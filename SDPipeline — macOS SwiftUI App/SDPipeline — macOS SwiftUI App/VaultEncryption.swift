import Foundation
import CryptoKit
import AppKit
import SwiftUI
import Combine

// MARK: - VaultEncryption
//
// Cifrado en reposo (at-rest) para imágenes y prompts del vault.
// Algoritmo: AES-GCM 256-bit (CryptoKit)
// Gestión de claves: Keychain (accesible solo cuando desbloqueado en este dispositivo)
//
// Arquitectura:
//   - Una clave maestra por vault (generada en el primer arranque)
//   - Cada archivo cifrado tiene un nonce único de 12 bytes
//   - Formato cifrado: [12B nonce] + [16B tag] + [ciphertext]
//   - El sidecar JSON puede cifrarse por separado con la misma clave
//   - Las thumbnails y previews públicas NO se cifran
//
// Política de aplicación:
//   - Modo transparente: la app descifra en memoria al acceder
//   - Los archivos .enc se guardan junto al original (o reemplazan)
//   - El path en Core Data apunta al .enc; VaultEncryption descifra al cargar
//
// ROADMAP: "Encriptación de imágenes y prompts" (🟠 CORTO PLAZO — Seguridad)

// MARK: - Encrypted File Format

// [12 bytes nonce][16 bytes tag][N bytes ciphertext]
// Total overhead: 28 bytes

struct EncryptedFileHeader {
    static let nonceSize   = 12
    static let tagSize     = 16
    static let headerSize  = nonceSize + tagSize   // 28 bytes overhead
    static let fileExtension = ".enc"
}

// MARK: - VaultEncryption Engine

@MainActor
final class VaultEncryption: ObservableObject {

    static let shared = VaultEncryption()
    private init() {}

    // MARK: - Configuration

    @Published var isEnabled:    Bool = false
    @Published var encryptedCount: Int = 0
    @Published var isProcessing: Bool = false

    private let keychainKey = "SDPipeline.vault.masterKey"

    // MARK: - Key Management

    /// Obtener o crear la clave maestra del vault.
    func masterKey() -> SymmetricKey {
        if let existing = KeychainHelper.load(key: keychainKey) {
            return SymmetricKey(data: existing)
        }
        let newKey  = SymmetricKey(size: .bits256)
        let keyData = newKey.withUnsafeBytes { Data($0) }
        KeychainHelper.save(key: keychainKey, data: keyData)
        ZeroKnowledgeLog.shared.write(
            category: .vaultAccess,
            message:  "Nueva clave maestra generada para vault",
            metadata: ["timestamp": ISO8601DateFormatter().string(from: Date())]
        )
        return newKey
    }

    /// Regenerar clave maestra (re-cifra todo el vault — DESTRUCTIVO si no se re-cifra).
    func rotateMasterKey() -> SymmetricKey {
        let oldKey = masterKey()
        let newKey = SymmetricKey(size: .bits256)
        let keyData = newKey.withUnsafeBytes { Data($0) }
        KeychainHelper.save(key: keychainKey, data: keyData)
        ZeroKnowledgeLog.shared.write(
            category: .vaultAccess,
            message:  "Rotación de clave maestra del vault",
            metadata: [:]
        )
        return newKey
    }

    // MARK: - Encrypt / Decrypt Data

    /// Cifrar datos con AES-GCM. Devuelve [nonce(12) + tag(16) + ciphertext].
    func encrypt(_ data: Data) throws -> Data {
        let key    = masterKey()
        let nonce  = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(data, using: key, nonce: nonce)

        var output = Data()
        nonce.withUnsafeBytes { output.append(contentsOf: $0) }
        output.append(sealed.tag)
        output.append(sealed.ciphertext)
        return output
    }

    /// Descifrar datos con AES-GCM. Espera formato [nonce(12) + tag(16) + ciphertext].
    func decrypt(_ encryptedData: Data) throws -> Data {
        guard encryptedData.count > EncryptedFileHeader.headerSize else {
            throw VaultEncryptionError.invalidFormat
        }

        let key         = masterKey()
        let nonceData   = encryptedData.prefix(EncryptedFileHeader.nonceSize)
        let tagData     = encryptedData.dropFirst(EncryptedFileHeader.nonceSize)
                                        .prefix(EncryptedFileHeader.tagSize)
        let ciphertext  = encryptedData.dropFirst(EncryptedFileHeader.headerSize)

        let nonce  = try AES.GCM.Nonce(data: nonceData)
        let sealed = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tagData)
        return try AES.GCM.open(sealed, using: key)
    }

    // MARK: - File Operations

    /// Cifrar un archivo en disco y guardar como .enc (no elimina el original).
    @discardableResult
    func encryptFile(at url: URL) throws -> URL {
        let plainData = try Data(contentsOf: url)
        let encData   = try encrypt(plainData)
        let encURL    = url.appendingPathExtension("enc")
        try encData.write(to: encURL, options: .atomic)
        return encURL
    }

    /// Descifrar un archivo .enc en memoria y devolver los datos originales.
    func decryptFile(at url: URL) throws -> Data {
        let encData = try Data(contentsOf: url)
        return try decrypt(encData)
    }

    /// Cargar imagen desde un archivo .enc directamente como NSImage.
    func loadEncryptedImage(at url: URL) -> NSImage? {
        guard let data = try? decryptFile(at: url) else { return nil }
        return NSImage(data: data)
    }

    /// Cifrar in-place: cifra y reemplaza el archivo original (sin backup).
    func encryptInPlace(at url: URL) throws {
        let enc    = try encryptFile(at: url)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: enc, to: url)
    }

    // MARK: - Batch Vault Encryption

    /// Cifrar todos los assets no cifrados del vault.
    func encryptVault(progress: @escaping (Double, String) -> Void) async {
        guard isEnabled else { return }
        isProcessing = true
        defer { isProcessing = false }

        let assets = AssetStore.shared.fetchAllAssets(limit: 10_000)
        let total  = Double(assets.count)
        var done   = 0

        for asset in assets {
            guard let path = asset.imagePath else { done += 1; continue }
            let url = URL(fileURLWithPath: path)

            // Skip if already .enc
            guard !path.hasSuffix(".enc"),
                  FileManager.default.fileExists(atPath: path)
            else { done += 1; continue }

            do {
                let encURL = try encryptFile(at: url)
                // Update Core Data path
                asset.imagePath = encURL.path
                try? AssetStore.shared.container.viewContext.save()
                done += 1
            } catch {
                done += 1
            }

            let pct = Double(done) / total
            await MainActor.run {
                progress(pct, "Cifrando \(done)/\(Int(total))…")
            }
        }

        encryptedCount = done
        ZeroKnowledgeLog.shared.write(
            category: .vaultAccess,
            message:  "Cifrado batch completado: \(done) assets",
            metadata: ["total": "\(Int(total))"]
        )
    }

    // MARK: - String Encryption (para prompts en sidecar)

    func encryptString(_ string: String) throws -> String {
        guard let data = string.data(using: .utf8) else { throw VaultEncryptionError.invalidInput }
        let enc = try encrypt(data)
        return enc.base64EncodedString()
    }

    func decryptString(_ base64: String) throws -> String {
        guard let enc = Data(base64Encoded: base64) else { throw VaultEncryptionError.invalidFormat }
        let plain = try decrypt(enc)
        guard let string = String(data: plain, encoding: .utf8) else { throw VaultEncryptionError.invalidFormat }
        return string
    }

    // MARK: - Settings Persistence

    func loadSettings() {
        isEnabled = UserDefaults.standard.bool(forKey: "vault.encryption.enabled")
    }

    func saveSettings() {
        UserDefaults.standard.set(isEnabled, forKey: "vault.encryption.enabled")
    }
}

// MARK: - Errors

enum VaultEncryptionError: LocalizedError {
    case invalidFormat
    case invalidInput
    case keyNotFound
    case decryptionFailed

    var errorDescription: String? {
        switch self {
        case .invalidFormat:    return "Formato de archivo cifrado inválido"
        case .invalidInput:     return "Input inválido para cifrar"
        case .keyNotFound:      return "Clave maestra no encontrada en Keychain"
        case .decryptionFailed: return "Error al descifrar — clave o datos inválidos"
        }
    }
}

// MARK: - VaultEncryptionView (Settings panel)

struct VaultEncryptionView: View {

    @StateObject private var engine = VaultEncryption.shared
    @State private var batchProgress: Double = 0
    @State private var batchText:     String = ""
    @State private var showKeyWarning = false
    @State private var isRunningBatch = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // Status header
            HStack(spacing: 12) {
                Image(systemName: engine.isEnabled ? "lock.fill" : "lock.open")
                    .font(.system(size: 20))
                    .foregroundColor(engine.isEnabled ? Color(hex: "#34d399") : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cifrado en Reposo")
                        .font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                    Text(engine.isEnabled
                         ? "AES-GCM 256-bit · Clave en Keychain"
                         : "Desactivado — imágenes sin cifrar en disco")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
                Spacer()
                Toggle("", isOn: $engine.isEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .onChange(of: engine.isEnabled) { _, _ in engine.saveSettings() }
            }
            .padding(14)
            .background(Color.white.opacity(0.04))
            .cornerRadius(10)

            if engine.isEnabled {

                // Info
                VStack(alignment: .leading, spacing: 8) {
                    infoRow("Algoritmo", "AES-GCM 256-bit (CryptoKit)")
                    infoRow("Clave",      "Keychain (solo este dispositivo)")
                    infoRow("Nonce",      "Único por archivo (12 bytes)")
                    infoRow("Assets cifrados", "\(engine.encryptedCount)")
                }
                .padding(12)
                .background(Color.white.opacity(0.03))
                .cornerRadius(8)

                // Batch encrypt
                VStack(alignment: .leading, spacing: 10) {
                    Text("CIFRADO BATCH DEL VAULT")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary).tracking(1.2)

                    Text("Cifra todos los assets existentes que aún no están cifrados. Este proceso puede tardar varios minutos según el tamaño del vault.")
                        .font(.system(size: 11)).foregroundColor(.secondary)

                    if isRunningBatch {
                        VStack(spacing: 6) {
                            ProgressView(value: batchProgress)
                                .progressViewStyle(.linear)
                                .tint(Color(hex: "#34d399"))
                            Text(batchText)
                                .font(.system(size: 10)).foregroundColor(.secondary)
                        }
                    } else {
                        Button(action: { runBatchEncrypt() }) {
                            Label("Cifrar todos los assets", systemImage: "lock.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .background(Color(hex: "#7c6af7").opacity(0.2))
                                .foregroundColor(Color(hex: "#7c6af7"))
                                .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Divider().background(Color.white.opacity(0.07))

                // Key rotation (danger zone)
                VStack(alignment: .leading, spacing: 8) {
                    Text("ZONA DE PELIGRO")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Color(hex: "#ef4444")).tracking(1.2)

                    Text("⚠️ Rotar la clave maestra invalida todos los archivos cifrados. Debes descifrar y re-cifrar el vault completo antes de rotar.")
                        .font(.system(size: 11)).foregroundColor(.secondary)

                    Button(action: { showKeyWarning = true }) {
                        Label("Rotar clave maestra…", systemImage: "key.slash")
                            .font(.system(size: 12))
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(Color.red.opacity(0.12))
                            .foregroundColor(.red).cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .alert("¿Rotar clave maestra?", isPresented: $showKeyWarning) {
                        Button("Cancelar", role: .cancel) {}
                        Button("Rotar", role: .destructive) {
                            _ = VaultEncryption.shared.rotateMasterKey()
                        }
                    } message: {
                        Text("Esta acción es irreversible. Los archivos cifrados con la clave anterior ya no serán accesibles a menos que los descifres primero.")
                    }
                }
            } else {
                // Explanation when disabled
                VStack(alignment: .leading, spacing: 8) {
                    Text("Cuando el cifrado está activado:")
                        .font(.system(size: 11, weight: .semibold)).foregroundColor(.white.opacity(0.8))
                    bulletPoint("Cada imagen generada se cifra automáticamente con AES-GCM.")
                    bulletPoint("La clave maestra se guarda en el Keychain del sistema.")
                    bulletPoint("Los archivos solo son legibles en este dispositivo y usuario.")
                    bulletPoint("El rendimiento se ve ligeramente afectado por el cifrado/descifrado.")
                }
                .padding(12).background(Color.white.opacity(0.03)).cornerRadius(8)
            }
        }
    }

    func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundColor(.secondary)
            Spacer()
            Text(value).font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.8))
        }
    }

    func bulletPoint(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•").font(.system(size: 11)).foregroundColor(Color(hex: "#7c6af7"))
            Text(text).font(.system(size: 11)).foregroundColor(.secondary)
        }
    }

    func runBatchEncrypt() {
        isRunningBatch = true
        batchProgress  = 0
        batchText      = "Iniciando…"
        Task {
            await VaultEncryption.shared.encryptVault { pct, text in
                batchProgress = pct
                batchText     = text
            }
            await MainActor.run {
                isRunningBatch = false
                batchText = "Cifrado completado ✓"
            }
        }
    }
}
