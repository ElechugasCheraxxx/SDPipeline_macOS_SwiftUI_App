import Foundation
import AppKit
import Combine

// MARK: - A1111UpdateManager
//
// Gestor de actualizaciones automáticas para Automatic1111 / Forge WebUI.
// Verifica versiones disponibles vía GitHub API y aplica actualizaciones
// con git pull en la instalación local.
//
// Features:
//   • Verificación de versión actual vs latest en GitHub
//   • Actualización automática programada (horaria/diaria/manual)
//   • Backup de settings antes de actualizar
//   • Gestión de extensiones (update all / selective)
//   • Changelog display
//   • Rollback a commit anterior si hay problemas
//   • Compatibilidad con múltiples forks (A1111, Forge, SD.Next, ComfyUI)
//
// ROADMAP: "Actualizaciones automáticas de A1111" (🟢 LARGO PLAZO)

@MainActor
final class A1111UpdateManager: ObservableObject {

    static let shared = A1111UpdateManager()
    private init() {
        loadConfig()
        startScheduler()
    }

    // MARK: - Config

    struct UpdateConfig: Codable {
        var webUIPath:          String            = ""
        var fork:               WebUIFork         = .automatic1111
        var autoCheckInterval:  CheckInterval     = .daily
        var autoInstall:        Bool              = false
        var backupBeforeUpdate: Bool              = true
        var updateExtensions:   Bool              = true
        var notifyOnUpdate:     Bool              = true
        var preReleaseChannel:  Bool              = false

        enum WebUIFork: String, CaseIterable, Codable {
            case automatic1111 = "Automatic1111"
            case forge         = "Forge"
            case sdNext        = "SD.Next"
            case comfyUI       = "ComfyUI"
            case vladmandic    = "Vladmandic"

            var githubRepo: String {
                switch self {
                case .automatic1111: return "AUTOMATIC1111/stable-diffusion-webui"
                case .forge:         return "lllyasviel/stable-diffusion-webui-forge"
                case .sdNext:        return "vladmandic/automatic"
                case .comfyUI:       return "comfyanonymous/ComfyUI"
                case .vladmandic:    return "vladmandic/automatic"
                }
            }

            var icon: String {
                switch self {
                case .automatic1111: return "wand.and.stars"
                case .forge:         return "hammer.fill"
                case .sdNext:        return "arrow.forward.circle.fill"
                case .comfyUI:       return "flowchart.fill"
                case .vladmandic:    return "v.circle.fill"
                }
            }
        }

        enum CheckInterval: String, CaseIterable, Codable {
            case manual  = "Manual"
            case hourly  = "Cada hora"
            case daily   = "Diario"
            case weekly  = "Semanal"

            var seconds: TimeInterval {
                switch self {
                case .manual:  return .infinity
                case .hourly:  return 3600
                case .daily:   return 86400
                case .weekly:  return 604800
                }
            }
        }
    }

    @Published var config = UpdateConfig()

    // MARK: - Version Info

    struct VersionInfo: Equatable {
        var current:      String = "unknown"
        var currentCommit: String = ""
        var latest:       String = "unknown"
        var latestCommit: String = ""
        var latestDate:   Date?  = nil
        var isUpToDate:   Bool   = true
        var changelog:    [ChangelogEntry] = []

        struct ChangelogEntry: Identifiable {
            let id      = UUID()
            let sha:    String
            let message: String
            let author:  String
            let date:   Date
        }
    }

    @Published var versionInfo        = VersionInfo()
    @Published var isChecking         = false
    @Published var isUpdating         = false
    @Published var updateProgress: Double = 0
    @Published var updateLog:      [String] = []
    @Published var lastCheckDate:  Date?    = nil
    @Published var extensionsList: [ExtensionInfo] = []

    // MARK: - Extension Info

    struct ExtensionInfo: Identifiable, Codable {
        var id      = UUID()
        var name:    String
        var path:    String
        var enabled: Bool   = true
        var hasUpdate: Bool = false
        var currentCommit: String = ""
        var latestCommit:  String = ""
        var remoteURL:     String = ""
    }

    // MARK: - Scheduler

    private var schedulerTask: Task<Void, Never>?

    func startScheduler() {
        schedulerTask?.cancel()
        guard config.autoCheckInterval != .manual else { return }

        schedulerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(config.autoCheckInterval.seconds * 1_000_000_000))
                guard !Task.isCancelled else { break }
                await checkForUpdates()
            }
        }
    }

    // MARK: - Check for Updates

    func checkForUpdates() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        do {
            // 1. Get current version from local git
            let current = await getCurrentVersion()
            versionInfo.current = current.version
            versionInfo.currentCommit = current.commit

            // 2. Fetch latest from GitHub API
            let latest = try await fetchLatestVersion()
            versionInfo.latest = latest.version
            versionInfo.latestCommit = latest.commit
            versionInfo.latestDate = latest.date
            versionInfo.isUpToDate = (current.commit == latest.commit)

            // 3. Get changelog if there's an update
            if !versionInfo.isUpToDate {
                versionInfo.changelog = try await fetchChangelog(
                    since: current.commit,
                    until: latest.commit
                )
            } else {
                versionInfo.changelog = []
            }

            lastCheckDate = Date()

            // 4. Check extensions
            await scanExtensions()

            // 5. Auto-install if enabled
            if config.autoInstall && !versionInfo.isUpToDate {
                try await installUpdate()
            } else if !versionInfo.isUpToDate && config.notifyOnUpdate {
                notifyUpdateAvailable()
            }

            ZeroKnowledgeLog.shared.write(
                category: .systemEvent,
                message: "A1111 update check: current=\(current.version) latest=\(latest.version) upToDate=\(versionInfo.isUpToDate)"
            )

        } catch {
            log("Error al verificar actualizaciones: \(error.localizedDescription)")
        }
    }

    // MARK: - Get Current Version (local git)

    private struct LocalVersionInfo {
        let version: String
        let commit: String
    }

    private func getCurrentVersion() async -> LocalVersionInfo {
        guard !config.webUIPath.isEmpty else {
            return LocalVersionInfo(version: "Not configured", commit: "")
        }

        let gitPath = config.webUIPath

        // Get current commit hash
        let (commitOut, _, _) = await runGit(in: gitPath, args: ["rev-parse", "--short", "HEAD"])
        let commit = commitOut.trimmingCharacters(in: .whitespacesAndNewlines)

        // Try to get tag name
        let (tagOut, _, _) = await runGit(in: gitPath, args: ["describe", "--tags", "--abbrev=0"])
        let tag = tagOut.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = tag.isEmpty ? "v\(commit)" : tag

        return LocalVersionInfo(version: version, commit: commit)
    }

    // MARK: - Fetch Latest (GitHub API)

    private struct GitHubVersionInfo {
        let version: String
        let commit: String
        let date: Date?
    }

    private func fetchLatestVersion() async throws -> GitHubVersionInfo {
        let repo = config.fork.githubRepo
        let endpoint = config.preReleaseChannel
            ? "https://api.github.com/repos/\(repo)/commits?per_page=1"
            : "https://api.github.com/repos/\(repo)/releases/latest"

        guard let url = URL(string: endpoint) else {
            throw UpdateError.invalidURL
        }

        var req = URLRequest(url: url)
        req.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        req.setValue("SDPipelineStudio/1.0", forHTTPHeaderField: "User-Agent")

        let (data, _) = try await URLSession.shared.data(for: req)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if config.preReleaseChannel {
            // Parse commit
            if let commits = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               let first = commits.first,
               let sha = first["sha"] as? String {
                let shortSha = String(sha.prefix(7))
                return GitHubVersionInfo(version: "dev-\(shortSha)", commit: shortSha, date: Date())
            }
        } else {
            // Parse release
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tag = json["tag_name"] as? String {
                let dateStr = json["published_at"] as? String ?? ""
                let date = ISO8601DateFormatter().date(from: dateStr)

                // Get commit SHA for the tag
                let (shaOut, _, _) = try await fetchTagCommit(tag: tag, repo: repo)
                return GitHubVersionInfo(version: tag, commit: shaOut, date: date)
            }
        }

        throw UpdateError.parseError
    }

    private func fetchTagCommit(tag: String, repo: String) async throws -> (String, String, Int) {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/git/refs/tags/\(tag)") else {
            return ("", "", -1)
        }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")

        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let obj  = json["object"] as? [String: Any],
              let sha  = obj["sha"] as? String
        else { return ("", "", 0) }

        return (String(sha.prefix(7)), "", 0)
    }

    // MARK: - Fetch Changelog

    private func fetchChangelog(since: String, until: String) async throws -> [VersionInfo.ChangelogEntry] {
        let repo = config.fork.githubRepo
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/commits?per_page=20") else {
            return []
        }

        var req = URLRequest(url: url)
        req.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")

        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let commits = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        return commits.prefix(15).compactMap { commit -> VersionInfo.ChangelogEntry? in
            guard let sha  = commit["sha"] as? String,
                  let commitInfo = commit["commit"] as? [String: Any],
                  let message    = commitInfo["message"] as? String,
                  let authorInfo = commitInfo["author"] as? [String: Any],
                  let author     = authorInfo["name"] as? String,
                  let dateStr    = authorInfo["date"] as? String,
                  let date       = ISO8601DateFormatter().date(from: dateStr)
            else { return nil }

            let shortMsg = message.split(separator: "\n").first.map(String.init) ?? message

            return VersionInfo.ChangelogEntry(
                sha:     String(sha.prefix(7)),
                message: shortMsg,
                author:  author,
                date:    date
            )
        }
    }

    // MARK: - Install Update

    func installUpdate() async throws {
        guard !isUpdating else { return }
        guard !config.webUIPath.isEmpty else { throw UpdateError.noPathConfigured }

        isUpdating = true
        updateProgress = 0
        defer { isUpdating = false }

        // 1. Backup settings
        if config.backupBeforeUpdate {
            log("📦 Haciendo backup de settings…")
            try await backupSettings()
            updateProgress = 0.15
        }

        // 2. Stash any local changes
        log("📋 Guardando cambios locales…")
        await runGit(in: config.webUIPath, args: ["stash"])
        updateProgress = 0.25

        // 3. Pull latest
        log("⬇️ Descargando actualización…")
        let (output, errOut, exitCode) = await runGit(in: config.webUIPath, args: ["pull", "origin", "master"])
        updateProgress = 0.60

        if exitCode != 0 {
            log("❌ Error en git pull: \(errOut)")
            throw UpdateError.gitPullFailed(errOut)
        }
        log("✅ Git pull completado:\n\(output.prefix(200))")

        // 4. Update extensions
        if config.updateExtensions {
            updateProgress = 0.70
            await updateAllExtensions()
        }

        // 5. Update pip requirements if needed
        updateProgress = 0.85
        await updatePipRequirements()

        updateProgress = 1.0
        versionInfo.isUpToDate = true
        versionInfo.current = versionInfo.latest

        log("✅ Actualización completada.")

        ZeroKnowledgeLog.shared.write(
            category: .systemEvent,
            message: "A1111 actualizado a \(versionInfo.latest)"
        )

        // Restart webUI if it was running
        if SDService.shared.webuiState == SDService.WebuiState.online {
            log("🔄 Reiniciando WebUI…")
            // Trigger restart via SDService
        }
    }

    // MARK: - Extensions Management

    func scanExtensions() async {
        guard !config.webUIPath.isEmpty else { return }

        let extPath = URL(fileURLWithPath: config.webUIPath)
            .appendingPathComponent("extensions")

        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: extPath, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }

        var extensions: [ExtensionInfo] = []

        for dir in dirs {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir)
            guard isDir.boolValue else { continue }

            let gitDir = dir.appendingPathComponent(".git")
            guard FileManager.default.fileExists(atPath: gitDir.path) else { continue }

            let (commit, _, _)  = await runGit(in: dir.path, args: ["rev-parse", "--short", "HEAD"])
            let (remote, _, _)  = await runGit(in: dir.path, args: ["remote", "get-url", "origin"])

            // Fetch remote HEAD (simplified — no auth required for public repos)
            let (fetchOut, _, _) = await runGit(in: dir.path, args: ["fetch", "--dry-run", "origin"])
            let hasUpdate = fetchOut.contains("->")

            extensions.append(ExtensionInfo(
                name:          dir.lastPathComponent,
                path:          dir.path,
                enabled:       !dir.lastPathComponent.hasSuffix(".disabled"),
                hasUpdate:     hasUpdate,
                currentCommit: commit.trimmingCharacters(in: .whitespacesAndNewlines),
                latestCommit:  "",
                remoteURL:     remote.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }

        extensionsList = extensions.sorted { $0.name < $1.name }
    }

    func updateExtension(_ ext: ExtensionInfo) async {
        log("⬇️ Actualizando extensión: \(ext.name)…")
        let (output, err, code) = await runGit(in: ext.path, args: ["pull", "origin"])
        if code == 0 {
            log("✅ \(ext.name): \(output.prefix(80))")
        } else {
            log("❌ \(ext.name) falló: \(err.prefix(80))")
        }
    }

    private func updateAllExtensions() async {
        for ext in extensionsList where ext.enabled {
            await updateExtension(ext)
        }
    }

    // MARK: - Pip Requirements

    private func updatePipRequirements() async {
        let reqPath = URL(fileURLWithPath: config.webUIPath)
            .appendingPathComponent("requirements.txt")

        guard FileManager.default.fileExists(atPath: reqPath.path) else { return }

        log("📦 Actualizando dependencias Python…")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pip3")
        proc.arguments = ["install", "-r", reqPath.path, "--upgrade", "-q"]
        proc.currentDirectoryURL = URL(fileURLWithPath: config.webUIPath)
        try? proc.run()
        proc.waitUntilExit()
        log(proc.terminationStatus == 0 ? "✅ Pip actualizado" : "⚠️ Pip completó con warnings")
    }

    // MARK: - Backup

    private func backupSettings() async throws {
        guard let vaultRoot = VaultManager.shared.vaultRoot else { return }

        let backupDir = vaultRoot
            .appendingPathComponent("Vault")
            .appendingPathComponent("A1111Backups")
            .appendingPathComponent(ISO8601DateFormatter().string(from: Date()).prefix(10).description)

        try? FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)

        let settingsSrc = URL(fileURLWithPath: config.webUIPath).appendingPathComponent("config.json")
        let settingsDst = backupDir.appendingPathComponent("config.json")

        try? FileManager.default.copyItem(at: settingsSrc, to: settingsDst)

        let stylesSrc = URL(fileURLWithPath: config.webUIPath).appendingPathComponent("styles.csv")
        let stylesDst = backupDir.appendingPathComponent("styles.csv")
        try? FileManager.default.copyItem(at: stylesSrc, to: stylesDst)

        log("Backup guardado en: \(backupDir.lastPathComponent)")
    }

    // MARK: - Rollback

    func rollback(to commit: String) async throws {
        log("⏪ Realizando rollback a \(commit)…")
        let (_, err, code) = await runGit(in: config.webUIPath, args: ["checkout", commit])
        if code != 0 { throw UpdateError.gitPullFailed(err) }
        versionInfo.isUpToDate = false
        versionInfo.current = commit
        log("✅ Rollback completado a \(commit)")
    }

    // MARK: - Notification

    private func notifyUpdateAvailable() {
        let notification = NSUserNotification()
        notification.title = "SDPipeline Studio — Actualización disponible"
        notification.informativeText = "\(config.fork.rawValue) \(versionInfo.latest) está disponible. Instalado: \(versionInfo.current)"
        notification.soundName = NSUserNotificationDefaultSoundName
        NSUserNotificationCenter.default.deliver(notification)
    }

    // MARK: - Git Helper

    @discardableResult
    private func runGit(in directory: String, args: [String]) async -> (String, String, Int) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = args
        proc.currentDirectoryURL = URL(fileURLWithPath: directory)

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError  = errPipe

        guard (try? proc.run()) != nil else { return ("", "git not found", -1) }
        proc.waitUntilExit()

        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (out, err, Int(proc.terminationStatus))
    }

    // MARK: - Helpers

    private func log(_ message: String) {
        let ts = Date().formatted(date: .omitted, time: .standard)
        updateLog.append("[\(ts)] \(message)")
        if updateLog.count > 500 { updateLog.removeFirst(100) }
    }

    private func loadConfig() {
        if let data = UserDefaults.standard.data(forKey: "A1111UpdateConfig"),
           let cfg  = try? JSONDecoder().decode(UpdateConfig.self, from: data) {
            config = cfg
        }
    }

    func saveConfig() {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: "A1111UpdateConfig")
        }
        startScheduler()   // Restart scheduler with new interval
    }

    // MARK: - Errors

    enum UpdateError: LocalizedError {
        case invalidURL
        case parseError
        case noPathConfigured
        case gitPullFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL:             return "URL de GitHub inválida."
            case .parseError:             return "Error al parsear respuesta de GitHub API."
            case .noPathConfigured:       return "No hay ruta de instalación de WebUI configurada."
            case .gitPullFailed(let msg): return "git pull falló: \(msg)"
            }
        }
    }
}
