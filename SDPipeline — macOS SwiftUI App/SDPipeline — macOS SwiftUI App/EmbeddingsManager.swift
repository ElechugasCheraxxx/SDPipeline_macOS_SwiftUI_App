import Foundation
import AppKit
import SwiftUI
import Combine

// MARK: - EmbeddingsManager
//
// Gestiona Textual Inversions (Embeddings) de Stable Diffusion.
// Fuentes:
//   - A1111 API: GET /sdapi/v1/embeddings  → lista de embeddings cargados
//   - Registro local: metadatos privados (descripción, tags, notas, favorito)
//   - Inyección directa en prompts como token: <embedding_name>
//
// Compatibilidad:
//   - SD 1.x embeddings (.pt / .bin)
//   - SDXL textual inversions
//
// Persistencia: Vault/meta/embeddings_registry.json
//
// ROADMAP: "Soporte para embeddings/textual inversions" (🟡 MEDIO PLAZO)

// MARK: - Models

struct EmbeddingInfo: Codable, Identifiable, Hashable {
    // Campos de A1111 API
    var step:            Int?    = nil
    var sd_checkpoint:   String? = nil
    var sd_checkpoint_name: String? = nil
    var shape:           [Int]?  = nil   // tensor shape
    var vectors:         Int?    = nil   // number of vectors

    // Computed
    var id:   String { name }
    var name: String = ""

    func hash(into hasher: inout Hasher) { hasher.combine(name) }
    static func == (lhs: EmbeddingInfo, rhs: EmbeddingInfo) -> Bool { lhs.name == rhs.name }
}

struct EmbeddingRecord: Codable, Identifiable {
    var id:             UUID    = UUID()
    var name:           String              // nombre del embedding (= token)
    var displayName:    String  = ""        // nombre amigable
    var description:    String  = ""
    var tags:           [String] = []
    var isFavorite:     Bool    = false
    var isNSFW:         Bool    = false
    var sourceURL:      String  = ""        // URL de origen (CivitAI, HuggingFace, etc.)
    var triggerToken:   String  = ""        // si es distinto al nombre del archivo
    var baseModel:      String  = "SD 1.5"  // "SD 1.5", "SDXL", etc.
    var addedAt:        Date    = Date()
    var lastUsedAt:     Date?   = nil
    var usageCount:     Int     = 0
    var notes:          String  = ""

    var effectiveToken: String {
        triggerToken.isEmpty ? name : triggerToken
    }

    /// Retorna el token listo para insertar en prompt
    var promptToken: String { effectiveToken }
}

struct EmbeddingInjectionResult {
    let prompt:      String
    let tokens:      [String]
    let recordsUsed: [EmbeddingRecord]
}

// MARK: - A1111 API Response

struct EmbeddingsAPIResponse: Decodable {
    let loaded:  [String: EmbeddingInfo]
    let skipped: [String: EmbeddingInfo]
}

// MARK: - EmbeddingsManager

@MainActor
final class EmbeddingsManager: ObservableObject {

    static let shared = EmbeddingsManager()
    private init() { loadRegistry() }

    // MARK: - State

    @Published var loaded:       [EmbeddingInfo]   = []    // desde A1111
    @Published var skipped:      [EmbeddingInfo]   = []    // SD 2.x en SD 1.5, etc.
    @Published var registry:     [EmbeddingRecord] = []    // metadatos locales
    @Published var activeTokens: [String]          = []    // tokens activos para inyectar
    @Published var isFetching:   Bool              = false
    @Published var lastFetchAt:  Date?             = nil

    private var registryURL: URL? {
        VaultManager.shared.vaultMetaURL?.appending(path: "embeddings_registry.json")
    }

    // MARK: - Fetch from A1111

    func fetchEmbeddings(baseURL: String) async {
        isFetching = true
        defer { isFetching = false }

        guard let url = URL(string: "\(baseURL)/sdapi/v1/embeddings") else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)

            // A1111 returns {"loaded": {"name": {...}}, "skipped": {"name": {...}}}
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

            var loadedInfos:  [EmbeddingInfo] = []
            var skippedInfos: [EmbeddingInfo] = []

            if let loadedDict = json["loaded"] as? [String: Any] {
                for (name, _) in loadedDict {
                    loadedInfos.append(EmbeddingInfo(name: name))
                }
            }

            if let skippedDict = json["skipped"] as? [String: Any] {
                for (name, _) in skippedDict {
                    skippedInfos.append(EmbeddingInfo(name: name))
                }
            }

            loaded  = loadedInfos.sorted { $0.name < $1.name }
            skipped = skippedInfos.sorted { $0.name < $1.name }
            lastFetchAt = Date()

            // Auto-registrar embeddings nuevos
            autoRegisterNewEmbeddings()

        } catch {
            print("⚠️ EmbeddingsManager: fetch failed: \(error)")
        }
    }

    // MARK: - Auto-register

    private func autoRegisterNewEmbeddings() {
        let existing = Set(registry.map { $0.name })
        var changed = false

        for info in loaded + skipped {
            if !existing.contains(info.name) {
                let record = EmbeddingRecord(
                    name:        info.name,
                    displayName: info.name,
                    baseModel:   "SD 1.5"
                )
                registry.append(record)
                changed = true
            }
        }

        if changed { saveRegistry() }
    }

    // MARK: - Inject into Prompt

    /// Inyecta los tokens activos en el prompt dado
    func inject(into prompt: String) -> EmbeddingInjectionResult {
        guard !activeTokens.isEmpty else {
            return EmbeddingInjectionResult(prompt: prompt, tokens: [], recordsUsed: [])
        }

        var tokens: [String] = []
        var records: [EmbeddingRecord] = []

        for token in activeTokens {
            if let record = registry.first(where: { $0.name == token }) {
                tokens.append(record.promptToken)
                records.append(record)
            } else {
                tokens.append(token)
            }
        }

        let injected = tokens.joined(separator: ", ")
        let finalPrompt = prompt.isEmpty ? injected : "\(prompt), \(injected)"

        return EmbeddingInjectionResult(
            prompt:      finalPrompt,
            tokens:      tokens,
            recordsUsed: records
        )
    }

    /// Agrega token a activos
    func activate(_ name: String) {
        if !activeTokens.contains(name) {
            activeTokens.append(name)
            recordUsage(name: name)
        }
    }

    /// Quita token de activos
    func deactivate(_ name: String) {
        activeTokens.removeAll { $0 == name }
    }

    func toggleActive(_ name: String) {
        if activeTokens.contains(name) { deactivate(name) }
        else                           { activate(name)   }
    }

    var hasActive: Bool { !activeTokens.isEmpty }

    // MARK: - Record Usage

    func recordUsage(name: String) {
        if let idx = registry.firstIndex(where: { $0.name == name }) {
            registry[idx].usageCount += 1
            registry[idx].lastUsedAt  = Date()
            saveRegistry()
        }
    }

    // MARK: - Record Management

    func updateRecord(_ record: EmbeddingRecord) {
        if let idx = registry.firstIndex(where: { $0.id == record.id }) {
            registry[idx] = record
        } else {
            registry.append(record)
        }
        saveRegistry()
    }

    func toggleFavorite(_ record: EmbeddingRecord) {
        if let idx = registry.firstIndex(where: { $0.id == record.id }) {
            registry[idx].isFavorite.toggle()
            saveRegistry()
        }
    }

    func record(for name: String) -> EmbeddingRecord? {
        registry.first { $0.name == name }
    }

    // MARK: - Search

    func search(query: String) -> [EmbeddingRecord] {
        guard !query.isEmpty else { return sortedRegistry }
        let q = query.lowercased()
        return sortedRegistry.filter {
            $0.name.lowercased().contains(q) ||
            $0.displayName.lowercased().contains(q) ||
            $0.description.lowercased().contains(q) ||
            $0.tags.contains { $0.lowercased().contains(q) }
        }
    }

    var sortedRegistry: [EmbeddingRecord] {
        registry.sorted {
            if $0.isFavorite != $1.isFavorite { return $0.isFavorite }
            return $0.usageCount > $1.usageCount
        }
    }

    var favorites: [EmbeddingRecord] {
        registry.filter { $0.isFavorite }
    }

    var recentlyUsed: [EmbeddingRecord] {
        registry
            .filter { $0.lastUsedAt != nil }
            .sorted { ($0.lastUsedAt ?? .distantPast) > ($1.lastUsedAt ?? .distantPast) }
            .prefix(10)
            .map { $0 }
    }

    // MARK: - Persistence

    private func loadRegistry() {
        guard let url  = registryURL,
              let data = try? Data(contentsOf: url),
              let recs = try? JSONDecoder.iso8601.decode([EmbeddingRecord].self, from: data)
        else { return }
        registry = recs
    }

    func saveRegistry() {
        guard let url  = registryURL,
              let data = try? JSONEncoder.pretty.encode(registry)
        else { return }
        try? data.write(to: url)
    }
}

// MARK: - EmbeddingsManagerView

struct EmbeddingsManagerView: View {

    @StateObject private var manager = EmbeddingsManager.shared
    @State private var searchQuery   = ""
    @State private var showFavorites = false
    @State private var editingRecord: EmbeddingRecord? = nil
    @State private var activeTab:    Tab = .all

    let baseURL: String

    enum Tab: String, CaseIterable {
        case all       = "Todos"
        case active    = "Activos"
        case favorites = "Favoritos"
        case recent    = "Recientes"
    }

    var displayedRecords: [EmbeddingRecord] {
        let base: [EmbeddingRecord]
        switch activeTab {
        case .all:       base = manager.search(query: searchQuery)
        case .active:    base = manager.sortedRegistry.filter { manager.activeTokens.contains($0.name) }
        case .favorites: base = manager.favorites
        case .recent:    base = manager.recentlyUsed
        }
        if searchQuery.isEmpty || activeTab != .all { return base }
        return base
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.white.opacity(0.07))
            tabBar
            Divider().background(Color.white.opacity(0.07))
            searchBar
            Divider().background(Color.white.opacity(0.05))

            if displayedRecords.isEmpty {
                emptyState
            } else {
                List(displayedRecords) { record in
                    EmbeddingRowView(
                        record: record,
                        isActive: manager.activeTokens.contains(record.name),
                        onToggle: { manager.toggleActive(record.name) },
                        onEdit: { editingRecord = record },
                        onFavorite: { manager.toggleFavorite(record) }
                    )
                }
                .listStyle(.plain)
            }

            Divider().background(Color.white.opacity(0.07))
            bottomBar
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
        .task { await manager.fetchEmbeddings(baseURL: baseURL) }
        .sheet(item: $editingRecord) { rec in
            EmbeddingEditorSheet(record: rec) { updated in
                manager.updateRecord(updated)
            }
        }
    }

    // MARK: - Header

    var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "textformat.characters.dashed")
                .font(.system(size: 14))
                .foregroundColor(Color(hex: "#7c6af7"))
            VStack(alignment: .leading, spacing: 1) {
                Text("Embeddings / Textual Inversions")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                HStack(spacing: 6) {
                    Text("\(manager.loaded.count) cargados")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    if !manager.skipped.isEmpty {
                        Text("· \(manager.skipped.count) omitidos (base model)")
                            .font(.system(size: 9))
                            .foregroundColor(Color(hex: "#f59e0b"))
                    }
                    if let last = manager.lastFetchAt {
                        Text("· \(last, style: .relative) atrás")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                }
            }
            Spacer()

            if manager.isFetching {
                ProgressView().controlSize(.small)
            } else {
                Button(action: {
                    Task { await manager.fetchEmbeddings(baseURL: baseURL) }
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Recargar desde A1111")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.white.opacity(0.03))
    }

    // MARK: - Tab Bar

    var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { tab in
                Button(action: { activeTab = tab }) {
                    HStack(spacing: 4) {
                        Text(tab.rawValue)
                            .font(.system(size: 11, weight: activeTab == tab ? .semibold : .regular))
                        if tab == .active && !manager.activeTokens.isEmpty {
                            Text("\(manager.activeTokens.count)")
                                .font(.system(size: 9))
                                .foregroundColor(.white)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color(hex: "#7c6af7"))
                                .cornerRadius(8)
                        }
                    }
                    .foregroundColor(activeTab == tab ? .white : .secondary)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(activeTab == tab ? Color.white.opacity(0.07) : Color.clear)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .background(Color.white.opacity(0.02))
    }

    // MARK: - Search Bar

    var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            TextField("Buscar embeddings…", text: $searchQuery)
                .font(.system(size: 11))
                .textFieldStyle(.plain)
            if !searchQuery.isEmpty {
                Button(action: { searchQuery = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.white.opacity(0.03))
    }

    // MARK: - Empty State

    var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "textformat.characters.dashed")
                .font(.system(size: 28))
                .foregroundColor(.secondary.opacity(0.4))
            Text("No se encontraron embeddings")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            if manager.loaded.isEmpty {
                Text("Verifica que A1111 esté en línea y tenga embeddings instalados.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Bottom Bar

    var bottomBar: some View {
        HStack(spacing: 8) {
            if !manager.activeTokens.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(manager.activeTokens, id: \.self) { token in
                            HStack(spacing: 3) {
                                Text(token)
                                    .font(.system(size: 10))
                                    .foregroundColor(.white)
                                Button(action: { manager.deactivate(token) }) {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 8))
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Color(hex: "#7c6af7").opacity(0.2))
                            .cornerRadius(4)
                        }
                    }
                }

                Button(action: { manager.activeTokens.removeAll() }) {
                    Text("Limpiar")
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "#ef4444"))
                }
                .buttonStyle(.plain)
            } else {
                Text("Selecciona embeddings para inyectar en el prompt")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Color.white.opacity(0.02))
    }
}

// MARK: - EmbeddingRowView

struct EmbeddingRowView: View {
    let record:    EmbeddingRecord
    let isActive:  Bool
    var onToggle:  () -> Void
    var onEdit:    () -> Void
    var onFavorite: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // Active toggle
            Button(action: onToggle) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundColor(isActive ? Color(hex: "#7c6af7") : .secondary)
            }
            .buttonStyle(.plain)

            // Info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(record.displayName.isEmpty ? record.name : record.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white)
                    if record.isNSFW {
                        Text("NSFW")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(Color(hex: "#ef4444"))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color(hex: "#ef4444").opacity(0.15))
                            .cornerRadius(3)
                    }
                    if record.baseModel != "SD 1.5" {
                        Text(record.baseModel)
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.white.opacity(0.06))
                            .cornerRadius(3)
                    }
                }

                HStack(spacing: 6) {
                    Text(record.name)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)

                    if record.usageCount > 0 {
                        Text("·  \(record.usageCount)×")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                }

                if !record.description.isEmpty {
                    Text(record.description)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.7))
                        .lineLimit(1)
                }
            }

            Spacer()

            // Actions
            Button(action: onFavorite) {
                Image(systemName: record.isFavorite ? "star.fill" : "star")
                    .font(.system(size: 11))
                    .foregroundColor(record.isFavorite ? Color(hex: "#f59e0b") : .secondary)
            }
            .buttonStyle(.plain)

            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .listRowBackground(isActive ? Color(hex: "#7c6af7").opacity(0.07) : Color.clear)
    }
}

// MARK: - EmbeddingEditorSheet

struct EmbeddingEditorSheet: View {
    @State var record: EmbeddingRecord
    var onSave: (EmbeddingRecord) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var newTag = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Editar Embedding")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Button("Cancelar") { dismiss() }.buttonStyle(.plain).foregroundColor(.secondary)
                Button("Guardar") { onSave(record); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(hex: "#7c6af7"))
                    .controlSize(.small)
            }
            .padding(16)
            .background(Color.white.opacity(0.03))

            Divider().background(Color.white.opacity(0.07))

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Group {
                        field("Nombre archivo (token)", text: $record.name)
                        field("Nombre amigable", text: $record.displayName)
                        field("Token en prompt (si difiere)", text: $record.triggerToken)

                        Picker("Base Model", selection: $record.baseModel) {
                            ForEach(["SD 1.5", "SDXL", "SD 2.1", "Pony", "Otro"], id: \.self) {
                                Text($0).tag($0)
                            }
                        }
                        .pickerStyle(.menu)
                        .font(.system(size: 11))
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Descripción").font(.system(size: 10)).foregroundColor(.secondary)
                        TextEditor(text: $record.description)
                            .font(.system(size: 11))
                            .frame(minHeight: 60)
                            .background(Color.white.opacity(0.04))
                            .cornerRadius(5)
                    }

                    HStack(spacing: 16) {
                        Toggle("NSFW", isOn: $record.isNSFW)
                            .font(.system(size: 11))
                        Toggle("Favorito", isOn: $record.isFavorite)
                            .font(.system(size: 11))
                    }

                    field("URL fuente (CivitAI, etc.)", text: $record.sourceURL)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Notas").font(.system(size: 10)).foregroundColor(.secondary)
                        TextEditor(text: $record.notes)
                            .font(.system(size: 11))
                            .frame(minHeight: 50)
                            .background(Color.white.opacity(0.04))
                            .cornerRadius(5)
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 400, height: 480)
        .background(Color(red: 0.10, green: 0.10, blue: 0.13))
    }

    func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
        }
    }
}
