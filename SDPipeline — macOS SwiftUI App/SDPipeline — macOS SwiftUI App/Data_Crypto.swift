import Foundation
import CryptoKit

// MARK: - Data + Crypto
// Helpers criptográficos sobre Data.
// Centralizado aquí para evitar redefinición en AssetStore y SteganographyEngine.
//
// REGLA DE ORO: No reimplementar SHA-256 manualmente en ningún otro archivo.
// Cualquier implementación hand-rolled produce hashes incorrectos y rompe
// la integridad del vault, SteganographyEngine y AssetStore.
// Toda la criptografía del proyecto pasa por este archivo y por CryptoKit.

extension Data {

    // MARK: - SHA-256

    /// SHA-256 del contenido como string hexadecimal lowercase (64 caracteres).
    /// Backed by Apple CryptoKit — auditado y acelerado por hardware.
    var sha256Hex: String {
        SHA256.hash(data: self)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Alias de sha256Hex para compatibilidad con código legacy y tests.
    /// Usar sha256Hex como nombre canónico en código nuevo.
    var sha256: String { sha256Hex }

    // MARK: - AES-GCM Encryption

    /// Cifra el contenido con AES-GCM.
    /// Devuelve nonce (12 bytes) + ciphertext + tag (16 bytes) combinados.
    func encryptedAESGCM(key: SymmetricKey) throws -> Data {
        let sealed = try AES.GCM.seal(self, using: key)
        guard let combined = sealed.combined else { throw CryptoVaultError.sealFailed }
        return combined
    }

    /// Cifra el contenido y devuelve el resultado como string Base64.
    /// Útil para entradas del ZeroKnowledgeLog y metadatos del vault.
    func encryptedBase64(key: SymmetricKey) throws -> String {
        try encryptedAESGCM(key: key).base64EncodedString()
    }

    // MARK: - AES-GCM Decryption

    /// Descifra datos AES-GCM en formato combined (nonce + ciphertext + tag).
    func decryptedAESGCM(key: SymmetricKey) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: self)
        return try AES.GCM.open(box, using: key)
    }

    /// Descifra un string Base64 AES-GCM.
    static func decryptedBase64(_ base64: String, key: SymmetricKey) throws -> Data {
        guard let data = Data(base64Encoded: base64) else { throw CryptoVaultError.invalidBase64 }
        return try data.decryptedAESGCM(key: key)
    }
}

// MARK: - CryptoVaultError

enum CryptoVaultError: LocalizedError {
    case sealFailed
    case invalidBase64
    case decryptionFailed
    case keychainReadFailed(OSStatus)
    case keychainWriteFailed(OSStatus)
    case keychainDeleteFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .sealFailed:                  return "AES-GCM seal failed"
        case .invalidBase64:               return "Invalid base64 input"
        case .decryptionFailed:            return "AES-GCM decryption failed"
        case .keychainReadFailed(let s):   return "Keychain read failed: OSStatus \(s)"
        case .keychainWriteFailed(let s):  return "Keychain write failed: OSStatus \(s)"
        case .keychainDeleteFailed(let s): return "Keychain delete failed: OSStatus \(s)"
        }
    }
}

// MARK: - VaultKeychain
// Keychain helper orientado a service+account (ZeroKnowledgeLog, BackupManager).
// Distinto de `KeychainHelper` en SteganographyEngine que usa key: String (account-only).

struct VaultKeychain {

    // MARK: SymmetricKey persistence

    /// Carga o genera-y-guarda una clave AES-256 para el servicio dado.
    static func symmetricKey(service: String, account: String = "sdpipeline") throws -> SymmetricKey {
        if let data = try? load(service: service, account: account) {
            return SymmetricKey(data: data)
        }
        let key     = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        try save(keyData, service: service, account: account)
        return key
    }

    static func deleteKey(service: String, account: String = "sdpipeline") throws {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CryptoVaultError.keychainDeleteFailed(status)
        }
    }

    // MARK: Generic data

    static func save(_ data: Data, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String:          kSecClassGenericPassword,
            kSecAttrService as String:    service,
            kSecAttrAccount as String:    account,
            kSecValueData as String:      data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw CryptoVaultError.keychainWriteFailed(status) }
    }

    static func load(service: String, account: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw CryptoVaultError.keychainReadFailed(status)
        }
        return data
    }

    // MARK: Service name constants

    static let zkLogService  = "com.sdpipeline.zklog"
    static let backupService = "com.sdpipeline.backup"
    static let vaultService  = "com.sdpipeline.vault"
}

// MARK: - SymmetricKey HKDF derivation

extension SymmetricKey {
    /// Deriva una clave AES-256 desde una passphrase usando HKDF-SHA256.
    static func derived(from passphrase: String, salt: Data? = nil) -> SymmetricKey {
        let ikm      = SymmetricKey(data: Data(passphrase.utf8))
        let saltData = salt ?? Data("SDPipelineStudio.v1".utf8)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            salt:             saltData,
            info:             Data("sdpipeline.aes256".utf8),
            outputByteCount:  32
        )
    }
}
