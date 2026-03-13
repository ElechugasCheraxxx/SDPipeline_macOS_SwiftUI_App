import Foundation
import AppKit
import SwiftUI
import Combine

// MARK: - ExternalEditorBridge
//
// Puente de integración con editores externos profesionales:
//   • Affinity Photo 2
//   • Adobe Photoshop
//   • GIMP
//   • Pixelmator Pro
//
// Workflow:
//   1. Detectar editores instalados en /Applications
//   2. Exportar asset temporal a disco (no expone el vault directo)
//   3. Abrir en editor elegido con NSWorkspace
//   4. Monitorear cambios con FSEvents
//   5. Re-importar versión editada al vault como nueva versión del asset
//   6. Registrar en AssetVersioningStore con tag .custom
//
// ROADMAP: "Integración con editores externos (Affinity, Photoshop, GIMP)" (🟡 MEDIO PLAZO)

@MainActor
final class ExternalEditorBridge: ObservableObject {

    static let shared = ExternalEditorBridge()
    private init() { detectInstalledEditors() }

    // MARK: - Supported Editors

    enum ExternalEditor: String, CaseIterable, Codable {
        case affinityPhoto   = "Affinity Photo 2"
        case affinityPhoto1  = "Affinity Photo"
        case photoshop       = "Adobe Photoshop"
        case gimp            = "GIMP"
        case pixelmator      = "Pixelmator Pro"
        case preview         = "Preview"    // fallback siempre disponible

        var bundleIDs: [String] {
            switch self {
            case .affinityPhoto:  return ["com.seriflabs.affinityphoto2"]
            case .affinityPhoto1: return ["com.seriflabs.affinityphoto"]
            case .photoshop:      return ["com.adobe.Photoshop"]
            case .gimp:           return ["org.gimp.gimp"]
            case .pixelmator:     return ["com.pixelmatorteam.pixelmator.x"]
            case .preview:        return ["com.apple.Preview"]
            }
        }

        var icon: String {
            switch self {
            case .affinityPhoto, .affinityPhoto1: return "paintbrush.pointed.fill"
            case .photoshop:                      return "photo.stack.fill"
            case .gimp:                           return "scissors"
            case .pixelmator:                     return "wand.and.sparkles"
            case .preview:                        return "eye.fill"
            }
        }

        var preferredFormats: [String] {
            switch self {
            case .affinityPhoto, .affinityPhoto1: return ["png", "tiff"]
            case .photoshop:                      return ["png", "tiff", "psd"]
            case .gimp:                           return ["png", "tiff", "xcf"]
            case .pixelmator:                     return ["png", "tiff"]
            case .preview:                        return ["png", "jpg"]
            }
        }
    }

    // MARK: - State

    @Published var installedEditors:   [ExternalEditor] = []
    @Published var preferredEditor:    ExternalEditor   = .preview
    @Published var isWaiting:          Bool             = false
    @Published var waitingAsset:       GeneratedAsset?  = nil
    @Published var waitingTempURL:     URL?             = nil
    @Published var lastImportedImage:  NSImage?         = nil
    @Published var lastError:          String?          = nil

    private var fsEventStream: FSEventStreamRef?
    private var importCallback: ((NSImage) -> Void)?

    // MARK: - Detection

    func detectInstalledEditors() {
        installedEditors = [.preview]   // preview siempre disponible
        let workspace = NSWorkspace.shared

        for editor in ExternalEditor.allCases where editor != .preview {
            for bundleID in editor.bundleIDs {
                if workspace.urlForApplication(withBundleIdentifier: bundleID) != nil {
                    installedEditors.append(editor)
                    break
                }
            }
        }

        // Restaurar preferencia guardada
        if let saved = UserDefaults.standard.string(forKey: "externalEditor.preferred"),
           let editor = ExternalEditor(rawValue: saved),
           installedEditors.contains(editor) {
            preferredEditor = editor
        } else {
            // Elegir el mejor disponible
            let priority: [ExternalEditor] = [.affinityPhoto, .photoshop, .pixelmator, .affinityPhoto1, .gimp, .preview]
            preferredEditor = priority.first { installedEditors.contains($0) } ?? .preview
        }
    }

    func setPreferredEditor(_ editor: ExternalEditor) {
        preferredEditor = editor
        UserDefaults.standard.set(editor.rawValue, forKey: "externalEditor.preferred")
    }

    // MARK: - Open in Editor

    /// Abre un asset en el editor externo y monitorea cambios.
    func openInEditor(_ asset: GeneratedAsset,
                      editor: ExternalEditor? = nil,
                      onImport: @escaping (NSImage) -> Void) async throws {

        let targetEditor = editor ?? preferredEditor

        // 1. Preparar archivo temporal (no exponer vault directo)
        guard let imagePath = asset.imagePath,
              let data = try? Data(contentsOf: URL(fileURLWithPath: imagePath))
        else { throw BridgeError.assetNotFound }

        let ext      = targetEditor.preferredFormats.first ?? "png"
        let tmpName  = "edit_\(asset.id?.uuidString.prefix(8) ?? "tmp").\(ext)"
        let tmpURL   = FileManager.default.temporaryDirectory.appending(path: tmpName)
        try data.write(to: tmpURL, options: .atomic)

        waitingAsset   = asset
        waitingTempURL = tmpURL
        importCallback = onImport
        isWaiting      = true

        // 2. Abrir en editor
        let opened = try await openFile(tmpURL, in: targetEditor)
        guard opened else { throw BridgeError.editorNotFound(targetEditor.rawValue) }

        // 3. Monitorear cambios con FSEvents
        startMonitoring(tmpURL)

        ZeroKnowledgeLog.shared.write(
            category: .systemEvent,
            message: "ExternalEditor: \(asset.displayTitle) abierto en \(targetEditor.rawValue)"
        )
    }

    private func openFile(_ url: URL, in editor: ExternalEditor) async throws -> Bool {
        let workspace = NSWorkspace.shared

        if editor == .preview {
            return workspace.open(url)
        }

        for bundleID in editor.bundleIDs {
            if let appURL = workspace.urlForApplication(withBundleIdentifier: bundleID) {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                return await withCheckedContinuation { continuation in
                    workspace.open([url], withApplicationAt: appURL, configuration: config) { _, error in
                        continuation.resume(returning: error == nil)
                    }
                }
            }
        }
        return false
    }

    // MARK: - FSEvents Monitoring

    private func startMonitoring(_ url: URL) {
        stopMonitoring()
        let dir = url.deletingLastPathComponent().path as CFString
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passRetained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        fsEventStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, _, _, _, _ in
                guard let info else { return }
                let bridge = Unmanaged<ExternalEditorBridge>.fromOpaque(info).takeUnretainedValue()
                Task { @MainActor in bridge.handleFileChanged() }
            },
            &ctx,
            [dir] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.5,  // 1.5 segundos de latencia
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
        )
        if let stream = fsEventStream {
            FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            FSEventStreamStart(stream)
        }
    }

    private func stopMonitoring() {
        if let stream = fsEventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            fsEventStream = nil
        }
    }

    private func handleFileChanged() {
        guard let tmpURL = waitingTempURL,
              let image  = NSImage(contentsOf: tmpURL),
              let cb     = importCallback
        else { return }
        lastImportedImage = image
        cb(image)
    }

    // MARK: - Import Back to Vault

    /// Importar la imagen editada como nueva versión del asset.
    func importEditedVersion(for asset: GeneratedAsset) async throws {
        guard let tmpURL = waitingTempURL,
              let data   = try? Data(contentsOf: tmpURL),
              let image  = NSImage(data: data)
        else { throw BridgeError.importFailed }

        stopMonitoring()

        // Guardar como nueva versión en AssetVersioningStore
        try await AssetVersioningStore.shared.addVersion(
            for: asset,
            image: image,
            tag: .custom,
            label: "Editado en \(preferredEditor.rawValue)"
        )

        // Limpiar temporal
        try? FileManager.default.removeItem(at: tmpURL)
        waitingTempURL = nil
        waitingAsset   = nil
        importCallback = nil
        isWaiting      = false

        ZeroKnowledgeLog.shared.write(
            category: .systemEvent,
            message: "ExternalEditor: versión importada para \(asset.displayTitle)"
        )
    }

    /// Cancelar edición externa.
    func cancelEditing() {
        stopMonitoring()
        if let tmpURL = waitingTempURL {
            try? FileManager.default.removeItem(at: tmpURL)
        }
        waitingTempURL = nil
        waitingAsset   = nil
        importCallback = nil
        isWaiting      = false
    }

    // MARK: - Errors

    enum BridgeError: LocalizedError {
        case assetNotFound
        case editorNotFound(String)
        case importFailed

        var errorDescription: String? {
            switch self {
            case .assetNotFound:           return "Asset no encontrado en disco."
            case .editorNotFound(let e):   return "Editor no encontrado: \(e)"
            case .importFailed:            return "No se pudo importar la imagen editada."
            }
        }
    }
}

// MARK: - AssetVersioningStore extension for external editor

extension AssetVersioningStore {
    func addVersion(for asset: GeneratedAsset, image: NSImage, tag: VersionTag, label: String) async throws {
        guard let assetID = asset.id else { return }
        let _ = try await addVersion(
            assetID: assetID,
            sourceImage: image,
            tag: tag,
            notes: label
        )
    }
}

// MARK: - External Editor Panel View

struct ExternalEditorPanel: View {

    @StateObject private var bridge = ExternalEditorBridge.shared
    var asset: GeneratedAsset?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "arrow.up.forward.app.fill")
                    .font(.system(size: 12)).foregroundColor(Color(hex: "#60a5fa"))
                Text("Editar externamente")
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
            }

            if bridge.isWaiting {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text("Esperando cambios en \(bridge.preferredEditor.rawValue)…")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                    Spacer()
                    Button("Importar") {
                        if let a = bridge.waitingAsset {
                            Task { try? await bridge.importEditedVersion(for: a) }
                        }
                    }
                    .buttonStyle(.borderedProminent).controlSize(.mini)
                    Button("Cancelar") { bridge.cancelEditing() }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundColor(.secondary)
                }
            } else {
                // Editor picker
                HStack(spacing: 6) {
                    Text("Editor").font(.system(size: 10)).foregroundColor(.secondary)
                    Picker("", selection: $bridge.preferredEditor) {
                        ForEach(bridge.installedEditors, id: \.self) { editor in
                            Label(editor.rawValue, systemImage: editor.icon).tag(editor)
                        }
                    }
                    .pickerStyle(.menu).font(.system(size: 11))
                    Spacer()
                    Button("Abrir en \(bridge.preferredEditor.rawValue)") {
                        if let a = asset {
                            Task { try? await bridge.openInEditor(a, onImport: { _ in }) }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                    .disabled(asset == nil)
                }

                if bridge.installedEditors.count <= 1 {
                    Text("Instala Affinity Photo, Photoshop o GIMP para habilitar.")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.04))
        .cornerRadius(8)
    }
}
