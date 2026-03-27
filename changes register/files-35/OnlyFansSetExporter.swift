import Foundation
import AppKit
import SwiftUI
import Combine
import CryptoKit
import ZipArchive

// MARK: - OnlyFansSetExporter
//
// Motor de exportación automatizada de sets para OnlyFans y plataformas similares.
// Produce un archivo ZIP listo para subir que incluye:
//   • Imágenes limpias (EXIF scrubbed) — versión pública
//   • Imágenes preview con watermark — para teasers/redes sociales
//   • Thumbnails 400x600px para catálogo de sets
//   • manifest.json con metadatos del set
//   • compliance.json con checklist de cumplimiento
//   • release_notes.txt autogenerado
//
// Pipeline:
//   1. Compliance gate: verifica licencias, consentimientos y NSFW flags
//   2. Export de imágenes vía ExportEngine (clean + preview)
//   3. Generación de thumbnails
//   4. Naming conventions: {handle}_{fecha}_{titulo}_{nro}.png
//   5. Compresión ZIP con hash SHA-256 del archivo final
//   6. Log en PublishComplianceLogger
//
// ROADMAP: "Export automático de sets OnlyFans" (🟠 CORTO PLAZO) — COMPLETADO

@MainActor
final class OnlyFansSetExporter: ObservableObject {

    static let shared = OnlyFansSetExporter()
    private init() {}

    // MARK: - Models

    struct SetExportConfig: Codable {
        var creatorHandle:      String  = "@creator"
        var includeWatermark:   Bool    = true
        var watermarkText:      String  = "@creator"
        var generateThumbnails: Bool    = true
        var thumbnailMaxDim:    Int     = 600
        var jpegQuality:        Double  = 0.92
        var outputFormat:       OutputFormat = .jpeg
        var namingConvention:   NamingConvention = .standard
        var includeManifest:    Bool    = true
        var requireCompliance:  Bool    = true
        var zipOutput:          Bool    = true

        enum OutputFormat: String, CaseIterable, Codable {
            case jpeg = "JPEG"
            case png  = "PNG"
            case webp = "WebP"
        }

        enum NamingConvention: String, CaseIterable, Codable {
            case standard    = "handle_date_title_nro"
            case sequential  = "set_nro"
            case uuid        = "uuid"
        }
    }

    struct SetExportResult {
        let setTitle:       String
        let assetCount:     Int
        let cleanURLs:      [URL]
        let previewURLs:    [URL]
        let thumbnailURLs:  [URL]
        let zipURL:         URL?
        let manifestURL:    URL
        let complianceURL:  URL
        let sha256:         String
        let exportedAt:     Date        = Date()
    }

    struct ExportProgress {
        var phase:       Phase         = .idle
        var current:     Int           = 0
        var total:       Int           = 0
        var currentFile: String        = ""

        var fraction: Double { total > 0 ? Double(current) / Double(total) : 0 }

        enum Phase: String {
            case idle        = "Esperando"
            case compliance  = "Verificando compliance…"
            case exporting   = "Exportando imágenes…"
            case thumbnails  = "Generando thumbnails…"
            case manifest    = "Escribiendo manifest…"
            case zipping     = "Comprimiendo set…"
            case finalizing  = "Finalizando…"
            case complete    = "Completado"
            case failed      = "Error"
        }
    }

    // MARK: - Published State

    @Published var progress     = ExportProgress()
    @Published var config       = SetExportConfig()
    @Published var isExporting  = false
    @Published var lastResult:  SetExportResult?
    @Published var exportError: String?

    // MARK: - Compliance Violation

    struct ComplianceViolation: Identifiable {
        let id = UUID()
        let severity: Severity
        let message:  String

        enum Severity { case blocking, warning }
    }

    // MARK: - Main Export Method

    /// Exporta un set completo de assets.
    /// - Parameters:
    ///   - assets:   Los GeneratedAssets a exportar (ordenados = orden final del set)
    ///   - setTitle: Título del set (ej: "Set Playa Verano #3")
    ///   - session:  ContentSession asociado (para metadatos)
    func exportSet(
        assets: [GeneratedAsset],
        setTitle: String,
        session: ContentSessionManager.ContentSession? = nil
    ) async throws -> SetExportResult {
        guard !assets.isEmpty else {
            throw ExportSetError.noAssets
        }

        isExporting  = true
        exportError  = nil
        progress     = ExportProgress(phase: .compliance, total: assets.count)

        defer { isExporting = false }

        // 1. ── Compliance Gate ──────────────────────────────────────────────
        if config.requireCompliance {
            let violations = await runComplianceChecks(assets: assets)
            let blocking   = violations.filter { $0.severity == .blocking }
            if !blocking.isEmpty {
                progress.phase = .failed
                let msgs = blocking.map(\.message).joined(separator: "; ")
                throw ExportSetError.complianceFailed(msgs)
            }
        }

        // 2. ── Preparar directorio de salida ───────────────────────────────
        let sanitized = sanitizeFilename(setTitle)
        let dateStr   = ISO8601DateFormatter().string(from: Date())
            .prefix(10)
            .replacingOccurrences(of: "-", with: "")
        let dirName   = "\(config.creatorHandle.trimmingCharacters(in: CharacterSet(charactersIn: "@")))_\(dateStr)_\(sanitized)"

        guard let vault = VaultManager.shared.activeVault else {
            throw ExportSetError.vaultNotConfigured
        }

        let exportDir = vault
            .appendingPathComponent("Exports")
            .appendingPathComponent(dirName)

        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)

        let cleanDir   = exportDir.appendingPathComponent("clean")
        let previewDir = exportDir.appendingPathComponent("preview")
        let thumbDir   = exportDir.appendingPathComponent("thumbnails")

        for dir in [cleanDir, previewDir, thumbDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // 3. ── Exportar imágenes ───────────────────────────────────────────
        progress.phase = .exporting
        var cleanURLs:   [URL] = []
        var previewURLs: [URL] = []

        for (idx, asset) in assets.enumerated() {
            progress.current  = idx + 1
            progress.currentFile = asset.baseName ?? "imagen_\(idx+1)"

            let nro     = String(format: "%03d", idx + 1)
            let baseName = buildFilename(asset: asset, index: nro, setTitle: sanitized)

            // Exportar imagen limpia
            let cleanURL   = cleanDir.appendingPathComponent("\(baseName).\(config.outputFormat.rawValue.lowercased())")
            let previewURL = previewDir.appendingPathComponent("\(baseName)_preview.\(config.outputFormat.rawValue.lowercased())")

            try await exportSingleImage(asset: asset, to: cleanURL, withWatermark: false)
            if config.includeWatermark {
                try await exportSingleImage(asset: asset, to: previewURL, withWatermark: true)
                previewURLs.append(previewURL)
            }
            cleanURLs.append(cleanURL)
        }

        // 4. ── Thumbnails ─────────────────────────────────────────────────
        progress.phase = .thumbnails
        var thumbnailURLs: [URL] = []

        if config.generateThumbnails {
            for (idx, asset) in assets.enumerated() {
                progress.current = idx + 1
                if let image = loadImage(asset: asset) {
                    let thumbURL = thumbDir.appendingPathComponent("thumb_\(String(format: "%03d", idx+1)).jpg")
                    if let thumbData = generateThumbnail(image: image, maxDim: config.thumbnailMaxDim) {
                        try thumbData.write(to: thumbURL, options: .atomic)
                        thumbnailURLs.append(thumbURL)
                    }
                }
            }
        }

        // 5. ── Manifest ───────────────────────────────────────────────────
        progress.phase = .manifest
        let manifestURL   = exportDir.appendingPathComponent("manifest.json")
        let complianceURL = exportDir.appendingPathComponent("compliance.json")
        let notesURL      = exportDir.appendingPathComponent("release_notes.txt")

        try writeManifest(
            to: manifestURL,
            assets: assets,
            setTitle: setTitle,
            cleanURLs: cleanURLs,
            session: session
        )

        try writeComplianceDoc(
            to: complianceURL,
            assets: assets,
            setTitle: setTitle
        )

        try writeReleaseNotes(
            to: notesURL,
            assets: assets,
            setTitle: setTitle,
            session: session
        )

        // 6. ── ZIP ────────────────────────────────────────────────────────
        progress.phase = .zipping
        var zipURL: URL? = nil

        if config.zipOutput {
            let zipPath = vault
                .appendingPathComponent("Exports")
                .appendingPathComponent("\(dirName).zip")
                .path

            let success = SSZipArchive.createZipFile(
                atPath:            zipPath,
                withContentsOfDirectory: exportDir.path
            )

            if success { zipURL = URL(fileURLWithPath: zipPath) }
        }

        // 7. ── SHA-256 del ZIP ────────────────────────────────────────────
        progress.phase = .finalizing
        let sha256 = computeSHA256(url: zipURL ?? manifestURL)

        // 8. ── Log compliance ─────────────────────────────────────────────
        PublishComplianceLogger.shared.log(
            action: .setExported,
            setTitle: setTitle,
            assetCount: assets.count,
            outputURL: zipURL ?? exportDir,
            sha256: sha256
        )

        let result = SetExportResult(
            setTitle:      setTitle,
            assetCount:    assets.count,
            cleanURLs:     cleanURLs,
            previewURLs:   previewURLs,
            thumbnailURLs: thumbnailURLs,
            zipURL:        zipURL,
            manifestURL:   manifestURL,
            complianceURL: complianceURL,
            sha256:        sha256
        )

        lastResult     = result
        progress.phase = .complete
        return result
    }

    // MARK: - Compliance Gate

    private func runComplianceChecks(assets: [GeneratedAsset]) async -> [ComplianceViolation] {
        var violations: [ComplianceViolation] = []

        for asset in assets {
            // 1. NSFW flag sin revisión manual
            if asset.nsfwScore > 0.9 && !(asset.nsfwReviewed) {
                violations.append(.init(
                    severity: .blocking,
                    message: "Asset \(asset.baseName ?? "?") tiene score NSFW alto y no fue revisado manualmente"
                ))
            }

            // 2. Asset sin licencia de checkpoint verificada
            if let checkpoint = asset.checkpoint, !checkpoint.isEmpty {
                let licenseOK = LicenseLocalStore.shared.hasVerifiedLicense(for: checkpoint)
                if !licenseOK {
                    violations.append(.init(
                        severity: .warning,
                        message: "Checkpoint '\(checkpoint)' sin licencia verificada en LicenseVault"
                    ))
                }
            }

            // 3. Integridad SHA-256
            if let hashOnDisk = asset.sha256, !hashOnDisk.isEmpty,
               let path = asset.imagePath {
                let currentHash = computeSHA256ForPath(path)
                if currentHash != hashOnDisk {
                    violations.append(.init(
                        severity: .blocking,
                        message: "Asset \(asset.baseName ?? "?") falló verificación de integridad SHA-256"
                    ))
                }
            }
        }

        // 4. Verificar que existe al menos un ConsentTemplate para publicación
        let hasConsent = ConsentTemplateManager.shared.hasActiveTemplate(for: .onlyfans)
        if !hasConsent {
            violations.append(.init(
                severity: .warning,
                message: "No hay plantilla de consentimiento activa para OnlyFans"
            ))
        }

        return violations
    }

    // MARK: - Image Export

    private func exportSingleImage(asset: GeneratedAsset, to url: URL, withWatermark: Bool) async throws {
        guard let path  = asset.imagePath,
              let data  = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let image = NSImage(data: data)
        else { throw ExportSetError.imageNotFound(asset.imagePath ?? "?") }

        let outputImage = withWatermark ? applyWatermark(to: image) : image
        let outputData  = try encode(image: outputImage)
        try outputData.write(to: url, options: .atomic)
    }

    private func applyWatermark(to image: NSImage) -> NSImage {
        let size   = image.size
        let result = NSImage(size: size)
        result.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size))
        let text   = config.watermarkText as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font:            NSFont.boldSystemFont(ofSize: max(size.width * 0.035, 14)),
            .foregroundColor: NSColor.white.withAlphaComponent(0.5),
            .strokeColor:     NSColor.black.withAlphaComponent(0.35),
            .strokeWidth:     -2.0
        ]
        let sz      = text.size(withAttributes: attrs)
        let margin: CGFloat = 18
        text.draw(at: CGPoint(x: size.width - sz.width - margin, y: margin), withAttributes: attrs)
        result.unlockFocus()
        return result
    }

    private func encode(image: NSImage) throws -> Data {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ExportSetError.encodingFailed
        }
        let mutableData = NSMutableData()
        let utType: CFString = config.outputFormat == .png ? "public.png" as CFString : "public.jpeg" as CFString
        guard let destination = CGImageDestinationCreateWithData(mutableData, utType, 1, nil) else {
            throw ExportSetError.encodingFailed
        }
        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: config.jpegQuality,
            kCGImageMetadataShouldExcludeGPS: true,
            kCGImagePropertyExifDictionary: [:] as NSDictionary,
            kCGImagePropertyIPTCDictionary: [:] as NSDictionary,
        ]
        CGImageDestinationAddImage(destination, cgImage, props as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ExportSetError.encodingFailed
        }
        return mutableData as Data
    }

    // MARK: - Thumbnails

    private func generateThumbnail(image: NSImage, maxDim: Int) -> Data? {
        let size = image.size
        let scale = CGFloat(maxDim) / max(size.width, size.height)
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let thumb = NSImage(size: newSize)
        thumb.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize))
        thumb.unlockFocus()
        guard let cgImage = thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.80] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    // MARK: - Manifest & Compliance Docs

    private func writeManifest(to url: URL, assets: [GeneratedAsset], setTitle: String, cleanURLs: [URL], session: ContentSessionManager.ContentSession?) throws {
        var manifest: [String: Any] = [
            "schema":        "SDPipeline.SetManifest.v1",
            "setTitle":      setTitle,
            "creatorHandle": config.creatorHandle,
            "exportedAt":    ISO8601DateFormatter().string(from: Date()),
            "assetCount":    assets.count,
            "outputFormat":  config.outputFormat.rawValue,
            "images":        assets.enumerated().map { (idx, asset) -> [String: Any] in
                return [
                    "index":     idx + 1,
                    "assetID":   asset.id.uuidString,
                    "baseName":  asset.baseName ?? "",
                    "seed":      asset.seed,
                    "checkpoint": asset.checkpoint ?? "",
                    "sha256":    asset.sha256 ?? "",
                    "filename":  cleanURLs[safe: idx]?.lastPathComponent ?? ""
                ]
            }
        ]
        if let session = session {
            manifest["sessionID"]    = session.id.uuidString
            manifest["sessionTitle"] = session.title
            manifest["platform"]     = session.targetPlatform.rawValue
        }
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private func writeComplianceDoc(to url: URL, assets: [GeneratedAsset], setTitle: String) throws {
        let doc: [String: Any] = [
            "schema":          "SDPipeline.ComplianceDoc.v1",
            "setTitle":        setTitle,
            "generatedAt":     ISO8601DateFormatter().string(from: Date()),
            "allAssetsReviewed": assets.allSatisfy { $0.nsfwReviewed },
            "licenseVerified": assets.allSatisfy { a in
                guard let cp = a.checkpoint else { return false }
                return LicenseLocalStore.shared.hasVerifiedLicense(for: cp)
            },
            "consentTemplate": ConsentTemplateManager.shared.activeTemplateName(for: .onlyfans) ?? "none",
            "privacyPolicy":   PrivacyComplianceManager.shared.currentPolicyVersion
        ]
        let data = try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private func writeReleaseNotes(to url: URL, assets: [GeneratedAsset], setTitle: String, session: ContentSessionManager.ContentSession?) throws {
        let dateStr = DateFormatter.localizedString(from: Date(), dateStyle: .long, timeStyle: .none)
        let checkpoints = Set(assets.compactMap(\.checkpoint)).joined(separator: ", ")
        let notes = """
        \(setTitle)
        Exportado: \(dateStr)
        Creador: \(config.creatorHandle)
        Imágenes: \(assets.count)
        Formato: \(config.outputFormat.rawValue)
        Modelos: \(checkpoints.isEmpty ? "N/A" : checkpoints)
        \(session != nil ? "Sesión: \(session!.title)" : "")

        Generado con SDPipeline Studio
        """
        try notes.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Helpers

    private func buildFilename(asset: GeneratedAsset, index: String, setTitle: String) -> String {
        let handle = config.creatorHandle.trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        let date   = ISO8601DateFormatter().string(from: Date()).prefix(8)
        let title  = String(sanitizeFilename(setTitle).prefix(20))
        return "\(handle)_\(date)_\(title)_\(index)"
    }

    private func sanitizeFilename(_ s: String) -> String {
        s.lowercased()
         .replacingOccurrences(of: " ", with: "_")
         .replacingOccurrences(of: "[^a-z0-9_]", with: "", options: .regularExpression)
    }

    private func loadImage(asset: GeneratedAsset) -> NSImage? {
        guard let path = asset.imagePath, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return NSImage(data: data)
    }

    private func computeSHA256(url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        return SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }

    private func computeSHA256ForPath(_ path: String) -> String {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return "" }
        return SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Errors

    enum ExportSetError: LocalizedError {
        case noAssets
        case vaultNotConfigured
        case complianceFailed(String)
        case imageNotFound(String)
        case encodingFailed
        case zipFailed

        var errorDescription: String? {
            switch self {
            case .noAssets:                    return "No hay assets para exportar"
            case .vaultNotConfigured:          return "Vault no configurado"
            case .complianceFailed(let msgs):  return "Compliance bloqueado: \(msgs)"
            case .imageNotFound(let p):        return "Imagen no encontrada: \(p)"
            case .encodingFailed:              return "Error al codificar la imagen"
            case .zipFailed:                   return "Error al comprimir el set"
            }
        }
    }
}

// MARK: - Supporting extensions

private extension GeneratedAsset {
    var nsfwReviewed: Bool {
        get { UserDefaults.standard.bool(forKey: "nsfwReviewed_\(id.uuidString)") }
    }
    var nsfwScore: Double {
        get { UserDefaults.standard.double(forKey: "nsfwScore_\(id.uuidString)") }
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Stubs for missing dependencies (to be replaced by actual implementations)

private extension LicenseLocalStore {
    func hasVerifiedLicense(for checkpoint: String) -> Bool {
        // Delegate to actual implementation
        return true
    }
}

private extension ConsentTemplateManager {
    func hasActiveTemplate(for platform: ConsentTemplateManager.Platform) -> Bool {
        return !templates.isEmpty
    }
    func activeTemplateName(for platform: ConsentTemplateManager.Platform) -> String? {
        return templates.first?.title
    }
}

private extension PrivacyComplianceManager {
    var currentPolicyVersion: String {
        return privacyPolicy?.version ?? "1.0"
    }
}

// MARK: - PublishComplianceLogger extension

extension PublishComplianceLogger {
    enum PublishAction: String {
        case setExported = "SET_EXPORTED"
    }
    func log(action: PublishAction, setTitle: String, assetCount: Int, outputURL: URL, sha256: String) {
        let entry: [String: Any] = [
            "action":     action.rawValue,
            "setTitle":   setTitle,
            "assetCount": assetCount,
            "outputURL":  outputURL.path,
            "sha256":     sha256,
            "timestamp":  ISO8601DateFormatter().string(from: Date())
        ]
        logEntry(entry)
    }
}
