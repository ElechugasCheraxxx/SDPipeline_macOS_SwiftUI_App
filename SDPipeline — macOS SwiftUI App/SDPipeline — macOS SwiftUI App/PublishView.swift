import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine

// MARK: - StudioPublishView
// Vista completa de la tab "Publicar" en RightPanelView.
// Renombrada desde PublishView para evitar conflicto con la definición
// existente en PublishEngine.swift.

struct StudioPublishView: View {

    let images: [NSImage]

    @StateObject private var engine   = PublishEngine.shared
    @StateObject private var store    = AssetStore.shared
    @State private var selectedPreset: ExportPreset?
    @State private var selectedAssets: Set<UUID> = []
    @State private var isExporting:    Bool = false
    @State private var exportMsg:      String? = nil
    @State private var showLog:        Bool = false
    @State private var watermarkText:  String = "@tuusuario"

    // Usar assets aprobados de la galería + imagen actual si existe
    var exportableAssets: [GeneratedAsset] {
        var assets = store.recentAssets.filter { $0.statusEnum == .approved || $0.statusEnum == .draft }
        return Array(assets.prefix(20))
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider().background(Color.white.opacity(0.07))

            HSplitView {
                // Izquierda: selector de assets
                assetSelector
                    .frame(minWidth: 180, maxWidth: 260)

                // Derecha: configuración de export
                exportConfig
                    .frame(minWidth: 220)
            }

            Divider().background(Color.white.opacity(0.07))
            bottomBar
        }
        .background(Color(red: 0.08, green: 0.08, blue: 0.10))
        .onAppear {
            if selectedPreset == nil {
                selectedPreset = PublishEngine.shared.presets.first
            }
        }
    }

    // MARK: - Header

    var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.up.to.line.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color(hex: "#7c6af7"), Color(hex: "#3de3c0")],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
            VStack(alignment: .leading, spacing: 1) {
                Text("Publicación").font(.system(size: 13, weight: .bold)).foregroundColor(.white)
                Text("\(exportableAssets.count) assets listos · \(selectedAssets.count) seleccionados")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
            Spacer()
            Button(action: { showLog.toggle() }) {
                Image(systemName: "list.bullet.clipboard")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Ver log de publicaciones")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.white.opacity(0.03))
        .sheet(isPresented: $showLog) {
            PublishLogView()
        }
    }

    // MARK: - Asset Selector

    var assetSelector: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Assets").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                Spacer()
                Button(action: {
                    if selectedAssets.count == exportableAssets.count {
                        selectedAssets.removeAll()
                    } else {
                        selectedAssets = Set(exportableAssets.compactMap { $0.id })
                    }
                }) {
                    Text(selectedAssets.count == exportableAssets.count ? "Ninguno" : "Todos")
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "#7c6af7"))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.white.opacity(0.03))

            if exportableAssets.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "photo.stack")
                        .font(.system(size: 24))
                        .foregroundColor(.white.opacity(0.1))
                    Text("No hay assets.\nGenera y aprueba imágenes primero.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(exportableAssets, id: \.objectID) { asset in
                            assetRow(asset)
                        }
                    }
                    .padding(6)
                }
            }
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
    }

    func assetRow(_ asset: GeneratedAsset) -> some View {
        let isSelected = asset.id.map { selectedAssets.contains($0) } ?? false

        return Button(action: {
            guard let id = asset.id else { return }
            if isSelected { selectedAssets.remove(id) }
            else          { selectedAssets.insert(id) }
        }) {
            HStack(spacing: 8) {
                // Checkbox
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundColor(isSelected ? Color(hex: "#7c6af7") : .secondary)

                // Thumbnail
                if let thumb = asset.thumbnail {
                    Image(nsImage: thumb)
                        .resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 32, height: 32)
                        .cornerRadius(4)
                        .clipped()
                } else {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.06))
                        .frame(width: 32, height: 32)
                        .overlay(Image(systemName: "photo").font(.system(size: 12)).foregroundColor(.secondary))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(asset.baseName?.truncated(18) ?? "—")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white)
                    Text("\(asset.width)×\(asset.height)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Status dot
                Circle()
                    .fill(asset.statusEnum == .approved ? Color.green : Color.gray)
                    .frame(width: 5, height: 5)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(isSelected ? Color(hex: "#7c6af7").opacity(0.12) : Color.clear)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Export Config

    var exportConfig: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {

                // Preset selector
                VStack(alignment: .leading, spacing: 6) {
                    sectionLabel("PLATAFORMA")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(engine.presets) { preset in
                                presetPill(preset)
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                }

                if let preset = selectedPreset {
                    // Watermark config
                    VStack(alignment: .leading, spacing: 6) {
                        sectionLabel("WATERMARK")
                        HStack(spacing: 8) {
                            Toggle("", isOn: .constant(preset.addWatermark))
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .scaleEffect(0.75)
                                .disabled(true)
                            TextField("Texto del watermark", text: $watermarkText)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12))
                                .foregroundColor(.white)
                                .padding(6)
                                .background(Color.white.opacity(0.05))
                                .cornerRadius(5)
                        }
                    }

                    // Export settings summary
                    VStack(alignment: .leading, spacing: 6) {
                        sectionLabel("CONFIGURACIÓN")
                        infoRow("Formato",    preset.format.rawValue.uppercased())
                        infoRow("Calidad",    "\(Int(preset.jpegQuality * 100))%")
                        infoRow("Límite",     preset.maxWidth > 0 ? "\(preset.maxWidth)×\(preset.maxHeight)" : "Sin límite")
                        infoRow("Metadatos",  preset.stripMetadata ? "Eliminados" : "Conservados")
                    }
                    .padding(10)
                    .background(Color.white.opacity(0.03))
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.06), lineWidth: 1))
                }

                // Export msg feedback
                if let msg = exportMsg {
                    Text(msg)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(msg.hasPrefix("✓") ? Color(hex: "#3de3c0") : Color.red.opacity(0.8))
                        .padding(8)
                        .background(Color.white.opacity(0.04))
                        .cornerRadius(6)
                }

                Spacer()
            }
            .padding(14)
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
    }

    // MARK: - Bottom Bar

    var bottomBar: some View {
        HStack(spacing: 10) {
            Text(selectedAssets.isEmpty ? "Selecciona assets para exportar" : "\(selectedAssets.count) seleccionados")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            Spacer()

            Button(action: exportSelected) {
                HStack(spacing: 6) {
                    if isExporting {
                        ProgressView().scaleEffect(0.6).progressViewStyle(.circular)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 11))
                    }
                    Text(isExporting ? "Exportando…" : "Exportar")
                        .font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(
                    Group {
                        if selectedAssets.isEmpty || isExporting {
                            Color.white.opacity(0.08)
                        } else {
                            LinearGradient(
                                colors: [Color(hex: "#7c6af7"), Color(hex: "#3de3c0")],
                                startPoint: .leading, endPoint: .trailing
                            )
                        }
                    }
                )
                .foregroundColor(.white)
                .cornerRadius(7)
            }
            .buttonStyle(.plain)
            .disabled(selectedAssets.isEmpty || isExporting || selectedPreset == nil)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color(red: 0.09, green: 0.09, blue: 0.11))
    }

    // MARK: - Actions

    private func exportSelected() {
        guard !selectedAssets.isEmpty, let preset = selectedPreset else { return }

        let assetsToExport = exportableAssets.filter { asset in
            asset.id.map { selectedAssets.contains($0) } ?? false
        }

        // Cargar imágenes desde disco
        let images: [NSImage] = assetsToExport.compactMap { asset in
            guard let path = asset.imagePath else { return nil }
            return NSImage(contentsOfFile: path)
        }

        guard !images.isEmpty else {
            exportMsg = "⚠️ No se pudieron cargar las imágenes desde disco"
            return
        }

        isExporting = true
        exportMsg = nil

        Task {
            var customPreset = preset
            customPreset.watermarkText = watermarkText

            let exported = await engine.exportImages(
                images,
                preset:  customPreset,
                setName: "export_\(Int(Date().timeIntervalSince1970))",
                notes:   "Exportado desde PublishView"
            )

            await MainActor.run {
                isExporting = false
                exportMsg   = exported.isEmpty
                    ? "⚠️ Error al exportar"
                    : "✓ \(exported.count) imagen(es) exportadas"
            }

            // Limpiar mensaje tras 5 segundos
            try? await Task.sleep(for: .seconds(5))
            await MainActor.run { exportMsg = nil }
        }
    }

    // MARK: - Sub-views

    func presetPill(_ preset: ExportPreset) -> some View {
        let isSelected = selectedPreset?.id == preset.id
        return Button(action: { selectedPreset = preset }) {
            HStack(spacing: 5) {
                Image(systemName: preset.platform.icon)
                    .font(.system(size: 10))
                Text(preset.platform.rawValue)
                    .font(.system(size: 10, weight: .medium))
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(isSelected ? Color(hex: "#7c6af7").opacity(0.25) : Color.white.opacity(0.05))
            .foregroundColor(isSelected ? .white : .secondary)
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color(hex: "#7c6af7").opacity(0.5) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(.secondary)
            .tracking(1.2)
    }

    func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white)
        }
    }
}

// MARK: - PublishLogView

struct PublishLogView: View {

    @StateObject private var engine = PublishEngine.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Log de Publicaciones")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(16)
            .background(Color.white.opacity(0.03))

            Divider().background(Color.white.opacity(0.07))

            if engine.publishLog.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 28))
                        .foregroundColor(.white.opacity(0.1))
                    Text("Sin registros de publicación")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(engine.publishLog.prefix(100)) { entry in
                            publishLogRow(entry)
                            Divider().background(Color.white.opacity(0.04))
                        }
                    }
                }
            }
        }
        .frame(width: 500, height: 380)
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
    }

    func publishLogRow(_ entry: PublishRecord) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "#3de3c0"))

            VStack(alignment: .leading, spacing: 2) {
                Text("\(entry.platform.rawValue) · \(entry.presetName)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                HStack(spacing: 6) {
                    Text(entry.timestamp, style: .relative)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text("· \(entry.imageCount) imagen(es)")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary.opacity(0.7))
                }
            }

            Spacer()

            if !entry.notes.isEmpty {
                Text(entry.notes.truncated(30))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary.opacity(0.6))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}
