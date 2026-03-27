import Foundation

// MARK: - Codable_Helpers.swift
// El archivo ORIGINAL no existe (era 16 líneas vacías).
// Se declara completo aquí sin riesgo de redeclaración.

// MARK: - JSONDecoder presets

extension JSONDecoder {

    static let iso8601: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Decodificador flexible: intenta ISO8601 (con y sin fracciones) y luego Unix timestamp.
    static let flexible: JSONDecoder = {
        let d = JSONDecoder()
        let fFull = ISO8601DateFormatter()
        fFull.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fBasic = ISO8601DateFormatter()
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let str = try? container.decode(String.self) {
                if let date = fFull.date(from: str)  { return date }
                if let date = fBasic.date(from: str) { return date }
            }
            if let interval = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: interval)
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode date")
        }
        return d
    }()
}

// MARK: - JSONEncoder presets

extension JSONEncoder {

    static let pretty: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting    = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    static let compact: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting    = .withoutEscapingSlashes
        return e
    }()
}

// MARK: - Encodable convenience

extension Encodable {

    func toJSON(pretty: Bool = false) throws -> Data {
        try (pretty ? JSONEncoder.pretty : JSONEncoder.compact).encode(self)
    }

    func toJSONString(pretty: Bool = false) -> String? {
        guard let data = try? toJSON(pretty: pretty) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func saveAsJSON(to url: URL, pretty: Bool = true) throws {
        try toJSON(pretty: pretty).write(to: url, options: .atomic)
    }
}

// MARK: - Decodable convenience

extension Decodable {

    static func loadFromJSON(at url: URL) -> Self? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.iso8601.decode(Self.self, from: data)
    }

    static func from(jsonString: String) -> Self? {
        guard let data = jsonString.data(using: .utf8) else { return nil }
        return try? JSONDecoder.iso8601.decode(Self.self, from: data)
    }
}

// MARK: - UserDefaults typed helpers
// (encode/decode están declarados en Models_Extended.swift)
// Aquí solo se añade el helper de fecha que NO está en Models_Extended.

// MARK: - Dictionary → Decodable bridge

extension Dictionary where Key == String {
    func decoded<T: Decodable>(_ type: T.Type) -> T? {
        guard let data = try? JSONSerialization.data(withJSONObject: self) else { return nil }
        return try? JSONDecoder.iso8601.decode(type, from: data)
    }
}
