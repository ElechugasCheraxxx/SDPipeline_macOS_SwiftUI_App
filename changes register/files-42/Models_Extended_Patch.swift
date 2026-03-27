import Foundation
import SwiftUI

// MARK: - Models_Extended_Patch v3
//
// Cambios v2 → v3:
//   🐛 FIX: _alwayson_scripts_storage era variable global estática — race condition en batch paralelo.
//           Eliminada. Scripts se pasan siempre explícitamente vía buildRequestWithScripts.
//   🐛 FIX: injectIPAdapterScripts era no-op. Reemplazada por mergeIPAdapterScripts(into:).
//   🐛 FIX: generateWithScripts no cancelaba progressPollTask al retornar. Corregido.
//   ✨ ADD: SDRequestScriptsRegistry actor — almacenamiento thread-safe de scripts por requestID.
//   ✨ ADD: SDService.generateWithRetry — reintentos con backoff exponencial.
//   ✨ ADD: SDService.cancelProgressPoll() / resetState() — métodos públicos de control.
//   ✨ ADD: PipelineRetryPolicy — política de reintentos configurable.
//   ✨ ADD: ControlNetEngine + ADetailerEngine .buildAlwaysOnScripts() bridges.

// MARK: - Thread-Safe Scripts Registry (reemplaza el global estático)

/// Actor que almacena scripts alwayson de cada request de forma aislada.
/// Reemplaza la antigua var global _alwayson_scripts_storage que causaba race conditions
/// cuando dos jobs batch se ejecutaban en paralelo.
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

    /// Limita el registry a maxCount entradas para evitar leaks en sesiones largas.
    func pruneOldEntries(maxCount: Int = 200) {
        guard registry.count > maxCount else { return }
        let toRemove = Array(registry.keys.prefix(registry.count - maxCount / 2))
        toRemove.forEach { registry.removeValue(forKey: $0) }
    }
}

// MARK: - SDRequest: scripts helpers

extension SDRequest {

    /// Inyecta scripts del IP-Adapter en un dict mutable.
    @MainActor
    func mergeIPAdapterScripts(into scripts: inout [String: Any]) {
        guard IPAdapterEngine.shared.isEnabled else { return }
        guard let ipScripts = IPAdapterEngine.shared.buildAlwaysOnScripts() else { return }
        for (key, value) in ipScripts { scripts[key] = value }
    }

    /// Inyecta scripts de ControlNet en un dict mutable.
    @MainActor
    func mergeControlNetScripts(into scripts: inout [String: Any]) {
        let cnScripts = ControlNetEngine.shared.buildAlwaysOnScripts()
        guard !cnScripts.isEmpty else { return }
        for (key, value) in cnScripts { scripts[key] = value }
    }

    /// Inyecta scripts de ADetailer en un dict mutable.
    @MainActor
    func mergeADetailerScripts(into scripts: inout [String: Any]) {
        let adScripts = ADetailerEngine.shared.buildAlwaysOnScripts()
        guard !adScripts.isEmpty else { return }
        for (key, value) in adScripts { scripts[key] = value }
    }
}

// MARK: - SDRequestWithScripts

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

// MARK: - AnyCodable

struct AnyCodable: Codable {
    let value: Any
    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self)               { value = v; return }
        if let v = try? c.decode(Int.self)                { value = v; return }
        if let v = try? c.decode(Double.self)             { value = v; return }
        if let v = try? c.decode(String.self)             { value = v; return }
        if let v = try? c.decode([AnyCodable].self)       { value = v.map(\.value); return }
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

    /// Construye SDRequest base + dict de alwayson_scripts unificado de todos los engines activos.
    /// IP-Adapter + ControlNet + ADetailer se fusionan en un único payload.
    @MainActor
    func buildRequestWithScripts(
        prompt:         String,
        negativePrompt: String
    ) -> (request: SDRequest, scripts: [String: Any]) {

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
        base.mergeIPAdapterScripts(into: &scripts)
        base.mergeControlNetScripts(into: &scripts)
        base.mergeADetailerScripts(into: &scripts)

        return (base, scripts)
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

    /// Delay en nanosegundos con jitter (evita thundering herd en batch).
    func delayNS(attempt: Int) -> UInt64 {
        let base   = Double(baseDelayMs)
        let exp    = min(base * pow(2.0, Double(attempt)), Double(maxDelayMs))
        let jitter = Double.random(in: 0.85...1.15)
        return UInt64(exp * jitter * 1_000_000)
    }
}

// MARK: - SDService extensions (v3)

extension SDService {

    var baseURL: URL? {
        URL(string: UserDefaults.standard.string(forKey: "sd.baseURL") ?? "http://127.0.0.1:7860")
    }

    // MARK: generateWithScripts — v3 (cancela poll correctamente)

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

            // ✅ FIX v3: cancelar poll SIEMPRE antes de cualquier throw/return
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
            // ✅ FIX v3: cancelar también en path de error
            progressPollTask?.cancel()
            progressPollTask = nil
            errorMessage     = error.localizedDescription
            stage            = .error
            progressText     = ""
        }

        isGenerating = false
        Task { await SDRequestScriptsRegistry.shared.pruneOldEntries() }
    }

    // MARK: generateWithRetry (NEW v3)

    /// Genera con reintentos automáticos según PipelineRetryPolicy.
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

            if errorMessage == nil { return }   // éxito

            attempt += 1
        }
    }

    // NOTE: cancelProgressPoll() and resetState() are defined in SDService.swift
}

// MARK: - ControlNetEngine alwayson_scripts bridge

extension ControlNetEngine {
    @MainActor
    func buildAlwaysOnScripts() -> [String: Any] {
        guard isEnabled else { return [:] }
        let activeUnits = self.activeUnits.filter { $0.enabled }
        guard !activeUnits.isEmpty else { return [:] }

        let unitPayloads = activeUnits.map { unit -> [String: Any] in
            var payload: [String: Any] = [
                "enabled":        unit.enabled,
                "module":         unit.preprocessor.rawValue,
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
            if let img     = unit.inputImage,
               let tiff    = img.tiffRepresentation,
               let bmpRep  = NSBitmapImageRep(data: tiff),
               let pngData = bmpRep.representation(using: .png, properties: [:]) {
                payload["image"] = pngData.base64EncodedString()
            }
            return payload
        }
        return ["ControlNet": ["args": unitPayloads]]
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
