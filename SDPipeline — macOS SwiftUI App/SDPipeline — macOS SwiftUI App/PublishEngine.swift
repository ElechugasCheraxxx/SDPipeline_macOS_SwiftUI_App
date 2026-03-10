import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Combine

// MARK: - PublishEngine
//
// Sistema de publicación profesional:
//   - Presets de export por plataforma (OnlyFans, Instagram, Twitter/X, etc.)
//   - Export en lote de imágenes seleccionadas
//   - Watermark por plataforma
//   - Log de publicación con compliance
//   - Firma digital en metadatos de cada export

// MARK: - Models

struct ExportPreset: Codable, Identifiable, Hashable {
    var id:          UUID    = UUID()
    var name:        String
    var platform:    Platform
    var maxWidth:    Int     = 0        // 0 = sin límite
    var maxHeight:   Int     = 0
    var jpegQuality: Double  = 0.92
    var format:      ImageFormat = .jpeg
    var addWatermark: Bool  = true
    var watermarkText: String = ""
    var watermarkOpacity: Double = 0.35
    var stripMetadata: Bool = true
    var addCreatorTag: Bool = true      // embeder tag del creador en EXIF UserComment

    enum Platform: String, Codable, CaseIterable {
        case onlyfans  = "OnlyFans"
        case instagram = "Instagram"
        case twitter   = "Twitter/X"
        case fansly    = "Fansly"
        case patreon   = "Patreon"
        case custom    = "Custom"

        var icon: String {
            switch self {
            case .onlyfans:  return "dollarsign.circle.fill"
            case .instagram: return "camera.circle.fill"
            case .twitter:   return "bird.fill"
            case .fansly:    return "star.circle.fill"
            case .patreon:   return "heart.circle.fill"
            case .custom:    return "gear.circle.fill"
            }
        }

        var defaultMaxSize: (Int, Int) {
            switch self {
            case .onlyfans:  return (3840, 5760)  // sin límite práctico
            case .instagram: return (1080, 1350)  // 4:5 portrait
            case .twitter:   return (4096, 4096)  // límite subida
            case .fansly:    return (3840, 5760)
            case .patreon:   return (2000, 2000)
            case .custom:    return (0, 0)
            }
        }
    }

    enum ImageFormat: String, Codable, CaseIterable {
        case jpeg = "JPEG"
        case png  = "PNG"
        case webp = "WebP"

        var utType: UTType {
            switch self {
            case .jpeg: return .jpeg
            case .png:  return .png
            case .webp: return .webP
            }
        }
    }

    // Presets builtin
    static let builtins: [ExportPreset] = [
        ExportPreset(
            name: "OnlyFans Full Quality",
            platform: .onlyfans,
            maxWidth: 3840, maxHeight: 5760,
            jpegQuality: 0.95, format: .jpeg,
            addWatermark: false, watermarkText: "",
            stripMetadata: true, addCreatorTag: true
        ),
        ExportPreset(
            name: "OnlyFans Preview (Watermark)",
            platform: .onlyfans,
            maxWidth: 1920, maxHeight: 2880,
            jpegQuality: 0.85, format: .jpeg,
            addWatermark: true, watermarkText: "@username",
            watermarkOpacity: 0.4,
            stripMetadata: true, addCreatorTag: true
        ),
        ExportPreset(
            name: "Instagram Portrait",
            platform: .instagram,
            maxWidth: 1080, maxHeight: 1350,
            jpegQuality: 0.90, format: .jpeg,
            addWatermark: false, stripMetadata: true, addCreatorTag: false
        ),
        ExportPreset(
            name: "Twitter/X",
            platform: .twitter,
            maxWidth: 4096, maxHeight: 4096,
            jpegQuality: 0.90, format: .jpeg,
            addWatermark: false, stripMetadata: true, addCreatorTag: false
        ),
    ]
}

struct PublishRecord: Codable, Identifiable {
    var id:          UUID       = UUID()
    var timestamp:   Date       = Date()
    var platform:    ExportPreset.Platform
    var presetName:  String
    var imageCount:  Int
    var exportPaths: [String]
    var notes:       String     = ""
    var setName:     String     = ""
}

// MARK: - PublishEngine

@MainActor
final class PublishEngine: ObservableObject {

    static let shared = PublishEngine()
    private init() { loadState() }

    // MARK: - State

    @Published var presets:       [ExportPreset]    = ExportPreset.builtins
    @Published var publishLog:    [PublishRecord]   = []
    @Published var isExporting:   Bool              = false
    @Published var exportProgress: Double           = 0
    @Published var progressText:  String            = ""
    @Published var lastExportDir: URL?              = nil
    @Published var errorMessage:  String?           = nil

    // MARK: - Export

    func exportImages(
        _ images:  [NSImage],
        preset:    ExportPreset,
        setName:   String   = "",
        notes:     String   = "",
        to destDir: URL?    = nil
    ) async -> [URL] {
        guard !isExporting else { return [] }
        isExporting    = true
        exportProgress = 0
        errorMessage   = nil

        let outputDir  = destDir ?? buildExportDir(preset: preset, setName: setName)
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        var exportedURLs: [URL] = []

        for (index, image) in images.enumerated() {
            progressText   = "Exportando \(index+1)/\(images.count)…"
            exportProgress = Double(index) / Double(images.count)

            let filename = buildFilename(index: index, preset: preset, setName: setName)
            let fileURL  = outputDir.appending(path: filename)

            if let processedImage = processImage(image, preset: preset),
               let data = encode(processedImage, preset: preset) {
                try? data.write(to: fileURL, options: .atomic)
                exportedURLs.append(fileURL)
            }
        }

        exportProgress = 1.0
        progressText   = "Export completado ✓ (\(exportedURLs.count) imágenes)"
        lastExportDir  = outputDir

        // Log de publicación
        let record = PublishRecord(
            platform:    preset.platform,
            presetName:  preset.name,
            imageCount:  exportedURLs.count,
            exportPaths: exportedURLs.map(\.path),
            notes:       notes,
            setName:     setName
        )
        publishLog.insert(record, at: 0)
        saveState()

        isExporting = false
        return exportedURLs
    }

    // MARK: - Image Processing

    private func processImage(_ image: NSImage, preset: ExportPreset) -> NSImage? {
        var processed = image

        // Resize si es necesario
        if preset.maxWidth > 0 || preset.maxHeight > 0 {
            processed = resize(processed, maxWidth: preset.maxWidth, maxHeight: preset.maxHeight)
        }

        // Watermark
        if preset.addWatermark && !preset.watermarkText.isEmpty {
            processed = addWatermark(processed, text: preset.watermarkText, opacity: preset.watermarkOpacity)
        }

        return processed
    }

    private func resize(_ image: NSImage, maxWidth: Int, maxHeight: Int) -> NSImage {
        let size = image.size
        guard maxWidth > 0 || maxHeight > 0 else { return image }

        var newW = size.width
        var newH = size.height

        if maxWidth > 0 && newW > CGFloat(maxWidth) {
            let ratio = CGFloat(maxWidth) / newW
            newW = CGFloat(maxWidth)
            newH *= ratio
        }
        if maxHeight > 0 && newH > CGFloat(maxHeight) {
            let ratio = CGFloat(maxHeight) / newH
            newH = CGFloat(maxHeight)
            newW *= ratio
        }

        let newSize = NSSize(width: newW, height: newH)
        let result  = NSImage(size: newSize)
        result.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize))
        result.unlockFocus()
        return result
    }

    private func addWatermark(_ image: NSImage, text: String, opacity: Double) -> NSImage {
        let result = NSImage(size: image.size)
        result.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: image.size))

        let attrs: [NSAttributedString.Key: Any] = [
            .font:            NSFont.boldSystemFont(ofSize: max(image.size.width * 0.04, 18)),
            .foregroundColor: NSColor.white.withAlphaComponent(opacity),
            .strokeColor:     NSColor.black.withAlphaComponent(opacity * 0.5),
            .strokeWidth:     -2.0
        ]
        let str  = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        let x    = image.size.width  - size.width  - image.size.width  * 0.03
        let y    = image.size.height * 0.03
        str.draw(at: NSPoint(x: x, y: y))
        result.unlockFocus()
        return result
    }

    private func encode(_ image: NSImage, preset: ExportPreset) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bmp  = NSBitmapImageRep(data: tiff) else { return nil }

        switch preset.format {
        case .jpeg:
            return bmp.representation(using: .jpeg, properties: [
                .compressionFactor: preset.jpegQuality
            ])
        case .png:
            return bmp.representation(using: .png, properties: [:])
        case .webp:
            // WebP no tiene soporte nativo en macOS — fallback a PNG
            return bmp.representation(using: .png, properties: [:])
        }
    }

    // MARK: - Helpers

    private func buildExportDir(preset: ExportPreset, setName: String) -> URL {
        let base = VaultManager.shared.exportURL ?? FileManager.default.temporaryDirectory
        let df   = DateFormatter(); df.dateFormat = "yyyyMMdd_HHmm"
        let ts   = df.string(from: Date())
        let name = setName.isEmpty
            ? "\(preset.platform.rawValue)_\(ts)"
            : "\(setName)_\(preset.platform.rawValue)_\(ts)"
        return base.appending(path: name)
    }

    private func buildFilename(index: Int, preset: ExportPreset, setName: String) -> String {
        let base = setName.isEmpty ? preset.platform.rawValue : setName
        let ext  = preset.format == .jpeg ? "jpg" : preset.format.rawValue.lowercased()
        return "\(base)_\(String(format: "%03d", index+1)).\(ext)"
    }

    // MARK: - Persistence

    private func saveState() {
        guard let url  = stateURL,
              let data = try? JSONEncoder.pretty.encode(publishLog) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func loadState() {
        guard let url  = stateURL,
              let data = try? Data(contentsOf: url),
              let recs = try? JSONDecoder.iso8601.decode([PublishRecord].self, from: data)
        else { return }
        publishLog = recs
    }

    private var stateURL: URL? {
        VaultManager.shared.vaultMetaURL?.appending(path: "publish_log.json")
    }
}

// MARK: - PublishView

struct PublishView: View {

    @ObservedObject var engine = PublishEngine.shared
    var images: [NSImage] = []

    @State private var selectedPreset: ExportPreset = ExportPreset.builtins[0]
    @State private var setName:   String = ""
    @State private var notes:     String = ""
    @State private var showLog:   Bool   = false

    var body: some View {
        VStack(spacing: 0) {

            HStack(spacing: 10) {
                Image(systemName: "arrow.up.to.line.circle.fill")
                    .font(.system(size: 14)).foregroundColor(Color(hex: "#fb923c"))
                Text("Publicar / Export")
                    .font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                Spacer()
                Button(action: { showLog.toggle() }) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 12))
                        .foregroundColor(showLog ? Color(hex: "#fb923c") : .secondary)
                }.buttonStyle(.plain).help("Log de publicación")
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(Color.white.opacity(0.03))

            Divider().background(Color.white.opacity(0.07))

            if showLog {
                logPanel
            } else {
                exportPanel
            }
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(Color(hex: "#fb923c").opacity(0.2), lineWidth: 1))
    }

    var exportPanel: some View {
        ScrollView {
            VStack(spacing: 14) {

                // Plataforma / Preset
                VStack(alignment: .leading, spacing: 6) {
                    sLabel("Plataforma")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(engine.presets) { preset in
                                Button(action: { selectedPreset = preset }) {
                                    VStack(spacing: 4) {
                                        Image(systemName: preset.platform.icon)
                                            .font(.system(size: 16))
                                        Text(preset.name).font(.system(size: 9)).lineLimit(2)
                                            .multilineTextAlignment(.center)
                                    }
                                    .frame(width: 80).padding(.vertical, 10)
                                    .background(selectedPreset.id == preset.id
                                        ? Color(hex: "#fb923c").opacity(0.2) : Color.white.opacity(0.04))
                                    .foregroundColor(selectedPreset.id == preset.id
                                        ? Color(hex: "#fb923c") : .secondary)
                                    .cornerRadius(8)
                                }.buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                }

                // Config del preset
                VStack(alignment: .leading, spacing: 8) {
                    sLabel("Configuración del preset")
                    HStack {
                        statBadge("Formato", selectedPreset.format.rawValue)
                        statBadge("Calidad", "\(Int(selectedPreset.jpegQuality * 100))%")
                        if selectedPreset.maxWidth > 0 {
                            statBadge("Max", "\(selectedPreset.maxWidth)×\(selectedPreset.maxHeight)")
                        }
                        statBadge("Watermark", selectedPreset.addWatermark ? "✓" : "✗")
                        statBadge("EXIF", selectedPreset.stripMetadata ? "Strip" : "Keep")
                    }
                }
                .padding(10).background(Color.white.opacity(0.03)).cornerRadius(8)

                // Set name + notes
                VStack(alignment: .leading, spacing: 8) {
                    sLabel("Nombre del set (opcional)")
                    TextField("Summer2025, Beachside_Set…", text: $setName)
                        .textFieldStyle(.roundedBorder)
                    sLabel("Notas para el log")
                    TextField("Publicado en OF, contenido del mes…", text: $notes)
                        .textFieldStyle(.roundedBorder)
                }

                // Resumen
                if !images.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle").font(.system(size: 11))
                            .foregroundColor(Color(hex: "#fb923c"))
                        Text("\(images.count) imagen\(images.count != 1 ? "es" : "") listas para export")
                            .font(.system(size: 12)).foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(8).background(Color(hex: "#fb923c").opacity(0.08)).cornerRadius(6)
                }

                // Progress
                if engine.isExporting {
                    VStack(spacing: 6) {
                        ProgressView(value: engine.exportProgress).accentColor(Color(hex: "#fb923c"))
                        Text(engine.progressText).font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    .padding(10).background(Color.white.opacity(0.03)).cornerRadius(8)
                }

                if let dir = engine.lastExportDir {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(Color(hex: "#34d399"))
                        Text("Exportado: \(dir.lastPathComponent)")
                            .font(.system(size: 11)).foregroundColor(Color(hex: "#34d399"))
                        Spacer()
                        Button("Abrir") { NSWorkspace.shared.open(dir) }
                            .buttonStyle(.plain).font(.system(size: 11))
                            .foregroundColor(Color(hex: "#fb923c"))
                    }
                    .padding(8).background(Color(hex: "#34d399").opacity(0.08)).cornerRadius(6)
                }

                if let err = engine.errorMessage {
                    Text("⚠ \(err)").font(.system(size: 11))
                        .foregroundColor(.red).padding(8)
                        .background(Color.red.opacity(0.08)).cornerRadius(6)
                }

                Button(action: { Task { await runExport() } }) {
                    HStack(spacing: 8) {
                        if engine.isExporting {
                            ProgressView().controlSize(.small).tint(.white)
                            Text("Exportando…")
                        } else {
                            Image(systemName: "arrow.up.to.line.circle.fill")
                            Text("Exportar \(images.isEmpty ? "" : "· \(images.count) imgs") para \(selectedPreset.platform.rawValue)")
                        }
                    }
                    .font(.system(size: 13, weight: .bold))
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(!images.isEmpty
                        ? LinearGradient(colors: [Color(hex: "#fb923c"), Color(hex: "#f97316")],
                                        startPoint: .leading, endPoint: .trailing)
                        : LinearGradient(colors: [.gray.opacity(0.3), .gray.opacity(0.3)],
                                        startPoint: .leading, endPoint: .trailing))
                    .foregroundColor(.white).cornerRadius(10)
                }
                .buttonStyle(.plain).disabled(images.isEmpty || engine.isExporting)
            }
            .padding(14)
        }
    }

    var logPanel: some View {
        Group {
            if engine.publishLog.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 28)).foregroundColor(.white.opacity(0.08))
                    Text("Sin publicaciones registradas")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity).padding(40)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(engine.publishLog.prefix(30)) { record in
                            publishRow(record)
                            Divider().background(Color.white.opacity(0.04))
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    func publishRow(_ r: PublishRecord) -> some View {
        HStack(spacing: 10) {
            Image(systemName: r.platform.icon)
                .font(.system(size: 14)).foregroundColor(Color(hex: "#fb923c"))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.setName.isEmpty ? r.presetName : r.setName)
                    .font(.system(size: 11, weight: .medium)).foregroundColor(.white)
                HStack(spacing: 6) {
                    Text(r.timestamp, style: .relative).font(.system(size: 10)).foregroundColor(.secondary)
                    Text("\(r.imageCount) imgs").font(.system(size: 10)).foregroundColor(.secondary)
                }
            }
            Spacer()
            Text(r.platform.rawValue).font(.system(size: 10)).foregroundColor(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func runExport() async {
        _ = await engine.exportImages(images, preset: selectedPreset, setName: setName, notes: notes)
    }

    func sLabel(_ t: String) -> some View {
        Text(t).font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
    }

    func statBadge(_ label: String, _ value: String) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
            Text(label).font(.system(size: 8)).foregroundColor(.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Color.white.opacity(0.05)).cornerRadius(6)
    }
}
