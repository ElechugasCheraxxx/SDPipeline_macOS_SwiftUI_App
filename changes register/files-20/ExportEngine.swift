import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - ExportEngine
// Responsable de producir las DOS versiones de cada imagen aprobada:
//   1. Versión LIMPIA  → sin metadatos SD, lista para publicar en OnlyFans
//   2. Versión PREVIEW → con watermark visible, para redes sociales / teasers
//
// La versión raw (original) NUNCA sale del vault — solo se exportan las dos
// versiones procesadas. El sidecar JSON tampoco se incluye en ningún export.

@MainActor
final class ExportEngine: ObservableObject {

    static let shared = ExportEngine()
    private init() {}

    // MARK: - Configuración de Watermark
    // Ajustable desde SettingsView (Cmd+,).

    @Published var watermarkConfig = WatermarkConfig()

    // MARK: - Configuración de Watermark (struct)

    struct WatermarkConfig {
        var text:      String   = "@tuusuario"
        var opacity:   Double   = 0.35
        var position:  Position = .bottomRight
        var fontSize:  CGFloat  = 18
        var textColor: NSColor  = .white

        enum Position { case topLeft, topRight, bottomLeft, bottomRight, center }
    }

    // MARK: - Export principal

    struct ExportResult {
        let cleanURL:   URL       // PNG sin metadatos
        let previewURL: URL       // PNG con watermark
        let sha256Clean: String   // Hash del PNG limpio para auditoría
    }

    /// Exportar imagen aprobada → versión limpia + versión preview.
    /// - Parameters:
    ///   - asset: El GeneratedAsset a exportar
    ///   - addWatermark: Si false, no genera preview (útil para pruebas)
    func export(
        asset: GeneratedAsset,
        addWatermark: Bool = true
    ) async throws -> ExportResult {

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

        // 1. Producir PNG limpio (EXIF scrubbing total)
        let cleanData = try scrubAndExport(image: image)
        try cleanData.write(to: cleanURL, options: .atomic)

        let sha256Clean = cleanData.sha256Hex

        // 2. Verificar integridad del clean export
        let verifyData = try Data(contentsOf: cleanURL)
        guard verifyData.sha256Hex == sha256Clean else {
            throw ExportError.integrityCheckFailed
        }

        // 3. Producir preview con watermark
        let previewData: Data
        if addWatermark {
            let watermarked = applyWatermark(to: image, config: watermarkConfig)
            previewData = try scrubAndExport(image: watermarked)
        } else {
            previewData = cleanData
        }
        try previewData.write(to: previewURL, options: .atomic)

        // 4. Actualizar sidecar con rutas de export y timestamp
        updateSidecarAfterExport(
            asset: asset,
            cleanURL: cleanURL,
            previewURL: previewURL
        )

        // 5. Actualizar paths en Core Data
        asset.cleanPath   = cleanURL.path
        asset.previewPath = previewURL.path
        try? AssetStore.shared.container.viewContext.save()

        return ExportResult(
            cleanURL:    cleanURL,
            previewURL:  previewURL,
            sha256Clean: sha256Clean
        )
    }

    // MARK: - EXIF / Metadata Scrubbing

    /// Produce un PNG completamente limpio de metadatos.
    /// Estrategia: re-renderizar la imagen pixel a pixel usando Core Graphics,
    /// luego escribir como PNG nuevo sin ningún bloque de metadatos.
    /// Esto elimina: EXIF, XMP, IPTC, tEXt (chunks PNG con prompts/seeds de A1111),
    /// iCCP (perfiles de color embebidos) y cualquier metadata privada.
    private func scrubAndExport(image: NSImage) throws -> Data {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ExportError.cgImageConversionFailed
        }

        var result: Data? = nil

        // Usar ImageIO para escribir PNG con opciones de privacidad explícitas
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw ExportError.cgImageConversionFailed
        }

        // Opciones: sin metadatos, sin GPS, sin EXIF, sin XMP
        let cleanOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 1.0,
            kCGImageMetadataShouldExcludeGPS:           true,
            // Pasar diccionario de metadatos vacío sobrescribe cualquier metadato existente
            kCGImagePropertyExifDictionary:             [:] as NSDictionary,
            kCGImagePropertyIPTCDictionary:             [:] as NSDictionary,
            kCGImagePropertyTIFFDictionary:             [:] as NSDictionary,
        ]

        CGImageDestinationAddImage(destination, cgImage, cleanOptions as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw ExportError.cgImageConversionFailed
        }

        result = mutableData as Data

        // Segunda pasada: limpiar chunks tEXt/iTXt de PNG (usados por A1111 para
        // incrustar el prompt). Estos NO son EXIF estándar y ImageIO no los elimina.
        guard let pngData = result else { throw ExportError.cgImageConversionFailed }
        return removePNGTextChunks(from: pngData)
    }

    // MARK: - PNG tEXt Chunk Removal
    // Automatic1111 incrusta prompt, seed y parámetros en chunks tEXt/iTXt del PNG.
    // Esta función los elimina reconstruyendo el PNG byte a byte.

    private func removePNGTextChunks(from data: Data) -> Data {
        let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

        // Verificar firma PNG
        guard data.count > 8,
              data.prefix(8).elementsEqual(pngSignature)
        else { return data }

        var result = Data(pngSignature)
        var offset = 8

        let chunksToRemove: Set<String> = ["tEXt", "iTXt", "zTXt", "eXIf", "iCCP"]

        while offset < data.count - 12 {
            // Leer longitud del chunk (4 bytes big-endian)
            let length = Int(data[offset...offset+3].uint32BigEndian)
            let typeRange = offset+4 ..< offset+8
            guard typeRange.upperBound <= data.count else { break }

            let typeBytes = data[typeRange]
            let typeName  = String(bytes: typeBytes, encoding: .ascii) ?? ""

            let totalChunkSize = 4 + 4 + length + 4 // length + type + data + CRC

            if !chunksToRemove.contains(typeName) {
                // Conservar este chunk
                let end = min(offset + totalChunkSize, data.count)
                result.append(data[offset..<end])
            }
            // Si es un chunk a eliminar, simplemente saltarlo

            offset += totalChunkSize

            // IEND siempre debe ser el último chunk
            if typeName == "IEND" { break }
        }

        return result
    }

    // MARK: - Watermark

    private func applyWatermark(to image: NSImage, config: WatermarkConfig) -> NSImage {
        let size = image.size
        let result = NSImage(size: size)

        result.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size))

        let text = config.text as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font:            NSFont.boldSystemFont(ofSize: config.fontSize),
            .foregroundColor: config.textColor.withAlphaComponent(config.opacity),
            .strokeColor:     NSColor.black.withAlphaComponent(config.opacity * 0.6),
            .strokeWidth:     -2.0,
        ]

        let textSize = text.size(withAttributes: attrs)
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

        text.draw(at: point, withAttributes: attrs)
        result.unlockFocus()
        return result
    }

    // MARK: - Sidecar Update

    private func updateSidecarAfterExport(
        asset: GeneratedAsset,
        cleanURL: URL,
        previewURL: URL
    ) {
        guard let sidecarPath = asset.sidecarPath else { return }
        let sidecarURL = URL(fileURLWithPath: sidecarPath)

        // Cargar sidecar existente y actualizar campos de integridad
        // Usamos un wrapper ligero para no re-codificar todo el struct
        guard var rawDict = (try? Data(contentsOf: sidecarURL))
            .flatMap({ try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any]
        else { return }

        var integrity = rawDict["integrity"] as? [String: Any] ?? [:]
        integrity["exportedAt"]           = ISO8601DateFormatter().string(from: Date())
        integrity["cleanVersionExists"]   = true
        integrity["previewVersionExists"] = true
        rawDict["integrity"] = integrity

        if let updated = try? JSONSerialization.data(withJSONObject: rawDict, options: [.prettyPrinted, .sortedKeys]) {
            try? updated.write(to: sidecarURL, options: .atomic)
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
            case .imageNotFound(let p):  return "Imagen no encontrada: \(p)"
            case .vaultNotConfigured:    return "Vault no configurado. Configura el studio primero."
            case .cgImageConversionFailed: return "Error al procesar la imagen con Core Graphics."
            case .integrityCheckFailed:  return "La verificación SHA-256 del export falló. Archivo potencialmente corrupto."
            }
        }
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
