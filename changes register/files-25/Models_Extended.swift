import Foundation
import SwiftUI

// MARK: - Img2ImgSettings
// Configuración para el pipeline de refinamiento img2img.
// Referenciada en RightPanelView bottomBar → Img2ImgEngine.shared.refine()

struct Img2ImgSettings: Codable {
    var denoisingStrength: Double  = 0.40
    var steps:             Int     = 28
    var cfgScale:          Double  = 7.0
    var samplerName:       String  = "DPM++ 2M Karras"
    var width:             Int     = 0     // 0 = usar dimensiones de la imagen origen
    var height:            Int     = 0
    var resizeMode:        Int     = 0     // 0=just resize, 1=crop/resize, 2=resize/fill
    var restoreFaces:      Bool    = false
    var seed:              Int     = -1
    var mask:              String? = nil   // base64 PNG de máscara para inpainting
    var inpaintFill:       Int     = 0     // 0=fill, 1=original, 2=latent noise, 3=latent nothing
    var inpaintingMaskInvert: Int  = 0
    var inpaintingFill:    Int     = 1

    // Hires fix para img2img
    var enableHR:          Bool    = false
    var hrScale:           Double  = 2.0
    var hrUpscaler:        String  = "4x-UltraSharp"
    var hrSteps:           Int     = 15

    // Presets rápidos
    static let refine        = Img2ImgSettings(denoisingStrength: 0.40, steps: 28)
    static let subtle        = Img2ImgSettings(denoisingStrength: 0.20, steps: 20)
    static let aggressive    = Img2ImgSettings(denoisingStrength: 0.65, steps: 35)
    static let faceRestore   = Img2ImgSettings(denoisingStrength: 0.35, steps: 28, restoreFaces: true)
    static let upscaleRefine = Img2ImgSettings(denoisingStrength: 0.40, steps: 28, enableHR: true, hrScale: 2.0)

    init(
        denoisingStrength: Double = 0.40,
        steps:             Int    = 28,
        cfgScale:          Double = 7.0,
        samplerName:       String = "DPM++ 2M Karras",
        width:             Int    = 0,
        height:            Int    = 0,
        resizeMode:        Int    = 0,
        restoreFaces:      Bool   = false,
        seed:              Int    = -1,
        enableHR:          Bool   = false,
        hrScale:           Double = 2.0,
        hrUpscaler:        String = "4x-UltraSharp",
        hrSteps:           Int    = 15
    ) {
        self.denoisingStrength = denoisingStrength
        self.steps             = steps
        self.cfgScale          = cfgScale
        self.samplerName       = samplerName
        self.width             = width
        self.height            = height
        self.resizeMode        = resizeMode
        self.restoreFaces      = restoreFaces
        self.seed              = seed
        self.enableHR          = enableHR
        self.hrScale           = hrScale
        self.hrUpscaler        = hrUpscaler
        self.hrSteps           = hrSteps
    }
}

// MARK: - LoRA Models
// LoRAEntry y SelectedLoRA — usados en LoRAManager y PipelineConnector

struct LoRAEntry: Codable, Identifiable, Hashable {
    var id:          UUID    = UUID()
    var name:        String           // Nombre del archivo sin extensión
    var alias:       String?          // Alias alternativo
    var path:        String  = ""
    var promptKey:   String           // Token para incrustar en el prompt: <lora:name:weight>
    var tags:        [String] = []
    var isPrivate:   Bool    = false  // LoRA privado (en PrivateLoRAs/)

    var promptToken: String { "<lora:\(promptKey):\(_defaultWeight)>" }

    private var _defaultWeight: Double = 0.8

    func hash(into hasher: inout Hasher) { hasher.combine(name) }
    static func == (lhs: LoRAEntry, rhs: LoRAEntry) -> Bool { lhs.name == rhs.name }
}

struct SelectedLoRA: Codable, Identifiable {
    var id:     UUID     = UUID()
    var lora:   LoRAEntry
    var weight: Double   = 0.8

    var promptFragment: String {
        "<lora:\(lora.promptKey):\(String(format: "%.2f", weight))>"
    }
}

// MARK: - GPU PreCheck Status

enum GPUPreCheckStatus: Equatable {
    case ok
    case warning(String)
    case critical(String)
    case unknown

    static func == (lhs: GPUPreCheckStatus, rhs: GPUPreCheckStatus) -> Bool {
        switch (lhs, rhs) {
        case (.ok, .ok), (.unknown, .unknown): return true
        case (.warning(let a), .warning(let b)): return a == b
        case (.critical(let a), .critical(let b)): return a == b
        default: return false
        }
    }
}

// MARK: - Asset Color extension (needed by AssetStore)

extension Color {
    // Forward declaration used in AssetStatus.color
    // The actual Color(hex:) initializer is in Color+Hex.swift
}

// MARK: - QueueJob (referenced in JobQueueView)

struct QueueJob: Identifiable, Codable {
    var id:           UUID         = UUID()
    var type:         QueueJobType
    var title:        String
    var priority:     JobPriority  = .normal
    var status:       JobStatus    = .queued
    var progress:     Double?      = nil    // 0.0-1.0 cuando está running
    var retryCount:   Int          = 0
    var maxRetries:   Int          = 3
    var createdAt:    Date         = Date()
    var startedAt:    Date?        = nil
    var completedAt:  Date?        = nil
    var errorMessage: String?      = nil
    var metadata:     [String: String] = [:]
}

enum JobStatus: String, Codable, CaseIterable {
    case queued    = "queued"
    case running   = "running"
    case completed = "completed"
    case failed    = "failed"
    case cancelled = "cancelled"

    var label: String {
        switch self {
        case .queued:    return "En espera"
        case .running:   return "Ejecutando"
        case .completed: return "Completado"
        case .failed:    return "Fallido"
        case .cancelled: return "Cancelado"
        }
    }
}

// MARK: - ContentSession extensions (TargetPlatform)

extension ContentSessionManager {
    enum TargetPlatform: String, Codable, CaseIterable {
        case onlyfans  = "OnlyFans"
        case instagram = "Instagram"
        case twitter   = "Twitter/X"
        case fansly    = "Fansly"
        case patreon   = "Patreon"
        case private_  = "Archivo privado"
    }

    enum SessionCategory: String, Codable, CaseIterable {
        case editorial   = "Editorial"
        case character   = "Personaje"
        case campaign    = "Campaña"
        case experimental = "Experimental"
        case bts         = "BTS"
        case lifestyle   = "Lifestyle"
    }
}

// MARK: - SDRequest helpers

extension SDRequest {
    /// Build SDRequest from GenerationSettings
    static func from(settings: GenerationSettings, prompt: String) -> SDRequest {
        SDRequest(
            prompt:            prompt,
            negativePrompt:    settings.negativePrompt,
            seed:              settings.seed,
            steps:             settings.steps,
            cfgScale:          settings.cfgScale,
            width:             settings.width,
            height:            settings.height,
            samplerName:       settings.samplerName,
            enableHR:          settings.enableHR,
            hrUpscaler:        settings.hrUpscaler,
            hrScale:           settings.hrScale,
            hrSecondPassSteps: settings.hrSteps,
            denoisingStrength: settings.denoisingStrength,
            restoreFaces:      settings.restoreFaces
        )
    }
}
