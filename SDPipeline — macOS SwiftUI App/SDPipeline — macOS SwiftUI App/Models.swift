import Foundation
import CoreData

// MARK: - SD API Request (Automatic1111 full spec)

struct SDRequest: Codable {
    var prompt: String
    var negative_prompt: String
    var seed: Int
    var steps: Int
    var cfg_scale: Double
    var width: Int
    var height: Int
    var sampler_name: String
    var batch_size: Int

    // Hires fix
    var enable_hr: Bool
    var hr_upscaler: String
    var hr_scale: Double
    var hr_second_pass_steps: Int
    var hr_resize_x: Int
    var hr_resize_y: Int
    var denoising_strength: Double

    // Restore faces / tiling
    var restore_faces: Bool
    var tiling: Bool

    // Extra metadata (ignored by A1111)
    var override_settings: [String: String]?

    init(
        prompt: String,
        negativePrompt: String        = "ugly, blurry, deformed, low quality, watermark, text, nsfw",
        seed: Int                     = -1,
        steps: Int                    = 28,
        cfgScale: Double              = 7.0,
        width: Int                    = 512,
        height: Int                   = 768,
        samplerName: String           = "DPM++ 2M Karras",
        batchSize: Int                = 1,
        enableHR: Bool                = false,
        hrUpscaler: String            = "4x-UltraSharp",
        hrScale: Double               = 2.0,
        hrSecondPassSteps: Int        = 15,
        hrResizeX: Int                = 0,
        hrResizeY: Int                = 0,
        denoisingStrength: Double     = 0.45,
        restoreFaces: Bool            = false,
        tiling: Bool                  = false
    ) {
        self.prompt               = prompt
        self.negative_prompt      = negativePrompt
        self.seed                 = seed
        self.steps                = steps
        self.cfg_scale            = cfgScale
        self.width                = width
        self.height               = height
        self.sampler_name         = samplerName
        self.batch_size           = batchSize
        self.enable_hr            = enableHR
        self.hr_upscaler          = hrUpscaler
        self.hr_scale             = hrScale
        self.hr_second_pass_steps = hrSecondPassSteps
        self.hr_resize_x          = hrResizeX
        self.hr_resize_y          = hrResizeY
        self.denoising_strength   = denoisingStrength
        self.restore_faces        = restoreFaces
        self.tiling               = tiling
    }
}

// MARK: - SD API Response

struct SDResponse: Codable {
    let images: [String]
    let parameters: SDResponseParameters?
    let info: String?
}

struct SDResponseParameters: Codable {
    let prompt: String?
    let seed: Int?
    let steps: Int?
}

// MARK: - SD Progress Response (polling /sdapi/v1/progress)

struct SDProgressResponse: Codable {
    let progress: Double
    let eta_relative: Double
    let state: SDProgressState?
    let current_image: String?
    let textinfo: String?

    struct SDProgressState: Codable {
        let job: String?
        let job_count: Int?
        let job_no: Int?
        let sampling_step: Int?
        let sampling_steps: Int?
    }

    var percentDisplay: String { "\(Int(progress * 100))%" }

    var etaDisplay: String {
        guard eta_relative > 0 else { return "" }
        return String(format: "ETA %.0fs", eta_relative)
    }
}

// MARK: - Pipeline Stage

enum PipelineStage: String, CaseIterable {
    case idle       = "Idle"
    case parsing    = "Parsing JSON"
    case building   = "Building Prompt"
    case sending    = "Sending to SD"
    case receiving  = "Receiving Image"
    case postproc   = "Post-Processing"
    case saving     = "Saving to Vault"
    case done       = "Done"
    case error      = "Error"
}

// MARK: - Generation Settings (UI state)

struct GenerationSettings {
    var negativePrompt: String  = "ugly, blurry, deformed, low quality, watermark, text, nsfw, extra limbs, bad anatomy, disfigured, mutation"
    var steps: Int              = 28
    var cfgScale: Double        = 7.0
    var width: Int              = 512
    var height: Int             = 768
    var samplerName: String     = "DPM++ 2M Karras"
    var seed: Int               = -1
    var checkpoint: String      = ""
    var sdBaseURL: String       = "http://127.0.0.1:7860"

    // Hires fix
    var enableHR: Bool          = false
    var hrUpscaler: String      = "4x-UltraSharp"
    var hrScale: Double         = 2.0
    var hrSteps: Int            = 15
    var denoisingStrength: Double = 0.45

    var restoreFaces: Bool      = false

    // Post-generation pipeline flags (new)
    var autoRunADetailer: Bool  = false
    var autoRunNSFWCheck: Bool  = true
    var autoRunPostProd: Bool   = false

    var webuiScriptPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/automatic1111/stable-diffusion-webui/webui.sh"
    }()

    static let samplers = [
        "DPM++ 2M Karras", "DPM++ SDE Karras", "DPM++ 2M SDE Karras",
        "Euler a", "Euler", "LMS", "Heun", "DPM2", "DPM2 a",
        "DPM++ 2S a", "DPM++ 2M", "DPM++ SDE",
        "DPM fast", "DPM adaptive", "DDIM", "PLMS"
    ]

    static let hrUpscalers = [
        "4x-UltraSharp", "ESRGAN_4x", "R-ESRGAN 4x+",
        "R-ESRGAN 4x+ Anime6B", "Latent", "Latent (nearest)", "None"
    ]
}

// MARK: - PromptBuilder (intent-aware)

struct PromptBuilder {

    private static let metaKeys: Set<String> = [
        "version", "project_name", "character_id", "generation_count",
        "consistency_lock", "enabled", "max_allowed_variation_percent",
        "face_similarity_score_target_0_100", "explicit_nudity_allowed",
        "minimum_coverage_enforced", "age_appropriate_enforced",
        "explicit_content_block", "sexual_act_block", "minor_protection_enforced",
        "no_genital_focus", "no_intimate_area_exposure", "age_appropriate_content_only",
        "focus_target", "forbidden_pose_conditions",
        "lock_eye_color", "lock_bone_structure", "lock_lip_shape",
        "allow_makeup_variation", "allow_hairstyle_variation",
        "age_verified", "consistency_rules", "mutation_control",
        "coverage_protocol", "safety_compliance_layer"
    ]

    private static let positiveMap: [(keys: [String], prefix: String?)] = [
        (["subject_system", "identity", "archetype"],           nil),
        (["subject_system", "identity", "name"],                nil),
        (["subject_system", "identity", "gender"],              nil),
        (["subject_system", "biometrics", "body_type"],         nil),
        (["subject_system", "expression_engine", "default_expression"], nil),
        (["subject_system", "expression_engine", "smile_type"],          nil),
        (["subject_system", "expression_engine", "editorial_emotion"],  nil),
        (["editorial_style_system", "style_category"],          nil),
        (["editorial_style_system", "visual_tone"],             nil),
        (["editorial_style_system", "target_industry"],         nil),
        (["wardrobe_engine", "outfit_category"],                nil),
        (["wardrobe_engine", "style_reference"],                nil),
        (["wardrobe_engine", "fabric_physics", "movement_behavior"], nil),
        (["wardrobe_engine", "layering_system", "base_layer"],  nil),
        (["wardrobe_engine", "layering_system", "secondary_layer"], nil),
        (["wardrobe_engine", "layering_system", "outer_layer"], nil),
        (["wardrobe_engine", "layering_system", "accessories"], nil),
        (["pose_engine", "pose_name"],                          nil),
        (["pose_engine", "pose_style"],                         nil),
        (["pose_engine", "body_orientation"],                   nil),
        (["pose_engine", "arm_positioning"],                    nil),
        (["pose_engine", "editorial_action"],                   nil),
        (["environment_system", "location_type"],               nil),
        (["environment_system", "setting_style"],               nil),
        (["environment_system", "time_of_day"],                 nil),
        (["environment_system", "ambient_energy"],              nil),
        (["environment_system", "color_grading_reference"],     nil),
        (["environment_system", "prop_interaction"],            nil),
        (["lighting_engine", "lighting_style"],                 nil),
        (["lighting_engine", "key_light", "color_temperature"], nil),
        (["camera_engine", "camera_type"],                      nil),
        (["camera_engine", "framing_type"],                     nil),
        (["camera_engine", "depth_of_field_strength"],          nil),
        (["camera_engine", "camera_angle"],                     nil),
        (["brand_projection", "editorial_voice"],               nil),
        (["generation_engine", "primary_prompt"],               nil),
    ]

    static func buildFromEditorialSchema(_ json: Any) -> (positive: String, negative: String) {
        guard let dict = json as? [String: Any] else { return (buildFlat(from: json), "") }

        var positiveTokens: [String] = []

        if let genEngine = dict["generation_engine"] as? [String: Any],
           let primary = genEngine["primary_prompt"] as? String, !primary.isEmpty {
            positiveTokens.append(primary)
            if let variations = genEngine["variation_prompts"] as? [String] {
                positiveTokens.append(contentsOf: variations.filter { !$0.isEmpty })
            }
        } else {
            for entry in positiveMap {
                if let value = resolvePath(entry.keys, in: dict) {
                    let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !clean.isEmpty else { continue }
                    if let prefix = entry.prefix {
                        positiveTokens.append("\(prefix) \(clean)")
                    } else {
                        positiveTokens.append(clean)
                    }
                }
            }
        }

        positiveTokens.append(contentsOf: qualityBoosters(from: dict))
        let negative = extractNegative(from: dict)

        let positive = positiveTokens
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .uniqued()
            .joined(separator: ", ")

        return (positive, negative)
    }

    static func buildFlat(from json: Any, prefix: String = "") -> String {
        var tokens: [String] = []
        extractFlat(value: json, key: prefix, into: &tokens)
        return tokens.joined(separator: ", ")
    }

    static func extractDirectPrompt(from json: Any) -> String? {
        guard let dict = json as? [String: Any] else { return nil }
        if let p = dict["prompt"] as? String, !p.isEmpty { return p }
        return nil
    }

    private static func resolvePath(_ keys: [String], in dict: [String: Any]) -> String? {
        var current: Any = dict
        for key in keys {
            guard let d = current as? [String: Any], let next = d[key] else { return nil }
            current = next
        }
        if let s = current as? String { return s.isEmpty ? nil : s }
        if let b = current as? Bool   { return b ? keys.last : nil }
        return nil
    }

    private static func extractNegative(from dict: [String: Any]) -> String {
        if let arr = dict["negative_prompt"] as? [String], !arr.isEmpty {
            return arr.joined(separator: ", ")
        }
        if let gen = dict["generation_engine"] as? [String: Any],
           let neg = gen["negative_prompt"] as? String, !neg.isEmpty {
            return neg
        }
        return ""
    }

    private static func qualityBoosters(from dict: [String: Any]) -> [String] {
        var boosters: [String] = []
        let components    = (dict["editorial_style_system"] as? [String: Any])?["components"] as? [String: Any]
        let lightingDrama = components?["lighting_drama_0_10"] as? Int ?? 0
        let cameraStory   = components?["camera_storytelling_0_10"] as? Int ?? 0

        if lightingDrama >= 8 { boosters.append("dramatic studio lighting, professional photography") }
        else if lightingDrama >= 5 { boosters.append("professional lighting") }

        if cameraStory >= 8 { boosters.append("editorial photography, award-winning composition") }
        else if cameraStory >= 5 { boosters.append("editorial photography") }

        if let camEngine = dict["camera_engine"] as? [String: Any] {
            if let lens = camEngine["lens_mm"] as? Int, lens >= 85 {
                boosters.append("shallow depth of field, bokeh")
            }
            if let aperture = camEngine["aperture"] as? String,
               ["f/1.4", "f/1.8"].contains(aperture) {
                boosters.append("soft background blur")
            }
        }

        let aspScore = (dict["brand_projection"] as? [String: Any])?["aspirational_level_0_10"] as? Int ?? 0
        if aspScore >= 8 { boosters.append("ultra high resolution, 8k, masterpiece") }
        else             { boosters.append("high quality, detailed") }

        if let rimEnabled = (dict["lighting_engine"] as? [String: Any])?["rim_light"] as? [String: Any],
           let on = rimEnabled["enabled"] as? Bool, on {
            boosters.append("rim lighting")
        }
        return boosters
    }

    private static func extractFlat(value: Any, key: String, into tokens: inout [String]) {
        let lowKey = key.lowercased()
        if metaKeys.contains(lowKey) { return }
        if lowKey.contains("id") || lowKey.contains("timestamp") ||
           lowKey.contains("url") || lowKey.contains("hash") { return }

        switch value {
        case let dict as [String: Any]:
            for (k, v) in dict.sorted(by: { $0.key < $1.key }) { extractFlat(value: v, key: k, into: &tokens) }
        case let array as [Any]:
            for item in array { extractFlat(value: item, key: key, into: &tokens) }
        case let str as String where !str.isEmpty:
            tokens.append(str)
        default: break
        }
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
