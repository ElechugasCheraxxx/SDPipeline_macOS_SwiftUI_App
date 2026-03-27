import Foundation
import AppKit
import SwiftUI

// MARK: - PipelineConnector
//
// Este archivo documenta y centraliza todas las CONEXIONES que faltan
// entre los módulos ya existentes. No define nueva lógica de negocio:
// solo actúa como "pegamento" entre piezas que existen pero no están
// conectadas entre sí.
//
// INSTRUCCIONES DE INTEGRACIÓN:
//
// 1. En RightPanelView.saveToVault(_:) — REEMPLAZAR el bloque actual con
//    PipelineConnector.saveToVaultFull(...)
//
// 2. En ContentView.generate() — AÑADIR llamada a SeedManager.recordUsage(...)
//    después de que sdService.stage == .done
//
// 3. En SDPipelineApp — AÑADIR BackupManager.shared.startScheduler() en .task

// MARK: - Full Vault Save (reemplaza el saveToVault actual en RightPanelView)

struct PipelineConnector {

    /// Guardar imagen en vault completo:
    ///   1. AssetStore (Core Data + PNG firmado con steg + sidecar JSON)
    ///   2. ExportEngine → versión limpia (sin EXIF) + preview con watermark
    ///   3. SeedManager → registrar seed en historial y favoritos si aplica
    ///   4. CharacterEngine → pinSeed si hay personaje activo
    ///
    /// - Returns: Mensaje de resultado para mostrar en la UI.
    @MainActor
    static func saveToVaultFull(
        image:      NSImage,
        settings:   GenerationSettings,
        parsedPrompt: String,
        sdService:  SDService
    ) async -> String {

        let req = SDRequest(
            prompt:             parsedPrompt,
            negativePrompt:     settings.negativePrompt,
            seed:               settings.seed,
            steps:              settings.steps,
            cfgScale:           settings.cfgScale,
            width:              settings.width,
            height:             settings.height,
            samplerName:        settings.samplerName,
            enableHR:           settings.enableHR,
            hrUpscaler:         settings.hrUpscaler,
            hrScale:            settings.hrScale,
            hrSecondPassSteps:  settings.hrSteps,
            denoisingStrength:  settings.denoisingStrength,
            restoreFaces:       settings.restoreFaces
        )

        // Resolver checkpoint activo (del CharacterEngine o del settings)
        let checkpoint = settings.checkpoint.isEmpty
            ? (CharacterEngine.shared.activeCharacter?.preferredCheckpoint ?? "")
            : settings.checkpoint

        // LoRA weights activos
        let loraWeights: [String: Double] = LoRAManager.shared.selectedLoRAs.reduce(into: [:]) {
            $0[$1.lora.promptKey] = $1.weight
        }

        // 1. Guardar en Core Data + PNG firmado + sidecar
        let asset = await AssetStore.shared.saveAsset(
            image:       image,
            request:     req,
            seed:        sdService.lastSeed,
            modelName:   checkpoint,
            checkpoint:  checkpoint,
            vaeUsed:     "",    // Extensible: conectar con SDService cuando A1111 lo exponga
            loraWeights: loraWeights,
            sessionTag:  nil
        )

        guard let asset else {
            return "⚠️ Error al guardar en vault"
        }

        // 2. ExportEngine — versión limpia + preview con watermark
        do {
            let exportResult = try await ExportEngine.shared.export(asset: asset)
            // exportResult.cleanURL y exportResult.previewURL ya guardados en Core Data por export()
            _ = exportResult
        } catch {
            // El export falla de forma no-crítica — el asset ya está en Core Data
            print("⚠️ ExportEngine: \(error.localizedDescription)")
        }

        // 3. SeedManager — registrar seed en historial
        if let seed = sdService.lastSeed, seed > 0 {
            SeedManager.shared.recordUsage(
                seed:       seed,
                promptHint: String(parsedPrompt.prefix(60)),
                width:      settings.width,
                height:     settings.height
            )
        }

        // 4. CharacterEngine — anclar seed al personaje activo si existe
        if let seed = sdService.lastSeed,
           let character = CharacterEngine.shared.activeCharacter {
            CharacterEngine.shared.pinSeed(seed, to: character.id)
        }

        // 5. Refrescar galería
        AssetStore.shared.fetchRecentAssets()

        return "✓ Guardado en Vault · Export generado"
    }

    // MARK: - Prompt Safety Check (wrapper unificado)

    /// Validar prompt antes de enviar. Retorna nil si está permitido,
    /// o el mensaje de error/advertencia si está bloqueado o flaggeado.
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
            return (false, warnings.first)    // Advertencia: permite pero avisa
        case .blocked(let reason, _):
            return (true, "🚫 \(reason)")
        }
    }

    // MARK: - GPU Pre-Check (wrapper unificado)

    /// Verificar VRAM antes de generar. Retorna advertencia si hay poco espacio.
    @MainActor
    static func gpuPreCheck(width: Int, height: Int) -> String? {
        GPUMonitor.shared.runPreCheck(requestedWidth: width, requestedHeight: height)

        switch GPUMonitor.shared.preCheckStatus {
        case .warning(let msg): return "⚠️ GPU: \(msg)"
        case .blocked(let msg): return "🚫 GPU: \(msg)"
        default:                return nil
        }
    }
}

// MARK: - ExportEngine async wrapper
// ExportEngine.export() es async throws pero GeneratedAsset.imagePath
// se setea síncronamente en AssetStore.saveAsset(). Este wrapper
// verifica que el path existe antes de lanzar el export.

extension ExportEngine {

    /// Export seguro: verifica que el asset tiene imagePath antes de exportar.
    @MainActor
    func export(asset: GeneratedAsset) async throws -> ExportResult {
        guard asset.imagePath != nil else {
            throw ExportError.imageNotFound("asset.imagePath es nil")
        }
        return try await export(asset: asset, addWatermark: true)
    }
}

// MARK: - LoRAManager selectedLoRAs accessor
// Expone la lista de LoRAs seleccionados para que PipelineConnector
// pueda extraer los pesos sin acceder a propiedades privadas.

extension LoRAManager {
    /// LoRAs actualmente seleccionados para la generación.
    /// El backing storage se define en LoRAManager — añadir si no existe:
    ///   @Published var selectedLoRAs: [SelectedLoRA] = []
    var selectedLoRAsForExport: [SelectedLoRA] {
        selectedLoRAs   // Propiedad ya publicada en LoRAManager
    }
}

// MARK: - SDPipelineApp integration snippet
// Añadir en SDPipelineApp.body.WindowGroup.task:
//
//   .task {
//       vault.checkFirstRun()
//       LicenseVault.shared.generateAllTemplates()
//       GPUMonitor.shared.detectDevice()
//       BackupManager.shared.startScheduler()  // ← AÑADIR ESTA LÍNEA
//   }

// MARK: - ContentView generate() integration snippet
// Añadir al final de generate() en ContentView, después de la llamada await sdService.generate():
//
//   if sdService.stage == .done, let seed = sdService.lastSeed {
//       SeedManager.shared.recordUsage(
//           seed:       seed,
//           promptHint: String(parsedPrompt.prefix(60)),
//           width:      settings.width,
//           height:     settings.height
//       )
//   }

// MARK: - RightPanelView.saveToVault replacement
// Reemplazar el método saveToVault(_ image: NSImage) en RightPanelView por:
//
//   private func saveToVault(_ image: NSImage) {
//       guard !isSavingVault else { return }
//       isSavingVault = true
//       Task {
//           let msg = await PipelineConnector.saveToVaultFull(
//               image:        image,
//               settings:     settings,
//               parsedPrompt: parsedPrompt,
//               sdService:    sdService
//           )
//           await MainActor.run {
//               isSavingVault = false
//               vaultSaveMsg  = msg
//           }
//           try? await Task.sleep(for: .seconds(3))
//           await MainActor.run { vaultSaveMsg = nil }
//       }
//   }
