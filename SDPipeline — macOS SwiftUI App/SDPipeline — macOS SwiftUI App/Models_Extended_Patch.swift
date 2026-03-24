import Foundation
import SwiftUI

// MARK: - Models_Extended_Patch v7
//
// Cambios v6 → v7:
//   🔧 FIX: SDRequestWithControlNet restaurado como struct ACTIVO (sin @deprecated).
//           Es el único mecanismo que funciona: serializa "controlnet_units" como
//           campo TOP-LEVEL en /sdapi/v1/txt2img.
//   🔧 FIX: Eliminado @available(*, deprecated) que marcaba el struct erróneamente.
//   📝 DOC: Historial de estrategias descartadas documentado en SDGenerationPlan.
//
// Cambios v5 → v6 (histórico):
//   🔧 FIX: "ControlNet" clave corregida (case-sensitive) en buildAlwaysOnScripts.
//   🗑️ DEP: SDRequestWithControlNet marcado deprecated (error — revertido en v7).
//
// Cambios v4 → v5 (histórico):
//   🐛 FIX: mergeIPAdapterScripts / mergeControlNetScripts eran no-ops efectivos.
//   ✨ ADD: SDGenerationPlan, SDRequestWithControlNet, generateWithPlan(), etc.
//   🔧 FIX: Campo "input_image" → "image". Filtrado de units sin imagen.

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
//
// Estrategias de ControlNet probadas y descartadas:
//   ❌ alwayson_scripts["controlnet"] → HTTP 422 (Script 'controlnet' not found)
//   ❌ alwayson_scripts["ControlNet"] → HTTP 422 (Script 'ControlNet' not found)
//   ❌ POST /controlnet/txt2img       → HTTP 404 (endpoint no existe)
//   ✅ "controlnet_units" top-level en /sdapi/v1/txt2img → SDRequestWithControlNet

struct SDGenerationPlan {
    let request:         SDRequest
    let alwaysOnScripts: [String: Any]    // ADetailer → alwayson_scripts["ADetailer"]
    let controlNetUnits: [[String: Any]]  // ControlNet/IP-Adapter → controlnet_units top-level

    var hasControlNetUnits:     Bool { !controlNetUnits.isEmpty }
    var hasAlwaysOnScripts:     Bool { !alwaysOnScripts.isEmpty }
    var isPlain:                Bool { !hasControlNetUnits && !hasAlwaysOnScripts }
    var needsControlNetEndpoint: Bool { hasControlNetUnits }  // compatibilidad
}

// MARK: - SDRequest: scripts helpers (compatibilidad BatchEngine)

extension SDRequest {

    @MainActor
    func mergeIPAdapterScripts(into scripts: inout [String: Any]) {}

    @MainActor
    func mergeControlNetScripts(into scripts: inout [String: Any]) {}

    @MainActor
    func mergeADetailerScripts(into scripts: inout [String: Any]) {
        let adScripts = ADetailerEngine.shared.buildAlwaysOnScripts()
        guard !adScripts.isEmpty else { return }
        for (key, value) in adScripts { scripts[key] = value }
    }
}

// MARK: - SDRequestWithScripts (para /sdapi/v1/txt2img + alwayson_scripts)
// Usado para ADetailer y otros scripts registrados en A1111.

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

// MARK: - SDRequestWithControlNet (para /sdapi/v1/txt2img con controlnet_units top-level)
//
// ✅ ESTRATEGIA ACTIVA en v7.
//
// Serializa "controlnet_units" como campo TOP-LEVEL en el body JSON —
// NO dentro de alwayson_scripts. Esta es la única forma que acepta
// la extensión sd-webui-controlnet en esta instalación.
//
// ADetailer y otros scripts válidos siguen en alwayson_scripts normalmente.

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
        case controlnet_units   // ✅ top-level — NO dentro de alwayson_scripts
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
        // ControlNet units — campo top-level, separado de alwayson_scripts
        if !controlNetUnits.isEmpty,
           let unitsData  = try? JSONSerialization.data(withJSONObject: controlNetUnits),
           let unitsValue = try? JSONDecoder().decode([AnyCodable].self, from: unitsData) {
            try c.encode(unitsValue, forKey: .controlnet_units)
        }
        // ADetailer u otros alwayson_scripts válidos
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

    /// Construye un SDGenerationPlan completo:
    ///   • alwaysOnScripts → ADetailer (via alwayson_scripts en /sdapi/v1/txt2img)
    ///   • controlNetUnits → ControlNet + IP-Adapter (via controlnet_units top-level)
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

        var alwaysOnScripts: [String: Any] = [:]
        base.mergeADetailerScripts(into: &alwaysOnScripts)

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

// MARK: - ControlNetEngine bridges (v7)

extension ControlNetEngine {

    /// Construye los dicts de unidades para inyectar en controlnet_units top-level.
    @MainActor
    func buildControlNetAPIUnits() -> [[String: Any]] {
        guard isEnabled else { return [] }
        let active = activeUnits.filter { $0.enabled }
        guard !active.isEmpty else { return [] }

        return active.compactMap { unit -> [String: Any]? in
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

            if unit.module != .none {
                guard let b64 = unit.imageBase64 else { return nil }
                dict["image"] = b64
            } else if let b64 = unit.imageBase64 {
                dict["image"] = b64
            }

            return dict
        }
    }

    /// Compatibilidad con BatchEngine — produce el bloque alwayson_scripts.
    /// NOTA: en el main path de v7 esto ya no se usa para ControlNet,
    /// pero se mantiene para BatchEngine u otros callers.
    @MainActor
    func buildAlwaysOnScripts() -> [String: Any] {
        guard isEnabled else { return [:] }
        let active = activeUnits.filter { $0.enabled }
        guard !active.isEmpty else { return [:] }

        let unitPayloads = active.compactMap { unit -> [String: Any]? in
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
            if unit.module != .none {
                guard let b64 = unit.imageBase64 else { return nil }
                payload["image"] = b64
            } else if let b64 = unit.imageBase64 {
                payload["image"] = b64
            }
            return payload
        }

        guard !unitPayloads.isEmpty else { return [:] }
        return ["ControlNet": ["args": unitPayloads]]
    }
}

// MARK: - IPAdapterEngine bridges (v7)

extension IPAdapterEngine {

    /// Construye el dict de unidad IP-Adapter para controlnet_units top-level.
    @MainActor
    func buildControlNetAPIUnit() -> [String: Any]? {
        guard config.enabled, let refPath = config.referenceImage, referenceImage != nil else { return nil }
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
            "image":          imageData.base64EncodedString(),
            "guidance_start": config.beginStep,
            "guidance_end":   config.endStep,
            "resize_mode":    2,
            "processor_res":  512
        ]
    }

    /// Legacy — no usado en v7 main path.
    @MainActor
    func buildAlwaysOnScriptsLegacy() -> [String: Any]? {
        guard config.enabled, let refPath = config.referenceImage, referenceImage != nil else { return nil }
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
