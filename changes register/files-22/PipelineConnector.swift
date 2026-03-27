import Foundation
import AppKit
import SwiftUI

// MARK: - PipelineConnector
//
// Pegamento central entre módulos del pipeline.
// v2 FIXES:
//   - saveAsset ahora es async → await correcto
//   - ExportEngine export wrapped correctamente
//   - Añadido ContentSessionManager.recordGeneration

struct PipelineConnector {

    /// Guardar imagen en vault completo:
    ///   1. AssetStore (Core Data + PNG firmado + sidecar JSON) — ahora async
    ///   2. ExportEngine → versión limpia + preview con watermark
    ///   3. SeedManager → registrar seed
    ///   4. CharacterEngine → pinSeed si hay personaje activo
    ///   5. ContentSessionManager → registrar en sesión activa
    ///
    /// - Returns: Mensaje de resultado para la UI.
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

        // 1. Guardar en Core Data + PNG firmado + sidecar (FIX: await correcto)
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
            return "⚠️ Error al guardar en vault"
        }

        // 2. ExportEngine — versión limpia + preview
        do {
            let exportResult = try await ExportEngine.shared.export(asset: asset, addWatermark: true)
            _ = exportResult
        } catch {
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
           let character = CharacterEngine.shared.activeCharacter {
            CharacterEngine.shared.pinSeed(seed, to: character.id)
        }

        // 5. ContentSessionManager — registrar en sesión activa
        ContentSessionManager.shared.recordAsset(asset)

        // 6. TaggingEngine — auto-tag si no tiene tags
        let tags = TaggingEngine.shared.tags(for: asset)
        if tags.isEmpty {
            TaggingEngine.shared.suggestTags(for: asset).forEach {
                TaggingEngine.shared.addTag($0, to: asset)
            }
        }

        // 7. Refrescar galería
        AssetStore.shared.fetchRecentAssets()

        return "✓ Guardado en Vault · Export generado"
    }

    // MARK: - Prompt Safety Check

    /// Validar prompt antes de enviar. Retorna (blocked, message).
    static func validateBeforeGenerate(
        parsedPrompt: String,
        settings:     GenerationSettings
    ) -> (blocked: Bool, message: String?) {
        let result = PromptSafetyFilter.validatePrompt(
            positive: parsedPrompt,
            negative: settings.negativePrompt
        )
        PromptSafetyFilter.logResult(result, prompt: parsedPrompt)

        switch result {
        case .allowed:
            return (false, nil)
        case .flagged(let warnings):
            return (false, warnings.first)
        case .blocked(let reason, _):
            return (true, "🚫 \(reason)")
        }
    }

    // MARK: - GPU Pre-Check

    @MainActor
    static func gpuPreCheck(width: Int, height: Int) -> String? {
        GPUMonitor.shared.runPreCheck(requestedWidth: width, requestedHeight: height)
        switch GPUMonitor.shared.preCheckStatus {
        case .warning(let msg):  return "⚠️ GPU: \(msg)"
        case .critical(let msg): return "🚫 GPU: \(msg)"
        default:                 return nil
        }
    }
}

// MARK: - ExportEngine async wrapper

extension ExportEngine {
    @MainActor
    func export(asset: GeneratedAsset, addWatermark: Bool = true) async throws -> ExportResult {
        guard asset.imagePath != nil else {
            throw ExportError.imageNotFound("asset.imagePath es nil")
        }
        return try await export(asset: asset, addWatermark: addWatermark)
    }
}
