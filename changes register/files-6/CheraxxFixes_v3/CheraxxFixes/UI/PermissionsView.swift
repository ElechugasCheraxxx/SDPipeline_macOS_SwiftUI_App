// UI/PermissionsView.swift
// CORRECCIÓN: MenuBarView ya NO está aquí — se movió a UI/MenuBarView.swift.
// Este archivo solo contiene PermissionsView.

import SwiftUI
import AppKit
import os

private let log = Logger(subsystem: "com.cheraxx.keymapper", category: "Permissions")

struct PermissionsView: View {

    @Environment(KeyMapper.self)     var keyMapper
    @Environment(WindowTracker.self) var windowTracker
    @Environment(\.dismiss)          var dismiss

    // Actualizamos el estado de permisos con un timer liviano
    // (TCC no emite notificaciones, la única forma es sondear con AXIsProcessTrusted)
    @State private var accessibilityGranted = false
    @State private var screenRecordGranted  = false
    @State private var inputMonitorGranted  = false
    @State private var refreshTimer:        Timer?

    var body: some View {
        VStack(spacing: 0) {
            // Cabecera
            HStack {
                Image(systemName: "shield.lefthalf.filled.badge.checkmark")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(CheraxxTheme.accentCyan)
                Text("Permisos del sistema")
                    .font(CheraxxTheme.fontTitle)
                    .foregroundStyle(CheraxxTheme.textPrimary)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(CheraxxTheme.textSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(20)

            Divider()

            // Lista de permisos
            ScrollView {
                VStack(spacing: 12) {
                    PermissionRow(
                        icon:    "accessibility",
                        title:   "Accesibilidad",
                        detail:  "Necesario para interceptar eventos de teclado y ratón mientras otras apps están en primer plano.",
                        granted: accessibilityGranted,
                        action:  openAccessibilitySettings
                    )

                    PermissionRow(
                        icon:    "rectangle.on.rectangle.slash",
                        title:   "Grabación de pantalla",
                        detail:  "Necesario para mostrar la pantalla del iPhone en el editor de controles.",
                        granted: screenRecordGranted,
                        action:  openScreenRecordSettings
                    )

                    PermissionRow(
                        icon:    "keyboard.badge.eye",
                        title:   "Supervisión de entrada",
                        detail:  "Requerido en macOS 10.15+ para monitorear teclas de acceso global.",
                        granted: inputMonitorGranted,
                        action:  openInputMonitorSettings
                    )
                }
                .padding(16)
            }

            Divider()

            // Estado global
            HStack {
                let allGranted = accessibilityGranted && screenRecordGranted && inputMonitorGranted
                Image(systemName: allGranted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(allGranted ? CheraxxTheme.accentGreen : CheraxxTheme.accentOrange)
                Text(allGranted
                     ? "Todos los permisos concedidos"
                     : "Algunos permisos están pendientes")
                    .font(CheraxxTheme.fontCaption)
                    .foregroundStyle(CheraxxTheme.textSecondary)
                Spacer()
                Button("Cerrar") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(16)
        }
        .frame(width: 460, height: 420)
        .background(CheraxxTheme.backgroundPrimary)
        .onAppear {
            refreshPermissions()
            // Sondear cada 2 s mientras el panel está abierto
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
                refreshPermissions()
            }
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }

    // MARK: - Comprobación de permisos
    private func refreshPermissions() {
        accessibilityGranted = AXIsProcessTrusted()
        screenRecordGranted  = CGPreflightScreenCaptureAccess()

        // Input Monitoring: intentar crear un event tap de prueba
        let testMask: CGEventMask = 1 << CGEventType.keyDown.rawValue
        let testTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .listenOnly, eventsOfInterest: testMask,
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
            userInfo: nil
        )
        inputMonitorGranted = testTap != nil
        if let t = testTap { CGEvent.tapEnable(tap: t, enable: false) }
    }

    // MARK: - Apertura de paneles de sistema
    private func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        log.debug("Abriendo ajustes de Accesibilidad")
    }

    private func openScreenRecordSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        log.debug("Abriendo ajustes de Grabación de pantalla")
    }

    private func openInputMonitorSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
        log.debug("Abriendo ajustes de Supervisión de entrada")
    }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - PermissionRow
private struct PermissionRow: View {
    var icon:    String
    var title:   String
    var detail:  String
    var granted: Bool
    var action:  () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(granted ? CheraxxTheme.accentGreen : CheraxxTheme.accentOrange)
                .frame(width: 28)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title)
                        .font(CheraxxTheme.fontHeadline)
                        .foregroundStyle(CheraxxTheme.textPrimary)
                    Spacer()
                    statusBadge
                }
                Text(detail)
                    .font(CheraxxTheme.fontCaption)
                    .foregroundStyle(CheraxxTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !granted {
                Button("Conceder") { action() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(CheraxxTheme.accentCyan)
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(granted ? 0.03 : 0.06))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(granted ? CheraxxTheme.accentGreen.opacity(0.20)
                                        : CheraxxTheme.accentOrange.opacity(0.25), lineWidth: 1)
                }
        }
    }

    private var statusBadge: some View {
        Text(granted ? "Concedido" : "Pendiente")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(granted ? CheraxxTheme.accentGreen : CheraxxTheme.accentOrange)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background {
                Capsule()
                    .fill(granted
                          ? CheraxxTheme.accentGreen.opacity(0.12)
                          : CheraxxTheme.accentOrange.opacity(0.12))
            }
    }
}

// MARK: - Preview
#if DEBUG
#Preview("PermissionsView") {
    PermissionsView()
        .environment(KeyMapper())
        .environment(WindowTracker())
}
#endif
