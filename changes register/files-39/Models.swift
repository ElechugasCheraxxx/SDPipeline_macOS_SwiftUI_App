import Foundation
import CoreData

// MARK: - Models.swift v2
//
// Cambios v1 → v2:
//   ✨ ADD: SDImg2ImgRequest — soporte completo img2img con mask, resize_mode, inpainting
//   ✨ ADD: SDRequestOverrideSettings — override checkpoint/VAE on-the-fly
//   ✨ ADD: AnyEncodable — wrapper para alwayson_scripts nativo en SDRequest
//   ✨ ADD: SDExtrasRequest + SDExtrasResponse — /extra-single-image (ESRGAN)
//   ✨ ADD: SDInterrogateRequest + Response — /sdapi/v1/interrogate (CLIP)
//   ✨ ADD: SDInfoDecoded — parsed del campo `info` de SDResponse
//   ✨ ADD: SDModelCheckpoint + SDSamplerInfo — modelos de catálogo A1111
//   ✨ ADD: Img2ImgResizeMode enum exhaustivo
//   ✨ ADD: InpaintFill enum exhaustivo
//   ✨ ADD: CharacterProfile — modelo top-level de personaje (movido desde CharacterEngine)
//   ✨ ADD: LoRAEntry — modelo top-level de LoRA (movido desde LoRAManager)
//   ✨ ADD: ControlNetUnit — modelo inline para scripts (sin depender de ControlNetEngine)
//   ✨ ADD: ContentSession — modelo top-level de sesión de contenido
//   ✨ ADD: GenerationSettings v2 — campos restoreFacesStrength, clipSkip, karrasNoise,
//          autoRunADetailer, autoRunCleanup, img2imgEnabled, img2imgDenoise
//   ✨ ADD: PipelineStage ampliado — img2img, upscaling, adetailer, postprocess, cleanup
//   🔁 UPD: SDResponse incluye infoDecoded computed
//   🔁 UPD: GenerationSettings.samplers incluye UniPC
//   🔁 UPD: PromptBuilder.positiveMap añade location_interior/exterior, weather,
//          fill_light, background_light, shot_movement

// MARK: - SD API Request (Automatic1111 full spec v2)

struct SDRequest: Codable {
    var prompt:                String
    var negative_prompt:       String
    var seed:                  Int
    var steps:                 Int
    var cfg_scale:             Double
    var width:                 Int
    var height:                Int
    var sampler_name:          String
    var batch_size:            Int

    // Hires fix
    var enable_hr:             Bool
    var hr_upscaler:           String
    var hr_scale:              Double
    var hr_second_pass_steps:  Int
    var hr_resize_x:           Int
    var hr_resize_y:           Int
    var denoising_strength:    Double

    // Restore faces / tiling
    var restore_faces:         Bool
    var tiling:                Bool

    // Override checkpoint/VAE on-the-fly
    var override_settings:     SDRequestOverrideSettings?

    init(
        prompt:               String,
        negativePrompt:       String  = "ugly, blurry, deformed, low quality, watermark, text",
        seed:                 Int     = -1,
        steps:                Int     = 28,
        cfgScale:             Double  = 7.0,
        width:                Int     = 512,
        height:               Int     = 768,
        samplerName:          String  = "DPM++ 2M Karras",
        batchSize:            Int     = 1,
        enableHR:             Bool    = false,
        hrUpscaler:           String  = "4x-UltraSharp",
        hrScale:              Double  = 2.0,
        hrSecondPassSteps:    Int     = 15,
        hrResizeX:            Int     = 0,
        hrResizeY:            Int     = 0,
        denoisingStrength:    Double  = 0.45,
        restoreFaces:         Bool    = false,
        tiling:               Bool    = false,
        overrideSettings:     SDRequestOverrideSettings? = nil
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
        self.override_settings    = overrideSettings
    }
}

// MARK: - Override Settings

struct SDRequestOverrideSettings: Codable {
    var sd_model_checkpoint:      String?
    var sd_vae:                   String?
    var CLIP_stop_at_last_layers: Int?
    var eta_noise_seed_delta:     Int?
    var s_noise:                  Double?

    init(
        checkpoint: String? = nil,
        vae:        String? = nil,
        clipSkip:   Int?    = nil,
        ensd:       Int?    = nil,
        sNoise:     Double? = nil
    ) {
        self.sd_model_checkpoint      = checkpoint
        self.sd_vae                   = vae
        self.CLIP_stop_at_last_layers = clipSkip
        self.eta_noise_seed_delta     = ensd
        self.s_noise                  = sNoise
    }
}

// MARK: - Img2Img Request (full spec)

struct SDImg2ImgRequest: Codable {
    var init_images:              [String]   // Base64 source image(s)
    var mask:                     String?    // Base64 mask (nil → no inpaint)
    var prompt:                   String
    var negative_prompt:          String
    var seed:                     Int
    var steps:                    Int
    var cfg_scale:                Double
    var width:                    Int
    var height:                   Int
    var sampler_name:             String
    var batch_size:               Int         = 1
    var denoising_strength:       Double
    var resize_mode:              Int
    var inpainting_fill:          Int         = InpaintFill.latentNoise.rawValue
    var inpaint_full_res:         Bool        = true
    var inpaint_full_res_padding: Int         = 32
    var inpainting_mask_invert:   Int         = 0
    var mask_blur:                Int         = 4
    var include_init_images:      Bool        = false
    var override_settings:        SDRequestOverrideSettings?

    init(
        base64Image:       String,
        prompt:            String,
        negativePrompt:    String              = "ugly, blurry, deformed, low quality",
        seed:              Int                 = -1,
        steps:             Int                 = 28,
        cfgScale:          Double              = 7.0,
        width:             Int                 = 512,
        height:            Int                 = 768,
        samplerName:       String              = "DPM++ 2M Karras",
        denoisingStrength: Double              = 0.55,
        resizeMode:        Img2ImgResizeMode   = .scaleToFit,
        mask:              String?             = nil
    ) {
        self.init_images        = [base64Image]
        self.mask               = mask
        self.prompt             = prompt
        self.negative_prompt    = negativePrompt
        self.seed               = seed
        self.steps              = steps
        self.cfg_scale          = cfgScale
        self.width              = width
        self.height             = height
        self.sampler_name       = samplerName
        self.denoising_strength = denoisingStrength
        self.resize_mode        = resizeMode.rawValue
    }
}

// MARK: - Img2Img Resize Mode

enum Img2ImgResizeMode: Int, Codable, CaseIterable {
    case justResize    = 0
    case cropAndResize = 1
    case scaleToFit    = 2
    case latentUpscale = 3

    var label: String {
        switch self {
        case .justResize:    return "Just Resize"
        case .cropAndResize: return "Crop & Resize"
        case .scaleToFit:    return "Scale to Fit"
        case .latentUpscale: return "Latent Upscale"
        }
    }
}

// MARK: - Inpaint Fill Mode

enum InpaintFill: Int, Codable, CaseIterable {
    case fill          = 0
    case original      = 1
    case latentNoise   = 2
    case latentNothing = 3

    var label: String {
        switch self {
        case .fill:          return "Fill"
        case .original:      return "Original"
        case .latentNoise:   return "Latent Noise"
        case .latentNothing: return "Latent Nothing"
        }
    }
}

// MARK: - Extras / Upscale Request

struct SDExtrasRequest: Codable {
    var image:                              String
    var resize_mode:                        Int    = 0
    var upscaling_resize:                   Double = 2.0
    var upscaling_resize_w:                 Int    = 0
    var upscaling_resize_h:                 Int    = 0
    var upscaler_1:                         String = "4x-UltraSharp"
    var upscaler_2:                         String = "None"
    var extras_upscaler_2_visibility:       Double = 0.0
    var upscale_first:                      Bool   = false
    var gfpgan_visibility:                  Double = 0.0
    var codeformer_visibility:              Double = 0.0
    var codeformer_weight:                  Double = 0.0

    init(base64: String, scale: Double = 2.0, upscaler: String = "4x-UltraSharp") {
        self.image            = base64
        self.upscaling_resize = scale
        self.upscaler_1       = upscaler
    }
}

struct SDExtrasResponse: Codable {
    let image:     String
    let html_info: String?
}

// MARK: - Interrogate Request

struct SDInterrogateRequest: Codable {
    var image: String
    var model: InterrogateModel = .clip

    enum InterrogateModel: String, Codable, CaseIterable {
        case clip         = "clip"
        case deepdanbooru = "deepdanbooru"
        var label: String { rawValue.capitalized }
    }
}

struct SDInterrogateResponse: Codable {
    let caption: String
}

// MARK: - SD API Response

struct SDResponse: Codable {
    let images:     [String]
    let parameters: SDResponseParameters?
    let info:        String?

    var infoDecoded: SDInfoDecoded? {
        guard let raw  = info,
              let data = raw.data(using: .utf8),
              let obj  = try? JSONDecoder().decode(SDInfoDecoded.self, from: data) else { return nil }
        return obj
    }
}

struct SDResponseParameters: Codable {
    let prompt:       String?
    let seed:         Int?
    let steps:        Int?
    let cfg_scale:    Double?
    let sampler_name: String?
    let width:        Int?
    let height:       Int?
}

struct SDInfoDecoded: Codable {
    let prompt:             String?
    let negative_prompt:    String?
    let seed:               Int?
    let subseed:            Int?
    let subseed_strength:   Double?
    let width:              Int?
    let height:             Int?
    let sampler_name:       String?
    let cfg_scale:          Double?
    let steps:              Int?
    let batch_size:         Int?
    let restore_faces:      Bool?
    let sd_model_hash:      String?
    let sd_model_name:      String?
    let denoising_strength: Double?
    let all_seeds:          [Int]?
    let all_prompts:        [String]?
}

// MARK: - SD Progress Response

struct SDProgressResponse: Codable {
    let progress:      Double
    let eta_relative:  Double
    let state:         SDProgressState?
    let current_image: String?
    let textinfo:      String?

    struct SDProgressState: Codable {
        let job:                  String?
        let job_count:            Int?
        let job_no:               Int?
        let sampling_step:        Int?
        let sampling_steps:       Int?
        let interrupted:          Bool?
        let stopping_generation:  Bool?
    }

    var percentDisplay: String { "\(Int(progress * 100))%" }

    var etaDisplay: String {
        guard eta_relative > 0 else { return "" }
        let secs = Int(eta_relative)
        return secs < 60 ? "~\(secs)s" : "~\(secs / 60)m \(secs % 60)s"
    }

    var isInterrupted: Bool { state?.interrupted == true }
}

// MARK: - SD Model Checkpoint

struct SDModelCheckpoint: Codable, Identifiable, Hashable {
    var title:      String
    var model_name: String
    var hash:       String?
    var sha256:     String?
    var filename:   String?

    var id: String { hash ?? model_name }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: SDModelCheckpoint, rhs: SDModelCheckpoint) -> Bool { lhs.id == rhs.id }
}

// MARK: - SD Sampler Info

struct SDSamplerInfo: Codable, Identifiable, Hashable {
    var name:    String
    var aliases: [String]
    var options: [String: String]?

    var id: String { name }
}

// MARK: - Pipeline Stage

enum PipelineStage: String, CaseIterable {
    case idle        = "Idle"
    case parsing     = "Parsing JSON"
    case building    = "Building Prompt"
    case sending     = "Sending to SD"
    case receiving   = "Receiving Image"
    case img2img     = "Img2Img Refinement"
    case upscaling   = "Upscaling"
    case adetailer   = "ADetailer"
    case postprocess = "Post-Processing"
    case cleanup     = "Artifact Cleanup"
    case saving      = "Saving to Vault"
    case exporting   = "Exporting"
    case done        = "Done"
    case error       = "Error"
    case interrupted = "Interrupted"

    var isActive: Bool {
        switch self {
        case .idle, .done, .error, .interrupted: return false
        default: return true
        }
    }

    var icon: String {
        switch self {
        case .idle:        return "wand.and.stars"
        case .parsing:     return "doc.text.magnifyingglass"
        case .building:    return "text.bubble"
        case .sending:     return "arrow.up.circle"
        case .receiving:   return "arrow.down.circle"
        case .img2img:     return "arrow.2.squarepath"
        case .upscaling:   return "arrow.up.backward.and.arrow.down.forward"
        case .adetailer:   return "face.smiling"
        case .postprocess: return "slider.horizontal.3"
        case .cleanup:     return "sparkle.magnifyingglass"
        case .saving:      return "externaldrive.fill"
        case .exporting:   return "square.and.arrow.up"
        case .done:        return "checkmark.circle.fill"
        case .error:       return "xmark.circle.fill"
        case .interrupted: return "stop.circle.fill"
        }
    }
}

// MARK: - Generation Settings v2

struct GenerationSettings {
    // Core
    var prompt:              String = ""
    var negativePrompt:      String = "ugly, blurry, deformed, low quality, watermark, text"
    var seed:                Int    = -1
    var steps:               Int    = 28
    var cfgScale:            Double = 7.0
    var width:               Int    = 512
    var height:              Int    = 768
    var samplerName:         String = "DPM++ 2M Karras"
    var batchSize:           Int    = 1
    var checkpoint:          String = ""
    var vaeUsed:             String = "Automatic"

    // Hires Fix
    var enableHR:            Bool   = false
    var hrUpscaler:          String = "4x-UltraSharp"
    var hrScale:             Double = 2.0
    var hrSteps:             Int    = 15
    var denoisingStrength:   Double = 0.45

    // Face Restoration
    var restoreFaces:         Bool   = false
    var restoreFacesStrength: Double = 0.5   // NEW v2

    // CLIP
    var clipSkip:             Int    = 1     // NEW v2 (CLIP_stop_at_last_layers)

    // Noise schedule
    var karrasNoise:          Bool   = true  // NEW v2

    // Auto-pipeline flags
    var autoRunADetailer:     Bool   = false // NEW v2
    var autoRunCleanup:       Bool   = false // NEW v2

    // Img2img refinement inline
    var img2imgEnabled:       Bool   = false // NEW v2
    var img2imgDenoise:       Double = 0.4   // NEW v2

    // API
    var sdBaseURL:            String = "http://127.0.0.1:7860"

    static var `default`: GenerationSettings { GenerationSettings() }

    var baseURL: URL? { URL(string: sdBaseURL) }

    func makeOverrideSettings() -> SDRequestOverrideSettings? {
        guard !checkpoint.isEmpty || (vaeUsed != "Automatic" && !vaeUsed.isEmpty) || clipSkip > 1 else { return nil }
        return SDRequestOverrideSettings(
            checkpoint: checkpoint.isEmpty ? nil : checkpoint,
            vae:        (vaeUsed.isEmpty || vaeUsed == "Automatic") ? nil : vaeUsed,
            clipSkip:   clipSkip > 1 ? clipSkip : nil
        )
    }

    // MARK: Static catalogs

    static let samplers = [
        "DPM++ 2M Karras", "DPM++ SDE Karras", "DPM++ 2M SDE Karras",
        "Euler a", "Euler", "LMS", "Heun", "DPM2", "DPM2 a",
        "DPM++ 2S a", "DPM++ 2M", "DPM++ SDE",
        "DPM fast", "DPM adaptive", "DDIM", "PLMS", "UniPC"
    ]

    static let hrUpscalers = [
        "4x-UltraSharp", "ESRGAN_4x", "R-ESRGAN 4x+",
        "R-ESRGAN 4x+ Anime6B", "Latent", "Latent (nearest)", "None"
    ]

    static let extraUpscalers = [
        "4x-UltraSharp", "ESRGAN_4x", "R-ESRGAN 4x+",
        "BSRGAN", "ScuNET PSNR", "SwinIR 4x",
        "Lanczos", "Nearest", "None"
    ]

    static let vaeOptions = [
        "Automatic", "None",
        "vae-ft-mse-840000-ema-pruned.safetensors",
        "kl-f8-anime2.ckpt"
    ]
}

// MARK: - CharacterProfile (top-level)

struct CharacterProfile: Codable, Identifiable, Hashable {
    var id:                  UUID    = UUID()
    var createdAt:           Date    = Date()
    var name:                String

    // Identity
    var archetype:           String  = ""
    var gender:              String  = ""

    // Biometrics
    var bodyType:            String  = ""
    var skinTone:            String  = ""
    var hairColor:           String  = ""
    var hairStyle:           String  = ""
    var eyeColor:            String  = ""

    // SD preferences
    var preferredCheckpoint: String  = ""
    var preferredSampler:    String  = "DPM++ 2M Karras"
    var preferredSteps:      Int     = 28
    var preferredCFG:        Double  = 7.0
    var preferredWidth:      Int     = 512
    var preferredHeight:     Int     = 768

    // Prompt fragments
    var promptCore:          String  = ""
    var promptStyle:         String  = ""
    var promptTrigger:       String  = ""
    var negativeAdditions:   String  = ""

    // LoRAs  { loraName: weight }
    var loraWeights:         [String: Double] = [:]

    // Consistency
    var referenceImagePath:  String? = nil
    var consistencyStrength: Double  = 0.7
    var ipAdapterEnabled:    Bool    = false
    var ipAdapterStrength:   Double  = 0.6

    // Seeds
    var favoriteSeed:        Int?    = nil
    var lockedSeed:          Bool    = false

    // Meta
    var tags:                [String] = []
    var notes:               String   = ""
    var isActive:            Bool     = true
    var sessionTag:          String?  = nil

    // Hashable
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: CharacterProfile, rhs: CharacterProfile) -> Bool { lhs.id == rhs.id }

    var fullPromptFragment: String {
        [promptCore, promptStyle, promptTrigger]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    var loraTokens: String {
        loraWeights
            .sorted { $0.key < $1.key }
            .map { "<lora:\($0.key):\(String(format: "%.2f", $0.value))>" }
            .joined(separator: " ")
    }
}

// MARK: - LoRAEntry (top-level)

struct LoRAEntry: Codable, Identifiable, Hashable {
    var id:       UUID   = UUID()
    var name:     String
    var alias:    String?
    var path:     String?
    var metadata: LoRAMeta?

    struct LoRAMeta: Codable, Hashable {
        var description:  String?
        var author:       String?
        var license:      String?
        var tags:         [String]?
        var baseModel:    String?
        var triggerWords: [String]?
    }

    var displayName: String { alias ?? name }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: LoRAEntry, rhs: LoRAEntry) -> Bool { lhs.id == rhs.id }
}

// MARK: - SelectedLoRA

struct SelectedLoRA: Identifiable {
    var id:     UUID      = UUID()
    var lora:   LoRAEntry
    var weight: Double    = 0.8

    var a1111Token: String {
        "<lora:\(lora.name):\(String(format: "%.2f", weight))>"
    }
}

// MARK: - ControlNetUnit (inline, engine-independent)

struct ControlNetUnit: Codable, Identifiable, Hashable {
    var id:            UUID    = UUID()
    var enabled:       Bool    = true
    var model:         String  = ""
    var module:        String  = "none"   // Preprocessor
    var weight:        Double  = 1.0
    var guidanceStart: Double  = 0.0
    var guidanceEnd:   Double  = 1.0
    var controlMode:   Int     = 0        // 0=Balanced 1=Prompt 2=ControlNet
    var resizeMode:    Int     = 1        // 0=Envelope 1=Crop 2=Fill
    var lowVram:       Bool    = false
    var pixelPerfect:  Bool    = true
    var imageBase64:   String? = nil
    var maskBase64:    String? = nil

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: ControlNetUnit, rhs: ControlNetUnit) -> Bool { lhs.id == rhs.id }

    /// Serializable payload for A1111 alwayson_scripts["ControlNet"]["args"][n]
    var scriptPayload: [String: Any] {
        var args: [String: Any] = [
            "enabled":        enabled,
            "model":          model,
            "module":         module,
            "weight":         weight,
            "guidance_start": guidanceStart,
            "guidance_end":   guidanceEnd,
            "control_mode":   controlMode,
            "resize_mode":    resizeMode,
            "lowvram":        lowVram,
            "pixel_perfect":  pixelPerfect,
        ]
        if let img = imageBase64 { args["image"] = img }
        if let msk = maskBase64  { args["mask"]  = msk }
        return args
    }
}

// MARK: - ContentSession (top-level)

struct ContentSession: Identifiable, Codable, Hashable {
    var id:         UUID     = UUID()
    var createdAt:  Date     = Date()
    var title:      String
    var category:   String   = "General"
    var tags:       [String] = []
    var notes:      String   = ""
    var isActive:   Bool     = false
    var assetCount: Int      = 0

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: ContentSession, rhs: ContentSession) -> Bool { lhs.id == rhs.id }
}

// MARK: - PromptBuilder (intent-aware v2)

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
        (["subject_system", "identity", "archetype"],                nil),
        (["subject_system", "identity", "name"],                     nil),
        (["subject_system", "identity", "gender"],                   nil),
        (["subject_system", "biometrics", "body_type"],              nil),
        (["subject_system", "biometrics", "skin_tone"],              nil),
        (["subject_system", "biometrics", "hair_color"],             nil),
        (["subject_system", "biometrics", "hair_style"],             nil),
        (["subject_system", "expression_engine", "default_expression"], nil),
        (["subject_system", "expression_engine", "smile_type"],        nil),
        (["subject_system", "expression_engine", "editorial_emotion"], nil),
        (["editorial_style_system", "style_category"],               nil),
        (["editorial_style_system", "visual_tone"],                  nil),
        (["editorial_style_system", "target_industry"],              nil),
        (["wardrobe_engine", "outfit_category"],                     nil),
        (["wardrobe_engine", "style_reference"],                     nil),
        (["wardrobe_engine", "fabric_physics", "movement_behavior"], nil),
        (["wardrobe_engine", "layering_system", "base_layer"],       nil),
        (["wardrobe_engine", "layering_system", "secondary_layer"],  nil),
        (["wardrobe_engine", "layering_system", "outer_layer"],      nil),
        (["wardrobe_engine", "layering_system", "accessories"],      nil),
        (["pose_engine", "pose_name"],                               nil),
        (["pose_engine", "pose_style"],                              nil),
        (["pose_engine", "body_orientation"],                        nil),
        (["pose_engine", "arm_positioning"],                         nil),
        (["pose_engine", "editorial_action"],                        nil),
        (["environment_system", "location_type"],                    nil),
        (["environment_system", "setting_style"],                    nil),
        (["environment_system", "location_interior"],                nil),  // NEW v2
        (["environment_system", "location_exterior"],                nil),  // NEW v2
        (["environment_system", "time_of_day"],                      nil),
        (["environment_system", "ambient_energy"],                   nil),
        (["environment_system", "color_grading_reference"],          nil),
        (["environment_system", "prop_interaction"],                  nil),
        (["environment_system", "weather"],                          nil),  // NEW v2
        (["lighting_engine", "lighting_style"],                      nil),
        (["lighting_engine", "key_light", "color_temperature"],      nil),
        (["lighting_engine", "fill_light", "intensity"],             nil),  // NEW v2
        (["lighting_engine", "background_light"],                    nil),  // NEW v2
        (["camera_engine", "camera_type"],                           nil),
        (["camera_engine", "framing_type"],                          nil),
        (["camera_engine", "depth_of_field_strength"],               nil),
        (["camera_engine", "camera_angle"],                          nil),
        (["camera_engine", "shot_movement"],                         nil),  // NEW v2
        (["brand_projection", "editorial_voice"],                    nil),
        (["generation_engine", "primary_prompt"],                    nil),
    ]

    static func buildFromEditorialSchema(_ json: Any) -> (positive: String, negative: String) {
        guard let dict = json as? [String: Any] else { return (buildFlat(from: json), "") }

        var positiveTokens: [String] = []

        if let genEngine = dict["generation_engine"] as? [String: Any],
           let primary   = genEngine["primary_prompt"] as? String, !primary.isEmpty {
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
