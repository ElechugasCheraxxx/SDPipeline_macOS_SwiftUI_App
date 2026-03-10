import Foundation
import SwiftUI
import Combine
import CryptoKit

// MARK: - IntegrityManager
//
// Verificación de integridad batch para todos los assets del vault.
// Ejecuta SHA-256 en background y reporta:
//   - Assets íntegros (hash coincide con el guardado en Core Data)
//   - Assets corruptos (hash diferente → posible modificación externa)
//   - Assets huérfanos (archivo no encontrado en disco)
//   - Assets sin hash registrado (generados antes del sistema de integridad)
//
// Se puede ejecutar manualmente desde Settings → Auditoría
// y se programa automáticamente en BackupManager pre-backup.

@MainActor
final class IntegrityManager: ObservableObject {

    static let shared = IntegrityManager()
    private init() {}

    // MARK: - Models

    enum VerificationResult {
        case ok
        case corrupted(storedHash: String, actualHash: String)
        case fileNotFound(path: String)
        case noHashRegistered
    }

    struct AssetVerificationRecord: Identifiable {
        let id      = UUID()
        let asset:  GeneratedAsset
        let result: VerificationResult
        let checkedAt: Date = Date()

        var isOK:       Bool { if case .ok = result { return true }; return false }
        var isProblematic: Bool { !isOK }

        var statusLabel: String {
            switch result {
            case .ok:               return "Íntegro"
            case .corrupted:        return "Corrupto"
            case .fileNotFound:     return "Archivo no encontrado"
            case .noHashRegistered: return "Sin hash"
            }
        }

        var statusColor: Color {
            switch result {
            case .ok:               return Color(hex: "#34d399")
            case .corrupted:        return Color(hex: "#ef4444")
            case .fileNotFound:     return Color(hex: "#f97316")
            case .noHashRegistered: return Color(hex: "#6b7280")
            }
        }

        var statusIcon: String {
            switch result {
            case .ok:               return "checkmark.shield.fill"
            case .corrupted:        return "exclamationmark.shield.fill"
            case .fileNotFound:     return "questionmark.folder.fill"
            case .noHashRegistered: return "shield.slash"
            }
        }
    }

    // MARK: - State

    @Published var isRunning:       Bool   = false
    @Published var progress:        Double = 0.0   // 0.0 – 1.0
    @Published var progressText:    String = ""
    @Published var results:         [AssetVerificationRecord] = []
    @Published var lastRunAt:       Date?  = nil

    var okCount:           Int { results.filter { $0.isOK }.count }
    var problematicCount:  Int { results.filter { $0.isProblematic }.count }
    var corruptedCount:    Int { results.filter { if case .corrupted = $0.result { return true }; return false }.count }
    var missingCount:      Int { results.filter { if case .fileNotFound = $0.result { return true }; return false }.count }

    // MARK: - Run Verification

    func runFullVerification() async {
        guard !isRunning else { return }

        isRunning   = true
        progress    = 0
        results     = []
        progressText = "Cargando assets…"

        let assets = AssetStore.shared.fetchAllAssets(limit: 10_000)
        let total  = Double(assets.count)

        guard total > 0 else {
            progressText = "No hay assets para verificar"
            isRunning    = false
            return
        }

        progressText = "Verificando \(assets.count) assets…"

        var newResults: [AssetVerificationRecord] = []

        // Run in batches of 20 to keep UI responsive
        for (i, asset) in assets.enumerated() {
            let record = await verifyAsset(asset)
            newResults.append(record)

            // Update UI every 10 assets
            if i % 10 == 0 || i == assets.count - 1 {
                let checked = i + 1
                progress     = Double(checked) / total
                progressText = "Verificando \(checked)/\(assets.count)…"
                results      = newResults
            }

            // Yield to keep UI responsive
            await Task.yield()
        }

        results      = newResults
        lastRunAt    = Date()
        isRunning    = false
        progressText = "Verificación completada"

        // Log result to ZeroKnowledgeLog
        ZeroKnowledgeLog.shared.write(
            category: .systemEvent,
            message:  "Integrity check: \(okCount) OK · \(corruptedCount) corruptos · \(missingCount) faltantes",
            metadata: [
                "total":     "\(assets.count)",
                "ok":        "\(okCount)",
                "corrupted": "\(corruptedCount)",
                "missing":   "\(missingCount)"
            ]
        )
    }

    /// Verificar un solo asset.
    func verifySingle(_ asset: GeneratedAsset) async -> AssetVerificationRecord {
        let record = await verifyAsset(asset)
        // Update existing record or append
        if let idx = results.firstIndex(where: { $0.asset.id == asset.id }) {
            results[idx] = record
        } else {
            results.append(record)
        }
        return record
    }

    // MARK: - Private

    private func verifyAsset(_ asset: GeneratedAsset) async -> AssetVerificationRecord {
        // Check file exists
        guard let path = asset.imagePath else {
            return AssetVerificationRecord(asset: asset, result: .fileNotFound(path: "nil"))
        }

        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            return AssetVerificationRecord(asset: asset, result: .fileNotFound(path: path))
        }

        // Check stored hash
        guard let storedHash = asset.sha256, !storedHash.isEmpty else {
            return AssetVerificationRecord(asset: asset, result: .noHashRegistered)
        }

        // Compute actual hash in background
        let actualHash: String = await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url) else { return "" }
            let digest = SHA256.hash(data: data)
            return digest.map { String(format: "%02hhx", $0) }.joined()
        }.value

        guard !actualHash.isEmpty else {
            return AssetVerificationRecord(asset: asset, result: .fileNotFound(path: path))
        }

        if actualHash == storedHash {
            return AssetVerificationRecord(asset: asset, result: .ok)
        } else {
            return AssetVerificationRecord(asset: asset, result: .corrupted(
                storedHash: storedHash,
                actualHash: actualHash
            ))
        }
    }

    // MARK: - Repair

    /// Actualizar hash de un asset corrupto (si el archivo fue editado intencionalmente).
    func reRegisterHash(for asset: GeneratedAsset) async -> Bool {
        guard let path = asset.imagePath,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path))
        else { return false }

        let newHash = data.sha256Hex
        asset.sha256 = newHash
        try? AssetStore.shared.container.viewContext.save()

        // Update in results
        if let idx = results.firstIndex(where: { $0.asset.id == asset.id }) {
            results[idx] = AssetVerificationRecord(asset: asset, result: .ok)
        }
        return true
    }
}

// MARK: - IntegrityDashboardView

struct IntegrityDashboardView: View {

    @StateObject private var manager = IntegrityManager.shared
    @State private var filterMode: FilterMode = .all

    enum FilterMode: String, CaseIterable {
        case all         = "Todos"
        case ok          = "Íntegros"
        case problematic = "Problemas"
    }

    var filtered: [IntegrityManager.AssetVerificationRecord] {
        switch filterMode {
        case .all:         return manager.results
        case .ok:          return manager.results.filter { $0.isOK }
        case .problematic: return manager.results.filter { $0.isProblematic }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.white.opacity(0.06))

            if manager.isRunning {
                progressView
            } else if manager.results.isEmpty {
                emptyState
            } else {
                statsBar
                Divider().background(Color.white.opacity(0.06))
                filterBar
                Divider().background(Color.white.opacity(0.06))
                resultsList
            }
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
    }

    var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "shield.checkered")
                .font(.system(size: 13))
                .foregroundColor(Color(hex: "#7c6af7"))
            Text("Integridad del Vault")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
            Spacer()
            if let lastRun = manager.lastRunAt {
                Text("Último: \(lastRun.shortDisplay)")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            Button(action: {
                Task { await manager.runFullVerification() }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10))
                    Text("Verificar")
                        .font(.system(size: 11, weight: .semibold))
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color(hex: "#7c6af7").opacity(0.25))
                .foregroundColor(Color(hex: "#7c6af7"))
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .disabled(manager.isRunning)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.white.opacity(0.03))
    }

    var progressView: some View {
        VStack(spacing: 12) {
            ProgressView(value: manager.progress)
                .progressViewStyle(.linear)
                .tint(Color(hex: "#7c6af7"))
                .frame(maxWidth: 300)
            Text(manager.progressText)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(30)
    }

    var statsBar: some View {
        HStack(spacing: 0) {
            statCell("\(manager.okCount)", "Íntegros", color: "#34d399")
            Divider().frame(height: 36).background(Color.white.opacity(0.06))
            statCell("\(manager.corruptedCount)", "Corruptos", color: "#ef4444")
            Divider().frame(height: 36).background(Color.white.opacity(0.06))
            statCell("\(manager.missingCount)", "Faltantes", color: "#f97316")
            Divider().frame(height: 36).background(Color.white.opacity(0.06))
            statCell("\(manager.results.count)", "Total", color: "#7c6af7")
        }
        .background(Color.white.opacity(0.02))
    }

    func statCell(_ value: String, _ label: String, color: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(Color(hex: color))
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    var filterBar: some View {
        HStack(spacing: 4) {
            ForEach(FilterMode.allCases, id: \.self) { mode in
                Button(action: { filterMode = mode }) {
                    Text(mode.rawValue)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(filterMode == mode ? .white : .secondary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(filterMode == mode ? Color.white.opacity(0.12) : Color.clear)
                        .cornerRadius(4)
                }.buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Color.white.opacity(0.02))
    }

    var resultsList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filtered.prefix(200)) { record in
                    integrityRow(record)
                    Divider().background(Color.white.opacity(0.04))
                }
            }
        }
    }

    func integrityRow(_ record: IntegrityManager.AssetVerificationRecord) -> some View {
        HStack(spacing: 10) {
            Image(systemName: record.statusIcon)
                .font(.system(size: 11))
                .foregroundColor(record.statusColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(record.asset.baseName ?? "—")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.85))
                Text(record.statusLabel)
                    .font(.system(size: 9))
                    .foregroundColor(record.statusColor)
            }

            Spacer()

            if case .corrupted = record.result {
                Button(action: {
                    Task { await manager.reRegisterHash(for: record.asset) }
                }) {
                    Text("Re-registrar")
                        .font(.system(size: 9))
                        .foregroundColor(Color(hex: "#f97316"))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color(hex: "#f97316").opacity(0.12))
                        .cornerRadius(3)
                }.buttonStyle(.plain)
            }

            Text(record.checkedAt.shortDisplay)
                .font(.system(size: 9))
                .foregroundColor(.secondary.opacity(0.5))
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
    }

    var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "shield.checkered")
                .font(.system(size: 32))
                .foregroundColor(.white.opacity(0.08))
            Text("Aún no se ha verificado el vault")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Text("Presiona \"Verificar\" para comprobar la integridad SHA-256 de todos los assets.")
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.6))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 240)
        }
        .frame(maxWidth: .infinity)
        .padding(40)
    }
}
