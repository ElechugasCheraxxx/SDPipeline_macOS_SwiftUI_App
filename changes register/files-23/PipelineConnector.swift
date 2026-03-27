import Foundation
import AppKit
import SwiftUI

// MARK: - PipelineConnector
//
// Pegamento central entre módulos del pipeline.
// v3 FIXES:
//   - ExportEngine wrapper ELIMINADO (causaba infinite loop — se llamaba a sí mismo)
//   - saveToVaultFull llama ExportEngine.shared.export() directamente
//   - validateBeforeGenerate retorna ValidationReport estructurado
//   - checkLicense() nuevo helper para PublishView
//   - ZeroKnowledgeLog integrado en operaciones críticas

struct PipelineConnector {

    // MARK: - ValidationReport

    struct ValidationReport {
        var blocked:    Bool
        var message:    String?
        var warnings:   [String]
        var gpuWarning: String?

        var hasIssues: Bool { blocked || !warnings.isEmpty || gpuWarning != nil }
        var canProceed: Bool { !blocked }
    }

    // MARK: - Save to Vault Full

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

        let loraWeights: [String: Double] = LoRAManager.shared.selectedLoRAs.reduce(into: [:]) {
            $0[$1.lora.promptKey] = $1.weight
        }

        // 1. Core Data + PNG firmado + sidecar
        let asset = await AssetStore.shared.saveAsset(
            image:       image,
            request:     req,
            seed:        sdService.lastSeed,
            modelName:   checkpoint,
            checkpoint:  checkpoint,
            vaeUsed:     "",
            loraWeights: loraWeights,
            sessionTag:  ContentSessionManager.shared.activeSession?.tag
        )

        guard let asset else {
            ZeroKnowledgeLog.shared.write(
                category: .systemEvent,
                message:  "saveToVaultFull: fallo al guardar asset en Core Data"
            )
            return "⚠️ Error al guardar en vault"
        }

        // 2. Export Engine — versión limpia + preview con watermark
        // FIX v3: llamar directamente, sin el wrapper que producía infinite loop.
        var exportMsg = ""
        do {
            let result = try await ExportEngine.shared.export(asset: asset, addWatermark: true)
            exportMsg = " · \(result.cleanURL.lastPathComponent)"
            ZeroKnowledgeLog.shared.write(
                category: .exportPerformed,
                message:  "Export OK · sha256: \(result.sha256Clean.prefix(12))…",
                metadata: ["asset": asset.baseName ?? "", "sha256": result.sha256Clean]
            )
        } catch {
            exportMsg = " · ⚠️ Export falló"
            print("⚠️ ExportEngine: \(error.localizedDescription)")
        }

        // 3. SeedManager
        if let seed = sdService.lastSeed, seed > 0 {
            SeedManager.shared.recordUsage(
                seed:       seed,
                promptHint: String(parsedPrompt.prefix(60)),
                width:      settings.width,
                height:     settings.height
            )
        }

        // 4. CharacterEngine — anclar seed al personaje activo
        if let seed = sdService.lastSeed,
           let char = CharacterEngine.shared.activeCharacter {
            CharacterEngine.shared.pinSeed(seed, to: char.id)
        }

        // 5. ContentSessionManager
        ContentSessionManager.shared.recordAsset(asset)

        // 6. TaggingEngine — auto-tag
        if TaggingEngine.shared.tags(for: asset).isEmpty {
            TaggingEngine.shared.suggestTags(for: asset).forEach {
                TaggingEngine.shared.addTag($0, to: asset)
            }
        }

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

        // 8. Refrescar
        AssetStore.shared.fetchRecentAssets()
        DashboardViewModel.shared.refresh()

        return "✓ Guardado en Vault\(exportMsg)"
    }

    // MARK: - Validation

    @MainActor
    static func validateBeforeGenerate(
        parsedPrompt: String,
        settings:     GenerationSettings
    ) -> ValidationReport {
        var report = ValidationReport(blocked: false, message: nil, warnings: [], gpuWarning: nil)

        let safetyResult = PromptSafetyFilter.validatePrompt(
            positive: parsedPrompt,
            negative: settings.negativePrompt
        )
        Task { @MainActor in
            PromptSafetyFilter.logResult(safetyResult, prompt: parsedPrompt)
        }

        switch safetyResult {
        case .allowed:
            break
        case .flagged(let warnings):
            report.warnings = warnings
            report.message  = warnings.first
        case .blocked(let reason, _):
            report.blocked = true
            report.message = "🚫 \(reason)"
        }

        GPUMonitor.shared.runPreCheck(requestedWidth: settings.width, requestedHeight: settings.height)
        switch GPUMonitor.shared.preCheckStatus {
        case .warning(let msg):  report.gpuWarning = "⚠️ GPU: \(msg)"
        case .critical(let msg): report.gpuWarning = "🚫 GPU: \(msg)"
        default: break
        }

        return report
    }

    // MARK: - License Check

    @MainActor
    static func checkLicense(checkpoint: String) -> (safe: Bool, message: String?) {
        guard !checkpoint.isEmpty else { return (true, nil) }
        let status = LicenseVault.shared.checkCompliance(checkpointName: checkpoint)
        return (status.isUsable, status.alertMessage)
    }
}
// NOTE: El extension `ExportEngine.export(asset:addWatermark:)` que existía aquí
// fue eliminado en v3 — producía infinite recursion al llamarse a sí mismo.
// ExportEngine.shared.export() ya es async natively; úsalo directamente.
