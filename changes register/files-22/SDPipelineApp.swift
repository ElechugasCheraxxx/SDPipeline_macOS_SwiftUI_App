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
                    _ = ContentSessionManager.shared       // ← Motor de sesiones narrativas
                    _ = JobQueueManager.shared             // ← Cola de jobs
                    CinematicFilterEngine.shared.loadPersistedPresets() // ← Filtros persistidos
                    ContentSessionManager.shared.refreshAllStats()      // ← Stats de sesiones
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
            }

            // ── Menú Sesiones ─────────────────────────────────────────────
            CommandMenu("Sesión") {
                Button("Nueva sesión de contenido…") {
                    // Trigger via notification — ContentView escucha
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
    static let showNewSession = Notification.Name("SDPipeline.showNewSession")
    static let showXYPlot     = Notification.Name("SDPipeline.showXYPlot")
}
