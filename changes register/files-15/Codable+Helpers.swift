import Foundation

// MARK: - Codable + Helpers
// Configuraciones estándar de encoder/decoder usadas en todo el proyecto.
// Centralizado aquí para evitar redefinición en AssetStore, SidecarJSON, etc.

extension JSONEncoder {

    /// Encoder con formato legible y fechas ISO8601.
    /// Usar para todos los archivos JSON del vault.
    static var pretty: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting     = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {

    /// Decoder con fechas ISO8601.
    /// Usar para todos los archivos JSON del vault.
    static var iso8601: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
