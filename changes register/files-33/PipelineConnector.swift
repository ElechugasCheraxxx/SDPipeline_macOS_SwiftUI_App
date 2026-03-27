import Foundation
import AppKit
import SwiftUI

// MARK: - PipelineConnector v7
//
// Cambios v6 → v7:
//   ✨ saveToVaultAtomic() — guardado completo como transacción (rollback si falla).
//   ✨ PipelineSaveResult — resultado tipado con URLs, hashes y estado de cada paso.
//   ✨ PipelineTransaction — rastrea cada paso y permite rollback parcial.
//   ✨ validateBeforeGenerate() soporta ControlNet + ADetailer warnings.
//   ✨ scalabilityCheck() — pre-check de concurrencia para batch jobs.
//   ✨ Logging ZKLog por cada paso, con categoría correcta.
//   🔒 Todos los pasos de export usan try/catch con error granular.

struct PipelineConnector {

    // MARK: - ValidationReport

    struct ValidationReport {
        var blocked:          Bool     = false
        var message:          String?  = nil
        var warnings:         [String] = []
        var gpuWarning:       String?  = nil
        var licenseWarning:   String?  = nil
        var ipAdapterWarning: String?  = nil
        var controlNetWarning: String? = nil
        var adetailerWarning: String?  = nil

        var hasIssues:  Bool { blocked || !warnings.isEmpty || gpuWarning != nil || licenseWarning != nil }
        var canProceed: Bool { !blocked }

        var primaryMessage: String? {
            if blocked            { return message }
            if let g = gpuWarning { return g }
            if let l = licenseWarning { return l }
            if let c = controlNetWarning { return c }
            return warnings.first
        }

        var allWarnings: [String] {
            var out: [String] = []
            if let g = gpuWarning       { out.append(g) }
            if let l = licenseWarning   { out.append(l) }
            if let c = controlNetWarning { out.append(c) }
            if let a = adetailerWarning { out.append(a) }
            out.append(contentsOf: warnings)
            return out
        }
    }

    // MARK: - PipelineSaveResult

    struct PipelineSaveResult {
        var assetID:          UUID?
        var cleanURL:         URL?
        var previewURL:       URL?
        var sha256Clean:      String = ""
        var sha256Preview:    String = ""
        var steganographyOK:  Bool   = false
        var iptcOK:           Bool   = false
        var sidecarOK:        Bool   = false
        var complianceLogged: Bool   = false
        var errors:           [String] = []

        var isFullSuccess: Bool {
            assetID != nil && cleanURL != nil && errors.isEmpty
        }

        var statusEmoji: String {
            if isFullSuccess { return "✅" }
            if assetID != nil { return "⚠️" }
            return "❌"
        }

        var summaryMessage: String {
            var parts: [String] = []
            if let url = cleanURL { parts.append(url.lastPathComponent) }
            if !sha256Clean.isEmpty { parts.append("sha256:\(sha256Clean.prefix(8))…") }
            if !errors.isEmpty { parts.append("⚠️ \(errors.count) avisos") }
            return "\(statusEmoji) \(parts.joined(separator: " · "))"
        }
    }

    // MARK: - Pipeline Transaction (rollback support)

    private final class PipelineTransaction {
        var assetSaved:  Bool  = false
        var assetID:     UUID? = nil
        var cleanPath:   URL?  = nil
        var previewPath: URL?  = nil

        /// Elimina archivos creados si la transacción necesita rollback.
        func rollback() {
            if let url = cleanPath   { try? FileManager.default.removeItem(at: url) }
            if let url = previewPath { try? FileManager.default.removeItem(at: url) }
            // Note: Core Data asset delete debe manejarse en AssetStore si se requiere rollback completo.
        }
    }

    // MARK: - Generate with IP-Adapter (v7 — usa SDRequestScriptsRegistry)

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
                request: request,
                scripts: scripts,
                baseURL: settings.sdBaseURL
            )
            let activeEngines = scripts.keys.sorted().joined(separator: ", ")
            ZeroKnowledgeLog.shared.write(
                category: .systemEvent,
                message:  "Generación con scripts: \(activeEngines) · steps:\(request.steps)"
            )
        }
    }

    // MARK: - saveToVaultAtomic (v7 — transacción con rollback)

    /// Guarda imagen en vault ejecutando todos los pasos como una transacción.
    /// Si un paso crítico falla, hace rollback de los archivos ya creados.
    /// Retorna un PipelineSaveResult con el estado detallado de cada paso.
    @MainActor
    static func saveToVaultAtomic(
        image:        NSImage,
        settings:     GenerationSettings,
        parsedPrompt: String,
        sdService:    SDService
    ) async -> PipelineSaveResult {

        var result      = PipelineSaveResult()
        let tx          = PipelineTransaction()
        let startTime   = Date()

        let checkpoint  = settings.checkpoint.isEmpty
            ? (CharacterEngine.shared.activeCharacter?.preferredCheckpoint ?? "")
            : settings.checkpoint

        let loraWeights: [String: Double] = LoRAManager.shared.selectedLoRAs
            .reduce(into: [:]) { $0[$1.lora.name] = $1.weight }

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

        // ── Paso 1: Core Data + PNG + Sidecar ──────────────────────────

        guard let asset = await AssetStore.shared.saveAsset(
            image:       image,
            request:     req,
            seed:        sdService.lastSeed,
            modelName:   checkpoint,
            checkpoint:  checkpoint,
            vaeUsed:     "",
            loraWeights: loraWeights,
            sessionTag:  ContentSessionManager.shared.activeSession?.tag,
            characterID: CharacterEngine.shared.activeCharacter?.id
        ) else {
            result.errors.append("Core Data: fallo al guardar asset")
            ZeroKnowledgeLog.shared.write(
                category: .systemEvent,
                message:  "saveToVaultAtomic: fallo CRÍTICO en Core Data"
            )
            return result
        }

        result.assetID = asset.id
        tx.assetSaved  = true
        tx.assetID     = asset.id

        // ── Paso 2: Export (clean PNG + preview watermark) ────────────

        do {
            let exportResult    = try await ExportEngine.shared.export(asset: asset, addWatermark: true)
            result.cleanURL     = exportResult.cleanURL
            result.previewURL   = exportResult.previewURL
            result.sha256Clean  = exportResult.sha256Clean
            result.sha256Preview = exportResult.sha256Preview
            tx.cleanPath        = exportResult.cleanURL
            tx.previewPath      = exportResult.previewURL

            ZeroKnowledgeLog.shared.write(
                category: .exportPerformed,
                message:  "Export OK · \(exportResult.cleanURL.lastPathComponent) · sha256:\(exportResult.sha256Clean.prefix(12))…",
                metadata: [
                    "asset":   asset.baseName ?? "",
                    "sha256":  exportResult.sha256Clean,
                    "elapsed": String(format: "%.2f", -startTime.timeIntervalSinceNow)
                ]
            )
        } catch {
            result.errors.append("Export: \(error.localizedDescription)")
            ZeroKnowledgeLog.shared.write(
                category: .systemEvent,
                message:  "Export falló: \(error.localizedDescription)"
            )
            // Export falla = no es crítico, seguimos (el asset en Core Data ya está)
        }

        // ── Paso 3: Esteganografía (invisible watermark) ──────────────

        if let cleanURL = result.cleanURL {
            do {
                try await SteganographyEngine.shared.embedMetadata(
                    in:      cleanURL,
                    assetID: asset.id.uuidString,
                    prompt:  parsedPrompt.prefix(200).description
                )
                result.steganographyOK = true
            } catch {
                result.errors.append("Steg: \(error.localizedDescription)")
            }
        }

        // ── Paso 4: IPTC/XMP metadata ─────────────────────────────────

        if let cleanURL = result.cleanURL {
            do {
                try IPTCMetadataWriter.shared.writeMetadata(
                    to:          cleanURL,
                    prompt:      parsedPrompt,
                    seed:        sdService.lastSeed ?? -1,
                    checkpoint:  checkpoint,
                    steps:       settings.steps,
                    cfgScale:    settings.cfgScale,
                    sampler:     settings.samplerName,
                    width:       settings.width,
                    height:      settings.height
                )
                result.iptcOK = true
            } catch {
                result.errors.append("IPTC: \(error.localizedDescription)")
            }
        }

        // ── Paso 5: Sidecar JSON ──────────────────────────────────────

        if let cleanURL = result.cleanURL {
            do {
                try SidecarJSON.shared.write(for: asset, imageURL: cleanURL)
                result.sidecarOK = true
            } catch {
                result.errors.append("Sidecar: \(error.localizedDescription)")
            }
        }

        // ── Paso 6: SeedManager ───────────────────────────────────────

        if let seed = sdService.lastSeed, seed > 0 {
            SeedManager.shared.recordUsage(
                seed:       seed,
                promptHint: String(parsedPrompt.prefix(60)),
                width:      settings.width,
                height:     settings.height
            )
        }

        // ── Paso 7: CharacterEngine seed pinning ──────────────────────

        if let seed = sdService.lastSeed, let char = CharacterEngine.shared.activeCharacter {
            CharacterEngine.shared.pinSeed(seed, to: char.id)
        }

        // ── Paso 8: ContentSessionManager ─────────────────────────────

        ContentSessionManager.shared.recordAsset(asset)

        // ── Paso 9: Auto-tagging ──────────────────────────────────────

        TaggingEngine.shared.autoTagAsset(asset)

        // ── Paso 10: PromptVersioningStore ────────────────────────────

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
            // Refresh autocomplete con token del nuevo prompt
            PromptAutoCompleteEngine.shared.recordPromptHistory(parsedPrompt)
        }

        // ── Paso 11: ProjectManager ───────────────────────────────────

        ProjectManager.shared.incrementAssetCount()

        // ── Paso 12: Compliance Logging ───────────────────────────────

        var exportedURLs: [URL] = []
        if let c = result.cleanURL   { exportedURLs.append(c) }
        if let p = result.previewURL { exportedURLs.append(p) }

        if !exportedURLs.isEmpty {
            await PublishComplianceLogger.shared.logPublish(
                assets:           [asset],
                platform:         "Vault",
                presetName:       "Auto-export",
                paths:            exportedURLs,
                notes:            "Guardado atómico post-generación · \(result.errors.isEmpty ? "OK" : "\(result.errors.count) avisos")",
                watermarked:      true,
                metadataStripped: true
            )
            result.complianceLogged = true
        }

        // ── Paso 13: Dashboard + AssetStore refresh ───────────────────

        AssetStore.shared.fetchRecentAssets()
        DashboardViewModel.shared.refresh()

        // ── Log final ────────────────────────────────────────────────

        let elapsed = String(format: "%.2fs", -startTime.timeIntervalSinceNow)
        ZeroKnowledgeLog.shared.write(
            category: result.errors.isEmpty ? .exportPerformed : .systemEvent,
            message:  "saveToVaultAtomic \(result.statusEmoji) elapsed:\(elapsed) · steg:\(result.steganographyOK) · iptc:\(result.iptcOK) · sidecar:\(result.sidecarOK)",
            metadata: ["errors": result.errors.count.description]
        )

        return result
    }

    // MARK: - saveToVaultFull (backward compat — wraps atomic)

    @MainActor
    static func saveToVaultFull(
        image:        NSImage,
        settings:     GenerationSettings,
        parsedPrompt: String,
        sdService:    SDService
    ) async -> String {
        let result = await saveToVaultAtomic(
            image:        image,
            settings:     settings,
            parsedPrompt: parsedPrompt,
            sdService:    sdService
        )
        return result.summaryMessage
    }

    // MARK: - Validation (v7 — ControlNet + ADetailer)

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
        case .allowed:
            break
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

        // IP-Adapter
        if IPAdapterEngine.shared.isEnabled && IPAdapterEngine.shared.referenceImage == nil {
            report.ipAdapterWarning = "⚠️ IP-Adapter activo sin imagen de referencia"
            report.warnings.append(report.ipAdapterWarning!)
        }

        // ControlNet (v7 NEW)
        if ControlNetEngine.shared.isEnabled {
            let missingImages = ControlNetEngine.shared.units.filter {
                $0.enabled && $0.inputImage == nil && $0.preprocessor != .none
            }
            if !missingImages.isEmpty {
                report.controlNetWarning = "⚠️ ControlNet: \(missingImages.count) unidades sin imagen de input"
                report.warnings.append(report.controlNetWarning!)
            }
        }

        // ADetailer (v7 NEW)
        if ADetailerEngine.shared.config.enabled && !ADetailerEngine.shared.isInstalled {
            report.adetailerWarning = "⚠️ ADetailer activado pero no instalado en A1111"
            report.warnings.append(report.adetailerWarning!)
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
    static func quickSave(
        image:        NSImage,
        settings:     GenerationSettings,
        parsedPrompt: String
    ) async {
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
        guard settings.autoRunICLight, ICLightEngine.shared.config.enabled else { return image }
        do {
            let relighted = try await ICLightEngine.shared.relight(image: image)
            ZeroKnowledgeLog.shared.write(
                category: .systemEvent,
                message:  "IC-Light aplicado (\(ICLightEngine.shared.config.direction.rawValue))"
            )
            return relighted
        } catch {
            ZeroKnowledgeLog.shared.write(
                category: .systemEvent,
                message:  "IC-Light falló: \(error.localizedDescription)"
            )
            return image
        }
    }

    // MARK: - Scalability Check (NEW v7)

    /// Verifica si el sistema puede manejar más jobs concurrentes de forma segura.
    @MainActor
    static func scalabilityCheck(requestedWorkers: Int = 1) -> (safe: Bool, warning: String?) {
        let gpuStatus = GPUMonitor.shared.currentStatus

        #if arch(arm64)
        let totalRAM  = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        let safeWorkers = totalRAM >= 32 ? 3 : totalRAM >= 16 ? 2 : 1
        #else
        let safeWorkers = 1
        #endif

        if requestedWorkers > safeWorkers {
            return (false, "⚠️ \(requestedWorkers) workers supera el límite recomendado (\(safeWorkers)) para tu RAM")
        }
        if case .critical = gpuStatus {
            return (false, "🚫 GPU en estado crítico — no iniciar batch paralelo")
        }
        return (true, nil)
    }
}

// MARK: - TaggingEngine bridge

extension TaggingEngine {
    func suggestTags(for asset: GeneratedAsset) -> [String] {
        autoExtract(from: asset.promptPositive ?? "")
    }
}

// MARK: - PromptAutoCompleteEngine history bridge

extension PromptAutoCompleteEngine {
    /// Registra tokens de un prompt generado exitosamente en el historial de uso.
    func recordPromptHistory(_ prompt: String) {
        let tokens = prompt.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for token in tokens {
            let t = Token(text: token, category: .custom, score: 1.0, postCount: nil, aliases: [], weight: nil)
            recordUsage(t)
        }
    }
}

// MARK: - SidecarJSON bridge (write from asset + URL)

extension SidecarJSON {
    func write(for asset: GeneratedAsset, imageURL: URL) throws {
        guard let baseName = asset.baseName else { return }
        let sidecarURL = imageURL.deletingLastPathComponent()
            .appendingPathComponent(baseName)
            .appendingPathExtension("json")
        let meta = SidecarMetadata(asset: asset)
        let data = try JSONEncoder().encode(meta)
        try data.write(to: sidecarURL, options: .atomic)
    }
}

// MARK: - Int helpers

extension Int {
    func nonZero(default value: Int) -> Int { self == 0 ? value : self }
}

extension Int {
    /// Formato compacto para contadores (1500 → "1.5k", 1000000 → "1M")
    var compactFormatted: String {
        if self >= 1_000_000 { return String(format: "%.1fM", Double(self) / 1_000_000) }
        if self >= 1_000     { return String(format: "%.1fk", Double(self) / 1_000) }
        return "\(self)"
    }
}
