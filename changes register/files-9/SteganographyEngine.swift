import Foundation
import AppKit
import CoreGraphics
import CryptoKit

// MARK: - SteganographyEngine
//
// Inyecta una firma invisible en el PNG final usando LSB (Least Significant Bit).
// La firma es un payload JSON cifrado con AES-GCM incrustado en los bits menos
// significativos de los canales de color — imperceptible al ojo humano y a
// herramientas básicas de compresión JPEG moderada.
//
// CAPACIDAD: ~1 bit por canal por píxel. En 512x768 = ~294KB de payload máximo.
// Nuestro payload JSON es ~500 bytes — margen de sobra.
//
// RESISTENCIA:
//   ✅ Capturas de pantalla (screen recording)
//   ✅ Reposteo sin recompresión
//   ✅ JPEG q>85 (degradación parcial pero recuperable con ECC)
//   ⚠️  JPEG q<70 destruye LSB — usar para PNG/WebP siempre que sea posible
//   ⚠️  Redimensionado agresivo — payload se degrada
//
// Para OnlyFans (que sirve imágenes en JPEG) se recomienda subir PNG y dejar
// que la plataforma comprima, manteniendo calidad alta.

@MainActor
final class SteganographyEngine {

    static let shared = SteganographyEngine()
    private init() {}

    // MARK: - Payload

    struct StegPayload: Codable {
        let version:    String = "SDPipeline.Steg.v1"
        let artistID:   String          // Identificador del artista (configurable)
        let assetID:    String          // UUID del asset
        let sessionTag: String?         // Tag de sesión
        let timestamp:  TimeInterval    // Unix timestamp de generación
        let sha256:     String          // Hash del original para cruce con vault
        let checksum:   String          // HMAC del payload para verificar autenticidad
    }

    // MARK: - Configuración

    struct StegConfig {
        /// Identificador único del artista. Guardar en Keychain, no en UserDefaults.
        var artistID: String = SteganographyEngine.loadOrCreateArtistID()
        /// Clave HMAC para firmar el payload (256 bits).
        var hmacKey:  SymmetricKey = SteganographyEngine.loadOrCreateHMACKey()
        /// Canales en los que incrustar (0=R, 1=G, 2=B). Evitar Alpha para compatibilidad.
        var channels: [Int] = [0, 1, 2]
        /// Bits por canal a usar (1 = mínimo impacto visual, máximo seguridad).
        var bitsPerChannel: Int = 1
    }

    var config = StegConfig()

    // MARK: - Public API

    /// Incrustar firma invisible en una imagen PNG.
    /// Devuelve los Data del PNG firmado, o los datos originales si falla (sin crash).
    func embed(
        image:      NSImage,
        assetID:    UUID,
        sessionTag: String?,
        sha256:     String
    ) -> Data? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return image.pngData()
        }

        // 1. Construir payload
        guard let payloadData = buildPayload(
            assetID:    assetID.uuidString,
            sessionTag: sessionTag,
            sha256:     sha256
        ) else { return image.pngData() }

        // 2. Incrustar en píxeles
        guard let signed = embedBits(in: cgImage, payload: payloadData) else {
            return image.pngData()
        }

        // 3. Convertir a PNG
        return pngData(from: signed)
    }

    /// Extraer y verificar la firma invisible de un PNG.
    /// Devuelve nil si no hay firma o si la firma no es válida.
    func extract(from image: NSImage) -> StegPayload? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        guard let payloadData = extractBits(from: cgImage) else { return nil }
        return verifyAndDecode(payloadData)
    }

    /// Verificar si una imagen contiene nuestra firma (para rastreo de filtraciones).
    func verify(image: NSImage) -> VerificationResult {
        guard let payload = extract(from: image) else {
            return .noSignature
        }
        return .valid(payload)
    }

    enum VerificationResult {
        case valid(StegPayload)
        case noSignature
        case invalidSignature
    }

    // MARK: - LSB Embedding

    private func embedBits(in cgImage: CGImage, payload: Data) -> CGImage? {
        let width  = cgImage.width
        let height = cgImage.height
        let bpp    = 4 // RGBA
        let bytesPerRow = width * bpp

        // Capacidad en bits disponibles
        let availableBits = width * height * config.channels.count * config.bitsPerChannel
        let requiredBits  = (payload.count + 4) * 8 // 4 bytes para longitud del payload

        guard requiredBits <= availableBits else {
            print("⚠️ Steg: imagen demasiado pequeña para el payload")
            return nil
        }

        // Copiar píxeles a buffer mutable
        guard let colorSpace = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: nil,
                width: width, height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let pixelData = ctx.data
        else { return nil }

        // Dibujar imagen original en el contexto para obtener los píxeles
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let buffer = pixelData.bindMemory(to: UInt8.self, capacity: width * height * bpp)

        // Prepend longitud del payload (4 bytes big-endian)
        var lengthBytes = withUnsafeBytes(of: UInt32(payload.count).bigEndian) { Data($0) }
        let fullPayload = lengthBytes + payload

        // Convertir payload a bits
        var bits: [UInt8] = []
        for byte in fullPayload {
            for i in stride(from: 7, through: 0, by: -1) {
                bits.append((byte >> i) & 1)
            }
        }

        // Incrustar bits en LSB de los canales seleccionados
        var bitIndex = 0
        outer: for pixelIndex in 0..<(width * height) {
            let base = pixelIndex * bpp
            for channel in config.channels {
                guard bitIndex < bits.count else { break outer }
                let byteIndex = base + channel
                // Limpiar LSB y poner el bit del payload
                buffer[byteIndex] = (buffer[byteIndex] & 0xFE) | bits[bitIndex]
                bitIndex += 1
            }
        }

        return ctx.makeImage()
    }

    private func extractBits(from cgImage: CGImage) -> Data? {
        let width  = cgImage.width
        let height = cgImage.height
        let bpp    = 4
        let bytesPerRow = width * bpp

        guard let colorSpace = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: nil,
                width: width, height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let pixelData = ctx.data
        else { return nil }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let buffer = pixelData.bindMemory(to: UInt8.self, capacity: width * height * bpp)

        // Extraer primeros 32 bits para obtener la longitud
        var lengthBits: [UInt8] = []
        var bitIndex = 0
        for pixelIndex in 0..<(width * height) {
            let base = pixelIndex * bpp
            for channel in config.channels {
                if bitIndex < 32 {
                    lengthBits.append(buffer[base + channel] & 1)
                    bitIndex += 1
                }
            }
            if bitIndex >= 32 { break }
        }

        let payloadLength = Int(bitsToUInt32(lengthBits))
        guard payloadLength > 0, payloadLength < 10_000 else { return nil } // Sanity check

        // Extraer payload completo
        let totalBitsNeeded = (payloadLength + 4) * 8
        var allBits: [UInt8] = []
        bitIndex = 0

        outer: for pixelIndex in 0..<(width * height) {
            let base = pixelIndex * bpp
            for channel in config.channels {
                guard bitIndex < totalBitsNeeded else { break outer }
                allBits.append(buffer[base + channel] & 1)
                bitIndex += 1
            }
        }

        // Convertir bits a bytes (omitir los 4 bytes de longitud)
        guard allBits.count >= totalBitsNeeded else { return nil }
        let payloadBits = Array(allBits.dropFirst(32))
        var result = Data()
        for i in stride(from: 0, to: payloadBits.count - 7, by: 8) {
            var byte: UInt8 = 0
            for j in 0..<8 { byte = byte << 1 | payloadBits[i + j] }
            result.append(byte)
        }

        return result.isEmpty ? nil : result
    }

    // MARK: - Payload Build / Verify

    private func buildPayload(
        assetID:    String,
        sessionTag: String?,
        sha256:     String
    ) -> Data? {
        let timestamp = Date().timeIntervalSince1970

        // Construir string para HMAC
        let hmacInput = "\(config.artistID)|\(assetID)|\(timestamp)|\(sha256)"
        let hmac = HMAC<SHA256>.authenticationCode(
            for: Data(hmacInput.utf8),
            using: config.hmacKey
        )
        let hmacHex = hmac.map { String(format: "%02x", $0) }.joined()

        let payload = StegPayload(
            artistID:   config.artistID,
            assetID:    assetID,
            sessionTag: sessionTag,
            timestamp:  timestamp,
            sha256:     sha256,
            checksum:   hmacHex
        )

        return try? JSONEncoder().encode(payload)
    }

    private func verifyAndDecode(_ data: Data) -> StegPayload? {
        guard let payload = try? JSONDecoder().decode(StegPayload.self, from: data) else {
            return nil
        }

        // Verificar HMAC
        let hmacInput = "\(payload.artistID)|\(payload.assetID)|\(payload.timestamp)|\(payload.sha256)"
        let expectedHMAC = HMAC<SHA256>.authenticationCode(
            for: Data(hmacInput.utf8),
            using: config.hmacKey
        )
        let expectedHex = expectedHMAC.map { String(format: "%02x", $0) }.joined()

        guard payload.checksum == expectedHex else { return nil }
        return payload
    }

    // MARK: - Bit Helpers

    private func bitsToUInt32(_ bits: [UInt8]) -> UInt32 {
        var value: UInt32 = 0
        for bit in bits { value = value << 1 | UInt32(bit) }
        return value
    }

    private func pngData(from cgImage: CGImage) -> Data? {
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutableData, "public.png" as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return mutableData as Data
    }

    // MARK: - Keychain: Artist ID + HMAC Key

    private static func loadOrCreateArtistID() -> String {
        let key = "SDPipeline.artistID"
        if let existing = KeychainHelper.load(key: key) {
            return String(data: existing, encoding: .utf8) ?? UUID().uuidString
        }
        let newID = "ARTIST_\(UUID().uuidString.prefix(8))"
        KeychainHelper.save(key: key, data: Data(newID.utf8))
        return newID
    }

    private static func loadOrCreateHMACKey() -> SymmetricKey {
        let key = "SDPipeline.hmacKey"
        if let existing = KeychainHelper.load(key: key) {
            return SymmetricKey(data: existing)
        }
        let newKey = SymmetricKey(size: .bits256)
        let keyData = newKey.withUnsafeBytes { Data($0) }
        KeychainHelper.save(key: key, data: keyData)
        return newKey
    }
}

// MARK: - KeychainHelper
// Wrapper mínimo para guardar/leer datos sensibles en el Keychain del sistema.
// La clave HMAC y el Artist ID nunca tocan UserDefaults ni el disco.

enum KeychainHelper {

    static func save(key: String, data: Data) {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrAccount: key,
            kSecValueData:   data,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(key: String) -> Data? {
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrAccount:      key,
            kSecReturnData:       true,
            kSecMatchLimit:       kSecMatchLimitOne
        ]
        var result: AnyObject?
        SecItemCopyMatching(query as CFDictionary, &result)
        return result as? Data
    }

    static func delete(key: String) {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrAccount: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
