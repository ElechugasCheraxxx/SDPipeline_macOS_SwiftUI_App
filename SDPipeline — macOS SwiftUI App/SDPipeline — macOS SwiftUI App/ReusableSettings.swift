import Foundation
import SwiftUI
import Combine

// MARK: - ReusableSettings v2
//
// Cambios v1 → v2:
//   ✨ ReusableSettingsManager — ObservableObject con CRUD completo + búsqueda
//   ✨ Soporte de etiquetas (tags) para organizar presets
//   ✨ Import/Export JSON de la colección entera
//   ✨ Preset "favorito" (estrella)
//   ✨ Contador de usos (useCount)
//   ✨ ReusableSettingsPanel — panel completo con búsqueda, filtros y preview
//   ✨ ReusableSettingsSaveSheet — sheet para guardar settings actuales con nombre
//   ✨ Persistencia de hasta 100 presets (antes 50)

// MARK: - Model

struct ReusableSettings: Codable, Identifiable, Hashable {

    var id:             UUID    = UUID()
    var savedAt:        Date    = Date()
    var label:          String  = ""
    var tags:           [String] = []
    var isFavorite:     Bool    = false
    var useCount:       Int     = 0

    // Prompt
    var promptPositive: String  = ""
    var promptNegative: String  = ""

    // Core params
    var seed:           Int     = -1
    var steps:          Int     = 28
    var cfgScale:       Double  = 7.0
    var samplerName:    String  = "DPM++ 2M Karras"
    var width:          Int     = 512
    var height:         Int     = 768

    // Model
    var checkpoint:     String  = ""
    var vaeUsed:        String  = ""
    var loraWeights:    [String: Double] = [:]

    // Hires
    var enableHR:           Bool   = false
    var hrUpscaler:         String = "4x-UltraSharp"
    var hrScale:            Double = 2.0
    var hrSteps:            Int    = 15
    var denoisingStrength:  Double = 0.45
    var restoreFaces:       Bool   = false

    // MARK: Computed display

    var summaryLabel: String {
        "\(width)×\(height) · \(steps)s · CFG\(String(format: "%.1f", cfgScale))"
    }
    var seedDisplay: String { seed == -1 ? "Random" : "\(seed)" }
    var modelDisplay: String { checkpoint.isEmpty ? "Modelo desconocido" : checkpoint }
    var hasLoRAs: Bool { !loraWeights.isEmpty }

    var resolvedLabel: String {
        label.isEmpty ? "\(summaryLabel) · \(savedAt.relativeLabel)" : label
    }

    // Hashable
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: ReusableSettings, rhs: ReusableSettings) -> Bool { lhs.id == rhs.id }
}

// MARK: - ReusableSettingsManager

@MainActor
final class ReusableSettingsManager: ObservableObject {

    static let shared = ReusableSettingsManager()
    private init() { load() }

    @Published var presets:      [ReusableSettings] = []
    @Published var searchQuery:  String             = ""
    @Published var filterFavs:   Bool               = false

    private static let storageKey = "sdpipeline.reusableSettings.v3"
    private static let maxPresets  = 100

    // MARK: - Computed

    var filteredPresets: [ReusableSettings] {
        var result = presets
        if filterFavs { result = result.filter { $0.isFavorite } }
        if !searchQuery.isEmpty {
            let q = searchQuery.lowercased()
            result = result.filter {
                $0.label.lowercased().contains(q)
                || $0.promptPositive.lowercased().contains(q)
                || $0.checkpoint.lowercased().contains(q)
                || $0.tags.contains { $0.lowercased().contains(q) }
            }
        }
        return result.sorted { a, b in
            if a.isFavorite != b.isFavorite { return a.isFavorite }
            return a.savedAt > b.savedAt
        }
    }

    var favoriteCount: Int { presets.filter { $0.isFavorite }.count }

    // MARK: - CRUD

    @discardableResult
    func save(_ settings: ReusableSettings) -> ReusableSettings {
        var s = settings
        s.savedAt = Date()
        presets.removeAll { $0.id == s.id }
        presets.insert(s, at: 0)
        if presets.count > Self.maxPresets { presets = Array(presets.prefix(Self.maxPresets)) }
        persist()
        return s
    }

    func delete(id: UUID) {
        presets.removeAll { $0.id == id }
        persist()
    }

    func deleteAll() {
        presets.removeAll()
        persist()
    }

    func toggleFavorite(_ id: UUID) {
        guard let idx = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[idx].isFavorite.toggle()
        persist()
    }

    func recordUse(_ id: UUID) {
        guard let idx = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[idx].useCount += 1
        persist()
    }

    func updateLabel(_ id: UUID, label: String, tags: [String]) {
        guard let idx = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[idx].label = label
        presets[idx].tags  = tags
        persist()
    }

    // MARK: - Persistence

    private func load() {
        presets = UserDefaults.standard.decode([ReusableSettings].self, forKey: Self.storageKey) ?? []
    }

    private func persist() {
        UserDefaults.standard.encode(presets, forKey: Self.storageKey)
    }

    // MARK: - Import / Export JSON

    func exportJSON() throws -> Data {
        try JSONEncoder().encode(presets)
    }

    func importJSON(_ data: Data) throws {
        let imported = try JSONDecoder().decode([ReusableSettings].self, from: data)
        // Merge: overwrite by ID, add new ones
        for preset in imported {
            presets.removeAll { $0.id == preset.id }
            presets.append(preset)
        }
        presets.sort { $0.savedAt > $1.savedAt }
        if presets.count > Self.maxPresets { presets = Array(presets.prefix(Self.maxPresets)) }
        persist()
    }

    // MARK: - Capture from GenerationSettings

    func capture(
        from settings:     GenerationSettings,
        positivePrompt:    String,
        negativePrompt:    String,
        seed:              Int?,
        label:             String = "",
        tags:              [String] = []
    ) -> ReusableSettings {
        ReusableSettings(
            label:           label,
            tags:            tags,
            promptPositive:  positivePrompt,
            promptNegative:  negativePrompt,
            seed:            seed ?? settings.seed,
            steps:           settings.steps,
            cfgScale:        settings.cfgScale,
            samplerName:     settings.samplerName,
            width:           settings.width,
            height:          settings.height,
            checkpoint:      settings.checkpoint,
            loraWeights:     LoRAManager.shared.selectedLoRAs.reduce(into: [:]) { $0[$1.lora.name] = $1.weight },
            enableHR:        settings.enableHR,
            hrUpscaler:      settings.hrUpscaler,
            hrScale:         settings.hrScale,
            hrSteps:         settings.hrSteps,
            denoisingStrength: settings.denoisingStrength,
            restoreFaces:    settings.restoreFaces
        )
    }
}

// MARK: - ReusableSettingsRow (v2)

struct ReusableSettingsRow: View {

    let settings: ReusableSettings
    let onApply:  (ReusableSettings) -> Void
    let onDelete: (UUID) -> Void
    let onToggleFav: (UUID) -> Void

    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            // Favorite star
            Button(action: { onToggleFav(settings.id) }) {
                Image(systemName: settings.isFavorite ? "star.fill" : "star")
                    .font(.system(size: 11))
                    .foregroundColor(settings.isFavorite ? Color(hex: "#f59e0b") : .secondary.opacity(0.4))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                // Label + summary
                HStack(spacing: 6) {
                    Text(settings.resolvedLabel)
                        .font(.system(size: 11, weight: settings.isFavorite ? .semibold : .medium))
                        .foregroundColor(.white)
                    Text(settings.summaryLabel)
                        .font(.system(size: 9)).foregroundColor(.secondary)
                    Spacer()
                }

                // Tags
                if !settings.tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(settings.tags.prefix(4), id: \.self) { tag in
                            Text(tag)
                                .font(.system(size: 8))
                                .foregroundColor(Color(hex: "#7c6af7"))
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(Color(hex: "#7c6af7").opacity(0.15))
                                .cornerRadius(4)
                        }
                    }
                }

                // Prompt + meta
                Text(settings.promptPositive.prefix(80) + (settings.promptPositive.count > 80 ? "…" : ""))
                    .font(.system(size: 10)).foregroundColor(.white.opacity(0.45)).lineLimit(1)

                HStack(spacing: 8) {
                    if !settings.checkpoint.isEmpty {
                        Label(settings.modelDisplay.prefix(22), systemImage: "cpu")
                            .font(.system(size: 8)).foregroundColor(.secondary).lineLimit(1)
                    }
                    if settings.seed != -1 {
                        Label("\(settings.seed)", systemImage: "number")
                            .font(.system(size: 8)).foregroundColor(.secondary)
                    }
                    if settings.hasLoRAs {
                        Label("\(settings.loraWeights.count) LoRA", systemImage: "cpu.fill")
                            .font(.system(size: 8)).foregroundColor(Color(hex: "#3de3c0"))
                    }
                    Spacer()
                    if settings.useCount > 0 {
                        Text("×\(settings.useCount)").font(.system(size: 8)).foregroundColor(.secondary)
                    }
                    Text(settings.savedAt.relativeLabel)
                        .font(.system(size: 8)).foregroundColor(Color.secondary.opacity(0.5))
                }
            }

            // Action buttons (on hover)
            if hovered {
                Button(action: { onApply(settings) }) {
                    Text("Aplicar")
                        .font(.system(size: 10, weight: .semibold)).foregroundColor(.white)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color(hex: "#7c6af7")).cornerRadius(6)
                }
                .buttonStyle(.plain)

                Button(action: { onDelete(settings.id) }) {
                    Image(systemName: "trash").font(.system(size: 10)).foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.white.opacity(hovered ? 0.06 : 0.02))
        .cornerRadius(7)
        .onHover { hovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: hovered)
    }
}

// MARK: - ReusableSettingsPanel

struct ReusableSettingsPanel: View {

    @StateObject private var manager = ReusableSettingsManager.shared
    var onApply: (ReusableSettings) -> Void

    @State private var showSaveSheet = false
    @State private var showImportExport = false

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ──────────────────────────────────────────────────
            HStack(spacing: 8) {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 12)).foregroundColor(Color(hex: "#7c6af7"))
                Text("Presets Guardados")
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                Text("\(manager.presets.count)")
                    .font(.system(size: 10)).foregroundColor(.secondary)
                Spacer()
                Toggle(isOn: $manager.filterFavs) {
                    Image(systemName: "star.fill").font(.system(size: 11))
                        .foregroundColor(manager.filterFavs ? Color(hex: "#f59e0b") : .secondary)
                }
                .toggleStyle(.button)
                .help("Mostrar solo favoritos")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.white.opacity(0.03))

            // ── Search ──────────────────────────────────────────────────
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundColor(.secondary)
                TextField("Buscar presets…", text: $manager.searchQuery)
                    .textFieldStyle(.plain).font(.system(size: 11)).foregroundColor(.white)
                if !manager.searchQuery.isEmpty {
                    Button(action: { manager.searchQuery = "" }) {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.white.opacity(0.02))

            Divider().background(Color.white.opacity(0.06))

            // ── List ────────────────────────────────────────────────────
            if manager.filteredPresets.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "bookmark.slash")
                        .font(.system(size: 28)).foregroundColor(.white.opacity(0.08))
                    Text(manager.searchQuery.isEmpty ? "Sin presets guardados" : "Sin resultados")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(manager.filteredPresets) { preset in
                            ReusableSettingsRow(
                                settings:    preset,
                                onApply:     { s in
                                    manager.recordUse(s.id)
                                    onApply(s)
                                },
                                onDelete:    { manager.delete(id: $0) },
                                onToggleFav: { manager.toggleFavorite($0) }
                            )
                            .padding(.horizontal, 4)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }

            Divider().background(Color.white.opacity(0.06))

            // ── Bottom Bar ───────────────────────────────────────────────
            HStack(spacing: 8) {
                Button(action: { showSaveSheet = true }) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle.fill").font(.system(size: 11))
                        Text("Guardar actual").font(.system(size: 10))
                    }
                    .foregroundColor(Color(hex: "#7c6af7"))
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: { showImportExport = true }) {
                    Image(systemName: "arrow.up.arrow.down").font(.system(size: 10)).foregroundColor(.secondary)
                }
                .buttonStyle(.plain).help("Importar / Exportar")

                if !manager.presets.isEmpty {
                    Button(action: { manager.deleteAll() }) {
                        Image(systemName: "trash").font(.system(size: 10)).foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain).help("Eliminar todos los presets")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.white.opacity(0.02))
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
        .cornerRadius(10)
    }
}

// MARK: - ReusableSettingsSaveSheet

struct ReusableSettingsSaveSheet: View {

    let settings:       GenerationSettings
    let positivePrompt: String
    let negativePrompt: String
    let lastSeed:       Int?

    @Environment(\.dismiss) private var dismiss
    @StateObject private var manager = ReusableSettingsManager.shared

    @State private var label:    String = ""
    @State private var tagsText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "bookmark.fill")
                    .foregroundColor(Color(hex: "#7c6af7")).font(.system(size: 14))
                Text("Guardar Preset").font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
            .background(Color.white.opacity(0.03))

            Divider().background(Color.white.opacity(0.07))

            VStack(alignment: .leading, spacing: 16) {
                // Summary preview
                VStack(alignment: .leading, spacing: 6) {
                    Text("RESUMEN").font(.system(size: 9, weight: .semibold)).foregroundColor(.secondary).tracking(1)
                    HStack(spacing: 8) {
                        summaryPill("\(settings.width)×\(settings.height)")
                        summaryPill("\(settings.steps) steps")
                        summaryPill("CFG \(String(format: "%.1f", settings.cfgScale))")
                        if let seed = lastSeed { summaryPill("Seed \(seed)") }
                    }
                    if !positivePrompt.isEmpty {
                        Text(positivePrompt.prefix(100) + "…")
                            .font(.system(size: 10)).foregroundColor(.white.opacity(0.5)).lineLimit(2)
                    }
                }

                // Label
                VStack(alignment: .leading, spacing: 6) {
                    Text("NOMBRE DEL PRESET").font(.system(size: 9, weight: .semibold)).foregroundColor(.secondary).tracking(1)
                    TextField("Ej: Retratos cinematográficos · 85mm", text: $label)
                        .textFieldStyle(.plain).font(.system(size: 12)).foregroundColor(.white)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(Color.white.opacity(0.06)).cornerRadius(7)
                }

                // Tags
                VStack(alignment: .leading, spacing: 6) {
                    Text("TAGS (separados por coma)").font(.system(size: 9, weight: .semibold)).foregroundColor(.secondary).tracking(1)
                    TextField("retrato, estudio, natural…", text: $tagsText)
                        .textFieldStyle(.plain).font(.system(size: 11)).foregroundColor(.white)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(Color.white.opacity(0.06)).cornerRadius(7)
                }
            }
            .padding(20)

            Divider().background(Color.white.opacity(0.07))

            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundColor(.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Color.white.opacity(0.06)).cornerRadius(7)

                Button(action: saveAndDismiss) {
                    HStack(spacing: 6) {
                        Image(systemName: "bookmark.fill").font(.system(size: 11))
                        Text("Guardar Preset").font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .background(Color(hex: "#7c6af7")).cornerRadius(7)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            .background(Color.white.opacity(0.02))
        }
        .frame(width: 480)
        .background(Color(red: 0.08, green: 0.08, blue: 0.11))
    }

    private func saveAndDismiss() {
        let tags = tagsText.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let preset = manager.capture(
            from:           settings,
            positivePrompt: positivePrompt,
            negativePrompt: negativePrompt,
            seed:           lastSeed,
            label:          label,
            tags:           tags
        )
        manager.save(preset)
        dismiss()
    }

    private func summaryPill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9)).foregroundColor(.white.opacity(0.7))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Color.white.opacity(0.08)).cornerRadius(5)
    }
}

// MARK: - Legacy shim (backward compat v1 API)

extension ReusableSettings {

    private static let legacyKey = "sdpipeline.reusableSettings.v2"

    static func loadAll() -> [ReusableSettings] {
        ReusableSettingsManager.shared.presets
    }

    static func save(_ settings: ReusableSettings) {
        ReusableSettingsManager.shared.save(settings)
    }

    static func delete(id: UUID) {
        ReusableSettingsManager.shared.delete(id: id)
    }

    static func deleteAll() {
        ReusableSettingsManager.shared.deleteAll()
    }
}

