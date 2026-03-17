import Foundation
import AppKit
import SwiftUI
import Combine

// MARK: - BackupManager
//
// Sistema de backup automático del vault usando rclone.
// Soporta destinos locales (segundo disco, Time Machine excluido) y
// remotos (S3, Google Drive, Dropbox, Backblaze B2) vía rclone.
//
// Filosofía de diseño:
//   • El vault NUNCA se mueve — se replican COPIAS.
//   • El backup excluye las imágenes originales raw si el usuario lo configura
//     (ahorro de espacio — las versiones limpias + sidecar son suficientes para
//     reconstruir el historial de licencias y compliance).
//   • Cada backup job genera un manifiesto SHA-256 para verificación posterior.
//   • Los logs de backup se guardan en Vault/backup_logs/ para auditoría.
//
// PREREQUISITO: rclone instalado en el sistema.
//   brew install rclone
//   rclone config  → configurar remote (s3, gdrive, b2, etc.)

@MainActor
final class BackupManager: ObservableObject {

    static let shared = BackupManager()
    private init() {
        loadConfig()
        checkRcloneAvailability()
    }

    // MARK: - Configuration

    struct BackupConfig: Codable {
        // Destinos de backup (se pueden configurar varios)
        var destinations:   [BackupDestination] = []
        // Programación
        var schedule:       BackupSchedule      = .daily
        var backupHour:     Int                 = 3    // 3 AM por defecto
        // Filtros
        var excludeRawPNGs: Bool                = false  // Si true: excluye *.orig.png
        var excludeLoRAs:   Bool                = false  // PrivateLoRAs suelen ser grandes
        // Verificación
        var verifyAfterBackup: Bool             = true
        // Última ejecución
        var lastBackupAt:   Date?               = nil
        var lastBackupOK:   Bool                = false
    }

    struct BackupDestination: Codable, Identifiable {
        var id:          UUID   = UUID()
        var name:        String              // "Backblaze B2 Principal"
        var type:        DestinationType
        var rcloneRemote: String            // "b2:mi-bucket/StudioIA" o "/Volumes/Backup/StudioIA"
        var isEnabled:   Bool = true

        enum DestinationType: String, Codable, CaseIterable {
            case local      = "Local (disco)"
            case s3         = "Amazon S3"
            case gcs        = "Google Cloud Storage"
            case b2         = "Backblaze B2"
            case gdrive     = "Google Drive"
            case dropbox    = "Dropbox"
            case sftp       = "SFTP / SSH"
            case custom     = "rclone custom"

            var icon: String {
                switch self {
                case .local:   return "externaldrive.fill"
                case .s3:      return "cloud.fill"
                case .gcs:     return "cloud.fill"
                case .b2:      return "flame.fill"
                case .gdrive:  return "folder.fill.badge.gearshape"
                case .dropbox: return "drop.fill"
                case .sftp:    return "terminal.fill"
                case .custom:  return "puzzlepiece.fill"
                }
            }
        }
    }

    enum BackupSchedule: String, Codable, CaseIterable {
        case manual   = "Manual"
        case hourly   = "Cada hora"
        case daily    = "Diario"
        case weekly   = "Semanal"

        var intervalSeconds: TimeInterval? {
            switch self {
            case .manual:  return nil
            case .hourly:  return 3600
            case .daily:   return 86400
            case .weekly:  return 604800
            }
        }
    }

    // MARK: - Published State

    @Published var config:           BackupConfig = BackupConfig()
    @Published var isRunning:        Bool         = false
    @Published var lastJobResult:    BackupJobResult?
    @Published var rcloneAvailable:  Bool         = false
    @Published var rclonePath:       String       = "/usr/local/bin/rclone"
    @Published var liveLog:          String       = ""

    // MARK: - Backup Job Result

    struct BackupJobResult: Identifiable {
        var id:              UUID    = UUID()
        var startedAt:       Date
        var finishedAt:      Date
        var destination:     String
        var success:         Bool
        var filesTransferred: Int
        var bytesTransferred: Int64
        var errorMessage:    String?
        var manifestURL:     URL?

        var duration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }
        var bytesFormatted: String {
            ByteCountFormatter.string(fromByteCount: bytesTransferred, countStyle: .file)
        }
    }

    // MARK: - Scheduling

    private var scheduleTimer: Timer?

    func startScheduler() {
        scheduleTimer?.invalidate()
        guard let interval = config.schedule.intervalSeconds else { return }

        // Check si toca ejecutar ya (si han pasado más de `interval` desde el último backup)
        if let last = config.lastBackupAt,
           Date().timeIntervalSince(last) > interval {
            Task { await runAllBackups() }
        }

        scheduleTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { await self?.runAllBackups() }
        }
    }

    func stopScheduler() {
        scheduleTimer?.invalidate()
        scheduleTimer = nil
    }

    // MARK: - Run Backup

    /// Ejecutar backup a todos los destinos habilitados.
    func runAllBackups() async {
        guard !isRunning else { return }
        guard rcloneAvailable else {
            liveLog = "⚠️ rclone no encontrado. Instalar con: brew install rclone\n"
            return
        }
        guard let vaultRoot = VaultManager.shared.vaultRoot else {
            liveLog = "⚠️ Vault no configurado.\n"
            return
        }

        isRunning = true
        liveLog   = "[\(Date().shortDisplay)] Iniciando backup…\n"

        var anySuccess = false

        for destination in config.destinations where destination.isEnabled {
            let result = await runBackup(
                source:      vaultRoot,
                destination: destination
            )
            lastJobResult = result
            anySuccess    = anySuccess || result.success

            let status = result.success ? "✓" : "✗"
            liveLog += "\(status) \(destination.name) — \(result.bytesFormatted) · \(Int(result.duration))s\n"
            if let err = result.errorMessage {
                liveLog += "  Error: \(err)\n"
            }
        }

        config.lastBackupAt = Date()
        config.lastBackupOK = anySuccess
        saveConfig()
        isRunning = false

        liveLog += "[\(Date().shortDisplay)] Backup finalizado.\n"

        // Guardar log de auditoría
        appendToBackupLog(liveLog)
    }

    /// Ejecutar backup a un destino específico.
    func runBackup(
        source:      URL,
        destination: BackupDestination
    ) async -> BackupJobResult {
        let startedAt = Date()

        // Construir argumentos rclone
        var args: [String] = [
            "sync",
            source.path,
            destination.rcloneRemote,
            "--progress",
            "--stats-one-line",
            "--transfers", "4",
        ]

        // Exclusiones opcionales
        var excludes: [String] = []
        if config.excludeRawPNGs  { excludes.append("*.orig.png") }
        if config.excludeLoRAs    { excludes.append("PrivateLoRAs/**") }
        // Nunca sincronizar los exports de preview al cloud — son derivados
        excludes.append("Export/Previews/**")

        for excl in excludes {
            args += ["--exclude", excl]
        }

        // Verificación post-sync
        if config.verifyAfterBackup {
            args.append("--checksum")
        }

        // Ejecutar rclone
        let (output, exitCode) = await runProcess(executable: rclonePath, arguments: args)

        let success = (exitCode == 0)
        let (transferred, bytes) = parseRcloneStats(from: output)

        // Generar manifiesto SHA-256 si exitoso
        var manifestURL: URL? = nil
        if success {
            manifestURL = await generateManifest(source: source, destination: destination)
        }

        return BackupJobResult(
            startedAt:         startedAt,
            finishedAt:        Date(),
            destination:       destination.name,
            success:           success,
            filesTransferred:  transferred,
            bytesTransferred:  bytes,
            errorMessage:      success ? nil : output,
            manifestURL:       manifestURL
        )
    }

    // MARK: - Manifest Generation

    /// Genera un archivo .manifest.json con hashes SHA-256 de todos los archivos del vault.
    /// Permite verificar que el backup es íntegro y completo.
    @discardableResult
    private func generateManifest(
        source:      URL,
        destination: BackupDestination
    ) async -> URL? {
        let fm = FileManager.default
        guard let logsURL = VaultManager.shared.vaultMetaURL?.appending(path: "backup_logs") else {
            return nil
        }

        try? fm.createDirectory(at: logsURL, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        let dateStr = formatter.string(from: Date())

        let manifestURL = logsURL.appending(
            path: "manifest_\(dateStr)_\(destination.id.uuidString.prefix(8)).json"
        )

        // Enumerate vault (solo archivos importantes, no temporales)
        let enumerator = fm.enumerator(
            at: source,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        var entries: [[String: Any]] = []
        var totalSize: Int64 = 0

        while let fileURL = enumerator?.nextObject() as? URL {
            guard !fileURL.hasDirectoryPath else { continue }

            // Excluir archivos temporales y previews
            let path = fileURL.path
            if path.contains("/Export/Previews/") { continue }
            if path.hasSuffix(".DS_Store") { continue }

            guard let data = try? Data(contentsOf: fileURL) else { continue }

            let sha256 = data.sha256Hex
            let size   = data.count
            totalSize  += Int64(size)

            entries.append([
                "path":   fileURL.path.replacingOccurrences(of: source.path, with: ""),
                "sha256": sha256,
                "size":   size
            ])
        }

        let manifest: [String: Any] = [
            "schema":      "SDPipeline.BackupManifest.v1",
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "destination": destination.rcloneRemote,
            "fileCount":   entries.count,
            "totalBytes":  totalSize,
            "files":       entries
        ]

        if let manifestData = try? JSONSerialization.data(
            withJSONObject: manifest,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? manifestData.write(to: manifestURL, options: .completeFileProtection)
            return manifestURL
        }

        return nil
    }

    // MARK: - rclone Availability

    func checkRcloneAvailability() {
        Task {
            // Probar rutas comunes
            let candidatePaths = [
                "/usr/local/bin/rclone",
                "/opt/homebrew/bin/rclone",   // Apple Silicon Homebrew
                "/usr/bin/rclone"
            ]

            for path in candidatePaths {
                if FileManager.default.isExecutableFile(atPath: path) {
                    rclonePath = path
                    rcloneAvailable = true
                    return
                }
            }

            // Intentar `which rclone` como fallback
            let (output, exitCode) = await runProcess(
                executable: "/usr/bin/which",
                arguments:  ["rclone"]
            )
            if exitCode == 0, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                rclonePath      = output.trimmingCharacters(in: .whitespacesAndNewlines)
                rcloneAvailable = true
            } else {
                rcloneAvailable = false
            }
        }
    }

    /// Verificar configuración de un remote específico.
    func testRemote(_ remote: String) async -> (Bool, String) {
        let (output, exitCode) = await runProcess(
            executable: rclonePath,
            arguments:  ["lsd", remote, "--max-depth", "1"]
        )
        return (exitCode == 0, output)
    }

    // MARK: - Process Runner

    private func runProcess(
        executable: String,
        arguments:  [String]
    ) async -> (output: String, exitCode: Int32) {
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments     = arguments

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError  = pipe

            nonisolated(unsafe) var outputData = Data()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if !chunk.isEmpty {
                    outputData.append(chunk)
                    if let text = String(data: chunk, encoding: .utf8) {
                        Task { @MainActor [weak self] in
                            self?.liveLog += text
                        }
                    }
                }
            }

            process.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                let output = String(data: outputData, encoding: .utf8) ?? ""
                continuation.resume(returning: (output, proc.terminationStatus))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(returning: ("Error: \(error.localizedDescription)", -1))
            }
        }
    }

    // MARK: - Stats Parser

    private func parseRcloneStats(from output: String) -> (files: Int, bytes: Int64) {
        // rclone --stats-one-line output: "Transferred: 4.234 MiB in 2s, 2.11 MiB/s, ETA -"
        // Parseado con regex básico

        var files: Int   = 0
        var bytes: Int64 = 0

        for line in output.components(separatedBy: "\n") {
            if line.contains("Transferred:") && line.contains("GiB") {
                // Parse GiB
                let comps = line.components(separatedBy: " ")
                if let idx = comps.firstIndex(where: { $0.contains("GiB") }),
                   idx > 0, let val = Double(comps[idx - 1]) {
                    bytes = Int64(val * 1_073_741_824)
                }
            } else if line.contains("Transferred:") && line.contains("MiB") {
                let comps = line.components(separatedBy: " ")
                if let idx = comps.firstIndex(where: { $0.contains("MiB") }),
                   idx > 0, let val = Double(comps[idx - 1]) {
                    bytes = Int64(val * 1_048_576)
                }
            }

            if line.contains("Checks:") || line.contains("Transferred:") {
                let comps = line.components(separatedBy: " ").compactMap { Int($0) }
                if let first = comps.first { files += first }
            }
        }

        return (files, bytes)
    }

    // MARK: - Audit Log

    private func appendToBackupLog(_ entry: String) {
        guard let logsURL = VaultManager.shared.vaultMetaURL?.appending(path: "backup_logs") else {
            return
        }
        try? FileManager.default.createDirectory(at: logsURL, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        let logFile = logsURL.appending(path: "backup_\(formatter.string(from: Date())).log")

        let line = "\n--- \(Date().shortDisplay) ---\n\(entry)"
        if let data = line.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: logFile) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            } else {
                try? data.write(to: logFile, options: .completeFileProtection)
            }
        }
    }

    // MARK: - Persistence

    private var configURL: URL? {
        VaultManager.shared.vaultMetaURL?.appending(path: "backup_config.json")
    }

    func saveConfig() {
        guard let url = configURL else { return }
        if let data = try? JSONEncoder.pretty.encode(config) {
            try? data.write(to: url, options: .completeFileProtection)
        }
    }

    private func loadConfig() {
        guard let url = configURL,
              let data = try? Data(contentsOf: url),
              let loaded = try? JSONDecoder.iso8601.decode(BackupConfig.self, from: data)
        else { return }
        self.config = loaded
    }
}

// MARK: - BackupSettingsView
// Panel de configuración de backup para incluir en Settings.

struct BackupSettingsView: View {

    @StateObject private var backup = BackupManager.shared
    @State private var showAddDestination = false
    @State private var newDestName:    String = ""
    @State private var newDestRemote:  String = ""
    @State private var newDestType:    BackupManager.BackupDestination.DestinationType = .b2

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // Header
            HStack {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 15))
                    .foregroundColor(Color(hex: "#3de3c0"))
                Text("Backup Automático")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                Spacer()

                // Estado rclone
                HStack(spacing: 5) {
                    Circle()
                        .fill(backup.rcloneAvailable ? Color.green : Color.red)
                        .frame(width: 6, height: 6)
                    Text(backup.rcloneAvailable ? "rclone OK" : "rclone no encontrado")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(backup.rcloneAvailable ? .green : Color(hex: "#ff7260"))
                }
            }

            // Instalación si falta
            if !backup.rcloneAvailable {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 12))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("rclone no instalado")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.orange)
                        Text("brew install rclone")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                        Text("Luego: rclone config  →  configurar tu remote")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Verificar") { backup.checkRcloneAvailability() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.white.opacity(0.07))
                        .cornerRadius(6)
                        .foregroundColor(.white)
                }
                .padding(12)
                .background(Color.orange.opacity(0.08))
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.2), lineWidth: 1))
            }

            // Programación
            HStack(spacing: 12) {
                Text("Frecuencia")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Picker("", selection: $backup.config.schedule) {
                    ForEach(BackupManager.BackupSchedule.allCases, id: \.self) { s in
                        Text(s.rawValue).tag(s)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 140)
                .onChange(of: backup.config.schedule) { _, _ in
                    backup.saveConfig()
                    backup.startScheduler()
                }

                if let lastBackup = backup.config.lastBackupAt {
                    Spacer()
                    HStack(spacing: 4) {
                        Image(systemName: backup.config.lastBackupOK ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(backup.config.lastBackupOK ? .green : .orange)
                        Text("Último: \(lastBackup.shortDisplay)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
            }

            // Opciones
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Excluir PNGs originales (.orig.png) del backup", isOn: $backup.config.excludeRawPNGs)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Toggle("Excluir carpeta PrivateLoRAs (safetensors grandes)", isOn: $backup.config.excludeLoRAs)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Toggle("Verificar integridad después del backup (--checksum)", isOn: $backup.config.verifyAfterBackup)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .onChange(of: backup.config.excludeRawPNGs) { _, _ in backup.saveConfig() }
            .onChange(of: backup.config.excludeLoRAs) { _, _ in backup.saveConfig() }
            .onChange(of: backup.config.verifyAfterBackup) { _, _ in backup.saveConfig() }

            Divider().background(Color.white.opacity(0.06))

            // Destinos
            HStack {
                Text("Destinos")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
                Spacer()
                Button(action: { showAddDestination = true }) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus").font(.system(size: 10))
                        Text("Añadir")
                    }
                    .font(.system(size: 11))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.white.opacity(0.07))
                    .cornerRadius(5)
                    .foregroundColor(.white)
                }
                .buttonStyle(.plain)
            }

            if backup.config.destinations.isEmpty {
                Text("Sin destinos configurados. Añade al menos uno.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(backup.config.destinations) { dest in
                    HStack(spacing: 10) {
                        Image(systemName: dest.type.icon)
                            .font(.system(size: 12))
                            .foregroundColor(Color(hex: "#7c6af7"))
                            .frame(width: 20)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(dest.name)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.white)
                            Text(dest.rcloneRemote)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        // Toggle habilitado
                        Toggle("", isOn: Binding(
                            get: { dest.isEnabled },
                            set: { enabled in
                                if let idx = backup.config.destinations.firstIndex(where: { $0.id == dest.id }) {
                                    backup.config.destinations[idx].isEnabled = enabled
                                    backup.saveConfig()
                                }
                            }
                        ))
                        .toggleStyle(.switch)
                        .scaleEffect(0.75)

                        // Eliminar
                        Button(action: {
                            backup.config.destinations.removeAll { $0.id == dest.id }
                            backup.saveConfig()
                        }) {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                                .foregroundColor(.red.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(10)
                    .background(Color.white.opacity(0.04))
                    .cornerRadius(6)
                }
            }

            // Botón backup manual
            HStack(spacing: 10) {
                Button(action: {
                    Task { await backup.runAllBackups() }
                }) {
                    HStack(spacing: 6) {
                        if backup.isRunning {
                            ProgressView().scaleEffect(0.6).progressViewStyle(.circular)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 11))
                        }
                        Text(backup.isRunning ? "Ejecutando…" : "Backup ahora")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(
                        backup.rcloneAvailable && !backup.isRunning && !backup.config.destinations.isEmpty
                            ? Color(hex: "#3de3c0").opacity(0.15)
                            : Color.white.opacity(0.05)
                    )
                    .cornerRadius(6)
                    .foregroundColor(
                        backup.rcloneAvailable && !backup.isRunning && !backup.config.destinations.isEmpty
                            ? Color(hex: "#3de3c0")
                            : .secondary
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(
                                backup.rcloneAvailable && !backup.isRunning && !backup.config.destinations.isEmpty
                                    ? Color(hex: "#3de3c0").opacity(0.3)
                                    : Color.white.opacity(0.06),
                                lineWidth: 1
                            )
                    )
                }
                .buttonStyle(.plain)
                .disabled(backup.isRunning || !backup.rcloneAvailable || backup.config.destinations.isEmpty)

                if let result = backup.lastJobResult {
                    HStack(spacing: 4) {
                        Image(systemName: result.success ? "checkmark.circle" : "xmark.circle")
                            .foregroundColor(result.success ? .green : .red)
                            .font(.system(size: 11))
                        Text(result.success
                             ? "\(result.bytesFormatted) · \(Int(result.duration))s"
                             : result.errorMessage ?? "Error")
                            .font(.system(size: 11))
                            .foregroundColor(result.success ? .secondary : Color(hex: "#ff7260"))
                    }
                }
            }

            // Log en vivo (si está corriendo)
            if backup.isRunning && !backup.liveLog.isEmpty {
                ScrollView {
                    Text(backup.liveLog)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: 80)
                .background(Color.black.opacity(0.3))
                .cornerRadius(6)
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.025))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.06), lineWidth: 1))

        // Sheet añadir destino
        .sheet(isPresented: $showAddDestination) {
            addDestinationSheet
        }
    }

    var addDestinationSheet: some View {
        VStack(spacing: 16) {
            Text("Añadir Destino de Backup")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)

            VStack(alignment: .leading, spacing: 8) {
                Text("Tipo").font(.system(size: 12)).foregroundColor(.secondary)
                Picker("Tipo", selection: $newDestType) {
                    ForEach(BackupManager.BackupDestination.DestinationType.allCases, id: \.self) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.menu)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Nombre").font(.system(size: 12)).foregroundColor(.secondary)
                TextField("Ej: Backblaze B2 Principal", text: $newDestName)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Remote rclone (destino)").font(.system(size: 12)).foregroundColor(.secondary)
                TextField("Ej: b2:mi-bucket/StudioIA", text: $newDestRemote)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                Text("Formato: remote:bucket/path  o  /ruta/local/absoluta")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 10) {
                Button("Cancelar") { showAddDestination = false }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(6)
                    .foregroundColor(.secondary)

                Button("Añadir") {
                    guard !newDestRemote.isEmpty, !newDestName.isEmpty else { return }
                    let dest = BackupManager.BackupDestination(
                        name:          newDestName,
                        type:          newDestType,
                        rcloneRemote:  newDestRemote
                    )
                    backup.config.destinations.append(dest)
                    backup.saveConfig()
                    showAddDestination = false
                    newDestName   = ""
                    newDestRemote = ""
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16).padding(.vertical, 7)
                .background(Color(hex: "#7c6af7"))
                .cornerRadius(6)
                .foregroundColor(.white)
                .disabled(newDestName.isEmpty || newDestRemote.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 400)
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
    }
}
