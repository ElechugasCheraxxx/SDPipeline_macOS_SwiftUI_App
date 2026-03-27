import Foundation
import SwiftUI
import CoreData

// MARK: - Models_Extended.swift v4
//
// REGLA ESTRICTA: nada declarado aquí puede ya existir en otro archivo.
// Archivos auditados antes de escribir esto:
//   NSImage_Helpers.swift   → pngData(), resized(maxDimension:), cgImageSafe
//   View_Helpers.swift      → String.truncated(_:), Date.shortDisplay, Date.filenameDate
//   Data_Crypto.swift       → Data.sha256Hex
//   ReusableSettings.swift  → struct ReusableSettings + init(from asset:)
//   AssetStore.swift        → assets(withStatus:limit:), fetchAllAssets(limit:)
//   CharacterEngine.swift   → CharacterProfile es top-level struct (NO nested en CharacterEngine)

// MARK: - SDRequest convenience factory

extension SDRequest {

    /// Build from GenerationSettings + resolved prompt.
    /// Usado en PipelineConnector, BatchEngine, XYPlotEngine, JobQueueManager.
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

    /// Variante img2img: deshabilita HR fix y permite override de dimensiones.
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

    /// Resumen en una línea para labels de jobs, logs, etc.
    var summaryLabel: String {
        "\(width)×\(height) · \(steps)s · CFG\(String(format: "%.1f", cfgScale)) · \(samplerName)"
    }

    var seedDisplay: String {
        seed == -1 ? "Random" : "\(seed)"
    }

    var hiresLabel: String {
        enableHR ? "×\(String(format: "%.1f", hrScale)) Hires" : "No Hires"
    }

    /// Aplica el checkpoint y resolución preferidos de un personaje.
    mutating func applyCharacterDefaults(_ character: CharacterProfile) {
        if !character.preferredCheckpoint.isEmpty {
            checkpoint = character.preferredCheckpoint
        }
    }
}

// MARK: - GeneratedAsset display helpers
// GeneratedAsset está declarado en AssetStore.swift como NSManagedObject.
// Solo se añaden computed helpers que NO existen allí.

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
        if secs < 60    { return "Just now" }
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

    var loraWeights: [String: Double] {
        guard let json = loraWeightsJSON,
              let data = json.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: Double].self, from: data)
        else { return [:] }
        return dict
    }

    var tagList: [String] {
        guard let t = tags, !t.isEmpty else { return [] }
        return t.split(separator: ",").map { $0.trimmingCharacters(in: .whitespace) }
    }
}

// MARK: - AssetStore extra queries
// assets(withStatus:) ya existe en AssetStore.swift. Solo se añaden los que faltan.

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
// LoRAManager.swift declara SelectedLoRA: Identifiable sin Codable.

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
// shortDisplay y filenameDate ya existen en View_Helpers.swift. Solo se añaden los que faltan.

extension Date {

    /// "2 hours ago", "3d ago", etc. — NO existe en View_Helpers.swift
    var relativeLabel: String {
        let secs = -timeIntervalSinceNow
        switch secs {
        case ..<60:      return "just now"
        case ..<3600:    return "\(Int(secs / 60))m ago"
        case ..<86400:   return "\(Int(secs / 3600))h ago"
        case ..<604800:  return "\(Int(secs / 86400))d ago"
        default:         return shortDisplay    // usa el de View_Helpers.swift
        }
    }

    /// "2025-03-13" (ISO date only, distinto de filenameDate que usa formato similar)
    var isoDateOnly: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: self)
    }
}

// MARK: - String extra helpers
// truncated(_:) ya existe en View_Helpers.swift. Solo los que faltan.

extension String {

    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var wordCount: Int { split(separator: " ").count }

    var tokenCount: Int { split(separator: ",").count }
}

// MARK: - UserDefaults Codable helpers

extension UserDefaults {

    func encode<T: Encodable>(_ value: T, forKey key: String) {
        guard let data = try? JSONEncoder.compact.encode(value) else { return }
        set(data, forKey: key)
    }

    func decode<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = data(forKey: key) else { return nil }
        return try? JSONDecoder.iso8601.decode(type, from: data)
    }

    func setDate(_ date: Date?, forKey key: String) {
        if let date { set(date.timeIntervalSince1970, forKey: key) }
        else        { removeObject(forKey: key) }
    }

    func date(forKey key: String) -> Date? {
        let t = double(forKey: key)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }
}

// MARK: - ReusableSettings static factory
// ReusableSettings struct y init(from asset:) ya existen en ReusableSettings.swift.
// Solo se agrega el static factory que construye desde los campos sueltos.

extension ReusableSettings {

    static func from(asset: GeneratedAsset) -> ReusableSettings {
        ReusableSettings(from: asset)   // usa el init(from:) de ReusableSettings.swift
    }
}
