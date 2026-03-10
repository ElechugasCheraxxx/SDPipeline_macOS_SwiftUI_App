import Foundation
import SwiftUI

// MARK: - Models_Extended.swift
//
// SOLO contiene tipos que NO están declarados en ningún otro archivo.
//
// ❌ ELIMINADO (ya existen en sus archivos):
//   • LoRAEntry, SelectedLoRA         → LoRAManager.swift
//   • Img2ImgSettings, JobStatus(img2img) → Img2ImgEngine.swift
//   • QueueJob, JobStatus(queue)      → JobQueueManager.swift
//   • ContentSessionManager.TargetPlatform, .SessionCategory → ContentSessionManager.swift
//   • GPUPreCheckStatus               → GPUMonitor.PreCheckStatus
//
// ✅ AÑADIDO (realmente faltaba):
//   • SDRequest.from(settings:prompt:) convenience
//   • SelectedLoRA: Codable conformance (original no la tiene)
//   • GPUPreCheckStatus typealias (para evitar prefijo GPUMonitor. en todo el código)

// MARK: - SDRequest convenience

extension SDRequest {
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

// MARK: - SelectedLoRA Codable
// LoRAManager.swift declara SelectedLoRA: Identifiable (sin Codable).
// Extension aquí agrega Codable para persistencia en ProjectManager y otros.

extension SelectedLoRA: Codable {
    enum CodingKeys: String, CodingKey { case id, lora, weight }

    public init(from decoder: Decoder) throws {
        let c   = try decoder.container(keyedBy: CodingKeys.self)
        self.id     = try c.decodeIfPresent(UUID.self,       forKey: .id)     ?? UUID()
        self.lora   = try c.decode(LoRAEntry.self,           forKey: .lora)
        self.weight = try c.decodeIfPresent(Double.self,     forKey: .weight) ?? 0.8
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id,     forKey: .id)
        try c.encode(lora,   forKey: .lora)
        try c.encode(weight, forKey: .weight)
    }
}

// MARK: - GPUPreCheckStatus typealias
// Evita escribir GPUMonitor.PreCheckStatus en PipelineConnector, ContentView, etc.

typealias GPUPreCheckStatus = GPUMonitor.PreCheckStatus
