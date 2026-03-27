import Foundation

// MARK: - Codable_Helpers.swift
// Shared encoder/decoder configurations used across the codebase.

// MARK: - JSONDecoder presets

extension JSONDecoder {

    /// ISO 8601 decoder for SidecarJSON, ZeroKnowledgeLog, etc.
    static let iso8601: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        d.keyDecodingStrategy  = .useDefaultKeys
        return d
    }()

    /// Flexible decoder that tries ISO8601 then unix timestamp fallback.
    static let flexible: JSONDecoder = {
        let d = JSONDecoder()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            // Try ISO string first
            if let str = try? container.decode(String.self) {
                if let date = formatter.date(from: str) { return date }
                // Try without fractional seconds
                let f2 = ISO8601DateFormatter()
                if let date = f2.date(from: str) { return date }
            }
            // Try unix timestamp
            if let interval = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: interval)
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode date")
        }
        return d
    }()

    /// Safe decode: returns nil instead of throwing.
    static func safeDecodeISO<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? iso8601.decode(type, from: data)
    }
}

// MARK: - JSONEncoder presets

extension JSONEncoder {

    /// Pretty-print encoder for sidecar JSON files, human-readable logs.
    static let pretty: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy   = .iso8601
        e.outputFormatting       = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    /// Compact encoder for UserDefaults persistence and network payloads.
    static let compact: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting     = .withoutEscapingSlashes
        return e
    }()

    /// Encode to JSON string (convenience for logging).
    static func toJSONString<T: Encodable>(_ value: T, pretty: Bool = false) -> String? {
        let enc = pretty ? JSONEncoder.pretty : JSONEncoder.compact
        guard let data = try? enc.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Codable round-trip helpers

extension Encodable {
    /// Serialize to Data using compact encoder.
    func toJSON(pretty: Bool = false) throws -> Data {
        try (pretty ? JSONEncoder.pretty : JSONEncoder.compact).encode(self)
    }

    /// Serialize to JSON string.
    func toJSONString(pretty: Bool = false) -> String? {
        guard let data = try? toJSON(pretty: pretty) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Save to a file URL as JSON.
    func saveAsJSON(to url: URL, pretty: Bool = true) throws {
        let data = try toJSON(pretty: pretty)
        try data.write(to: url, options: .atomic)
    }
}

extension Decodable {
    /// Load from a file URL.
    static func loadFromJSON(at url: URL) -> Self? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.iso8601.decode(Self.self, from: data)
    }

    /// Decode from JSON string.
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
}

// MARK: - Dictionary → Decodable bridge
// Useful for converting [String:Any] API responses into typed structs.

extension Dictionary where Key == String {
    func decode<T: Decodable>(_ type: T.Type) -> T? {
        guard let data = try? JSONSerialization.data(withJSONObject: self) else { return nil }
        return try? JSONDecoder.iso8601.decode(type, from: data)
    }
}
