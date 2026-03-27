// UI/MenuBarView.swift
// CORRECCIÓN: MenuBarView estaba mezclado dentro de PermissionsView.swift.
// Ahora tiene su propio archivo. PermissionsView.swift solo contiene PermissionsView.

import SwiftUI
import os

private let log = Logger(subsystem: "com.cheraxx.keymapper", category: "MenuBar")

struct MenuBarView: View {

    @Environment(KeyMapper.self)      var keyMapper
    @Environment(ProfileStore.self)   var profileStore
    @Environment(WindowTracker.self)  var windowTracker

    @State private var showSettings      = false
    @State private var showPermissions   = false
    @State private var hoveredProfileID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            // Cabecera con estado
            statusHeader

            Divider().padding(.horizontal, 12)

            // Perfil activo y toggle del mapper
            activeProfileSection

            Divider().padding(.horizontal, 12)

            // Lista de perfiles (máx. 5 en el menú)
            profileListSection

            Divider().padding(.horizontal, 12)

            // Pie: permisos y ajustes
            footerSection
        }
        .padding(.vertical, 8)
        .frame(width: 280)
        .sheet(isPresented: $showPermissions) {
            PermissionsView()
                .environment(keyMapper)
                .environment(profileStore)
                .environment(windowTracker)
        }
    }

    // MARK: - Secciones

    private var statusHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(windowTracker.isMirroringActive
                    ? CheraxxTheme.accentCyan : CheraxxTheme.textDisabled)

            VStack(alignment: .leading, spacing: 1) {
                Text("Cheraxx KeyMapper")
                    .font(CheraxxTheme.fontHeadline)
                    .foregroundStyle(CheraxxTheme.textPrimary)
                Text(windowTracker.statusMessage)
                    .font(CheraxxTheme.fontCaption)
                    .foregroundStyle(CheraxxTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var activeProfileSection: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Perfil activo")
                    .font(CheraxxTheme.fontCaption)
                    .foregroundStyle(CheraxxTheme.textSecondary)
                Text(profileStore.selectedProfile?.name ?? "Ninguno")
                    .font(CheraxxTheme.fontBody)
                    .foregroundStyle(CheraxxTheme.textPrimary)
            }
            Spacer()

            // Toggle Mapper
            Button {
                if keyMapper.isEnabled { keyMapper.disable() }
                else                   { keyMapper.enable()  }
                log.debug("Toggle KeyMapper desde MenuBar → \(self.keyMapper.isEnabled ? "ON" : "OFF")")
            } label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(keyMapper.isEnabled ? CheraxxTheme.accentGreen : CheraxxTheme.textDisabled)
                        .frame(width: 7, height: 7)
                    Text(keyMapper.isEnabled ? "Activo" : "Inactivo")
                        .font(CheraxxTheme.fontCaption)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background {
                    Capsule()
                        .fill(keyMapper.isEnabled
                              ? CheraxxTheme.accentGreen.opacity(0.15)
                              : Color.white.opacity(0.06))
                        .overlay {
                            Capsule().stroke(
                                keyMapper.isEnabled
                                    ? CheraxxTheme.accentGreen.opacity(0.40)
                                    : Color.white.opacity(0.10),
                                lineWidth: 1
                            )
                        }
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var profileListSection: some View {
        VStack(spacing: 2) {
            Text("Perfiles")
                .font(CheraxxTheme.fontCaption)
                .foregroundStyle(CheraxxTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 6)

            ForEach(profileStore.profiles.prefix(5)) { profile in
                Button {
                    profileStore.selectedProfile = profile
                    keyMapper.setProfile(profile)
                    log.debug("Perfil seleccionado desde MenuBar: \(profile.name)")
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: profile.iconName ?? "gamecontroller.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Color(hex: profile.accentHex ?? "#00D4FF"))
                        Text(profile.name)
                            .font(CheraxxTheme.fontBody)
                            .foregroundStyle(CheraxxTheme.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if profileStore.selectedProfile?.id == profile.id {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(CheraxxTheme.accentCyan)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        hoveredProfileID == profile.id
                            ? Color.white.opacity(0.07)
                            : Color.clear
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .onHover { hovered in
                    hoveredProfileID = hovered ? profile.id : nil
                }
            }

            if profileStore.profiles.count > 5 {
                Text("+\(profileStore.profiles.count - 5) más")
                    .font(CheraxxTheme.fontCaption)
                    .foregroundStyle(CheraxxTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 4)
            }
        }
        .padding(.bottom, 4)
    }

    private var footerSection: some View {
        HStack(spacing: 0) {
            Button("Permisos") {
                showPermissions = true
            }
            .buttonStyle(.plain)
            .font(CheraxxTheme.fontCaption)
            .foregroundStyle(CheraxxTheme.textSecondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Spacer()

            Button("Salir") {
                log.info("App terminada desde MenuBar")
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(CheraxxTheme.fontCaption)
            .foregroundStyle(CheraxxTheme.textSecondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }
}

// MARK: - Preview
#if DEBUG
#Preview("MenuBarView") {
    MenuBarView()
        .environment(KeyMapper())
        .environment(ProfileStore())
        .environment(WindowTracker())
        .background(CheraxxTheme.backgroundPrimary)
}
#endif
