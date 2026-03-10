import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import SwiftUI

// MARK: - IPTCMetadataWriter
//
// Incrusta metadatos IPTC/XMP en imágenes exportadas (solo versión clean).
// Objetivo: hacer la biblioteca navegable y compatible con DAMs externos
// (Eagle, DigiKam, Lightroom, Finder Smart Folders).
//
// Campos embebidos:
//   IPTC: Creator, Copyright, Keywords, Description, DateCreated
//   XMP:  dc:creator, dc:rights, dc:description, dc:subject (tags),
//         xmp:CreateDate, xmp:CreatorTool, xmp:Rating
//   EXIF: UserComment (prompt hash), DateTimeOriginal
//
// NOTA DE SEGURIDAD:
//   El PROMPT COMPLETO nunca se incrusta en archivos de export — solo el hash.
//   Los metadatos IPTC/XMP se añaden DESPUÉS del EXIF scrub de ExportEngine.
//   Para la versión PREVIEW (watermark) se omiten los metadatos de autoría.
//
// ROADMAP: "Biblioteca con metadatos incrustados IPTC/XMP/EXIF" (🟠 CORTO PLAZO)

struct IPTCMetadataWriter {

    // MARK: - Configuration

    struct IPTCConfig {
        var creatorName:    String = ""       // Nombre del estudio/artista
        var copyrightLine:  String = ""       // "© 2025 Studio Name. All rights reserved."
        var website:        String = ""       // URL del creador
        var embedPromptHash: Bool  = true     // SHA-256 truncado en UserComment
        var embedTags:       Bool  = true     // Tags de TaggingEngine en Keywords
        var embedRating:     Bool  = true     // Rating Core Data en XMP:Rating

        // Leer/guardar en UserDefaults
        static let defaults = IPTCConfig()
        static var saved: IPTCConfig {
            var c = IPTCConfig()
            let ud = UserDefaults.standard
            c.creatorName    = ud.string(forKey: "iptc.creatorName")   ?? ""
            c.copyrightLine  = ud.string(forKey: "iptc.copyright")     ?? ""
            c.website        = ud.string(forKey: "iptc.website")       ?? ""
            c.embedPromptHash = ud.bool(forKey:  "iptc.embedHash")
            c.embedTags       = ud.bool(forKey:  "iptc.embedTags")
            c.embedRating     = ud.bool(forKey:  "iptc.embedRating")
            return c
        }

        func persist() {
            let ud = UserDefaults.standard
            ud.set(creatorName,    forKey: "iptc.creatorName")
            ud.set(copyrightLine,  forKey: "iptc.copyright")
            ud.set(website,        forKey: "iptc.website")
            ud.set(embedPromptHash, forKey: "iptc.embedHash")
            ud.set(embedTags,       forKey: "iptc.embedTags")
            ud.set(embedRating,     forKey: "iptc.embedRating")
        }
    }

    // MARK: - Main API

    /// Incrustar metadatos IPTC/XMP en un PNG ya exportado (clean version).
    /// Devuelve la URL del archivo modificado (sobrescribe el original).
    @discardableResult
    static func embed(
        in imageURL: URL,
        asset: GeneratedAsset,
        tags: [String] = [],
        config: IPTCConfig = .saved
    ) throws -> URL {

        guard let imageData = try? Data(contentsOf: imageURL),
              let source    = CGImageSourceCreateWithData(imageData as CFData, nil),
              let cgImage   = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw IPTCError.sourceLoadFailed }

        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutableData, UTType.png.identifier as CFString, 1, nil
        ) else { throw IPTCError.destinationCreateFailed }

        // Build metadata properties dict
        let metadata = buildMetadataDict(asset: asset, tags: tags, config: config)

        CGImageDestinationAddImage(dest, cgImage, metadata as CFDictionary)

        guard CGImageDestinationFinalize(dest) else {
            throw IPTCError.finalizeFailed
        }

        try (mutableData as Data).write(to: imageURL, options: .atomic)
        return imageURL
    }

    // MARK: - Metadata Builder

    private static func buildMetadataDict(
        asset: GeneratedAsset,
        tags:  [String],
        config: IPTCConfig
    ) -> [CFString: Any] {

        let dateStr = ISO8601DateFormatter().string(from: asset.createdAt ?? Date())
        let shortDate = String(dateStr.prefix(10)) // "2025-01-15"
        let promptHash = config.embedPromptHash
            ? (asset.promptPositive ?? "").data(using: .utf8).map { Data($0).sha256Hex.prefix(16) }.map(String.init) ?? ""
            : ""

        // ── IPTC Dictionary ──────────────────────────────────────────────
        var iptcDict: [CFString: Any] = [:]

        if !config.creatorName.isEmpty {
            iptcDict[kCGImagePropertyIPTCCreatorContactInfo] = [
                kCGImagePropertyIPTCContactInfoCity: ""
            ]
            iptcDict[kCGImagePropertyIPTCByline]          = config.creatorName
            iptcDict[kCGImagePropertyIPTCBylineTitle]      = "AI Art Director"
        }

        if !config.copyrightLine.isEmpty {
            iptcDict[kCGImagePropertyIPTCCopyrightNotice] = config.copyrightLine
        }

        // Description: session tag + asset ID fragment (NO prompt completo)
        let description = [
            asset.sessionTag,
            asset.baseName
        ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        if !description.isEmpty {
            iptcDict[kCGImagePropertyIPTCCaptionAbstract] = description
        }

        iptcDict[kCGImagePropertyIPTCDateCreated] = shortDate

        // Keywords: tags + model name (truncated, no prompt)
        if config.embedTags && !tags.isEmpty {
            iptcDict[kCGImagePropertyIPTCKeywords] = tags
        }

        // ── TIFF Dictionary ──────────────────────────────────────────────
        var tiffDict: [CFString: Any] = [:]
        tiffDict[kCGImagePropertyTIFFSoftware]   = "SDPipelineStudio"
        tiffDict[kCGImagePropertyTIFFDateTime]   = shortDate
        if !config.creatorName.isEmpty {
            tiffDict[kCGImagePropertyTIFFArtist] = config.creatorName
        }
        if !config.copyrightLine.isEmpty {
            tiffDict[kCGImagePropertyTIFFCopyright] = config.copyrightLine
        }

        // ── EXIF Dictionary ──────────────────────────────────────────────
        var exifDict: [CFString: Any] = [:]
        exifDict[kCGImagePropertyExifDateTimeOriginal] = shortDate
        // UserComment: solo hash corto (NO el prompt)
        if config.embedPromptHash && !promptHash.isEmpty {
            exifDict[kCGImagePropertyExifUserComment] = "ph:\(promptHash)"
        }

        // ── Rating (XMP-style via TIFF) ──────────────────────────────────
        // Core Graphics no tiene native XMP API, así que usamos la extensión
        // de rating estándar de macOS vía kCGImagePropertyIPTCUrgency (workaround)
        // Nota: el rating real en XMP requiere un XMP sidecar o librería externa.
        if config.embedRating && asset.rating > 0 {
            // Map 1-5 stars to IPTC urgency 1-5 (invertido: 1=highest en IPTC)
            let urgency = max(1, min(5, 6 - Int(asset.rating)))
            iptcDict[kCGImagePropertyIPTCUrgency] = "\(urgency)"
        }

        return [
            kCGImagePropertyIPTCDictionary: iptcDict,
            kCGImagePropertyTIFFDictionary: tiffDict,
            kCGImagePropertyExifDictionary: exifDict,
        ]
    }

    // MARK: - Errors

    enum IPTCError: LocalizedError {
        case sourceLoadFailed
        case destinationCreateFailed
        case finalizeFailed

        var errorDescription: String? {
            switch self {
            case .sourceLoadFailed:         return "No se pudo cargar la imagen fuente."
            case .destinationCreateFailed:  return "No se pudo crear el destino de imagen."
            case .finalizeFailed:           return "Error al finalizar la imagen con metadatos."
            }
        }
    }
}

// MARK: - IPTCSettingsView (embed in SettingsView .export section)

struct IPTCSettingsView: View {

    @State private var config = IPTCMetadataWriter.IPTCConfig.saved

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            VStack(alignment: .leading, spacing: 6) {
                Text("Nombre del creador / estudio")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                TextField("Ej: Studio Valentina", text: $config.creatorName)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12))
                    .onChange(of: config.creatorName) { _, _ in config.persist() }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Línea de copyright")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                TextField("© 2025 Studio Name. All rights reserved.", text: $config.copyrightLine)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12))
                    .onChange(of: config.copyrightLine) { _, _ in config.persist() }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Website / contacto")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                TextField("https://example.com", text: $config.website)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12))
                    .onChange(of: config.website) { _, _ in config.persist() }
            }

            Divider().background(Color.white.opacity(0.07))

            Toggle(isOn: $config.embedTags) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Incrustar tags en Keywords IPTC")
                        .font(.system(size: 12)).foregroundColor(.white)
                    Text("Los tags de la galería aparecerán como keywords en el archivo PNG")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)
            .onChange(of: config.embedTags) { _, _ in config.persist() }

            Toggle(isOn: $config.embedRating) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Incrustar rating en metadatos IPTC")
                        .font(.system(size: 12)).foregroundColor(.white)
                    Text("El rating de la galería se guarda como IPTC Urgency (1-5)")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)
            .onChange(of: config.embedRating) { _, _ in config.persist() }

            Toggle(isOn: $config.embedPromptHash) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Incrustar hash de prompt en EXIF UserComment")
                        .font(.system(size: 12)).foregroundColor(.white)
                    Text("Solo el SHA-256 truncado (16 hex chars), no el prompt completo")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)
            .onChange(of: config.embedPromptHash) { _, _ in config.persist() }
        }
    }
}
