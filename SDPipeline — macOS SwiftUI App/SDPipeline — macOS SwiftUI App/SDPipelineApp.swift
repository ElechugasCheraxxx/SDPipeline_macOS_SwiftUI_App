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
                    
                    // ← NUEVO
                    GPUMonitor.shared.detectDevice()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1340, height: 820)   // +140px para acomodar galería
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
            }
        }
    }
}
