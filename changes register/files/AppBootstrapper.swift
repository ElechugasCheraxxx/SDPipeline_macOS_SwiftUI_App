import SwiftUI
import AppKit

// ══════════════════════════════════════════════════════
//  AppBootstrapper.swift — Application
//  Único responsable de crear y configurar la ventana flotante.
//  Antes vivía en AppDelegate dentro de BlackCompanyApp.swift
// ══════════════════════════════════════════════════════

final class AppBootstrapper: NSObject, NSApplicationDelegate {
    private var window: NSPanel!

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = buildPanel()
        window.contentView = NSHostingView(rootView: HomeView())
        window.center()
        window.makeKeyAndOrderFront(nil)

        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
    }

    // ── Panel factory ─────────────────────────────────
    private func buildPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 310),
            styleMask: [
                .borderless,
                .nonactivatingPanel,
                .hudWindow,
                .utilityWindow
            ],
            backing: .buffered,
            defer: false
        )
        panel.level                    = .floating
        panel.isMovableByWindowBackground = true
        panel.backgroundColor          = .clear
        panel.isOpaque                 = false
        panel.hasShadow                = true
        panel.collectionBehavior       = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed     = false
        return panel
    }
}
