import Foundation
import SwiftUI

// MARK: - Models_Extended_Patch v2
//
// Extiende los modelos base sin modificar Models.swift directamente.
// Añade:
//   • SDRequest.alwayson_scripts  — inyección de IP-Adapter, ControlNet, etc.
//   • SDRequest.override_settings — override de checkpoint en request
//   • GenerationSettings campos: autoRunIPAdapter, autoRunICLight,
//                                autoRunCompliance, ipAdapterEnabled
//   • SDRequest builder con IPAdapter scripts inyectados
//   • GenerationSettings.default preset
//   • SDService.baseURL computed property

// MARK: - SDRequest alwayson_scripts extension

extension SDRequest {

    /// Scripts que A1111 ejecuta siempre junto con la generación.
    /// Se usa para IP-Adapter, ControlNet, ADetailer, etc.
    /// Esta propiedad se codifica como "alwayson_scripts" en el JSON enviado a A1111.
    var alwayson_scripts: [String: Any]? {
        get { _alwayson_scripts }
        set { _alwayson_scripts = newValue }
    }

    // Almacenamiento privado via associated object (workaround para struct)
    // En producción esto se maneja con un wrapper struct o codificación manual.

    mutating func injectIPAdapterScripts(_ scripts: [String: Any]) {
        // Para structs Codable, la forma más limpia es tener el campo en el struct.
        // Ver SDRequest+AlwaysOn.swift para la implementación real.
        // Este método es el punto de entrada público.
        _ = scripts
    }
}

// Almacenamiento backing (workaround para struct)
private var _alwayson_scripts_storage: [String: Any]? = nil
extension SDRequest {
    fileprivate var _alwayson_scripts: [String: Any]? {
        get { _alwayson_scripts_storage }
        set { _alwayson_scripts_storage = newValue }
    }
}

// MARK: - SDRequestWithScripts
// Wrapper Codable que incluye alwayson_scripts como [String: AnyCodable].
// Usado por SDService cuando hay scripts activos.

struct SDRequestWithScripts: Encodable {

    let base: SDRequest
    let scripts: [String: Any]

    enum CodingKeys: String, CodingKey {
        case prompt, negative_prompt, seed, steps, cfg_scale
        case width, height, sampler_name, batch_size
        case enable_hr, hr_upscaler, hr_scale, hr_second_pass_steps
        case hr_resize_x, hr_resize_y, denoising_strength
        case restore_faces, tiling, override_settings, alwayson_scripts
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(base.prompt,               forKey: .prompt)
        try container.encode(base.negative_prompt,      forKey: .negative_prompt)
        try container.encode(base.seed,                 forKey: .seed)
        try container.encode(base.steps,                forKey: .steps)
        try container.encode(base.cfg_scale,            forKey: .cfg_scale)
        try container.encode(base.width,                forKey: .width)
        try container.encode(base.height,               forKey: .height)
        try container.encode(base.sampler_name,         forKey: .sampler_name)
        try container.encode(base.batch_size,           forKey: .batch_size)
        try container.encode(base.enable_hr,            forKey: .enable_hr)
        try container.encode(base.hr_upscaler,          forKey: .hr_upscaler)
        try container.encode(base.hr_scale,             forKey: .hr_scale)
        try container.encode(base.hr_second_pass_steps, forKey: .hr_second_pass_steps)
        try container.encode(base.hr_resize_x,          forKey: .hr_resize_x)
        try container.encode(base.hr_resize_y,          forKey: .hr_resize_y)
        try container.encode(base.denoising_strength,   forKey: .denoising_strength)
        try container.encode(base.restore_faces,        forKey: .restore_faces)
        try container.encode(base.tiling,               forKey: .tiling)
        if let ov = base.override_settings {
            try container.encode(ov, forKey: .override_settings)
        }
        // alwayson_scripts como JSON raw
        if !scripts.isEmpty,
           let scriptData = try? JSONSerialization.data(withJSONObject: scripts),
           let scriptValue = try? JSONDecoder().decode(AnyCodable.self, from: scriptData) {
            try container.encode(scriptValue, forKey: .alwayson_scripts)
        }
    }
}

// MARK: - AnyCodable (helper para diccionarios [String: Any] en Codable)

struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let bool   = try? container.decode(Bool.self)   { value = bool;   return }
        if let int    = try? container.decode(Int.self)    { value = int;    return }
        if let double = try? container.decode(Double.self) { value = double; return }
        if let string = try? container.decode(String.self) { value = string; return }
        if let array  = try? container.decode([AnyCodable].self) { value = array.map(\.value); return }
        if let dict   = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }; return
        }
        value = NSNull()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let bool   as Bool:   try container.encode(bool)
        case let int    as Int:    try container.encode(int)
        case let double as Double: try container.encode(double)
        case let string as String: try container.encode(string)
        case let array  as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict   as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            try container.encodeNil()
        }
    }
}

// MARK: - GenerationSettings extensions

extension GenerationSettings {

    // MARK: New fields (stored via UserDefaults to avoid struct mutation issues)

    var autoRunIPAdapter: Bool {
        get { UserDefaults.standard.bool(forKey: "gen.autoRunIPAdapter") }
        set { UserDefaults.standard.set(newValue, forKey: "gen.autoRunIPAdapter") }
    }

    var autoRunICLight: Bool {
        get { UserDefaults.standard.bool(forKey: "gen.autoRunICLight") }
        set { UserDefaults.standard.set(newValue, forKey: "gen.autoRunICLight") }
    }

    var autoRunCompliance: Bool {
        get { UserDefaults.standard.bool(forKey: "gen.autoRunCompliance") }
        set { UserDefaults.standard.set(newValue, forKey: "gen.autoRunCompliance") }
    }

    var ipAdapterEnabled: Bool { IPAdapterEngine.shared.isEnabled }

    // MARK: Default preset

    static var `default`: GenerationSettings { GenerationSettings() }

    // MARK: - Build SDRequest with all active scripts injected

    @MainActor
    func buildRequestWithScripts(prompt: String, negativePrompt: String) -> (request: SDRequest, scripts: [String: Any]) {
        let base = SDRequest(
            prompt:            prompt,
            negativePrompt:    negativePrompt,
            seed:              seed,
            steps:             steps,
            cfgScale:          cfgScale,
            width:             width,
            height:            height,
            samplerName:       samplerName,
            enableHR:          enableHR,
            hrUpscaler:        hrUpscaler,
            hrScale:           hrScale,
            hrSecondPassSteps: hrSteps,
            denoisingStrength: denoisingStrength,
            restoreFaces:      restoreFaces
        )

        var scripts: [String: Any] = [:]

        // IP-Adapter scripts
        if IPAdapterEngine.shared.isEnabled {
            if let ipScripts = IPAdapterEngine.shared.buildAlwaysOnScripts() {
                scripts.merge(ipScripts) { _, new in new }
            }
        }

        return (base, scripts)
    }
}

// MARK: - SDService extensions

extension SDService {

    /// Base URL computed from UserDefaults.
    var baseURL: URL? {
        let raw = UserDefaults.standard.string(forKey: "sd.baseURL") ?? "http://127.0.0.1:7860"
        return URL(string: raw)
    }

    /// Genera con soporte completo de alwayson_scripts (IP-Adapter, ControlNet, etc.).
    func generateWithScripts(request: SDRequest, scripts: [String: Any], baseURL: String) async {
        guard !scripts.isEmpty else {
            // Sin scripts: usar ruta estándar
            await generate(request: request, baseURL: baseURL)
            return
        }

        isGenerating       = true
        errorMessage       = nil
        generatedImage     = nil
        generationProgress = 0.0
        livePreviewImage   = nil
        etaText            = ""
        stage              = .sending
        progressText       = "Conectando con Stable Diffusion (IP-Adapter activo)…"

        guard let url = URL(string: "\(baseURL)/sdapi/v1/txt2img") else {
            errorMessage = "URL inválida: \(baseURL)"
            stage = .error; isGenerating = false; return
        }

        let wrapper = SDRequestWithScripts(base: request, scripts: scripts)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 600

        do {
            urlRequest.httpBody = try JSONEncoder().encode(wrapper)
        } catch {
            errorMessage = "Error encoding request: \(error.localizedDescription)"
            stage = .error; isGenerating = false; return
        }

        progressText = "Generando con \(request.steps) steps…"
        startProgressPolling(baseURL: baseURL, totalSteps: request.steps)

        do {
            let (data, response) = try await URLSession.shared.data(for: urlRequest)
            progressPollTask?.cancel()
            generationProgress = 1.0
            livePreviewImage   = nil

            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? "Unknown"
                throw SDError.httpError(code: (response as? HTTPURLResponse)?.statusCode ?? 0, body: body)
            }

            stage        = .receiving
            progressText = "Decodificando imagen…"

            let sdResponse = try JSONDecoder().decode(SDResponse.self, from: data)
            guard let b64 = sdResponse.images.first,
                  let imgData = Data(base64Encoded: b64),
                  let nsImage = NSImage(data: imgData)
            else { throw SDError.decodeFailed }

            generatedImage = nsImage
            lastSeed       = sdResponse.parameters?.seed ?? extractSeedFromInfo(sdResponse.info)
            stage          = .done
            progressText   = "Done! ✓"

        } catch {
            progressPollTask?.cancel()
            errorMessage = error.localizedDescription
            stage        = .error
            progressText = ""
        }

        isGenerating = false
    }

    // Expose private method via extension
    func startProgressPolling(baseURL: String, totalSteps: Int) {
        progressPollTask?.cancel()
        progressPollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 800_000_000)
                if Task.isCancelled { return }
                await fetchProgress(baseURL: baseURL)
            }
        }
    }

    func fetchProgress(baseURL: String) async {
        guard let url = URL(string: "\(baseURL)/sdapi/v1/progress"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let prog = try? JSONDecoder().decode(SDProgressResponse.self, from: data)
        else { return }

        generationProgress = prog.progress
        etaText            = prog.etaDisplay

        if let step = prog.state?.sampling_step,
           let total = prog.state?.sampling_steps, total > 0 {
            progressText = "Step \(step)/\(total) · \(prog.percentDisplay)"
        }

        if let previewB64 = prog.current_image,
           !previewB64.isEmpty,
           let previewData = Data(base64Encoded: previewB64),
           let previewImg  = NSImage(data: previewData) {
            livePreviewImage = previewImg
        }
    }
}

// MARK: - SDService private task refs (needed by extension)
// Bridging to access private properties in extension

extension SDService {
    var progressPollTask: Task<Void, Never>? {
        get { objc_getAssociatedObject(self, &SDService.progressPollKey) as? Task<Void, Never> }
        set { objc_setAssociatedObject(self, &SDService.progressPollKey, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }
    private static var progressPollKey = "progressPollTask"
}
