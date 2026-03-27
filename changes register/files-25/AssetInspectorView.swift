import SwiftUI
import AppKit

// MARK: - AssetInspectorView
// Panel lateral de inspección de un GeneratedAsset.
// Muestra todos los metadatos, permite editar rating/tags/status,
// y ofrece acciones rápidas (export, refine, reuse settings).

struct AssetInspectorView: View {

    let asset:            GeneratedAsset
    var onClose:          () -> Void
    var onReuseSettings:  (ReusableSettings) -> Void

    @StateObject private var tagging = TaggingEngine.shared
    @StateObject private var store   = AssetStore.shared
    @State private var showFullPrompt = false
    @State private var newTag:   String = ""
    @State private var exportMsg: String? = nil
    @State private var isExporting: Bool  = false

    var tags: [String] { tagging.tags(for: asset) }
    var image: NSImage? {
        guard let p = asset.imagePath else { return nil }
        return NSImage(contentsOfFile: p)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Text("Inspector")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.white.opacity(0.03))

            Divider().background(Color.white.opacity(0.06))

            ScrollView {
                VStack(spacing: 0) {

                    // Thumbnail
                    if let img = image {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: 200)
                            .cornerRadius(6)
                            .padding(10)
                    } else {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.white.opacity(0.05))
                            .frame(height: 140)
                            .overlay(
                                Image(systemName: "photo")
                                    .font(.system(size: 22))
                                    .foregroundColor(.secondary)
                            )
                            .padding(10)
                    }

                    // Rating
                    VStack(alignment: .leading, spacing: 6) {
                        sectionHeader("Rating")
                        RatingCuratorView(
                            rating: Int(asset.rating),
                            onChange: { store.updateRating(asset, rating: $0) }
                        )
                    }
                    .padding(.horizontal, 12).padding(.bottom, 10)

                    Divider().background(Color.white.opacity(0.05))

                    // Status
                    VStack(alignment: .leading, spacing: 6) {
                        sectionHeader("Estado")
                        Picker("", selection: Binding(
                            get: { asset.statusEnum },
                            set: { store.updateStatus(asset, status: $0) }
                        )) {
                            ForEach(AssetStatus.allCases, id: \.self) { s in
                                Label(s.label, systemImage: s.icon).tag(s)
                            }
                        }
                        .pickerStyle(.segmented)
                        .font(.system(size: 10))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)

                    Divider().background(Color.white.opacity(0.05))

                    // Tags
                    VStack(alignment: .leading, spacing: 6) {
                        sectionHeader("Tags")
                        TagCloudView(
                            tags: tags,
                            onRemove: { tagging.removeTag($0, from: asset) },
                            onAdd:    { tagging.addTag($0, to: asset) }
                        )
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)

                    Divider().background(Color.white.opacity(0.05))

                    // Prompt
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            sectionHeader("Prompt")
                            Spacer()
                            Button(action: { showFullPrompt.toggle() }) {
                                Text(showFullPrompt ? "Colapsar" : "Ver todo")
                                    .font(.system(size: 9))
                                    .foregroundColor(Color(hex: "#7c6af7"))
                            }.buttonStyle(.plain)
                        }
                        Text(asset.promptPositive ?? "—")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.white.opacity(0.75))
                            .lineLimit(showFullPrompt ? nil : 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let neg = asset.promptNegative, !neg.isEmpty {
                            Text("Neg: \(neg)")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                                .lineLimit(showFullPrompt ? nil : 1)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)

                    Divider().background(Color.white.opacity(0.05))

                    // Generation params
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader("Parámetros")
                        paramGrid
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)

                    Divider().background(Color.white.opacity(0.05))

                    // Model info
                    VStack(alignment: .leading, spacing: 6) {
                        sectionHeader("Modelo")
                        if let cp = asset.checkpoint, !cp.isEmpty {
                            paramRow("Checkpoint", cp)
                        }
                        if let vae = asset.vaeUsed, !vae.isEmpty {
                            paramRow("VAE", vae)
                        }
                        let loras = asset.loraWeights
                        if !loras.isEmpty {
                            ForEach(Array(loras.keys.sorted()), id: \.self) { key in
                                paramRow("LoRA: \(key)", String(format: "%.2f", loras[key] ?? 0))
                            }
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)

                    Divider().background(Color.white.opacity(0.05))

                    // Integrity
                    VStack(alignment: .leading, spacing: 6) {
                        sectionHeader("Integridad")
                        if let sha = asset.sha256 {
                            paramRow("SHA-256", String(sha.prefix(16)) + "…")
                        }
                        let ok = AssetStore.shared.verifyIntegrity(asset)
                        HStack(spacing: 5) {
                            Image(systemName: ok ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                                .font(.system(size: 10))
                                .foregroundColor(ok ? Color(hex: "#34d399") : Color(hex: "#ef4444"))
                            Text(ok ? "Archivo íntegro" : "Hash no coincide")
                                .font(.system(size: 10))
                                .foregroundColor(ok ? Color(hex: "#34d399") : Color(hex: "#ef4444"))
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)

                    Divider().background(Color.white.opacity(0.05))

                    // Actions
                    VStack(spacing: 6) {
                        // Reuse settings
                        Button(action: { onReuseSettings(ReusableSettings(from: asset)) }) {
                            Label("Reutilizar settings", systemImage: "arrow.uturn.left")
                                .font(.system(size: 11))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                        }
                        .buttonStyle(.plain)
                        .background(Color.white.opacity(0.06))
                        .cornerRadius(6)

                        // Quick export
                        Button(action: { quickExport() }) {
                            HStack(spacing: 6) {
                                if isExporting {
                                    ProgressView().scaleEffect(0.6).progressViewStyle(.circular)
                                } else {
                                    Image(systemName: "square.and.arrow.up")
                                }
                                Text(isExporting ? "Exportando…" : "Exportar")
                                    .font(.system(size: 11))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                        }
                        .buttonStyle(.plain)
                        .background(Color(hex: "#7c6af7").opacity(0.25))
                        .cornerRadius(6)
                        .disabled(isExporting)

                        // Show in Finder
                        if let path = asset.imagePath {
                            Button(action: {
                                NSWorkspace.shared.activateFileViewerSelecting(
                                    [URL(fileURLWithPath: path)]
                                )
                            }) {
                                Label("Mostrar en Finder", systemImage: "folder")
                                    .font(.system(size: 11))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 7)
                            }
                            .buttonStyle(.plain)
                            .background(Color.white.opacity(0.04))
                            .cornerRadius(6)
                        }

                        if let msg = exportMsg {
                            Text(msg)
                                .font(.system(size: 10))
                                .foregroundColor(msg.hasPrefix("✓") ? Color(hex: "#34d399") : .orange)
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                }
            }
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
    }

    // MARK: - Param Grid

    var paramGrid: some View {
        LazyVGrid(columns: [
            GridItem(.flexible()),
            GridItem(.flexible())
        ], spacing: 6) {
            paramCell("Seed",    "\(asset.seed)")
            paramCell("Steps",   "\(asset.steps)")
            paramCell("CFG",     String(format: "%.1f", asset.cfgScale))
            paramCell("Sampler", asset.samplerName ?? "—")
            paramCell("W×H",     "\(asset.width)×\(asset.height)")
            if let date = asset.createdAt {
                paramCell("Fecha",   date.shortDisplay)
            }
        }
    }

    func paramCell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 8))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04))
        .cornerRadius(5)
    }

    func paramRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white.opacity(0.8))
                .lineLimit(1)
        }
    }

    func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(.secondary)
            .textCase(.uppercase)
    }

    // MARK: - Quick Export

    private func quickExport() {
        isExporting = true
        Task {
            do {
                let result = try await ExportEngine.shared.export(asset: asset, addWatermark: true)
                exportMsg = "✓ \(result.cleanURL.lastPathComponent)"
            } catch {
                exportMsg = "⚠️ \(error.localizedDescription)"
            }
            isExporting = false
            try? await Task.sleep(for: .seconds(3))
            exportMsg = nil
        }
    }
}

// MARK: - RatingCuratorView
// Widget de rating reutilizable: 0-5 estrellas con interacción.
// Usado en AssetInspectorView, GalleryView, PromptVersionPickerView.

struct RatingCuratorView: View {
    let rating:    Int
    var onChange:  (Int) -> Void
    var size:      CGFloat = 14
    var showLabel: Bool    = true
    @State private var hoveredStar: Int? = nil

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 2) {
                ForEach(1...5, id: \.self) { star in
                    Button(action: {
                        // Si clic en la misma estrella activa → quitar rating
                        onChange(star == rating ? 0 : star)
                    }) {
                        Image(systemName: starIcon(star))
                            .font(.system(size: size))
                            .foregroundColor(starColor(star))
                    }
                    .buttonStyle(.plain)
                    .onHover { hoveredStar = $0 ? star : nil }
                }
            }

            if showLabel && rating > 0 {
                Text(ratingLabel)
                    .font(.system(size: size - 4, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
    }

    private func starIcon(_ star: Int) -> String {
        let effective = hoveredStar ?? rating
        return star <= effective ? "star.fill" : "star"
    }

    private func starColor(_ star: Int) -> Color {
        let effective = hoveredStar ?? rating
        if star <= effective {
            switch effective {
            case 1, 2: return Color(hex: "#f97316")
            case 3:    return Color(hex: "#fbbf24")
            case 4, 5: return Color(hex: "#fde047")
            default:   return .yellow
            }
        }
        return Color.white.opacity(0.2)
    }

    private var ratingLabel: String {
        switch rating {
        case 1: return "Descartable"
        case 2: return "Regular"
        case 3: return "Buena"
        case 4: return "Destacada"
        case 5: return "Masterpiece"
        default: return ""
        }
    }
}

// MARK: - BatchRatingView
// Permite calificar varios assets en modo curador (swipe-like).

struct BatchRatingView: View {
    @StateObject private var store = AssetStore.shared
    @State private var assets:     [GeneratedAsset] = []
    @State private var currentIdx: Int = 0

    var currentAsset: GeneratedAsset? { assets.indices.contains(currentIdx) ? assets[currentIdx] : nil }

    var body: some View {
        VStack(spacing: 16) {
            if assets.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 32))
                        .foregroundColor(Color(hex: "#34d399"))
                    Text("Todos los assets están calificados")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let asset = currentAsset {
                // Thumbnail
                if let path = asset.imagePath, let img = NSImage(contentsOfFile: path) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 300)
                        .cornerRadius(8)
                }

                // Prompt preview
                Text((asset.promptPositive ?? "").truncated(80))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)

                // Rating buttons
                HStack(spacing: 12) {
                    ForEach(1...5, id: \.self) { r in
                        Button(action: { rate(r) }) {
                            VStack(spacing: 4) {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 18))
                                    .foregroundColor(ratingColor(r))
                                Text("\(r)")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.secondary)
                            }
                            .frame(width: 48, height: 48)
                            .background(ratingColor(r).opacity(0.1))
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Skip button
                Button("Saltar") { next() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                // Progress
                Text("\(currentIdx + 1) de \(assets.count) sin calificar")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .padding(20)
        .onAppear { loadUnrated() }
    }

    private func loadUnrated() {
        assets = store.fetchAllAssets(limit: 200).filter { $0.rating == 0 }
    }

    private func rate(_ rating: Int) {
        guard let asset = currentAsset else { return }
        store.updateRating(asset, rating: rating)
        next()
    }

    private func next() {
        if currentIdx + 1 < assets.count {
            currentIdx += 1
        } else {
            loadUnrated()
            currentIdx = 0
        }
    }

    private func ratingColor(_ r: Int) -> Color {
        switch r {
        case 1: return Color(hex: "#6b7280")
        case 2: return Color(hex: "#f97316")
        case 3: return Color(hex: "#fbbf24")
        case 4: return Color(hex: "#34d399")
        case 5: return Color(hex: "#7c6af7")
        default: return .gray
        }
    }
}
