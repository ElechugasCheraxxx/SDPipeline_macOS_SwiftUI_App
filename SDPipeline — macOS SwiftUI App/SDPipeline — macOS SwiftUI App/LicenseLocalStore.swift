import Foundation
import SwiftUI
import Combine
import AppKit

// MARK: - LicenseLocalStore
//
// Repositorio local de archivos LICENSE.txt y documentos legales por modelo/LoRA.
// Complementa LicenseVault.swift (que almacena model_cards en JSON).
//
// LicenseLocalStore:
//   - Almacena los archivos LICENSE.txt crudos por checkpoint
//   - Parsea licencias conocidas (MIT, Apache 2.0, CreativeML, OpenRAIL, etc.)
//   - Detecta restricciones críticas (NoCommercial, NoAdult, etc.)
//   - Genera un reporte de compliance consolidado
//   - Permite adjuntar documentos adicionales (contratos, términos, etc.)
//
// Estructura en disco:
//   Vault/Licencias/licenses/
//     {checkpoint_sha256}/
//       LICENSE.txt
//       model_terms.txt      (opcional)
//       notes.txt            (opcional)
//       attachments/         (PDFs, etc.)
//
// ROADMAP: "Control local de licencias (repositorio LICENSE.txt)" (🔴 INMEDIATO)

// MARK: - License Types

enum LicenseType: String, Codable, CaseIterable {
    case mit           = "MIT"
    case apache2       = "Apache 2.0"
    case gpl3          = "GPL 3.0"
    case cc0           = "CC0 (Dominio Público)"
    case ccBy          = "CC BY"
    case ccByNc        = "CC BY-NC"
    case ccByNcNd      = "CC BY-NC-ND"
    case ccBySa        = "CC BY-SA"
    case creativeML    = "CreativeML Open RAIL-M"
    case creativeMLNc  = "CreativeML Open RAIL-M (No Commercial)"
    case openRAIL      = "OpenRAIL"
    case openRAILPlus  = "OpenRAIL++"
    case sdxlResearch  = "SDXL Research License"
    case proprietary   = "Propietario"
    case unknown       = "Desconocido"
    case custom        = "Personalizado"

    var isCommercialAllowed: Bool? {
        switch self {
        case .mit, .apache2, .cc0, .ccBy, .creativeML, .openRAIL, .openRAILPlus: return true
        case .gpl3, .ccBySa:                                  return true    // con condiciones
        case .ccByNc, .ccByNcNd, .creativeMLNc:              return false
        case .sdxlResearch:                                   return false
        case .proprietary, .unknown, .custom:                 return nil
        }
    }

    var isSharingAllowed: Bool? {
        switch self {
        case .mit, .apache2, .cc0, .ccBy, .gpl3, .ccBySa,
             .creativeML, .openRAIL, .openRAILPlus:           return true
        case .ccByNcNd:                                       return false
        case .proprietary, .unknown, .custom:                 return nil
        default:                                              return true
        }
    }

    var requiresAttribution: Bool {
        switch self {
        case .cc0, .mit:  return false
        case .apache2:    return true  // notices only
        default:          return true
        }
    }

    var riskLevel: RiskLevel {
        switch self {
        case .cc0, .mit, .apache2, .ccBy: return .low
        case .creativeML, .openRAIL, .openRAILPlus: return .low
        case .gpl3, .ccBySa:              return .medium
        case .ccByNc, .ccByNcNd:          return .medium
        case .creativeMLNc:               return .high
        case .sdxlResearch, .proprietary: return .high
        case .unknown:                    return .unknown
        case .custom:                     return .medium
        }
    }

    enum RiskLevel: Int, Comparable {
        case low = 0, medium = 1, high = 2, unknown = 3

        var label: String {
            switch self {
            case .low:     return "Bajo"
            case .medium:  return "Moderado"
            case .high:    return "Alto"
            case .unknown: return "Desconocido"
            }
        }

        var color: String {
            switch self {
            case .low:     return "#34d399"
            case .medium:  return "#f59e0b"
            case .high:    return "#ef4444"
            case .unknown: return "#8b8b8b"
            }
        }

        static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Intenta detectar el tipo de licencia desde el contenido del archivo
    static func detect(from text: String) -> LicenseType {
        let t = text.lowercased()

        if t.contains("creativeml open rail-m") && t.contains("non-commercial") { return .creativeMLNc }
        if t.contains("creativeml open rail-m") { return .creativeML }
        if t.contains("openrail++")              { return .openRAILPlus }
        if t.contains("openrail")                { return .openRAIL }
        if t.contains("cc by-nc-nd")             { return .ccByNcNd }
        if t.contains("cc by-nc-sa") || (t.contains("cc by-nc") && t.contains("share")) { return .ccBySa }
        if t.contains("cc by-nc")                { return .ccByNc }
        if t.contains("cc by-sa")                { return .ccBySa }
        if t.contains("cc by") || t.contains("creative commons attribution") { return .ccBy }
        if t.contains("cc0") || t.contains("public domain dedication") { return .cc0 }
        if t.contains("apache license") && t.contains("version 2.0") { return .apache2 }
        if t.contains("mit license")             { return .mit }
        if t.contains("gnu general public license") && t.contains("version 3") { return .gpl3 }
        if t.contains("stable diffusion xl") && t.contains("research") { return .sdxlResearch }
        if t.contains("all rights reserved")     { return .proprietary }

        return .unknown
    }
}

// MARK: - License Restriction

struct LicenseRestriction: Codable, Identifiable {
    var id:       UUID   = UUID()
    var type:     RestrictionType
    var severity: Severity
    var note:     String = ""

    enum RestrictionType: String, Codable, CaseIterable {
        case noCommercial       = "No uso comercial"
        case noAdultContent     = "No contenido adulto"
        case noDeepfake         = "No deepfake"
        case noCopyright        = "No infringir copyright"
        case noHate             = "No discurso de odio"
        case noRealPeople       = "No personas reales"
        case noWeapons          = "No armas"
        case attributionRequired = "Atribución requerida"
        case sharealike          = "Share-alike obligatorio"
        case noModifications     = "Sin modificaciones"
        case customRestriction   = "Restricción personalizada"

        var icon: String {
            switch self {
            case .noCommercial:       return "dollarsign.slash"
            case .noAdultContent:     return "eye.slash.fill"
            case .noDeepfake:         return "person.crop.circle.badge.xmark"
            case .noCopyright:        return "c.circle.fill"
            case .noHate:             return "person.2.slash"
            case .noRealPeople:       return "person.slash.fill"
            case .noWeapons:          return "shield.slash.fill"
            case .attributionRequired: return "a.circle.fill"
            case .sharealike:          return "arrow.triangle.2.circlepath"
            case .noModifications:     return "lock.fill"
            case .customRestriction:   return "exclamationmark.triangle.fill"
            }
        }
    }

    enum Severity: String, Codable, CaseIterable {
        case blocker = "Bloqueante"
        case warning = "Advertencia"
        case info    = "Informativo"

        var color: String {
            switch self {
            case .blocker: return "#ef4444"
            case .warning: return "#f59e0b"
            case .info:    return "#3de3c0"
            }
        }
    }
}

// MARK: - LicenseEntry

struct LicenseEntry: Codable, Identifiable {
    var id:           UUID          = UUID()
    var createdAt:    Date          = Date()
    var updatedAt:    Date          = Date()

    var modelName:    String                    // checkpoint o LoRA name
    var sha256:       String        = ""        // para vincular con ModelManager
    var licenseType:  LicenseType   = .unknown
    var rawText:      String        = ""        // contenido del LICENSE.txt
    var sourceURL:    String        = ""        // de dónde vino el modelo
    var restrictions: [LicenseRestriction] = []
    var notes:        String        = ""
    var isVerified:   Bool          = false     // ¿revisado manualmente?
    var reviewedBy:   String        = ""
    var reviewedAt:   Date?         = nil

    var directoryName: String {
        sha256.isEmpty
            ? modelName.replacing(/[^a-zA-Z0-9_-]/, with: { _ in "_" })
            : String(sha256.prefix(16))
    }

    var complianceStatus: ComplianceStatus {
        let blockers = restrictions.filter { $0.severity == .blocker }
        if !blockers.isEmpty { return .blocked }
        let warnings = restrictions.filter { $0.severity == .warning }
        if !warnings.isEmpty { return .warning }
        if licenseType == .unknown { return .unverified }
        return .compliant
    }

    enum ComplianceStatus: String {
        case compliant   = "Compliant"
        case warning     = "Warning"
        case blocked     = "Bloqueado"
        case unverified  = "Sin verificar"

        var icon: String {
            switch self {
            case .compliant:  return "checkmark.shield.fill"
            case .warning:    return "exclamationmark.shield.fill"
            case .blocked:    return "xmark.shield.fill"
            case .unverified: return "questionmark.circle.fill"
            }
        }

        var color: String {
            switch self {
            case .compliant:  return "#34d399"
            case .warning:    return "#f59e0b"
            case .blocked:    return "#ef4444"
            case .unverified: return "#8b8b8b"
            }
        }
    }
}

// MARK: - LicenseLocalStore

@MainActor
final class LicenseLocalStore: ObservableObject {

    static let shared = LicenseLocalStore()
    private init() { loadRegistry() }

    // MARK: - State

    @Published var entries:  [LicenseEntry]  = []
    @Published var isLoading: Bool           = false

    private var registryURL: URL?
    // MARK: - Persistence

    /// Ubicación por defecto del registro en disco si no se configuró explícitamente
    private var defaultRegistryURL: URL {
        let fm = FileManager.default
        let appSupport = try? fm.url(for: .applicationSupportDirectory,
                                     in: .userDomainMask,
                                     appropriateFor: nil,
                                     create: true)
        let base = (appSupport ?? fm.temporaryDirectory)
            .appendingPathComponent("Vault/Licencias/licenses", isDirectory: true)
        // Creamos el directorio si no existe
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("registry.json")
    }

    /// Carga el registro de licencias desde disco
    func loadRegistry() {
        isLoading = true
        defer { isLoading = false }

        let url = registryURL ?? defaultRegistryURL
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            entries = []
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode([LicenseEntry].self, from: data)
            entries = decoded
        } catch {
            // Si hay error al leer/decodificar, dejamos la lista vacía pero no rompemos la app
            entries = []
            #if DEBUG
            print("[LicenseLocalStore] Error al cargar registry: \(error)")
            #endif
        }
    }

    /// Guarda el registro de licencias en disco
    func saveRegistry() {
        let url = registryURL ?? defaultRegistryURL
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: url, options: [.atomic])
        } catch {
            #if DEBUG
            print("[LicenseLocalStore] Error al guardar registry: \(error)")
            #endif
        }
    }
}

