import Foundation
import SwiftUI
import Combine

// MARK: - PromptVersioningStore
//
// Historial versionado de prompts exitosos.
// Permite guardar, buscar y reutilizar prompts con su contexto completo.
// Persistencia: JSON en Vault/prompt_versions.json
//
// ROADMAP: "Versionamiento de prompts exitosos" (Sección 7 - UI/UX)

@MainActor
final class PromptVersioningStore: ObservableObject {

    static let shared = PromptVersioningStore()
    private init() { load() }

    // MARK: - Models

    struct PromptVersion: Codable, Identifiable, Hashable {
        var id:           UUID    = UUID()
        var savedAt:      Date    = Date()
        var positive:     String
        var negative:     String
        var label:        String            // Nombre amigable dado por el usuario
        var tags:         [String] = []
        var rating:       Int     = 0       // 0-5
        var usageCount:   Int     = 0
        var characterID:  UUID?   = nil     // Si está vinculado a un personaje
        var sourceAssetID: UUID?  = nil     // Asset que originó este prompt
        var notes:        String  = ""

        // Parámetros SD asociados (para reproducción exacta)
        var steps:        Int     = 28
        var cfgScale:     Double  = 7.0
        var samplerName:  String  = "DPM++ 2M Karras"
        var width:        Int     = 512
        var height:       Int     = 768
        var checkpoint:   String  = ""

        func hash(into hasher: inout Hasher) { hasher.combine(id) }
        static func == (lhs: PromptVersion, rhs: PromptVersion) -> Bool { lhs.id == rhs.id }
    }

    // MARK: - State

    @Published var versions: [PromptVersion] = []

    private let maxVersions = 1000

    // MARK: - Public API

    /// Guardar un prompt como nueva versión.
    @discardableResult
    func save(
        positive:     String,
        negative:     String,
        label:        String  = "",
        tags:         [String] = [],
        characterID:  UUID?   = nil,
        sourceAssetID: UUID?  = nil,
        steps:        Int     = 28,
        cfgScale:     Double  = 7.0,
        samplerName:  String  = "DPM++ 2M Karras",
        width:        Int     = 512,
        height:       Int     = 768,
        checkpoint:   String  = ""
    ) -> PromptVersion {
        let autoLabel = label.isEmpty
            ? "Prompt \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short))"
            : label

        let version = PromptVersion(
            positive:      positive,
            negative:      negative,
            label:         autoLabel,
            tags:          tags,
            characterID:   characterID,
            sourceAssetID: sourceAssetID,
            steps:         steps,
            cfgScale:      cfgScale,
            samplerName:   samplerName,
            width:         width,
            height:        height,
            checkpoint:    checkpoint
        )

        versions.insert(version, at: 0)

        if versions.count > maxVersions {
            versions = Array(versions.prefix(maxVersions))
        }

        save()
        return version
    }

    /// Auto-guardar desde un asset existente (llamado tras guardar en vault).
    @discardableResult
    func autoSave(from asset: GeneratedAsset) -> PromptVersion {
        save(
            positive:      asset.promptPositive ?? "",
            negative:      asset.promptNegative ?? "",
            label:         asset.sessionTag ?? "Prompt \(asset.baseName ?? "")",
            sourceAssetID: asset.id,
            steps:         Int(asset.steps),
            cfgScale:      asset.cfgScale,
            samplerName:   asset.samplerName ?? "DPM++ 2M Karras",
            width:         Int(asset.width),
            height:        Int(asset.height),
            checkpoint:    asset.checkpoint ?? ""
        )
    }

    /// Eliminar una versión.
    func delete(_ version: PromptVersion) {
        versions.removeAll { $0.id == version.id }
        save()
    }

    /// Actualizar label / tags / rating.
    func update(id: UUID, label: String? = nil, tags: [String]? = nil, rating: Int? = nil, notes: String? = nil) {
        guard let idx = versions.firstIndex(where: { $0.id == id }) else { return }
        if let label  = label  { versions[idx].label  = label }
        if let tags   = tags   { versions[idx].tags   = tags }
        if let rating = rating { versions[idx].rating = max(0, min(5, rating)) }
        if let notes  = notes  { versions[idx].notes  = notes }
        save()
    }

    func incrementUsage(id: UUID) {
        guard let idx = versions.firstIndex(where: { $0.id == id }) else { return }
        versions[idx].usageCount += 1
        save()
    }

    // MARK: - Search

    func search(query: String, characterID: UUID? = nil, minRating: Int = 0) -> [PromptVersion] {
        var result = versions

        if let charID = characterID {
            result = result.filter { $0.characterID == charID }
        }

        if minRating > 0 {
            result = result.filter { $0.rating >= minRating }
        }

        if !query.isEmpty {
            let q = query.lowercased()
            result = result.filter {
                $0.label.lowercased().contains(q) ||
                $0.positive.lowercased().contains(q) ||
                $0.tags.contains(where: { $0.lowercased().contains(q) })
            }
        }

        return result
    }

    /// Top N prompts más usados.
    func topPrompts(count: Int = 10) -> [PromptVersion] {
        Array(versions.sorted { $0.usageCount > $1.usageCount }.prefix(count))
    }

    // MARK: - Persistence

    private func save() {
        guard let url = persistenceURL else { return }

        struct Registry: Codable { var versions: [PromptVersion] }
        let registry = Registry(versions: versions)

        if let data = try? JSONEncoder.pretty.encode(registry) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func load() {
        guard let url = persistenceURL,
              let data = try? Data(contentsOf: url)
        else { return }

        struct Registry: Codable { var versions: [PromptVersion] }
        if let registry = try? JSONDecoder.iso8601.decode(Registry.self, from: data) {
            self.versions = registry.versions
        }
    }

    private var persistenceURL: URL? {
        VaultManager.shared.vaultMetaURL?.appending(path: "prompt_versions.json")
    }
}

// MARK: - PromptVersionPickerView

struct PromptVersionPickerView: View {

    @Binding var selectedPositive: String
    @Binding var selectedNegative: String
    var onPick: (() -> Void)? = nil

    @StateObject private var store = PromptVersioningStore.shared
    @State private var query: String = ""
    @State private var minRating: Int = 0
    @State private var showSaveSheet = false
    @State private var newLabel: String = ""

    var results: [PromptVersioningStore.PromptVersion] {
        store.search(query: query, minRating: minRating)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text("Prompts guardados")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Button(action: { showSaveSheet = true }) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 13))
                        .foregroundColor(Color(hex: "#7c6af7"))
                }
                .buttonStyle(.plain)
                .help("Guardar prompt actual")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.white.opacity(0.03))

            // Search + rating filter
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                TextField("Buscar…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(.white)
                Spacer()
                // Rating filter
                HStack(spacing: 2) {
                    ForEach(1...5, id: \.self) { star in
                        Button(action: { minRating = minRating == star ? 0 : star }) {
                            Image(systemName: star <= minRating ? "star.fill" : "star")
                                .font(.system(size: 9))
                                .foregroundColor(star <= minRating ? .yellow : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.white.opacity(0.04))

            Divider().background(Color.white.opacity(0.06))

            if results.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 22))
                        .foregroundColor(.white.opacity(0.15))
                    Text("Sin prompts guardados")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity).padding(20)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(results.prefix(50)) { version in
                            promptRow(version)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .sheet(isPresented: $showSaveSheet) {
            saveSheet
        }
    }

    func promptRow(_ version: PromptVersioningStore.PromptVersion) -> some View {
        Button(action: {
            selectedPositive = version.positive
            selectedNegative = version.negative
            PromptVersioningStore.shared.incrementUsage(id: version.id)
            onPick?()
        }) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(version.label)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white)
                        if version.rating > 0 {
                            HStack(spacing: 1) {
                                ForEach(1...version.rating, id: \.self) { _ in
                                    Image(systemName: "star.fill")
                                        .font(.system(size: 7))
                                        .foregroundColor(.yellow)
                                }
                            }
                        }
                    }
                    Text(version.positive.truncated(60))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    if !version.tags.isEmpty {
                        Text(version.tags.prefix(3).map { "#\($0)" }.joined(separator: " "))
                            .font(.system(size: 9))
                            .foregroundColor(Color(hex: "#7c6af7").opacity(0.7))
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text("×\(version.usageCount)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.5))
                    Button(action: { store.delete(version) }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.white.opacity(0.02))
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }

    var saveSheet: some View {
        VStack(spacing: 16) {
            Text("Guardar prompt actual")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
            TextField("Nombre / etiqueta…", text: $newLabel)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
            HStack {
                Button("Cancelar") { showSaveSheet = false }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Guardar") {
                    store.save(
                        positive: selectedPositive,
                        negative: selectedNegative,
                        label:    newLabel
                    )
                    showSaveSheet = false
                    newLabel = ""
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color(hex: "#7c6af7"))
                .foregroundColor(.white)
                .cornerRadius(6)
                .disabled(selectedPositive.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
    }
}
