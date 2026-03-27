import Foundation
import AppKit
import SwiftUI
import Combine
import CryptoKit

// MARK: - PublishComplianceLogger v2
//
// Cambios v1 → v2:
//   ✨ ADD: logEntry(_ dict:) — método genérico para entrada en JSONL
//   ✨ ADD: LogAction.setExported + batchExported + imageExported
//   ✨ ADD: Rotación automática del log (max 10MB → comprime y archiva)
//   ✨ ADD: readEntries(limit:) — lee las N entradas más recientes
//   ✨ ADD: exportLogAsCSV() — exporta el log como CSV para auditoría
//   ✨ ADD: Firma SHA-256 de cada entrada para integridad del log

@MainActor
final class PublishComplianceLogger: ObservableObject {

    static let shared = PublishComplianceLogger()
    private init() { ensureLogFile() }

    // MARK: - Models

    enum LogAction: String, Codable {
        case imagePublished   = "IMAGE_PUBLISHED"
        case imageExported    = "IMAGE_EXPORTED"
        case setExported      = "SET_EXPORTED"
        case batchExported    = "BATCH_EXPORTED"
        case imageBlocked     = "IMAGE_BLOCKED"
        case consentSigned    = "CONSENT_SIGNED"
        case licenseVerified  = "LICENSE_VERIFIED"
        case privacyUpdated   = "PRIVACY_POLICY_UPDATED"
        case termsUpdated     = "TERMS_UPDATED"
        case complianceCheck  = "COMPLIANCE_CHECK"
    }

    struct LogEntry: Identifiable, Codable {
        let id:        UUID
        let timestamp: Date
        let action:    LogAction
        let details:   [String: AnyCodable]
        let sha256:    String           // Hash del entry para integridad

        struct AnyCodable: Codable {
            let value: Any
            init(_ value: Any) { self.value = value }
            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let s = try? container.decode(String.self)  { value = s; return }
                if let i = try? container.decode(Int.self)     { value = i; return }
                if let d = try? container.decode(Double.self)  { value = d; return }
                if let b = try? container.decode(Bool.self)    { value = b; return }
                value = ""
            }
            func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                switch value {
                case let s as String: try container.encode(s)
                case let i as Int:    try container.encode(i)
                case let d as Double: try container.encode(d)
                case let b as Bool:   try container.encode(b)
                default:              try container.encode(String(describing: value))
                }
            }
        }
    }

    // MARK: - Published State

    @Published var recentEntries: [LogEntry] = []
    @Published var totalEntries:  Int         = 0

    // MARK: - GDPR Flags (stored in class body — @Published requires this)

    struct GDPRFlags {
        var retentionDays:         Int  = 90
        var rightToErasure:        Bool = true
        var consentRequired:       Bool = true
        var allowsDataPortability: Bool = true
    }

    @Published var gdprFlags: GDPRFlags = {
        let ud = UserDefaults.standard
        return GDPRFlags(
            retentionDays:         ud.integer(forKey: "compliance.retentionDays") > 0
                                   ? ud.integer(forKey: "compliance.retentionDays") : 90,
            rightToErasure:        ud.object(forKey: "compliance.rightToErasure")  == nil
                                   ? true : ud.bool(forKey: "compliance.rightToErasure"),
            consentRequired:       ud.object(forKey: "compliance.consentRequired") == nil
                                   ? true : ud.bool(forKey: "compliance.consentRequired"),
            allowsDataPortability: ud.object(forKey: "compliance.dataPortability") == nil
                                   ? true : ud.bool(forKey: "compliance.dataPortability")
        )
    }() {
        didSet { persistGDPRFlags() }
    }

    private func persistGDPRFlags() {
        let ud = UserDefaults.standard
        ud.set(gdprFlags.retentionDays,         forKey: "compliance.retentionDays")
        ud.set(gdprFlags.rightToErasure,        forKey: "compliance.rightToErasure")
        ud.set(gdprFlags.consentRequired,       forKey: "compliance.consentRequired")
        ud.set(gdprFlags.allowsDataPortability, forKey: "compliance.dataPortability")
    }

    // MARK: - Log File Management

    private var logURL: URL? {
        VaultManager.shared.vaultRoot?
            .appendingPathComponent("Legal")
            .appendingPathComponent("publish_log.jsonl")
    }

    private func ensureLogFile() {
        guard let url = logURL else { return }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        loadRecentEntries()
    }

    // MARK: - Write API

    /// Escribe un diccionario arbitrario como entrada en el log JSONL.
    /// Llamado internamente y también por OnlyFansSetExporter y ExportBatchCoordinator.
    func logEntry(_ dict: [String: Any]) {
        var entry = dict
        entry["_id"]        = UUID().uuidString
        entry["_timestamp"] = ISO8601DateFormatter().string(from: Date())

        // Firma del entry
        if let data = try? JSONSerialization.data(withJSONObject: entry),
           let sha256 = computeSHA256(data: data) {
            entry["_sha256"] = sha256
        }

        guard let logURL = logURL,
              let data   = try? JSONSerialization.data(withJSONObject: entry),
              var line   = String(data: data, encoding: .utf8)
        else { return }

        line += "\n"
        if let fileHandle = try? FileHandle(forWritingTo: logURL) {
            fileHandle.seekToEndOfFile()
            fileHandle.write(Data(line.utf8))
            try? fileHandle.close()
        }

        totalEntries += 1
        rotateIfNeeded()
        loadRecentEntries()
    }

    /// Log estructurado de publicación de imagen.
    func logPublish(
        assetID:    UUID,
        platform:   String,
        assetName:  String,
        checkpoint: String?,
        sha256:     String,
        tags:       [String] = []
    ) {
        logEntry([
            "action":     LogAction.imagePublished.rawValue,
            "assetID":    assetID.uuidString,
            "assetName":  assetName,
            "platform":   platform,
            "checkpoint": checkpoint ?? "",
            "sha256":     sha256,
            "tags":       tags.joined(separator: ",")
        ])
    }

    /// Log de compliance check (llamado antes de publicación).
    func logComplianceCheck(
        assetID:  UUID,
        passed:   Bool,
        issues:   [String] = []
    ) {
        logEntry([
            "action":  LogAction.complianceCheck.rawValue,
            "assetID": assetID.uuidString,
            "passed":  passed,
            "issues":  issues.joined(separator: " | ")
        ])
    }

    /// Log para la exportación de lotes.
    func logBatchExport(succeeded: Int, failed: Int, duration: TimeInterval) {
        logEntry([
            "action": LogAction.batchExported.rawValue,
            "succeeded": succeeded,
            "failed": failed,
            "durationSec": duration
        ])
    }

    // MARK: - Read API

    func readEntries(limit: Int = 50) -> [[String: Any]] {
        guard let url  = logURL,
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return [] }

        let lines = text.components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .reversed()
            .prefix(limit)

        return lines.compactMap { line -> [String: Any]? in
            guard let lineData = line.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { return nil }
            return dict
        }
    }

    private func loadRecentEntries() {
        let dicts = readEntries(limit: 100)
        totalEntries = max(totalEntries, dicts.count)
    }

    // MARK: - CSV Export

    func exportLogAsCSV() -> String {
        let entries = readEntries(limit: 10_000)
        var csv  = "timestamp,action,assetID,platform,sha256,notes\n"
        for entry in entries {
            let ts       = entry["_timestamp"] as? String ?? ""
            let action   = entry["action"] as? String ?? ""
            let assetID  = entry["assetID"] as? String ?? ""
            let platform = entry["platform"] as? String ?? ""
            let sha256   = entry["sha256"] as? String ?? ""
            let notes    = (entry["issues"] as? String ?? entry["setTitle"] as? String ?? "")
                           .replacingOccurrences(of: "\"", with: "'")
            csv += "\"\(ts)\",\"\(action)\",\"\(assetID)\",\"\(platform)\",\"\(sha256)\",\"\(notes)\"\n"
        }
        return csv
    }

    func saveCSVToVault() -> URL? {
        guard let vault = VaultManager.shared.vaultRoot else { return nil }
        let url = vault
            .appendingPathComponent("Legal")
            .appendingPathComponent("publish_log_\(ISO8601DateFormatter().string(from: Date()).prefix(10)).csv")
        try? exportLogAsCSV().write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Log Rotation

    private func rotateIfNeeded() {
        guard let url = logURL else { return }
        let maxSizeBytes = 10 * 1024 * 1024 // 10MB
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size  = attrs[.size] as? Int,
              size > maxSizeBytes
        else { return }

        // Archivar el log actual
        let archiveURL = url.deletingLastPathComponent()
            .appendingPathComponent("publish_log_archive_\(Int(Date().timeIntervalSince1970)).jsonl.gz")

        // Comprimir y archivar (simplificado — en producción usar zlib)
        try? FileManager.default.copyItem(at: url, to: archiveURL)

        // Truncar el log actual
        try? "".write(to: url, atomically: true, encoding: .utf8)
        totalEntries = 0
    }

    // MARK: - Helpers

    private func computeSHA256(data: Data) -> String? {
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - ComplianceLogView

struct ComplianceLogView: View {

    @ObservedObject private var logger = PublishComplianceLogger.shared
    @State private var entries: [[String: Any]] = []
    @State private var showCSVExport = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "#3de3c0"))
                Text("Log de Compliance")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Text("\(logger.totalEntries) entradas")
                    .font(.system(size: 10)).foregroundColor(.secondary)
                Button(action: exportCSV) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.doc").font(.system(size: 10))
                        Text("CSV").font(.system(size: 10))
                    }
                    .foregroundColor(Color(hex: "#7c6af7"))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color(hex: "#7c6af7").opacity(0.12))
                    .cornerRadius(5)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color.white.opacity(0.03))

            Divider().background(Color.white.opacity(0.07))

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { idx, entry in
                        logRow(entry: entry)
                        if idx < entries.count - 1 {
                            Divider().background(Color.white.opacity(0.05))
                        }
                    }
                    if entries.isEmpty {
                        Text("Sin entradas de compliance registradas.")
                            .font(.system(size: 11)).foregroundColor(.secondary)
                            .frame(maxWidth: .infinity).padding(20)
                    }
                }
            }
        }
        .onAppear { entries = logger.readEntries(limit: 100) }
    }

    func logRow(entry: [String: Any]) -> some View {
        HStack(alignment: .top, spacing: 10) {
            // Action icon
            let action = entry["action"] as? String ?? ""
            Image(systemName: actionIcon(action))
                .font(.system(size: 11))
                .foregroundColor(actionColor(action))
                .frame(width: 16)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(action.replacingOccurrences(of: "_", with: " "))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white)
                    Spacer()
                    if let ts = entry["_timestamp"] as? String {
                        Text(String(ts.prefix(16)).replacingOccurrences(of: "T", with: " "))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
                // Detalles clave
                let details = ["assetName", "setTitle", "platform", "succeeded", "issues"]
                    .compactMap { key -> String? in
                        guard let val = entry[key] else { return nil }
                        return "\(key): \(val)"
                    }
                    .joined(separator: " · ")
                if !details.isEmpty {
                    Text(details)
                        .font(.system(size: 9)).foregroundColor(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    func actionIcon(_ action: String) -> String {
        switch action {
        case "IMAGE_PUBLISHED":        return "arrow.up.to.line"
        case "IMAGE_EXPORTED":         return "square.and.arrow.up"
        case "SET_EXPORTED":           return "rectangle.stack.fill.badge.plus"
        case "BATCH_EXPORTED":         return "square.stack.3d.up"
        case "IMAGE_BLOCKED":          return "xmark.shield.fill"
        case "CONSENT_SIGNED":         return "signature"
        case "COMPLIANCE_CHECK":       return "checkmark.seal"
        case "LICENSE_VERIFIED":       return "checkmark.seal.fill"
        default:                       return "doc.text"
        }
    }

    func actionColor(_ action: String) -> Color {
        switch action {
        case "IMAGE_BLOCKED":          return Color(hex: "#ef4444")
        case "COMPLIANCE_CHECK":       return Color(hex: "#f59e0b")
        case "CONSENT_SIGNED", "LICENSE_VERIFIED": return Color(hex: "#3de3c0")
        default:                       return Color(hex: "#7c6af7")
        }
    }

    func exportCSV() {
        if let url = PublishComplianceLogger.shared.saveCSVToVault() {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }
}

// MARK: - Computed compliance properties

extension PublishComplianceLogger {
    /// Compliance score: ratio of published vs blocked entries (0.0–1.0).
    var currentComplianceScore: Double {
        let total  = totalEntries
        guard total > 0 else { return 1.0 }
        let blocked = readEntries(limit: total).filter {
            ($0["action"] as? String) == LogAction.imageBlocked.rawValue
        }.count
        return max(0.0, 1.0 - Double(blocked) / Double(total))
    }

    /// Total number of published/exported files logged.
    var totalFilesPublished: Int {
        readEntries(limit: 10_000).filter {
            guard let a = $0["action"] as? String else { return false }
            return [LogAction.imagePublished.rawValue,
                    LogAction.imageExported.rawValue,
                    LogAction.setExported.rawValue,
                    LogAction.batchExported.rawValue].contains(a)
        }.count
    }

    /// Ratio of watermarked images among all published/exported entries (0.0–1.0).
    /// Entries are expected to carry a "watermark" key set to true/false or "true"/"false".
    var watermarkRate: Double {
        let published = readEntries(limit: 10_000).filter {
            guard let a = $0["action"] as? String else { return false }
            return [LogAction.imagePublished.rawValue,
                    LogAction.imageExported.rawValue].contains(a)
        }
        guard !published.isEmpty else { return 0.0 }
        let withWatermark = published.filter {
            ($0["watermark"] as? Bool) == true ||
            ($0["watermark"] as? String) == "true"
        }.count
        return Double(withWatermark) / Double(published.count)
    }

    // MARK: - Platform Breakdown

    /// Count of published/exported entries grouped by platform.
    var platformBreakdown: [String: Int] {
        let entries = readEntries(limit: 10_000)
        var counts: [String: Int] = [:]
        for entry in entries {
            let platform = entry["platform"] as? String ?? "unknown"
            counts[platform, default: 0] += 1
        }
        return counts
    }

    // MARK: - Compliance Records

    struct ComplianceRecord: Identifiable {
        let id:              UUID
        let timestamp:       Date
        let platform:        String
        let presetName:      String
        let watermarked:     Bool
        let metadataStripped: Bool
        let stegEmbedded:    Bool
        let exportedPaths:   [String]
    }

    /// Recent typed compliance records for display in the audit view.
    var records: [ComplianceRecord] {
        let isoParser = ISO8601DateFormatter()
        return readEntries(limit: 50).compactMap { entry -> ComplianceRecord? in
            let tsString = entry["_timestamp"] as? String ?? ""
            let ts       = isoParser.date(from: tsString) ?? Date()
            return ComplianceRecord(
                id:               UUID(uuidString: entry["_id"] as? String ?? "") ?? UUID(),
                timestamp:        ts,
                platform:         entry["platform"]         as? String  ?? "—",
                presetName:       entry["presetName"]       as? String  ?? "—",
                watermarked:      (entry["watermark"]       as? Bool)   == true,
                metadataStripped: (entry["metadataStripped"] as? Bool)  == true,
                stegEmbedded:     (entry["stegEmbedded"]    as? Bool)   == true,
                exportedPaths:    entry["exportedPaths"]    as? [String] ?? []
            )
        }
    }

    // MARK: - JSON Export

    /// Exports the compliance log as a JSON file to the vault and returns its URL.
    func exportReportAsJSON() throws -> URL? {
        let entries = readEntries(limit: 10_000)
        let data    = try JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted])
        guard let vaultURL = VaultManager.shared.vaultRoot else { return nil }
        let dir  = vaultURL.appendingPathComponent("Legal")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url  = dir.appendingPathComponent("compliance_report.json")
        try data.write(to: url)
        return url
    }

    // MARK: - Purge

    /// Deletes entries older than gdprFlags.retentionDays from the log file.
    /// Returns the number of entries removed.
    @discardableResult
    func purgeExpiredRecords() -> Int {
        guard let logURL = logURL else { return 0 }
        let cutoff = Calendar.current.date(byAdding: .day,
                                           value: -gdprFlags.retentionDays,
                                           to: Date()) ?? Date()
        let isoParser = ISO8601DateFormatter()
        guard let raw = try? String(contentsOf: logURL, encoding: .utf8) else { return 0 }
        let lines  = raw.components(separatedBy: .newlines).filter { !$0.isEmpty }
        var kept   = 0
        var purged = 0
        let filtered = lines.filter { line in
            guard let data    = line.data(using: .utf8),
                  let obj     = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tsStr   = obj["_timestamp"] as? String,
                  let ts      = isoParser.date(from: tsStr)
            else { kept += 1; return true }
            if ts >= cutoff { kept += 1; return true }
            purged += 1; return false
        }
        let newContent = filtered.joined(separator: "\n") + (filtered.isEmpty ? "" : "\n")
        try? newContent.write(to: logURL, atomically: true, encoding: .utf8)
        totalEntries = kept
        loadRecentEntries()
        return purged
    }
}





