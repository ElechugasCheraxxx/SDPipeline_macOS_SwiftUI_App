import Foundation
import AppKit
import SwiftUI
import Combine

// MARK: - ProjectManager
//
// Sistema de proyectos múltiples con vault aislado por proyecto.
// Cada proyecto tiene su propio subdirectorio dentro del vault root,
// su propio Core Data store y su propia configuración de checkpoint/LoRAs.
//
// Arquitectura:
//   VaultRoot/
//   ├── .projects_registry.json      ← índice de todos los proyectos
//   ├── Proyecto_A/                 ← vault aislado del proyecto A
//   │   ├── Generaciones/
//   │   ├── Export/
//   │   ├── Vault/
//   │   └── ...
//   └── Proyecto_B/
//       └── ...
//
// El proyecto activo define qué AssetStore, GeneracionesURL, etc. usa
// el resto de la app vía VaultManager.shared.activeProjectRoot

@MainActor
final class ProjectManager: ObservableObject {

    static let shared = ProjectManager()
    private init() { loadRegistry() }

    // MARK: - Models

    struct Project: Codable, Identifiable, Hashable {
        var id:           UUID    = UUID()
        var name:         String
        var description:  String  = ""
        var category:     ProjectCategory = .general
        var createdAt:    Date    = Date()
        var lastOpenedAt: Date    = Date()
        var isArchived:   Bool    = false
        var color:        String  = "#7c6af7"     // Hex color para UI
        var icon:         String  = "folder.fill"
        var thumbnailAssetID: UUID? = nil          // Último asset generado como cover

        // Settings base del proyecto
        var defaultCheckpoint:  String  = ""
        var defaultBaseURL:     String  = "http://127.0.0.1:7860"
        var defaultWidth:       Int     = 512
        var defaultHeight:      Int     = 768
        var defaultSampler:     String  = "DPM++ 2M Karras"
        var defaultSteps:       Int     = 28
        var defaultCFG:         Double  = 7.0
        var defaultLoRAs:       [String] = []
        var defaultNegative:    String  = "ugly, blurry, deformed, low quality"

        // Stats (actualizadas en memoria)
        var assetCount:     Int    = 0
        var approvedCount:  Int    = 0

        // Computed: nombre de directorio seguro
        var directoryName: String {
            let safe = name
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .init(charactersIn: "/\\:*?\"<>|"))
                .joined(separator: "_")
                .replacingOccurrences(of: " ", with: "_")
            return "\(safe)_\(id.uuidString.prefix(8))"
        }

        func hash(into hasher: inout Hasher) { hasher.combine(id) }
        static func == (lhs: Project, rhs: Project) -> Bool { lhs.id == rhs.id }
    }

    enum ProjectCategory: String, Codable, CaseIterable {
        case general      = "General"
        case editorial    = "Editorial"
        case character    = "Personaje"
        case campaign     = "Campaña"
        case experimental = "Experimental"
        case archive      = "Archivo"

        var icon: String {
            switch self {
            case .general:      return "folder.fill"
            case .editorial:    return "photo.artframe"
            case .character:    return "person.crop.square.fill"
            case .campaign:     return "megaphone.fill"
            case .experimental: return "wand.and.sparkles"
            case .archive:      return "archivebox.fill"
            }
        }
    }

    // MARK: - State

    @Published var projects:       [Project]  = []
    @Published var activeProject:  Project?   = nil
    @Published var isCreating:     Bool       = false
    @Published var showProjectPicker: Bool    = false

    // MARK: - Public API

    /// Crear nuevo proyecto y establecerlo como activo.
    @discardableResult
    func create(
        name:        String,
        description: String        = "",
        category:    ProjectCategory = .general,
        color:       String        = "#7c6af7"
    ) -> Project {
        let project = Project(
            name:        name,
            description: description,
            category:    category,
            color:       color
        )

        // Crear estructura de directorios
        createDirectoryStructure(for: project)

        projects.insert(project, at: 0)
        saveRegistry()

        setActive(project)
        return project
    }

    /// Cambiar proyecto activo.
    func setActive(_ project: Project) {
        guard let idx = projects.firstIndex(where: { $0.id == project.id }) else { return }
        var updated = projects[idx]
        updated.lastOpenedAt = Date()
        projects[idx] = updated
        activeProject = updated
        saveRegistry()

        // Notificar a VaultManager para que actualice rutas
        VaultManager.shared.setActiveProject(updated)

        NotificationCenter.default.post(name: .projectDidChange, object: updated)
    }

    /// Actualizar propiedades de un proyecto.
    func update(_ project: Project) {
        guard let idx = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[idx] = project
        if activeProject?.id == project.id { activeProject = project }
        saveRegistry()
    }

    /// Archivar proyecto (no elimina datos).
    func archive(_ project: Project) {
        guard let idx = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[idx].isArchived = true
        if activeProject?.id == project.id {
            // Activar el siguiente proyecto disponible
            if let next = projects.first(where: { !$0.isArchived && $0.id != project.id }) {
                setActive(next)
            } else {
                activeProject = nil
                VaultManager.shared.clearActiveProject()
            }
        }
        saveRegistry()
    }

    /// Eliminar proyecto permanentemente (con confirmación requerida en UI).
    func delete(_ project: Project, deleteFiles: Bool = false) {
        if deleteFiles {
            if let dir = projectRoot(for: project) {
                try? FileManager.default.removeItem(at: dir)
            }
        }
        projects.removeAll { $0.id == project.id }
        if activeProject?.id == project.id {
            activeProject = projects.first(where: { !$0.isArchived })
            if let p = activeProject { VaultManager.shared.setActiveProject(p) }
            else { VaultManager.shared.clearActiveProject() }
        }
        saveRegistry()
    }

    /// Incrementar contador de assets del proyecto activo.
    func incrementAssetCount() {
        guard let active = activeProject,
              let idx = projects.firstIndex(where: { $0.id == active.id })
        else { return }
        projects[idx].assetCount += 1
        activeProject = projects[idx]
        saveRegistry()
    }

    /// Actualizar approved count del proyecto activo.
    func updateApprovedCount(_ count: Int) {
        guard let active = activeProject,
              let idx = projects.firstIndex(where: { $0.id == active.id })
        else { return }
        projects[idx].approvedCount = count
        activeProject = projects[idx]
    }

    /// URL raíz del directorio de un proyecto.
    func projectRoot(for project: Project) -> URL? {
        VaultManager.shared.vaultRoot?.appending(path: project.directoryName)
    }

    /// URL raíz del proyecto activo.
    var activeProjectRoot: URL? {
        guard let p = activeProject else { return nil }
        return projectRoot(for: p)
    }

    /// Proyectos visibles (no archivados), ordenados por último acceso.
    var activeProjects: [Project] {
        projects
            .filter { !$0.isArchived }
            .sorted { $0.lastOpenedAt > $1.lastOpenedAt }
    }

    /// Proyectos archivados.
    var archivedProjects: [Project] {
        projects.filter { $0.isArchived }
    }

    // MARK: - Directory Structure

    func createDirectoryStructure(for project: Project) {
        guard let root = projectRoot(for: project) else { return }
        let fm = FileManager.default

        let subdirs = [
            "Generaciones",
            "Generaciones/\(Date().filenameDate)",
            "MasterPicks",
            "Export",
            "Export/Previews",
            "Personajes",
            "Escenas",
            "Referencias",
            "PrivateLoRAs",
            "Vault",
            "Vault/Licencias"
        ]

        for sub in subdirs {
            let url = root.appending(path: sub)
            if !fm.fileExists(atPath: url.path) {
                try? fm.createDirectory(at: url, withIntermediateDirectories: true)
            }
        }

        // README del proyecto
        let readmeURL = root.appending(path: "README.txt")
        if !fm.fileExists(atPath: readmeURL.path) {
            let content = """
            SDPipeline Studio — Proyecto: \(project.name)
            ============================================
            Creado: \(Date().shortDisplay)
            Categoría: \(project.category.rawValue)
            ID: \(project.id.uuidString)

            \(project.description.isEmpty ? "Sin descripción." : project.description)

            Estructura:
            • Generaciones/   → Raw output de SD (no modificar)
            • MasterPicks/    → Imágenes aprobadas
            • Export/         → Versiones limpias para publicar
            • Vault/          → Metadatos, sidecar JSONs, licencias
            • PrivateLoRAs/   → LoRAs privados del proyecto
            """
            try? content.write(to: readmeURL, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Persistence

    private var registryURL: URL? {
        VaultManager.shared.vaultRoot?.appending(path: ".projects_registry.json")
    }

    private struct Registry: Codable {
        var projects:        [Project]
        var activeProjectID: UUID?
        var schemaVersion:   String = "ProjectManager.v1"
    }

    private func saveRegistry() {
        guard let url = registryURL else { return }
        let registry = Registry(
            projects:        projects,
            activeProjectID: activeProject?.id
        )
        if let data = try? JSONEncoder.pretty.encode(registry) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func loadRegistry() {
        guard let url  = registryURL,
              let data = try? Data(contentsOf: url),
              let reg  = try? JSONDecoder.iso8601.decode(Registry.self, from: data)
        else {
            // Primer arranque — crear proyecto default si hay vault configurado
            Task { @MainActor in
                if VaultManager.shared.vaultRoot != nil {
                    createDefaultProjectIfNeeded()
                }
            }
            return
        }

        self.projects = reg.projects

        if let activeID = reg.activeProjectID,
           let active   = reg.projects.first(where: { $0.id == activeID }) {
            self.activeProject = active
            VaultManager.shared.setActiveProject(active)
        } else if let first = reg.projects.first(where: { !$0.isArchived }) {
            self.activeProject = first
            VaultManager.shared.setActiveProject(first)
        }
    }

    /// Crear proyecto "Default" en primer arranque si el vault ya existe.
    func createDefaultProjectIfNeeded() {
        guard projects.isEmpty, VaultManager.shared.vaultRoot != nil else { return }
        create(name: "Mi Primer Proyecto", description: "Proyecto creado automáticamente", category: .general)
    }
}

// MARK: - VaultManager extensions for multi-project

extension VaultManager {

    /// Actualizar todas las URLs calculadas al cambiar de proyecto activo.
    func setActiveProject(_ project: ProjectManager.Project) {
        guard let root = vaultRoot else { return }
        activeProjectDirectory = root.appending(path: project.directoryName)
    }

    func clearActiveProject() {
        activeProjectDirectory = nil
    }

    /// Directorio raíz del proyecto activo (override de URLs calculadas).
    var activeProjectDirectory: URL? {
        get { _activeProjectDirectory }
        set { _activeProjectDirectory = newValue }
    }

    // Backing storage via associated object pattern.
    // Using a UInt8 key avoids the "exposes internal String representation"
    // warning that arises when taking &String as UnsafeRawPointer.
    private var _activeProjectDirectory: URL? {
        get { objc_getAssociatedObject(self, &VaultManager.projectDirKey) as? URL }
        set { objc_setAssociatedObject(self, &VaultManager.projectDirKey, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }
    private static var projectDirKey: UInt8 = 0

    /// Override generacionesURL para usar el directorio del proyecto activo.
    var projectGeneracionesURL: URL? {
        (activeProjectDirectory ?? vaultRoot?.appending(path: "Generaciones"))
            .map { $0.appendingPathComponent("Generaciones") }
    }

    var projectExportURL: URL? {
        (activeProjectDirectory ?? vaultRoot)
            .map { $0.appendingPathComponent("Export") }
    }

    var projectPreviewsURL: URL? {
        projectExportURL.map { $0.appendingPathComponent("Previews") }
    }

    var projectVaultMetaURL: URL? {
        (activeProjectDirectory ?? vaultRoot)
            .map { $0.appendingPathComponent("Vault") }
    }
}

// MARK: - ProjectPickerView

struct ProjectPickerView: View {
    @StateObject private var manager = ProjectManager.shared
    @State private var showCreate = false
    @State private var newName    = ""
    @State private var newCategory: ProjectManager.ProjectCategory = .general
    @State private var newDesc    = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "folder.badge.gearshape")
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: "#7c6af7"))
                Text("Proyectos")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Button(action: { showCreate = true }) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(Color(hex: "#7c6af7"))
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color.white.opacity(0.03))

            Divider().background(Color.white.opacity(0.06))

            // Active project banner
            if let active = manager.activeProject {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color(hex: active.color))
                        .frame(width: 8, height: 8)
                    Text(active.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                    Text("activo")
                        .font(.system(size: 9))
                        .foregroundColor(Color(hex: "#34d399"))
                    Spacer()
                    Text("\(active.assetCount) assets")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Color(hex: active.color).opacity(0.08))
            }

            Divider().background(Color.white.opacity(0.05))

            // Project list
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(manager.activeProjects) { project in
                        projectRow(project)
                    }
                    if !manager.archivedProjects.isEmpty {
                        Text("Archivados")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(manager.archivedProjects) { project in
                            projectRow(project)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .sheet(isPresented: $showCreate) { createSheet }
    }

    func projectRow(_ project: ProjectManager.Project) -> some View {
        let isActive = manager.activeProject?.id == project.id
        return Button(action: { manager.setActive(project) }) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(hex: project.color).opacity(0.2))
                    .frame(width: 30, height: 30)
                    .overlay(
                        Image(systemName: project.category.icon)
                            .font(.system(size: 13))
                            .foregroundColor(Color(hex: project.color))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                        .foregroundColor(isActive ? .white : .white.opacity(0.7))
                    Text("\(project.assetCount) assets · \(project.category.rawValue)")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }

                Spacer()

                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#34d399"))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(isActive ? Color.white.opacity(0.07) : Color.clear)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Archivar proyecto") { manager.archive(project) }
            Divider()
            Button("Eliminar…", role: .destructive) { manager.delete(project) }
        }
    }

    var createSheet: some View {
        VStack(spacing: 18) {
            Text("Nuevo Proyecto")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.white)

            VStack(alignment: .leading, spacing: 6) {
                Text("Nombre").font(.system(size: 11)).foregroundColor(.secondary)
                TextField("Ej: Beach Editorial Marzo", text: $newName)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Categoría").font(.system(size: 11)).foregroundColor(.secondary)
                Picker("", selection: $newCategory) {
                    ForEach(ProjectManager.ProjectCategory.allCases, id: \.self) {
                        Label($0.rawValue, systemImage: $0.icon).tag($0)
                    }
                }
                .pickerStyle(.menu)
                .font(.system(size: 12))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Descripción (opcional)").font(.system(size: 11)).foregroundColor(.secondary)
                TextField("Temática, notas, referencias…", text: $newDesc)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12))
            }

            HStack {
                Button("Cancelar") { showCreate = false }
                    .buttonStyle(.plain).foregroundColor(.secondary)
                Spacer()
                Button("Crear Proyecto") {
                    guard !newName.isEmpty else { return }
                    manager.create(name: newName, description: newDesc, category: newCategory)
                    showCreate = false
                    newName = ""; newDesc = ""
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(newName.isEmpty ? Color.gray.opacity(0.3) : Color(hex: "#7c6af7"))
                .foregroundColor(.white).cornerRadius(7)
                .disabled(newName.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 380)
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
    }
}

// MARK: - ProjectBadge (mini widget para header)

struct ProjectBadge: View {
    @StateObject private var manager = ProjectManager.shared
    @State private var showPicker = false

    var body: some View {
        Button(action: { showPicker.toggle() }) {
            HStack(spacing: 5) {
                if let p = manager.activeProject {
                    Circle()
                        .fill(Color(hex: p.color))
                        .frame(width: 6, height: 6)
                    Text(p.name)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.75))
                        .lineLimit(1)
                } else {
                    Text("Sin proyecto")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.white.opacity(0.06))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPicker, arrowEdge: .bottom) {
            ProjectPickerView()
                .frame(width: 300, height: 420)
        }
    }
}


