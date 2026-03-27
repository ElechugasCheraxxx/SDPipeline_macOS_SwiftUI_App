import AppKit
import SwiftUI

@main
struct SDPipelineApp: App {

    @StateObject private var vault = VaultManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vault)
                .sheet(isPresented: $vault.showFirstRunSheet) {
                    VaultSetupSheet()
                        .environmentObject(vault)
                        .onDisappear {
                            // After vault setup, init ProjectManager
                            ProjectManager.shared.createDefaultProjectIfNeeded()
                        }
                }
                .task {
                    vault.checkFirstRun()
                    LicenseVault.shared.generateAllTemplates()
                    GPUMonitor.shared.detectDevice()
                    BackupManager.shared.startScheduler()
                    _ = PromptVersioningStore.shared
                    _ = TaggingEngine.shared
                    _ = WildcardEngine.shared
                    _ = DashboardViewModel.shared
                    _ = ContentSessionManager.shared
                    _ = JobQueueManager.shared
                    _ = ProjectManager.shared                    // ← Multi-proyecto
                    _ = IntegrityManager.shared                 // ← Verificación integridad
                    CinematicFilterEngine.shared.loadPersistedPresets()
                    ContentSessionManager.shared.refreshAllStats()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1400, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {}

            // ── Menú Vault ────────────────────────────────────────────────
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

                Divider()

                Button("Encolar exports pendientes") {
                    JobQueueManager.shared.enqueueAllPendingExports()
                }

                Divider()

                Button("Verificar integridad del vault") {
                    Task { await IntegrityManager.shared.runFullVerification() }
                }
            }

            // ── Menú Proyectos ─────────────────────────────────────────────
            CommandMenu("Proyecto") {
                Button("Nuevo proyecto…") {
                    ProjectManager.shared.showProjectPicker = true
                }
                .keyboardShortcut("n", modifiers: [.command, .shift, .option])

                Divider()

                ForEach(ProjectManager.shared.activeProjects.prefix(5)) { project in
                    Button(project.name) {
                        ProjectManager.shared.setActive(project)
                    }
                }
            }

            // ── Menú Sesiones ─────────────────────────────────────────────
            CommandMenu("Sesión") {
                Button("Nueva sesión de contenido…") {
                    NotificationCenter.default.post(name: .showNewSession, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command, .option])

                Divider()

                Button("Cerrar sesión activa") {
                    if let active = ContentSessionManager.shared.activeSession {
                        ContentSessionManager.shared.close(session: active)
                    }
                }
                .disabled(ContentSessionManager.shared.activeSession == nil)
            }

            // ── Menú Pipeline ─────────────────────────────────────────────
            CommandMenu("Pipeline") {
                Button("X/Y Plot…") {
                    NotificationCenter.default.post(name: .showXYPlot, object: nil)
                }
                .keyboardShortcut("p", modifiers: [.command, .option])

                Divider()

                Button("Limpiar cola de jobs") {
                    JobQueueManager.shared.cancelAll()
                }

                Divider()

                Button("Curator de rating…") {
                    // Open batch rating view — via notification or sheet
                    NotificationCenter.default.post(name: .showBatchRating, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
            }
        }

        // ── Panel de Ajustes (Cmd+,) ──────────────────────────────────
        Settings {
            SettingsView()
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let showNewSession  = Notification.Name("SDPipeline.showNewSession")
    static let showXYPlot      = Notification.Name("SDPipeline.showXYPlot")
    static let showBatchRating = Notification.Name("SDPipeline.showBatchRating")
    static let showProjectPicker = Notification.Name("SDPipeline.showProjectPicker")
}

// MARK: - ContentSessionManager close fix
// The app calls close(session:) — ensure the method signature matches.

extension ContentSessionManager {
    /// Close a session (wrapper to handle both signatures).
    func close(session: ContentSession) {
        close(session)
    }
}

// MARK: - JobQueueManager enqueueAllPendingExports fix

extension JobQueueManager {
    /// Enqueue export jobs for all approved assets that don't have a clean export yet.
    func enqueueAllPendingExports() {
        let assets = AssetStore.shared.assets(withStatus: .approved, limit: 200)
        let pending = assets.filter { $0.cleanPath == nil || ($0.cleanPath?.isEmpty ?? true) }

        for asset in pending {
            let job = QueueJob(
                type:     .export,
                title:    "Export: \(asset.baseName ?? asset.id?.uuidString.prefix(8).description ?? "asset")",
                priority: .normal,
                metadata: ["assetID": asset.id?.uuidString ?? ""]
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
