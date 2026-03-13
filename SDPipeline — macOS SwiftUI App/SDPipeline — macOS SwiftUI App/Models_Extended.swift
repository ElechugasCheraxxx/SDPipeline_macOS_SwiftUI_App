import Foundation
import SwiftUI
import CoreData

// MARK: - Models_Extended.swift v5 (Corregido para escalabilidad)

// MARK: - SDRequest convenience factory
extension SDRequest {
    static func from(
        settings:        GenerationSettings,
        prompt:          String,
        negativeOverride: String? = nil
    ) -> SDRequest {
        SDRequest(
            prompt:            prompt,
            negativePrompt:    negativeOverride ?? settings.negativePrompt,
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

    static func img2imgBase(
        settings: GenerationSettings,
        prompt:   String,
        width:    Int? = nil,
        height:   Int? = nil
    ) -> SDRequest {
        var req = from(settings: settings, prompt: prompt)
        if let w = width  { req.width  = w }
        if let h = height { req.height = h }
        req.enable_hr = false
        return req
    }
}

// MARK: - GenerationSettings convenience
extension GenerationSettings {
    var summaryLabel: String {
        "\(width)×\(height) · \(steps)s · CFG\(String(format: "%.1f", cfgScale)) · \(samplerName)"
    }

    var seedDisplay: String {
        seed == -1 ? "Random" : "\(seed)"
    }

    var hiresLabel: String {
        enableHR ? "×\(String(format: "%.1f", hrScale)) Hires" : "No Hires"
    }

    mutating func applyCharacterDefaults(_ character: CharacterProfile) {
        if !character.preferredCheckpoint.isEmpty {
            checkpoint = character.preferredCheckpoint
        }
    }
}

// MARK: - GeneratedAsset display helpers
extension GeneratedAsset {
    var displayTitle: String {
        baseName ?? id?.uuidString.prefix(8).description ?? "Untitled"
    }

    var resolutionLabel: String {
        "\(width)×\(height)"
    }

    var promptPreview: String {
        let p = promptPositive ?? ""
        return p.count > 80 ? String(p.prefix(80)) + "…" : p
    }

    var modelLabel: String {
        let cp = checkpoint ?? ""
        let mn = modelName ?? ""
        return cp.isEmpty ? (mn.isEmpty ? "Unknown model" : mn) : cp
    }

    var ageLabel: String {
        guard let date = createdAt else { return "—" }
        let secs = -date.timeIntervalSinceNow
        if secs < 60  { return "Just now" }
        if secs < 3600  { return "\(Int(secs / 60))m ago" }
        if secs < 86400 { return "\(Int(secs / 3600))h ago" }
        return "\(Int(secs / 86400))d ago"
    }

    var ratingColor: Color {
        switch rating {
        case 5:  return Color(hex: "#fbbf24")
        case 4:  return Color(hex: "#f59e0b")
        case 3:  return Color(hex: "#d97706")
        case 2:  return Color(hex: "#9ca3af")
        default: return Color(hex: "#6b7280")
        }
    }

    func setTagList(_ list: [String]) {
        tags = list.joined(separator: ",")
    }

    var tagList: [String] {
        guard let t = tags, !t.isEmpty else { return [] }
        return t.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    var absoluteImageURL: URL? {
        guard let path = imagePath,
              let root = VaultManager.shared.vaultRoot else { return nil }
        return root.appending(path: path)
    }

    var absoluteCleanURL: URL? {
        guard let path = cleanPath,
              let root = VaultManager.shared.vaultRoot else { return nil }
        return root.appending(path: path)
    }
}

// MARK: - AssetStore extra queries
extension AssetStore {
    func assets(forCharacter characterID: UUID, limit: Int = 100) -> [GeneratedAsset] {
        fetchAllAssets(limit: limit).filter { $0.characterID == characterID }
    }

    func assets(forSessionTag tag: String, limit: Int = 200) -> [GeneratedAsset] {
        fetchAllAssets(limit: limit).filter { $0.sessionTag == tag }
    }

    var averageRating: Double {
        let rated = fetchAllAssets(limit: 500).filter { $0.rating > 0 }
        guard !rated.isEmpty else { return 0 }
        return Double(rated.reduce(0) { $0 + Int($1.rating) }) / Double(rated.count)
    }

    func topSeeds(limit: Int = 10) -> [(seed: Int64, count: Int)] {
        var counts: [Int64: Int] = [:]
        for asset in fetchAllAssets(limit: 500) where asset.seed > 0 {
            counts[asset.seed, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }
            .prefix(limit)
            .map { (seed: $0.key, count: $0.value) }
    }

    func checkpointDistribution(limit: Int = 500) -> [(checkpoint: String, count: Int)] {
        var counts: [String: Int] = [:]
        for asset in fetchAllAssets(limit: limit) {
            let cp = asset.checkpoint ?? asset.modelName ?? "Unknown"
            counts[cp, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }
            .map { (checkpoint: $0.key, count: $0.value) }
    }
}

// MARK: - GPUPreCheckStatus typealias
typealias GPUPreCheckStatus = GPUMonitor.PreCheckStatus

// MARK: - SelectedLoRA Codable conformance
extension SelectedLoRA: Codable {
    enum CodingKeys: String, CodingKey { case id, lora, weight }

    public init(from decoder: Decoder) throws {
        let c       = try decoder.container(keyedBy: CodingKeys.self)
        self.id     = try c.decodeIfPresent(UUID.self,   forKey: .id)     ?? UUID()
        self.lora   = try c.decode(LoRAEntry.self,        forKey: .lora)
        self.weight = try c.decodeIfPresent(Double.self,  forKey: .weight) ?? 0.8
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id,     forKey: .id)
        try c.encode(lora,   forKey: .lora)
        try c.encode(weight, forKey: .weight)
    }
}

// MARK: - Date extra helpers
extension Date {
    var relativeLabel: String {
        let secs = -timeIntervalSinceNow
        switch secs {
        case ..<60:      return "just now"
        case ..<3600:    return "\(Int(secs / 60))m ago"
        case ..<86400:   return "\(Int(secs / 3600))h ago"
        case ..<604800:  return "\(Int(secs / 86400))d ago"
        default:         return shortDisplay
        }
    }

    var isoDateOnly: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: self)
    }
}

// MARK: - String extra helpers
extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var wordCount: Int { split(separator: " ").count }
    var tokenCount: Int { split(separator: ",").count }
}

// MARK: - ReusableSettings static factory
extension ReusableSettings {
    static func from(asset: GeneratedAsset) -> ReusableSettings {
        // Mapeo seguro y explícito de los valores del asset al struct.
        ReusableSettings(
            promptPositive: asset.promptPositive ?? "",
            promptNegative: asset.promptNegative ?? "",
            seed: Int(asset.seed),
            steps: Int(asset.steps),
            cfgScale: asset.cfgScale,
            samplerName: asset.samplerName ?? "DPM++ 2M Karras",
            width: Int(asset.width),
            height: Int(asset.height),
            checkpoint: asset.checkpoint ?? ""
        )
    }
}
