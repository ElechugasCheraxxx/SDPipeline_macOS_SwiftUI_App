import Foundation
import CryptoKit
import Combine
import SwiftUI

// MARK: - ZeroKnowledgeLog
//
// Log de seguridad y auditoría cifrado con AES-GCM.
// La clave se guarda en el Keychain — nunca en disco ni UserDefaults.
// Cada entrada es un JSON cifrado independiente (nonce único por entrada).
// Formato de archivo: JSONL donde cada línea es {"nonce":b64,"ciphertext":b64}
//
// Uso:
//   ZeroKnowledgeLog.shared.write(category: .promptBlocked, message: "…")
//   let entries = ZeroKnowledgeLog.shared.readAll()
//
// ROADMAP: "Zero-Knowledge Logs cifrados" (Sección 3 - Seguridad)

@MainActor
final class ZeroKnowledgeLog: ObservableObject {

    static let shared = ZeroKnowledgeLog()
    private init() {}

    // MARK: - Categories

    enum LogCategory: String, Codable, CaseIterable {
        case promptBlocked   = "PROMPT_BLOCKED"
        case promptFlagged   = "PROMPT_FLAGGED"
        case nsfwDetected    = "NSFW_DETECTED"
        case nsfwQuarantine  = "NSFW_QUARANTINE"
        case exportPerformed = "EXPORT_PERFORMED"
        case vaultAccess     = "VAULT_ACCESS"
        case backupJob       = "BACKUP_JOB"
        case licenseIssue    = "LICENSE_ISSUE"
        case systemEvent     = "SYSTEM_EVENT"
        case authAttempt     = "AUTH_ATTEMPT"

        var icon: String {
            switch self {
            case .promptBlocked:   return "xmark.shield.fill"
            case .promptFlagged:   return "exclamationmark.shield"
            case .nsfwDetected:    return "eye.slash.fill"
            case .nsfwQuarantine:  return "lock.shield.fill"
            case .exportPerformed: return "arrow.up.doc.fill"
            case .vaultAccess:     return "externaldrive.fill"
            case .backupJob:       return "externaldrive.badge.timemachine"
            case .licenseIssue:    return "doc.badge.exclamationmark"
            case .systemEvent:     return "gear.badge.checkmark"
            case .authAttempt:     return "person.badge.key.fill"
            }
        }
    }

    // MARK: - Entry Model (unencrypted in-memory)

    struct LogEntry: Codable, Identifiable {
        var id:        UUID     = UUID()
        var timestamp: Date     = Date()
        var category:  LogCategory
        var message:   String
        var metadata:  [String: String] = [:]
        var sessionID: String  = ZeroKnowledgeLog.currentSessionID
    }

    // MARK: - Session ID (per-launch)

    static let currentSessionID: String = UUID().uuidString.prefix(8).description

    // MARK: - Published

    @Published var decryptedEntries: [LogEntry] = []
    @Published var isLoaded: Bool = false

    // MARK: - Public API

    /// Escribir una entrada en el log cifrado.
    func write(
        category: LogCategory,
        message:  String,
        metadata: [String: String] = [:]
    ) {
        let entry = LogEntry(
            category: category,
            message:  message,
            metadata: metadata
        )

        // Añadir a caché en memoria
        decryptedEntries.insert(entry, at: 0)
        if decryptedEntries.count > 2000 {
            decryptedEntries = Array(decryptedEntries.prefix(2000))
        }

        // Persistir cifrado
        guard let line = encryptEntry(entry),
              let url  = logURL
        else { return }

        let lineWithNewline = line + "\n"
        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(lineWithNewline.data(using: .utf8)!)
                handle.closeFile()
            }
        } else {
            try? lineWithNewline.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Leer y descifrar todas las entradas del log.
    func loadAll() {
        guard let url  = logURL,
              let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            isLoaded = true
            return
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        decryptedEntries = lines.compactMap { decryptLine(String($0)) }
            .sorted { $0.timestamp > $1.timestamp }
        isLoaded = true
    }

    /// Buscar entradas por categoría o mensaje.
    func entries(
        category: LogCategory? = nil,
        query: String = "",
        limit: Int = 200
    ) -> [LogEntry] {
        var result = decryptedEntries

        if let cat = category {
            result = result.filter { $0.category == cat }
        }

        if !query.isEmpty {
            let q = query.lowercased()
            result = result.filter {
                $0.message.lowercased().contains(q) ||
                $0.metadata.values.contains(where: { $0.lowercased().contains(q) })
            }
        }

        return Array(result.prefix(limit))
    }

    /// Exportar log descifrado como JSON (para auditoría externa).
    func exportDecrypted() -> Data? {
        try? JSONEncoder.pretty.encode(decryptedEntries)
    }

    /// Rotar log: archivar el actual y empezar uno nuevo.
    func rotate() {
        guard let url = logURL else { return }
        let archiveURL = url.deletingLastPathComponent()
            .appending(path: "security_archive_\(Int(Date().timeIntervalSince1970)).zklog")
        try? FileManager.default.moveItem(at: url, to: archiveURL)
        decryptedEntries.removeAll()
    }

    // MARK: - Encryption

    private func encryptEntry(_ entry: LogEntry) -> String? {
        guard let data = try? JSONEncoder().encode(entry) else { return nil }

        let key   = loadOrCreateKey()
        let nonce = AES.GCM.Nonce()

        guard let sealed = try? AES.GCM.seal(data, using: key, nonce: nonce) else { return nil }

        let payload: [String: String] = [
            "n": sealed.nonce.withUnsafeBytes { Data($0).base64EncodedString() },
            "c": sealed.ciphertext.base64EncodedString(),
            "t": sealed.tag.base64EncodedString()
        ]

        guard let payloadData = try? JSONSerialization.data(withJSONObject: payload),
              let line = String(data: payloadData, encoding: .utf8)
        else { return nil }

        return line
    }

    private func decryptLine(_ line: String) -> LogEntry? {
        guard let data = line.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let nonceB64  = payload["n"],
              let cipherB64 = payload["c"],
              let tagB64    = payload["t"],
              let nonceData  = Data(base64Encoded: nonceB64),
              let cipherData = Data(base64Encoded: cipherB64),
              let tagData    = Data(base64Encoded: tagB64)
        else { return nil }

        let key = loadOrCreateKey()

        guard let nonce  = try? AES.GCM.Nonce(data: nonceData),
              let sealed = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: cipherData, tag: tagData),
              let plain  = try? AES.GCM.open(sealed, using: key),
              let entry  = try? JSONDecoder().decode(LogEntry.self, from: plain)
        else { return nil }

        return entry
    }

    // MARK: - Key Management (Keychain)

    private func loadOrCreateKey() -> SymmetricKey {
        let keychainKey = "SDPipeline.zklog.aesKey"
        if let data = KeychainHelper.load(key: keychainKey) {
            return SymmetricKey(data: data)
        }
        let newKey  = SymmetricKey(size: .bits256)
        let keyData = newKey.withUnsafeBytes { Data($0) }
        KeychainHelper.save(key: keychainKey, data: keyData)
        return newKey
    }

    // MARK: - URL

    private var logURL: URL? {
        VaultManager.shared.vaultMetaURL?.appending(path: "security.zklog")
    }
}

// MARK: - ZeroKnowledgeLog convenience wrappers

extension PromptSafetyFilter {

    /// Reemplaza appendToSecurityLog con escritura cifrada.
    static func logResultZK(_ result: FilterResult, prompt: String) {
        let truncated = String(prompt.prefix(80))

        switch result {
        case .allowed:
            break
        case .blocked(let reason, let terms):
            ZeroKnowledgeLog.shared.write(
                category: .promptBlocked,
                message:  "\(reason)",
                metadata: ["terms": terms.joined(separator: ","), "prompt": truncated]
            )
        case .flagged(let warnings):
            ZeroKnowledgeLog.shared.write(
                category: .promptFlagged,
                message:  warnings.joined(separator: " | "),
                metadata: ["prompt": truncated]
            )
        }
    }
}

// NSFWDetector.logResultZK is defined in NSFWDetector.swift

// MARK: - ZeroKnowledgeLogView

struct ZeroKnowledgeLogView: View {

    @StateObject private var log = ZeroKnowledgeLog.shared
    @State private var selectedCategory: ZeroKnowledgeLog.LogCategory? = nil
    @State private var query: String = ""

    var filtered: [ZeroKnowledgeLog.LogEntry] {
        log.entries(category: selectedCategory, query: query)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: "#7c6af7"))
                Text("Audit Log (Cifrado AES-GCM)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Button(action: { log.rotate() }) {
                    Image(systemName: "arrow.clockwise.circle")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Rotar log — archivar y empezar uno nuevo")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color.white.opacity(0.03))

            // Filters
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                TextField("Buscar…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(.white)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.white.opacity(0.04))

            // Category pills
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    categoryPill(nil, "Todos")
                    ForEach(ZeroKnowledgeLog.LogCategory.allCases, id: \.self) { cat in
                        categoryPill(cat, cat.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
            }
            .background(Color.white.opacity(0.02))

            Divider().background(Color.white.opacity(0.06))

            if !log.isLoaded {
                Button("Cargar log cifrado") { log.loadAll() }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Color(hex: "#7c6af7").opacity(0.15))
                    .foregroundColor(Color(hex: "#7c6af7"))
                    .cornerRadius(6)
                    .frame(maxWidth: .infinity)
                    .padding(24)
            } else if filtered.isEmpty {
                Text("Sin entradas")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(30)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered.prefix(200)) { entry in
                            logRow(entry)
                            Divider().background(Color.white.opacity(0.04))
                        }
                    }
                }
            }
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.07), lineWidth: 1))
    }

    func logRow(_ entry: ZeroKnowledgeLog.LogEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.category.icon)
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#7c6af7"))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.message.truncated(70))
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(entry.timestamp, style: .relative)
                        .font(.system(size: 9)).foregroundColor(.secondary)
                    Text("·")
                        .font(.system(size: 9)).foregroundColor(.secondary)
                    Text(entry.category.rawValue)
                        .font(.system(size: 9)).foregroundColor(.secondary.opacity(0.7))
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
    }

    func categoryPill(_ category: ZeroKnowledgeLog.LogCategory?, _ label: String) -> some View {
        let isSelected = selectedCategory == category
        return Button(action: { selectedCategory = category }) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(isSelected ? .white : .secondary)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(isSelected ? Color.white.opacity(0.14) : Color.white.opacity(0.04))
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }
}
