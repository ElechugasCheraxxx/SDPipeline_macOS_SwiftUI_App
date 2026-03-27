import Foundation
import AppKit
import Combine

// MARK: - DAMBridge
//
// Puente de integración con Digital Asset Managers externos.
// Soporta: Eagle, DigiKam, Lightroom Classic, Capture One, Mylio.

@MainActor
final class DAMBridge: ObservableObject {

    static let shared = DAMBridge()
    private init() {
        loadConfig()
        setupWatchFolderIfEnabled()
    }

    // MARK: - Config

    struct DAMConfig: Codable {
        var activeDAM:         DAMType         = .eagle
        var eagleLibraryPath:  String         = ""
        var digiKamDBPath:     String         = ""
        var lightroomCatalog:  String         = ""
        var captureOneCatalog: String         = ""
        var watchFolderPath:   String         = ""
        var autoExportOnApproval: Bool        = false
        var autoExportOnPublish:  Bool        = true
        var syncRatings:          Bool        = true
        var syncTags:             Bool        = true
        var createSmartAlbums:    Bool        = true
        var albumNameFormat:      String      = "{character}_{date}"
        var exportFormat:         ExportFormat = .png
        var overwriteExisting:    Bool        = false

        enum DAMType: String, CaseIterable, Codable {
            case eagle        = "Eagle"
            case digiKam      = "DigiKam"
            case lightroom    = "Lightroom Classic"
            case captureOne   = "Capture One"
            case mylio        = "Mylio"
            case watchFolder  = "Carpeta de Vigilancia"

            var icon: String {
                switch self {
                case .eagle:       return "eagle"
                case .digiKam:     return "photo.stack.fill"
                case .lightroom:   return "camera.aperture"
                case .captureOne:  return "camera.filters"
                case .mylio:       return "photo.on.rectangle.angled"
                case .watchFolder: return "folder.badge.gearshape"
                }
            }

            var sfIcon: String {
                switch self {
                case .eagle:       return "tray.and.arrow.down.fill"
                case .digiKam:     return "photo.stack.fill"
                case .lightroom:   return "camera.aperture"
                case .captureOne:  return "camera.filters"
                case .mylio:       return "photo.on.rectangle.angled"
                case .watchFolder: return "folder.badge.gearshape"
                }
            }

            var isAPIBased: Bool {
                return self == .eagle
            }

            var supportsRatingSync: Bool {
                switch self {
                case .eagle, .lightroom, .captureOne: return true
                default: return false
                }
            }
        }

        enum ExportFormat: String, CaseIterable, Codable {
            case png    = "PNG"
            case jpeg   = "JPEG"
            case tiff   = "TIFF"
            case webp   = "WebP"
        }
    }

    @Published var config = DAMConfig()
    @Published var isExporting     = false
    @Published var syncLog:  [String] = []
    @Published var exportQueue: [ExportJob] = []
    @Published var pendingCount: Int = 0

    // MARK: - Export Job

    struct ExportJob: Identifiable {
        let id            = UUID()
        let asset:      GeneratedAsset
        let targetDAM:  DAMConfig.DAMType
        var status:     JobStatus = .pending
        var targetPath: URL?
        var errorMsg:   String?
        var exportedAt: Date?

        enum JobStatus: String {
            case pending  = "Pendiente"
            case running  = "Exportando"
            case done     = "Completado"
            case failed   = "Fallido"
            case skipped  = "Omitido"
        }
    }

    // MARK: - Export to Active DAM

    func export(asset: GeneratedAsset, to dam: DAMConfig.DAMType? = nil) async throws {
        let targetDAM = dam ?? config.activeDAM

        var job = ExportJob(asset: asset, targetDAM: targetDAM)
        exportQueue.append(job)
        let jobIdx = exportQueue.count - 1

        exportQueue[jobIdx].status = .running

        do {
            let url: URL
            switch targetDAM {
            case .eagle:
                url = try await exportToEagle(asset: asset)
            case .digiKam:
                url = try await exportToDigiKam(asset: asset)
            case .watchFolder:
                url = try await exportToWatchFolder(asset: asset)
            case .lightroom:
                url = try await exportToLightroom(asset: asset)
            case .captureOne:
                url = try await exportToWatchFolder(asset: asset, prefix: "captureone")
            case .mylio:
                url = try await exportToWatchFolder(asset: asset, prefix: "mylio")
            }

            exportQueue[jobIdx].targetPath = url
            exportQueue[jobIdx].status     = .done
            exportQueue[jobIdx].exportedAt = Date()

            log("✅ \(targetDAM.rawValue): \(asset.baseName ?? "asset") exportado → \(url.lastPathComponent)")

            ZeroKnowledgeLog.shared.write(
                category: .exportPerformed,
                message: "DAMBridge export: \(targetDAM.rawValue) — \(asset.baseName ?? "asset")"
            )

        } catch {
            exportQueue[jobIdx].status   = .failed
            exportQueue[jobIdx].errorMsg = error.localizedDescription
            log("❌ \(targetDAM.rawValue): \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Eagle Integration

    private func exportToEagle(asset: GeneratedAsset) async throws -> URL {
        let eagleAPIBase = "http://localhost:41595/api"

        guard let pingURL = URL(string: "\(eagleAPIBase)/application/info") else {
            throw DAMError.damNotRunning("Eagle")
        }

        let (_, pingResp) = try await URLSession.shared.data(from: pingURL)
        guard (pingResp as? HTTPURLResponse)?.statusCode == 200 else {
            throw DAMError.damNotRunning("Eagle")
        }

        guard let imagePath = asset.cleanPath ?? asset.imagePath,
              let imageURL   = URL(string: "file://\(imagePath)")
        else { throw DAMError.assetNotFound }

        let tags    = TaggingEngine.shared.tags(for: asset)
        let rating  = Int(asset.rating)
        let name    = asset.baseName ?? "SD_Asset"
        let website = "SDPipelineStudio"
        let annotation = asset.promptPositive ?? ""

        let body: [String: Any] = [
            "items": [[
                "url":         imageURL.absoluteString,
                "name":        name,
                "website":     website,
                "tags":        tags,
                "star":        rating,
                "annotation":  annotation.prefix(500).description
            ]]
        ]

        guard let addURL = URL(string: "\(eagleAPIBase)/item/addFromURLs") else {
            throw DAMError.invalidConfig
        }

        var req = URLRequest(url: addURL)
        req.httpMethod  = "POST"
        req.httpBody    = try JSONSerialization.data(withJSONObject: body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, _) = try await URLSession.shared.data(for: req)

        guard let json  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = json["status"] as? String,
              status     == "success"
        else { throw DAMError.exportFailed("Eagle API rechazó el item") }

        if config.createSmartAlbums {
            await createEagleSmartAlbum(for: asset, apiBase: eagleAPIBase)
        }

        return URL(fileURLWithPath: imagePath)
    }

    private func createEagleSmartAlbum(for asset: GeneratedAsset, apiBase: String) async {
        guard let folderURL = URL(string: "\(apiBase)/folder/create") else { return }
        let folderName = formatAlbumName(for: asset)
        let body: [String: Any] = ["folderName": folderName]
        var req = URLRequest(url: folderURL)
        req.httpMethod = "POST"
        req.httpBody   = try? JSONSerialization.data(withJSONObject: body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try? await URLSession.shared.data(for: req)
    }

    // MARK: - DigiKam Integration

    private func exportToDigiKam(asset: GeneratedAsset) async throws -> URL {
        guard !config.digiKamDBPath.isEmpty else {
            throw DAMError.invalidConfig
        }

        let digiKamAlbumsPath = URL(fileURLWithPath: config.digiKamDBPath)
            .deletingLastPathComponent()
            .appendingPathComponent("Albums")
            .appendingPathComponent("SDPipelineStudio")

        try? FileManager.default.createDirectory(at: digiKamAlbumsPath, withIntermediateDirectories: true)

        guard let sourcePath = asset.cleanPath ?? asset.imagePath else {
            throw DAMError.assetNotFound
        }

        let sourceURL = URL(fileURLWithPath: sourcePath)
        let destURL   = digiKamAlbumsPath.appendingPathComponent(sourceURL.lastPathComponent)

        if !config.overwriteExisting && FileManager.default.fileExists(atPath: destURL.path) {
            return destURL
        }

        try FileManager.default.copyItem(at: sourceURL, to: destURL)
        try writeXMPSidecar(for: asset, next: destURL)

        return destURL
    }

    // MARK: - Watch Folder Integration

    private func exportToWatchFolder(asset: GeneratedAsset, prefix: String = "") async throws -> URL {
        var watchPath = config.watchFolderPath
        if watchPath.isEmpty {
            if let vaultRoot = VaultManager.shared.vaultRoot {
                watchPath = vaultRoot.appendingPathComponent("Export/WatchFolder").path
            }
        }

        let watchURL = URL(fileURLWithPath: watchPath)
        try? FileManager.default.createDirectory(at: watchURL, withIntermediateDirectories: true)

        guard let sourcePath = asset.cleanPath ?? asset.imagePath else {
            throw DAMError.assetNotFound
        }

        let sourceURL  = URL(fileURLWithPath: sourcePath)
        let baseName   = prefix.isEmpty ? sourceURL.lastPathComponent : "\(prefix)_\(sourceURL.lastPathComponent)"
        let destURL    = watchURL.appendingPathComponent(baseName)

        try? FileManager.default.removeItem(at: destURL)
        try FileManager.default.copyItem(at: sourceURL, to: destURL)
        try writeXMPSidecar(for: asset, next: destURL)

        return destURL
    }

    // MARK: - Lightroom Integration

    private func exportToLightroom(asset: GeneratedAsset) async throws -> URL {
        guard !config.lightroomCatalog.isEmpty else {
            throw DAMError.invalidConfig
        }

        let autoImportFolder = URL(fileURLWithPath: config.lightroomCatalog)
            .deletingLastPathComponent()
            .appendingPathComponent("Auto Import")
            .appendingPathComponent("SDPipelineStudio")

        try? FileManager.default.createDirectory(at: autoImportFolder, withIntermediateDirectories: true)

        guard let sourcePath = asset.cleanPath ?? asset.imagePath else {
            throw DAMError.assetNotFound
        }

        let sourceURL = URL(fileURLWithPath: sourcePath)
        let destURL   = autoImportFolder.appendingPathComponent(sourceURL.lastPathComponent)

        try FileManager.default.copyItem(at: sourceURL, to: destURL)
        try writeXMPSidecar(for: asset, next: destURL)

        return destURL
    }

    // MARK: - XMP Sidecar

    private func writeXMPSidecar(for asset: GeneratedAsset, next destURL: URL) throws {
        let xmpURL  = destURL.deletingPathExtension().appendingPathExtension("xmp")
        let tags    = TaggingEngine.shared.tags(for: asset)
        let rating  = Int(asset.rating)
        let title   = asset.baseName ?? "SD Asset"
        let prompt  = asset.promptPositive ?? ""
        let date    = (asset.createdAt ?? Date()).formatted(date: .numeric, time: .omitted)

        let xmpContent = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="SDPipelineStudio">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about=""
                xmlns:dc="http://purl.org/dc/elements/1.1/"
                xmlns:xmp="http://ns.adobe.com/xap/1.0/"
                xmlns:lr="http://ns.adobe.com/lightroom/1.0/"
                xmlns:ai="http://ns.adobe.com/xap/1.0/sType/AIEngine#">
              <dc:title><rdf:Alt><rdf:li xml:lang="x-default">\(title)</rdf:li></rdf:Alt></dc:title>
              <dc:description><rdf:Alt><rdf:li xml:lang="x-default">\(escapeXML(prompt.prefix(1000).description))</rdf:li></rdf:Alt></dc:description>
              <dc:subject>
                <rdf:Bag>
                  \(tags.map { "<rdf:li>\(escapeXML($0))</rdf:li>" }.joined(separator: "\n                  "))
                </rdf:Bag>
              </dc:subject>
              <xmp:Rating>\(rating)</xmp:Rating>
              <xmp:CreateDate>\(date)</xmp:CreateDate>
              <xmp:CreatorTool>SDPipelineStudio</xmp:CreatorTool>
              <lr:hierarchicalSubject>
                <rdf:Bag>
                  <rdf:li>SDPipeline</rdf:li>
                  \(tags.map { "<rdf:li>SDPipeline|\(escapeXML($0))</rdf:li>" }.joined(separator: "\n                  "))
                </rdf:Bag>
              </lr:hierarchicalSubject>
            </rdf:Description>
          </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """

        try xmpContent.write(to: xmpURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Batch Export

    struct BatchExportResult {
        let exported: Int
        let failed:   Int
        let skipped:  Int
        let duration: TimeInterval
    }

    func batchExport(
        assets: [GeneratedAsset],
        to dam: DAMConfig.DAMType? = nil
    ) async -> BatchExportResult {
        var exported = 0
        var failed   = 0
        var skipped  = 0
        let start    = Date()

        for asset in assets {
            do {
                try await export(asset: asset, to: dam)
                exported += 1
            } catch DAMError.assetNotFound {
                skipped += 1
            } catch {
                failed += 1
                log("❌ \(asset.baseName ?? "asset"): \(error.localizedDescription)")
            }
        }

        let result = BatchExportResult(
            exported: exported,
            failed:   failed,
            skipped:  skipped,
            duration: Date().timeIntervalSince(start)
        )

        log("Batch export: ✅ \(exported) exportados, ❌ \(failed) fallidos, ⏭️ \(skipped) omitidos")

        return result
    }

    // MARK: - Auto-Export Hooks

    func onAssetApproved(_ asset: GeneratedAsset) async {
        guard config.autoExportOnApproval else { return }
        try? await export(asset: asset)
    }

    func onAssetPublished(_ asset: GeneratedAsset) async {
        guard config.autoExportOnPublish else { return }
        try? await export(asset: asset)
    }

    // MARK: - Watch Folder Monitor

    private var watchFolderMonitor: DispatchSourceFileSystemObject?

    func setupWatchFolderIfEnabled() {
        guard !config.watchFolderPath.isEmpty else { return }
        setupWatchFolder(at: URL(fileURLWithPath: config.watchFolderPath))
    }

    func setupWatchFolder(at url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        log("📂 Watch folder activo: \(url.path)")
    }

    // MARK: - Album Name Formatting

    private func formatAlbumName(for asset: GeneratedAsset) -> String {
        var name = config.albumNameFormat
        let date = (asset.createdAt ?? Date()).formatted(.dateTime.year().month().day())
        let char = asset.characterName ?? "Personaje"
        name = name.replacingOccurrences(of: "{character}", with: char)
        name = name.replacingOccurrences(of: "{date}", with: date)
        name = name.replacingOccurrences(of: "{model}", with: asset.checkpoint ?? "SD")
        return name
    }

    // MARK: - DAM Detection

    struct DetectedDAMs {
        var eagle:     Bool = false
        var digiKam:   Bool = false
        var lightroom: Bool = false
        var captureOne: Bool = false
        var mylio:     Bool = false
    }

    func detectInstalledDAMs() async -> DetectedDAMs {
        var detected = DetectedDAMs()

        detected.eagle = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.eagleapp.Eagle"
        ) != nil

        detected.digiKam = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "org.kde.digikam"
        ) != nil

        detected.lightroom = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.adobe.Lightroom"
        ) != nil || NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.adobe.LightroomClassicCC7"
        ) != nil

        detected.captureOne = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.phaseone.captureone"
        ) != nil

        detected.mylio = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.mylio.MylioTouch"
        ) != nil

        return detected
    }

    func openDAM() {
        switch config.activeDAM {
        case .eagle:
            NSWorkspace.shared.open(URL(string: "eagle://")!)
        case .lightroom:
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.adobe.LightroomClassicCC7") {
                NSWorkspace.shared.open(url)
            }
        case .watchFolder where !config.watchFolderPath.isEmpty:
            NSWorkspace.shared.open(URL(fileURLWithPath: config.watchFolderPath))
        default:
            break
        }
    }

    // MARK: - Helpers

    private func escapeXML(_ str: String) -> String {
        str.replacingOccurrences(of: "&",  with: "&amp;")
           .replacingOccurrences(of: "<",  with: "&lt;")
           .replacingOccurrences(of: ">",  with: "&gt;")
           .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func log(_ message: String) {
        let ts = Date().formatted(date: .omitted, time: .standard)
        syncLog.append("[\(ts)] \(message)")
        if syncLog.count > 300 { syncLog.removeFirst(50) }
    }

    private func loadConfig() {
        if let data = UserDefaults.standard.data(forKey: "DAMBridgeConfig"),
           let cfg  = try? JSONDecoder().decode(DAMConfig.self, from: data) {
            config = cfg
        }
    }

    func saveConfig() {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: "DAMBridgeConfig")
        }
    }

    // MARK: - Errors

    enum DAMError: LocalizedError {
        case damNotRunning(String)
        case invalidConfig
        case assetNotFound
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .damNotRunning(let dam): return "\(dam) no está corriendo o no responde."
            case .invalidConfig:          return "Configuración de DAM incompleta."
            case .assetNotFound:          return "Asset no encontrado en el vault."
            case .exportFailed(let msg):  return "Export fallido: \(msg)"
            }
        }
    }
}

// MARK: - GeneratedAsset DAM helpers

extension GeneratedAsset {
    var characterName: String? {
        return nil
    }
}
