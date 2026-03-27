// Persistence/ProfileStore.swift
// CORRECCIONES:
// ✅ Logger estructurado (os.Logger) en lugar de print().
// ✅ save() propaga errores con throw (ya existía).
// ✅ Escritura con debounce de 0.3 s (ya existía).
// ✅ loadAllSync() con logging de errores de decodificación.
// ✅ Swift 6 / @MainActor (ya existía).
// ✅ Preview añadido.

import Foundation
import SwiftUI
import UniformTypeIdentifiers
import os

private let log = Logger(subsystem: "com.cheraxx.keymapper", category: "ProfileStore")

// MARK: - Tipo de archivo
extension UTType {
    static let immap = UTType(exportedAs: "com.cheraxx.immap")
}

// MARK: - FileDocument para exportación
struct ImmapDocument: FileDocument {
    static var readableContentTypes: [UTType] = [.immap, .json]

    var profile: MappingProfile

    init(profile: MappingProfile) { self.profile = profile }

    init(configuration: ReadConfiguration) throws {
        let data = configuration.file.regularFileContents ?? Data()
        profile  = try JSONDecoder.cheraxx.decode(MappingProfile.self, from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = try JSONEncoder.pretty.encode(profile)
        return FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - ProfileStore
@Observable
@MainActor
final class ProfileStore {

    var profiles:        [MappingProfile] = []
    var selectedProfile: MappingProfile? {
        didSet { onProfileChanged?(selectedProfile) }
    }
    var onProfileChanged: ((MappingProfile?) -> Void)?
    var lastSaveError:    Error?

    private let fm             = FileManager.default
    private var pendingSaveWork: [UUID: DispatchWorkItem] = [:]

    private var storageDir: URL {
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("CheraxxKeyMapper/profiles", isDirectory: true)
    }

    // MARK: - Inicialización
    init() {
        loadAllSync()
        if profiles.isEmpty { insertDemoProfile() }
        selectedProfile = profiles.first
    }

    // MARK: - CRUD
    func add(_ profile: MappingProfile) {
        profiles.append(profile)
        scheduleSave(profile)
    }

    func update(_ profile: MappingProfile, immediate: Bool = false) {
        guard let idx = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        var updated       = profile
        updated.updatedAt = Date()
        profiles[idx]     = updated
        if selectedProfile?.id == updated.id { selectedProfile = updated }

        if immediate { immediatelySave(updated) }
        else         { scheduleSave(updated) }
    }

    func delete(_ profile: MappingProfile) {
        profiles.removeAll { $0.id == profile.id }
        if selectedProfile?.id == profile.id { selectedProfile = profiles.first }

        let url = storageDir.appendingPathComponent("\(profile.id.uuidString).immap")
        do {
            try fm.removeItem(at: url)
            log.info("Perfil eliminado: \(profile.name)")
        } catch {
            log.warning("No se pudo eliminar \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    // MARK: - Persistencia
    func save(_ profile: MappingProfile) throws {
        try fm.createDirectory(at: storageDir, withIntermediateDirectories: true)
        let url  = storageDir.appendingPathComponent("\(profile.id.uuidString).immap")
        let data = try JSONEncoder.pretty.encode(profile)
        try data.write(to: url, options: .atomic)
    }

    private func scheduleSave(_ profile: MappingProfile) {
        pendingSaveWork[profile.id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.immediatelySave(profile)
            self?.pendingSaveWork.removeValue(forKey: profile.id)
        }
        pendingSaveWork[profile.id] = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func immediatelySave(_ profile: MappingProfile) {
        do {
            try save(profile)
            lastSaveError = nil
            log.debug("Perfil guardado: \(profile.name)")
        } catch {
            lastSaveError = error
            log.error("Error al guardar \(profile.name): \(error.localizedDescription)")
        }
    }

    // MARK: - Carga
    private func loadAllSync() {
        guard fm.fileExists(atPath: storageDir.path) else { return }
        do {
            let files = try fm.contentsOfDirectory(at: storageDir, includingPropertiesForKeys: nil)
            profiles = files
                .filter { $0.pathExtension == "immap" }
                .compactMap { url -> MappingProfile? in
                    guard let data = try? Data(contentsOf: url) else {
                        log.warning("No se pudo leer \(url.lastPathComponent)")
                        return nil
                    }
                    do {
                        return try JSONDecoder.cheraxx.decode(MappingProfile.self, from: data)
                    } catch {
                        log.error("Error decodificando \(url.lastPathComponent): \(error.localizedDescription)")
                        return nil
                    }
                }
                .sorted { $0.updatedAt > $1.updatedAt }
            log.info("\(self.profiles.count) perfil(es) cargado(s) desde disco")
        } catch {
            log.error("No se pudo leer el directorio de perfiles: \(error.localizedDescription)")
        }
    }

    // MARK: - Importación
    func importFile(from url: URL) throws -> MappingProfile {
        let data = try Data(contentsOf: url)

        if let profile = try? JSONDecoder.cheraxx.decode(MappingProfile.self, from: data) {
            var imported  = profile
            imported.id   = UUID()
            imported.name += " (importado)"
            log.info("Perfil importado (formato nativo): \(imported.name)")
            return imported
        }

        let bsProfiles = try BlueStacksImporter.importProfiles(from: data)
        guard let first = bsProfiles.first else {
            throw ImportError.unrecognizedFormat
        }
        log.info("Perfil importado (BlueStacks): \(first.name)")
        return first
    }

    // MARK: - Perfil de demostración
    private func insertDemoProfile() {
        var demo = MappingProfile(
            name:        "Demo — FPS",
            description: "Perfil de ejemplo para FPS genérico",
            bindings:    [],
            iconName:    "scope",
            accentHex:   "#00D4FF"
        )
        demo.bindings = [
            KeyBinding(label: "Mover", action: .dpad, x: 17, y: 75,
                       params: .dpad(keyUp: "W", keyDown: "S", keyLeft: "A", keyRight: "D")),
            KeyBinding(label: "Apuntar/Disparar", action: .aimAndShoot, x: 74, y: 44,
                       params: .aimAndShoot(keyToggle: "Tab", keyAction: "MouseLButton", keySuspend: "X")),
            KeyBinding(label: "Saltar",    action: .tap, x: 85, y: 80, params: .tap(key: "Space")),
            KeyBinding(label: "Agacharse", action: .tap, x: 70, y: 85, params: .tap(key: "C")),
            KeyBinding(label: "Recargar",  action: .tap, x: 92, y: 60, params: .tap(key: "R")),
        ]
        profiles.append(demo)
        immediatelySave(demo)
        log.info("Perfil de demostración creado")
    }

    enum ImportError: LocalizedError {
        case unrecognizedFormat
        var errorDescription: String? {
            "Formato de archivo no reconocido. Usa .immap (nativo) o el JSON de BlueStacks."
        }
    }
}

// MARK: - Codificadores JSON
extension JSONEncoder {
    static var pretty: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting    = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    static var cheraxx: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

// MARK: - Preview
#if DEBUG
#Preview {
    let store = ProfileStore()
    return Text("ProfileStore: \(store.profiles.count) perfiles")
}
#endif
