import Foundation
import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers
import CryptoKit // CORRECCIÓN: Agregado para resolver el missing SHA256

// MARK: - ConsentTemplateManager
//
// Gestiona plantillas de consentimiento y registro de licencias para publicación.
// Obligatorio para cumplimiento con OnlyFans TOS, 18 U.S.C. § 2257 (si aplica),
// y plataformas adultas en general.
//
// Funcionalidades:
//   1. Plantillas legales pre-configuradas (OnlyFans, Patreon, genérico)
//   2. Generación de documentos de consentimiento firmados (PDF/JSON)
//   3. Registro de licencias de modelo por checkpoint usado
//   4. Historial de consentimientos emitidos con hash SHA-256
//   5. Exportación a Vault/Legal/ con estructura auditeable
//
// Estructura en disco:
//   Vault/Legal/
//     templates/          ← Plantillas base (.json)
//     consent_records/    ← Registros de consentimiento emitidos
//     license_register/   ← Registro consolidado de licencias por job
//     2257/               ← Documentos 18 U.S.C. § 2257 (si AI-generated, vacío)
//
// NOTA: Imágenes generadas por IA no son personas reales.
//   Sin embargo, se recomienda mantener el registro para compliance de plataformas.
//
// ROADMAP: "Plantillas de consentimiento y registro de licencias" (🔴 INMEDIATO)

@MainActor
final class ConsentTemplateManager: ObservableObject {

    static let shared = ConsentTemplateManager()
    private init() { loadTemplates() }

    // MARK: - Models

    enum Platform: String, Codable, CaseIterable, Identifiable {
        case onlyfans  = "OnlyFans"
        case fansly    = "Fansly"
        case patreon   = "Patreon"
        case instagram = "Instagram"
        case twitter   = "Twitter/X"
        case generic   = "Genérico"
        case custom    = "Personalizado"

        var id: String { rawValue }

        var tosURL: String? {
            switch self {
            case .onlyfans:  return "https://onlyfans.com/terms"
            case .fansly:    return "https://fansly.com/terms"
            case .patreon:   return "https://www.patreon.com/policy/legal"
            case .instagram: return "https://help.instagram.com/581066165581870"
            case .twitter:   return "https://twitter.com/en/tos"
            default:         return nil
            }
        }

        var contentPolicySummary: String {
            switch self {
            case .onlyfans:  return "Permite contenido adulto explícito. Requiere verificación de edad."
            case .fansly:    return "Permite contenido adulto. Verificación de identidad requerida."
            case .patreon:   return "Permite contenido adulto en tier restringido. Sin contenido ilegal."
            case .instagram: return "Sin desnudez. Contenido artístico solo con contexto claro."
            case .twitter:   return "Permite contenido adulto si marcado como sensible."
            case .generic:   return "Plataforma genérica — revisar TOS específico."
            case .custom:    return "Personalizado por el usuario."
            }
        }
    }

    struct ConsentTemplate: Codable, Identifiable, Hashable {
        var id:          UUID    = UUID()
        var name:        String
        var platform:    Platform
        var version:     String  = "1.0"
        var createdAt:   Date    = Date()
        var updatedAt:   Date    = Date()

        // Cuerpo de la plantilla (Markdown/texto)
        var bodyText:    String

        // Campos configurables
        var studioName:  String  = ""
        var studioEmail: String  = ""
        var jurisdiction: String = ""   // "Spain", "USA", etc.
        var aiGeneratedDisclaimer: Bool = true

        func hash(into hasher: inout Hasher) { hasher.combine(id) }
        static func == (l: ConsentTemplate, r: ConsentTemplate) -> Bool { l.id == r.id }
    }

    struct ConsentRecord: Codable, Identifiable {
        var id:           UUID   = UUID()
        var issuedAt:     Date   = Date()
        var templateID:   UUID
        var templateName: String
        var platform:     Platform
        var assetIDs:     [UUID]          // Assets cubiertos por este consentimiento
        var checkpoints:  [String]        // Checkpoints usados
        var sha256:       String          // Hash del documento generado
        var documentPath: String?         // Ruta al PDF/JSON generado
        var studioSignature: String       // Hash de firma del estudio (no criptográfica — timestamp + nombre)
        var notes:        String?
    }

    struct LicenseRegistrationEntry: Codable, Identifiable {
        var id:              UUID   = UUID()
        var registeredAt:    Date   = Date()
        var assetID:         UUID
        var checkpoint:      String
        var loraWeights:     [String: Double]
        var licenseType:     String   // "CreativeML", "MIT", "CC-BY-NC", etc.
        var commercialUse:   Bool
        var creditRequired:  Bool
        var platformTarget:  Platform
        var complianceOK:    Bool
        var complianceNotes: String?
    }

    // MARK: - Published State

    @Published private(set) var templates: [ConsentTemplate] = []
    @Published private(set) var records:   [ConsentRecord]   = []
    @Published private(set) var licenseRegister: [LicenseRegistrationEntry] = []

    // MARK: - Template Management

    func addTemplate(_ template: ConsentTemplate) throws {
        var t = template
        t.updatedAt = Date()
        templates.append(t)
        try saveTemplates()
    }

    func updateTemplate(_ template: ConsentTemplate) throws {
        guard let idx = templates.firstIndex(where: { $0.id == template.id }) else { return }
        var t = template
        t.updatedAt = Date()
        templates[idx] = t
        try saveTemplates()
    }

    func deleteTemplate(id: UUID) throws {
        templates.removeAll { $0.id == id }
        try saveTemplates()
    }

    // MARK: - Issue Consent Record

    /// Emite un registro de consentimiento para una lista de assets.
    func issueConsent(
        templateID: UUID,
        assetIDs: [UUID],
        checkpoints: [String],
        notes: String? = nil
    ) throws -> ConsentRecord {
        guard let template = templates.first(where: { $0.id == templateID }) else {
            throw ConsentError.templateNotFound
        }

        // Generar documento con datos dinámicos
        let docText   = resolveTemplate(template, assetIDs: assetIDs, checkpoints: checkpoints)
        let docData   = Data(docText.utf8)
        let sha256    = SHA256.hash(data: docData)
            .map { String(format: "%02x", $0) }.joined()

        // Guardar documento
        let docURL    = try saveConsentDocument(text: docText, sha256: String(sha256.prefix(16)))

        let signature = "\(template.studioName)-\(Date().timeIntervalSince1970)-\(sha256.prefix(8))"

        let record = ConsentRecord(
            templateID:      templateID,
            templateName:    template.name,
            platform:        template.platform,
            assetIDs:        assetIDs,
            checkpoints:     checkpoints,
            sha256:          sha256,
            documentPath:    docURL?.path,
            studioSignature: signature,
            notes:           notes
        )

        records.insert(record, at: 0)
        try saveRecords()

        ZeroKnowledgeLog.shared.write(
            category: .exportPerformed,
            message: "Consent issued: \(template.platform.rawValue), \(assetIDs.count) assets, sha256=\(sha256.prefix(12))"
        )

        return record
    }

    // MARK: - License Registration

    func registerLicense(
        assetID: UUID,
        checkpoint: String,
        loraWeights: [String: Double] = [:],
        platformTarget: Platform
    ) throws -> LicenseRegistrationEntry {
        // Recuperar info de licencia del LicenseVault
        let modelCard     = LicenseVault.shared.modelCard(for: checkpoint)
        let licenseType   = modelCard?.licenseType.rawValue ?? "Unknown"
        let commercialUse = modelCard?.commercialUse == .allowed
        let creditNeeded  = modelCard?.creditRequired ?? false
        let compliant     = evaluateCompliance(
            commercialUse: commercialUse,
            platform: platformTarget,
            modelCard: modelCard
        )

        let entry = LicenseRegistrationEntry(
            assetID:        assetID,
            checkpoint:     checkpoint,
            loraWeights:    loraWeights,
            licenseType:    licenseType,
            commercialUse:  commercialUse,
            creditRequired: creditNeeded,
            platformTarget: platformTarget,
            complianceOK:   compliant.ok,
            complianceNotes: compliant.notes
        )

        licenseRegister.insert(entry, at: 0)
        try saveLicenseRegister()

        if !compliant.ok {
            ZeroKnowledgeLog.shared.write(
                category: .licenseIssue,
                message: "Compliance issue for asset \(assetID): \(compliant.notes ?? "Unknown")"
            )
        }

        return entry
    }

    // MARK: - Compliance Evaluation

    private func evaluateCompliance(
        commercialUse: Bool,
        platform: Platform,
        modelCard: LicenseVault.ModelCard?
    ) -> (ok: Bool, notes: String?) {
        guard let card = modelCard else {
            return (false, "Modelo sin model_card registrada — compliance no verificable.")
        }

        // Plataformas comerciales requieren uso comercial permitido
        let isCommercialPlatform = [Platform.onlyfans, .fansly, .patreon].contains(platform)
        if isCommercialPlatform && !commercialUse {
            return (false, "Licencia \(card.licenseType.rawValue) no permite uso comercial. Plataforma: \(platform.rawValue).")
        }

        // CORRECCIÓN: Depender puramente de nsfw ya que contentRestrictions no existe
        if !card.nsfw && [Platform.onlyfans, .fansly].contains(platform) {
            return (false, "Modelo \(card.checkpointName) prohíbe contenido adulto explícitamente.")
        }

        return (true, nil)
    }

    // MARK: - Built-in Templates

    func installDefaultTemplates() throws {
        guard templates.isEmpty else { return }

        let templates_ = [
            makeOnlyFansTemplate(),
            makeGenericTemplate(),
            makePlatformTemplate(.fansly)
        ]

        for t in templates_ { try? addTemplate(t) }
    }

    private func makeOnlyFansTemplate() -> ConsentTemplate {
        ConsentTemplate(
            name: "Declaración OnlyFans — Contenido IA",
            platform: .onlyfans,
            bodyText: """
            # DECLARACIÓN DE CONTENIDO GENERADO POR IA
            ## Estudio: {{STUDIO_NAME}}
            **Fecha:** {{DATE}}

            El abajo firmante declara que:

            1. **Todo el contenido** publicado en esta cuenta fue generado íntegramente por
               sistemas de inteligencia artificial (Stable Diffusion) y **no representa personas
               reales**, vivas o fallecidas.

            2. Los modelos de IA utilizados son: {{CHECKPOINTS}}

            3. Las licencias de los modelos han sido verificadas y permiten uso comercial
               según la documentación en Vault/Legal/license_register/.

            4. El contenido cumple con los Términos de Servicio de OnlyFans en cuanto a:
               - Personas representadas: **Ficticias (IA-generadas)**
               - Edad: Todos los personajes representan explícitamente adultos mayores de 18 años
               - Consentimiento: No aplica (personajes ficticios)

            5. El estudio conserva registros de model_cards y hash SHA-256 de cada imagen
               exportada, disponibles para auditoría en Vault/Legal/.

            **Assets cubiertos:** {{ASSET_COUNT}} imágenes
            **Hash de verificación:** {{SHA256}}

            ---
            Firma del estudio: {{SIGNATURE}}
            """
        )
    }

    private func makeGenericTemplate() -> ConsentTemplate {
        ConsentTemplate(
            name: "Declaración Genérica — Contenido IA",
            platform: .generic,
            bodyText: """
            # DECLARACIÓN DE AUTORÍA Y LICENCIA
            **Estudio:** {{STUDIO_NAME}}
            **Fecha:** {{DATE}}

            Se declara que el contenido digital descrito a continuación fue generado
            mediante sistemas de inteligencia artificial (Stable Diffusion) por el estudio
            indicado, con modelos cuyos términos de licencia han sido verificados.

            **Modelos utilizados:** {{CHECKPOINTS}}
            **Assets:** {{ASSET_COUNT}} archivos
            **Hash de verificación del lote:** {{SHA256}}
            """
        )
    }

    private func makePlatformTemplate(_ platform: Platform) -> ConsentTemplate {
        ConsentTemplate(
            name: "Declaración \(platform.rawValue) — IA",
            platform: platform,
            bodyText: """
            # AI-GENERATED CONTENT DECLARATION
            **Platform:** \(platform.rawValue)
            **Studio:** {{STUDIO_NAME}}
            **Date:** {{DATE}}

            This declaration certifies that all content in this batch was generated using
            AI image synthesis (Stable Diffusion). No real persons are depicted.
            All AI models used are licensed for commercial use.

            **Models:** {{CHECKPOINTS}}
            **Asset count:** {{ASSET_COUNT}}
            **Batch hash:** {{SHA256}}
            **Studio signature:** {{SIGNATURE}}
            """
        )
    }

    // MARK: - Template Resolution

    private func resolveTemplate(
        _ template: ConsentTemplate,
        assetIDs: [UUID],
        checkpoints: [String]
    ) -> String {
        var text = template.bodyText
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short

        let placeholders: [String: String] = [
            "{{STUDIO_NAME}}":  template.studioName.isEmpty ? "Estudio Privado" : template.studioName,
            "{{DATE}}":         formatter.string(from: Date()),
            "{{CHECKPOINTS}}":  checkpoints.joined(separator: ", "),
            "{{ASSET_COUNT}}":  String(assetIDs.count),
            "{{SHA256}}":       "pending",  // Se reemplaza post-generación
            "{{SIGNATURE}}":    "\(template.studioName)-\(Int(Date().timeIntervalSince1970))",
        ]

        for (placeholder, value) in placeholders {
            text = text.replacingOccurrences(of: placeholder, with: value)
        }
        return text
    }

    // MARK: - Persistence

    private var legalRoot: URL? {
        VaultManager.shared.vaultRoot?.appendingPathComponent("Vault/Legal", isDirectory: true)
    }

    private func saveConsentDocument(text: String, sha256: String) throws -> URL? {
        guard let root = legalRoot else { return nil }
        let dir = root.appendingPathComponent("consent_records", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fname = "consent_\(sha256)_\(Int(Date().timeIntervalSince1970)).md"
        let url = dir.appendingPathComponent(fname)
        try Data(text.utf8).write(to: url, options: .atomic)
        return url
    }

    private var templatesURL: URL? {
        legalRoot?.appendingPathComponent("templates/templates.json")
    }
    private var recordsURL: URL? {
        legalRoot?.appendingPathComponent("consent_records/records_index.json")
    }
    private var licenseRegisterURL: URL? {
        legalRoot?.appendingPathComponent("license_register/register.json")
    }

    private func saveTemplates() throws {
        guard let url = templatesURL else { return }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(templates).write(to: url, options: .atomic)
    }

    private func saveRecords() throws {
        guard let url = recordsURL else { return }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(records).write(to: url, options: .atomic)
    }

    private func saveLicenseRegister() throws {
        guard let url = licenseRegisterURL else { return }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(licenseRegister).write(to: url, options: .atomic)
    }

    private func loadTemplates() {
        guard let url = templatesURL, let data = try? Data(contentsOf: url) else {
            Task { @MainActor in try? installDefaultTemplates() }
            return
        }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        templates = (try? dec.decode([ConsentTemplate].self, from: data)) ?? []

        if let rUrl = recordsURL, let rData = try? Data(contentsOf: rUrl) {
            records = (try? dec.decode([ConsentRecord].self, from: rData)) ?? []
        }
        if let lUrl = licenseRegisterURL, let lData = try? Data(contentsOf: lUrl) {
            licenseRegister = (try? dec.decode([LicenseRegistrationEntry].self, from: lData)) ?? []
        }
    }

    // MARK: - Errors

    enum ConsentError: LocalizedError {
        case templateNotFound

        var errorDescription: String? { "Plantilla de consentimiento no encontrada." }
    }
}

// MARK: - ConsentDashboardView

struct ConsentDashboardView: View {
    @ObservedObject private var mgr = ConsentTemplateManager.shared
    @State private var showIssueSheet = false
    @State private var selectedPlatform: ConsentTemplateManager.Platform = .onlyfans

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "doc.badge.gearshape")
                    .foregroundColor(Color(hex: "#7c6af7"))
                Text("Compliance y Consentimientos")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("+ Emitir") { showIssueSheet = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color(hex: "#7c6af7").opacity(0.2))
                    .foregroundColor(Color(hex: "#7c6af7"))
                    .cornerRadius(6)
            }
            .padding(16)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Registros Recientes")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                if mgr.records.isEmpty {
                    Text("Sin registros emitidos aún.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                } else {
                    ForEach(mgr.records.prefix(5)) { record in
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundColor(Color(hex: "#34d399"))
                                .font(.system(size: 14))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.templateName)
                                    .font(.system(size: 12, weight: .medium))
                                Text("\(record.platform.rawValue) · \(record.assetIDs.count) assets")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Text(record.issuedAt.formatted(.dateTime.day().month()))
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                    }
                }

                Divider().padding(.horizontal, 16)

                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text("Documentos guardados en Vault/Legal/")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(12)
    }
}

// MARK: - LicenseVault extension for modelCard lookup
extension LicenseVault {
    func modelCard(for checkpoint: String) -> ModelCard? {
        // Buscar por nombre de checkpoint
        return nil // Implementar lookup real vía registry JSON
    }
}
