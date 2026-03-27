import SwiftUI
import AppKit
import CoreData
import Combine

// MARK: - GalleryView
//
// v2 — Galería completa con:
//   - TagFilterBar integrada (filtros por tag AND/OR)
//   - Bulk actions (aprobar / rechazar / exportar selección)
//   - RatingCuratorView integrado en inspector
//   - Search por prompt, tag y session
//   - Sorting múltiple (fecha, rating, status)
//   - Integración NSFWStatusBadge en thumbnails
//   - Inspector de metadatos completo

struct GalleryView: View {

    var onReuseSettings: (ReusableSettings) -> Void

    @StateObject private var store        = AssetStore.shared
    @StateObject private var tagging      = TaggingEngine.shared

    // Filters
    @State private var searchQuery:    String       = ""
    @State private var selectedStatus: AssetStatus? = nil
    @State private var selectedRating: Int          = 0
    @State private var activeTags:     [String]     = []
    @State private var tagLogicMode:   TagLogicMode = .and
    @State private var sortMode:       SortMode     = .newest
    @State private var showTagBar:     Bool         = true

    // Selection
    @State private var selectedAssets: Set<UUID>     = []
    @State private var bulkMode:       Bool          = false

    // Inspector
    @State private var inspectedAsset: GeneratedAsset? = nil
    @State private var showInspector:  Bool            = false

    // Grid
    @State private var gridColumns: Int = 3

    enum SortMode: String, CaseIterable {
        case newest  = "Más reciente"
        case oldest  = "Más antiguo"
        case rating  = "Mayor rating"
        case status  = "Estado"
    }

    enum TagLogicMode { case and, or }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 6), count: gridColumns)
    }

    // MARK: - Filtered Assets

    var filteredAssets: [GeneratedAsset] {
        var assets = store.fetchAllAssets(limit: 500)

        // Text search
        if !searchQuery.isEmpty {
            assets = assets.filter {
                ($0.promptPositive ?? "").localizedCaseInsensitiveContains(searchQuery) ||
                ($0.sessionTag    ?? "").localizedCaseInsensitiveContains(searchQuery) ||
                ($0.baseName      ?? "").localizedCaseInsensitiveContains(searchQuery)
            }
        }

        // Status filter
        if let status = selectedStatus {
            assets = assets.filter { $0.statusEnum == status }
        }

        // Rating filter
        if selectedRating > 0 {
            assets = assets.filter { $0.rating >= Int32(selectedRating) }
        }

        // Tag filter
        if !activeTags.isEmpty {
            let matchingIDs: Set<String>
            switch tagLogicMode {
            case .and: matchingIDs = tagging.assetIDs(matchingAll: activeTags)
            case .or:  matchingIDs = tagging.assetIDs(matchingAny: activeTags)
            }
            assets = assets.filter { a in
                guard let id = a.id?.uuidString else { return false }
                return matchingIDs.contains(id)
            }
        }

        // Sort
        switch sortMode {
        case .newest: return assets.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        case .oldest: return assets.sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
        case .rating: return assets.sorted { $0.rating > $1.rating }
        case .status: return assets.sorted { ($0.status ?? "") < ($1.status ?? "") }
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().background(Color.white.opacity(0.06))

            if showTagBar {
                TagFilterBar(activeTags: $activeTags)
                    .frame(maxHeight: 110)
                Divider().background(Color.white.opacity(0.06))
            }

            if bulkMode && !selectedAssets.isEmpty {
                bulkActionBar
                Divider().background(Color.white.opacity(0.06))
            }

            HStack(spacing: 0) {
                // Grid
                ScrollView {
                    if filteredAssets.isEmpty {
                        emptyState
                    } else {
                        LazyVGrid(columns: columns, spacing: 6) {
                            ForEach(filteredAssets) { asset in
                                GalleryThumbnailCell(
                                    asset:      asset,
                                    isSelected: selectedAssets.contains(asset.id ?? UUID()),
                                    bulkMode:   bulkMode,
                                    onTap: {
                                        if bulkMode {
                                            toggleSelection(asset)
                                        } else {
                                            inspectedAsset = asset
                                            showInspector  = true
                                        }
                                    },
                                    onLongPress: {
                                        bulkMode = true
                                        toggleSelection(asset)
                                    }
                                )
                            }
                        }
                        .padding(10)
                    }
                }
                .frame(maxWidth: .infinity)

                // Inspector
                if showInspector, let asset = inspectedAsset {
                    Divider().background(Color.white.opacity(0.06))
                    AssetInspectorView(
                        asset: asset,
                        onClose: { showInspector = false; inspectedAsset = nil },
                        onReuseSettings: { r in
                            onReuseSettings(r)
                            showInspector = false
                        }
                    )
                    .frame(width: 280)
                    .transition(.move(edge: .trailing))
                }
            }
        }
        .background(Color(red: 0.08, green: 0.08, blue: 0.10))
    }

    // MARK: - Toolbar

    var toolbar: some View {
        HStack(spacing: 8) {
            // Search
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                TextField("Buscar prompt, sesión, tag…", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                if !searchQuery.isEmpty {
                    Button(action: { searchQuery = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Color.white.opacity(0.05))
            .cornerRadius(7)
            .frame(maxWidth: 240)

            // Status filter pills
            statusPills

            Spacer()

            // Rating filter
            HStack(spacing: 3) {
                ForEach(1...5, id: \.self) { star in
                    Button(action: { selectedRating = selectedRating == star ? 0 : star }) {
                        Image(systemName: star <= selectedRating ? "star.fill" : "star")
                            .font(.system(size: 10))
                            .foregroundColor(star <= selectedRating ? .yellow : .secondary)
                    }.buttonStyle(.plain)
                }
            }

            // Sort menu
            Menu {
                ForEach(SortMode.allCases, id: \.self) { mode in
                    Button(action: { sortMode = mode }) {
                        HStack {
                            Text(mode.rawValue)
                            if sortMode == mode { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Ordenar")

            // Tag bar toggle
            Button(action: { withAnimation { showTagBar.toggle() } }) {
                Image(systemName: showTagBar ? "tag.fill" : "tag")
                    .font(.system(size: 11))
                    .foregroundColor(showTagBar ? Color(hex: "#7c6af7") : .secondary)
            }.buttonStyle(.plain).help("Filtros por tag")

            // Bulk toggle
            Button(action: {
                bulkMode.toggle()
                if !bulkMode { selectedAssets.removeAll() }
            }) {
                Image(systemName: bulkMode ? "checkmark.square.fill" : "checkmark.square")
                    .font(.system(size: 11))
                    .foregroundColor(bulkMode ? Color(hex: "#7c6af7") : .secondary)
            }.buttonStyle(.plain).help("Selección múltiple")

            // Grid size
            HStack(spacing: 4) {
                Button(action: { if gridColumns > 2 { gridColumns -= 1 } }) {
                    Image(systemName: "minus.square")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }.buttonStyle(.plain)
                Button(action: { if gridColumns < 6 { gridColumns += 1 } }) {
                    Image(systemName: "plus.square")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }.buttonStyle(.plain)
            }

            Text("\(filteredAssets.count) imgs")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Color.white.opacity(0.03))
    }

    var statusPills: some View {
        HStack(spacing: 4) {
            statusPill(nil, "Todas")
            ForEach(AssetStatus.allCases, id: \.self) { s in
                statusPill(s, s.label)
            }
        }
    }

    func statusPill(_ status: AssetStatus?, _ label: String) -> some View {
        let isSelected = selectedStatus == status
        return Button(action: { selectedStatus = status }) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(isSelected ? .white : .secondary)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(isSelected ? Color(hex: "#7c6af7").opacity(0.3) : Color.white.opacity(0.05))
                .cornerRadius(5)
        }.buttonStyle(.plain)
    }

    // MARK: - Bulk Action Bar

    var bulkActionBar: some View {
        HStack(spacing: 10) {
            Text("\(selectedAssets.count) seleccionadas")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)

            Spacer()

            Button(action: { bulkUpdateStatus(.approved) }) {
                Label("Aprobar", systemImage: "checkmark.circle")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Color(hex: "#34d399").opacity(0.2))
            .foregroundColor(Color(hex: "#34d399"))
            .cornerRadius(6)

            Button(action: { bulkUpdateStatus(.rejected) }) {
                Label("Rechazar", systemImage: "xmark.circle")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Color(hex: "#ef4444").opacity(0.2))
            .foregroundColor(Color(hex: "#ef4444"))
            .cornerRadius(6)

            Button(action: { bulkAutoTag() }) {
                Label("Auto-tag", systemImage: "tag")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Color(hex: "#7c6af7").opacity(0.2))
            .foregroundColor(Color(hex: "#7c6af7"))
            .cornerRadius(6)

            Button(action: { selectedAssets.removeAll() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.white.opacity(0.04))
    }

    // MARK: - Empty State

    var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.stack")
                .font(.system(size: 44))
                .foregroundColor(.white.opacity(0.08))
            Text("Sin imágenes")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.2))
            if !searchQuery.isEmpty || !activeTags.isEmpty || selectedStatus != nil {
                Button(action: { clearFilters() }) {
                    Text("Limpiar filtros")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "#7c6af7"))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: - Actions

    private func toggleSelection(_ asset: GeneratedAsset) {
        guard let id = asset.id else { return }
        if selectedAssets.contains(id) { selectedAssets.remove(id) }
        else { selectedAssets.insert(id) }
    }

    private func bulkUpdateStatus(_ status: AssetStatus) {
        let assets = store.fetchAllAssets(limit: 500)
            .filter { selectedAssets.contains($0.id ?? UUID()) }
        assets.forEach { store.updateStatus($0, status: status) }
        selectedAssets.removeAll()
        bulkMode = false
    }

    private func bulkAutoTag() {
        let assets = store.fetchAllAssets(limit: 500)
            .filter { selectedAssets.contains($0.id ?? UUID()) }
        tagging.autoTagUntagged(assets: assets)
        selectedAssets.removeAll()
    }

    private func clearFilters() {
        searchQuery    = ""
        activeTags     = []
        selectedStatus = nil
        selectedRating = 0
    }
}

// MARK: - GalleryThumbnailCell

struct GalleryThumbnailCell: View {
    let asset:      GeneratedAsset
    let isSelected: Bool
    let bulkMode:   Bool
    let onTap:      () -> Void
    let onLongPress: () -> Void

    @StateObject private var tagging = TaggingEngine.shared

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .topLeading) {
                // Thumbnail
                Group {
                    if let thumb = asset.thumbnail {
                        Image(nsImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else if let path = asset.imagePath,
                              let img = NSImage(contentsOfFile: path) {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle()
                            .fill(Color.white.opacity(0.05))
                            .overlay(
                                Image(systemName: "photo")
                                    .font(.system(size: 20))
                                    .foregroundColor(.white.opacity(0.15))
                            )
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity)
                .aspectRatio(2/3, contentMode: .fit)
                .clipped()
                .cornerRadius(6)

                // Overlay gradient
                VStack {
                    Spacer()
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.65)],
                        startPoint: .center, endPoint: .bottom
                    )
                    .frame(height: 50)
                    .cornerRadius(6)
                }

                // Bottom badges
                VStack(alignment: .leading, spacing: 2) {
                    Spacer()
                    HStack(spacing: 4) {
                        // Status dot
                        Circle()
                            .fill(asset.statusEnum.color)
                            .frame(width: 5, height: 5)
                        // Rating
                        if asset.rating > 0 {
                            Text(String(repeating: "★", count: Int(asset.rating)))
                                .font(.system(size: 8))
                                .foregroundColor(.yellow)
                        }
                        Spacer()
                        // NSFW badge if needed
                        let tags = tagging.tags(for: asset)
                        if tags.contains("nsfw") {
                            Text("18+")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundColor(.orange)
                                .padding(.horizontal, 3).padding(.vertical, 1)
                                .background(Color.orange.opacity(0.25))
                                .cornerRadius(3)
                        }
                    }
                    .padding(5)
                }

                // Selection checkbox
                if bulkMode {
                    VStack {
                        HStack {
                            Spacer()
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 16))
                                .foregroundColor(isSelected ? Color(hex: "#7c6af7") : .white.opacity(0.5))
                                .background(Color.black.opacity(0.3))
                                .clipShape(Circle())
                        }
                        Spacer()
                    }
                    .padding(5)
                }

                // Selection border
                if isSelected {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(hex: "#7c6af7"), lineWidth: 2)
                }
            }
        }
        .buttonStyle(.plain)
        .onLongPressGesture { onLongPress() }
        .contextMenu { contextMenu }
    }

    @ViewBuilder
    var contextMenu: some View {
        Button(action: { AssetStore.shared.updateStatus(asset, status: .approved) }) {
            Label("Aprobar", systemImage: "checkmark.circle")
        }
        Button(action: { AssetStore.shared.updateStatus(asset, status: .rejected) }) {
            Label("Rechazar", systemImage: "xmark.circle")
        }
        Divider()
        Button(action: {
            TaggingEngine.shared.suggestTags(for: asset).forEach {
                TaggingEngine.shared.addTag($0, to: asset)
            }
        }) {
            Label("Auto-tag", systemImage: "tag")
        }
        Divider()
        Button(role: .destructive, action: { AssetStore.shared.delete(asset) }) {
            Label("Eliminar", systemImage: "trash")
        }
    }
}

// MARK: - AssetInspectorView

struct AssetInspectorView: View {
    let asset: GeneratedAsset
    let onClose: () -> Void
    let onReuseSettings: (ReusableSettings) -> Void

    @StateObject private var tagging = TaggingEngine.shared
    @State private var notes: String = ""
    @State private var showFullPrompt: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack {
                    Text("Inspector")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color.white.opacity(0.03))

                Divider().background(Color.white.opacity(0.06))

                VStack(alignment: .leading, spacing: 14) {

                    // Thumbnail grande
                    if let thumb = asset.thumbnail {
                        Image(nsImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .cornerRadius(8)
                            .frame(maxWidth: .infinity)
                    }

                    // Rating Curator
                    RatingCuratorView(asset: asset)

                    // Status
                    statusRow

                    Divider().background(Color.white.opacity(0.06))

                    // Metadata
                    metaSection

                    Divider().background(Color.white.opacity(0.06))

                    // Prompt
                    promptSection

                    Divider().background(Color.white.opacity(0.06))

                    // Tags
                    tagSection

                    Divider().background(Color.white.opacity(0.06))

                    // Actions
                    actionsSection
                }
                .padding(14)
            }
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
        .onAppear { notes = asset.notes ?? "" }
    }

    var statusRow: some View {
        HStack(spacing: 8) {
            ForEach(AssetStatus.allCases, id: \.self) { status in
                Button(action: { AssetStore.shared.updateStatus(asset, status: status) }) {
                    HStack(spacing: 3) {
                        Image(systemName: status.icon)
                            .font(.system(size: 9))
                        Text(status.label)
                            .font(.system(size: 9, weight: .medium))
                    }
                    .foregroundColor(asset.statusEnum == status ? .white : .secondary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(asset.statusEnum == status
                        ? status.color.opacity(0.25)
                        : Color.white.opacity(0.04))
                    .cornerRadius(5)
                }
                .buttonStyle(.plain)
            }
        }
    }

    var metaSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            inspectorLabel("Parámetros SD")
            metaRow("Seed",    value: "\(asset.seed)")
            metaRow("Steps",   value: "\(asset.steps)")
            metaRow("CFG",     value: String(format: "%.1f", asset.cfgScale))
            metaRow("Sampler", value: asset.samplerName ?? "—")
            metaRow("Size",    value: "\(asset.width)×\(asset.height)")
            if let cp = asset.checkpoint, !cp.isEmpty {
                metaRow("Modelo", value: (cp as NSString).lastPathComponent)
            }
            if let date = asset.createdAt {
                metaRow("Fecha", value: date.shortDisplay)
            }
            if let sha = asset.sha256 {
                metaRow("SHA-256", value: sha.prefix(16) + "…")
            }
        }
    }

    var promptSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                inspectorLabel("Prompt")
                Spacer()
                Button(action: { showFullPrompt.toggle() }) {
                    Text(showFullPrompt ? "Menos" : "Más")
                        .font(.system(size: 9))
                        .foregroundColor(Color(hex: "#7c6af7"))
                }.buttonStyle(.plain)
            }
            if let prompt = asset.promptPositive {
                Text(showFullPrompt ? prompt : prompt.truncated(120))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var tagSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            inspectorLabel("Tags")
            TagCloudView(
                tags: tagging.tags(for: asset),
                onRemove: { tagging.removeTag($0, from: asset) },
                onAdd:    { tagging.addTag($0, to: asset) }
            )

            // Suggested tags
            let suggestions = tagging.suggestTags(for: asset).prefix(4)
            if !suggestions.isEmpty {
                HStack {
                    Text("Sugeridas:")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    ForEach(Array(suggestions), id: \.self) { tag in
                        Button(action: { tagging.addTag(tag, to: asset) }) {
                            Text("+ \(tag)")
                                .font(.system(size: 9))
                                .foregroundColor(Color(hex: "#7c6af7"))
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }

    var actionsSection: some View {
        VStack(spacing: 8) {
            Button(action: { onReuseSettings(ReusableSettings(from: asset)) }) {
                Label("Reutilizar settings", systemImage: "arrow.uturn.left")
                    .font(.system(size: 11, weight: .medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .padding(.vertical, 7)
            .background(Color(hex: "#7c6af7").opacity(0.15))
            .foregroundColor(Color(hex: "#7c6af7"))
            .cornerRadius(7)

            Button(action: {
                if let path = asset.cleanPath ?? asset.imagePath,
                   let img = NSImage(contentsOfFile: path) {
                    let panel = NSSavePanel()
                    panel.allowedContentTypes = [.png]
                    panel.nameFieldStringValue = "\(asset.baseName ?? "export")_clean.png"
                    if panel.runModal() == .OK, let url = panel.url {
                        img.pngData().map { try? $0.write(to: url) }
                    }
                }
            }) {
                Label("Exportar PNG", systemImage: "square.and.arrow.down")
                    .font(.system(size: 11, weight: .medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.06))
            .foregroundColor(.white.opacity(0.8))
            .cornerRadius(7)

            Button(role: .destructive, action: { AssetStore.shared.delete(asset) }) {
                Label("Eliminar", systemImage: "trash")
                    .font(.system(size: 11))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .padding(.vertical, 6)
            .foregroundColor(Color(hex: "#ef4444").opacity(0.8))
        }
    }

    // MARK: - Helpers

    func metaRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .frame(width: 60, alignment: .leading)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)
            Spacer()
        }
    }

    func inspectorLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.secondary)
            .tracking(0.8)
            .textCase(.uppercase)
    }
}

// MARK: - RatingCuratorView
//
// Sistema de rating curator 1-5 estrellas.
// Integrado en AssetInspectorView y GalleryThumbnailCell inspector.
// Persiste via AssetStore.updateRating()

struct RatingCuratorView: View {
    let asset: GeneratedAsset
    @State private var hovered: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Rating Curator")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .tracking(0.8)
                .textCase(.uppercase)

            HStack(spacing: 6) {
                ForEach(1...5, id: \.self) { star in
                    Button(action: {
                        // Toggle: clic en mismo rating lo borra
                        let newRating = Int(asset.rating) == star ? 0 : star
                        AssetStore.shared.updateRating(asset, rating: newRating)
                    }) {
                        Image(systemName: starIcon(for: star))
                            .font(.system(size: 18))
                            .foregroundColor(starColor(for: star))
                    }
                    .buttonStyle(.plain)
                    .onHover { inside in hovered = inside ? star : 0 }
                    .animation(.easeOut(duration: 0.1), value: hovered)
                }

                Spacer()

                if asset.rating > 0 {
                    Text(ratingLabel)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.04))
        .cornerRadius(8)
    }

    func starIcon(for star: Int) -> String {
        let effective = hovered > 0 ? hovered : Int(asset.rating)
        return star <= effective ? "star.fill" : "star"
    }

    func starColor(for star: Int) -> Color {
        let effective = hovered > 0 ? hovered : Int(asset.rating)
        if star <= effective {
            switch effective {
            case 1: return Color(hex: "#ef4444")
            case 2: return Color(hex: "#f97316")
            case 3: return Color(hex: "#fbbf24")
            case 4: return Color(hex: "#84cc16")
            case 5: return Color(hex: "#34d399")
            default: return .yellow
            }
        }
        return .white.opacity(0.2)
    }

    var ratingLabel: String {
        switch Int(asset.rating) {
        case 1: return "Descartar"
        case 2: return "Regular"
        case 3: return "Buena"
        case 4: return "Muy buena"
        case 5: return "Maestra"
        default: return ""
        }
    }
}
