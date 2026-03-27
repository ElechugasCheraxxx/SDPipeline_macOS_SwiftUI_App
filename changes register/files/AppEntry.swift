import SwiftUI

// ══════════════════════════════════════════════════════
//  AppEntry.swift — Application
//  @main — Único punto de entrada de la app.
//  Reemplaza BlackCompanyApp.swift
// ══════════════════════════════════════════════════════

@main
struct AppEntry: App {
    @NSApplicationDelegateAdaptor(AppBootstrapper.self) var bootstrapper

    var body: some Scene {
        Settings { EmptyView() }
    }
}
