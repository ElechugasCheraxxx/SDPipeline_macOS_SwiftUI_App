import Foundation
import CryptoKit
import Security
import AppKit
import Combine

// MARK: - VaultCryptoEngine
//
// Motor de cifrado AES-256-GCM para el vault del studio.
// Implementa:
//   • Cifrado de imágenes privadas (versión en vault, no la exportada)
//   • Cifrado de prompts sensibles en Core Data
//   • Cifrado de perfiles de personajes
//   • Gestión de claves via Keychain (no UserDefaults)
//   • Rotación de claves con re-cifrado en background
//
// La versión EXPORTADA (limpia) nunca se cifra — sale lista para publicar.
// Solo los assets del vault (Generaciones/, MasterPicks/, Vault/) se cifran.
//
// ROADMAP: Directorios raíz cifrados tipo Vault (🔴 INMEDIATO)
//          Encriptación de imágenes y prompts (🟠 CORTO PLAZO)

@MainActor
final class VaultCryptoEngine: ObservableObject {

    static let shared = VaultCryptoEngine()
    private init() { _ = vaultKey }

    // MARK: - Published State

    @Published var isEncryptionEnabled: Bool = true
    @Published var encryptionStatus:    String = "Activo"
    @Published var lastKeyRotation:     Date? = nil

    // MARK: - Keychain Keys

    private enum KeychainTag {
        static let vaultKey   = "studio.vault.aes256gcm.key"
        static let promptKey  = "studio.prompt.aes256gcm.key"
        static let backupKey  = "studio.backup.aes256gcm.key"
    }

    // MARK: - Key Management

    /// Clave principal del vault (AES-256-GCM, 256 bits).
    /// Se genera una vez y se persiste en Keychain.
    var vaultKey: SymmetricKey {
        if let existing = loadKey(tag: KeychainTag.vaultKey) { return existing }
        let fresh = SymmetricKey(size: .bits256)
        storeKey(fresh, tag: KeychainTag.vaultKey)
        return fresh
    }

    var promptKey: SymmetricKey {
        if let existing = loadKey(tag: KeychainTag.promptKey) { return existing }
        let fresh = SymmetricKey(size: .bits256)
        storeKey(fresh, tag: KeychainTag.promptKey)
        return fresh
    }

    var backupKey: SymmetricKey {
        if let existing = loadKey(tag: KeychainTag.backupKey) { return existing }
        let fresh = SymmetricKey(size: .bits256)
        storeKey(fresh, tag: KeychainTag.backupKey)
        return fresh
    }

    // MARK: - Encrypt / Decrypt Data

    /// Cifra datos arbitrarios con AES-256-GCM.
    /// El nonce (12 bytes) se antepone al ciphertext para facilitar el decrypt.
    func encrypt(_ plaintext: Data, using key: SymmetricKey = VaultCryptoEngine.shared.vaultKey) throws -> Data {
        let sealedBox = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealedBox.combined else {
            throw CryptoError.sealingFailed
        }
        return combined
    }

    func decrypt(_ ciphertext: Data, using key: SymmetricKey = VaultCryptoEngine.shared.vaultKey) throws -> Data {
        let sealedBox = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(sealedBox, using: key)
    }

    // MARK: - Encrypt / Decrypt Files

    /// Cifra un archivo en disco y devuelve la URL del archivo cifrado (.enc).
    @discardableResult
    func encryptFile(at url: URL, deleteOriginal: Bool = true) async throws -> URL {
        let plaintext = try Data(contentsOf: url)
        let encrypted = try encrypt(plaintext)
        let encURL    = url.appendingPathExtension("enc")
        try encrypted.write(to: encURL, options: .atomic)
        if deleteOriginal { try? FileManager.default.removeItem(at: url) }
        return encURL
    }

    /// Descifra un .enc en memoria sin escribir el plaintext a disco.
    func decryptFileToMemory(at encURL: URL) async throws -> Data {
        let ciphertext = try Data(contentsOf: encURL)
        return try decrypt(ciphertext)
    }

    /// Descifra un .enc a un archivo temporal para visualización.
    func decryptFileToTemp(at encURL: URL) async throws -> URL {
        let plaintext = try await decryptFileToMemory(at: encURL)
        let tmpURL    = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(encURL.deletingPathExtension().pathExtension)
        try plaintext.write(to: tmpURL, options: .atomic)
        return tmpURL
    }

    // MARK: - Encrypt / Decrypt Strings (for prompts, JSON)

    func encryptString(_ string: String, using key: SymmetricKey? = nil) throws -> Data {
        guard let data = string.data(using: .utf8) else { throw CryptoError.encodingFailed }
        return try encrypt(data, using: key ?? promptKey)
    }

    func decryptString(_ ciphertext: Data, using key: SymmetricKey? = nil) throws -> String {
        let data = try decrypt(ciphertext, using: key ?? promptKey)
        guard let string = String(data: data, encoding: .utf8) else { throw CryptoError.decodingFailed }
        return string
    }

    // MARK: - Batch Encrypt Vault Directory

    /// Cifra todos los PNG del directorio dado en background.
    /// Útil para cifrado inicial del vault existente.
    func encryptDirectory(_ url: URL) async throws -> Int {
        var count = 0
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return 0
        }
        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            guard ["png", "jpg", "jpeg", "webp"].contains(ext) else { continue }
            try await encryptFile(at: fileURL, deleteOriginal: true)
            count += 1
        }
        return count
    }

    // MARK: - Key Rotation

    /// Rota la clave del vault: genera una nueva, re-cifra todos los .enc del vault,
    /// luego descarta la clave antigua de Keychain.
    func rotateVaultKey() async throws -> Int {
        guard let vaultRoot = VaultManager.shared.vaultRoot else {
            throw CryptoError.vaultNotConfigured
        }
        let oldKey = vaultKey
        let newKey = SymmetricKey(size: .bits256)
        var count  = 0

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: vaultRoot, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return 0
        }
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension.lowercased() == "enc" else { continue }
            let ciphertext = try Data(contentsOf: fileURL)
            let plaintext  = try decrypt(ciphertext, using: oldKey)
            let newCipher  = try encrypt(plaintext, using: newKey)
            try newCipher.write(to: fileURL, options: .atomic)
            count += 1
        }

        // Persist new key
        storeKey(newKey, tag: KeychainTag.vaultKey)
        lastKeyRotation = Date()
        UserDefaults.standard.set(Date(), forKey: "vault.lastKeyRotation")
        return count
    }

    // MARK: - HMAC Signing (for steg payload integrity)

    func sign(_ data: Data, with key: SymmetricKey? = nil) -> Data {
        let k = key ?? vaultKey
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: k)
        return Data(mac)
    }

    func verify(_ data: Data, signature: Data, with key: SymmetricKey? = nil) -> Bool {
        let k   = key ?? vaultKey
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: k)
        return Data(mac) == signature
    }

    // MARK: - Keychain Helpers

    private func storeKey(_ key: SymmetricKey, tag: String) {
        let keyData = key.withUnsafeBytes { Data($0) }
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrAccount: tag,
            kSecValueData:   keyData,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    private func loadKey(tag: String) -> SymmetricKey? {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrAccount: tag,
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return SymmetricKey(data: data)
    }

    func deleteAllKeys() {
        [KeychainTag.vaultKey, KeychainTag.promptKey, KeychainTag.backupKey].forEach { tag in
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrAccount: tag
            ]
            SecItemDelete(query as CFDictionary)
        }
    }

    // MARK: - Errors

    enum CryptoError: LocalizedError {
        case sealingFailed
        case openingFailed
        case encodingFailed
        case decodingFailed
        case vaultNotConfigured
        case fileNotFound(String)

        var errorDescription: String? {
            switch self {
            case .sealingFailed:        return "AES-GCM: No se pudo sellar el mensaje."
            case .openingFailed:        return "AES-GCM: No se pudo descifrar — datos corruptos o clave incorrecta."
            case .encodingFailed:       return "No se pudo codificar el string como UTF-8."
            case .decodingFailed:       return "No se pudo decodificar los datos descifrados como UTF-8."
            case .vaultNotConfigured:   return "Vault no configurado. Configura el studio primero."
            case .fileNotFound(let p):  return "Archivo no encontrado: \(p)"
            }
        }
    }
}

// MARK: - EncryptedAssetViewer
// Carga temporal en memoria para visualizar assets cifrados sin desencriptar a disco.

extension VaultCryptoEngine {

    func loadEncryptedAsset(_ asset: GeneratedAsset) async -> NSImage? {
        guard let path = asset.imagePath else { return nil }
        let url = URL(fileURLWithPath: path)
        let encURL = url.appendingPathExtension("enc")

        if FileManager.default.fileExists(atPath: encURL.path) {
            guard let plaintext = try? await decryptFileToMemory(at: encURL) else { return nil }
            return NSImage(data: plaintext)
        } else if FileManager.default.fileExists(atPath: url.path) {
            return NSImage(contentsOf: url)
        }
        return nil
    }
}
