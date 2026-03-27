import SwiftUI
import AppKit
import CoreData
import Combine

// MARK: - GalleryView
// Panel de galería completo: grid de thumbnails, búsqueda, filtros,
// inspector de metadatos, rating curator y seed reuse.

struct GalleryView: View {

    // Callback para reutilizar seed/prompt en el pipeline principal
    var onReuseSettings: (ReusableSettings) -> Void

    @StateObject private var store = AssetStore.shared
    @State private var searchQuery:    String = ""
    @State private var selectedStatus: AssetStatus? = nil
    @State private var selectedRating: Int = 0              // 0 = todos
    @State private var selectedAsset:  GeneratedAsset? = nil
    @State private var showInspector:  Bool = false
    @State private var gridColumns:    Int = 3
    @State private var sortNewest:     Bool = true

    // Configuración de columnas dinámica
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 8), count: gridColumns)
    }

    var filteredAssets: [GeneratedAsset] {
        var assets = store.recentAssets

        if !searchQuery.isEmpty {
            assets = assets.filter {
                ($0.promptPositive ?? "").localizedCaseInsensitiveContains(searchQuery) ||
                ($0.sessionTag ?? "").localizedCaseInsensitiveContains(searchQuery) ||
                ($0.baseName ?? "").localizedCaseInsensitiveContains(searchQuery)
            }
        }
        if let status = selectedStatus {
            assets = assets.filter { $0.statusEnum == status }
        }
        if selectedRating > 0 {
            assets = assets.filter { $0.rating >= Int32(selectedRating) }
        }
        return sortNewest ? assets : assets.reversed()
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().background(Color.white.opacity(0.07))
            filterBar
            Divider().background(Color.white.opacity(0.07))

            if filteredAssets.isEmpty {
                emptyState
            } else {
                HSplitView {
                    gridPanel
                    if showInspector, let asset = selectedAsset {
                        MetadataInspector(
                            asset: asset,
                            onReuse: { settings in
                                onReuseSettings(settings)
                            },
                            onClose: { showInspector = false }
                        )
                        .frame(minWidth: 260, maxWidth: 300)
                    }
                }
            }
        }
        .background(Color(red: 0.08, green: 0.08, blue: 0.10))
        .onAppear { store.fetchRecentAssets() }
    }

    // MARK: - Toolbar

    var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "photo.stack")
                .foregroundColor(.secondary).font(.system(size: 13))
            Text("Galería")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))
            Text("\(filteredAssets.count)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.white.opacity(0.06))
                .cornerRadius(4)
            Spacer()

            // Grid size control
            HStack(spacing: 4) {
                ForEach([2, 3, 4], id: \.self) { cols in
                    Button(action: { gridColumns = cols }) {
                        Image(systemName: cols == 2 ? "square.grid.2x2" :
                              cols == 3 ? "square.grid.3x3" : "square.grid.4x3.fill")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(gridColumns == cols ? Color(hex: "#7c6af7") : .secondary)
                }
            }

            Button(action: { sortNewest.toggle() }) {
                Image(systemName: sortNewest ? "arrow.down.circle" : "arrow.up.circle")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain).foregroundColor(.secondary)
            .help(sortNewest ? "Más recientes primero" : "Más antiguos primero")

            Button(action: { showInspector.toggle() }) {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .foregroundColor(showInspector ? Color(hex: "#7c6af7") : .secondary)
            .help("Inspector de metadatos")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.white.opacity(0.03))
    }

    // MARK: - Filter Bar

    var filterBar: some View {
        HStack(spacing: 10) {
            // Search
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                TextField("Buscar por prompt, sesión…", text: $searchQuery)
                    .font(.system(size: 12))
                    .textFieldStyle(.plain)
                    .foregroundColor(.white)
                if !searchQuery.isEmpty {
                    Button(action: { searchQuery = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10)).foregroundColor(.secondary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.white.opacity(0.05))
            .cornerRadius(6)

            Divider().frame(height: 16).background(Color.white.opacity(0.1))

            // Status filter
            Menu {
                Button("Todos") { selectedStatus = nil }
                Divider()
                ForEach(AssetStatus.allCases, id: \.self) { s in
                    Button(s.label) { selectedStatus = s }
                }
            } label: {
                HStack(spacing: 4) {
                    Circle().fill(statusColor(selectedStatus))
                        .frame(width: 6, height: 6)
                    Text(selectedStatus?.label ?? "Estado")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9)).foregroundColor(.secondary)
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color.white.opacity(0.05)).cornerRadius(5)
            }
            .buttonStyle(.plain)

            // Rating filter
            Menu {
                Button("Todos") { selectedRating = 0 }
                Divider()
                ForEach(1...5, id: \.self) { r in
                    Button(String(repeating: "★", count: r)) { selectedRating = r }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 10))
                        .foregroundColor(selectedRating > 0 ? .yellow : .secondary)
                    Text(selectedRating > 0 ? String(repeating: "★", count: selectedRating) : "Rating")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9)).foregroundColor(.secondary)
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color.white.opacity(0.05)).cornerRadius(5)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color(red: 0.09, green: 0.09, blue: 0.11))
    }

    // MARK: - Grid

    var gridPanel: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(filteredAssets, id: \.id) { asset in
                    GalleryCell(
                        asset: asset,
                        isSelected: selectedAsset?.id == asset.id,
                        onTap: {
                            selectedAsset = asset
                            showInspector = true
                        },
                        onRatingChange: { rating in
                            store.updateRating(asset, rating: rating)
                        },
                        onStatusChange: { status in
                            store.updateStatus(asset, status: status)
                        }
                    )
                }
            }
            .padding(10)
        }
    }

    // MARK: - Empty State

    var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.stack")
                .font(.system(size: 44)).foregroundColor(.white.opacity(0.08))
            Text(searchQuery.isEmpty ? "Sin generaciones todavía" : "Sin resultados para \"\(searchQuery)\"")
                .font(.system(size: 13)).foregroundColor(.white.opacity(0.2))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func statusColor(_ status: AssetStatus?) -> Color {
        switch status {
        case .draft:     return .gray
        case .approved:  return .green
        case .published: return .blue
        case .rejected:  return .red
        case nil:        return .clear
        }
    }
}

// MARK: - GalleryCell

struct GalleryCell: View {
    let asset:           GeneratedAsset
    let isSelected:      Bool
    var onTap:           () -> Void
    var onRatingChange:  (Int) -> Void
    var onStatusChange:  (AssetStatus) -> Void

    @State private var hovered = false

    var body: some View {
        ZStack(alignment: .bottom) {
            // Thumbnail
            Group {
                if let thumb = asset.thumbnail {
                    Image(nsImage: thumb)
                        .resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(Color.white.opacity(0.04))
                        .overlay(
                            Image(systemName: "photo")
                                .foregroundColor(.secondary)
                        )
                }
            }
            .frame(minHeight: 120)
            .clipped()

            // Hover overlay
            if hovered || isSelected {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.75)],
                    startPoint: .center, endPoint: .bottom
                )

                VStack(spacing: 0) {
                    Spacer()
                    HStack(spacing: 4) {
                        // Rating stars
                        HStack(spacing: 2) {
                            ForEach(1...5, id: \.self) { star in
                                Button(action: {
                                    onRatingChange(asset.rating == Int32(star) ? 0 : star)
                                }) {
                                    Image(systemName: Int32(star) <= asset.rating ? "star.fill" : "star")
                                        .font(.system(size: 9))
                                        .foregroundColor(Int32(star) <= asset.rating ? .yellow : .white.opacity(0.4))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        Spacer()
                        // Status dot
                        statusDot
                    }
                    .padding(6)
                }
            }

            // Selection ring
            if isSelected {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(hex: "#7c6af7"), lineWidth: 2)
            }
        }
        .cornerRadius(6)
        .aspectRatio(CGFloat(asset.width) / max(CGFloat(asset.height), 1), contentMode: .fit)
        .onTapGesture { onTap() }
        .onHover { hovered = $0 }
        .contextMenu { contextMenuItems }
    }

    var statusDot: some View {
        Circle()
            .fill(assetStatusColor)
            .frame(width: 6, height: 6)
            .help(asset.statusEnum.label)
    }

    var assetStatusColor: Color {
        switch asset.statusEnum {
        case .draft:     return .gray
        case .approved:  return .green
        case .published: return .blue
        case .rejected:  return .red
        }
    }

    @ViewBuilder
    var contextMenuItems: some View {
        Text(asset.baseName ?? "Asset").font(.headline)
        Divider()
        Menu("Cambiar estado") {
            ForEach(AssetStatus.allCases, id: \.self) { s in
                Button(s.label) { onStatusChange(s) }
            }
        }
        Menu("Rating") {
            Button("Sin rating") { onRatingChange(0) }
            ForEach(1...5, id: \.self) { r in
                Button(String(repeating: "★", count: r)) { onRatingChange(r) }
            }
        }
        Divider()
        Button("Abrir en Finder") {
            if let path = asset.imagePath {
                NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
            }
        }
    }
}

// MARK: - MetadataInspector

struct MetadataInspector: View {
    let asset:   GeneratedAsset
    var onReuse: (ReusableSettings) -> Void
    var onClose: () -> Void

    @State private var showFullPrompt  = false
    @State private var exportMessage:  String? = nil

    // MARK: - Export Action

    private func exportAsset() {
        // ExportEngine.export(asset:) es async throws — lanzar desde Task en el MainActor.
        // WatermarkConfig y la selección de rutas son responsabilidad de ExportEngine;
        // GalleryView solo dispara la exportación y muestra el resultado.
        Task { @MainActor in
            do {
                let result = try await ExportEngine.shared.export(asset: asset)
                // Revelar en Finder
                NSWorkspace.shared.selectFile(result.cleanURL.path, inFileViewerRootedAtPath: "")
                exportMessage = "✓ Exportado correctamente"
            } catch {
                exportMessage = "⚠️ Error al exportar: \(error.localizedDescription)"
            }
            // Limpiar mensaje tras 3s
            try? await Task.sleep(for: .seconds(3))
            exportMessage = nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Inspector")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(5).background(Color.white.opacity(0.06))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color.white.opacity(0.03))

            Divider().background(Color.white.opacity(0.07))

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {

                    // Preview
                    if let thumb = asset.thumbnail {
                        Image(nsImage: thumb)
                            .resizable().aspectRatio(contentMode: .fit)
                            .cornerRadius(6)
                    }

                    // Identity
                    infoSection("ASSET") {
                        infoRow("ID",      asset.baseName ?? "-")
                        infoRow("Fecha",   formatDate(asset.createdAt))
                        infoRow("Estado",  asset.statusEnum.label)
                        infoRow("Rating",  asset.rating > 0 ? String(repeating: "★", count: Int(asset.rating)) : "Sin calificar")
                        if let tag = asset.sessionTag {
                            infoRow("Sesión", tag)
                        }
                    }

                    // Prompt
                    infoSection("PROMPT") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(asset.promptPositive ?? "-")
                                .font(.system(size: 11))
                                .foregroundColor(Color(red: 0.85, green: 0.95, blue: 0.78))
                                .lineLimit(showFullPrompt ? nil : 4)
                                .fixedSize(horizontal: false, vertical: true)
                            if (asset.promptPositive?.count ?? 0) > 150 {
                                Button(showFullPrompt ? "Ver menos" : "Ver todo") {
                                    showFullPrompt.toggle()
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 10))
                                .foregroundColor(Color(hex: "#7c6af7"))
                            }
                        }
                        .padding(8)
                        .background(Color.white.opacity(0.04))
                        .cornerRadius(5)
                    }

                    // Generation params
                    infoSection("PARÁMETROS") {
                        infoRow("Seed",    "\(asset.seed)")
                        infoRow("Steps",   "\(asset.steps)")
                        infoRow("CFG",     String(format: "%.1f", asset.cfgScale))
                        infoRow("Sampler", asset.samplerName ?? "-")
                        infoRow("Size",    "\(asset.width)×\(asset.height)")
                    }

                    // Model
                    if let checkpoint = asset.checkpoint, !checkpoint.isEmpty {
                        infoSection("MODELO") {
                            infoRow("Checkpoint", checkpoint)
                            if let vae = asset.vaeUsed, !vae.isEmpty {
                                infoRow("VAE", vae)
                            }
                            if !asset.loraWeights.isEmpty {
                                infoRow("LoRAs", asset.loraWeights.map {
                                    "\($0.key): \(String(format: "%.2f", $0.value))"
                                }.joined(separator: "\n"))
                            }
                        }
                    }

                    // Integrity
                    if let sha = asset.sha256 {
                        infoSection("INTEGRIDAD") {
                            Text(sha)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                    }

                    // Action buttons
                    VStack(spacing: 8) {
                        // ── Exportar clean + preview ─────────────────────────
                        Button(action: exportAsset) {
                            Label("Exportar Clean + Preview", systemImage: "square.and.arrow.up.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .frame(maxWidth: .infinity).padding(.vertical, 8)
                                .background(
                                    LinearGradient(
                                        colors: [Color(hex: "#3de3c0"), Color(hex: "#7c6af7")],
                                        startPoint: .leading, endPoint: .trailing
                                    )
                                )
                                .foregroundColor(.white).cornerRadius(7)
                        }
                        .buttonStyle(.plain)

                        // ── Reutilizar settings ──────────────────────────────
                        Button(action: {
                            onReuse(ReusableSettings(
                                seed:           Int(asset.seed),
                                steps:          Int(asset.steps),
                                cfgScale:       asset.cfgScale,
                                samplerName:    asset.samplerName ?? "DPM++ 2M Karras",
                                width:          Int(asset.width),
                                height:         Int(asset.height),
                                promptPositive: asset.promptPositive ?? "",
                                promptNegative: asset.promptNegative ?? "",
                                checkpoint:     asset.checkpoint ?? ""
                            ))
                        }) {
                            Label("Reutilizar Todo", systemImage: "arrow.uturn.left.circle.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .frame(maxWidth: .infinity).padding(.vertical, 8)
                                .background(Color(hex: "#7c6af7"))
                                .foregroundColor(.white).cornerRadius(7)
                        }
                        .buttonStyle(.plain)

                        Button(action: {
                            onReuse(ReusableSettings(
                                seed:           Int(asset.seed),
                                steps:          Int(asset.steps),
                                cfgScale:       asset.cfgScale,
                                samplerName:    asset.samplerName ?? "DPM++ 2M Karras",
                                width:          Int(asset.width),
                                height:         Int(asset.height),
                                promptPositive: "",   // No reutilizar prompt
                                promptNegative: asset.promptNegative ?? "",
                                checkpoint:     asset.checkpoint ?? ""
                            ))
                        }) {
                            Label("Solo Seed + Config", systemImage: "number.circle")
                                .font(.system(size: 12))
                                .frame(maxWidth: .infinity).padding(.vertical, 7)
                                .background(Color.white.opacity(0.07))
                                .foregroundColor(.white.opacity(0.8)).cornerRadius(7)
                        }
                        .buttonStyle(.plain)

                        Button(action: {
                            if let path = asset.imagePath {
                                NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                            }
                        }) {
                            Label("Abrir en Finder", systemImage: "folder")
                                .font(.system(size: 12))
                                .frame(maxWidth: .infinity).padding(.vertical, 7)
                                .background(Color.white.opacity(0.05))
                                .foregroundColor(.secondary).cornerRadius(7)
                        }
                        .buttonStyle(.plain)

                        // Feedback de export
                        if let msg = exportMessage {
                            Text(msg)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(msg.hasPrefix("✓") ? Color(hex: "#3de3c0") : Color(red: 1, green: 0.45, blue: 0.4))
                                .frame(maxWidth: .infinity, alignment: .center)
                                .transition(.opacity)
                        }
                    }
                }
                .padding(12)
            }
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
    }

    // MARK: - Inspector Helpers

    @ViewBuilder
    func infoSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(Color(hex: "#7c6af7"))
                .tracking(1.5)
            content()
        }
    }

    func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 64, alignment: .trailing)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white.opacity(0.8))
                .textSelection(.enabled)
            Spacer()
        }
    }

    func formatDate(_ date: Date?) -> String {
        guard let date else { return "-" }
        let f = DateFormatter()
        f.dateFormat = "dd MMM yyyy  HH:mm"
        return f.string(from: date)
    }
}

// MARK: - ReusableSettings
// Struct de transporte para devolver configuraciones al pipeline principal.

struct ReusableSettings {
    var seed:           Int
    var steps:          Int
    var cfgScale:       Double
    var samplerName:    String
    var width:          Int
    var height:         Int
    var promptPositive: String
    var promptNegative: String
    var checkpoint:     String
}

// MARK: - SeedManager
// Gestiona seeds favoritos por personaje/sesión.
// Persiste en el vault como JSON ligero.

@MainActor
final class SeedManager: ObservableObject {

    static let shared = SeedManager()
    private init() { load() }

    @Published var favorites: [FavoriteSeed] = []

    struct FavoriteSeed: Codable, Identifiable {
        var id:          UUID    = UUID()
        var seed:        Int
        var label:       String              // Descripción libre
        var characterTag: String?            // Personaje al que está asociado
        var promptHint:  String?             // Primeras palabras del prompt
        var addedAt:     Date    = Date()
        var timesUsed:   Int     = 0
    }

    // MARK: - Public API

    func addFavorite(seed: Int, label: String, characterTag: String? = nil, promptHint: String? = nil) {
        // Evitar duplicados por seed
        guard !favorites.contains(where: { $0.seed == seed }) else { return }
        let fav = FavoriteSeed(
            seed:         seed,
            label:        label,
            characterTag: characterTag,
            promptHint:   promptHint
        )
        favorites.insert(fav, at: 0)
        save()
    }

    func removeFavorite(id: UUID) {
        favorites.removeAll { $0.id == id }
        save()
    }

    func incrementUsage(seed: Int) {
        if let idx = favorites.firstIndex(where: { $0.seed == seed }) {
            favorites[idx].timesUsed += 1
            save()
        }
    }

    /// Registrar uso de seed tras generación. Llamado por PipelineConnector.
    func recordUsage(seed: Int, promptHint: String = "", width: Int = 512, height: Int = 768) {
        guard seed > 0 else { return }
        incrementUsage(seed: seed)
    }

    /// ¿Está el seed en favoritos?
    func isFavorite(_ seed: Int) -> Bool {
        favorites.contains { $0.seed == seed }
    }

    func favorites(for character: String) -> [FavoriteSeed] {
        favorites.filter { $0.characterTag == character }
    }

    // MARK: - Persistence

    private var storageURL: URL? {
        VaultManager.shared.vaultMetaURL?.appending(path: "seed_favorites.json")
    }

    private func save() {
        guard let url = storageURL else { return }
        try? JSONEncoder.pretty.encode(favorites).write(to: url, options: .atomic)
    }

    private func load() {
        guard let url = storageURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder.iso8601.decode([FavoriteSeed].self, from: data)
        else { return }
        favorites = decoded
    }
}

// MARK: - PromptHistory
// Registro de prompts exitosos (rating >= 4) para reutilización y referencia.

@MainActor
final class PromptHistory: ObservableObject {

    static let shared = PromptHistory()
    private init() { load() }

    @Published var entries: [PromptEntry] = []

    struct PromptEntry: Codable, Identifiable {
        var id:           UUID    = UUID()
        var positive:     String
        var negative:     String
        var seed:         Int
        var rating:       Int
        var usageCount:   Int     = 1
        var lastUsed:     Date    = Date()
        var tags:         [String] = []
        var assetID:      String?  // UUID del asset asociado
    }

    func record(positive: String, negative: String, seed: Int, rating: Int = 0, assetID: String? = nil) {
        // Deduplicar por prompt positivo exacto
        if let idx = entries.firstIndex(where: { $0.positive == positive }) {
            entries[idx].usageCount += 1
            entries[idx].lastUsed = Date()
            entries[idx].rating = max(entries[idx].rating, rating)
        } else {
            entries.insert(PromptEntry(
                positive:  positive,
                negative:  negative,
                seed:      seed,
                rating:    rating,
                assetID:   assetID
            ), at: 0)
            // Mantener solo los últimos 500 prompts
            if entries.count > 500 { entries = Array(entries.prefix(500)) }
        }
        save()
    }

    /// Prompts con rating >= umbral, ordenados por uso.
    func topPrompts(minRating: Int = 4, limit: Int = 20) -> [PromptEntry] {
        entries
            .filter { $0.rating >= minRating }
            .sorted { $0.usageCount > $1.usageCount }
            .prefix(limit)
            .map { $0 }
    }

    private var storageURL: URL? {
        VaultManager.shared.vaultMetaURL?.appending(path: "prompt_history.json")
    }

    private func save() {
        guard let url = storageURL else { return }
        try? JSONEncoder.pretty.encode(entries).write(to: url, options: .atomic)
    }

    private func load() {
        guard let url = storageURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder.iso8601.decode([PromptEntry].self, from: data)
        else { return }
        entries = decoded
    }
}
