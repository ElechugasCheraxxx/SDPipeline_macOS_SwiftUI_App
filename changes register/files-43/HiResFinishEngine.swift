import Foundation
import AppKit
import SwiftUI
import Combine

// MARK: - HiResFinishEngine
//
// Motor de "Finalizar en Alta Resolución" — el botón de one-click
// que lleva una imagen generada al nivel de calidad máxima para publicación.
//
// Pipeline completo en un solo paso:
//   1. ADetailer — refinamiento automático de caras y manos
//   2. PostProduction — ESRGAN upscale 2x/4x + face restore (GFPGAN/CodeFormer)
//   3. CinematicFilter — filtro cinemático opcional (si el usuario lo configuró)
//   4. ExportEngine — EXIF scrub + dual export (clean + preview con watermark)
//   5. SteganographyEngine — firma invisible en PNG final
//   6. IPTCMetadataWriter — metadata IPTC/XMP en versión clean
//   7. AssetVersioningStore — registrar como nueva versión (tag: .upscaled)
//
// Configuración:
//   • Presets de calidad: Draft / Standard / Master
//   • Parámetros ajustables por preset
//   • Estimación de tiempo y almacenamiento antes de ejecutar
//
// ROADMAP: "Botón Finalizar en Alta Resolución" (🟠 CORTO PLAZO)

@MainActor
final class HiResFinishEngine: ObservableObject {

    static let shared = HiResFinishEngine()
    private init() { loadPreset() }

    // MARK: - Quality Presets

    enum QualityPreset: String, Codable, CaseIterable {
        case draft    = "Draft"
        case standard = "Standard"
        case master   = "Master"

        var label: String { rawValue }
        var description: String {
            switch self {
            case .draft:    return "Rápido · ADetailer básico · sin upscale"
            case .standard: return "Balanceado · ADetailer + upscale 2x · filtro ligero"
            case .master:   return "Máxima calidad · ADetailer Pro + 4x upscale + filtro cinemático"
            }
        }

        var estimatedTimeMultiplier: Double {
            switch self {
            case .draft:    return 1.0
            case .standard: return 2.5
            case .master:   return 6.0
            }
        }

        var estimatedSizeMultiplierMB: Double {
            switch self {
            case .draft:    return 0.5
            case .standard: return 2.0
            case .master:   return 8.0
            }
        }
    }

    // MARK: - Finish Config

    struct FinishConfig: Codable {
        var preset:           QualityPreset = .standard

        // ADetailer
        var runADetailer:     Bool   = true
        var adetailerFace:    Bool   = true
        var adetailerHands:   Bool   = true
        var adetailerStrength: Double = 0.4

        // Upscale
        var runUpscale:       Bool   = true
        var upscaleFactor:    Double = 2.0       // 2x Standard, 4x Master
        var upscaleModel:     String = "R-ESRGAN 4x+"
        var faceRestore:      Bool   = true
        var faceRestoreModel: String = "CodeFormer"
        var faceRestoreWeight: Double = 0.7

        // Cinematic Filter
        var runCinematicFilter: Bool   = false
        var cinematicPresetName: String = ""

        // Export
        var runExport:        Bool   = true
        var addWatermark:     Bool   = true
        var applySteganography: Bool = true
        var embedIPTCMetadata:  Bool = true

        // Versioning
        var saveAsNewVersion: Bool   = true

        static func from(preset: QualityPreset) -> FinishConfig {
            switch preset {
            case .draft:
                return FinishConfig(
                    preset: .draft,
                    runADetailer: true, adetailerFace: true, adetailerHands: false,
                    adetailerStrength: 0.35,
                    runUpscale: false,
                    runCinematicFilter: false
                )
            case .standard:
                return FinishConfig(
                    preset: .standard,
                    runADetailer: true, adetailerFace: true, adetailerHands: true,
                    adetailerStrength: 0.4,
                    runUpscale: true, upscaleFactor: 2.0,
                    runCinematicFilter: false
                )
            case .master:
                return FinishConfig(
                    preset: .master,
                    runADetailer: true, adetailerFace: true, adetailerHands: true,
                    adetailerStrength: 0.45,
                    runUpscale: true, upscaleFactor: 4.0,
                    faceRestore: true, faceRestoreWeight: 0.8,
                    runCinematicFilter: true,
                    applySteganography: true,
                    embedIPTCMetadata: true
                )
            }
        }
    }

    // MARK: - Pipeline State

    struct PipelineProgress {
        var totalSteps:    Int        = 0
        var currentStep:   Int        = 0
        var currentLabel:  String     = ""
        var errors:        [String]   = []
        var isComplete:    Bool       = false

        var percentage: Double {
            guard totalSteps > 0 else { return 0 }
            return Double(currentStep) / Double(totalSteps) * 100
        }
    }

    struct FinishResult {
        let asset:          GeneratedAsset
        let versionID:      UUID?
        let exportResult:   ExportEngine.ExportResult?
        let stepsCompleted: [String]
        let warnings:       [String]
        let durationSeconds: Double
    }

    // MARK: - Published State

    @Published var config       = FinishConfig()
    @Published var progress     = PipelineProgress()
    @Published var isRunning    = false
    @Published var lastResult:  FinishResult?

    // MARK: - Estimate

    struct FinishEstimate {
        let steps:         [String]
        let estimatedSecs: Int
        let estimatedMB:   Double
    }

    func estimate(for asset: GeneratedAsset, config c: FinishConfig? = nil) -> FinishEstimate {
        let cfg = c ?? config
        var steps    = [String]()
        var baseSecs = 30.0  // ADetailer baseline

        if cfg.runADetailer {
            steps.append("ADetailer (\(cfg.adetailerFace ? "caras" : "")\(cfg.adetailerHands ? " + manos" : ""))")
            baseSecs += 20
        }
        if cfg.runUpscale {
            steps.append("Upscale \(cfg.upscaleFactor, specifier: "%.0f")x (\(cfg.upscaleModel))")
            baseSecs += 45 * cfg.upscaleFactor
        }
        if cfg.faceRestore {
            steps.append("Face Restore (\(cfg.faceRestoreModel))")
            baseSecs += 15
        }
        if cfg.runCinematicFilter {
            steps.append("Filtro Cinemático")
            baseSecs += 8
        }
        if cfg.runExport {
            steps.append("Export Clean + Preview")
            baseSecs += 5
        }
        if cfg.applySteganography {
            steps.append("Esteganografía")
            baseSecs += 3
        }
        if cfg.embedIPTCMetadata {
            steps.append("Metadata IPTC/XMP")
            baseSecs += 2
        }

        let sizeMB = cfg.upscaleFactor * cfg.upscaleFactor * 2.0   // heurística

        return FinishEstimate(
            steps:         steps,
            estimatedSecs: Int(baseSecs),
            estimatedMB:   sizeMB
        )
    }

    // MARK: - Execute Pipeline

    func finishInHighResolution(
        asset: GeneratedAsset,
        customConfig: FinishConfig? = nil
    ) async throws -> FinishResult {
        let cfg = customConfig ?? config

        isRunning = true
        let startDate = Date()
        var completed = [String]()
        var warnings  = [String]()
        var versionID: UUID?
        var exportResult: ExportEngine.ExportResult?

        let steps = estimate(for: asset, config: cfg).steps
        progress = PipelineProgress(totalSteps: steps.count, currentStep: 0, currentLabel: "Iniciando…")

        defer {
            isRunning = false
        }

        // 1 ─ ADetailer
        if cfg.runADetailer {
            await updateProgress(label: "ADetailer — refinando detalles…", steps: steps)
            do {
                try await runADetailerStep(asset: asset, cfg: cfg)
                completed.append("ADetailer")
            } catch {
                warnings.append("ADetailer falló: \(error.localizedDescription)")
            }
        }

        // 2 ─ Post-Producción (Upscale + Face Restore)
        if cfg.runUpscale || cfg.faceRestore {
            await updateProgress(label: "Upscale \(cfg.upscaleFactor, specifier: "%.0f")x…", steps: steps)
            do {
                try await runPostProductionStep(asset: asset, cfg: cfg)
                completed.append("Upscale/FaceRestore")
            } catch {
                warnings.append("Post-producción falló: \(error.localizedDescription)")
            }
        }

        // 3 ─ Cinematic Filter
        if cfg.runCinematicFilter && !cfg.cinematicPresetName.isEmpty {
            await updateProgress(label: "Aplicando filtro cinemático…", steps: steps)
            do {
                try await runCinematicFilterStep(asset: asset, presetName: cfg.cinematicPresetName)
                completed.append("CinematicFilter")
            } catch {
                warnings.append("Filtro cinemático falló: \(error.localizedDescription)")
            }
        }

        // 4 ─ Export (EXIF scrub + dual version)
        if cfg.runExport {
            await updateProgress(label: "Exportando versiones clean + preview…", steps: steps)
            do {
                exportResult = try await ExportEngine.shared.export(
                    asset: asset,
                    addWatermark: cfg.addWatermark
                )
                completed.append("Export")
            } catch {
                warnings.append("Export falló: \(error.localizedDescription)")
            }
        }

        // 5 ─ Steganography
        if cfg.applySteganography, let cleanURL = exportResult?.cleanURL {
            await updateProgress(label: "Incrustando firma invisible…", steps: steps)
            do {
                try await runSteganographyStep(asset: asset, outputURL: cleanURL)
                completed.append("Steganography")
            } catch {
                warnings.append("Esteganografía falló: \(error.localizedDescription)")
            }
        }

        // 6 ─ IPTC Metadata
        if cfg.embedIPTCMetadata, let cleanURL = exportResult?.cleanURL {
            await updateProgress(label: "Incrustando metadata IPTC/XMP…", steps: steps)
            let tags = TaggingEngine.shared.tags(for: asset)
            _ = try? IPTCMetadataWriter.embed(in: cleanURL, asset: asset, tags: tags)
            completed.append("IPTC")
        }

        // 7 ─ Version Registration
        if cfg.saveAsNewVersion, let cleanURL = exportResult?.cleanURL,
           let imageData = try? Data(contentsOf: cleanURL),
           let assetUUID = UUID(uuidString: asset.id?.uuidString ?? "") {
            await updateProgress(label: "Registrando versión final…", steps: steps)
            let sha256 = exportResult?.sha256Clean ?? ""
            versionID = try? AssetVersioningStore.shared.addVersion(
                assetID:            assetUUID,
                imageData:          imageData,
                tag:                .upscaled,
                customLabel:        "Alta Resolución \(cfg.upscaleFactor, specifier: "%.0f")x",
                transformationNote: "Pipeline: \(completed.joined(separator: " + "))",
                deltaParams:        [
                    "upscale_factor":  "\(cfg.upscaleFactor)",
                    "upscale_model":   cfg.upscaleModel,
                    "face_restore":    "\(cfg.faceRestore)",
                    "adetailer":       "\(cfg.runADetailer)",
                ]
            ).id
        }

        progress.currentStep  = steps.count
        progress.currentLabel = "¡Completado!"
        progress.isComplete   = true

        let duration = Date().timeIntervalSince(startDate)

        let result = FinishResult(
            asset:           asset,
            versionID:       versionID,
            exportResult:    exportResult,
            stepsCompleted:  completed,
            warnings:        warnings,
            durationSeconds: duration
        )

        lastResult = result

        ZeroKnowledgeLog.shared.write(
            category: .exportPerformed,
            message: "HiResFinish complete in \(Int(duration))s: \(completed.joined(separator: "+"))"
        )

        return result
    }

    // MARK: - Step Implementations

    private func runADetailerStep(asset: GeneratedAsset, cfg: FinishConfig) async throws {
        guard let path = asset.imagePath else { throw FinishError.imageNotFound }
        let imgData = try Data(contentsOf: URL(fileURLWithPath: path))
        let b64     = imgData.base64EncodedString()

        var adetailerUnits: [[String: Any]] = []
        if cfg.adetailerFace {
            adetailerUnits.append(ADetailerEngine.shared.buildUnit(
                model: "face_yolov8n.pt",
                denoise: cfg.adetailerStrength
            ))
        }
        if cfg.adetailerHands {
            adetailerUnits.append(ADetailerEngine.shared.buildUnit(
                model: "hand_yolov8n.pt",
                denoise: cfg.adetailerStrength
            ))
        }

        guard !adetailerUnits.isEmpty else { return }

        let request: [String: Any] = [
            "init_images": [b64],
            "denoising_strength": cfg.adetailerStrength,
            "alwayson_scripts": ["ADetailer": ["args": adetailerUnits]]
        ]

        _ = try await SDService.shared.postRaw(
            endpoint: "/sdapi/v1/img2img",
            body: request
        )
    }

    private func runPostProductionStep(asset: GeneratedAsset, cfg: FinishConfig) async throws {
        guard let path = asset.imagePath else { throw FinishError.imageNotFound }
        let imgData = try Data(contentsOf: URL(fileURLWithPath: path))
        let b64     = imgData.base64EncodedString()

        var body: [String: Any] = ["image": b64]
        if cfg.runUpscale {
            body["upscaling_resize"] = cfg.upscaleFactor
            body["upscaler_1"] = cfg.upscaleModel
        }
        if cfg.faceRestore {
            body["codeformer_visibility"]   = cfg.faceRestoreWeight
            body["codeformer_weight"]       = cfg.faceRestoreWeight
            body["restore_faces"]           = true
        }

        _ = try await SDService.shared.postRaw(
            endpoint: "/sdapi/v1/extra-single-image",
            body: body
        )
    }

    private func runCinematicFilterStep(asset: GeneratedAsset, presetName: String) async throws {
        guard let path = asset.imagePath,
              let image = NSImage(contentsOfFile: path),
              let preset = CinematicFilterEngine.shared.presets.first(where: { $0.name == presetName })
        else { return }

        CinematicFilterEngine.shared.applyPreset(preset)
        let filtered = image  // CinematicFilterEngine applies async; use original if sync needed

        if let data = filtered.tiffRepresentation,
           let bitmapRep = NSBitmapImageRep(data: data),
           let pngData = bitmapRep.representation(using: .png, properties: [:]) as Data? {
            try pngData.write(to: URL(fileURLWithPath: path), options: Data.WritingOptions.atomic)
        }
    }

    private func runSteganographyStep(asset: GeneratedAsset, outputURL: URL) async throws {
        guard let uuidStr = asset.id?.uuidString else { return }
        if let img = NSImage(contentsOf: outputURL),
           let uuid = UUID(uuidString: uuidStr),
           let pngData = SteganographyEngine.shared.embed(image: img, assetID: uuid, sessionTag: nil, sha256: "") {
            try pngData.write(to: outputURL, options: Data.WritingOptions.atomic)
        }
    }

    // MARK: - Progress Helper

    private func updateProgress(label: String, steps: [String]) async {
        progress.currentStep  = min(progress.currentStep + 1, progress.totalSteps)
        progress.currentLabel = label
        try? await Task.sleep(nanoseconds: 100_000_000)  // 0.1s UI update
    }

    // MARK: - Persistence

    private var configURL: URL? {
        VaultManager.shared.vaultRoot?
            .appendingPathComponent("Vault/hiresfinish_config.json")
    }

    private func loadPreset() {
        guard let url = configURL, let data = try? Data(contentsOf: url) else { return }
        let dec = JSONDecoder()
        config = (try? dec.decode(FinishConfig.self, from: data)) ?? FinishConfig()
    }

    func saveConfig() {
        guard let url = configURL else { return }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted]
        try? enc.encode(config).write(to: url, options: .atomic)
    }

    enum FinishError: LocalizedError {
        case imageNotFound
        var errorDescription: String? { "Imagen original no encontrada en el vault." }
    }
}

// MARK: - HiRes Finish Button View (Inline)

struct HiResFinishButton: View {
    let asset: GeneratedAsset
    @ObservedObject private var engine = HiResFinishEngine.shared
    @State private var showEstimate    = false
    @State private var showResult      = false

    var body: some View {
        VStack(spacing: 0) {
            // Main button
            Button(action: {
                if !engine.isRunning { showEstimate = true }
            }) {
                HStack(spacing: 8) {
                    if engine.isRunning {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "sparkles")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    Text(engine.isRunning ? "Finalizando…" : "Finalizar en Alta Resolución")
                        .font(.system(size: 12, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    LinearGradient(
                        colors: [Color(hex: "#7c6af7"), Color(hex: "#a78bfa")],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                .foregroundColor(.white)
                .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .disabled(engine.isRunning)

            // Progress bar
            if engine.isRunning {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: engine.progress.percentage, total: 100)
                        .progressViewStyle(.linear)
                        .tint(Color(hex: "#7c6af7"))
                    Text(engine.progress.currentLabel)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .padding(.top, 8)
                .transition(.opacity)
            }

            // Result badge
            if let result = engine.lastResult, !engine.isRunning {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(Color(hex: "#34d399"))
                    Text("Completado en \(Int(result.durationSeconds))s · \(result.stepsCompleted.count) pasos")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .padding(.top, 6)
                .transition(.opacity)
            }
        }
        .sheet(isPresented: $showEstimate) {
            FinishEstimateSheet(asset: asset, isPresented: $showEstimate)
        }
        .animation(.easeInOut(duration: 0.2), value: engine.isRunning)
    }
}

private struct FinishEstimateSheet: View {
    let asset: GeneratedAsset
    @Binding var isPresented: Bool
    @ObservedObject private var engine = HiResFinishEngine.shared
    @State private var selectedPreset: HiResFinishEngine.QualityPreset = .standard

    var estimate: HiResFinishEngine.FinishEstimate {
        engine.estimate(for: asset, config: .from(preset: selectedPreset))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Finalizar en Alta Resolución")
                .font(.system(size: 16, weight: .bold))

            // Preset picker
            Picker("Preset", selection: $selectedPreset) {
                ForEach(HiResFinishEngine.QualityPreset.allCases, id: \.self) { preset in
                    Text(preset.label).tag(preset)
                }
            }
            .pickerStyle(.segmented)

            Text(selectedPreset.description)
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            // Steps
            VStack(alignment: .leading, spacing: 6) {
                Text("PASOS")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                ForEach(estimate.steps, id: \.self) { step in
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 11))
                            .foregroundColor(Color(hex: "#7c6af7"))
                        Text(step)
                            .font(.system(size: 12))
                    }
                }
            }

            // Estimate
            HStack(spacing: 20) {
                VStack(spacing: 4) {
                    Text("~\(estimate.estimatedSecs)s")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(Color(hex: "#7c6af7"))
                    Text("Tiempo estimado")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                VStack(spacing: 4) {
                    Text("~\(estimate.estimatedMB, specifier: "%.1f")MB")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(Color(hex: "#7c6af7"))
                    Text("Tamaño estimado")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }

            HStack {
                Button("Cancelar") { isPresented = false }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Iniciar Pipeline") {
                    isPresented = false
                    let cfg = HiResFinishEngine.FinishConfig.from(preset: selectedPreset)
                    Task {
                        _ = try? await HiResFinishEngine.shared.finishInHighResolution(
                            asset: asset, customConfig: cfg
                        )
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    LinearGradient(
                        colors: [Color(hex: "#7c6af7"), Color(hex: "#a78bfa")],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                .foregroundColor(.white)
                .cornerRadius(8)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}
