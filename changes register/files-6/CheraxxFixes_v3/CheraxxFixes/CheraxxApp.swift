// CheraxxApp.swift
// CORRECCIONES:
// ✅ Singletons descontrolados eliminados:
//    WindowTracker, KeyMapper, OverlayManager y ProfileStore se crean
//    una sola vez aquí y se pasan por @Environment. Ningún subsistema
//    accede a instancias mediante .shared excepto MouseSimulator
//    (que solo actúa, no observa estado).
// ✅ CheraxxCommands está en Commands/CheraxxCommands.swift — no aquí.
// ✅ autoSwitchProfile() conectado a NSWorkspace observer.
// ✅ Toggle del mapper desde notificación de menú.
// ✅ Logger estructurado.

import SwiftUI
import AppKit
import os

private let log = Logger(subsystem: "com.cheraxx.keymapper", category: "App")

@main
struct CheraxxApp: App {

    // MARK: - Árbol de dependencias (única fuente de verdad)
    @State private var profileStore   = ProfileStore()
    @State private var windowTracker  = WindowTracker()
    @State private var keyMapper      = KeyMapper()          // usa EventTapManager internamente
    @State private var overlayManager = OverlayManager()

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // ── Menú de la barra de estado ──────────────────────────────────
        MenuBarExtra("Cheraxx", systemImage: menuBarIcon) {
            MenuBarView()
                .environment(keyMapper)
                .environment(profileStore)
                .environment(windowTracker)
        }
        .menuBarExtraStyle(.window)

        // ── Ventana principal del editor ────────────────────────────────
        Window("Cheraxx KeyMapper", id: "main") {
            ContentView()
                .environment(keyMapper)
                .environment(profileStore)
                .environment(windowTracker)
                .environment(overlayManager)
                .frame(minWidth: 960, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        // CheraxxCommands definido una sola vez en Commands/CheraxxCommands.swift
        .commands { CheraxxCommands(profileStore: profileStore) }
        .defaultSize(width: 1100, height: 700)
    }

    // MARK: - Inicialización de componentes
    init() {
        // No se puede llamar métodos de instancia en init() antes de que
        // los @State se hayan creado; la configuración se hace en .task{}
        // dentro de ContentView (ver onAppSetup abajo).
    }

    private var menuBarIcon: String {
        keyMapper.isEnabled ? "keyboard.fill" : "keyboard"
    }
}

// MARK: - Configuración post-init
// Añade este modificador a ContentView en escenas que necesiten setup inicial.
struct AppSetupModifier: ViewModifier {
    var keyMapper:      KeyMapper
    var profileStore:   ProfileStore
    var windowTracker:  WindowTracker
    var overlayManager: OverlayManager

    func body(content: Content) -> some View {
        content
            .task {
                // 0. FIX dos WindowTrackers: inyectar el WindowTracker compartido de CheraxxApp
                //    en KeyMapper ANTES de cualquier otro setup.
                //    KeyMapper() crea su propio WindowTracker interno por defecto;
                //    aquí lo reemplazamos con la instancia compartida para que todos
                //    los componentes (OverlayManager, KeyMapper, CheraxxApp) observen
                //    el mismo estado de la ventana de Mirroring.
                keyMapper.windowTracker = windowTracker

                // 1. Conectar perfil inicial al mapper (ahora usa el windowTracker correcto)
                if let first = profileStore.selectedProfile {
                    keyMapper.setProfile(first)
                }

                // 2. Conectar OverlayManager (reactivo, sin NotificationCenter)
                overlayManager.setup(keyMapper: keyMapper, windowTracker: windowTracker)

                // 3. Iniciar tracking de ventana
                windowTracker.startTracking()

                // 4. Escuchar cambios de perfil para auto-switch
                setupAutoSwitch()

                // 5. Escuchar comando de toggle desde el menú
                NotificationCenter.default.addObserver(
                    forName: .toggleKeyMapper,
                    object: nil, queue: .main
                ) { _ in keyMapper.toggle() }

                log.info("App configurada — perfil inicial: \(profileStore.selectedProfile?.name ?? "ninguno")")
            }
            .onChange(of: profileStore.selectedProfile) { _, newProfile in
                keyMapper.setProfile(newProfile)
            }
    }

    // MARK: - Auto-switch de perfil por bundle ID de la app activa
    private func setupAutoSwitch() {
        // WindowTracker ya observa NSWorkspace.didActivateApplicationNotification.
        // Aquí reaccionamos al cambio de activeAppBundleID con withObservationTracking.
        observeActiveApp()
    }

    private func observeActiveApp() {
        withObservationTracking {
            _ = windowTracker.activeAppBundleID
        } onChange: {
            Task { @MainActor in
                autoSwitch(bundleID: windowTracker.activeAppBundleID)
                observeActiveApp() // re-programar
            }
        }
    }

    private func autoSwitch(bundleID: String?) {
        guard let bundleID else { return }
        // Buscar el primer perfil cuyo appBundleID coincide
        if let match = profileStore.profiles.first(where: {
            $0.appBundleID?.lowercased() == bundleID.lowercased()
        }), match.id != profileStore.selectedProfile?.id {
            profileStore.selectedProfile = match
            log.info("Auto-switch a perfil '\(match.name)' para \(bundleID)")
        }
    }
}

extension View {
    func onAppSetup(keyMapper: KeyMapper,
                    profileStore: ProfileStore,
                    windowTracker: WindowTracker,
                    overlayManager: OverlayManager) -> some View {
        modifier(AppSetupModifier(
            keyMapper:      keyMapper,
            profileStore:   profileStore,
            windowTracker:  windowTracker,
            overlayManager: overlayManager
        ))
    }
}
