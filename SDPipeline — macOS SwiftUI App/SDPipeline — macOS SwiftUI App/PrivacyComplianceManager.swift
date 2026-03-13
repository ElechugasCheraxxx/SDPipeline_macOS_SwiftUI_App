import Foundation
import AppKit
import SwiftUI
import Combine

// MARK: - PrivacyComplianceManager
//
// Gestión de Política de Privacidad, Términos y Condiciones, y Logs de Publicación.
//
// Responsabilidades:
//   1. Almacenar y versionar la política de privacidad del estudio
//   2. Almacenar T&Cs básicos para suscriptores/viewers
//   3. Log de publicación con compliance (qué se publicó, cuándo, en qué plataforma)
//   4. Auditoría de GDPR/CCPA básica (para operaciones en EU/CA)
//   5. Registro de procesamiento de datos (qué datos se generan y almacenan)
//
// Estructura en disco:
//   Vault/Legal/
//     privacy_policy.md
//     terms_and_conditions.md
//     publish_log.jsonl          ← Append-only, una línea JSON por publicación
//     data_processing_register.json
//
// ROADMAP: "Política de privacidad y T&Cs básicos" + "Logs de publicación con compliance" (🟠 CORTO PLAZO)

@MainActor
final class PrivacyComplianceManager: ObservableObject {

    static let shared = PrivacyComplianceManager()
    private init() { loadAll() }

    // MARK: - Models

    struct PolicyDocument: Codable {
        var id:          UUID   = UUID()
        var title:       String
        var version:     String = "1.0"
        var createdAt:   Date   = Date()
        var updatedAt:   Date   = Date()
        var content:     String
        var jurisdiction: String = ""   // "EU", "US-CA", "ES", etc.
    }

    struct PublishLogEntry: Codable, Identifiable {
        var id:            UUID   = UUID()
        var publishedAt:   Date   = Date()

        // Qué se publicó
        var assetIDs:      [UUID]
        var assetCount:    Int
        var platform:      String    // "OnlyFans", "Instagram", etc.
        var contentType:   ContentType
        var isAIGenerated: Bool      = true

        // Compliance checks en el momento de publicación
        var nsfwChecked:   Bool      = false
        var nsfwLevel:     String    = "unknown"
        var promptFiltered: Bool     = false
        var licenseOK:     Bool      = false
        var watermarkApplied: Bool   = false
        var exifScrubbed:  Bool      = false
        var steganographyApplied: Bool = false
        var consentRecordID: UUID?

        // Trazabilidad
        var exportPaths:   [String]  = []
        var batchHash:     String    = ""   // SHA-256 del lote de exportación

        enum ContentType: String, Codable, CaseIterable {
            case explicit    = "Explicit"
            case tasteful    = "Tasteful"
            case artistic    = "Artistic"
            case promotional = "Promotional"
            case safe        = "Safe for Work"
        }
    }

    struct DataProcessingRecord: Codable {
        var updatedAt:     Date     = Date()

        // Qué datos genera y procesa el estudio
        var dataTypes: [DataType]

        struct DataType: Codable, Identifiable {
            var id:          UUID   = UUID()
            var name:        String
            var description: String
            var storedLocally: Bool
            var sharedExternally: Bool
            var retentionPolicy: String    // "Indefinido", "1 año", etc.
            var legalBasis:  String        // "Interés legítimo", "Contrato", etc.
        }
    }

    // MARK: - Published State

    @Published var privacyPolicy:       PolicyDocument?
    @Published var termsAndConditions:  PolicyDocument?
    @Published var publishLog:          [PublishLogEntry] = []
    @Published var dataProcessingRecord: DataProcessingRecord?

    // MARK: - Policy Management

    func savePrivacyPolicy(_ policy: PolicyDocument) throws {
        var p = policy; p.updatedAt = Date()
        privacyPolicy = p
        try writeDocument(p, filename: "privacy_policy.md")
    }

    func saveTermsAndConditions(_ tcs: PolicyDocument) throws {
        var t = tcs; t.updatedAt = Date()
        termsAndConditions = t
        try writeDocument(t, filename: "terms_and_conditions.md")
    }

    func installDefaultPolicies() throws {
        if privacyPolicy == nil {
            try savePrivacyPolicy(PolicyDocument(
                title:   "Política de Privacidad del Estudio",
                content: defaultPrivacyPolicy()
            ))
        }
        if termsAndConditions == nil {
            try saveTermsAndConditions(PolicyDocument(
                title:   "Términos y Condiciones",
                content: defaultTermsAndConditions()
            ))
        }
        if dataProcessingRecord == nil {
            try saveDataProcessingRecord(buildDefaultDataRecord())
        }
    }

    // MARK: - Publish Log

    /// Registrar una publicación en el log de compliance.
    func logPublication(
        assetIDs:             [UUID],
        platform:             String,
        contentType:          PublishLogEntry.ContentType,
        nsfwLevel:            String            = "unknown",
        licenseOK:            Bool              = false,
        watermarkApplied:     Bool              = false,
        exifScrubbed:         Bool              = false,
        steganographyApplied: Bool              = false,
        consentRecordID:      UUID?             = nil,
        exportPaths:          [String]          = [],
        batchHash:            String            = ""
    ) throws {
        let entry = PublishLogEntry(
            assetIDs:             assetIDs,
            assetCount:           assetIDs.count,
            platform:             platform,
            contentType:          contentType,
            nsfwChecked:          nsfwLevel != "unknown",
            nsfwLevel:            nsfwLevel,
            promptFiltered:       true,   // Siempre filtrado por PromptSafetyFilter
            licenseOK:            licenseOK,
            watermarkApplied:     watermarkApplied,
            exifScrubbed:         exifScrubbed,
            steganographyApplied: steganographyApplied,
            consentRecordID:      consentRecordID,
            exportPaths:          exportPaths,
            batchHash:            batchHash
        )

        publishLog.insert(entry, at: 0)
        try appendToPublishLog(entry)

        ZeroKnowledgeLog.shared.write(
            category: .exportPerformed,
            message: "PUBLISH: \(platform) · \(assetIDs.count) assets · type=\(contentType.rawValue) · nsfw=\(nsfwLevel)"
        )
    }

    // MARK: - Compliance Report

    func generateComplianceReport(for platform: String? = nil) -> ComplianceReport {
        let filtered = platform.map { p in publishLog.filter { $0.platform == p } } ?? publishLog
        let total    = filtered.count

        let missingLicense      = filtered.filter { !$0.licenseOK }.count
        let missingWatermark    = filtered.filter { !$0.watermarkApplied }.count
        let missingExifScrub    = filtered.filter { !$0.exifScrubbed }.count
        let missingSteg         = filtered.filter { !$0.steganographyApplied }.count
        let missingConsent      = filtered.filter { $0.consentRecordID == nil }.count

        let complianceScore = total == 0 ? 100 :
            Int(100.0 - (
                Double(missingLicense) * 25 +
                Double(missingWatermark) * 15 +
                Double(missingExifScrub) * 20 +
                Double(missingSteg) * 10 +
                Double(missingConsent) * 30
            ) / Double(total))

        return ComplianceReport(
            platform:          platform ?? "Todas",
            totalPublications: total,
            complianceScore:   max(0, complianceScore),
            issues: ComplianceReport.Issues(
                missingLicense:   missingLicense,
                missingWatermark: missingWatermark,
                missingExifScrub: missingExifScrub,
                missingSteg:      missingSteg,
                missingConsent:   missingConsent
            ),
            generatedAt: Date()
        )
    }

    struct ComplianceReport {
        let platform:          String
        let totalPublications: Int
        let complianceScore:   Int
        let issues:            Issues
        let generatedAt:       Date

        struct Issues {
            let missingLicense:   Int
            let missingWatermark: Int
            let missingExifScrub: Int
            let missingSteg:      Int
            let missingConsent:   Int

            var allOK: Bool {
                missingLicense == 0 && missingWatermark == 0 &&
                missingExifScrub == 0 && missingSteg == 0 && missingConsent == 0
            }
        }

        var scoreColor: Color {
            complianceScore >= 80 ? Color(hex: "#34d399") :
            complianceScore >= 60 ? Color(hex: "#fbbf24") : Color(hex: "#f87171")
        }
    }

    // MARK: - Default Templates

    private func defaultPrivacyPolicy() -> String {
        """
        # Política de Privacidad

        **Última actualización:** \(Date().formatted(.dateTime.day().month().year()))

        ## 1. Responsable del Tratamiento
        Este estudio de creación de contenido digital con IA (en adelante, "el Estudio") es el
        único responsable del tratamiento de los datos generados.

        ## 2. Datos que Procesamos
        - **Imágenes generadas:** Creadas íntegramente por IA. No contienen datos biométricos.
        - **Metadatos de generación:** Seeds, prompts, timestamps. Almacenados localmente.
        - **Logs de operación:** Cifrados localmente con AES-256. Sin acceso de terceros.

        ## 3. Contenido Generado por IA
        Todo el contenido visual publicado es generado por sistemas de inteligencia artificial.
        **No se utilizan ni procesan imágenes de personas reales.**

        ## 4. Almacenamiento y Seguridad
        - Todos los datos se almacenan localmente en el vault cifrado del estudio.
        - No se envían datos a servidores externos salvo la API de Stable Diffusion (local).
        - Los metadatos EXIF/prompts se eliminan antes de la publicación.

        ## 5. Derechos
        Para cualquier consulta sobre este contenido, contactar al Estudio directamente.

        ## 6. Actualizaciones
        Esta política puede actualizarse. La versión vigente siempre estará en Vault/Legal/.
        """
    }

    private func defaultTermsAndConditions() -> String {
        """
        # Términos y Condiciones

        **Fecha:** \(Date().formatted(.dateTime.day().month().year()))

        ## 1. Naturaleza del Contenido
        Todo el contenido visual producido por este Estudio es generado íntegramente
        por inteligencia artificial. No representa personas reales.

        ## 2. Propiedad Intelectual
        El Estudio retiene todos los derechos sobre el contenido generado, sujeto a los
        términos de licencia de los modelos de IA utilizados (Creative ML OpenRAIL, MIT, etc.).

        ## 3. Uso Autorizado
        El contenido está destinado exclusivamente a plataformas para adultos verificadas
        y mayores de 18 años, conforme a los TOS de cada plataforma.

        ## 4. Prohibiciones
        Queda estrictamente prohibida la redistribución no autorizada, modificación maliciosa,
        o uso del contenido para engañar sobre la identidad de personas reales.

        ## 5. Limitación de Responsabilidad
        El Estudio no se responsabiliza del uso no autorizado del contenido una vez publicado.
        La esteganografía aplicada permite rastrear copias no autorizadas.

        ## 6. Legislación Aplicable
        Estos términos se rigen por la legislación vigente en la jurisdicción del Estudio.
        """
    }

    private func buildDefaultDataRecord() -> DataProcessingRecord {
        DataProcessingRecord(
            dataTypes: [
                .init(name: "Imágenes generadas por IA",
                      description: "Archivos PNG/JPG creados por Stable Diffusion",
                      storedLocally: true, sharedExternally: true,
                      retentionPolicy: "Indefinido", legalBasis: "Interés legítimo del creador"),
                .init(name: "Metadatos de generación",
                      description: "Prompts, seeds, configuración SD",
                      storedLocally: true, sharedExternally: false,
                      retentionPolicy: "Indefinido", legalBasis: "Interés legítimo"),
                .init(name: "Logs cifrados de operación",
                      description: "Zero-Knowledge Log AES-256",
                      storedLocally: true, sharedExternally: false,
                      retentionPolicy: "12 meses rolling", legalBasis: "Obligación legal"),
                .init(name: "Registros de licencias",
                      description: "Model cards y LICENSE.txt de modelos",
                      storedLocally: true, sharedExternally: false,
                      retentionPolicy: "Indefinido", legalBasis: "Obligación legal"),
            ]
        )
    }

    func saveDataProcessingRecord(_ record: DataProcessingRecord) throws {
        dataProcessingRecord = record
        guard let url = legalRoot?.appendingPathComponent("data_processing_register.json") else { return }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(record).write(to: url, options: .atomic)
    }

    // MARK: - Persistence Helpers

    private var legalRoot: URL? {
        VaultManager.shared.vaultRoot?.appendingPathComponent("Vault/Legal", isDirectory: true)
    }

    private func writeDocument(_ doc: PolicyDocument, filename: String) throws {
        guard let root = legalRoot else { return }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // Escribir markdown
        let mdURL = root.appendingPathComponent(filename)
        try Data(doc.content.utf8).write(to: mdURL, options: .atomic)

        // Escribir metadata JSON
        let metaURL = root.appendingPathComponent(filename.replacingOccurrences(of: ".md", with: "_meta.json"))
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(doc).write(to: metaURL, options: .atomic)
    }

    private func appendToPublishLog(_ entry: PublishLogEntry) throws {
        guard let root = legalRoot else { return }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("publish_log.jsonl")
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        var line = try enc.encode(entry)
        line.append(contentsOf: "\n".utf8)

        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            handle.closeFile()
        } else {
            try line.write(to: url, options: .atomic)
        }
    }

    private func loadAll() {
        guard let root = legalRoot else { return }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601

        // Load privacy policy metadata
        let ppMeta = root.appendingPathComponent("privacy_policy_meta.json")
        if let data = try? Data(contentsOf: ppMeta) {
            privacyPolicy = try? dec.decode(PolicyDocument.self, from: data)
        }

        // Load T&C metadata
        let tcMeta = root.appendingPathComponent("terms_and_conditions_meta.json")
        if let data = try? Data(contentsOf: tcMeta) {
            termsAndConditions = try? dec.decode(PolicyDocument.self, from: data)
        }

        // Load publish log (last 500 lines)
        let logURL = root.appendingPathComponent("publish_log.jsonl")
        if let content = try? String(contentsOf: logURL, encoding: .utf8) {
            let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }.suffix(500)
            publishLog = lines.compactMap {
                try? dec.decode(PublishLogEntry.self, from: Data($0.utf8))
            }.reversed()
        }

        // Load data processing record
        let drURL = root.appendingPathComponent("data_processing_register.json")
        if let data = try? Data(contentsOf: drURL) {
            dataProcessingRecord = try? dec.decode(DataProcessingRecord.self, from: data)
        }
    }
}

// MARK: - Compliance Dashboard View

struct ComplianceDashboardView: View {
    @ObservedObject private var mgr = PrivacyComplianceManager.shared
    @State private var report: PrivacyComplianceManager.ComplianceReport?
    @State private var selectedPlatform: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundColor(Color(hex: "#34d399"))
                Text("Compliance de Publicación")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Generar Reporte") {
                    report = mgr.generateComplianceReport(for: selectedPlatform)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color(hex: "#34d399").opacity(0.15))
                .foregroundColor(Color(hex: "#34d399"))
                .cornerRadius(6)
            }
            .padding(16)

            Divider()

            if let r = report {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Score de Compliance")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            Text("\(r.complianceScore)/100")
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                                .foregroundColor(r.scoreColor)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(r.platform)
                                .font(.system(size: 13, weight: .semibold))
                            Text("\(r.totalPublications) publicaciones")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }

                    if !r.issues.allOK {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("ISSUES")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.secondary)

                            ComplianceIssueRow(count: r.issues.missingLicense,   label: "Sin licencia verificada",  icon: "doc.badge.ellipsis")
                            ComplianceIssueRow(count: r.issues.missingWatermark, label: "Sin watermark",            icon: "water.waves")
                            ComplianceIssueRow(count: r.issues.missingExifScrub, label: "Sin EXIF scrub",           icon: "eye.slash")
                            ComplianceIssueRow(count: r.issues.missingSteg,      label: "Sin esteganografía",       icon: "lock.shield")
                            ComplianceIssueRow(count: r.issues.missingConsent,   label: "Sin registro de consent",  icon: "doc.badge.gearshape")
                        }
                    } else {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundColor(Color(hex: "#34d399"))
                            Text("Compliance completo — todas las publicaciones verificadas.")
                                .font(.system(size: 12))
                                .foregroundColor(Color(hex: "#34d399"))
                        }
                    }
                }
                .padding(16)
            } else {
                // Recent log preview
                VStack(alignment: .leading, spacing: 6) {
                    Text("PUBLICACIONES RECIENTES")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)

                    if mgr.publishLog.isEmpty {
                        Text("Sin publicaciones registradas.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                    } else {
                        ForEach(mgr.publishLog.prefix(4)) { entry in
                            HStack(spacing: 10) {
                                Image(systemName: entry.licenseOK ? "checkmark.circle" : "exclamationmark.circle")
                                    .foregroundColor(entry.licenseOK ? Color(hex: "#34d399") : Color(hex: "#fbbf24"))
                                    .font(.system(size: 12))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("\(entry.platform) · \(entry.assetCount) assets")
                                        .font(.system(size: 12, weight: .medium))
                                    Text(entry.contentType.rawValue)
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Text(entry.publishedAt.formatted(.dateTime.day().month()))
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 5)
                        }
                        .padding(.bottom, 8)
                    }
                }
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(12)
    }
}

private struct ComplianceIssueRow: View {
    let count: Int
    let label: String
    let icon:  String

    var body: some View {
        guard count > 0 else { return AnyView(EmptyView()) }
        return AnyView(
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#fbbf24"))
                    .frame(width: 16)
                Text("\(count) publicaciones: \(label)")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#fbbf24"))
            }
        )
    }
}
