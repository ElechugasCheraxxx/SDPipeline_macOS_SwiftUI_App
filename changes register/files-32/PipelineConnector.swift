import Foundation
import AppKit
import SwiftUI

// MARK: - PipelineConnector v6
//
// Cambios v5→v6:
//   + generateWithIPAdapter() — inyecta alwayson_scripts de IPAdapterEngine
//   + saveToVaultFull() — compliance logging automático post-export
//   + auto-tagging mejorado (usa TaggingEngine.autoTagAsset)
//   + validateBeforeGenerate() — verifica IP-Adapter config
//   + IC-Light post-processing opcional
//   + ProjectFolderManager aware (guarda en proyecto activo)

struct PipelineConnector {

    // MARK: - ValidationReport

    struct ValidationReport {
        var blocked:        Bool     = false
        var message:        String?  = nil
        var warnings:       [String] = []
        var gpuWarning:     String?  = nil
        var licenseWarning: String?  = nil
        var ipAdapterWarning: String? = nil

        var hasIssues:  Bool { blocked || !warnings.isEmpty || gpuWarning != nil || licenseWarning != nil }
        var canProceed: Bool { !blocked }

        var primaryMessage: String? {
            if blocked { return message }
            if let g = gpuWarning  { return g }
            if let l = licenseWarning { return l }
            return warnings.first
        }
    }

    // MARK: - Generate with IP-Adapter

    /// Construye el request completo con alwayson_scripts y ejecuta la generación.
    @MainActor
    static func generateWithIPAdapter(
        prompt:         String,
        negativePrompt: String,
        settings:       GenerationSettings,
        sdService:      SDService
    ) async {
        let (request, scripts) = settings.buildRequestWithScripts(
            prompt:         prompt,
            negativePrompt: negativePrompt
        )

        if scripts.isEmpty {
            await sdService.generate(request: request, baseURL: settings.sdBaseURL)
        } else {
            await sdService.generateWithScripts(
                request:  request,
                scripts:  scripts,
                baseURL:  settings.sdBaseURL
            )
            ZeroKnowledgeLog.shared.write(
                category: .systemEvent,
                message:  "Generación con scripts: \(scripts.keys.joined(separator: ", "))"
            )
        }
    }

    // MARK: - Save to Vault Full (v6)

    @MainActor
    static func saveToVaultFull(
        image:        NSImage,
        settings:     GenerationSettings,
        parsedPrompt: String,
        sdService:    SDService
    ) async -> String {

        let req = SDRequest(
            prompt:            parsedPrompt,
            negativePrompt:    settings.negativePrompt,
            seed:              settings.seed,
            steps:             settings.steps,
            cfgScale:          settings.cfgScale,
            width:             settings.width,
            height:            settings.height,
            samplerName:       settings.samplerName,
            enableHR:          settings.enableHR,
            hrUpscaler:        settings.hrUpscaler,
            hrScale:           settings.hrScale,
            hrSecondPassSteps: settings.hrSteps,
            denoisingStrength: settings.denoisingStrength,
            restoreFaces:      settings.restoreFaces
        )

        let checkpoint = settings.checkpoint.isEmpty
            ? (CharacterEngine.shared.activeCharacter?.preferredCheckpoint ?? "")
            : settings.checkpoint

        let loraWeights: [String: Double] = LoRAManager.shared.selectedLoRAs
            .reduce(into: [:]) { $0[$1.lora.name] = $1.weight }

        // 1. Core Data + PNG + sidecar + esteganografía
        let asset = await AssetStore.shared.saveAsset(
            image:       image,
            request:     req,
            seed:        sdService.lastSeed,
            modelName:   checkpoint,
            checkpoint:  checkpoint,
            vaeUsed:     "",
            loraWeights: loraWeights,
            sessionTag:  ContentSessionManager.shared.activeSession?.tag,
            characterID: CharacterEngine.shared.activeCharacter?.id
        )

        guard let asset else {
            ZeroKnowledgeLog.shared.write(category: .systemEvent,
                message: "saveToVaultFull: fallo al guardar asset en Core Data")
            return "⚠️ Error al guardar en vault"
        }

        // 2. Export (clean PNG + preview watermark)
        var exportMsg  = ""
        var exportedURLs: [URL] = []
        do {
            let result = try await ExportEngine.shared.export(asset: asset, addWatermark: true)
            exportMsg    = " · \(result.cleanURL.lastPathComponent)"
            exportedURLs = [result.cleanURL, result.previewURL]
            ZeroKnowledgeLog.shared.write(
                category: .exportPerformed,
                message:  "Export OK · sha256: \(result.sha256Clean.prefix(12))…",
                metadata: ["asset": asset.baseName ?? "", "sha256": result.sha256Clean]
            )
        } catch {
            exportMsg = " · ⚠️ Export: \(error.localizedDescription)"
        }

        // 3. SeedManager
        if let seed = sdService.lastSeed, seed > 0 {
            SeedManager.shared.recordUsage(
                seed: seed, promptHint: String(parsedPrompt.prefix(60)),
                width: settings.width, height: settings.height
            )
        }

        // 4. CharacterEngine seed pinning
        if let seed = sdService.lastSeed,
           let char = CharacterEngine.shared.activeCharacter {
            CharacterEngine.shared.pinSeed(seed, to: char.id)
        }

        // 5. ContentSessionManager
        ContentSessionManager.shared.recordAsset(asset)

        // 6. TaggingEngine — auto-extract desde prompt
        TaggingEngine.shared.autoTagAsset(asset)

        // 7. PromptVersioningStore
        if !parsedPrompt.isEmpty {
            PromptVersioningStore.shared.save(
                positive:    parsedPrompt,
                negative:    settings.negativePrompt,
                steps:       settings.steps,
                cfgScale:    settings.cfgScale,
                samplerName: settings.samplerName,
                width:       settings.width,
                height:      settings.height,
                checkpoint:  checkpoint
            )
        }

        // 8. ProjectManager
        ProjectManager.shared.incrementAssetCount()

        // 9. Compliance logging (v6 NEW)
        if !exportedURLs.isEmpty {
            await PublishComplianceLogger.shared.logPublish(
                assets:          [asset],
                platform:        "Vault",
                presetName:      "Auto-export",
                paths:           exportedURLs,
                notes:           "Guardado automático post-generación",
                watermarked:     true,
                metadataStripped: true
            )
        }

        // 10. Dashboard refresh
        AssetStore.shared.fetchRecentAssets()
        DashboardViewModel.shared.refresh()

        return "✓ Guardado en Vault\(exportMsg)"
    }

    // MARK: - Validation (v6)

    @MainActor
    static func validateBeforeGenerate(
        parsedPrompt: String,
        settings:     GenerationSettings
    ) -> ValidationReport {
        var report = ValidationReport()

        // Prompt safety
        let safetyResult = PromptSafetyFilter.validatePrompt(
            positive: parsedPrompt,
            negative: settings.negativePrompt
        )
        Task { @MainActor in PromptSafetyFilter.logResult(safetyResult, prompt: parsedPrompt) }

        switch safetyResult {
        case .allowed: break
        case .flagged(let warnings):
            report.warnings = warnings
            report.message  = warnings.first
        case .blocked(let reason, _):
            report.blocked = true
            report.message = "🚫 \(reason)"
        }

        guard !report.blocked else { return report }

        // GPU pre-check
        GPUMonitor.shared.runPreCheck(
            requestedWidth:  settings.width,
            requestedHeight: settings.height
        )
        switch GPUMonitor.shared.preCheckStatus {
        case .warning(let msg):  report.gpuWarning = "⚠️ GPU: \(msg)"
        case .critical(let msg): report.gpuWarning = "🚫 GPU: \(msg)"
        case .ok, .unknown:      break
        }

        // License check
        if !settings.checkpoint.isEmpty {
            let (_, msg) = checkLicense(checkpoint: settings.checkpoint)
            report.licenseWarning = msg
        }

        // IP-Adapter config warning
        if IPAdapterEngine.shared.isEnabled && IPAdapterEngine.shared.referenceImage == nil {
            report.ipAdapterWarning = "⚠️ IP-Adapter activo pero sin imagen de referencia"
        }

        return report
    }

    @MainActor
    static func checkLicense(checkpoint: String) -> (safe: Bool, message: String?) {
        guard !checkpoint.isEmpty else { return (true, nil) }
        let status = LicenseVault.shared.checkCompliance(checkpointName: checkpoint)
        return (status.isUsable, status.alertMessage)
    }

    // MARK: - Quick Save (sin export completo)

    @MainActor
    static func quickSave(image: NSImage, settings: GenerationSettings, parsedPrompt: String) async {
        let req = SDRequest(
            prompt:         parsedPrompt,
            negativePrompt: settings.negativePrompt,
            seed:           settings.seed,
            steps:          settings.steps,
            cfgScale:       settings.cfgScale,
            width:          settings.width,
            height:         settings.height
        )
        _ = await AssetStore.shared.saveAsset(
            image:       image,
            request:     req,
            seed:        settings.seed,
            modelName:   settings.checkpoint,
            checkpoint:  settings.checkpoint,
            vaeUsed:     "",
            loraWeights: [:]
        )
    }

    // MARK: - IC-Light Post-Process

    @MainActor
    static func applyICLightIfEnabled(to image: NSImage, settings: GenerationSettings) async -> NSImage {
        guard settings.autoRunICLight,
              ICLightEngine.shared.config.enabled
        else { return image }

        do {
            let relighted = try await ICLightEngine.shared.relight(image: image)
            ZeroKnowledgeLog.shared.write(
                category: .systemEvent,
                message: "IC-Light relight aplicado (\(ICLightEngine.shared.config.direction.rawValue))"
            )
            return relighted
        } catch {
            ZeroKnowledgeLog.shared.write(
                category: .systemEvent,
                message: "IC-Light falló: \(error.localizedDescription)"
            )
            return image
        }
    }
}

// MARK: - TaggingEngine suggestTags bridge

extension TaggingEngine {
    /// Extrae tags sugeridos del prompt del asset sin añadirlos todavía.
    func suggestTags(for asset: GeneratedAsset) -> [String] {
        autoExtract(from: asset.promptPositive ?? "")
    }
}

// MARK: - GenerationSettings SDRequest builder helpers

extension GenerationSettings {

    var cfgScale: Double {
        get { Double(UserDefaults.standard.double(forKey: "gen.cfgScale").nonZero(default: 7.0)) }
        set { UserDefaults.standard.set(newValue, forKey: "gen.cfgScale") }
    }

    var hrSteps: Int {
        get { UserDefaults.standard.integer(forKey: "gen.hrSteps").nonZero(default: 15) }
        set { UserDefaults.standard.set(newValue, forKey: "gen.hrSteps") }
    }
}

extension Int {
    func nonZero(default value: Int) -> Int { self == 0 ? value : self }
}
