import AppKit
import SwiftUI

@main
struct SDPipelineApp: App {

    @StateObject private var vault = VaultManager.shared
    @StateObject private var env   = AppEnvironment.shared

    // MARK: - App Init

    init() {
        // Configure URLSession for SD API (high timeout, no caching)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest  = 600
        config.timeoutIntervalForResource = 600
        config.requestCachePolicy         = .reloadIgnoringLocalCacheData
        URLSession.shared.configuration.timeoutIntervalForRequest = 600
    }

    // MARK: - Scene

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vault)
                .environmentObject(env)
                .sheet(isPresented: $vault.showFirstRunSheet) {
                    VaultSetupSheet()
                        .environmentObject(vault)
                        .onDisappear {
                            ProjectManager.shared.createDefaultProjectIfNeeded()
                        }
                }
                .task { await env.boot() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1400, height: 860)
        .commands { appCommands }

        Settings {
            SettingsView()
        }
    }

    // MARK: - Boot Sequence
    // ↳ Delegado a AppEnvironment.boot() — ver AppEnvironment.swift

    // MARK: - Menu Commands

    @CommandsBuilder
    private var appCommands: some Commands {
        CommandGroup(replacing: .newItem) {}

        // ── Vault ─────────────────────────────────────────────────────────
        CommandMenu("Vault") {
            Button("Abrir Vault en Finder") {
                if let url = VaultManager.shared.vaultRoot {
                    NSWorkspace.shared.open(url)
                }
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])

            Divider()

            Button("Re-configurar Vault…") {
                vault.showFirstRunSheet = true
            }

            Divider()

            Button("Backup ahora") {
                Task { await BackupManager.shared.runAllBackups() }
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])

            Button("Verificar integridad del vault") {
                Task { await IntegrityManager.shared.runFullVerification() }
            }

            Divider()

            Button("Encolar exports pendientes") {
                JobQueueManager.shared.enqueueAllPendingExports()
            }
        }

        // ── Proyecto ──────────────────────────────────────────────────────
        CommandMenu("Proyecto") {
            Button("Nuevo proyecto…") {
                ProjectManager.shared.showProjectPicker = true
            }
            .keyboardShortcut("n", modifiers: [.command, .shift, .option])

            Divider()

            ForEach(ProjectManager.shared.activeProjects.prefix(6)) { project in
                Button(project.name) {
                    ProjectManager.shared.setActive(project)
                }
            }
        }

        // ── Sesión ────────────────────────────────────────────────────────
        CommandMenu("Sesión") {
            Button("Nueva sesión de contenido…") {
                NotificationCenter.default.post(name: .showNewSession, object: nil)
            }
            .keyboardShortcut("n", modifiers: [.command, .option])

            Divider()

            Button("Cerrar sesión activa") {
                if let active = ContentSessionManager.shared.activeSession {
                    ContentSessionManager.shared.close(active)
                }
            }
            .disabled(ContentSessionManager.shared.activeSession == nil)
        }

        // ── Pipeline ──────────────────────────────────────────────────────
        CommandMenu("Pipeline") {
            Button("Generar") {
                NotificationCenter.default.post(name: .triggerGenerate, object: nil)
            }
            .keyboardShortcut(.return, modifiers: [.command])

            Button("Interrumpir generación") {
                NotificationCenter.default.post(name: .interruptGeneration, object: nil)
            }
            .keyboardShortcut(".", modifiers: [.command])

            Divider()

            Button("X/Y Plot…") {
                NotificationCenter.default.post(name: .showXYPlot, object: nil)
            }
            .keyboardShortcut("p", modifiers: [.command, .option])

            Button("Batch…") {
                NotificationCenter.default.post(name: .showBatchView, object: nil)
            }
            .keyboardShortcut("k", modifiers: [.command, .option])

            Divider()

            Button("Curator de rating…") {
                NotificationCenter.default.post(name: .showBatchRating, object: nil)
            }
            .keyboardShortcut("r", modifiers: [.command, .option])

            Divider()

            Button("Pausar cola de jobs") {
                JobQueueManager.shared.pauseQueue()
            }

            Button("Reanudar cola de jobs") {
                JobQueueManager.shared.startQueue()
            }

            Button("Limpiar historial de cola") {
                JobQueueManager.shared.clearHistory()
            }
        }

        // ── Seguridad ─────────────────────────────────────────────────────
        CommandMenu("Seguridad") {
            Button("Ver logs cifrados") {
                NotificationCenter.default.post(name: .showSecurityLogs, object: nil)
            }

            Button("Exportar audit report…") {
                NotificationCenter.default.post(name: .exportAuditReport, object: nil)
            }

            Divider()

            Button("Purgar metadatos EXIF (Kill-Switch)") {
                NotificationCenter.default.post(name: .exifKillSwitch, object: nil)
            }
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let showNewSession      = Notification.Name("SDPipeline.showNewSession")
    static let showXYPlot          = Notification.Name("SDPipeline.showXYPlot")
    static let showBatchView       = Notification.Name("SDPipeline.showBatchView")
    static let showBatchRating     = Notification.Name("SDPipeline.showBatchRating")
    static let showProjectPicker   = Notification.Name("SDPipeline.showProjectPicker")
    static let triggerGenerate     = Notification.Name("SDPipeline.triggerGenerate")
    static let interruptGeneration = Notification.Name("SDPipeline.interruptGeneration")
    static let showSecurityLogs    = Notification.Name("SDPipeline.showSecurityLogs")
    static let exportAuditReport   = Notification.Name("SDPipeline.exportAuditReport")
    static let exifKillSwitch      = Notification.Name("SDPipeline.exifKillSwitch")
    static let projectDidChange    = Notification.Name("SDPipeline.projectDidChange")
}

// MARK: - ContentSessionManager compatibility shim

extension ContentSessionManager {
    func close(session: ContentSession) { close(session) }
}

// MARK: - IntegrityManager scheduled check

extension IntegrityManager {
    /// Lightweight scheduled check — only warns, doesn't block UI.
    func runScheduledCheck() async {
        let lastRun = UserDefaults.standard.object(forKey: "integrity.lastScheduledCheck") as? Date
        let interval: TimeInterval = 7 * 86400 // weekly
        guard lastRun == nil || Date().timeIntervalSince(lastRun!) > interval else { return }
        await runFullVerification()
        UserDefaults.standard.set(Date(), forKey: "integrity.lastScheduledCheck")
    }
}

// MARK: - JobQueueManager enqueueAllPendingExports

extension JobQueueManager {
    func enqueueAllPendingExports() {
        let assets = AssetStore.shared.fetchAllAssets(limit: 200)
        let pending = assets.filter {
            $0.statusEnum == .approved &&
            ($0.cleanPath == nil || ($0.cleanPath?.isEmpty ?? true))
        }
        for asset in pending {
            let job = GenerationJob(
                name:       "Export: \(asset.displayTitle)",
                request:    SDRequest(prompt: "[export-only]"),
                settings:   .default,
                priority:   .normal,
                sessionTag: asset.sessionTag
            )
            enqueue(job)
        }
        if !pending.isEmpty {
            ZeroKnowledgeLog.shared.write(
                category: .exportPerformed,
                message:  "Enqueued \(pending.count) pending exports"
            )
        }
    }
}
