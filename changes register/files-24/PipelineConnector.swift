import Foundation
import AppKit
import SwiftUI

// MARK: - PipelineConnector v4
// Pegamento central entre módulos del pipeline.
// FIXES v3→v4:
//   - Todas las llamadas usan APIs verificadas contra los archivos fuente reales
//   - LoRAManager.selectedLoRAs[x].promptKey → .lora.promptKey (SelectedLoRA.lora es LoRAEntry)
//   - ExportEngine.shared.export() es async throws → wrapped correctamente
//   - ZeroKnowledgeLog.entries(category:) → usado directamente
//   - GPUMonitor.preCheckStatus switch usa .ok/.warning/.critical/.unknown

struct PipelineConnector {

    // MARK: - ValidationReport

    struct ValidationReport {
        var blocked:    Bool    = false
        var message:    String? = nil
        var warnings:   [String] = []
        var gpuWarning: String? = nil

        var hasIssues:  Bool { blocked || !warnings.isEmpty || gpuWarning != nil }
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

        // LoRA weights: SelectedLoRA tiene .lora (LoRAEntry) y .weight
        let loraWeights: [String: Double] = LoRAManager.shared.selectedLoRAs
            .reduce(into: [:]) { $0[$1.lora.name] = $1.weight }

        // 1. Core Data + PNG con esteganografía + sidecar
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

        // 2. ExportEngine — clean PNG + preview con watermark
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
            exportMsg = " · ⚠️ Export falló: \(error.localizedDescription)"
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

        // 4. CharacterEngine
        if let seed = sdService.lastSeed, let char = CharacterEngine.shared.activeCharacter {
            CharacterEngine.shared.pinSeed(seed, to: char.id)
        }

        // 5. ContentSessionManager
        ContentSessionManager.shared.recordAsset(asset)

        // 6. TaggingEngine — auto-tag si vacío
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

        // 8. Refrescar galería + dashboard
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
        var report = ValidationReport()

        // Safety filter
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
