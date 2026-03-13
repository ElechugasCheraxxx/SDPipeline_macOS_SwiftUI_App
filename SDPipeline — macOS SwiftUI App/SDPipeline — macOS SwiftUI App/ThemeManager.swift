import Foundation
import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers // Added for .json export

// MARK: - ThemeManager
//
// Sistema de personalización temática de UI para SDPipelineStudio.
// Permite al usuario cambiar el aspecto visual de la app sin recompilación.

@MainActor
final class ThemeManager: ObservableObject {

    static let shared = ThemeManager()
    private init() { loadPersistedTheme() }

    // MARK: - Theme Model

    struct AppTheme: Codable, Identifiable, Equatable {
        var id:          String   = UUID().uuidString
        var name:        String
        var isBuiltIn:   Bool     = false
        var author:      String   = "Studio"

        // Primary palette
        var accentPrimary:   String = "#7c6af7"   // Purple
        var accentSecondary: String = "#3de3c0"   // Teal
        var accentDanger:    String = "#ef4444"   // Red
        var accentWarning:   String = "#fbbf24"   // Amber
        var accentSuccess:   String = "#34d399"   // Green

        // Background layers
        var bgBase:       String = "#0d0d14"
        var bgSurface:    String = "#13131e"
        var bgCard:       String = "#1a1a2e"
        var bgInput:      String = "#111118"

        // Text hierarchy
        var textPrimary:   String = "#f0f0f5"
        var textSecondary: String = "#9090a8"
        var textMuted:     String = "#606078"

        // Dividers
        var borderColor:   String = "#ffffff12"

        // Typography
        var bodyFontSize:   CGFloat = 12
        var uiFontSize:     CGFloat = 11
        var labelFontSize:  CGFloat = 10
        var codeFontName:   String  = "SF Mono"

        // Sidebar
        var sidebarWidth:  CGFloat = 220
        var rightPanelWidth: CGFloat = 320

        // Visual effects
        var useMaterialBlur:      Bool   = true
        var cardCornerRadius:     CGFloat = 10
        var inputCornerRadius:    CGFloat = 7
        var buttonCornerRadius:   CGFloat = 7
        var animationsEnabled:    Bool   = true

        // Gradient accent
        var gradientStart: String = "#7c6af7"
        var gradientEnd:   String = "#3de3c0"

        // SwiftUI Color accessors
        var swiftAccentPrimary:   Color { Color(hex: accentPrimary) }
        var swiftAccentSecondary: Color { Color(hex: accentSecondary) }
        var swiftAccentDanger:    Color { Color(hex: accentDanger) }
        var swiftAccentSuccess:   Color { Color(hex: accentSuccess) }
        var swiftAccentWarning:   Color { Color(hex: accentWarning) }
        var swiftBgBase:          Color { Color(hex: bgBase) }
        var swiftBgSurface:       Color { Color(hex: bgSurface) }
        var swiftBgCard:          Color { Color(hex: bgCard) }
        var swiftTextPrimary:     Color { Color(hex: textPrimary) }
        var swiftTextSecondary:   Color { Color(hex: textSecondary) }
        var swiftBorder:          Color { Color(hex: borderColor) }
        var swiftGradient: LinearGradient {
            LinearGradient(
                colors: [Color(hex: gradientStart), Color(hex: gradientEnd)],
                startPoint: .leading, endPoint: .trailing
            )
        }
    }

    // MARK: - Built-In Themes

    static let builtInThemes: [AppTheme] = [
        darkStudio,
        neonNight,
        amberClassic,
        arcticBlue,
        warmEarth,
        midnightRose
    ]

    static let darkStudio: AppTheme = {
        var t = AppTheme(name: "Dark Studio")
        t.isBuiltIn = true
        return t
    }()

    static let neonNight: AppTheme = {
        var t = AppTheme(name: "Neon Night")
        t.isBuiltIn    = true
        t.accentPrimary   = "#ff2d78"
        t.accentSecondary = "#00f5c4"
        t.bgBase          = "#070710"
        t.bgSurface       = "#0e0e1a"
        t.bgCard          = "#141426"
        t.gradientStart   = "#ff2d78"
        t.gradientEnd     = "#00f5c4"
        return t
    }()

    static let amberClassic: AppTheme = {
        var t = AppTheme(name: "Amber Classic")
        t.isBuiltIn    = true
        t.accentPrimary   = "#f59e0b"
        t.accentSecondary = "#d97706"
        t.accentSuccess   = "#10b981"
        t.bgBase          = "#0a0800"
        t.bgSurface       = "#111000"
        t.bgCard          = "#1a1600"
        t.bgInput         = "#0d0b00"
        t.textPrimary     = "#fef3c7"
        t.textSecondary   = "#92400e"
        t.gradientStart   = "#f59e0b"
        t.gradientEnd     = "#d97706"
        return t
    }()

    static let arcticBlue: AppTheme = {
        var t = AppTheme(name: "Arctic Blue")
        t.isBuiltIn    = true
        t.accentPrimary   = "#38bdf8"
        t.accentSecondary = "#818cf8"
        t.bgBase          = "#0a0e1a"
        t.bgSurface       = "#0f1525"
        t.bgCard          = "#141d35"
        t.bgInput         = "#0c1020"
        t.textPrimary     = "#e0f2fe"
        t.textSecondary   = "#7dd3fc"
        t.gradientStart   = "#38bdf8"
        t.gradientEnd     = "#818cf8"
        return t
    }()

    static let warmEarth: AppTheme = {
        var t = AppTheme(name: "Warm Earth")
        t.isBuiltIn    = true
        t.accentPrimary   = "#dc8a5a"
        t.accentSecondary = "#b8a98a"
        t.bgBase          = "#100c08"
        t.bgSurface       = "#1a1410"
        t.bgCard          = "#231c16"
        t.bgInput         = "#130f0b"
        t.textPrimary     = "#f5e6d3"
        t.textSecondary   = "#c4a882"
        t.gradientStart   = "#dc8a5a"
        t.gradientEnd     = "#b8a98a"
        return t
    }()

    static let midnightRose: AppTheme = {
        var t = AppTheme(name: "Midnight Rose")
        t.isBuiltIn    = true
        t.accentPrimary   = "#ec4899"
        t.accentSecondary = "#a855f7"
        t.bgBase          = "#0e0810"
        t.bgSurface       = "#150d18"
        t.bgCard          = "#1e1225"
        t.bgInput         = "#110a14"
        t.textPrimary     = "#fce7f3"
        t.textSecondary   = "#f9a8d4"
        t.gradientStart   = "#ec4899"
        t.gradientEnd     = "#a855f7"
        return t
    }()

    // MARK: - State

    @Published var activeTheme:   AppTheme       = ThemeManager.darkStudio
    @Published var customThemes:  [AppTheme]     = []
    @Published var isEditing:     Bool           = false
    @Published var editingTheme:  AppTheme?      = nil

    var allThemes: [AppTheme] {
        ThemeManager.builtInThemes + customThemes
    }

    // MARK: - Apply Theme

    func apply(_ theme: AppTheme) {
        activeTheme = theme
        applyToAppearance()
        persist()
    }

    func applyByName(_ name: String) {
        if let theme = allThemes.first(where: { $0.name == name }) {
            apply(theme)
        }
    }

    private func applyToAppearance() {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let accentNS = NSColor(hex: activeTheme.accentPrimary)
        NSColorPanel.shared.color = accentNS
    }

    // MARK: - Custom Theme CRUD

    func createCustomTheme(name: String, basedOn base: AppTheme? = nil) -> AppTheme {
        var theme = base ?? activeTheme
        theme.id        = UUID().uuidString
        theme.name      = name
        theme.isBuiltIn = false
        theme.author    = "User"
        customThemes.append(theme)
        persistCustomThemes()
        return theme
    }

    func updateCustomTheme(_ theme: AppTheme) {
        if let idx = customThemes.firstIndex(where: { $0.id == theme.id }) {
            customThemes[idx] = theme
            if activeTheme.id == theme.id { activeTheme = theme }
            persistCustomThemes()
        }
    }

    func deleteCustomTheme(_ theme: AppTheme) {
        guard !theme.isBuiltIn else { return }
        customThemes.removeAll { $0.id == theme.id }
        if activeTheme.id == theme.id { apply(ThemeManager.darkStudio) }
        persistCustomThemes()
    }

    // MARK: - Export / Import

    func exportTheme(_ theme: AppTheme) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(theme)

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(theme.name.lowercased().replacingOccurrences(of: " ", with: "_")).sdtheme.json")
        try data.write(to: tempURL, options: .atomic)
        return tempURL
    }

    func importTheme(from url: URL) throws {
        let data  = try Data(contentsOf: url)
        var theme = try JSONDecoder().decode(AppTheme.self, from: data)
        theme.id        = UUID().uuidString
        theme.isBuiltIn = false
        
        let existingNames = allThemes.map { $0.name }
        if existingNames.contains(theme.name) {
            theme.name = "\(theme.name) (imported)"
        }
        customThemes.append(theme)
        persistCustomThemes()
    }

    // MARK: - Backup to Vault

    func backupThemesToVault() throws {
        guard let vaultRoot = VaultManager.shared.vaultRoot else { return }
        let themesDir = vaultRoot.appendingPathComponent("Vault/Themes")
        try? FileManager.default.createDirectory(at: themesDir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let activeData = try encoder.encode(activeTheme)
        try activeData.write(to: themesDir.appendingPathComponent("active_theme.json"), options: .atomic)

        for theme in customThemes {
            let safe = theme.name.lowercased().replacingOccurrences(of: " ", with: "_")
            let data = try encoder.encode(theme)
            try data.write(to: themesDir.appendingPathComponent("\(safe).json"), options: .atomic)
        }
    }

    // MARK: - Persistence

    private let activeThemeKey  = "AppTheme_Active"
    private let customThemesKey = "AppTheme_Custom"

    private func persist() {
        if let data = try? JSONEncoder().encode(activeTheme) {
            UserDefaults.standard.set(data, forKey: activeThemeKey)
        }
    }

    private func persistCustomThemes() {
        if let data = try? JSONEncoder().encode(customThemes) {
            UserDefaults.standard.set(data, forKey: customThemesKey)
        }
    }

    private func loadPersistedTheme() {
        if let data  = UserDefaults.standard.data(forKey: activeThemeKey),
           let theme = try? JSONDecoder().decode(AppTheme.self, from: data) {
            activeTheme = theme
        }
        if let data   = UserDefaults.standard.data(forKey: customThemesKey),
           let themes = try? JSONDecoder().decode([AppTheme].self, from: data) {
            customThemes = themes
        }
        applyToAppearance()
    }

    // MARK: - SwiftUI Environment Key

    var t: AppTheme { activeTheme }
}

// MARK: - Theme Environment Key (SwiftUI)

private struct ThemeKey: EnvironmentKey {
    static var defaultValue: ThemeManager.AppTheme = ThemeManager.darkStudio
}

extension EnvironmentValues {
    var appTheme: ThemeManager.AppTheme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

extension View {
    func withAppTheme() -> some View {
        self.environmentObject(ThemeManager.shared)
            .environment(\.appTheme, ThemeManager.shared.activeTheme)
    }
}

// MARK: - ThemeSettingsView

struct ThemeSettingsView: View {
    @ObservedObject private var tm = ThemeManager.shared
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var selectedForExport: ThemeManager.AppTheme?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {

            // Section: Built-In
            themeGroup(title: "Temas del Sistema", themes: ThemeManager.builtInThemes)

            if !tm.customThemes.isEmpty {
                themeGroup(title: "Temas Personalizados", themes: tm.customThemes, allowDelete: true)
            }

            // Actions
            HStack(spacing: 10) {
                Button("Nuevo tema…") {
                    let t = tm.createCustomTheme(name: "Mi Tema", basedOn: tm.activeTheme)
                    tm.editingTheme = t
                    tm.isEditing = true
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(.white)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color(hex: "#7c6af7"))
                .cornerRadius(6)

                Button("Importar…") { showImporter = true }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundColor(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.white.opacity(0.06)).cornerRadius(6)

                Spacer()

                Button("Backup al Vault") { try? tm.backupThemesToVault() }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundColor(.secondary)
            }
        }
        .padding(20)
        .sheet(isPresented: $tm.isEditing) {
            if let theme = tm.editingTheme {
                ThemeEditorSheet(theme: theme)
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result { try? tm.importTheme(from: url) }
        }
    }

    func themeGroup(title: String, themes: [ThemeManager.AppTheme], allowDelete: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold)).foregroundColor(.secondary).tracking(1)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 200))], spacing: 8) {
                ForEach(themes) { theme in
                    ThemeCard(theme: theme, isActive: tm.activeTheme.id == theme.id,
                              allowDelete: allowDelete,
                              onSelect: { tm.apply(theme) },
                              onEdit: { tm.editingTheme = theme; tm.isEditing = true },
                              onDelete: { tm.deleteCustomTheme(theme) },
                              onExport: {
                                  selectedForExport = theme
                                  if let url = try? tm.exportTheme(theme) {
                                      NSWorkspace.shared.open(url)
                                  }
                              })
                }
            }
        }
    }
}

// MARK: - ThemeCard

struct ThemeCard: View {
    let theme: ThemeManager.AppTheme
    let isActive: Bool
    let allowDelete: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onExport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                Color(hex: theme.accentPrimary).frame(height: 6)
                Color(hex: theme.accentSecondary).frame(height: 6)
                Color(hex: theme.bgCard).frame(width: 20, height: 6)
            }
            .cornerRadius(3)

            Text(theme.name).font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
            Text(theme.isBuiltIn ? "Sistema" : theme.author).font(.system(size: 9)).foregroundColor(.secondary)

            HStack(spacing: 6) {
                if isActive {
                    Label("Activo", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 9)).foregroundColor(Color(hex: "#34d399"))
                } else {
                    Button("Aplicar") { onSelect() }
                        .buttonStyle(.plain).font(.system(size: 9)).foregroundColor(Color(hex: "#7c6af7"))
                }
                Spacer()
                if !theme.isBuiltIn {
                    Button(action: onEdit) { Image(systemName: "pencil").font(.system(size: 9)) }
                        .buttonStyle(.plain).foregroundColor(.secondary)
                    Button(action: onDelete) { Image(systemName: "trash").font(.system(size: 9)) }
                        .buttonStyle(.plain).foregroundColor(Color(hex: "#ef4444"))
                }
                Button(action: onExport) { Image(systemName: "square.and.arrow.up").font(.system(size: 9)) }
                    .buttonStyle(.plain).foregroundColor(.secondary)
            }
        }
        .padding(10)
        .background(isActive ? Color(hex: theme.accentPrimary).opacity(0.15) : Color.white.opacity(0.04))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(isActive ? Color(hex: theme.accentPrimary) : Color.white.opacity(0.08), lineWidth: 1))
    }
}

// MARK: - ThemeEditorSheet

struct ThemeEditorSheet: View {
    @State var theme: ThemeManager.AppTheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Editor de Tema").font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                Spacer()
                Button(action: { dismiss() }) { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }
                    .buttonStyle(.plain)
            }
            .padding(16)

            Divider().background(Color.white.opacity(0.08))

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    TextField("Nombre del tema", text: $theme.name)
                        .textFieldStyle(.plain).font(.system(size: 12)).foregroundColor(.white)
                        .padding(8).background(Color.white.opacity(0.06)).cornerRadius(6)

                    colorSection(title: "Colores de Acento") {
                        colorRow("Principal",    binding: $theme.accentPrimary)
                        colorRow("Secundario",   binding: $theme.accentSecondary)
                        colorRow("Éxito",        binding: $theme.accentSuccess)
                        colorRow("Advertencia",  binding: $theme.accentWarning)
                        colorRow("Peligro",      binding: $theme.accentDanger)
                    }

                    colorSection(title: "Fondos") {
                        colorRow("Base",         binding: $theme.bgBase)
                        colorRow("Superficie",   binding: $theme.bgSurface)
                        colorRow("Tarjeta",      binding: $theme.bgCard)
                        colorRow("Input",        binding: $theme.bgInput)
                    }

                    colorSection(title: "Texto") {
                        colorRow("Principal",    binding: $theme.textPrimary)
                        colorRow("Secundario",   binding: $theme.textSecondary)
                        colorRow("Silenciado",   binding: $theme.textMuted)
                    }

                    colorSection(title: "Gradiente Accent") {
                        colorRow("Inicio",       binding: $theme.gradientStart)
                        colorRow("Fin",          binding: $theme.gradientEnd)
                    }
                }
                .padding(16)
            }

            Divider().background(Color.white.opacity(0.08))

            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }
                    .buttonStyle(.plain).foregroundColor(.secondary).padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Color.white.opacity(0.06)).cornerRadius(6)
                Button("Guardar") {
                    ThemeManager.shared.updateCustomTheme(theme)
                    ThemeManager.shared.apply(theme)
                    dismiss()
                }
                .buttonStyle(.plain).foregroundColor(.white).padding(.horizontal, 14).padding(.vertical, 8)
                .background(Color(hex: "#7c6af7")).cornerRadius(6)
            }
            .font(.system(size: 12))
            .padding(16)
        }
        .frame(width: 420, height: 560)
        .background(Color(red: 0.08, green: 0.08, blue: 0.11))
    }

    func colorSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold)).foregroundColor(.secondary).tracking(1)
            content()
        }
    }

    func colorRow(_ label: String, binding: Binding<String>) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundColor(.secondary).frame(width: 100, alignment: .leading)
            Rectangle().fill(Color(hex: binding.wrappedValue)).frame(width: 24, height: 24).cornerRadius(4)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.2), lineWidth: 1))
            TextField("#RRGGBB", text: binding)
                .textFieldStyle(.plain).font(.system(size: 11, design: .monospaced)).foregroundColor(.white)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.white.opacity(0.06)).cornerRadius(4)
        }
    }
}
