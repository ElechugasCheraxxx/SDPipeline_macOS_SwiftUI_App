import Foundation

// MARK: - SidecarJSON
// Cada imagen generada nace con un .meta.json hermano que contiene
// el "linaje" completo de la generación. Este archivo NUNCA sale del vault.
// El archivo export (limpio) NO lleva este sidecar adjunto.

struct SidecarJSON: Codable {

    // MARK: - Identidad del Asset

    let schemaVersion:  String   = "SDPipeline.Sidecar.v1"
    let baseName:       String
    let version:        Int
    let createdAt:      Date
    let imageFilename:  String   // Solo filename, no path completo (portable)
    let sha256:         String

    // MARK: - Linaje del Modelo

    let model: ModelLineage

    struct ModelLineage: Codable {
        let name:        String
        let checkpoint:  String
        let vaeUsed:     String
        let loraWeights: [String: Double]  // "lora_name": 0.8
    }

    // MARK: - Parámetros Completos de Generación

    let generation: GenerationParams

    struct GenerationParams: Codable {
        let promptPositive:   String
        let promptNegative:   String
        let seed:             Int
        let steps:            Int
        let cfgScale:         Double
        let samplerName:      String
        let width:            Int
        let height:           Int
        let batchSize:        Int

        // Hires fix
        let enableHR:         Bool
        let hrUpscaler:       String?
        let hrScale:          Double?
        let hrSecondPassSteps: Int?
        let denoisingStrength: Double?

        // Extras
        let restoreFaces:     Bool
        let tiling:           Bool
    }

    // MARK: - Metadatos de Sesión

    let session: SessionMeta

    struct SessionMeta: Codable {
        let tag:           String?    // Nombre de sesión/shoot (ej. "Beach Editorial Mar 2025")
        let appVersion:    String
        let sdVersion:     String?    // Versión de A1111 si disponible
        let machineModel:  String     // Mac model para referencia de hardware
    }

    // MARK: - Integridad y Auditoría

    let integrity: IntegrityRecord

    struct IntegrityRecord: Codable {
        let sha256Original:       String    // Hash del PNG raw de SD
        let generatedAt:          Date      // Timestamp exacto de generación
        let exportedAt:           Date?     // Cuando se exportó versión limpia
        let cleanVersionExists:   Bool
        let previewVersionExists: Bool
    }

    // MARK: - Init desde SDRequest + contexto

    init(
        baseName:    String,
        version:     Int,
        imageURL:    URL,
        request:     SDRequest,
        seed:        Int,
        modelName:   String,
        checkpoint:  String,
        vaeUsed:     String,
        loraWeights: [String: Double],
        sha256:      String,
        sessionTag:  String?,
        sdVersion:   String? = nil
    ) {
        self.baseName      = baseName
        self.version       = version
        self.createdAt     = Date()
        self.imageFilename = imageURL.lastPathComponent
        self.sha256        = sha256

        self.model = ModelLineage(
            name:        modelName,
            checkpoint:  checkpoint,
            vaeUsed:     vaeUsed,
            loraWeights: loraWeights
        )

        self.generation = GenerationParams(
            promptPositive:    request.prompt,
            promptNegative:    request.negative_prompt,
            seed:              seed,
            steps:             request.steps,
            cfgScale:          request.cfg_scale,
            samplerName:       request.sampler_name,
            width:             request.width,
            height:            request.height,
            batchSize:         request.batch_size,
            enableHR:          request.enable_hr,
            hrUpscaler:        request.hr_upscaler.isEmpty ? nil : request.hr_upscaler,
            hrScale:           request.enable_hr ? request.hr_scale : nil,
            hrSecondPassSteps: request.enable_hr ? request.hr_second_pass_steps : nil,
            denoisingStrength: request.enable_hr ? request.denoising_strength : nil,
            restoreFaces:      request.restore_faces,
            tiling:            request.tiling
        )

        self.session = SessionMeta(
            tag:          sessionTag,
            appVersion:   Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            sdVersion:    sdVersion,
            machineModel: SidecarJSON.machineName
        )

        self.integrity = IntegrityRecord(
            sha256Original:       sha256,
            generatedAt:          Date(),
            exportedAt:           nil,
            cleanVersionExists:   false,
            previewVersionExists: false
        )
    }

    // MARK: - Helpers

    /// Leer un sidecar desde disco.
    static func load(from url: URL) -> SidecarJSON? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.iso8601.decode(SidecarJSON.self, from: data)
    }

    /// Guardar sidecar a disco.
    func save(to url: URL) throws {
        let data = try JSONEncoder.pretty.encode(self)
        try data.write(to: url, options: .atomic)
    }

    /// Nombre del modelo de Mac (para referencia de hardware en auditoría).
    private static var machineName: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var machine = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &machine, &size, nil, 0)
        return String(cString: machine)
    }
}

// MARK: - JSONDecoder ISO8601

extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
