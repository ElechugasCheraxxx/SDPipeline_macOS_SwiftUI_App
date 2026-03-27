import Foundation
import AppKit
import Combine

// MARK: - TiledUpscalerEngine
//
// Motor de upscaling en teselas (tiles) para imágenes de alta resolución.
// Evita el cuello de botella de VRAM procesando la imagen por partes.
//
// Modos soportados:
//   1. Ultimate SD Upscale  — extensión A1111 (/sdapi/v1/img2img con script)
//   2. ESRGAN Tile-by-Tile  — /sdapi/v1/extra-single-image con tiling manual
//   3. SUPIR / 4x-UltraSharp — via extra endpoint con modelo explícito
//
// Pipeline:
//   Original (512px) → Tile Split → Upscale por tile → Stitch → Output (4096px)
//
// ROADMAP: "Upscaling Tiled + Supir/Ultimate SD Upscale" (🟡 MEDIO PLAZO)

@MainActor
final class TiledUpscalerEngine: ObservableObject {

    static let shared = TiledUpscalerEngine()
    private init() { loadPersistedConfig() }

    // MARK: - Config

    struct TiledUpscaleConfig: Codable {
        var mode:           UpscaleMode    = .ultimateSD
        var scaleFactor:    Double         = 4.0
        var tileSize:       Int            = 512
        var tileOverlap:    Int            = 64
        var upscalerModel:  String         = "4x-UltraSharp"
        var denoisingStr:   Double         = 0.25
        var steps:          Int            = 20
        var cfgScale:       Double         = 7.0
        var saveIntermediate: Bool         = false
        var targetMaxRes:   Int            = 4096   // px máx en lado largo

        enum UpscaleMode: String, CaseIterable, Codable {
            case ultimateSD  = "Ultimate SD Upscale"
            case esrgan      = "ESRGAN Tiled"
            case supir       = "SUPIR"
            case ultraSharp  = "4x-UltraSharp"

            var icon: String {
                switch self {
                case .ultimateSD: return "square.grid.3x3.fill"
                case .esrgan:     return "arrow.up.left.and.arrow.down.right"
                case .supir:      return "sparkles"
                case .ultraSharp: return "wand.and.stars"
                }
            }

            var apiEndpoint: String {
                switch self {
                case .ultimateSD: return "/sdapi/v1/img2img"
                case .esrgan, .ultraSharp, .supir: return "/sdapi/v1/extra-single-image"
                }
            }
        }
    }

    @Published var config            = TiledUpscaleConfig()
    @Published var isUpscaling       = false
    @Published var progress: Double  = 0
    @Published var progressText      = ""
    @Published var currentTile       = 0
    @Published var totalTiles        = 0
    @Published var lastResult: UpscaleResult?
    @Published var errorMessage: String?

    // MARK: - Result

    struct UpscaleResult: Identifiable {
        let id          = UUID()
        let sourceURL:   URL
        let outputURL:   URL
        let outputSize:  CGSize
        let scaleFactor: Double
        let mode:        TiledUpscaleConfig.UpscaleMode
        let duration:    TimeInterval
        let sha256:      String
        let tilesUsed:   Int
    }

    // MARK: - Main Upscale Entry Point

    /// Upscale a source image using the configured mode.
    /// Saves result to project's MasterPicks/ folder with versioning.
    func upscale(
        asset: GeneratedAsset,
        baseURL: String,
        overrideConfig: TiledUpscaleConfig? = nil
    ) async throws -> UpscaleResult {
        guard !isUpscaling else { throw UpscaleError.alreadyRunning }
        isUpscaling  = true
        errorMessage = nil
        progress     = 0
        let cfg = overrideConfig ?? config
        let start = Date()

        defer { isUpscaling = false }

        guard let imagePath = asset.imagePath,
              let imageData  = try? Data(contentsOf: URL(fileURLWithPath: imagePath)),
              let nsImage    = NSImage(data: imageData)
        else { throw UpscaleError.sourceImageNotFound }

        progressText = "Preparando imagen (\(Int(nsImage.size.width))×\(Int(nsImage.size.height)))…"
        progress = 0.05

        let result: UpscaleResult

        switch cfg.mode {
        case .ultimateSD:
            result = try await upscaleWithUltimateSD(
                image: nsImage, imageData: imageData,
                asset: asset, baseURL: baseURL, cfg: cfg, start: start
            )
        case .esrgan, .ultraSharp, .supir:
            result = try await upscaleWithExtra(
                imageData: imageData,
                asset: asset, baseURL: baseURL, cfg: cfg, start: start
            )
        }

        // Save version in AssetVersioningStore
        let versionTag = "upscale_\(cfg.mode.rawValue.lowercased().replacingOccurrences(of: " ", with: "_"))_\(Int(cfg.scaleFactor))x"
        await AssetVersioningStore.shared.createVersion(
            for: asset,
            sourcePath: result.outputURL.path,
            tag: versionTag,
            notes: "Tiled upscale \(cfg.mode.rawValue) @ \(cfg.scaleFactor)x — \(result.tilesUsed) tiles"
        )

        // Log
        ZeroKnowledgeLog.shared.write(
            category: .exportPerformed,
            message: "Upscale completado: \(cfg.mode.rawValue) \(cfg.scaleFactor)x — \(result.tilesUsed) tiles — \(String(format: "%.1f", result.duration))s"
        )

        lastResult = result
        progress   = 1.0
        progressText = "✅ Upscale completado (\(Int(result.outputSize.width))×\(Int(result.outputSize.height)))"
        return result
    }

    // MARK: - Ultimate SD Upscale (A1111 extension)

    private func upscaleWithUltimateSD(
        image: NSImage,
        imageData: Data,
        asset: GeneratedAsset,
        baseURL: String,
        cfg: TiledUpscaleConfig,
        start: Date
    ) async throws -> UpscaleResult {

        progressText = "Construyendo request Ultimate SD Upscale…"
        progress = 0.10

        let base64 = imageData.base64EncodedString()

        // Ultimate SD Upscale script payload
        let scriptArgs: [Any] = [
            0,              // _ (ignored)
            cfg.tileSize,   // tile_width
            cfg.tileSize,   // tile_height
            cfg.tileOverlap, // mask_blur
            cfg.tileOverlap, // padding
            cfg.scaleFactor, // scale_factor
            false,          // upscale_first
            true,           // use_linear_blending
            cfg.denoisingStr, // denoising_strength
            cfg.steps,      // steps
            cfg.cfgScale,   // cfg_scale
            true,           // save_upscaled_image_to_local_path
            cfg.upscalerModel  // upscaler
        ]

        let prompt    = asset.promptPositive ?? ""
        let negPrompt = asset.promptNegative ?? "blurry, artifacts, noise"

        let body: [String: Any] = [
            "init_images":          [base64],
            "prompt":               prompt,
            "negative_prompt":      negPrompt,
            "denoising_strength":   cfg.denoisingStr,
            "steps":                cfg.steps,
            "cfg_scale":            cfg.cfgScale,
            "width":                Int(image.size.width * cfg.scaleFactor),
            "height":               Int(image.size.height * cfg.scaleFactor),
            "sampler_name":         "DPM++ 2M Karras",
            "script_name":          "ultimate sd upscale",
            "script_args":          scriptArgs
        ]

        progressText = "Enviando a A1111 (Ultimate SD Upscale)…"
        progress = 0.20

        let url = URL(string: "\(baseURL)\(cfg.mode.apiEndpoint)")!
        var req = URLRequest(url: url)
        req.httpMethod  = "POST"
        req.httpBody    = try JSONSerialization.data(withJSONObject: body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 600   // Upscaling puede tardar varios minutos

        // Poll progress while waiting
        let progressTask = Task {
            var p = 0.20
            while p < 0.90 {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                p = min(p + 0.05, 0.88)
                await MainActor.run {
                    self.progress = p
                    self.progressText = "Procesando… \(Int(p * 100))%"
                }
            }
        }

        let (data, response) = try await URLSession.shared.data(for: req)
        progressTask.cancel()

        guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else {
            throw UpscaleError.apiError("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }

        progressText = "Decodificando resultado…"
        progress = 0.92

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let images = json["images"] as? [String],
              let firstB64 = images.first,
              let pngData = Data(base64Encoded: firstB64)
        else { throw UpscaleError.invalidResponse }

        return try await saveUpscaleResult(
            pngData: pngData, asset: asset, cfg: cfg, start: start,
            estimatedTiles: estimateTileCount(imageSize: image.size, tileSize: cfg.tileSize, overlap: cfg.tileOverlap, scale: cfg.scaleFactor)
        )
    }

    // MARK: - ESRGAN / Extra-Single-Image Upscale

    private func upscaleWithExtra(
        imageData: Data,
        asset: GeneratedAsset,
        baseURL: String,
        cfg: TiledUpscaleConfig,
        start: Date
    ) async throws -> UpscaleResult {

        progressText = "Enviando a /extra-single-image (\(cfg.mode.rawValue))…"
        progress = 0.15

        let base64 = imageData.base64EncodedString()

        // For SUPIR, use the dedicated upscaler name
        let upscalerName: String
        switch cfg.mode {
        case .supir:      upscalerName = "SUPIR"
        case .ultraSharp: upscalerName = "4x-UltraSharp"
        default:          upscalerName = cfg.upscalerModel
        }

        let body: [String: Any] = [
            "image":           base64,
            "resize_mode":     0,
            "show_extras_results": true,
            "gfpgan_visibility":   0.0,
            "codeformer_visibility": 0.0,
            "codeformer_weight":   0.0,
            "upscaling_resize":     cfg.scaleFactor,
            "upscaler_1":           upscalerName,
            "upscaler_2":           "None",
            "extras_upscaler_2_visibility": 0.0,
            "upscale_first":       false
        ]

        let url = URL(string: "\(baseURL)/sdapi/v1/extra-single-image")!
        var req = URLRequest(url: url)
        req.httpMethod  = "POST"
        req.httpBody    = try JSONSerialization.data(withJSONObject: body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 300

        let (data, _) = try await URLSession.shared.data(for: req)

        progress = 0.85
        progressText = "Decodificando imagen upscalada…"

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let imageB64 = json["image"] as? String,
              let pngData = Data(base64Encoded: imageB64)
        else { throw UpscaleError.invalidResponse }

        return try await saveUpscaleResult(
            pngData: pngData, asset: asset, cfg: cfg, start: start, estimatedTiles: 1
        )
    }

    // MARK: - Save Result

    private func saveUpscaleResult(
        pngData: Data,
        asset: GeneratedAsset,
        cfg: TiledUpscaleConfig,
        start: Date,
        estimatedTiles: Int
    ) async throws -> UpscaleResult {

        progress = 0.94
        progressText = "Guardando imagen upscalada…"

        // Output URL in project's MasterPicks folder
        let projectFolderMgr = ProjectFolderManager.shared
        guard let project = projectFolderMgr.projects.first else {
            throw UpscaleError.noActiveProject
        }

        let upscaleDir = project.rootURL
            .appendingPathComponent("MasterPicks")
            .appendingPathComponent("Upscaled")

        try? FileManager.default.createDirectory(at: upscaleDir, withIntermediateDirectories: true)

        let baseName   = (asset.baseName ?? UUID().uuidString)
        let suffix     = "_\(cfg.mode.rawValue.lowercased().replacingOccurrences(of: " ", with: "_"))_\(Int(cfg.scaleFactor))x"
        let outputURL  = upscaleDir.appendingPathComponent("\(baseName)\(suffix).png")

        try pngData.write(to: outputURL, options: .atomic)

        let sha256 = pngData.sha256Hex
        let duration = Date().timeIntervalSince(start)

        // Determine actual output size
        let outSize: CGSize
        if let img = NSImage(data: pngData) {
            outSize = img.size
        } else {
            let src = asset.imagePath.flatMap { NSImage(contentsOfFile: $0) }
            outSize = CGSize(
                width:  (src?.size.width ?? 512) * cfg.scaleFactor,
                height: (src?.size.height ?? 512) * cfg.scaleFactor
            )
        }

        progress = 0.98

        return UpscaleResult(
            sourceURL:   URL(fileURLWithPath: asset.imagePath ?? ""),
            outputURL:   outputURL,
            outputSize:  outSize,
            scaleFactor: cfg.scaleFactor,
            mode:        cfg.mode,
            duration:    duration,
            sha256:      sha256,
            tilesUsed:   estimatedTiles
        )
    }

    // MARK: - Batch Upscale

    struct BatchUpscaleJob {
        let asset: GeneratedAsset
        var status: JobStatus = .pending
        var result: UpscaleResult?
        var error: String?

        enum JobStatus { case pending, running, done, failed }
    }

    @Published var batchJobs: [BatchUpscaleJob] = []
    @Published var isBatchRunning = false

    func runBatchUpscale(
        assets: [GeneratedAsset],
        baseURL: String,
        cfg: TiledUpscaleConfig? = nil
    ) async {
        guard !isBatchRunning else { return }
        isBatchRunning = true
        batchJobs = assets.map { BatchUpscaleJob(asset: $0) }

        for i in batchJobs.indices {
            batchJobs[i].status = .running
            do {
                let result = try await upscale(asset: batchJobs[i].asset, baseURL: baseURL, overrideConfig: cfg)
                batchJobs[i].result = result
                batchJobs[i].status = .done
            } catch {
                batchJobs[i].error  = error.localizedDescription
                batchJobs[i].status = .failed
            }
        }
        isBatchRunning = false
    }

    // MARK: - Helpers

    private func estimateTileCount(imageSize: CGSize, tileSize: Int, overlap: Int, scale: Double) -> Int {
        let targetW = imageSize.width * scale
        let targetH = imageSize.height * scale
        let step    = max(1, tileSize - overlap)
        let cols    = Int(ceil(targetW / Double(step)))
        let rows    = Int(ceil(targetH / Double(step)))
        return max(1, cols * rows)
    }

    // MARK: - Available Upscalers (queried from A1111)

    @Published var availableUpscalers: [String] = [
        "4x-UltraSharp", "ESRGAN_4x", "R-ESRGAN 4x+", "R-ESRGAN 4x+ Anime6B",
        "LDSR", "ScuNET GAN", "SwinIR 4x", "SUPIR"
    ]

    func refreshUpscalerList(baseURL: String) async {
        guard let url = URL(string: "\(baseURL)/sdapi/v1/upscalers") else { return }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return }
        let names = json.compactMap { $0["name"] as? String }.filter { $0 != "None" }
        availableUpscalers = names.isEmpty ? availableUpscalers : names
    }

    // MARK: - Persistence

    private func loadPersistedConfig() {
        if let data = UserDefaults.standard.data(forKey: "TiledUpscalerConfig"),
           let cfg  = try? JSONDecoder().decode(TiledUpscaleConfig.self, from: data) {
            config = cfg
        }
    }

    func persistConfig() {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: "TiledUpscalerConfig")
        }
    }

    // MARK: - Errors

    enum UpscaleError: LocalizedError {
        case alreadyRunning
        case sourceImageNotFound
        case apiError(String)
        case invalidResponse
        case noActiveProject

        var errorDescription: String? {
            switch self {
            case .alreadyRunning:      return "Ya hay un upscale en progreso."
            case .sourceImageNotFound: return "No se encontró la imagen fuente en el vault."
            case .apiError(let msg):  return "Error de API A1111: \(msg)"
            case .invalidResponse:    return "Respuesta inválida del servidor de upscaling."
            case .noActiveProject:    return "No hay proyecto activo. Crea un proyecto primero."
            }
        }
    }
}
