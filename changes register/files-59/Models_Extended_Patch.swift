import Foundation
import SwiftUI

// MARK: - Models_Extended_Patch v5
//
// Cambios v4 → v5:
//   🐛 FIX: ControlNet y IP-Adapter ya no usan alwayson_scripts — A1111 no los registra ahí.
//           Ahora se enrutan al endpoint /controlnet/txt2img con clave "controlnet_units".
//   🐛 FIX: mergeIPAdapterScripts / mergeControlNetScripts eran no-ops efectivos.
//           Reemplazados por buildControlNetAPIUnit() / buildControlNetAPIUnits().
//   ✨ ADD: SDGenerationPlan — struct de routing que decide qué endpoint usar.
//   ✨ ADD: SDRequestWithControlNet — Encodable para /controlnet/txt2img.
//   ✨ ADD: SDService.generateWithControlNet() — POST a /controlnet/txt2img.
//   ✨ ADD: SDService.generateWithPlan() — entry point unificado.
//   ✨ ADD: ControlNetEngine.buildControlNetAPIUnits() — formato nativo del endpoint.
//   ✨ ADD: IPAdapterEngine.buildControlNetAPIUnit() — idem para IP-Adapter.
//   🔁 UPD: buildRequestWithScripts() → retorna SDGenerationPlan (breaking change intencional).
//   🔁 UPD: mergeIPAdapterScripts / mergeControlNetScripts — no-ops para compatibilidad BatchEngine.

// MARK: - Thread-Safe Scripts Registry

actor SDRequestScriptsRegistry {

    static let shared = SDRequestScriptsRegistry()
    private init() {}

    private var registry: [UUID: [String: Any]] = [:]

    func set(_ scripts: [String: Any], for id: UUID) {
        registry[id] = scripts
    }

    func get(for id: UUID) -> [String: Any]? {
        registry[id]
    }

    func remove(for id: UUID) {
        registry.removeValue(forKey: id)
    }

    func pruneOldEntries(maxCount: Int = 200) {
        guard registry.count > maxCount else { return }
        let toRemove = Array(registry.keys.prefix(registry.count - maxCount / 2))
        toRemove.forEach { registry.removeValue(forKey: $0) }
    }
}

// MARK: - SDGenerationPlan

/// Encapsula el routing de generación: qué endpoint usar y qué payloads enviar.
struct SDGenerationPlan {
    let request:         SDRequest
    let alwaysOnScripts: [String: Any]    // ADetailer, etc. → /sdapi/v1/txt2img alwayson_scripts
    let controlNetUnits: [[String: Any]]  // ControlNet/IP-Adapter → /controlnet/txt2img

    var needsControlNetEndpoint: Bool { !controlNetUnits.isEmpty }
    var hasAlwaysOnScripts:      Bool { !alwaysOnScripts.isEmpty }
    var isPlain:                 Bool { !needsControlNetEndpoint && !hasAlwaysOnScripts }
}

// MARK: - SDRequest: scripts helpers (compatibilidad BatchEngine)

extension SDRequest {

    /// No-op — mantenido para compatibilidad de BatchEngine.
    /// IP-Adapter se enruta vía SDGenerationPlan.controlNetUnits en v5.
    @MainActor
    func mergeIPAdapterScripts(into scripts: inout [String: Any]) {}

    /// No-op — mantenido para compatibilidad de BatchEngine.
    /// ControlNet se enruta vía SDGenerationPlan.controlNetUnits en v5.
    @MainActor
    func mergeControlNetScripts(into scripts: inout [String: Any]) {}

    /// Inyecta scripts de ADetailer en un dict mutable.
    @MainActor
    func mergeADetailerScripts(into scripts: inout [String: Any]) {
        let adScripts = ADetailerEngine.shared.buildAlwaysOnScripts()
        guard !adScripts.isEmpty else { return }
        for (key, value) in adScripts { scripts[key] = value }
    }
}

// MARK: - SDRequestWithScripts (para /sdapi/v1/txt2img + alwayson_scripts)

struct SDRequestWithScripts: Encodable {

    let base:    SDRequest
    let scripts: [String: Any]

    enum CodingKeys: String, CodingKey {
        case prompt, negative_prompt, seed, steps, cfg_scale
        case width, height, sampler_name, batch_size
        case enable_hr, hr_upscaler, hr_scale, hr_second_pass_steps
        case hr_resize_x, hr_resize_y, denoising_strength
        case restore_faces, tiling, override_settings, alwayson_scripts
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(base.prompt,               forKey: .prompt)
        try c.encode(base.negative_prompt,      forKey: .negative_prompt)
        try c.encode(base.seed,                 forKey: .seed)
        try c.encode(base.steps,                forKey: .steps)
        try c.encode(base.cfg_scale,            forKey: .cfg_scale)
        try c.encode(base.width,                forKey: .width)
        try c.encode(base.height,               forKey: .height)
        try c.encode(base.sampler_name,         forKey: .sampler_name)
        try c.encode(base.batch_size,           forKey: .batch_size)
        try c.encode(base.enable_hr,            forKey: .enable_hr)
        try c.encode(base.hr_upscaler,          forKey: .hr_upscaler)
        try c.encode(base.hr_scale,             forKey: .hr_scale)
        try c.encode(base.hr_second_pass_steps, forKey: .hr_second_pass_steps)
        try c.encode(base.hr_resize_x,          forKey: .hr_resize_x)
        try c.encode(base.hr_resize_y,          forKey: .hr_resize_y)
        try c.encode(base.denoising_strength,   forKey: .denoising_strength)
        try c.encode(base.restore_faces,        forKey: .restore_faces)
        try c.encode(base.tiling,               forKey: .tiling)
        if let ov = base.override_settings { try c.encode(ov, forKey: .override_settings) }
        if !scripts.isEmpty,
           let scriptData  = try? JSONSerialization.data(withJSONObject: scripts),
           let scriptValue = try? JSONDecoder().decode(AnyCodable.self, from: scriptData) {
            try c.encode(scriptValue, forKey: .alwayson_scripts)
        }
    }
}

// MARK: - SDRequestWithControlNet (para /controlnet/txt2img)
//
// Endpoint nativo de sd-webui-controlnet. Acepta "controlnet_units" como
// array top-level — NO dentro de alwayson_scripts.
// ADetailer sigue pasando en alwayson_scripts dentro del mismo payload.

struct SDRequestWithControlNet: Encodable {

    let base:            SDRequest
    let controlNetUnits: [[String: Any]]
    let alwaysOnScripts: [String: Any]

    enum CodingKeys: String, CodingKey {
        case prompt, negative_prompt, seed, steps, cfg_scale
        case width, height, sampler_name, batch_size
        case enable_hr, hr_upscaler, hr_scale, hr_second_pass_steps
        case hr_resize_x, hr_resize_y, denoising_strength
        case restore_faces, tiling, override_settings
        case controlnet_units
        case alwayson_scripts
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(base.prompt,               forKey: .prompt)
        try c.encode(base.negative_prompt,      forKey: .negative_prompt)
        try c.encode(base.seed,                 forKey: .seed)
        try c.encode(base.steps,                forKey: .steps)
        try c.encode(base.cfg_scale,            forKey: .cfg_scale)
        try c.encode(base.width,                forKey: .width)
        try c.encode(base.height,               forKey: .height)
        try c.encode(base.sampler_name,         forKey: .sampler_name)
        try c.encode(base.batch_size,           forKey: .batch_size)
        try c.encode(base.enable_hr,            forKey: .enable_hr)
        try c.encode(base.hr_upscaler,          forKey: .hr_upscaler)
        try c.encode(base.hr_scale,             forKey: .hr_scale)
        try c.encode(base.hr_second_pass_steps, forKey: .hr_second_pass_steps)
        try c.encode(base.hr_resize_x,          forKey: .hr_resize_x)
        try c.encode(base.hr_resize_y,          forKey: .hr_resize_y)
        try c.encode(base.denoising_strength,   forKey: .denoising_strength)
        try c.encode(base.restore_faces,        forKey: .restore_faces)
        try c.encode(base.tiling,               forKey: .tiling)
        if let ov = base.override_settings {
            try c.encode(ov, forKey: .override_settings)
        }
        // ControlNet units — top-level, NO en alwayson_scripts
        if !controlNetUnits.isEmpty,
           let unitsData  = try? JSONSerialization.data(withJSONObject: controlNetUnits),
           let unitsValue = try? JSONDecoder().decode([AnyCodable].self, from: unitsData) {
            try c.encode(unitsValue, forKey: .controlnet_units)
        }
        // ADetailer u otros alwayson válidos
        if !alwaysOnScripts.isEmpty,
           let scriptData  = try? JSONSerialization.data(withJSONObject: alwaysOnScripts),
           let scriptValue = try? JSONDecoder().decode(AnyCodable.self, from: scriptData) {
            try c.encode(scriptValue, forKey: .alwayson_scripts)
        }
    }
}

// MARK: - AnyCodable

struct AnyCodable: Codable {
    let value: Any
    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self)                 { value = v; return }
        if let v = try? c.decode(Int.self)                  { value = v; return }
        if let v = try? c.decode(Double.self)               { value = v; return }
        if let v = try? c.decode(String.self)               { value = v; return }
        if let v = try? c.decode([AnyCodable].self)         { value = v.map(\.value); return }
        if let v = try? c.decode([String: AnyCodable].self) { value = v.mapValues(\.value); return }
        value = NSNull()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let v as Bool:           try c.encode(v)
        case let v as Int:            try c.encode(v)
        case let v as Double:         try c.encode(v)
        case let v as String:         try c.encode(v)
        case let v as [Any]:          try c.encode(v.map { AnyCodable($0) })
        case let v as [String: Any]:  try c.encode(v.mapValues { AnyCodable($0) })
        default:                      try c.encodeNil()
        }
    }
}

// MARK: - GenerationSettings extensions

extension GenerationSettings {

    var autoRunIPAdapter: Bool {
        get { UserDefaults.standard.bool(forKey: "gen.autoRunIPAdapter") }
        set { UserDefaults.standard.set(newValue, forKey: "gen.autoRunIPAdapter") }
    }
    var autoRunCompliance: Bool {
        get { UserDefaults.standard.bool(forKey: "gen.autoRunCompliance") }
        set { UserDefaults.standard.set(newValue, forKey: "gen.autoRunCompliance") }
    }
    var ipAdapterEnabled: Bool { IPAdapterEngine.shared.isEnabled }

    /// Construye un SDGenerationPlan completo con routing automático:
    ///   • alwaysOnScripts  — ADetailer (alwayson válido en A1111)
    ///   • controlNetUnits  — ControlNet + IP-Adapter → /controlnet/txt2img
    @MainActor
    func buildRequestWithScripts(
        prompt:         String,
        negativePrompt: String
    ) -> SDGenerationPlan {

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

        // ADetailer → alwayson_scripts (funciona correctamente en A1111)
        var alwaysOnScripts: [String: Any] = [:]
        base.mergeADetailerScripts(into: &alwaysOnScripts)

        // IP-Adapter + ControlNet → /controlnet/txt2img
        var controlNetUnits: [[String: Any]] = []
        if let ipUnit = IPAdapterEngine.shared.buildControlNetAPIUnit() {
            controlNetUnits.append(ipUnit)
        }
        controlNetUnits.append(contentsOf: ControlNetEngine.shared.buildControlNetAPIUnits())

        return SDGenerationPlan(
            request:         base,
            alwaysOnScripts: alwaysOnScripts,
            controlNetUnits: controlNetUnits
        )
    }
}

// MARK: - PipelineRetryPolicy

struct PipelineRetryPolicy {

    var maxAttempts:    Int  = 3
    var baseDelayMs:    Int  = 1_500
    var maxDelayMs:     Int  = 30_000
    var retryOnTimeout: Bool = true
    var retryOnHTTP5xx: Bool = true
    var retryOn429:     Bool = true

    static let `default`  = PipelineRetryPolicy()
    static let aggressive = PipelineRetryPolicy(maxAttempts: 5, baseDelayMs: 2_000, maxDelayMs: 60_000)
    static let singleShot = PipelineRetryPolicy(maxAttempts: 1, baseDelayMs: 0,     maxDelayMs: 0)

    func shouldRetry(statusCode: Int?, attempt: Int) -> Bool {
        guard attempt < maxAttempts else { return false }
        guard let code = statusCode else { return retryOnTimeout }
        if code == 429 { return retryOn429 }
        if code >= 500 { return retryOnHTTP5xx }
        return false
    }

    func delayNS(attempt: Int) -> UInt64 {
        let base   = Double(baseDelayMs)
        let exp    = min(base * pow(2.0, Double(attempt)), Double(maxDelayMs))
        let jitter = Double.random(in: 0.85...1.15)
        return UInt64(exp * jitter * 1_000_000)
    }
}

// MARK: - SDService extensions (v5)

extension SDService {

    var baseURL: URL? {
        URL(string: UserDefaults.standard.string(forKey: "sd.baseURL") ?? "http://127.0.0.1:7860")
    }

    // MARK: generateWithPlan — entry point unificado (NEW v5)

    /// Enruta al endpoint correcto según el plan:
    ///   • ControlNet activo  → /controlnet/txt2img
    ///   • Solo alwayson      → /sdapi/v1/txt2img con alwayson_scripts
    ///   • Sin extras         → /sdapi/v1/txt2img directo
    func generateWithPlan(_ plan: SDGenerationPlan, baseURL: String) async {
        if plan.needsControlNetEndpoint {
            await generateWithControlNet(
                request:         plan.request,
                controlNetUnits: plan.controlNetUnits,
                alwaysOnScripts: plan.alwaysOnScripts,
                baseURL:         baseURL
            )
        } else if plan.hasAlwaysOnScripts {
            await generateWithScripts(
                request: plan.request,
                scripts: plan.alwaysOnScripts,
                baseURL: baseURL
            )
        } else {
            await generate(request: plan.request, baseURL: baseURL)
        }
    }

    // MARK: generateWithControlNet — POST a /controlnet/txt2img (NEW v5)

    /// Envía el request al endpoint nativo de sd-webui-controlnet.
    /// "controlnet_units" va top-level; ADetailer va en "alwayson_scripts".
    func generateWithControlNet(
        request:         SDRequest,
        controlNetUnits: [[String: Any]],
        alwaysOnScripts: [String: Any] = [:],
        baseURL:         String
    ) async {

        isGenerating       = true
        errorMessage       = nil
        generatedImage     = nil
        generationProgress = 0.0
        livePreviewImage   = nil
        etaText            = ""
        stage              = .sending

        let unitCount = controlNetUnits.count
        progressText  = "ControlNet (\(unitCount) unidad\(unitCount == 1 ? "" : "es"))…"

        guard let url = URL(string: "\(baseURL)/controlnet/txt2img") else {
            errorMessage = "URL inválida: \(baseURL)/controlnet/txt2img"
            stage = .error; isGenerating = false; return
        }

        let wrapper = SDRequestWithControlNet(
            base:            request,
            controlNetUnits: controlNetUnits,
            alwaysOnScripts: alwaysOnScripts
        )

        var urlRequest             = URLRequest(url: url)
        urlRequest.httpMethod      = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 600

        do {
            urlRequest.httpBody = try JSONEncoder().encode(wrapper)
        } catch {
            errorMessage = "Encode error: \(error.localizedDescription)"
            stage = .error; isGenerating = false; return
        }

        progressText = "Generando \(request.steps) steps · ControlNet…"
        startProgressPolling(baseURL: baseURL, totalSteps: request.steps)

        do {
            let (data, response) = try await URLSession.shared.data(for: urlRequest)

            progressPollTask?.cancel()
            progressPollTask   = nil
            generationProgress = 1.0
            livePreviewImage   = nil

            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? "No body"
                throw SDError.httpError(
                    code: (response as? HTTPURLResponse)?.statusCode ?? 0,
                    body: body
                )
            }

            stage        = .receiving
            progressText = "Decodificando imagen…"

            let sdResponse = try JSONDecoder().decode(SDResponse.self, from: data)
            guard let b64     = sdResponse.images.first,
                  let imgData = Data(base64Encoded: b64),
                  let nsImage = NSImage(data: imgData)
            else { throw SDError.decodeFailed }

            generatedImage = nsImage
            lastSeed       = sdResponse.parameters?.seed ?? extractSeedFromInfo(sdResponse.info) ?? 0
            stage          = .done
            progressText   = "✓ Hecho (\(unitCount) CN unit\(unitCount == 1 ? "" : "s"))"

            ZeroKnowledgeLog.shared.write(
                category: .systemEvent,
                message:  "ControlNet OK · \(unitCount) units · seed:\(lastSeed) · steps:\(request.steps)"
            )

        } catch {
            progressPollTask?.cancel()
            progressPollTask = nil
            errorMessage     = error.localizedDescription
            stage            = .error
            progressText     = ""

            ZeroKnowledgeLog.shared.write(
                category: .systemEvent,
                message:  "ControlNet error: \(error.localizedDescription)"
            )
        }

        isGenerating = false
        Task { await SDRequestScriptsRegistry.shared.pruneOldEntries() }
    }

    // MARK: generateWithScripts — v3

    func generateWithScripts(
        request: SDRequest,
        scripts: [String: Any],
        baseURL: String
    ) async {
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
        let activeKeys     = scripts.keys.sorted().joined(separator: ", ")
        progressText       = "SD conectando · scripts: \(activeKeys)…"

        guard let url = URL(string: "\(baseURL)/sdapi/v1/txt2img") else {
            errorMessage = "URL inválida: \(baseURL)"
            stage = .error; isGenerating = false; return
        }

        let wrapper = SDRequestWithScripts(base: request, scripts: scripts)
        var urlRequest             = URLRequest(url: url)
        urlRequest.httpMethod      = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 600

        do {
            urlRequest.httpBody = try JSONEncoder().encode(wrapper)
        } catch {
            errorMessage = "Encode error: \(error.localizedDescription)"
            stage = .error; isGenerating = false; return
        }

        progressText = "Generando \(request.steps) steps · \(activeKeys)…"
        startProgressPolling(baseURL: baseURL, totalSteps: request.steps)

        do {
            let (data, response) = try await URLSession.shared.data(for: urlRequest)

            progressPollTask?.cancel()
            progressPollTask   = nil
            generationProgress = 1.0
            livePreviewImage   = nil

            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? "No body"
                throw SDError.httpError(
                    code: (response as? HTTPURLResponse)?.statusCode ?? 0,
                    body: body
                )
            }

            stage        = .receiving
            progressText = "Decodificando imagen…"

            let sdResponse = try JSONDecoder().decode(SDResponse.self, from: data)
            guard let b64     = sdResponse.images.first,
                  let imgData = Data(base64Encoded: b64),
                  let nsImage = NSImage(data: imgData)
            else { throw SDError.decodeFailed }

            generatedImage = nsImage
            lastSeed = sdResponse.parameters?.seed ?? extractSeedFromInfo(sdResponse.info) ?? 0
            stage        = .done
            progressText = "✓ Hecho (\(scripts.count) scripts activos)"

        } catch {
            progressPollTask?.cancel()
            progressPollTask = nil
            errorMessage     = error.localizedDescription
            stage            = .error
            progressText     = ""
        }

        isGenerating = false
        Task { await SDRequestScriptsRegistry.shared.pruneOldEntries() }
    }

    // MARK: generateWithRetry (v3)

    func generateWithRetry(
        request: SDRequest,
        baseURL: String,
        scripts: [String: Any] = [:],
        policy:  PipelineRetryPolicy
    ) async {
        var attempt = 0
        while attempt < policy.maxAttempts {
            if attempt > 0 {
                let delay = policy.delayNS(attempt: attempt - 1)
                progressText = "Reintentando (\(attempt)/\(policy.maxAttempts))…"
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
                ZeroKnowledgeLog.shared.write(
                    category: .systemEvent,
                    message:  "SD retry intento \(attempt)/\(policy.maxAttempts)"
                )
            }

            if scripts.isEmpty {
                await generate(request: request, baseURL: baseURL)
            } else {
                await generateWithScripts(request: request, scripts: scripts, baseURL: baseURL)
            }

            if errorMessage == nil { return }
            attempt += 1
        }
    }

    // NOTE: cancelProgressPoll() and resetState() are defined in SDService.swift
}

// MARK: - ControlNetEngine bridges (v5)

extension ControlNetEngine {

    /// Formato para /controlnet/txt2img — usa "input_image" (no "image").
    @MainActor
    func buildControlNetAPIUnits() -> [[String: Any]] {
        guard isEnabled else { return [] }
        let active = activeUnits.filter { $0.enabled }
        guard !active.isEmpty else { return [] }

        return active.map { unit -> [String: Any] in
            var dict: [String: Any] = [
                "enabled":        unit.enabled,
                "module":         unit.module.rawValue,
                "model":          unit.model,
                "weight":         unit.weight,
                "guidance_start": unit.guidanceStart,
                "guidance_end":   unit.guidanceEnd,
                "control_mode":   unit.controlMode.rawValue,
                "pixel_perfect":  unit.pixelPerfect,
                "processor_res":  unit.processorRes,
                "threshold_a":    unit.thresholdA,
                "threshold_b":    unit.thresholdB,
                "resize_mode":    1
            ]
            if let b64 = unit.imageBase64 {
                dict["input_image"] = b64   // /controlnet/txt2img usa "input_image"
            }
            return dict
        }
    }

    /// Compatibilidad con BatchEngine — mantiene la firma original.
    @MainActor
    func buildAlwaysOnScripts() -> [String: Any] {
        guard isEnabled else { return [:] }
        let active = activeUnits.filter { $0.enabled }
        guard !active.isEmpty else { return [:] }

        let unitPayloads = active.map { unit -> [String: Any] in
            var payload: [String: Any] = [
                "enabled":        unit.enabled,
                "module":         unit.module.rawValue,
                "model":          unit.model,
                "weight":         unit.weight,
                "guidance_start": unit.guidanceStart,
                "guidance_end":   unit.guidanceEnd,
                "control_mode":   unit.controlMode.rawValue,
                "pixel_perfect":  unit.pixelPerfect,
                "processor_res":  unit.processorRes,
                "threshold_a":    unit.thresholdA,
                "threshold_b":    unit.thresholdB
            ]
            if let b64 = unit.imageBase64 { payload["image"] = b64 }
            return payload
        }
        return ["ControlNet": ["args": unitPayloads]]
    }
}

// MARK: - IPAdapterEngine bridges (v5)

extension IPAdapterEngine {

    /// Formato para /controlnet/txt2img — usa "input_image" (no "image", sin data URI prefix).
    @MainActor
    func buildControlNetAPIUnit() -> [String: Any]? {
        guard config.enabled, let refPath = config.referenceImage else { return nil }
        guard let imageData = try? Data(contentsOf: URL(fileURLWithPath: refPath)),
              !imageData.isEmpty
        else { return nil }

        let model      = config.model
        let moduleName = model.isFaceModel ? "ip-adapter-faceid" : "ip-adapter_clip_sd15"

        return [
            "enabled":        true,
            "module":         moduleName,
            "model":          model.rawValue,
            "weight":         config.weight,
            "input_image":    imageData.base64EncodedString(),  // sin data URI prefix
            "guidance_start": config.beginStep,
            "guidance_end":   config.endStep,
            "resize_mode":    2,    // Crop and Resize
            "processor_res":  512
        ]
    }

    /// Compatibilidad — bloque alwayson_scripts original (no usado en v5 main path).
    @MainActor
    func buildAlwaysOnScripts() -> [String: Any]? {
        guard config.enabled, let refPath = config.referenceImage else { return nil }
        guard let imageData = try? Data(contentsOf: URL(fileURLWithPath: refPath)),
              !imageData.isEmpty
        else { return nil }

        let model      = config.model
        let moduleName = model.isFaceModel ? "ip-adapter-faceid" : "ip-adapter_clip_sd15"

        let args: [String: Any] = [
            "enabled":        true,
            "module":         moduleName,
            "model":          model.rawValue,
            "weight":         config.weight,
            "image":          "data:image/png;base64,\(imageData.base64EncodedString())",
            "guidance_start": config.beginStep,
            "guidance_end":   config.endStep,
            "resize_mode":    "Crop and Resize",
            "processor_res":  512
        ]
        return ["ControlNet": ["args": [args]]]
    }
}

// MARK: - ADetailerEngine alwayson_scripts bridge

extension ADetailerEngine {
    @MainActor
    func buildAlwaysOnScripts() -> [String: Any] {
        guard isEnabled, !activeUnits.isEmpty else { return [:] }
        let enabledUnits = activeUnits.filter { $0.enabled }
        guard !enabledUnits.isEmpty else { return [:] }
        var args: [Any] = [true]
        args.append(contentsOf: enabledUnits.map { $0.toAPIDict })
        return ["ADetailer": ["args": args]]
    }
}
