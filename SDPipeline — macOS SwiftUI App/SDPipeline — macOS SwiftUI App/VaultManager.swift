import Foundation
import AppKit
import SwiftUI
import Combine

// MARK: - VaultManager
// Gestiona la estructura de directorios del estudio personal.
// Configurable al primer arranque; persiste la ruta elegida en UserDefaults.
// Todas las rutas son calculadas (computed) desde el root, nunca hard-coded.

@MainActor
final class VaultManager: ObservableObject {

    static let shared = VaultManager()

    // MARK: - Published State

    @Published var isConfigured: Bool = false
    @Published var vaultRoot: URL?
    @Published var showFirstRunSheet: Bool = false

    // MARK: - UserDefaults Keys

    private enum Keys {
        static let vaultRootBookmark = "vault.root.securityBookmark"
        static let vaultRootPath    = "vault.root.path"
    }

    // MARK: - Directory Structure
    // ~/StudioIA/ (o donde el usuario elija)
    // ├── Generaciones/          Raw output de SD — nunca se modifica
    // │   └── YYYY-MM-DD/        Subcarpetas por fecha para navegación rápida
    // ├── MasterPicks/           Imágenes aprobadas tras curaduría
    // ├── Export/                Versiones limpias (sin metadatos) listas para publicar
    // │   └── Previews/          Versiones con watermark para redes sociales
    // ├── Personajes/            Perfiles JSON de personajes guardados
    // ├── Escenas/               Presets de escenas guardadas
    // ├── Referencias/           Imágenes de referencia para img2img / ControlNet
    // ├── PrivateLoRAs/          .safetensors propios — nunca compartidos
    // └── Vault/                 Metadatos completos, licencias, sidecar JSONs
    //     └── Licencias/         model_card + LICENSE.txt de cada checkpoint

    var generacionesURL: URL? { subdirectory("Generaciones") }
    var masterPicksURL:  URL? { subdirectory("MasterPicks") }
    var exportURL:       URL? { subdirectory("Export") }
    var previewsURL:     URL? { subdirectory("Export/Previews") }
    var personajesURL:   URL? { subdirectory("Personajes") }
    var escenasURL:      URL? { subdirectory("Escenas") }
    var referenciasURL:  URL? { subdirectory("Referencias") }
    var privateLoRAsURL: URL? { subdirectory("PrivateLoRAs") }
    var vaultMetaURL:    URL? { subdirectory("Vault") }
    var licenciasURL:    URL? { subdirectory("Vault/Licencias") }

    /// Subdirectorio por fecha dentro de Generaciones (YYYY-MM-DD)
    var todayGeneracionesURL: URL? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: Date())
        return generacionesURL?.appending(path: today)
    }

    // MARK: - Init

    private init() {
        loadSavedVaultRoot()
    }

    // MARK: - Public API

    /// Llamar al arranque de la app. Muestra el sheet de configuración si no hay vault.
    func checkFirstRun() {
        if vaultRoot == nil {
            showFirstRunSheet = true
        }
    }

    /// El usuario elige la carpeta raíz del vault. Guarda un security-scoped bookmark.
    func selectVaultRoot() {
        let panel = NSOpenPanel()
        panel.title = "Selecciona la carpeta raíz de tu Studio"
        panel.message = "Elige dónde guardar todos tus assets. Recomendado: ~/StudioIA o un volumen externo cifrado."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Usar esta carpeta"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        applyVaultRoot(url)
    }

    /// Crear la carpeta raíz predeterminada en el home del usuario.
    func useDefaultVaultRoot() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let defaultURL = home.appending(path: "StudioIA")
        applyVaultRoot(defaultURL)
    }

    /// Ruta completa para un asset con nombre base y versión (v001, v002…).
    func versionedURL(baseName: String, version: Int, in directory: URL, ext: String = "png") -> URL {
        let versionStr = String(format: "v%03d", version)
        return directory.appending(path: "\(baseName)_\(versionStr).\(ext)")
    }

    /// Ruta del sidecar JSON para una imagen dada.
    func sidecarURL(for imageURL: URL) -> URL {
        imageURL.deletingPathExtension().appendingPathExtension("meta.json")
    }

    /// Ruta de la versión limpia (export) para una imagen aprobada.
    func cleanExportURL(for imageURL: URL) -> URL? {
        guard let exportDir = exportURL else { return nil }
        let name = imageURL.deletingPathExtension().lastPathComponent
        return exportDir.appending(path: "\(name)_clean.png")
    }

    /// Ruta del preview con watermark.
    func previewExportURL(for imageURL: URL) -> URL? {
        guard let previewDir = previewsURL else { return nil }
        let name = imageURL.deletingPathExtension().lastPathComponent
        return previewDir.appending(path: "\(name)_preview.png")
    }

    // MARK: - Private

    private func subdirectory(_ path: String) -> URL? {
        guard let root = vaultRoot else { return nil }
        return root.appending(path: path)
    }

    private func applyVaultRoot(_ url: URL) {
        // Guardar security-scoped bookmark para acceso persistente tras reinicio
        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmark, forKey: Keys.vaultRootBookmark)
        } catch {
            // Fallback: guardar solo el path (sin sandbox esto es suficiente)
            UserDefaults.standard.set(url.path, forKey: Keys.vaultRootPath)
        }

        vaultRoot = url
        createDirectoryStructure()
        isConfigured = true
        showFirstRunSheet = false
    }

    private func loadSavedVaultRoot() {
        // Intentar restaurar desde security-scoped bookmark
        if let bookmarkData = UserDefaults.standard.data(forKey: Keys.vaultRootBookmark) {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                _ = url.startAccessingSecurityScopedResource()
                vaultRoot = url
                isConfigured = true

                // Regenerar bookmark si está stale
                if isStale { applyVaultRoot(url) }
                return
            }
        }

        // Fallback: restaurar desde path simple
        if let path = UserDefaults.standard.string(forKey: Keys.vaultRootPath) {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path) {
                vaultRoot = url
                isConfigured = true
                createDirectoryStructure() // Asegurar que existen todos los subdirectorios
            }
        }
    }

    /// Crear toda la estructura de directorios si no existe.
    private func createDirectoryStructure() {
        let fm = FileManager.default
        let dirs: [URL?] = [
            generacionesURL, todayGeneracionesURL,
            masterPicksURL, exportURL, previewsURL,
            personajesURL, escenasURL, referenciasURL,
            privateLoRAsURL, vaultMetaURL, licenciasURL
        ]

        for dir in dirs.compactMap({ $0 }) {
            if !fm.fileExists(atPath: dir.path) {
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }

        // Crear README en PrivateLoRAs como recordatorio
        let readmeURL = privateLoRAsURL?.appending(path: "README.txt")
        if let readmeURL, !fm.fileExists(atPath: readmeURL.path) {
            let content = """
            PRIVATE LoRAs — SDPipeline Studio
            ==================================
            Esta carpeta contiene tus archivos .safetensors privados.
            NO compartir. NO subir a repositorios públicos.
            Cada archivo debe tener su LICENSE.txt en Vault/Licencias/
            """
            try? content.write(to: readmeURL, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - First Run Sheet

struct VaultSetupSheet: View {
    @ObservedObject var vault = VaultManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "externaldrive.badge.checkmark")
                    .font(.system(size: 28))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color(hex: "#7c6af7"), Color(hex: "#3de3c0")],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text("Configurar tu Studio Vault")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                    Text("Primer arranque — elige dónde guardar tus assets")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(24)
            .background(Color.white.opacity(0.03))

            Divider().background(Color.white.opacity(0.08))

            VStack(spacing: 16) {

                // Opción 1: Carpeta default
                VaultOptionCard(
                    icon: "folder.fill",
                    iconColor: Color(hex: "#7c6af7"),
                    title: "Carpeta predeterminada",
                    subtitle: "~/StudioIA/ — Rápido, en tu carpeta home",
                    action: {
                        vault.useDefaultVaultRoot()
                        dismiss()
                    }
                )

                // Opción 2: Elegir ubicación
                VaultOptionCard(
                    icon: "externaldrive.fill",
                    iconColor: Color(hex: "#3de3c0"),
                    title: "Elegir ubicación",
                    subtitle: "Recomendado: volumen externo cifrado (FileVault)",
                    action: {
                        vault.selectVaultRoot()
                        if vault.isConfigured { dismiss() }
                    }
                )

                Text("💡 Para máxima seguridad, usa un volumen APFS cifrado con FileVault.\nPuedes cambiar la ubicación más tarde en Configuración.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }
            .padding(24)
        }
        .frame(width: 460)
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
    }
}

private struct VaultOptionCard: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundColor(iconColor)
                    .frame(width: 44, height: 44)
                    .background(iconColor.opacity(0.12))
                    .cornerRadius(10)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(16)
            .background(Color.white.opacity(hovered ? 0.07 : 0.04))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}
