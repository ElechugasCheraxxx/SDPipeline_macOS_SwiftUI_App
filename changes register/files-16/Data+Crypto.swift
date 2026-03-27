import Foundation
import CryptoKit

// MARK: - Data + Crypto
// Helpers criptográficos sobre Data.
// Centralizado aquí para evitar redefinición en AssetStore y SteganographyEngine.

extension Data {

    /// SHA-256 del contenido como string hexadecimal lowercase.
    var sha256Hex: String {
        SHA256.hash(data: self)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
