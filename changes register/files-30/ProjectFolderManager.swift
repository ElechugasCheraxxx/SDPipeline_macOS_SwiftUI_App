import Foundation
import AppKit
import Combine
import CryptoKit

// MARK: - ProjectFolderManager
//
// Gestiona la estructura de carpetas por proyectos dentro del vault.
// Cada proyecto tiene su propio subdirectorio con estructura completa:
//
//   VaultRoot/
//   └── Proyectos/
//       └── {ProjectName}_{UUID}/
//           ├── Generaciones/
//           │   └── YYYY-MM-DD/
//           ├── MasterPicks/
//           ├── Export/
//           │   └── Previews/
//           ├── Personajes/
//           ├── Escenas/
//           ├── Referencias/
//           ├── PrivateLoRAs/
//           └── Vault/
//               ├── Licencias/
//               ├── Sidecar/
//               └── Versions/
//
// ROADMAP: Sistema de carpetas por proyectos (🔴 INMEDIATO)

@MainActor
final class ProjectFolderManager: ObservableObject {

    static let shared = ProjectFolderManager()
    private init() {}

    // MARK: - Project Structure

    struct ProjectFolder: Identifiable, Codable {
        let id:       UUID
        var name:     String
        var color:    String          // hex color para UI
        var rootURL:  URL             // path absoluto del proyecto
        var isActive: Bool
        var createdAt: Date
        var updatedAt: Date

        // Subdirectorios calculados
        var generacionesURL: URL { rootURL.appending(path: "Generaciones") }
        var masterPicksURL:  URL { rootURL.appending(path: "MasterPicks") }
        var exportURL:       URL { rootURL.appending(path: "Export") }
        var previewsURL:     URL { rootURL.appending(path: "Export/Previews") }
        var personajesURL:   URL { rootURL.appending(path: "Personajes") }
        var escenasURL:      URL { rootURL.appending(path: "Escenas") }
        var referenciasURL:  URL { rootURL.appending(path: "Referencias") }
        var privateLoRAsURL: URL { rootURL.appending(path: "PrivateLoRAs") }
        var vaultMetaURL:    URL { rootURL.appending(path: "Vault") }
        var licenciasURL:    URL { rootURL.appending(path: "Vault/Licencias") }
        var sidecarURL:      URL { rootURL.appending(path: "Vault/Sidecar") }
        var versionsURL:     URL { rootURL.appending(path: "Vault/Versions") }

        func todayGeneracionesURL() -> URL {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            return generacionesURL.appending(path: fmt.string(from: Date()))
        }

        var folderName: String { "\(name)_\(id.uuidString.prefix(8))" }
    }

    // MARK: - State

    @Published var projects:       [ProjectFolder] = []
    @Published var activeProject:  ProjectFolder?
    @Published var isCreating:     Bool = false
    @Published var lastError:      String? = nil

    // MARK: - Load / Persist

    private var indexURL: URL? {
        VaultManager.shared.vaultMetaURL?.appending(path: "projects_index.json")
    }

    func loadProjects() {
        guard let url = indexURL,
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([ProjectFolder].self, from: data)
        else { return }
        projects = list
        activeProject = list.first(where: { $0.isActive }) ?? list.first
    }

    func saveProjectsIndex() {
        guard let url = indexURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(projects) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Create Project

    @discardableResult
    func createProject(name: String, color: String = "#7c6af7") throws -> ProjectFolder {
        guard let vaultRoot = VaultManager.shared.vaultRoot else {
            throw ProjectError.vaultNotConfigured
        }

        let projectsRoot = vaultRoot.appending(path: "Proyectos")
        let id = UUID()
        let folderName = "\(sanitize(name))_\(id.uuidString.prefix(8))"
        let rootURL = projectsRoot.appending(path: folderName)

        var folder = ProjectFolder(
            id:        id,
            name:      name,
            color:     color,
            rootURL:   rootURL,
            isActive:  projects.isEmpty,
            createdAt: Date(),
            updatedAt: Date()
        )

        try createDirectoryStructure(for: folder)

        // Crear README del proyecto
        let readme = """
        # Proyecto: \(name)
        Creado: \(Date().formatted(date: .complete, time: .standard))
        ID: \(id.uuidString)

        ## Estructura
        - Generaciones/   — Imágenes raw de Stable Diffusion (inmutables)
        - MasterPicks/    — Imágenes aprobadas tras curaduría
        - Export/         — Versiones limpias para publicar
        - Personajes/     — Perfiles JSON de personajes
        - Escenas/        — Presets de escenas guardadas
        - Referencias/    — Imágenes de referencia para img2img/ControlNet
        - PrivateLoRAs/   — LoRAs privados del proyecto
        - Vault/          — Metadatos, licencias, sidecars (NO compartir)
        """
        try readme.write(to: rootURL.appending(path: "README.md"), atomically: true, encoding: .utf8)

        if projects.isEmpty { folder.isActive = true }
        projects.append(folder)
        saveProjectsIndex()
        return folder
    }

    // MARK: - Switch Active Project

    func setActive(_ project: ProjectFolder) {
        for i in projects.indices { projects[i].isActive = false }
        if let idx = projects.firstIndex(where: { $0.id == project.id }) {
            projects[idx].isActive = true
            activeProject = projects[idx]
        }
        saveProjectsIndex()
    }

    // MARK: - Delete Project (soft delete — no borra el directorio)

    func archiveProject(_ project: ProjectFolder) {
        projects.removeAll { $0.id == project.id }
        if activeProject?.id == project.id {
            activeProject = projects.first
            if let first = activeProject {
                setActive(first)
            }
        }
        saveProjectsIndex()
    }

    // MARK: - Resolve URLs for Active Project

    func todayGeneracionesURL() -> URL? {
        activeProject?.todayGeneracionesURL()
            ?? VaultManager.shared.todayGeneracionesURL
    }

    func masterPicksURL() -> URL? {
        activeProject?.masterPicksURL
            ?? VaultManager.shared.masterPicksURL
    }

    func exportURL() -> URL? {
        activeProject?.exportURL
            ?? VaultManager.shared.exportURL
    }

    func previewsURL() -> URL? {
        activeProject?.previewsURL
            ?? VaultManager.shared.previewsURL
    }

    func vaultMetaURL() -> URL? {
        activeProject?.vaultMetaURL
            ?? VaultManager.shared.vaultMetaURL
    }

    // MARK: - Directory Creation

    private func createDirectoryStructure(for folder: ProjectFolder) throws {
        let fm = FileManager.default
        let dirs: [URL] = [
            folder.rootURL,
            folder.generacionesURL,
            folder.masterPicksURL,
            folder.exportURL,
            folder.previewsURL,
            folder.personajesURL,
            folder.escenasURL,
            folder.referenciasURL,
            folder.privateLoRAsURL,
            folder.vaultMetaURL,
            folder.licenciasURL,
            folder.sidecarURL,
            folder.versionsURL,
        ]
        for dir in dirs {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // .nomedia en PrivateLoRAs para evitar indexado por Spotlight
        let nomedia = folder.privateLoRAsURL.appending(path: ".nomedia")
        if !fm.fileExists(atPath: nomedia.path) {
            try "".write(to: nomedia, atomically: true, encoding: .utf8)
        }

        // .gitignore en la raíz del proyecto
        let gitignore = """
        # Stable Diffusion Pipeline Studio
        PrivateLoRAs/
        Vault/
        *.enc
        *.safetensors
        *.ckpt
        """
        try gitignore.write(to: folder.rootURL.appending(path: ".gitignore"), atomically: true, encoding: .utf8)
    }

    // MARK: - Stats

    var totalAssets: Int {
        let fm = FileManager.default
        return projects.reduce(0) { total, project in
            let genURL = project.generacionesURL
            let count  = (try? fm.contentsOfDirectory(at: genURL, includingPropertiesForKeys: nil))?.count ?? 0
            return total + count
        }
    }

    func diskUsage(for project: ProjectFolder) -> Int64 {
        folderSize(project.rootURL)
    }

    private func folderSize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            total += (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
        }
        return total
    }

    // MARK: - Helpers

    private func sanitize(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "-_ "))
        return name.unicodeScalars
            .filter { allowed.contains($0) }
            .map { String($0) }
            .joined()
            .replacingOccurrences(of: " ", with: "_")
            .prefix(32)
            .description
    }

    // MARK: - Errors

    enum ProjectError: LocalizedError {
        case vaultNotConfigured
        case directoryCreationFailed(String)
        case projectNotFound(UUID)

        var errorDescription: String? {
            switch self {
            case .vaultNotConfigured: return "Vault no configurado. Ejecuta el setup primero."
            case .directoryCreationFailed(let p): return "No se pudo crear directorio: \(p)"
            case .projectNotFound(let id): return "Proyecto no encontrado: \(id)"
            }
        }
    }
}

// MARK: - VaultManager extension for project-aware URLs

extension VaultManager {
    /// URL del día actual dentro del proyecto activo, o Generaciones/ global.
    var todayProjectURL: URL? {
        ProjectFolderManager.shared.todayGeneracionesURL()
    }
}
