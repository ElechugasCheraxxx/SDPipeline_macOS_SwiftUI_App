import SwiftUI
import AppKit
import CoreData
import Combine
import UniformTypeIdentifiers

// MARK: - GalleryView v5
// Correcciones aplicadas:
//   - Añadido `import UniformTypeIdentifiers` para acceder a UTType.png
//   - Uso de `id: \.objectID` en ForEach para modelos de CoreData.
//   - Invocación correcta del factory estático: `ReusableSettings.from(asset:)`

struct GalleryView: View {

    var onReuseSettings: (ReusableSettings) -> Void

    @StateObject private var store   = AssetStore.shared
    @StateObject private var tagging = TaggingEngine.shared

    // Filters
    @State private var searchQuery:    String       = ""
    @State private var selectedStatus: AssetStatus? = nil
    @State private var selectedRating: Int          = 0
    @State private var activeTags:     [String]     = []
    @State private var tagLogicAND:    Bool         = true
    @State private var sortMode:       SortMode     = .newest
    @State private var showTagBar:     Bool         = true

    // Bulk
    @State private var bulkMode:       Bool         = false
    @State private var selectedIDs:    Set<UUID>    = []

    // Inspector
    @State private var inspectedAsset: GeneratedAsset? = nil

    // Grid
    @State private var gridColumns: Int = 3

    enum SortMode: String, CaseIterable {
        case newest = "Reciente"; case oldest = "Antiguo"
        case rating = "Rating";   case status = "Estado"
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 6), count: gridColumns)
    }

    // MARK: - Filtered Assets

    var filteredAssets: [GeneratedAsset] {
        var assets = store.fetchAllAssets(limit: 500)
        if !searchQuery.isEmpty {
            assets = assets.filter {
                ($0.promptPositive ?? "").localizedCaseInsensitiveContains(searchQuery) ||
                ($0.sessionTag    ?? "").localizedCaseInsensitiveContains(searchQuery) ||
                ($0.baseName      ?? "").localizedCaseInsensitiveContains(searchQuery)
            }
        }
        if let status = selectedStatus { assets = assets.filter { $0.statusEnum == status } }
        if selectedRating > 0 { assets = assets.filter { $0.rating >= Int32(selectedRating) } }
        if !activeTags.isEmpty {
            let matchIDs = tagLogicAND
                ? tagging.assetIDs(matchingAll: activeTags)
                : tagging.assetIDs(matchingAny: activeTags)
            assets = assets.filter {
                guard let id = $0.id?.uuidString else { return false }
                return matchIDs.contains(id)
            }
        }
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
            if showTagBar { tagBar; Divider().background(Color.white.opacity(0.06)) }
            if bulkMode && !selectedIDs.isEmpty { bulkBar; Divider().background(Color.white.opacity(0.06)) }
            HStack(spacing: 0) {
                gridPane
                if let asset = inspectedAsset {
                    Divider().background(Color.white.opacity(0.06))
                    AssetInspectorView(
                        asset: asset,
                        onClose: { inspectedAsset = nil },
                        onReuseSettings: { r in onReuseSettings(r); inspectedAsset = nil }
                    )
                    .frame(width: 272)
                    .transition(.move(edge: .trailing))
                    .animation(.easeInOut(duration: 0.18), value: inspectedAsset != nil)
                }
            }
        }
        .background(Color(red: 0.08, green: 0.08, blue: 0.10))
    }

    // MARK: - Toolbar

    var toolbar: some View {
        HStack(spacing: 8) {
            // Search
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundColor(.secondary)
                TextField("Buscar…", text: $searchQuery)
                    .textFieldStyle(.plain).font(.system(size: 11)).foregroundColor(.white)
                if !searchQuery.isEmpty {
                    Button(action: { searchQuery = "" }) {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundColor(.secondary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(Color.white.opacity(0.05)).cornerRadius(6).frame(maxWidth: 200)

            // Status pills
            statusPills

            Spacer()

            // Rating filter
            HStack(spacing: 2) {
                ForEach(1...5, id: \.self) { star in
                    Button(action: { selectedRating = selectedRating == star ? 0 : star }) {
                        Image(systemName: star <= selectedRating ? "star.fill" : "star")
                            .font(.system(size: 9))
                            .foregroundColor(star <= selectedRating ? .yellow : .secondary)
                    }.buttonStyle(.plain)
                }
            }

            // Sort
            Menu {
                ForEach(SortMode.allCases, id: \.self) { mode in
                    Button(action: { sortMode = mode }) {
                        HStack { Text(mode.rawValue); if sortMode == mode { Image(systemName: "checkmark") } }
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down").font(.system(size: 11)).foregroundColor(.secondary)
            }.buttonStyle(.plain)

            // Tag toggle
            Button(action: { withAnimation(.easeInOut(duration: 0.15)) { showTagBar.toggle() } }) {
                Image(systemName: showTagBar ? "tag.fill" : "tag").font(.system(size: 11))
                    .foregroundColor(showTagBar ? Color(hex: "#7c6af7") : .secondary)
            }.buttonStyle(.plain)

            // Bulk toggle
            Button(action: { bulkMode.toggle(); if !bulkMode { selectedIDs.removeAll() } }) {
                Image(systemName: bulkMode ? "checkmark.square.fill" : "checkmark.square")
                    .font(.system(size: 11))
                    .foregroundColor(bulkMode ? Color(hex: "#7c6af7") : .secondary)
            }.buttonStyle(.plain)

            // Grid size
            HStack(spacing: 3) {
                Button(action: { if gridColumns > 2 { gridColumns -= 1 } }) {
                    Image(systemName: "minus").font(.system(size: 9)).foregroundColor(.secondary)
                }.buttonStyle(.plain)
                Text("\(gridColumns)").font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary)
                Button(action: { if gridColumns < 6 { gridColumns += 1 } }) {
                    Image(systemName: "plus").font(.system(size: 9)).foregroundColor(.secondary)
                }.buttonStyle(.plain)
            }

            Text("\(filteredAssets.count)")
                .font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.white.opacity(0.03))
    }

    var statusPills: some View {
        HStack(spacing: 3) {
            statusPill(nil, "All")
            ForEach(AssetStatus.allCases, id: \.self) { s in statusPill(s, s.label) }
        }
    }

    func statusPill(_ s: AssetStatus?, _ label: String) -> some View {
        let sel = selectedStatus == s
        return Button(action: { selectedStatus = s }) {
            Text(label).font(.system(size: 8, weight: .medium))
                .foregroundColor(sel ? .white : .secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(sel ? Color(hex: "#7c6af7").opacity(0.3) : Color.white.opacity(0.05))
                .cornerRadius(4)
        }.buttonStyle(.plain)
    }

    // MARK: - Tag Bar

    var tagBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Tags").font(.system(size: 9, weight: .semibold)).foregroundColor(.secondary).tracking(0.8)
                // AND / OR toggle
                Button(action: { tagLogicAND.toggle() }) {
                    Text(tagLogicAND ? "AND" : "OR")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(tagLogicAND ? Color(hex: "#7c6af7") : Color(hex: "#3de3c0"))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.white.opacity(0.06)).cornerRadius(3)
                }.buttonStyle(.plain)
                if !activeTags.isEmpty {
                    Button(action: { activeTags.removeAll() }) {
                        Text("Clear").font(.system(size: 8)).foregroundColor(.secondary)
                    }.buttonStyle(.plain)
                }
                Spacer()
            }
            // Top tags as filter chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(tagging.topTags.prefix(24)), id: \.tag) { item in
                        let active = activeTags.contains(item.tag)
                        Button(action: {
                            if active { activeTags.removeAll { $0 == item.tag } }
                            else { activeTags.append(item.tag) }
                        }) {
                            HStack(spacing: 3) {
                                Text(item.tag).font(.system(size: 9))
                                Text("(\(item.count))").font(.system(size: 8)).opacity(0.7)
                            }
                            .foregroundColor(active ? .white : .secondary)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(active ? Color(hex: "#7c6af7").opacity(0.35) : Color.white.opacity(0.05))
                            .cornerRadius(5)
                        }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color.white.opacity(0.02))
    }

    // MARK: - Bulk Bar

    var bulkBar: some View {
        HStack(spacing: 8) {
            Text("\(selectedIDs.count) sel.").font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
            Spacer()
            bulkBtn("Aprobar", "checkmark.circle", Color(hex: "#34d399")) { bulkStatus(.approved) }
            bulkBtn("Rechazar", "xmark.circle", Color(hex: "#ef4444")) { bulkStatus(.rejected) }
            bulkBtn("Auto-tag", "tag", Color(hex: "#7c6af7")) { bulkAutoTag() }
            Button(action: { selectedIDs.removeAll(); bulkMode = false }) {
                Image(systemName: "xmark").font(.system(size: 10)).foregroundColor(.secondary)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 7).background(Color.white.opacity(0.04))
    }

    func bulkBtn(_ label: String, _ icon: String, _ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon).font(.system(size: 10))
                .foregroundColor(color)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(color.opacity(0.15)).cornerRadius(5)
        }.buttonStyle(.plain)
    }

    // MARK: - Grid Pane

    var gridPane: some View {
        ScrollView {
            if filteredAssets.isEmpty {
                emptyState
            } else {
                LazyVGrid(columns: columns, spacing: 6) {
                    // Usar \.objectID para garantizar conformidad con Identifiable en NSManagedObject
                    ForEach(filteredAssets, id: \.objectID) { asset in
                        ThumbnailCell(
                            asset:      asset,
                            isSelected: selectedIDs.contains(asset.id ?? UUID()),
                            bulkMode:   bulkMode,
                            onTap: {
                                if bulkMode { toggle(asset) }
                                else {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        inspectedAsset = inspectedAsset?.id == asset.id ? nil : asset
                                    }
                                }
                            },
                            onLongPress: { bulkMode = true; toggle(asset) }
                        )
                    }
                }
                .padding(8)
            }
        }
        .frame(maxWidth: .infinity)
    }

    var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.stack").font(.system(size: 40)).foregroundColor(.white.opacity(0.07))
            Text("Sin imágenes").font(.system(size: 13)).foregroundColor(.white.opacity(0.18))
            if !searchQuery.isEmpty || !activeTags.isEmpty || selectedStatus != nil {
                Button(action: { searchQuery = ""; activeTags = []; selectedStatus = nil; selectedRating = 0 }) {
                    Text("Limpiar filtros").font(.system(size: 11)).foregroundColor(Color(hex: "#7c6af7"))
                }.buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    // MARK: - Actions

    private func toggle(_ asset: GeneratedAsset) {
        guard let id = asset.id else { return }
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
    }

    private func bulkStatus(_ status: AssetStatus) {
        store.fetchAllAssets(limit: 500).filter { selectedIDs.contains($0.id ?? UUID()) }
            .forEach { store.updateStatus($0, status: status) }
        selectedIDs.removeAll(); bulkMode = false
    }

    private func bulkAutoTag() {
        let assets = store.fetchAllAssets(limit: 500).filter { selectedIDs.contains($0.id ?? UUID()) }
        TaggingEngine.shared.autoTagUntagged(assets: assets)
        selectedIDs.removeAll()
    }
}

// MARK: - ThumbnailCell

struct ThumbnailCell: View {
    let asset:       GeneratedAsset
    let isSelected:  Bool
    let bulkMode:    Bool
    let onTap:       () -> Void
    let onLongPress: () -> Void

    @StateObject private var tagging = TaggingEngine.shared

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .topLeading) {
                thumbnail
                bottomOverlay
                if bulkMode { selectionCheckbox }
                if isSelected { selectionBorder }
            }
        }
        .buttonStyle(.plain)
        .onLongPressGesture(minimumDuration: 0.4) { onLongPress() }
        .contextMenu { contextMenuItems }
    }

    var thumbnail: some View {
        Group {
            if let img = asset.thumbnail {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else if let path = asset.imagePath, let img = NSImage(contentsOfFile: path) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(Color.white.opacity(0.04))
                    .overlay(Image(systemName: "photo").font(.system(size: 18))
                        .foregroundColor(.white.opacity(0.12)))
            }
        }
        .aspectRatio(2/3, contentMode: .fit).clipped().cornerRadius(5)
    }

    var bottomOverlay: some View {
        VStack {
            Spacer()
            ZStack(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.55)],
                              startPoint: .center, endPoint: .bottom)
                    .frame(height: 44).cornerRadius(5)
                HStack(spacing: 4) {
                    Circle().fill(asset.statusEnum.color).frame(width: 4, height: 4)
                    if asset.rating > 0 {
                        Text(String(repeating: "★", count: Int(asset.rating)))
                            .font(.system(size: 7)).foregroundColor(.yellow)
                    }
                    Spacer()
                    let tags = tagging.tags(for: asset)
                    if tags.contains("nsfw") {
                        Text("18+").font(.system(size: 6, weight: .bold))
                            .foregroundColor(.orange)
                            .padding(.horizontal, 3).padding(.vertical, 1)
                            .background(Color.orange.opacity(0.2)).cornerRadius(2)
                    }
                }
                .padding(.horizontal, 5).padding(.bottom, 4)
            }
        }
    }

    var selectionCheckbox: some View {
        VStack { HStack { Spacer()
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15))
                .foregroundColor(isSelected ? Color(hex: "#7c6af7") : .white.opacity(0.5))
                .shadow(radius: 2)
        }.padding(4); Spacer() }
    }

    var selectionBorder: some View {
        RoundedRectangle(cornerRadius: 5)
            .stroke(Color(hex: "#7c6af7"), lineWidth: 2)
    }

    @ViewBuilder
    var contextMenuItems: some View {
        Button(action: { AssetStore.shared.updateStatus(asset, status: .approved)  }) {
            Label("Aprobar", systemImage: "checkmark.circle")
        }
        Button(action: { AssetStore.shared.updateStatus(asset, status: .published) }) {
            Label("Publicar", systemImage: "arrow.up.circle")
        }
        Button(action: { AssetStore.shared.updateStatus(asset, status: .rejected)  }) {
            Label("Rechazar", systemImage: "xmark.circle")
        }
        Divider()
        Button(action: {
            TaggingEngine.shared.suggestTags(for: asset)
                .forEach { TaggingEngine.shared.addTag($0, to: asset) }
        }) { Label("Auto-tag", systemImage: "tag") }
        Divider()
        Button(role: .destructive, action: { AssetStore.shared.delete(asset) }) {
            Label("Eliminar", systemImage: "trash")
        }
    }
}

// MARK: - AssetInspectorView

struct AssetInspectorView: View {
    let asset:           GeneratedAsset
    let onClose:         () -> Void
    let onReuseSettings: (ReusableSettings) -> Void

    @StateObject private var tagging = TaggingEngine.shared
    @State private var showFullPrompt = false
    @State private var newTag:        String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack {
                    Text("Inspector").font(.system(size: 11, weight: .bold)).foregroundColor(.white)
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.system(size: 10)).foregroundColor(.secondary)
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Color.white.opacity(0.03))

                Divider().background(Color.white.opacity(0.06))

                VStack(alignment: .leading, spacing: 12) {
                    // Thumbnail
                    if let t = asset.thumbnail {
                        Image(nsImage: t).resizable().aspectRatio(contentMode: .fit)
                            .cornerRadius(6).frame(maxWidth: .infinity)
                    }

                    // Rating Curator
                    RatingCuratorView(asset: asset)

                    // Status row
                    statusRow

                    Divider().background(Color.white.opacity(0.06))
                    metaSection
                    Divider().background(Color.white.opacity(0.06))
                    promptSection
                    Divider().background(Color.white.opacity(0.06))
                    tagSection
                    Divider().background(Color.white.opacity(0.06))
                    actionsSection
                }
                .padding(12)
            }
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
    }

    var statusRow: some View {
        HStack(spacing: 4) {
            ForEach(AssetStatus.allCases, id: \.self) { s in
                Button(action: { AssetStore.shared.updateStatus(asset, status: s) }) {
                    Text(s.label).font(.system(size: 8, weight: .medium))
                        .foregroundColor(asset.statusEnum == s ? .white : .secondary)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(asset.statusEnum == s ? s.color.opacity(0.3) : Color.white.opacity(0.04))
                        .cornerRadius(4)
                }.buttonStyle(.plain)
            }
        }
    }

    var metaSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            sLabel("Parámetros SD")
            mRow("Seed",    "\(asset.seed)")
            mRow("Steps",   "\(asset.steps)")
            mRow("CFG",     String(format: "%.1f", asset.cfgScale))
            mRow("Sampler", asset.samplerName ?? "—")
            mRow("Size",    "\(asset.width)×\(asset.height)")
            if let cp = asset.checkpoint, !cp.isEmpty {
                mRow("Modelo", (cp as NSString).lastPathComponent)
            }
            if let d = asset.createdAt { mRow("Fecha", d.shortDisplay) }
            if let sha = asset.sha256  { mRow("SHA-256", "\(sha.prefix(14))…") }
        }
    }

    var promptSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                sLabel("Prompt")
                Spacer()
                Button(action: { showFullPrompt.toggle() }) {
                    Text(showFullPrompt ? "Menos" : "Más").font(.system(size: 8))
                        .foregroundColor(Color(hex: "#7c6af7"))
                }.buttonStyle(.plain)
            }
            if let p = asset.promptPositive {
                Text(showFullPrompt ? p : p.truncated(100))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var tagSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sLabel("Tags")
            // Existing tags
            let tags = tagging.tags(for: asset)
            if !tags.isEmpty {
                FlowLayoutSimple(spacing: 4) {
                    ForEach(Array(tags).sorted(), id: \.self) { tag in
                        HStack(spacing: 3) {
                            Text(tag).font(.system(size: 9))
                            Button(action: { tagging.removeTag(tag, from: asset) }) {
                                Image(systemName: "xmark").font(.system(size: 7))
                            }.buttonStyle(.plain)
                        }
                        .foregroundColor(.white.opacity(0.8))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color(hex: "#7c6af7").opacity(0.2)).cornerRadius(4)
                    }
                }
            }
            // Add tag field
            HStack(spacing: 5) {
                TextField("Añadir tag…", text: $newTag)
                    .textFieldStyle(.plain).font(.system(size: 10)).foregroundColor(.white)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Color.white.opacity(0.05)).cornerRadius(4)
                    .onSubmit {
                        let t = newTag.trimmingCharacters(in: .whitespaces)
                        if !t.isEmpty { tagging.addTag(t, to: asset); newTag = "" }
                    }
            }
            // Suggestions
            let sugg = tagging.suggestTags(for: asset).filter { !tags.contains($0) }.prefix(4)
            if !sugg.isEmpty {
                HStack(spacing: 4) {
                    Text("Sug:").font(.system(size: 8)).foregroundColor(.secondary)
                    ForEach(Array(sugg), id: \.self) { tag in
                        Button(action: { tagging.addTag(tag, to: asset) }) {
                            Text(tag).font(.system(size: 8)).foregroundColor(Color(hex: "#7c6af7"))
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }

    var actionsSection: some View {
        VStack(spacing: 7) {
            // Llamada al factory method estático de ReusableSettings
            Button(action: { onReuseSettings(ReusableSettings.from(asset: asset)) }) {
                Label("Reutilizar settings", systemImage: "arrow.uturn.left")
                    .font(.system(size: 11, weight: .medium)).frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain).padding(.vertical, 7)
            .background(Color(hex: "#7c6af7").opacity(0.15))
            .foregroundColor(Color(hex: "#7c6af7")).cornerRadius(6)

            Button(action: exportPNG) {
                Label("Exportar PNG", systemImage: "square.and.arrow.down")
                    .font(.system(size: 11, weight: .medium)).frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain).padding(.vertical, 7)
            .background(Color.white.opacity(0.06)).foregroundColor(.white.opacity(0.8)).cornerRadius(6)

            Button(role: .destructive, action: { AssetStore.shared.delete(asset) }) {
                Label("Eliminar", systemImage: "trash")
                    .font(.system(size: 10)).frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain).padding(.vertical, 5)
            .foregroundColor(Color(hex: "#ef4444").opacity(0.8))
        }
    }

    private func exportPNG() {
        let path = asset.cleanPath ?? asset.imagePath
        guard let path, let img = NSImage(contentsOfFile: path) else { return }
        let panel = NSSavePanel()
        // Utilizando UTType.png gracias a la importación añadida en la parte superior
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(asset.baseName ?? "export")_clean.png"
        if panel.runModal() == .OK, let url = panel.url { img.pngData().map { try? $0.write(to: url) } }
    }

    func mRow(_ l: String, _ v: String) -> some View {
        HStack {
            Text(l).font(.system(size: 9)).foregroundColor(.secondary).frame(width: 52, alignment: .leading)
            Text(v).font(.system(size: 9, design: .monospaced)).foregroundColor(.white.opacity(0.8)).lineLimit(1)
            Spacer()
        }
    }

    func sLabel(_ t: String) -> some View {
        Text(t).font(.system(size: 9, weight: .semibold)).foregroundColor(.secondary)
            .tracking(0.8).textCase(.uppercase)
    }
}

// MARK: - RatingCuratorView

struct RatingCuratorView: View {
    let asset: GeneratedAsset
    @State private var hovered: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Rating Curator").font(.system(size: 9, weight: .semibold))
                .foregroundColor(.secondary).tracking(0.8).textCase(.uppercase)
            HStack(spacing: 5) {
                ForEach(1...5, id: \.self) { star in
                    Button(action: {
                        let newRating = Int(asset.rating) == star ? 0 : star
                        AssetStore.shared.updateRating(asset, rating: newRating)
                    }) {
                        Image(systemName: effectiveStar(star) <= star && effectiveStar(star) > 0
                              ? "star.fill" : "star")
                        .font(.system(size: 16))
                        .foregroundColor(starColor(star))
                    }
                    .buttonStyle(.plain)
                    .onHover { inside in hovered = inside ? star : 0 }
                }
                Spacer()
                if asset.rating > 0 {
                    Text(ratingLabel).font(.system(size: 9)).foregroundColor(.secondary)
                }
            }
        }
        .padding(9).background(Color.white.opacity(0.04)).cornerRadius(7)
    }

    private func effectiveStar(_ star: Int) -> Int { hovered > 0 ? hovered : Int(asset.rating) }

    private func starColor(_ star: Int) -> Color {
        let eff = effectiveStar(star)
        guard star <= eff, eff > 0 else { return .white.opacity(0.15) }
        switch eff {
        case 1: return Color(hex: "#ef4444")
        case 2: return Color(hex: "#f97316")
        case 3: return Color(hex: "#fbbf24")
        case 4: return Color(hex: "#84cc16")
        default: return Color(hex: "#34d399")
        }
    }

    var ratingLabel: String {
        switch Int(asset.rating) {
        case 1: return "Descartar"; case 2: return "Regular"; case 3: return "Buena"
        case 4: return "Muy buena"; case 5: return "Maestra"; default: return ""
        }
    }
}

// MARK: - FlowLayoutSimple
// Layout simple para chips de tags en el inspector (sin dependencias externas)

struct FlowLayoutSimple: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        var x: CGFloat = 0; var y: CGFloat = 0; var rowH: CGFloat = 0
        let maxW = proposal.width ?? .infinity
        for sub in subviews {
            let sz = sub.sizeThatFits(.unspecified)
            if x + sz.width > maxW, x > 0 { y += rowH + spacing; x = 0; rowH = 0 }
            rowH = max(rowH, sz.height); x += sz.width + spacing
        }
        return CGSize(width: maxW, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX; var y = bounds.minY; var rowH: CGFloat = 0
        for sub in subviews {
            let sz = sub.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX, x > bounds.minX { y += rowH + spacing; x = bounds.minX; rowH = 0 }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            rowH = max(rowH, sz.height); x += sz.width + spacing
        }
    }
}
