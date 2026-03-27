import Foundation

// MARK: - Codable_Helpers.swift (extended)
//
// El archivo ORIGINAL ya declara:
//   JSONEncoder.pretty    (static var, en extension JSONEncoder)
//   JSONDecoder.iso8601   (static var, en extension JSONDecoder)
//   → NO redeclarar ninguno de los dos.
//
// Este archivo añade solo lo que falta.

// MARK: - JSONEncoder extra presets

extension JSONEncoder {

    /// Encoder compacto (una línea), fechas ISO8601. Para UserDefaults y payloads de red.
    static var compact: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting     = .withoutEscapingSlashes
        return e
    }
}

// MARK: - JSONDecoder extra presets

extension JSONDecoder {

    /// Decodificador flexible: intenta ISO8601 con y sin fracciones, luego Unix timestamp.
    static var flexible: JSONDecoder {
        let d = JSONDecoder()
        let fFull  = ISO8601DateFormatter()
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
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Cannot decode date")
        }
        return d
    }
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

// MARK: - UserDefaults Codable helpers

extension UserDefaults {

    func encode<T: Encodable>(_ value: T, forKey key: String) {
        guard let data = try? JSONEncoder.compact.encode(value) else { return }
        set(data, forKey: key)
    }

    func decode<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = data(forKey: key) else { return nil }
        return try? JSONDecoder.iso8601.decode(type, from: data)
    }

    func setDate(_ date: Date?, forKey key: String) {
        if let date { set(date.timeIntervalSince1970, forKey: key) }
        else        { removeObject(forKey: key) }
    }

    func date(forKey key: String) -> Date? {
        let t = double(forKey: key)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }
}

// MARK: - Dictionary → Decodable bridge

extension Dictionary where Key == String {
    func decoded<T: Decodable>(_ type: T.Type) -> T? {
        guard let data = try? JSONSerialization.data(withJSONObject: self) else { return nil }
        return try? JSONDecoder.iso8601.decode(type, from: data)
    }
}
