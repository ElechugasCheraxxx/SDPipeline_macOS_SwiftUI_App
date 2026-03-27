import AppKit
import SwiftUI

@main
struct SDPipelineApp: App {

    @StateObject private var vault = VaultManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vault)
                // Primera ejecución: mostrar selector de vault si no está configurado
                .sheet(isPresented: $vault.showFirstRunSheet) {
                    VaultSetupSheet()
                        .environmentObject(vault)
                }
                .task {
                    vault.checkFirstRun()
                    LicenseVault.shared.generateAllTemplates()
                    GPUMonitor.shared.detectDevice()
                    BackupManager.shared.startScheduler()          // ← Backups automáticos
                    _ = PromptVersioningStore.shared               // ← Inicializar eager
                _ = TaggingEngine.shared                        // ← Index de tags
                _ = WildcardEngine.shared                       // ← Wildcards engine
                _ = DashboardViewModel.shared                   // ← KPIs precalculados
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1340, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}

            // ── Menú Vault ──────────────────────────────────────────────
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
            }
        }

        // ── Panel de Ajustes (Cmd+,) ─────────────────────────────────
        Settings {
            SettingsView()
        }
    }
}

