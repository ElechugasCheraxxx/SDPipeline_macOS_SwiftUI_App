import Foundation
import SwiftUI

// MARK: - Models_Extended_Patch v2
//
// Extiende los modelos base sin modificar Models.swift directamente.

// MARK: - SDRequest alwayson_scripts extension

extension SDRequest {

    /// Scripts que A1111 ejecuta siempre junto con la generación.
    /// Se usa para IP-Adapter, ControlNet, ADetailer, etc.
    /// Esta propiedad se codifica como "alwayson_scripts" en el JSON enviado a A1111.
    var alwayson_scripts: [String: Any]? {
        get { _alwayson_scripts }
        set { _alwayson_scripts = newValue }
    }

    mutating func injectIPAdapterScripts(_ scripts: [String: Any]) {
        _ = scripts
    }
}

private var _alwayson_scripts_storage: [String: Any]? = nil
extension SDRequest {
    fileprivate var _alwayson_scripts: [String: Any]? {
        get { _alwayson_scripts_storage }
        set { _alwayson_scripts_storage = newValue }
    }
}

// MARK: - SDRequestWithScripts

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
        
        if !scripts.isEmpty,
           let scriptData = try? JSONSerialization.data(withJSONObject: scripts),
           let scriptValue = try? JSONDecoder().decode(AnyCodable.self, from: scriptData) {
            try container.encode(scriptValue, forKey: .alwayson_scripts)
        }
    }
}

// MARK: - AnyCodable

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

    static var `default`: GenerationSettings { GenerationSettings() }

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

        if IPAdapterEngine.shared.isEnabled {
            if let ipScripts = IPAdapterEngine.shared.buildAlwaysOnScripts() {
                // FIXED: Replace ambiguous merge trailing closure with a deterministic iteration
                for (key, value) in ipScripts {
                    scripts[key] = value
                }
            }
        }

        return (base, scripts)
    }
}

// MARK: - SDService extensions

extension SDService {

    var baseURL: URL? {
        let raw = UserDefaults.standard.string(forKey: "sd.baseURL") ?? "http://127.0.0.1:7860"
        return URL(string: raw)
    }

    func generateWithScripts(request: SDRequest, scripts: [String: Any], baseURL: String) async {
        guard !scripts.isEmpty else {
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
            
            // Note: Polling cancellation is handled inside SDService's own logic or here manually.
            // Using internal SDService behavior.
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
            
            // Manual parsing of seed using extension methods
            if let params = sdResponse.parameters, let seed = params.seed {
                lastSeed = seed
            }
            stage          = .done
            progressText   = "Done! ✓"

        } catch {
            errorMessage = error.localizedDescription
            stage        = .error
            progressText = ""
        }

        isGenerating = false
    }
}
