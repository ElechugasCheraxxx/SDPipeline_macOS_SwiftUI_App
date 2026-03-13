import Foundation
import CryptoKit
import Security

// MARK: - Data_Crypto.swift (extended)
//
// El archivo ORIGINAL ya declara:
//   Data.sha256Hex   → NO redeclarar
//
// IMPORTANTE: SteganographyEngine.swift declara `enum KeychainHelper`
// con API: save(key:data:) / load(key:) / delete(key:)
// Para no colisionar, este archivo usa el nombre `VaultKeychain`
// con API distinta orientada a service/account.

// MARK: - AES-GCM Data extensions

extension Data {

    /// Cifrar con AES-GCM. Devuelve nonce (12B) + ciphertext + tag (16B) combinados.
    func encryptedAESGCM(key: SymmetricKey) throws -> Data {
        let sealed = try AES.GCM.seal(self, using: key)
        guard let combined = sealed.combined else { throw CryptoVaultError.sealFailed }
        return combined
    }

    /// Cifrar y devolver como base64 (para entradas del ZeroKnowledgeLog).
    func encryptedBase64(key: SymmetricKey) throws -> String {
        try encryptedAESGCM(key: key).base64EncodedString()
    }

    /// Descifrar AES-GCM combined (nonce + ciphertext + tag).
    func decryptedAESGCM(key: SymmetricKey) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: self)
        return try AES.GCM.open(box, using: key)
    }

    /// Descifrar desde base64.
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
// Keychain helper orientado a service+account (para ZeroKnowledgeLog, BackupManager).
// Distinto de `KeychainHelper` en SteganographyEngine que usa key: String (account-only).

struct VaultKeychain {

    // MARK: SymmetricKey persistence

    /// Cargar o generar-y-guardar una clave AES-256 para el servicio dado.
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
