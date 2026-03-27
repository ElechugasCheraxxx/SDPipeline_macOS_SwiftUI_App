import Foundation
import SwiftUI
import Combine

// MARK: - TaggingEngine
//
// Motor de tags persistente para la galería.
// Indexa assets por tags, permite búsqueda full-text y por combinación de tags.
// Los tags se persisten en Vault/tag_index.json y en Core Data (via AssetStore).
//
// Features:
//   - Tag por asset (add/remove)
//   - Sugerencias automáticas (basadas en frecuencia + prompt)
//   - Búsqueda por AND/OR de tags
//   - Tags frecuentes (top cloud)
//   - Extracción automática de tags desde prompt (keywords de SD)
//
// ROADMAP: "Buscador por tags con filtros" (Sección 🟠 CORTO PLAZO)

@MainActor
final class TaggingEngine: ObservableObject {

    static let shared = TaggingEngine()
    private init() { loadIndex() }

    // MARK: - Index (assetID → [tag])

    @Published var index: [String: Set<String>] = [:]    // assetID.uuidString → tags
    @Published var tagFrequency: [String: Int]  = [:]    // tag → count global

    // MARK: - Public API

    /// Tags del asset dado.
    func tags(for asset: GeneratedAsset) -> [String] {
        guard let id = asset.id?.uuidString else { return [] }
        return (index[id] ?? []).sorted()
    }

    /// Añadir tag a un asset.
    @discardableResult
    func addTag(_ tag: String, to asset: GeneratedAsset) -> Bool {
        guard let id = asset.id?.uuidString else { return false }
        let normalized = normalizeTag(tag)
        guard !normalized.isEmpty else { return false }

        if index[id] == nil { index[id] = [] }
        let isNew = index[id]!.insert(normalized).inserted

        if isNew {
            tagFrequency[normalized, default: 0] += 1
            saveIndex()
        }
        return isNew
    }

    /// Eliminar tag de un asset.
    func removeTag(_ tag: String, from asset: GeneratedAsset) {
        guard let id = asset.id?.uuidString else { return }
        let normalized = normalizeTag(tag)
        guard index[id]?.remove(normalized) != nil else { return }

        tagFrequency[normalized, default: 1] -= 1
        if tagFrequency[normalized, default: 0] <= 0 {
            tagFrequency.removeValue(forKey: normalized)
        }
        saveIndex()
    }

    /// Buscar assets por tags (AND logic: asset debe tener TODOS los tags).
    func assetIDs(matchingAll tags: [String]) -> Set<String> {
        let normalized = tags.map { normalizeTag($0) }.filter { !$0.isEmpty }
        guard !normalized.isEmpty else { return Set(index.keys) }

        return index.filter { _, assetTags in
            normalized.allSatisfy { assetTags.contains($0) }
        }.reduce(into: Set<String>()) { $0.insert($1.key) }
    }

    /// Buscar assets por tags (OR logic: asset debe tener AL MENOS UNO).
    func assetIDs(matchingAny tags: [String]) -> Set<String> {
        let normalized = tags.map { normalizeTag($0) }.filter { !$0.isEmpty }
        guard !normalized.isEmpty else { return [] }

        return index.filter { _, assetTags in
            normalized.contains(where: { assetTags.contains($0) })
        }.reduce(into: Set<String>()) { $0.insert($1.key) }
    }

    /// Top N tags más frecuentes.
    func topTags(limit: Int = 30) -> [(tag: String, count: Int)] {
        tagFrequency
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { (tag: $0.key, count: $0.value) }
    }

    /// Sugerencias automáticas de tags desde el prompt de un asset.
    func suggestTags(for asset: GeneratedAsset) -> [String] {
        let prompt = (asset.promptPositive ?? "").lowercased()
        var suggestions: [String] = []

        // Extraer keywords de SD tokens del prompt
        let sdKeywords: [String: [String]] = [
            "portrait":     ["portrait", "face", "headshot"],
            "full body":    ["full body", "full-body", "standing"],
            "outdoor":      ["outdoor", "outside", "nature", "forest", "beach", "city"],
            "indoor":       ["indoor", "inside", "room", "studio", "bedroom"],
            "nsfw":         ["nsfw", "nude", "naked", "explicit"],
            "fashion":      ["fashion", "dress", "outfit", "clothing", "couture"],
            "cinematic":    ["cinematic", "film", "movie"],
            "fantasy":      ["fantasy", "magical", "elf", "wizard"],
            "realistic":    ["photorealistic", "realistic", "photo"],
            "anime":        ["anime", "manga", "cartoon"],
            "dark":         ["dark", "noir", "shadow", "moody"],
            "bright":       ["bright", "sunny", "golden", "light"],
            "closeup":      ["close-up", "closeup", "macro"],
            "night":        ["night", "dark", "midnight", "neon"],
        ]

        for (tag, keywords) in sdKeywords {
            if keywords.contains(where: { prompt.contains($0) }) {
                suggestions.append(tag)
            }
        }

        // Añadir checkpoint como tag
        if let checkpoint = asset.checkpoint, !checkpoint.isEmpty {
            let checkpointTag = (checkpoint as NSString).deletingPathExtension
                .components(separatedBy: .init(charactersIn: "/_-"))
                .first ?? checkpoint
            suggestions.append("model:\(checkpointTag.lowercased().prefix(20))")
        }

        // Añadir rating como tag si está calificado
        if asset.rating > 0 {
            suggestions.append("rating:\(asset.rating)★")
        }

        // Filtrar los que ya tiene
        let existing = Set(tags(for: asset))
        return suggestions.filter { !existing.contains($0) }
    }

    /// Auto-tag batch en todos los assets sin tags.
    func autoTagUntagged(assets: [GeneratedAsset]) {
        for asset in assets {
            guard let id = asset.id?.uuidString,
                  (index[id] ?? []).isEmpty
            else { continue }
            let suggestions = suggestTags(for: asset)
            suggestions.forEach { addTag($0, to: asset) }
        }
    }

    // MARK: - Normalization

    private func normalizeTag(_ tag: String) -> String {
        tag.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "  ", with: " ")
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == ":" || $0 == "★" }
    }

    // MARK: - Persistence

    private var indexURL: URL? {
        VaultManager.shared.vaultMetaURL?.appending(path: "tag_index.json")
    }

    private struct IndexPayload: Codable {
        var index:        [String: [String]]
        var tagFrequency: [String: Int]
    }

    private func loadIndex() {
        guard let url     = indexURL,
              let data    = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(IndexPayload.self, from: data)
        else { return }

        index        = payload.index.mapValues { Set($0) }
        tagFrequency = payload.tagFrequency
    }

    func saveIndex() {
        guard let url = indexURL else { return }
        let payload = IndexPayload(
            index:        index.mapValues { Array($0) },
            tagFrequency: tagFrequency
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting     = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payload) else { return }
        try? data.write(to: url, options: Data.WritingOptions.atomic)
    }
}

// MARK: - TagCloudView

struct TagCloudView: View {
    let tags: [String]
    var onRemove: ((String) -> Void)? = nil
    var onAdd:    ((String) -> Void)? = nil
    @State private var newTag: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Existing tags
            if !tags.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(tags, id: \.self) { tag in
                        tagChip(tag)
                    }
                }
            }

            // Add new tag
            if onAdd != nil {
                HStack(spacing: 4) {
                    Image(systemName: "tag")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    TextField("+ tag", text: $newTag)
                        .textFieldStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundColor(.white)
                        .onSubmit {
                            if !newTag.isEmpty {
                                onAdd?(newTag)
                                newTag = ""
                            }
                        }
                }
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Color.white.opacity(0.04))
                .cornerRadius(4)
            }
        }
    }

    func tagChip(_ tag: String) -> some View {
        HStack(spacing: 3) {
            Text(tag)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.white.opacity(0.85))
            if let onRemove = onRemove {
                Button(action: { onRemove(tag) }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(Color(hex: "#7c6af7").opacity(0.18))
        .cornerRadius(4)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(hex: "#7c6af7").opacity(0.3), lineWidth: 0.5))
    }
}

// MARK: - TagFilterBar (for GalleryView)

struct TagFilterBar: View {

    @StateObject private var engine = TaggingEngine.shared
    @Binding var activeTags: [String]
    var logicMode: TagLogicMode = .and
    @State private var searchTag: String = ""

    enum TagLogicMode { case and, or }

    var topTags: [(tag: String, count: Int)] { engine.topTags(limit: 20) }

    var body: some View {
        VStack(spacing: 0) {
            // Search
            HStack(spacing: 6) {
                Image(systemName: "tag.fill")
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "#7c6af7"))
                TextField("Filtrar por tag…", text: $searchTag)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(.white)
                    .onSubmit {
                        if !searchTag.isEmpty && !activeTags.contains(searchTag) {
                            activeTags.append(searchTag.lowercased())
                            searchTag = ""
                        }
                    }
                if !activeTags.isEmpty {
                    Button(action: { activeTags.removeAll() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.white.opacity(0.04))

            // Active filter tags
            if !activeTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(activeTags, id: \.self) { tag in
                            HStack(spacing: 3) {
                                Text(tag)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundColor(.white)
                                Button(action: { activeTags.removeAll { $0 == tag } }) {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 7))
                                }
                                .buttonStyle(.plain)
                                .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Color(hex: "#7c6af7").opacity(0.25))
                            .cornerRadius(4)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 4)
                }
            }

            // Top tags cloud
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(topTags, id: \.tag) { item in
                        let isActive = activeTags.contains(item.tag)
                        Button(action: {
                            if isActive { activeTags.removeAll { $0 == item.tag } }
                            else { activeTags.append(item.tag) }
                        }) {
                            HStack(spacing: 3) {
                                Text(item.tag)
                                    .font(.system(size: 9))
                                Text("\(item.count)")
                                    .font(.system(size: 8))
                                    .foregroundColor(isActive ? .white.opacity(0.7) : .secondary)
                            }
                            .foregroundColor(isActive ? .white : .secondary)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(isActive ? Color(hex: "#7c6af7").opacity(0.3) : Color.white.opacity(0.04))
                            .cornerRadius(4)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
            }
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
    }
}

// MARK: - FlowLayout (helper for tag chips)

struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
    }
}
