import Foundation
import CryptoKit
import Security

// MARK: - Data_Crypto.swift
// AES-GCM encryption/decryption + Keychain helpers for:
//   - ZeroKnowledgeLog (per-entry encrypted JSONL)
//   - VaultManager (optional vault encryption layer)
//   - BackupManager (encrypted backup archives)

// MARK: - AES-GCM Data extensions

extension Data {

    // MARK: Encrypt

    /// Encrypt with AES-GCM. Returns nonce (12 bytes) + ciphertext + tag (16 bytes) combined.
    func encryptedAESGCM(key: SymmetricKey) throws -> Data {
        let sealed = try AES.GCM.seal(self, using: key)
        guard let combined = sealed.combined else {
            throw CryptoError.sealFailed
        }
        return combined
    }

    /// Encrypt and return as base64 string (for JSONL log entries).
    func encryptedBase64(key: SymmetricKey) throws -> String {
        try encryptedAESGCM(key: key).base64EncodedString()
    }

    // MARK: Decrypt

    /// Decrypt AES-GCM combined data (nonce + ciphertext + tag).
    func decryptedAESGCM(key: SymmetricKey) throws -> Data {
        let sealedBox = try AES.GCM.SealedBox(combined: self)
        return try AES.GCM.open(sealedBox, using: key)
    }

    /// Decrypt from base64 string.
    static func decryptedBase64(_ base64: String, key: SymmetricKey) throws -> Data {
        guard let data = Data(base64Encoded: base64) else {
            throw CryptoError.invalidBase64
        }
        return try data.decryptedAESGCM(key: key)
    }
}

// MARK: - CryptoError

enum CryptoError: LocalizedError {
    case sealFailed
    case invalidBase64
    case decryptionFailed
    case keyGenerationFailed
    case keychainReadFailed(OSStatus)
    case keychainWriteFailed(OSStatus)
    case keychainDeleteFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .sealFailed:                  return "AES-GCM seal failed"
        case .invalidBase64:               return "Invalid base64 input"
        case .decryptionFailed:            return "AES-GCM decryption failed"
        case .keyGenerationFailed:         return "Failed to generate symmetric key"
        case .keychainReadFailed(let s):   return "Keychain read failed: \(s)"
        case .keychainWriteFailed(let s):  return "Keychain write failed: \(s)"
        case .keychainDeleteFailed(let s): return "Keychain delete failed: \(s)"
        }
    }
}

// MARK: - KeychainHelper

struct KeychainHelper {

    // MARK: SymmetricKey persistence

    /// Load or generate-and-store a 256-bit AES key for a given service identifier.
    static func symmetricKey(service: String, account: String = "sdpipeline") throws -> SymmetricKey {
        // Try loading existing key
        if let data = try? load(service: service, account: account) {
            return SymmetricKey(data: data)
        }
        // Generate new key and save
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        try save(keyData, service: service, account: account)
        return key
    }

    /// Delete a stored key (e.g., for vault reset).
    static func deleteKey(service: String, account: String = "sdpipeline") throws {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CryptoError.keychainDeleteFailed(status)
        }
    }

    // MARK: Generic data storage

    static func save(_ data: Data, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      service,
            kSecAttrAccount as String:      account,
            kSecValueData as String:        data,
            kSecAttrAccessible as String:   kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        // Delete existing first
        SecItemDelete(query as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CryptoError.keychainWriteFailed(status)
        }
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
            throw CryptoError.keychainReadFailed(status)
        }
        return data
    }
}

// MARK: - Key derivation from passphrase (PBKDF2)

extension SymmetricKey {

    /// Derive a 256-bit key from a passphrase + salt using HKDF.
    static func derived(from passphrase: String, salt: Data? = nil) -> SymmetricKey {
        let inputKeyMaterial = SymmetricKey(data: Data(passphrase.utf8))
        let saltData = salt ?? Data("SDPipelineStudio.v1".utf8)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKeyMaterial,
            salt: saltData,
            info: Data("sdpipeline.aes256".utf8),
            outputByteCount: 32
        )
    }
}

// MARK: - Predefined service keys

extension KeychainHelper {
    /// Key used by ZeroKnowledgeLog
    static let zkLogService   = "com.sdpipeline.zklog"
    /// Key used for backup archive encryption
    static let backupService  = "com.sdpipeline.backup"
    /// Key used for optional vault file encryption
    static let vaultService   = "com.sdpipeline.vault"
}
