import Foundation
import AppKit
import SwiftUI
import Combine

// MARK: - ICLightEngine
//
// Motor de relight cinemático usando IC-Light (Illumination-Conditioned Light).
// IC-Light permite re-iluminar imágenes generadas manteniendo la identidad del sujeto.

@MainActor
final class ICLightEngine: ObservableObject {

    static let shared = ICLightEngine()
    private init() { loadPresets() }

    // MARK: - Models

    enum ICLightMode: String, CaseIterable, Codable {
        case fc  = "FC"   // Foreground Conditioned
        case fbc = "FBC"  // Foreground + Background Conditioned

        var displayName: String {
            switch self {
            case .fc:  return "Sujeto + luz (FC)"
            case .fbc: return "Sujeto + fondo + luz (FBC)"
            }
        }

        var description: String {
            switch self {
            case .fc:  return "Re-ilumina el sujeto usando solo un prompt de luz. Ideal para retratos."
            case .fbc: return "Integra sujeto con nuevo fondo bajo iluminación coherente."
            }
        }
    }

    enum LightingDirection: String, CaseIterable, Codable {
        case front    = "front"
        case back     = "back"
        case left     = "left"
        case right    = "right"
        case top      = "top"
        case dramatic = "dramatic"
        case rembrandt = "rembrandt"
        case butterfly = "butterfly"
        case loop     = "loop"

        var displayName: String { rawValue.capitalized }

        var prompt: String {
            switch self {
            case .front:     return "soft front lighting, beauty light, even illumination"
            case .back:      return "dramatic backlight, rim lighting, silhouette, contre-jour"
            case .left:      return "side lighting from left, Rembrandt shadow on right side"
            case .right:     return "side lighting from right, Rembrandt shadow on left side"
            case .top:       return "top lighting, overhead light, butterfly shadow under nose"
            case .dramatic:  return "dramatic chiaroscuro lighting, strong shadows, high contrast"
            case .rembrandt: return "Rembrandt lighting, triangular highlight on cheek, deep shadow"
            case .butterfly: return "butterfly lighting, glamour light, centered top soft light"
            case .loop:      return "loop lighting, 45 degree angle, small shadow under nose"
            }
        }

        var icon: String {
            switch self {
            case .front:     return "sun.max.fill"
            case .back:      return "sun.and.horizon.fill"
            case .left:      return "arrow.left.circle.fill"
            case .right:     return "arrow.right.circle.fill"
            case .top:       return "arrow.up.circle.fill"
            case .dramatic:  return "moon.fill"
            case .rembrandt: return "paintpalette.fill"
            case .butterfly: return "sparkles"
            case .loop:      return "circle.lefthalf.striped.horizontal.fill"
            }
        }
    }

    // MARK: - Configuration

    struct ICLightConfig: Codable {
        var enabled:          Bool              = false
        var mode:             ICLightMode       = .fc
        var direction:        LightingDirection = .front
        var lightPrompt:      String            = ""
        var backgroundImage:  String?           = nil
        var strength:         Double            = 0.7
        var denoisingStrength: Double           = 0.35
        var removeBg:         Bool              = true
        var steps:            Int               = 28
        var cfg:              Double            = 2.0
        var useHighRes:       Bool              = false
        var hiResScale:       Double            = 1.5
        var sampler:          String            = "DPM++ 2M Karras"
        var seed:             Int               = -1
    }

    // MARK: - Presets

    struct LightingPreset: Identifiable, Codable {
        let id:          UUID            = UUID()
        var name:        String
        var mode:        ICLightMode
        var direction:   LightingDirection
        var lightPrompt: String
        var strength:    Double
        var tags:        [String]        = []
        var isBuiltIn:   Bool            = true
    }

    // MARK: - State

    @Published var config:       ICLightConfig    = ICLightConfig()
    @Published var presets:      [LightingPreset] = []
    @Published var isProcessing: Bool             = false
    @Published var progress:     Double           = 0
    @Published var progressText: String           = ""
    @Published var lastResult:   NSImage?         = nil
    @Published var lastError:    String?          = nil
    @Published var isInstalled:  Bool             = false

    // MARK: - Process

    func relight(image: NSImage, config: ICLightConfig? = nil) async throws -> NSImage {
        let cfg = config ?? self.config
        isProcessing = true
        progress     = 0
        progressText = "Preparando relight…"
        defer { isProcessing = false }

        if isInstalled {
            return try await relightViaICLight(image: image, cfg: cfg)
        } else {
            return try await relightViaImg2Img(image: image, cfg: cfg)
        }
    }

    private func relightViaICLight(image: NSImage, cfg: ICLightConfig) async throws -> NSImage {
        guard let base64 = imageToBase64(image) else {
            throw ICLightError.imageConversionFailed
        }

        progress     = 0.2
        progressText = "Conectando con IC-Light…"

        let lightPrompt = cfg.lightPrompt.isEmpty
            ? cfg.direction.prompt
            : "\(cfg.direction.prompt), \(cfg.lightPrompt)"

        let payload: [String: Any] = [
            "mode":          cfg.mode.rawValue,
            "foreground":    base64,
            "background":    cfg.backgroundImage.flatMap { imageToBase64URL($0) } ?? NSNull(),
            "light_prompt":  lightPrompt,
            "strength":      cfg.strength,
            "steps":         cfg.steps,
            "cfg":           cfg.cfg,
            "sampler":       cfg.sampler,
            "seed":          cfg.seed,
            "remove_bg":     cfg.removeBg,
        ]

        progress     = 0.4
        progressText = "Procesando…"

        let apiURL   = URL(string: "http://localhost:7861/iclight/relight")!
        var request  = URLRequest(url: apiURL, timeoutInterval: 300)
        request.httpMethod  = "POST"
        request.httpBody    = try? JSONSerialization.data(withJSONObject: payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, _)   = try await URLSession.shared.data(for: request)
        progress         = 0.85
        progressText     = "Decodificando resultado…"

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resultB64 = json["result"] as? String,
              let imageData = Data(base64Encoded: resultB64),
              let result    = NSImage(data: imageData)
        else {
            throw ICLightError.invalidResponse
        }

        progress     = 1.0
        progressText = "Relight completado ✓"
        lastResult   = result
        return result
    }

    private func relightViaImg2Img(image: NSImage, cfg: ICLightConfig) async throws -> NSImage {
        progress     = 0.1
        progressText = "IC-Light no instalado. Usando img2img como fallback…"

        guard let base64 = imageToBase64(image) else {
            throw ICLightError.imageConversionFailed
        }

        let lightPrompt = cfg.direction.prompt + (cfg.lightPrompt.isEmpty ? "" : ", \(cfg.lightPrompt)")
        let negPrompt   = "flat lighting, uniform lighting, no shadows, overexposed"

        let payload: [String: Any] = [
            "init_images":        [base64],
            "prompt":             "professional photography, \(lightPrompt), high quality",
            "negative_prompt":    negPrompt,
            "denoising_strength": cfg.denoisingStrength,
            "steps":              cfg.steps,
            "cfg_scale":          7.5,
            "sampler_name":       "DPM++ 2M Karras",
            "seed":               cfg.seed,
            "width":              image.size.width > 0 ? Int(image.size.width) : 512,
            "height":             image.size.height > 0 ? Int(image.size.height) : 768,
        ]

        progress     = 0.4
        progressText = "Enviando a img2img…"

        guard let base = SDService.shared.baseURL else { throw ICLightError.sdNotAvailable }
        var req = URLRequest(url: base.appending(path: "sdapi/v1/img2img"), timeoutInterval: 300)
        req.httpMethod = "POST"
        req.httpBody   = try? JSONSerialization.data(withJSONObject: payload)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, _) = try await URLSession.shared.data(for: req)
        progress       = 0.85

        guard let json     = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let images    = json["images"] as? [String],
              let first     = images.first,
              let imageData = Data(base64Encoded: first),
              let result    = NSImage(data: imageData)
        else {
            throw ICLightError.invalidResponse
        }

        progress     = 1.0
        progressText = "Relight (fallback) completado ✓"
        lastResult   = result
        return result
    }

    // MARK: - Check Installation

    func checkInstallation() async {
        guard let base = URL(string: "http://localhost:7861/iclight/ping") else { return }
        if let (_, resp) = try? await URLSession.shared.data(from: base),
           let http = resp as? HTTPURLResponse, http.statusCode == 200 {
            isInstalled = true
        } else {
            isInstalled = false
        }
    }

    // MARK: - Presets

    private func loadPresets() {
        presets = Self.builtInPresets
        if let url  = VaultManager.shared.vaultMetaURL?.appending(path: "iclight_presets.json"),
           let data = try? Data(contentsOf: url),
           let list = try? JSONDecoder().decode([LightingPreset].self, from: data) {
            let userPresets = list.filter { !$0.isBuiltIn }
            presets = Self.builtInPresets + userPresets
        }
    }

    func savePreset(name: String) {
        let preset = LightingPreset(
            name:        name,
            mode:        config.mode,
            direction:   config.direction,
            lightPrompt: config.lightPrompt,
            strength:    config.strength,
            isBuiltIn:   false
        )
        presets.append(preset)

        if let url  = VaultManager.shared.vaultMetaURL?.appending(path: "iclight_presets.json"),
           let data = try? JSONEncoder().encode(presets.filter { !$0.isBuiltIn }) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func applyPreset(_ preset: LightingPreset) {
        config.mode        = preset.mode
        config.direction   = preset.direction
        config.lightPrompt = preset.lightPrompt
        config.strength    = preset.strength
    }

    static let builtInPresets: [LightingPreset] = [
        LightingPreset(name: "Golden Hour", mode: .fc, direction: .back,
                       lightPrompt: "warm golden sunset, god rays, orange glow", strength: 0.75,
                       tags: ["sunset", "warm", "outdoor"]),
        LightingPreset(name: "Studio Portrait", mode: .fc, direction: .butterfly,
                       lightPrompt: "studio softbox, beauty dish, clean background", strength: 0.65,
                       tags: ["studio", "portrait", "clean"]),
        LightingPreset(name: "Chiaroscuro", mode: .fc, direction: .dramatic,
                       lightPrompt: "dramatic chiaroscuro, Renaissance painting light, deep black shadows", strength: 0.8,
                       tags: ["artistic", "dramatic", "dark"]),
        LightingPreset(name: "Neon Night", mode: .fbc, direction: .front,
                       lightPrompt: "neon lights, cyberpunk city at night, pink and blue neon glow", strength: 0.7,
                       tags: ["neon", "cyberpunk", "night"]),
        LightingPreset(name: "Rembrandt", mode: .fc, direction: .rembrandt,
                       lightPrompt: "Rembrandt lighting, old master painting, triangular face highlight", strength: 0.7,
                       tags: ["rembrandt", "artistic", "portrait"]),
        LightingPreset(name: "Natural Outdoor", mode: .fbc, direction: .front,
                       lightPrompt: "natural sunlight, blue sky, soft outdoor shadows", strength: 0.55,
                       tags: ["outdoor", "natural", "daylight"]),
    ]

    // MARK: - Helpers

    private func imageToBase64(_ image: NSImage) -> String? {
        guard let data = image.pngData() else { return nil }
        return data.base64EncodedString()
    }

    private func imageToBase64URL(_ path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return data.base64EncodedString()
    }

    // MARK: - Errors

    enum ICLightError: LocalizedError {
        case imageConversionFailed
        case sdNotAvailable
        case invalidResponse
        case processingFailed(String)

        var errorDescription: String? {
            switch self {
            case .imageConversionFailed: return "No se pudo convertir la imagen."
            case .sdNotAvailable:        return "Stable Diffusion no disponible."
            case .invalidResponse:       return "Respuesta inválida de IC-Light."
            case .processingFailed(let m): return "Error de procesamiento: \(m)"
            }
        }
    }
}
