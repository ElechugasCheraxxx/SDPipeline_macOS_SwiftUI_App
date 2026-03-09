import Foundation
import AppKit
import SwiftUI
import Combine

// MARK: - LicenseVault
//
// Gestiona el vault legal del estudio:
//   1. Registro automático de model_card + licencia por checkpoint
//   2. Repositorio de LICENSE.txt de cada modelo descargado
//   3. Plantillas de consentimiento para publicación
//   4. Compliance docs para OnlyFans / plataformas adultos
//
// Toda la información se guarda en Vault/Licencias/ con estructura auditeable.

@MainActor
final class LicenseVault: ObservableObject {

    static let shared = LicenseVault()
    private init() {}

    // MARK: - Model Card

    struct ModelCard: Codable, Identifiable {
        var id:              UUID    = UUID()
        var registeredAt:    Date    = Date()

        // Identificación del modelo
        var checkpointName:  String           // Nombre del archivo .safetensors
        var modelVersion:    String           // v1.5, SDXL, etc.
        var baseModel:       String           // SD 1.5 / SDXL / Flux / etc.
        var source:          ModelSource
        var sourceURL:       String?          // URL de descarga (CivitAI, HuggingFace)

        // Licencia
        var licenseType:     LicenseType
        var licenseURL:      String?
        var commercialUse:   CommercialUseStatus
        var creditRequired:  Bool
        var modificationsOK: Bool
        var sharingOK:       Bool
        var nsfw:            Bool             // El modelo permite contenido adulto
        var notes:           String?

        // Captura de licencia (fecha en que se leyó — las licencias cambian)
        var licenseSnapshotDate: Date = Date()
        var licenseSnapshotPath: String?      // Ruta al .txt guardado

        enum ModelSource: String, Codable, CaseIterable {
            case civitai      = "CivitAI"
            case huggingface  = "HuggingFace"
            case stabilityai  = "Stability AI"
            case custom       = "Entrenamiento propio"
            case other        = "Otro"
        }

        enum LicenseType: String, Codable, CaseIterable {
            case creativeml_openrail   = "CreativeML OpenRAIL-M"
            case creativeml_openrail_plus = "CreativeML OpenRAIL++"
            case apache2               = "Apache 2.0"
            case mit                   = "MIT"
            case cc_by                 = "CC BY 4.0"
            case cc_by_nc              = "CC BY-NC 4.0"
            case commercial_restricted = "Commercial Restricted"
            case proprietary           = "Propietaria"
            case unknown               = "Desconocida — revisar antes de monetizar"
        }

        enum CommercialUseStatus: String, Codable, CaseIterable {
            case allowed           = "Permitido"
            case allowed_with_attr = "Permitido con atribución"
            case restricted        = "Restringido — verificar términos"
            case prohibited        = "Prohibido"
            case unknown           = "Desconocido — NO usar comercialmente hasta verificar"
        }

        // Semáforo rápido de si es seguro monetizar
        var monetizationSafe: Bool {
            switch commercialUse {
            case .allowed, .allowed_with_attr: return true
            default: return false
            }
        }
    }

    // MARK: - Public API

    /// Verificar si un checkpoint ya tiene model_card registrado.
    func isRegistered(checkpoint: String) -> Bool {
        if case .notRegistered = checkCompliance(checkpointName: checkpoint) { return false }
        return true
    }

    /// Registrar un nuevo modelo en el vault legal.
    @discardableResult
    func registerModel(_ card: ModelCard) -> Bool {
        guard let dir = VaultManager.shared.licenciasURL else { return false }

        let filename = sanitizeFilename(card.checkpointName) + ".model_card.json"
        let fileURL  = dir.appending(path: filename)

        do {
            let data = try JSONEncoder.pretty.encode(card)
            try data.write(to: fileURL, options: .atomic)
            // Guardar snapshot de licencia si hay URL
            saveModelCardSnapshot(card: card, dir: dir)
            return true
        } catch {
            print("⚠️ LicenseVault: error guardando model card: \(error)")
            return false
        }
    }

    /// Cargar todos los model cards registrados.
    func loadAllModelCards() -> [ModelCard] {
        guard let dir = VaultManager.shared.licenciasURL else { return [] }

        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return [] }

        return files
            .filter { $0.lastPathComponent.hasSuffix(".model_card.json") }
            .compactMap { url -> ModelCard? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder.iso8601.decode(ModelCard.self, from: data)
            }
            .sorted { $0.registeredAt > $1.registeredAt }
    }

    /// Verificar si un checkpoint tiene licencia registrada y permite uso comercial.
    func checkCompliance(checkpointName: String) -> ComplianceStatus {
        let cards = loadAllModelCards()
        guard let card = cards.first(where: {
            $0.checkpointName.lowercased() == checkpointName.lowercased()
        }) else {
            return .notRegistered(checkpointName)
        }

        if !card.monetizationSafe {
            return .blocked(card, reason: "Licencia '\(card.licenseType.rawValue)' no permite uso comercial")
        }

        // Advertir si la snapshot de licencia tiene más de 90 días
        let daysSinceSnapshot = Calendar.current.dateComponents(
            [.day], from: card.licenseSnapshotDate, to: Date()
        ).day ?? 0

        if daysSinceSnapshot > 90 {
            return .warning(card, "La licencia fue verificada hace \(daysSinceSnapshot) días. Stability AI y otros proveedores actualizan condiciones. Recomendado re-verificar.")
        }

        return .compliant(card)
    }

    enum ComplianceStatus {
        case compliant(ModelCard)
        case warning(ModelCard, String)
        case blocked(ModelCard, reason: String)
        case notRegistered(String)

        var isUsable: Bool {
            switch self {
            case .compliant, .warning: return true
            default: return false
            }
        }

        var alertMessage: String? {
            switch self {
            case .compliant:                  return nil
            case .warning(_, let msg):        return "⚠️ \(msg)"
            case .blocked(_, let reason):     return "🚫 \(reason)"
            case .notRegistered(let name):    return "❓ '\(name)' no tiene licencia registrada en el vault. Verifica antes de monetizar."
            }
        }
    }

    // MARK: - LICENSE.txt Management

    /// Guardar el contenido de una licencia como snapshot de texto.
    func saveLicenseSnapshot(
        checkpointName: String,
        licenseText:    String
    ) -> URL? {
        guard let dir = VaultManager.shared.licenciasURL else { return nil }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let dateStr  = formatter.string(from: Date())
        let filename = "\(sanitizeFilename(checkpointName))_LICENSE_\(dateStr).txt"
        let fileURL  = dir.appending(path: filename)

        try? licenseText.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    // MARK: - Consent Templates

    enum ConsentTemplateType: String, CaseIterable {
        case onlyfansPublication  = "Publicación en OnlyFans"
        case contentRelease       = "Content Release General"
        case aiGeneratedDisclaimer = "Disclaimer — Contenido Generado por IA"
        case privacyPolicy        = "Política de Privacidad (Fans)"

        var filename: String { rawValue.replacingOccurrences(of: " ", with: "_") + ".txt" }
    }

    /// Generar y guardar plantilla de consentimiento en el vault.
    func generateConsentTemplate(_ type: ConsentTemplateType) -> URL? {
        guard let dir = VaultManager.shared.licenciasURL else { return nil }

        let content = templateContent(for: type)
        let fileURL  = dir.appending(path: type.filename)

        try? content.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    /// Generar todas las plantillas de una vez (primer arranque del vault legal).
    func generateAllTemplates() {
        ConsentTemplateType.allCases.forEach { _ = generateConsentTemplate($0) }
    }

    /// Abrir el vault legal en Finder para revisión manual.
    func openLicensesInFinder() {
        guard let url = VaultManager.shared.licenciasURL else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Private Helpers

    private func saveModelCardSnapshot(card: ModelCard, dir: URL) {
        guard let licenseURL = card.licenseURL,
              let url = URL(string: licenseURL)
        else { return }

        // Intentar descargar la licencia para guardar snapshot
        // (operación best-effort, no bloqueante)
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let text = String(data: data, encoding: .utf8)
            else { return }

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            let filename = "\(sanitizeFilename(card.checkpointName))_LICENSE_\(formatter.string(from: Date())).txt"
            try? text.write(
                to: dir.appending(path: filename),
                atomically: true, encoding: .utf8
            )
        }
    }

    private func sanitizeFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return name.components(separatedBy: invalid).joined(separator: "_")
    }

    // MARK: - Consent Template Content

    private func templateContent(for type: ConsentTemplateType) -> String {
        let date = DateFormatter.localizedString(from: Date(), dateStyle: .long, timeStyle: .none)

        switch type {

        case .onlyfansPublication:
            return """
            CONTENT PUBLICATION RELEASE — ONLYFANS
            =======================================
            Fecha / Date: \(date)
            Artista / Artist: [TU_NOMBRE_ARTÍSTICO]
            Plataforma / Platform: OnlyFans

            DECLARACIÓN:
            El/la suscriptor/a acepta que el contenido publicado en este perfil es:
            1. Generado íntegramente por Inteligencia Artificial (Stable Diffusion).
            2. No representa a ninguna persona real, viva o fallecida.
            3. Todo el contenido de temática adulta es producido bajo las condiciones
               de uso de la plataforma OnlyFans (Terms of Service vigentes).
            4. El artista certifica tener 18+ años de edad.
            5. Ningún menor de edad aparece ni es representado en ningún contenido.

            NOTAS LEGALES:
            - Los modelos de IA utilizados cuentan con licencias de uso comercial
              verificadas y registradas en el vault legal privado del artista.
            - Todo el contenido está protegido por marca de agua digital (visible
              e invisible) y registro de procedencia criptográfica.

            [FIRMA DEL ARTISTA]                    [FECHA]
            ___________________________            ___________
            """

        case .contentRelease:
            return """
            CONTENT RELEASE — AI GENERATED MEDIA
            =====================================
            Fecha / Date: \(date)

            Este documento certifica que todo el contenido visual producido bajo
            el proyecto [NOMBRE_DEL_PROYECTO] es:

            1. GENERADO POR IA: Producido con Stable Diffusion y modelos de
               aprendizaje automático. No contiene fotografías de personas reales.

            2. PROPIEDAD INTELECTUAL: El artista [TU_NOMBRE] retiene todos los
               derechos sobre el output generado, sujeto a las licencias de los
               modelos base utilizados (ver Vault/Licencias/ para registros).

            3. USO COMERCIAL: Los modelos y checkpoints utilizados cuentan con
               autorización verificada para uso comercial (ver model_card asociado).

            4. PROTECCIÓN: Cada imagen contiene firma digital invisible (esteganografía)
               que permite rastrear el origen en caso de distribución no autorizada.

            [ARTISTA]                              [FECHA]
            ___________________________            ___________
            """

        case .aiGeneratedDisclaimer:
            return """
            DISCLAIMER — CONTENIDO GENERADO POR INTELIGENCIA ARTIFICIAL
            =============================================================
            Fecha / Date: \(date)

            TODO EL CONTENIDO DE ESTE PERFIL ES GENERADO POR IA.

            • Las imágenes son producidas con Stable Diffusion (IA generativa).
            • NO representan a personas reales.
            • Son obras de arte digital creadas por el artista usando herramientas
              de inteligencia artificial.
            • Ninguna imagen contiene material ilegal ni involucra menores de edad.
            • El contenido cumple con los Términos de Servicio de OnlyFans.

            AI-GENERATED CONTENT NOTICE:
            All content on this profile is created using AI image generation tools.
            No real persons are depicted. All characters are fictional.
            """

        case .privacyPolicy:
            return """
            POLÍTICA DE PRIVACIDAD — PERFIL DE CONTENIDO IA
            ================================================
            Última actualización: \(date)
            Artista: [TU_NOMBRE_ARTÍSTICO]

            1. DATOS QUE NO RECOPILAMOS
               No recopilamos datos personales de suscriptores más allá de los
               proporcionados voluntariamente a través de OnlyFans.

            2. CONTENIDO
               Todo el contenido es generado por IA. Las "modelos" son personajes
               ficticios sin identidad real.

            3. PROTECCIÓN DE CONTENIDO
               El contenido está protegido por marcas de agua visibles e invisibles.
               Copiar, redistribuir o revender el contenido sin autorización está
               prohibido y puede ser rastreado criptográficamente.

            4. CONTACTO
               Para consultas sobre uso del contenido: [TU_EMAIL_CONTACTO]

            5. JURISDICCIÓN
               Esta política se rige por las leyes de [TU_PAÍS].
            """
        }
    }
}

// MARK: - LicenseVault UI Helper

extension LicenseVault.ModelCard {
    /// Badge de color para mostrar en la UI según estado de cumplimiento.
    var complianceBadgeColor: String {
        switch commercialUse {
        case .allowed:           return "green"
        case .allowed_with_attr: return "yellow"
        case .restricted:        return "orange"
        case .prohibited:        return "red"
        case .unknown:           return "gray"
        }
    }
}
