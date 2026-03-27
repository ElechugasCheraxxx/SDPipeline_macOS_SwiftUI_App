import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import Combine
import CryptoKit
@preconcurrency import CoreData

// MARK: - ExportEngine v2
//
// Cambios v1 → v2:
//   ✨ ADD: exportBatch() — exporta múltiples assets en paralelo configurable
//   ✨ ADD: exportWithFormat() — soporte JPEG/PNG/WebP con calidad configurable
//   ✨ ADD: exportPreset system — presets guardables para exportación
//   ✨ ADD: beginSetExport() / finalizeSetExport() — hooks para OnlyFansSetExporter
//   ✨ ADD: progressCallback — opcional para reportar progreso en batch
//   ✨ ADD: ExportPreset model con persistencia
//   🔁 UPD: WatermarkConfig ahora incluye font + diagonal tiling
//   🔁 UPD: scrubAndExport acepta formato de salida

// MARK: - BatchExportConfig / BatchExportResult (top-level — nonisolated)

struct BatchExportConfig: Sendable {
    var preset:           ExportEngine.ExportPreset
    var maxConcurrent:    Int
    var continueOnError:  Bool
    var progressCallback: (@Sendable (Int, Int) -> Void)?

    // Explicit nonisolated init so BatchExportConfig() can be constructed
    // as a default-parameter expression in nonisolated contexts without
    // inheriting @MainActor isolation from ExportEngine. (fixes SW6 warning)
    nonisolated init(
        preset:           ExportEngine.ExportPreset        = ExportEngine.ExportPreset(name: "batch"),
        maxConcurrent:    Int                              = 2,
        continueOnError:  Bool                             = true,
        progressCallback: (@Sendable (Int, Int) -> Void)? = nil
    ) {
        self.preset           = preset
        self.maxConcurrent    = maxConcurrent
        self.continueOnError  = continueOnError
        self.progressCallback = progressCallback
    }
}

struct BatchExportResult {
    let results:       [(GeneratedAsset, ExportEngine.ExportResult)]
    let errors:        [(GeneratedAsset, Error)]
    let totalExported: Int
    let totalFailed:   Int
    let durationSec:   Double
}

@MainActor
final class ExportEngine: ObservableObject {

    static let shared = ExportEngine()
    private init() { loadPresets() }

    // MARK: - Configuración de Watermark

    @Published var watermarkConfig = WatermarkConfig()

    struct WatermarkConfig {
        var text:      String   = "@tuusuario"
        var opacity:   Double   = 0.35
        var position:  Position = .bottomRight
        var fontSize:  CGFloat  = 18
        var textColor: NSColor  = .white
        var tiled:     Bool     = false  // NEW: watermark en diagonal tiled
        var tileAngle: Double   = -30    // Ángulo del tiled watermark

        enum Position: CaseIterable {
            case topLeft, topRight, bottomLeft, bottomRight, center
        }
    }

    // MARK: - Export Presets

    struct ExportPreset: Codable, Identifiable {
        var id:            UUID            = UUID()
        var name:          String
        var format:        OutputFormat    = .jpeg
        var quality:       Double          = 0.92
        var addWatermark:  Bool            = true
        var watermarkText: String          = "@creator"
        var maxDimension:  Int?            = nil     // nil = sin resize
        var isFavorite:    Bool            = false

        // Explicit nonisolated init so this struct can be constructed from
        // nonisolated contexts (e.g. BatchExportConfig default parameter
        // expressions) without inheriting @MainActor isolation from ExportEngine.
        nonisolated init(
            id:            UUID         = UUID(),
            name:          String,
            format:        OutputFormat = .jpeg,
            quality:       Double       = 0.92,
            addWatermark:  Bool         = true,
            watermarkText: String       = "@creator",
            maxDimension:  Int?         = nil,
            isFavorite:    Bool         = false
        ) {
            self.id            = id
            self.name          = name
            self.format        = format
            self.quality       = quality
            self.addWatermark  = addWatermark
            self.watermarkText = watermarkText
            self.maxDimension  = maxDimension
            self.isFavorite    = isFavorite
        }

        enum OutputFormat: String, CaseIterable, Codable {
            case jpeg = "JPEG"
            case png  = "PNG"
            case webp = "WebP"

            var utType: UTType {
                switch self {
                case .jpeg: return .jpeg
                case .png:  return .png
                case .webp: return UTType("public.webp") ?? .png
                }
            }
            var fileExtension: String { rawValue.lowercased() }
        }
    }

    @Published var presets: [ExportPreset] = []

    // MARK: - Export Result

    struct ExportResult {
        let cleanURL:    URL
        let previewURL:  URL
        let sha256Clean: String
        let format:      ExportPreset.OutputFormat
        let fileSizeBytes: Int
    }

    // MARK: - Single Asset Export (v1 compat + format support)

    func export(
        asset: GeneratedAsset,
        addWatermark: Bool = true,
        preset: ExportPreset? = nil
    ) async throws -> ExportResult {
        let activePreset = preset ?? ExportPreset(name: "default", addWatermark: addWatermark)

        guard let imagePath = asset.imagePath,
              let origData  = try? Data(contentsOf: URL(fileURLWithPath: imagePath)),
              let image     = NSImage(data: origData)
        else {
            throw ExportError.imageNotFound(asset.imagePath ?? "nil")
        }

        guard let cleanURL   = VaultManager.shared.cleanExportURL(for: URL(fileURLWithPath: imagePath)),
              let previewURL = VaultManager.shared.previewExportURL(for: URL(fileURLWithPath: imagePath))
        else {
            throw ExportError.vaultNotConfigured
        }

        // 1. Resize si el preset lo indica
        let processedImage = activePreset.maxDimension != nil
            ? resize(image: image, maxDim: activePreset.maxDimension!)
            : image

        // 2. Producir imagen limpia
        let cleanData = try scrubAndExport(image: processedImage, format: activePreset.format, quality: activePreset.quality)
        try cleanData.write(to: cleanURL, options: .completeFileProtection)
        let sha256Clean = cleanData.sha256Hex // Extraído de Data+Crypto.swift

        // 3. Verificar integridad
        let verifyData = try Data(contentsOf: cleanURL)
        guard verifyData.sha256Hex == sha256Clean else {
            throw ExportError.integrityCheckFailed
        }

        // 4. Producir preview con watermark
        let previewData: Data
        if activePreset.addWatermark {
            var wConfig = watermarkConfig
            wConfig.text = activePreset.watermarkText
            let watermarked = applyWatermark(to: processedImage, config: wConfig)
            previewData = try scrubAndExport(image: watermarked, format: activePreset.format, quality: activePreset.quality)
        } else {
            previewData = cleanData
        }
        try previewData.write(to: previewURL, options: .completeFileProtection)

        // 5. Actualizar sidecar + Core Data
        updateSidecarAfterExport(asset: asset, cleanURL: cleanURL, previewURL: previewURL)
        asset.cleanPath   = cleanURL.path
        asset.previewPath = previewURL.path
        try? AssetStore.shared.container.viewContext.save()

        // 6. Incrustar IPTC/XMP en versión limpia
        let tags = TaggingEngine.shared.tags(for: asset)
        _ = try? IPTCMetadataWriter.embed(in: cleanURL, asset: asset, tags: tags)

        return ExportResult(
            cleanURL:      cleanURL,
            previewURL:    previewURL,
            sha256Clean:   sha256Clean,
            format:        activePreset.format,
            fileSizeBytes: cleanData.count
        )
    }

    // MARK: - Batch Export

    // Swift 6 fix: NSManagedObject does not conform to Sendable, so it cannot be used
    // directly as the result type of a TaskGroup child task. Since both exportBatch()
    // and export() are @MainActor-isolated, all access to GeneratedAsset happens on the
    // main actor's serial executor — making this wrapper safe to use.
    private struct UncheckedAssetRef: @unchecked Sendable {
        let asset: GeneratedAsset
    }

    @MainActor
    func exportBatch(
        assets: [GeneratedAsset],
        config: BatchExportConfig = BatchExportConfig()
    ) async -> BatchExportResult {
        let start = Date()
        var results: [(GeneratedAsset, ExportResult)] = []
        var errors:  [(GeneratedAsset, Error)]         = []

        let semaphore = AsyncSemaphore(limit: config.maxConcurrent)

        await withTaskGroup(of: (UncheckedAssetRef, Result<ExportResult, Error>).self) { group in
            for asset in assets {
                let ref = UncheckedAssetRef(asset: asset)
                // @MainActor keeps GeneratedAsset on the main-actor executor so it
                // never crosses a concurrency boundary. Both export() and exportBatch()
                // are @MainActor-isolated, so this adds no extra serialisation cost.
                group.addTask { @MainActor in
                    await semaphore.wait()
                    defer { Task { await semaphore.signal() } }
                    do {
                        let result = try await self.export(asset: ref.asset, preset: config.preset)
                        return (ref, .success(result))
                    } catch {
                        return (ref, .failure(error))
                    }
                }
            }

            var completed = 0
            for await (ref, outcome) in group {
                completed += 1
                config.progressCallback?(completed, assets.count)
                switch outcome {
                case .success(let r): results.append((ref.asset, r))
                case .failure(let e):
                    errors.append((ref.asset, e))
                    if !config.continueOnError { group.cancelAll() }
                }
            }
        }

        return BatchExportResult(
            results:       results,
            errors:        errors,
            totalExported: results.count,
            totalFailed:   errors.count,
            durationSec:   Date().timeIntervalSince(start)
        )
    }

    // MARK: - Set Export Hook

    /// Prepara el directorio de export para un set y retorna las URLs destino.
    func beginSetExport(setLabel: String) throws -> (cleanDir: URL, previewDir: URL) {
        guard let vault = VaultManager.shared.vaultRoot else {
            throw ExportError.vaultNotConfigured
        }
        let cleanDir   = vault.appendingPathComponent("Exports/\(setLabel)/clean")
        let previewDir = vault.appendingPathComponent("Exports/\(setLabel)/preview")
        try FileManager.default.createDirectory(at: cleanDir,   withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: previewDir, withIntermediateDirectories: true)
        return (cleanDir, previewDir)
    }

    /// Exporta un asset directamente a URLs de destino específicas.
    func exportToDestination(
        asset: GeneratedAsset,
        cleanURL: URL,
        previewURL: URL,
        preset: ExportPreset = ExportPreset(name: "set")
    ) async throws -> String {
        guard let imagePath = asset.imagePath,
              let origData  = try? Data(contentsOf: URL(fileURLWithPath: imagePath)),
              let image     = NSImage(data: origData)
        else { throw ExportError.imageNotFound(asset.imagePath ?? "nil") }

        let processedImage = preset.maxDimension != nil
            ? resize(image: image, maxDim: preset.maxDimension!)
            : image

        let cleanData = try scrubAndExport(image: processedImage, format: preset.format, quality: preset.quality)
        try cleanData.write(to: cleanURL, options: .completeFileProtection)
        let sha256 = cleanData.sha256Hex

        if preset.addWatermark {
            var wConfig = watermarkConfig
            wConfig.text = preset.watermarkText
            let wm = applyWatermark(to: processedImage, config: wConfig)
            let previewData = try scrubAndExport(image: wm, format: preset.format, quality: preset.quality)
            try previewData.write(to: previewURL, options: .completeFileProtection)
        } else {
            try cleanData.write(to: previewURL, options: .completeFileProtection)
        }
        return sha256
    }

    // MARK: - Preset Management

    func addPreset(_ preset: ExportPreset) {
        presets.append(preset)
        savePresets()
    }

    func removePreset(id: UUID) {
        presets.removeAll { $0.id == id }
        savePresets()
    }

    func updatePreset(_ preset: ExportPreset) {
        if let idx = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[idx] = preset
            savePresets()
        }
    }

    private func loadPresets() {
        guard let data = UserDefaults.standard.data(forKey: "export.presets"),
              let loaded = try? JSONDecoder().decode([ExportPreset].self, from: data)
        else { return }
        presets = loaded
    }

    private func savePresets() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        UserDefaults.standard.set(data, forKey: "export.presets")
    }

    // MARK: - EXIF / Metadata Scrubbing

    func scrubAndExport(
        image: NSImage,
        format: ExportPreset.OutputFormat = .png,
        quality: Double = 1.0
    ) throws -> Data {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ExportError.cgImageConversionFailed
        }

        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData, format.utType.identifier as CFString, 1, nil
        ) else {
            throw ExportError.cgImageConversionFailed
        }

        let cleanOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImageMetadataShouldExcludeGPS:           true,
            kCGImagePropertyExifDictionary:             [:] as NSDictionary,
            kCGImagePropertyIPTCDictionary:             [:] as NSDictionary,
            kCGImagePropertyTIFFDictionary:             [:] as NSDictionary,
        ]

        CGImageDestinationAddImage(destination, cgImage, cleanOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ExportError.cgImageConversionFailed
        }

        let data = mutableData as Data
        // Para PNG: limpiar chunks tEXt/iTXt de A1111
        return format == .png ? removePNGTextChunks(from: data) : data
    }

    // MARK: - PNG tEXt Chunk Removal

    private func removePNGTextChunks(from data: Data) -> Data {
        let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard data.count > 8, data.prefix(8).elementsEqual(pngSignature) else { return data }

        var result = Data(pngSignature)
        var offset = 8
        let chunksToRemove: Set<String> = ["tEXt", "iTXt", "zTXt", "eXIf", "iCCP"]

        while offset < data.count - 12 {
            let length = Int(data[offset...offset+3].uint32BigEndian)
            let typeRange = offset+4 ..< offset+8
            guard typeRange.upperBound <= data.count else { break }
            let typeName  = String(bytes: data[typeRange], encoding: .ascii) ?? ""
            let totalChunkSize = 4 + 4 + length + 4
            if !chunksToRemove.contains(typeName) {
                let end = min(offset + totalChunkSize, data.count)
                result.append(data[offset..<end])
            }
            offset += totalChunkSize
            if typeName == "IEND" { break }
        }
        return result
    }

    // MARK: - Resize

    private func resize(image: NSImage, maxDim: Int) -> NSImage {
        let size  = image.size
        let scale = CGFloat(maxDim) / max(size.width, size.height)
        guard scale < 1.0 else { return image }
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let result  = NSImage(size: newSize)
        result.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize))
        result.unlockFocus()
        return result
    }

    // MARK: - Watermark

    func applyWatermark(to image: NSImage, config: WatermarkConfig) -> NSImage {
        let size   = image.size
        let result = NSImage(size: size)
        result.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size))

        if config.tiled {
            applyTiledWatermark(text: config.text, size: size, config: config)
        } else {
            applySingleWatermark(text: config.text, size: size, config: config)
        }

        result.unlockFocus()
        return result
    }

    private func applySingleWatermark(text: String, size: CGSize, config: WatermarkConfig) {
        let nsText = text as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font:            NSFont.boldSystemFont(ofSize: max(size.width * 0.04, config.fontSize)),
            .foregroundColor: config.textColor.withAlphaComponent(config.opacity),
            .strokeColor:     NSColor.black.withAlphaComponent(config.opacity * 0.6),
            .strokeWidth:     -2.0,
        ]
        let textSize = nsText.size(withAttributes: attrs)
        let margin: CGFloat = 20
        let point: CGPoint = {
            switch config.position {
            case .topLeft:     return CGPoint(x: margin, y: size.height - textSize.height - margin)
            case .topRight:    return CGPoint(x: size.width - textSize.width - margin, y: size.height - textSize.height - margin)
            case .bottomLeft:  return CGPoint(x: margin, y: margin)
            case .bottomRight: return CGPoint(x: size.width - textSize.width - margin, y: margin)
            case .center:      return CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2)
            }
        }()
        nsText.draw(at: point, withAttributes: attrs)
    }

    private func applyTiledWatermark(text: String, size: CGSize, config: WatermarkConfig) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.translateBy(x: size.width / 2, y: size.height / 2)
        ctx.rotate(by: CGFloat(config.tileAngle) * .pi / 180)

        let nsText = text as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font:            NSFont.systemFont(ofSize: max(size.width * 0.03, 14)),
            .foregroundColor: config.textColor.withAlphaComponent(config.opacity * 0.5),
        ]
        let textSize  = nsText.size(withAttributes: attrs)
        let xSpacing  = textSize.width * 2.5
        let ySpacing  = textSize.height * 3.0
        let diagonal  = hypot(size.width, size.height)
        let cols = Int(diagonal / xSpacing) + 2
        let rows = Int(diagonal / ySpacing) + 2

        for row in -rows...rows {
            for col in -cols...cols {
                let x = CGFloat(col) * xSpacing
                let y = CGFloat(row) * ySpacing
                nsText.draw(at: CGPoint(x: x - textSize.width / 2, y: y - textSize.height / 2), withAttributes: attrs)
            }
        }
        ctx.restoreGState()
    }

    // MARK: - Sidecar Update

    private func updateSidecarAfterExport(asset: GeneratedAsset, cleanURL: URL, previewURL: URL) {
        guard let sidecarPath = asset.sidecarPath else { return }
        let sidecarURL = URL(fileURLWithPath: sidecarPath)
        guard var rawDict = (try? Data(contentsOf: sidecarURL))
            .flatMap({ try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any]
        else { return }
        var integrity = rawDict["integrity"] as? [String: Any] ?? [:]
        integrity["exportedAt"]           = ISO8601DateFormatter().string(from: Date())
        integrity["cleanVersionExists"]   = true
        integrity["previewVersionExists"] = true
        rawDict["integrity"] = integrity
        if let updated = try? JSONSerialization.data(withJSONObject: rawDict, options: [.prettyPrinted, .sortedKeys]) {
            try? updated.write(to: sidecarURL, options: .completeFileProtection)
        }
    }

    // MARK: - Errors

    enum ExportError: LocalizedError {
        case imageNotFound(String)
        case vaultNotConfigured
        case cgImageConversionFailed
        case integrityCheckFailed

        var errorDescription: String? {
            switch self {
            case .imageNotFound(let p):    return "Imagen no encontrada: \(p)"
            case .vaultNotConfigured:      return "Vault no configurado."
            case .cgImageConversionFailed: return "Error al procesar la imagen con Core Graphics."
            case .integrityCheckFailed:    return "Verificación SHA-256 del export falló."
            }
        }
    }
}

// MARK: - Async Semaphore (concurrencia controlada)

actor AsyncSemaphore {
    private var count: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.count = limit }

    func wait() async {
        if count > 0 { count -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        if waiters.isEmpty { count += 1; return }
        waiters.removeFirst().resume()
    }
}

// MARK: - Data helpers

extension DataProtocol {
    var uint32BigEndian: UInt32 {
        var value: UInt32 = 0
        let bytes = Array(self)
        guard bytes.count >= 4 else { return 0 }
        value = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) |
                (UInt32(bytes[2]) << 8)  |  UInt32(bytes[3])
        return value
    }
}


