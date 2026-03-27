import Foundation
import SwiftUI
import Combine
import CoreData
import NaturalLanguage

// MARK: - TaggingEngine v2
//
// Motor de tags persistente y bidireccional para la galería.
//   - Index en memoria: O(1) add/remove/query
//   - Persistencia dual: JSON (rápido) + Core Data (GeneratedAsset.tags)
//   - Extracción automática de keywords desde prompts SD
//   - Sugerencias por ML (NLTagger) + frecuencia global
//   - Búsqueda AND/OR/NOT con ranking por relevancia
//   - Tag cloud paginada y ordenable
//   - Merge de tags al importar assets externos
//
// ROADMAP: "Buscador por tags con filtros" (🟠 CORTO PLAZO) — COMPLETADO

@MainActor
final class TaggingEngine: ObservableObject {

    static let shared = TaggingEngine()
    private init() { loadIndex() }

    // MARK: - Models

    struct TagItem: Identifiable, Comparable {
        let id = UUID()
        let tag:   String
        let count: Int
        static func < (lhs: TagItem, rhs: TagItem) -> Bool { lhs.count > rhs.count }
    }

    struct TagSearchResult: Identifiable {
        let id = UUID()
        let assetID: String
        let relevance: Double       // 0-1, basado en cuántos tags coinciden
    }

    enum SearchMode { case and, or, not }

    // MARK: - Index

    @Published var index:        [String: Set<String>] = [:]   // assetUUID → tags
    @Published var tagFrequency: [String: Int]  = [:]           // tag → count global
    @Published var topTags:      [TagItem]       = []

    private let indexQueue = DispatchQueue(label: "studio.tagging.index", qos: .utility)

    // MARK: - Public API — Tags de un asset

    func tags(for asset: GeneratedAsset) -> [String] {
        guard let id = asset.id?.uuidString else { return [] }
        // Fuente de verdad: Core Data (sincronizado). Fallback: índice en memoria.
        if let storedTags = asset.tags, !storedTags.isEmpty {
            return storedTags.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.sorted()
        }
        return (index[id] ?? []).sorted()
    }

    // MARK: - Add / Remove

    @discardableResult
    func addTag(_ tag: String, to asset: GeneratedAsset) -> Bool {
        guard let id = asset.id?.uuidString else { return false }
        let normalized = normalizeTag(tag)
        guard !normalized.isEmpty, normalized.count <= 64 else { return false }

        if index[id] == nil { index[id] = [] }
        let inserted = index[id]!.insert(normalized).inserted
        guard inserted else { return false }

        tagFrequency[normalized, default: 0] += 1
        syncToAsset(asset, id: id)
        saveIndex()
        refreshTopTags()
        return true
    }

    func addTags(_ tags: [String], to asset: GeneratedAsset) {
        tags.forEach { addTag($0, to: asset) }
    }

    func removeTag(_ tag: String, from asset: GeneratedAsset) {
        guard let id = asset.id?.uuidString else { return }
        let normalized = normalizeTag(tag)
        guard index[id]?.remove(normalized) != nil else { return }
        tagFrequency[normalized, default: 1] -= 1
        if tagFrequency[normalized, default: 0] <= 0 { tagFrequency.removeValue(forKey: normalized) }
        syncToAsset(asset, id: id)
        saveIndex()
        refreshTopTags()
    }

    func setTags(_ tags: [String], for asset: GeneratedAsset) {
        guard let id = asset.id?.uuidString else { return }
        // Decrementar frecuencias de tags viejos
        if let old = index[id] {
            for t in old { tagFrequency[t, default: 1] -= 1 }
        }
        let normalized = Set(tags.map { normalizeTag($0) }.filter { !$0.isEmpty })
        index[id] = normalized
        for t in normalized { tagFrequency[t, default: 0] += 1 }
        syncToAsset(asset, id: id)
        saveIndex()
        refreshTopTags()
    }

    // MARK: - Auto-extract from Prompt

    /// Extrae tags relevantes del prompt SD usando heurísticas + NLTagger.
    func autoExtract(from prompt: String) -> [String] {
        var tags: Set<String> = []

        // 1. Palabras clave SD conocidas (quality, style, lighting, etc.)
        let sdKeywords = Self.sdKeywordSet
        let words = prompt.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 }
        for word in words {
            if sdKeywords.contains(word) { tags.insert(word) }
        }

        // 2. NLTagger para entidades (lugar, persona, organización → tags de escena)
        let tagger = NLTagger(tagSchemes: [.nameType, .lexicalClass])
        tagger.string = prompt
        tagger.enumerateTags(in: prompt.startIndex..<prompt.endIndex, unit: .word,
                              scheme: .nameType, options: [.omitWhitespace, .omitPunctuation]) { tag, range in
            if let tag, [.personalName, .placeName, .organizationName].contains(tag) {
                tags.insert(normalizeTag(String(prompt[range])))
            }
            return true
        }

        // 3. Extracción de tokens entre paréntesis/corchetes (LoRA triggers, emphasis)
        let parenPattern = try? NSRegularExpression(pattern: #"\(([^)]+)\)"#)
        let bracketPattern = try? NSRegularExpression(pattern: #"\[([^\]]+)\]"#)
        for pattern in [parenPattern, bracketPattern].compactMap({ $0 }) {
            let matches = pattern.matches(in: prompt, range: NSRange(prompt.startIndex..., in: prompt))
            for match in matches {
                if let range = Range(match.range(at: 1), in: prompt) {
                    let token = String(prompt[range])
                        .components(separatedBy: ":").first ?? ""
                    let t = normalizeTag(token)
                    if t.count >= 3 { tags.insert(t) }
                }
            }
        }

        return Array(tags).sorted()
    }

    func autoTagAsset(_ asset: GeneratedAsset) {
        let prompt = asset.promptPositive ?? ""
        let extracted = autoExtract(from: prompt)
        addTags(extracted, to: asset)
    }

    // MARK: - Search

    func search(tags: [String], mode: SearchMode = .and) -> [TagSearchResult] {
        let normalized = tags.map { normalizeTag($0) }.filter { !$0.isEmpty }
        guard !normalized.isEmpty else {
            return index.map { TagSearchResult(assetID: $0.key, relevance: 1.0) }
        }

        var results: [TagSearchResult] = []
        for (assetID, assetTags) in index {
            let matchCount = normalized.filter { assetTags.contains($0) }.count
            switch mode {
            case .and:
                if matchCount == normalized.count {
                    results.append(TagSearchResult(assetID: assetID,
                                                   relevance: Double(matchCount) / Double(normalized.count)))
                }
            case .or:
                if matchCount > 0 {
                    results.append(TagSearchResult(assetID: assetID,
                                                   relevance: Double(matchCount) / Double(normalized.count)))
                }
            case .not:
                if matchCount == 0 {
                    results.append(TagSearchResult(assetID: assetID, relevance: 1.0))
                }
            }
        }
        return results.sorted { $0.relevance > $1.relevance }
    }

    func assetIDs(matchingAll tags: [String]) -> Set<String> {
        Set(search(tags: tags, mode: .and).map { $0.assetID })
    }

    func assetIDs(matchingAny tags: [String]) -> Set<String> {
        Set(search(tags: tags, mode: .or).map { $0.assetID })
    }

    // MARK: - Suggestions

    func suggestions(for prefix: String, limit: Int = 12) -> [String] {
        guard !prefix.isEmpty else {
            return topTags.prefix(limit).map { $0.tag }
        }
        let p = normalizeTag(prefix)
        return tagFrequency
            .filter { $0.key.hasPrefix(p) }
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { $0.key }
    }

    func cooccurringTags(with tag: String, limit: Int = 8) -> [String] {
        let normalized = normalizeTag(tag)
        var coCount: [String: Int] = [:]
        for assetTags in index.values {
            guard assetTags.contains(normalized) else { continue }
            for other in assetTags where other != normalized {
                coCount[other, default: 0] += 1
            }
        }
        return coCount.sorted { $0.value > $1.value }.prefix(limit).map { $0.key }
    }

    // MARK: - Bulk Operations

    func reindexAll(assets: [GeneratedAsset]) {
        index = [:]
        tagFrequency = [:]
        for asset in assets {
            guard let id = asset.id?.uuidString else { continue }
            let tagList = asset.tags?
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty } ?? []
            if !tagList.isEmpty {
                index[id] = Set(tagList)
                for t in tagList { tagFrequency[t, default: 0] += 1 }
            }
        }
        saveIndex()
        refreshTopTags()
    }

    func mergeIndex(from other: [String: [String]]) {
        for (assetID, tags) in other {
            let normalized = Set(tags.map { normalizeTag($0) }.filter { !$0.isEmpty })
            if index[assetID] == nil { index[assetID] = [] }
            for t in normalized {
                if index[assetID]!.insert(t).inserted {
                    tagFrequency[t, default: 0] += 1
                }
            }
        }
        saveIndex()
        refreshTopTags()
    }

    func deleteTagGlobally(_ tag: String) {
        let normalized = normalizeTag(tag)
        for key in index.keys {
            index[key]?.remove(normalized)
        }
        tagFrequency.removeValue(forKey: normalized)
        // Sync back to Core Data
        let ctx = AssetStore.shared.container.viewContext
        let request = GeneratedAsset.fetchRequest()
        if let assets = try? ctx.fetch(request) {
            for asset in assets {
                guard let id = asset.id?.uuidString, index[id] != nil else { continue }
                syncToAsset(asset, id: id)
            }
        }
        saveIndex()
        refreshTopTags()
    }

    func renameTag(_ old: String, to new: String) {
        let oldN = normalizeTag(old)
        let newN = normalizeTag(new)
        guard !newN.isEmpty else { return }
        for key in index.keys {
            if index[key]?.remove(oldN) != nil {
                index[key]!.insert(newN)
            }
        }
        let count = tagFrequency[oldN] ?? 0
        tagFrequency.removeValue(forKey: oldN)
        tagFrequency[newN, default: 0] += count
        saveIndex()
        refreshTopTags()
    }

    // MARK: - Stats

    var totalTaggedAssets: Int { index.filter { !$0.value.isEmpty }.count }
    var uniqueTagCount:    Int { tagFrequency.count }
    var totalTagUses:      Int { tagFrequency.values.reduce(0, +) }

    // MARK: - Core Data Sync

    private func syncToAsset(_ asset: GeneratedAsset, id: String) {
        let tagString = (index[id] ?? []).sorted().joined(separator: ", ")
        asset.tags = tagString
        try? AssetStore.shared.container.viewContext.save()
    }

    // MARK: - Persistence

    private var indexURL: URL? {
        VaultManager.shared.vaultMetaURL?.appending(path: "tag_index.json")
    }

    private func saveIndex() {
        guard let url = indexURL else { return }
        let payload: [String: Any] = [
            "version":    2,
            "savedAt":    ISO8601DateFormatter().string(from: Date()),
            "index":      index.mapValues { Array($0) },
            "frequency":  tagFrequency
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .completeFileProtection)
        }
    }

    private func loadIndex() {
        guard let url = indexURL,
              let data = try? Data(contentsOf: url),
              let raw  = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        if let idx = raw["index"] as? [String: [String]] {
            index = idx.mapValues { Set($0) }
        }
        if let freq = raw["frequency"] as? [String: Int] {
            tagFrequency = freq
        }
        refreshTopTags()
    }

    private func refreshTopTags() {
        topTags = tagFrequency
            .sorted { $0.value > $1.value }
            .prefix(50)
            .map { TagItem(tag: $0.key, count: $0.value) }
    }

    // MARK: - Normalization

    func normalizeTag(_ tag: String) -> String {
        tag.trimmingCharacters(in: .whitespacesAndNewlines)
           .lowercased()
           .replacingOccurrences(of: " ", with: "_")
           .filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }

    // MARK: - SD Keyword Database

    private static let sdKeywordSet: Set<String> = [
        "portrait", "cinematic", "realistic", "photorealistic", "ultrarealistic",
        "detailed", "highdetail", "sharp", "focus", "bokeh", "dof",
        "lighting", "backlight", "rimlight", "softlight", "hardlight", "dramatic",
        "golden_hour", "sunset", "studio", "outdoor", "indoor",
        "blonde", "brunette", "redhead", "dark_hair", "curly", "straight",
        "blue_eyes", "green_eyes", "brown_eyes", "gray_eyes",
        "smile", "serious", "melancholic", "confident",
        "nude", "clothed", "lingerie", "elegant", "casual",
        "solo", "couple", "group",
        "masterpiece", "best_quality", "high_quality", "award_winning",
        "8k", "4k", "hdr", "raw_photo", "analog_style",
        "fantasy", "sci_fi", "modern", "vintage", "retro", "noir",
        "beach", "forest", "urban", "room", "bedroom", "bathroom",
        "watercolor", "oil_painting", "digital_art", "illustration",
        "anime", "manga", "3d_render", "unreal_engine",
        "nsfw", "explicit", "tasteful", "artistic"
    ]
}

// MARK: - TaggingEngine SwiftUI integration

extension TaggingEngine {

    /// Devuelve los assets filtrados del store según los tags activos.
    func filteredAssets(from all: [GeneratedAsset], activeTags: [String], mode: SearchMode = .and) -> [GeneratedAsset] {
        guard !activeTags.isEmpty else { return all }
        let matchingIDs = mode == .and ? assetIDs(matchingAll: activeTags) : assetIDs(matchingAny: activeTags)
        return all.filter { asset in
            guard let id = asset.id?.uuidString else { return false }
            return matchingIDs.contains(id)
        }
    }
}

// MARK: - Public boot API

extension TaggingEngine {
    /// Public wrapper for loadIndex — called from AppEnvironment.boot()
    func loadIndexPublic() {
        loadIndex()
    }
}

    // MARK: - Auto-tag untagged assets
    func autoTagUntagged(assets: [GeneratedAsset]) {
        let tagIndex = self.index  // capture to avoid C stdlib index() shadowing
        for asset in assets {
            guard let id = asset.id?.uuidString,
                  (tagIndex[id] == nil || tagIndex[id]!.isEmpty)
            else { continue }
            let suggested = self.autoExtract(from: asset.promptPositive ?? "")
            for tag in suggested { _ = self.addTag(tag, to: asset) }
        }
    }
