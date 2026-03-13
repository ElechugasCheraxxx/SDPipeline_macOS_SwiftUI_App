import Foundation
import SwiftUI
import Combine

// MARK: - PromptDatabase
//
// Base de datos local de prompts exitosos para SDPipelineStudio.
// Almacena, organiza y permite reutilizar prompts que producen buenos resultados.
//
// Fuentes de entrada:
//   1. Manual: el usuario guarda prompts desde el pipeline o galería
//   2. Auto-import: importa desde PromptVersioningStore (prompts usados en generaciones exitosas)
//   3. Bulk-import: importa desde archivos .txt o JSON externos
//
// Búsqueda:
//   - Texto (positive, negative, tags, notas)
//   - Por checkpoint
//   - Por rating mínimo
//   - Por tags
//   - Por período de tiempo
//
// Persistencia: Vault/meta/prompt_database.json (cap 2000 entradas)
//
// ROADMAP: "Base de datos de prompts exitosos" (🟡 MEDIO PLAZO)

// MARK: - Models

struct PromptEntry: Codable, Identifiable {
    var id:             UUID    = UUID()
    var createdAt:      Date    = Date()
    var lastUsedAt:     Date?   = nil
    var updatedAt:      Date    = Date()

    // Contenido principal
    var positive:       String
    var negative:       String  = ""

    // Metadatos de generación
    var checkpoint:     String  = ""
    var steps:          Int     = 0
    var cfgScale:       Double  = 0
    var samplerName:    String  = ""
    var width:          Int     = 0
    var height:         Int     = 0
    var seed:           Int?    = nil
    var loraNames:      [String] = []

    // Organización
    var title:          String  = ""        // nombre amigable opcional
    var tags:           [String] = []
    var rating:         Int     = 0         // 0-5
    var isFavorite:     Bool    = false
    var category:       Category = .general
    var notes:          String  = ""
    var previewImagePath: String? = nil     // ruta a una imagen de muestra

    // Stats
    var useCount:       Int     = 0
    var successRate:    Double  = 1.0       // fracción de veces que produjo resultado bueno

    // Source
    var sourceType:     SourceType = .manual
    var sourceAssetID:  UUID?  = nil        // GeneratedAsset de origen (si aplica)

    enum Category: String, Codable, CaseIterable {
        case general    = "General"
        case portrait   = "Retrato"
        case fashion    = "Moda"
        case editorial  = "Editorial"
        case artistic   = "Artístico"
        case commercial = "Comercial"
        case nsfw       = "NSFW"
        case landscape  = "Paisaje"
        case concept    = "Concepto"

        var icon: String {
            switch self {
            case .general:    return "square.grid.2x2"
            case .portrait:   return "person.fill"
            case .fashion:    return "tshirt.fill"
            case .editorial:  return "magazine.fill"
            case .artistic:   return "paintpalette.fill"
            case .commercial: return "briefcase.fill"
            case .nsfw:       return "eye.slash.fill"
            case .landscape:  return "mountain.2.fill"
            case .concept:    return "lightbulb.fill"
            }
        }

        var color: String {
            switch self {
            case .general:    return "#8b8b8b"
            case .portrait:   return "#7c6af7"
            case .fashion:    return "#f472b6"
            case .editorial:  return "#3de3c0"
            case .artistic:   return "#f59e0b"
            case .commercial: return "#60a5fa"
            case .nsfw:       return "#ef4444"
            case .landscape:  return "#34d399"
            case .concept:    return "#a78bfa"
            }
        }
    }

    enum SourceType: String, Codable {
        case manual     = "Manual"
        case autoImport = "Auto-importado"
        case bulkImport = "Bulk import"
        case versioning = "Versioning"
    }

    var displayTitle: String {
        if !title.isEmpty { return title }
        let preview = positive.prefix(50)
        return String(preview) + (positive.count > 50 ? "…" : "")
    }
}

// MARK: - Search & Filter

struct PromptFilter {
    var query:       String                  = ""
    var category:    PromptEntry.Category?   = nil
    var minRating:   Int                     = 0
    var checkpoint:  String                  = ""
    var tags:        [String]                = []
    var favoritesOnly: Bool                  = false
    var sortMode:    SortMode                = .newest

    enum SortMode: String, CaseIterable {
        case newest   = "Más reciente"
        case oldest   = "Más antiguo"
        case rating   = "Rating"
        case mostUsed = "Más usado"
        case alpha    = "Alfabético"
    }

    var isEmpty: Bool {
        query.isEmpty && category == nil && minRating == 0 &&
        checkpoint.isEmpty && tags.isEmpty && !favoritesOnly
    }
}

// MARK: - PromptDatabase

@MainActor
final class PromptDatabase: ObservableObject {

    static let shared = PromptDatabase()
    private init() { loadDatabase() }

    static let maxEntries = 2000

    // MARK: - State

    @Published var entries:     [PromptEntry] = []
    @Published var filter:      PromptFilter  = PromptFilter()
    @Published var isImporting: Bool          = false

    private var dbURL: URL? {
        VaultManager.shared.vaultMetaURL?.appending(path: "prompt_database.json")
    }

    // MARK: - Computed

    var filtered: [PromptEntry] {
        applyFilter(filter, to: entries)
    }

    var favorites: [PromptEntry] {
        entries.filter { $0.isFavorite }
    }

    var topRated: [PromptEntry] {
        entries.filter { $0.rating >= 4 }.sorted { $0.rating > $1.rating }.prefix(20).map { $0 }
    }

    var mostUsed: [PromptEntry] {
        entries.sorted { $0.useCount > $1.useCount }.prefix(20).map { $0 }
    }

    var recentlyAdded: [PromptEntry] {
        entries.sorted { $0.createdAt > $1.createdAt }.prefix(20).map { $0 }
    }

    var checkpoints: [String] {
        Array(Set(entries.compactMap { $0.checkpoint.isEmpty ? nil : $0.checkpoint })).sorted()
    }

    var allTags: [String] {
        let tagSets = entries.map { Set($0.tags) }
        let all = tagSets.reduce(Set<String>()) { $0.union($1) }
        return all.sorted()
    }

    var stats: DatabaseStats {
        DatabaseStats(
            total:      entries.count,
            favorites:  entries.filter { $0.isFavorite }.count,
            withRating: entries.filter { $0.rating > 0 }.count,
            avgRating:  entries.filter { $0.rating > 0 }.map { Double($0.rating) }.reduce(0, +) /
                        Double(max(1, entries.filter { $0.rating > 0 }.count)),
            categories: Dictionary(grouping: entries) { $0.category }
                .mapValues { $0.count }
        )
    }

    struct DatabaseStats {
        var total:      Int
        var favorites:  Int
        var withRating: Int
        var avgRating:  Double
        var categories: [PromptEntry.Category: Int]
    }

    // MARK: - CRUD

    @discardableResult
    func save(_ entry: PromptEntry) -> PromptEntry {
        var e = entry
        e.updatedAt = Date()
        if let idx = entries.firstIndex(where: { $0.id == e.id }) {
            entries[idx] = e
        } else {
            entries.insert(e, at: 0)
            if entries.count > Self.maxEntries {
                entries = Array(entries.prefix(Self.maxEntries))
            }
        }
        saveDatabase()
        return e
    }

    /// Guarda un prompt desde el pipeline rápidamente
    @discardableResult
    func saveFromPipeline(
        positive:   String,
        negative:   String   = "",
        checkpoint: String   = "",
        steps:      Int      = 0,
        cfgScale:   Double   = 0,
        sampler:    String   = "",
        width:      Int      = 0,
        height:     Int      = 0,
        seed:       Int?     = nil,
        loraNames:  [String] = [],
        rating:     Int      = 0,
        category:   PromptEntry.Category = .general,
        title:      String   = ""
    ) -> PromptEntry {
        let entry = PromptEntry(
            positive:    positive,
            negative:    negative,
            checkpoint:  checkpoint,
            steps:       steps,
            cfgScale:    cfgScale,
            samplerName: sampler,
            width:       width,
            height:      height,
            seed:        seed,
            loraNames:   loraNames,
            title:       title,
            rating:      rating,
            category:    category,
            sourceType:  .manual
        )
        return save(entry)
    }

    func delete(_ entry: PromptEntry) {
        entries.removeAll { $0.id == entry.id }
        saveDatabase()
    }

    func delete(ids: Set<UUID>) {
        entries.removeAll { ids.contains($0.id) }
        saveDatabase()
    }

    func updateRating(_ entry: PromptEntry, rating: Int) {
        if let idx = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[idx].rating = max(0, min(5, rating))
            entries[idx].updatedAt = Date()
            saveDatabase()
        }
    }

    func toggleFavorite(_ entry: PromptEntry) {
        if let idx = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[idx].isFavorite.toggle()
            entries[idx].updatedAt = Date()
            saveDatabase()
        }
    }

    func recordUse(_ entry: PromptEntry) {
        if let idx = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[idx].useCount  += 1
            entries[idx].lastUsedAt = Date()
            saveDatabase()
        }
    }

    // MARK: - Import

    /// Importar desde PromptVersioningStore (prompts usados en generaciones)
    func importFromVersioningStore(minRating: Int = 0) {
        isImporting = true
        defer { isImporting = false }

        let existing = Set(entries.compactMap { $0.sourceAssetID?.uuidString ?? $0.positive })
        var imported = 0

        let versions = PromptVersioningStore.shared.versions
        for v in versions {
            if existing.contains(v.positive) { continue }
            let entry = PromptEntry(
                positive:    v.positive,
                negative:    v.negative,
                checkpoint:  v.checkpoint,
                steps:       v.steps,
                cfgScale:    v.cfgScale,
                samplerName: v.samplerName,
                width:       v.width,
                height:      v.height,
                sourceType:  .versioning
            )
            entries.append(entry)
            imported += 1
        }

        if entries.count > Self.maxEntries {
            entries = Array(entries.prefix(Self.maxEntries))
        }

        if imported > 0 { saveDatabase() }
    }

    /// Importar desde archivo .txt (un prompt por línea)
    func importFromTxt(url: URL) {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        isImporting = true
        defer { isImporting = false }

        let lines = content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        for line in lines {
            let entry = PromptEntry(
                positive:   line,
                sourceType: .bulkImport
            )
            entries.append(entry)
        }

        if entries.count > Self.maxEntries {
            entries = Array(entries.prefix(Self.maxEntries))
        }
        saveDatabase()
    }

    // MARK: - Filter

    func applyFilter(_ f: PromptFilter, to list: [PromptEntry]) -> [PromptEntry] {
        var result = list

        if !f.query.isEmpty {
            let q = f.query.lowercased()
            result = result.filter {
                $0.positive.lowercased().contains(q) ||
                $0.negative.lowercased().contains(q) ||
                $0.title.lowercased().contains(q) ||
                $0.notes.lowercased().contains(q) ||
                $0.tags.contains { $0.lowercased().contains(q) } ||
                $0.checkpoint.lowercased().contains(q)
            }
        }

        if let cat = f.category {
            result = result.filter { $0.category == cat }
        }

        if f.minRating > 0 {
            result = result.filter { $0.rating >= f.minRating }
        }

        if !f.checkpoint.isEmpty {
            result = result.filter { $0.checkpoint == f.checkpoint }
        }

        if !f.tags.isEmpty {
            result = result.filter { entry in
                f.tags.allSatisfy { entry.tags.contains($0) }
            }
        }

        if f.favoritesOnly {
            result = result.filter { $0.isFavorite }
        }

        switch f.sortMode {
        case .newest:   result.sort { $0.createdAt   > $1.createdAt }
        case .oldest:   result.sort { $0.createdAt   < $1.createdAt }
        case .rating:   result.sort { $0.rating      > $1.rating }
        case .mostUsed: result.sort { $0.useCount    > $1.useCount }
        case .alpha:    result.sort { $0.displayTitle < $1.displayTitle }
        }

        return result
    }

    // MARK: - Persistence

    private func loadDatabase() {
        guard let url  = dbURL,
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder.iso8601.decode([PromptEntry].self, from: data)
        else { return }
        entries = list
    }

    func saveDatabase() {
        guard let url  = dbURL,
              let data = try? JSONEncoder.pretty.encode(entries)
        else { return }
        try? data.write(to: url)
    }
}

// MARK: - PromptDatabaseView

struct PromptDatabaseView: View {

    var onSelect: ((PromptEntry) -> Void)? = nil

    @StateObject private var db = PromptDatabase.shared
    @State private var selectedEntry:    PromptEntry? = nil
    @State private var editingEntry:     PromptEntry? = nil
    @State private var showImportMenu:   Bool = false
    @State private var showNewEntry:     Bool = false
    @State private var activeTab:        ViewTab = .all

    enum ViewTab: String, CaseIterable {
        case all       = "Todos"
        case favorites = "Favoritos"
        case top       = "Top"
        case recent    = "Recientes"
    }

    var displayedEntries: [PromptEntry] {
        switch activeTab {
        case .all:       return db.filtered
        case .favorites: return db.favorites
        case .top:       return db.topRated
        case .recent:    return db.recentlyAdded
        }
    }

    var body: some View {
        HSplitView {
            // Left: list
            VStack(spacing: 0) {
                dbHeader
                Divider().background(Color.white.opacity(0.07))
                filterBar
                Divider().background(Color.white.opacity(0.05))
                tabRow
                Divider().background(Color.white.opacity(0.05))
                promptList
            }
            .frame(minWidth: 300, maxWidth: 480)

            // Right: detail
            if let entry = selectedEntry {
                PromptDetailView(
                    entry: entry,
                    onUse: {
                        db.recordUse(entry)
                        onSelect?(entry)
                    },
                    onEdit:   { editingEntry = entry },
                    onDelete: { db.delete(entry); selectedEntry = nil },
                    onFavorite: { db.toggleFavorite(entry) }
                )
            } else {
                VStack {
                    Spacer()
                    Image(systemName: "text.cursor")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary.opacity(0.3))
                    Text("Selecciona un prompt")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .background(Color(red: 0.08, green: 0.08, blue: 0.10))
            }
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
        .sheet(item: $editingEntry) { entry in
            PromptEntryEditorSheet(entry: entry) { updated in
                db.save(updated)
                selectedEntry = updated
            }
        }
    }

    // MARK: - DB Header

    var dbHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.book.closed.fill")
                .font(.system(size: 13))
                .foregroundColor(Color(hex: "#7c6af7"))
            VStack(alignment: .leading, spacing: 1) {
                Text("Prompt Database")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                Text("\(db.entries.count) prompts · \(db.favorites.count) favoritos")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button(action: { showNewEntry = true }) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(Color(hex: "#7c6af7"))
            }
            .buttonStyle(.plain)
            .help("Nuevo prompt")

            Menu {
                Button("Importar desde VersioningStore") {
                    db.importFromVersioningStore()
                }
                Button("Importar desde .txt…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.plainText]
                    if panel.runModal() == .OK, let url = panel.url {
                        db.importFromTxt(url: url)
                    }
                }
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .menuStyle(.borderlessButton)
            .help("Importar prompts")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.white.opacity(0.03))
        .sheet(isPresented: $showNewEntry) {
            PromptEntryEditorSheet(entry: PromptEntry(positive: "")) { entry in
                db.save(entry)
            }
        }
    }

    // MARK: - Filter Bar

    var filterBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                TextField("Buscar prompts…", text: $db.filter.query)
                    .font(.system(size: 11))
                    .textFieldStyle(.plain)
                if !db.filter.query.isEmpty {
                    Button(action: { db.filter.query = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color.white.opacity(0.05))
            .cornerRadius(6)
            .padding(.horizontal, 10)

            HStack(spacing: 6) {
                // Category filter
                Picker("", selection: $db.filter.category) {
                    Text("Categorías").tag(nil as PromptEntry.Category?)
                    ForEach(PromptEntry.Category.allCases, id: \.self) { cat in
                        Label(cat.rawValue, systemImage: cat.icon).tag(Optional(cat))
                    }
                }
                .pickerStyle(.menu)
                .font(.system(size: 10))
                .frame(maxWidth: 140)

                // Checkpoint filter
                if !db.checkpoints.isEmpty {
                    Picker("", selection: $db.filter.checkpoint) {
                        Text("Modelo").tag("")
                        ForEach(db.checkpoints, id: \.self) { cp in
                            Text(cp.prefix(22)).tag(cp)
                        }
                    }
                    .pickerStyle(.menu)
                    .font(.system(size: 10))
                    .frame(maxWidth: 130)
                }

                // Sort
                Picker("", selection: $db.filter.sortMode) {
                    ForEach(PromptFilter.SortMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .font(.system(size: 10))
                .frame(maxWidth: 110)

                Spacer()

                Toggle("★", isOn: $db.filter.favoritesOnly)
                    .toggleStyle(.button)
                    .help("Solo favoritos")
                    .font(.system(size: 11))
            }
            .padding(.horizontal, 10)
        }
        .padding(.vertical, 6)
    }

    // MARK: - Tab Row

    var tabRow: some View {
        HStack(spacing: 0) {
            ForEach(ViewTab.allCases, id: \.self) { tab in
                Button(action: { activeTab = tab }) {
                    Text(tab.rawValue)
                        .font(.system(size: 11, weight: activeTab == tab ? .semibold : .regular))
                        .foregroundColor(activeTab == tab ? .white : .secondary)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(activeTab == tab ? Color.white.opacity(0.07) : Color.clear)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text("\(displayedEntries.count)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .padding(.trailing, 10)
        }
        .background(Color.white.opacity(0.02))
    }

    // MARK: - Prompt List

    var promptList: some View {
        List(displayedEntries, selection: $selectedEntry) { entry in
            PromptEntryRow(
                entry: entry,
                isSelected: selectedEntry?.id == entry.id,
                onSelect: { selectedEntry = entry },
                onFavorite: { db.toggleFavorite(entry) },
                onRating: { db.updateRating(entry, rating: $0) }
            )
            .tag(entry)
        }
        .listStyle(.plain)
    }
}

// MARK: - PromptEntryRow

struct PromptEntryRow: View {
    let entry:      PromptEntry
    let isSelected: Bool
    var onSelect:   () -> Void
    var onFavorite: () -> Void
    var onRating:   (Int) -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                // Category color bar
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(hex: entry.category.color))
                    .frame(width: 3, height: 36)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(entry.displayTitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white)
                            .lineLimit(1)

                        Spacer()

                        if entry.useCount > 0 {
                            Text("\(entry.useCount)×")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }

                        Button(action: onFavorite) {
                            Image(systemName: entry.isFavorite ? "star.fill" : "star")
                                .font(.system(size: 10))
                                .foregroundColor(entry.isFavorite ? Color(hex: "#f59e0b") : .secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    Text(entry.positive)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .lineLimit(2)

                    HStack(spacing: 6) {
                        if !entry.checkpoint.isEmpty {
                            Text(entry.checkpoint.prefix(18))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.secondary.opacity(0.6))
                        }

                        // Mini star rating
                        HStack(spacing: 1) {
                            ForEach(1...5, id: \.self) { i in
                                Image(systemName: i <= entry.rating ? "star.fill" : "star")
                                    .font(.system(size: 7))
                                    .foregroundColor(i <= entry.rating ? Color(hex: "#f59e0b") : .secondary.opacity(0.3))
                                    .onTapGesture { onRating(i) }
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? Color(hex: "#7c6af7").opacity(0.12) : Color.clear)
    }
}

// MARK: - PromptDetailView

struct PromptDetailView: View {
    let entry:      PromptEntry
    var onUse:      () -> Void
    var onEdit:     () -> Void
    var onDelete:   () -> Void
    var onFavorite: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                // Title + actions
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.displayTitle)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                        HStack(spacing: 6) {
                            Label(entry.category.rawValue, systemImage: entry.category.icon)
                                .font(.system(size: 10))
                                .foregroundColor(Color(hex: entry.category.color))
                            Text("·  \(entry.useCount) usos")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }

                    Spacer()

                    Button(action: onFavorite) {
                        Image(systemName: entry.isFavorite ? "star.fill" : "star")
                            .font(.system(size: 14))
                            .foregroundColor(entry.isFavorite ? Color(hex: "#f59e0b") : .secondary)
                    }
                    .buttonStyle(.plain)

                    Button(action: onEdit) {
                        Image(systemName: "pencil.circle")
                            .font(.system(size: 16))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Divider().background(Color.white.opacity(0.07))

                // Positive prompt
                promptBlock("Prompt Positivo", text: entry.positive, color: Color(hex: "#3de3c0"))

                // Negative prompt
                if !entry.negative.isEmpty {
                    promptBlock("Prompt Negativo", text: entry.negative, color: Color(hex: "#ef4444"))
                }

                Divider().background(Color.white.opacity(0.07))

                // Generation params
                if entry.steps > 0 || !entry.checkpoint.isEmpty {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: 6) {
                        if !entry.checkpoint.isEmpty {
                            paramCell("Modelo", value: entry.checkpoint)
                        }
                        if !entry.samplerName.isEmpty {
                            paramCell("Sampler", value: entry.samplerName)
                        }
                        if entry.steps > 0 {
                            paramCell("Steps", value: "\(entry.steps)")
                        }
                        if entry.cfgScale > 0 {
                            paramCell("CFG", value: String(format: "%.1f", entry.cfgScale))
                        }
                        if entry.width > 0 && entry.height > 0 {
                            paramCell("Resolución", value: "\(entry.width)×\(entry.height)")
                        }
                        if let seed = entry.seed {
                            paramCell("Seed", value: "\(seed)")
                        }
                    }
                }

                // Rating
                HStack(spacing: 4) {
                    Text("Rating:")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    ForEach(1...5, id: \.self) { i in
                        Image(systemName: i <= entry.rating ? "star.fill" : "star")
                            .font(.system(size: 14))
                            .foregroundColor(i <= entry.rating ? Color(hex: "#f59e0b") : .secondary.opacity(0.3))
                    }
                }

                // Notes
                if !entry.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Notas")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)
                        Text(entry.notes)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.8))
                    }
                }

                Divider().background(Color.white.opacity(0.07))

                // Actions
                HStack(spacing: 8) {
                    Button(action: onUse) {
                        Label("Usar prompt", systemImage: "arrow.right.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(LinearGradient(
                                colors: [Color(hex: "#7c6af7"), Color(hex: "#5b4ecf")],
                                startPoint: .leading, endPoint: .trailing))
                            .foregroundColor(.white)
                            .cornerRadius(7)
                    }
                    .buttonStyle(.plain)

                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(entry.positive, forType: .string)
                    }) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12))
                            .padding(8)
                            .background(Color.white.opacity(0.08))
                            .cornerRadius(7)
                    }
                    .buttonStyle(.plain)
                    .help("Copiar prompt al portapapeles")

                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .padding(8)
                            .background(Color(hex: "#ef4444").opacity(0.15))
                            .foregroundColor(Color(hex: "#ef4444"))
                            .cornerRadius(7)
                    }
                    .buttonStyle(.plain)
                    .help("Eliminar")
                }
            }
            .padding(16)
        }
        .background(Color(red: 0.08, green: 0.08, blue: 0.10))
    }

    func promptBlock(_ label: String, text: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(color)
                    .textCase(.uppercase)
                Spacer()
                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.85))
                .textSelection(.enabled)
                .padding(8)
                .background(color.opacity(0.06))
                .cornerRadius(6)
        }
    }

    func paramCell(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Color.white.opacity(0.04))
        .cornerRadius(5)
    }
}

// MARK: - PromptEntryEditorSheet

struct PromptEntryEditorSheet: View {
    @State var entry:  PromptEntry
    var onSave: (PromptEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var newTag = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Editar Prompt")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Button("Cancelar") { dismiss() }.buttonStyle(.plain).foregroundColor(.secondary)
                Button("Guardar") { entry.updatedAt = Date(); onSave(entry); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(hex: "#7c6af7"))
                    .controlSize(.small)
            }
            .padding(16)
            .background(Color.white.opacity(0.03))

            Divider().background(Color.white.opacity(0.07))

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    TextField("Título (opcional)", text: $entry.title)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Prompt Positivo").font(.system(size: 10)).foregroundColor(.secondary)
                        TextEditor(text: $entry.positive)
                            .font(.system(size: 11))
                            .frame(minHeight: 100)
                            .background(Color.white.opacity(0.04))
                            .cornerRadius(5)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Prompt Negativo").font(.system(size: 10)).foregroundColor(.secondary)
                        TextEditor(text: $entry.negative)
                            .font(.system(size: 11))
                            .frame(minHeight: 50)
                            .background(Color.white.opacity(0.04))
                            .cornerRadius(5)
                    }

                    HStack(spacing: 12) {
                        Picker("Categoría", selection: $entry.category) {
                            ForEach(PromptEntry.Category.allCases, id: \.self) { cat in
                                Label(cat.rawValue, systemImage: cat.icon).tag(cat)
                            }
                        }
                        .pickerStyle(.menu)
                        .font(.system(size: 11))

                        HStack(spacing: 2) {
                            ForEach(1...5, id: \.self) { i in
                                Image(systemName: i <= entry.rating ? "star.fill" : "star")
                                    .font(.system(size: 16))
                                    .foregroundColor(i <= entry.rating ? Color(hex: "#f59e0b") : .secondary)
                                    .onTapGesture { entry.rating = i }
                            }
                        }

                        Toggle("Favorito", isOn: $entry.isFavorite)
                            .font(.system(size: 11))
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Notas").font(.system(size: 10)).foregroundColor(.secondary)
                        TextEditor(text: $entry.notes)
                            .font(.system(size: 11))
                            .frame(minHeight: 50)
                            .background(Color.white.opacity(0.04))
                            .cornerRadius(5)
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 480, height: 520)
        .background(Color(red: 0.10, green: 0.10, blue: 0.13))
    }
}
