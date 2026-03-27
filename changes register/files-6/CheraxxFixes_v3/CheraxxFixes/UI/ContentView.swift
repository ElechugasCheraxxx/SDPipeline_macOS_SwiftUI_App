// UI/ContentView.swift
// CORRECCIONES:
// ✅ CheraxxCommands eliminado de este archivo (ya no está duplicado).
//    La definición única está en Commands/CheraxxCommands.swift.
// ✅ onAppSetup() conecta todos los componentes sin duplicar lógica.
// ✅ Perfil seleccionado único: profileStore.selectedProfile es la fuente de verdad.
// ✅ Preview añadido.
// ✅ Todo en español — sin mezcla de idiomas.

import SwiftUI
import os

private let log = Logger(subsystem: "com.cheraxx.keymapper", category: "ContentView")

struct ContentView: View {

    @Environment(KeyMapper.self)      var keyMapper
    @Environment(ProfileStore.self)   var profileStore
    @Environment(WindowTracker.self)  var windowTracker
    @Environment(OverlayManager.self) var overlayManager

    // Panel lateral
    @State private var sidebarWidth: CGFloat = 240
    @State private var showSidebar            = true
    @State private var showImport             = false
    @State private var showExport             = false
    @State private var showNewProfile         = false
    @State private var importError:           Error?    = nil
    @State private var showImportError        = false

    var body: some View {
        HStack(spacing: 0) {
            // ── Panel lateral: lista de perfiles ──────────────────────
            if showSidebar {
                ProfileSidebarView(
                    onNewProfile:  { showNewProfile = true },
                    onImport:      { showImport = true },
                    onExport:      { showExport = true }
                )
                .frame(width: sidebarWidth)
                .background(CheraxxTheme.backgroundSecondary)

                Divider()
            }

            // ── Canvas principal ───────────────────────────────────────
            Group {
                if let profile = Binding<MappingProfile>(
                    get: { profileStore.selectedProfile ?? MappingProfile(name: "Sin perfil") },
                    set: { profileStore.update($0) }
                ) as Binding<MappingProfile>? {
                    MappingCanvasView(profile: profile)
                        .id(profileStore.selectedProfile?.id)
                } else {
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(CheraxxTheme.backgroundPrimary)
        // ── Toolbar ────────────────────────────────────────────────────
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    withAnimation(.easeInOut(duration: 0.20)) { showSidebar.toggle() }
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .help("Mostrar/ocultar barra lateral")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                // Indicador de guardado
                if profileStore.lastSaveError != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(CheraxxTheme.accentOrange)
                        .help("Error al guardar el perfil")
                }
                // Toggle mapper desde toolbar
                Button {
                    keyMapper.toggle()
                    log.debug("Toggle mapper desde toolbar → \(self.keyMapper.isEnabled ? "ON" : "OFF")")
                } label: {
                    Image(systemName: keyMapper.isEnabled ? "keyboard.fill" : "keyboard")
                        .foregroundStyle(keyMapper.isEnabled ? CheraxxTheme.accentGreen : CheraxxTheme.textSecondary)
                }
                .help(keyMapper.isEnabled ? "Desactivar KeyMapper" : "Activar KeyMapper")
            }
        }
        // ── Configuración inicial (una sola vez) ───────────────────────
        .onAppSetup(
            keyMapper:      keyMapper,
            profileStore:   profileStore,
            windowTracker:  windowTracker,
            overlayManager: overlayManager
        )
        // ── Comandos de menú (escucha de notificaciones) ───────────────
        .onReceive(NotificationCenter.default.publisher(for: .createNewProfile)) { _ in
            showNewProfile = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .importProfile)) { _ in
            showImport = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .exportProfile)) { _ in
            showExport = true
        }
        // ── Sheets ─────────────────────────────────────────────────────
        .sheet(isPresented: $showNewProfile) {
            NewProfileSheet { newProfile in
                profileStore.add(newProfile)
                profileStore.selectedProfile = newProfile
            }
            .environment(profileStore)
        }
        .fileImporter(
            isPresented: $showImport,
            allowedContentTypes: [.immap, .json],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result: result)
        }
        .fileExporter(
            isPresented: $showExport,
            document: profileStore.selectedProfile.map { ImmapDocument(profile: $0) },
            contentType: .immap,
            defaultFilename: "\(profileStore.selectedProfile?.name ?? "perfil").immap"
        ) { result in
            if case .failure(let error) = result {
                log.error("Error exportando perfil: \(error.localizedDescription)")
            }
        }
        .alert("Error al importar", isPresented: $showImportError) {
            Button("Aceptar", role: .cancel) {}
        } message: {
            Text(importError?.localizedDescription ?? "Archivo no reconocido.")
        }
    }

    // MARK: - Estado vacío
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "plus.rectangle.on.folder")
                .font(.system(size: 48))
                .foregroundStyle(CheraxxTheme.textDisabled)
            Text("Sin perfil seleccionado")
                .font(CheraxxTheme.fontTitle)
                .foregroundStyle(CheraxxTheme.textSecondary)
            Button("Crear perfil") { showNewProfile = true }
                .buttonStyle(.borderedProminent)
                .tint(CheraxxTheme.accentCyan)
        }
    }

    // MARK: - Importación
    private func handleImport(result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            importError     = error
            showImportError = true
            log.error("Error abriendo archivo: \(error.localizedDescription)")

        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let imported = try profileStore.importFile(from: url)
                profileStore.add(imported)
                profileStore.selectedProfile = imported
                log.info("Perfil importado desde \(url.lastPathComponent)")
            } catch {
                importError     = error
                showImportError = true
                log.error("Error importando perfil: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Preview
#if DEBUG
#Preview("ContentView") {
    ContentView()
        .environment(KeyMapper())
        .environment(ProfileStore())
        .environment(WindowTracker())
        .environment(OverlayManager())
        .frame(width: 1100, height: 700)
}
#endif
