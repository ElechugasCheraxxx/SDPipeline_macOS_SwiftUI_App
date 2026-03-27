import Foundation
import SwiftUI
import CoreData

// MARK: - Models_Extended.swift v3
// Solo contiene tipos y extensiones NO declarados en otros archivos.
// Regla: si ya existe en su archivo de origen, NO se redeclara aquí.

// MARK: - SDRequest convenience factory

extension SDRequest {
    /// Build from GenerationSettings + resolved prompt (uso frecuente en PipelineConnector, BatchEngine, etc.)
    static func from(settings: GenerationSettings, prompt: String, negativeOverride: String? = nil) -> SDRequest {
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

    /// Build a minimal request for img2img (overrides width/height with reference image dims)
    static func img2imgBase(settings: GenerationSettings, prompt: String, width: Int? = nil, height: Int? = nil) -> SDRequest {
        var req = from(settings: settings, prompt: prompt)
        if let w = width  { req.width  = w }
        if let h = height { req.height = h }
        req.enable_hr = false // Hires disabled for img2img
        return req
    }
}

// MARK: - GenerationSettings convenience

extension GenerationSettings {
    /// Returns a human-readable summary for display in job rows, logs, etc.
    var summaryLabel: String {
        "\(width)×\(height) · \(steps)s · CFG\(String(format:"%.1f", cfgScale)) · \(samplerName)"
    }

    var seedDisplay: String {
        seed == -1 ? "Random" : "\(seed)"
    }

    var hiresLabel: String {
        enableHR ? "×\(String(format: "%.1f", hrScale)) Hires" : "No Hires"
    }

    mutating func applyCharacterDefaults(_ character: CharacterEngine.CharacterProfile) {
        if !character.preferredCheckpoint.isEmpty { checkpoint = character.preferredCheckpoint }
        if character.preferredWidth  > 0 { width  = character.preferredWidth  }
        if character.preferredHeight > 0 { height = character.preferredHeight }
    }
}

// MARK: - GeneratedAsset helpers

extension GeneratedAsset {

    // MARK: Thumbnail loading (lazy, cache-friendly)

    /// Load thumbnail NSImage from disk (synchronous — call from background or use async variant).
    func loadThumbnail(maxDimension: CGFloat = 200) -> NSImage? {
        guard let url = absoluteImageURL,
              let image = NSImage(contentsOf: url) else { return nil }
        return image.resized(toMaxDimension: maxDimension)
    }

    // MARK: Rating helpers

    func starLabel(filled: Bool = true) -> String {
        let filled = (0..<Int(rating)).map { _ in "★" }.joined()
        let empty  = (Int(rating)..<5).map { _ in "☆" }.joined()
        return filled + empty
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

    // MARK: Age helpers

    var ageLabel: String {
        guard let date = createdAt else { return "—" }
        let secs = -date.timeIntervalSinceNow
        if secs < 60    { return "Just now" }
        if secs < 3600  { return "\(Int(secs / 60))m ago" }
        if secs < 86400 { return "\(Int(secs / 3600))h ago" }
        return "\(Int(secs / 86400))d ago"
    }

    var dateLabel: String {
        guard let date = createdAt else { return "—" }
        return date.shortDisplay
    }

    // MARK: Prompt preview

    var promptPreview: String {
        let p = promptPositive ?? ""
        return p.count > 80 ? String(p.prefix(80)) + "…" : p
    }

    var modelLabel: String {
        checkpoint?.isEmpty == false ? checkpoint! : (modelName ?? "Unknown model")
    }
}

// MARK: - AssetStore helpers

extension AssetStore {

    /// Fetch all assets with optional status filter and limit.
    func assets(withStatus status: AssetStatus, limit: Int = 100) -> [GeneratedAsset] {
        fetchAllAssets(limit: limit).filter { $0.statusEnum == status }
    }

    /// Fetch assets by characterID.
    func assets(forCharacter characterID: UUID, limit: Int = 100) -> [GeneratedAsset] {
        fetchAllAssets(limit: limit).filter { $0.characterID == characterID }
    }

    /// Fetch assets by session tag.
    func assets(forSessionTag tag: String, limit: Int = 200) -> [GeneratedAsset] {
        fetchAllAssets(limit: limit).filter { $0.sessionTag == tag }
    }

    /// Top seeds used (for SeedManager dashboard).
    func topSeeds(limit: Int = 10) -> [(seed: Int64, count: Int)] {
        let assets = fetchAllAssets(limit: 500)
        var counts: [Int64: Int] = [:]
        for asset in assets where asset.seed > 0 {
            counts[asset.seed, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }
            .prefix(limit)
            .map { (seed: $0.key, count: $0.value) }
    }

    /// Average rating across all rated assets.
    var averageRating: Double {
        let rated = fetchAllAssets(limit: 500).filter { $0.rating > 0 }
        guard !rated.isEmpty else { return 0 }
        return Double(rated.reduce(0) { $0 + Int($1.rating) }) / Double(rated.count)
    }

    /// Checkpoint usage distribution.
    func checkpointDistribution(limit: Int = 500) -> [(checkpoint: String, count: Int)] {
        let assets = fetchAllAssets(limit: limit)
        var counts: [String: Int] = [:]
        for asset in assets {
            let cp = asset.checkpoint ?? asset.modelName ?? "Unknown"
            counts[cp, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }.map { (checkpoint: $0.key, count: $0.value) }
    }
}

// MARK: - GPUPreCheckStatus typealias

/// Convenience typealias so callers don't need `GPUMonitor.PreCheckStatus` prefix everywhere.
typealias GPUPreCheckStatus = GPUMonitor.PreCheckStatus

// MARK: - SelectedLoRA Codable conformance
// LoRAManager.swift declares SelectedLoRA: Identifiable without Codable.
// This extension adds persistence support for ProjectManager and CharacterEngine.

extension SelectedLoRA: Codable {
    enum CodingKeys: String, CodingKey { case id, lora, weight }

    public init(from decoder: Decoder) throws {
        let c   = try decoder.container(keyedBy: CodingKeys.self)
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

// MARK: - Date helpers

extension Date {
    /// "Mar 13 · 14:22" style
    var shortDisplay: String {
        let f = DateFormatter()
        f.dateFormat = "MMM d · HH:mm"
        return f.string(from: self)
    }

    /// "2025-03-13" ISO date only
    var isoDateOnly: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: self)
    }

    /// "2 hours ago", "3 days ago", etc.
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
}

// MARK: - String helpers

extension String {
    func truncated(_ maxLength: Int, ellipsis: String = "…") -> String {
        count > maxLength ? String(prefix(maxLength)) + ellipsis : self
    }

    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Simple word count for prompt analysis.
    var wordCount: Int { split(separator: " ").count }

    /// Comma-separated token count (for prompt tokens).
    var tokenCount: Int { split(separator: ",").count }
}

// MARK: - NSImage helpers

extension NSImage {
    func resized(toMaxDimension maxDim: CGFloat) -> NSImage {
        let originalSize = size
        let ratio = min(maxDim / originalSize.width, maxDim / originalSize.height)
        guard ratio < 1 else { return self }
        let newSize = NSSize(width: originalSize.width * ratio, height: originalSize.height * ratio)
        let new = NSImage(size: newSize)
        new.lockFocus()
        draw(in: NSRect(origin: .zero, size: newSize),
             from: NSRect(origin: .zero, size: originalSize),
             operation: .copy, fraction: 1.0)
        new.unlockFocus()
        return new
    }

    func pngData() -> Data? {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .png, properties: [:])
    }

    var pixelSize: NSSize {
        guard let rep = representations.first else { return size }
        return NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }
}

// MARK: - Data SHA-256 helper

extension Data {
    var sha256Hex: String {
        // Requires CryptoKit — imported in AssetStore.swift
        // This is a thin wrapper to avoid importing CryptoKit in every file
        import CryptoKit
        return SHA256.hash(data: self).compactMap { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Color hex initializer (cross-reference with Color_Hex.swift)
// Already declared in Color_Hex.swift — do NOT redeclare.
// Extension here is a compile-time reminder only — remove if causes duplicate.

// MARK: - UserDefaults typed helpers

extension UserDefaults {
    func setDate(_ date: Date?, forKey key: String) {
        if let date { set(date.timeIntervalSince1970, forKey: key) }
        else        { removeObject(forKey: key) }
    }

    func date(forKey key: String) -> Date? {
        let t = double(forKey: key)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }
}

// MARK: - ReusableSettings from GeneratedAsset

extension ReusableSettings {
    /// Build ReusableSettings from a GeneratedAsset (for "Reuse Settings" in Gallery/Inspector).
    static func from(asset: GeneratedAsset) -> ReusableSettings {
        ReusableSettings(
            promptPositive: asset.promptPositive ?? "",
            promptNegative: asset.promptNegative ?? "",
            seed:           Int(asset.seed),
            steps:          Int(asset.steps),
            cfgScale:       asset.cfgScale,
            samplerName:    asset.samplerName ?? "DPM++ 2M Karras",
            width:          Int(asset.width),
            height:         Int(asset.height),
            checkpoint:     asset.checkpoint ?? ""
        )
    }
}
