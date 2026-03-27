import Foundation
import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers

// MARK: - ScenePreset
// Una escena encapsula todo el contexto ambiental reutilizable:
//   - Localización + atmósfera
//   - Iluminación
//   - Cámara + encuadre
//   - Vestuario/props opcionales
//   - Imagen de referencia para img2img / ControlNet

struct ScenePreset: Codable, Identifiable, Hashable {

    var id:        UUID   = UUID()
    var createdAt: Date   = Date()
    var updatedAt: Date   = Date()

    // ── Identidad ──────────────────────────────────────────────────
    var name:      String                      // "Penthouse Sunset", "Forest Mist"
    var category:  SceneCategory  = .interior
    var tags:      [String]       = []
    var isFavorite: Bool          = false
    var lastUsedAt: Date?         = nil
    var usageCount: Int           = 0

    enum SceneCategory: String, Codable, CaseIterable {
        case interior  = "Interior"
        case exterior  = "Exterior"
        case studio    = "Estudio"
        case fantasy   = "Fantasía"
        case urban     = "Urbano"
        case nature    = "Naturaleza"
        case abstract_ = "Abstracto"

        var icon: String {
            switch self {
            case .interior:  return "house.fill"
            case .exterior:  return "sun.max.fill"
            case .studio:    return "camera.studio"
            case .fantasy:   return "sparkles"
            case .urban:     return "building.2.fill"
            case .nature:    return "leaf.fill"
            case .abstract_: return "waveform"
            }
        }
    }

    // ── Ambiente ────────────────────────────────────────────────────
    var environment: EnvironmentBlock

    struct EnvironmentBlock: Codable, Hashable {
        var locationType:   String = ""   // "luxury penthouse", "misty forest"
        var settingStyle:   String = ""   // "modern minimalist", "baroque opulent"
        var timeOfDay:      String = ""   // "golden hour", "midnight", "midday"
        var weather:        String = ""   // "clear sky", "light rain", "foggy"
        var ambientEnergy:  String = ""   // "serene", "electric", "intimate"
        var colorGrading:   String = ""   // "warm tones", "cinematic teal-orange"
        var props:          String = ""   // "silk sheets, champagne glass"
        var extra:          String = ""
    }

    // ── Iluminación ─────────────────────────────────────────────────
    var lighting: LightingBlock

    struct LightingBlock: Codable, Hashable {
        var style:          String = ""   // "soft rembrandt", "hard chiaroscuro"
        var keyLight:       String = ""   // "warm golden backlight"
        var fillLight:      String = ""   // "soft cool fill"
        var rimLight:       Bool   = false
        var rimColor:       String = ""   // "warm amber rim"
        var practicals:     String = ""   // "neon signs, candles"
        var extra:          String = ""
    }

    // ── Cámara ──────────────────────────────────────────────────────
    var camera: CameraBlock

    struct CameraBlock: Codable, Hashable {
        var frameType:      String = ""   // "medium shot", "full body", "close-up"
        var angle:          String = ""   // "eye level", "low angle", "bird's eye"
        var dof:            String = ""   // "shallow depth of field"
        var lens:           String = ""   // "85mm", "35mm wide"
        var cameraType:     String = ""   // "35mm film", "medium format digital"
        var extra:          String = ""
    }

    // ── Prompt base ─────────────────────────────────────────────────
    var basePromptPositive: String = ""
    var basePromptNegative: String = ""

    // ── Imagen de referencia ────────────────────────────────────────
    var referenceImageFilename: String? = nil

    // ── Computed: prompt completo de la escena ───────────────────────
    var fullScenePrompt: String {
        let envTokens = [
            environment.locationType, environment.settingStyle,
            environment.timeOfDay,    environment.weather,
            environment.ambientEnergy, environment.colorGrading,
            environment.props,         environment.extra
        ].filter { !$0.isEmpty }

        let lightTokens = [
            lighting.style, lighting.keyLight, lighting.fillLight,
            lighting.rimLight ? (lighting.rimColor.isEmpty ? "rim lighting" : lighting.rimColor + " rim lighting") : nil,
            lighting.practicals, lighting.extra
        ].compactMap { $0 }.filter { !$0.isEmpty }

        let camTokens = [
            camera.frameType, camera.angle, camera.dof,
            camera.lens, camera.cameraType, camera.extra
        ].filter { !$0.isEmpty }

        let all = ([basePromptPositive] + envTokens + lightTokens + camTokens)
            .filter { !$0.isEmpty }

        return all.joined(separator: ", ")
    }

    // ── Vault ────────────────────────────────────────────────────────
    func sceneDirectory(vault: VaultManager) -> URL? {
        vault.escenasURL?.appending(path: id.uuidString)
    }

    func referenceImageURL(vault: VaultManager) -> URL? {
        guard let dir = sceneDirectory(vault: vault) else { return nil }
        return dir.appending(path: "reference.png")
    }

    static func == (lhs: ScenePreset, rhs: ScenePreset) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - SceneEngine

@MainActor
final class SceneEngine: ObservableObject {

    static let shared = SceneEngine()
    private init() { loadAll() }

    // MARK: - State

    @Published var scenes:       [ScenePreset] = []
    @Published var activeScene:  ScenePreset?  = nil
    @Published var searchText:   String        = ""
    @Published var filterCat:    ScenePreset.SceneCategory? = nil
    @Published var filterFavs:   Bool          = false

    // MARK: - Persistence

    private let indexFilename = "scenes_index.json"

    private var indexURL: URL? {
        VaultManager.shared.escenasURL?.appending(path: indexFilename)
    }

    func loadAll() {
        guard let url  = indexURL,
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder.iso8601.decode([ScenePreset].self, from: data)
        else {
            seedBuiltinScenes()
            return
        }
        scenes = sorted(list)
    }

    private func saveAll() {
        guard let url = indexURL else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder.pretty.encode(scenes) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - CRUD

    @discardableResult
    func create(name: String, category: ScenePreset.SceneCategory = .interior) -> ScenePreset {
        var s = ScenePreset(
            name: name, category: category,
            environment: .init(), lighting: .init(), camera: .init()
        )
        s.id = UUID()
        createSceneDirectory(s)
        scenes.insert(s, at: 0)
        saveAll()
        return s
    }

    func save(_ scene: ScenePreset) {
        var updated = scene
        updated.updatedAt = Date()
        if let idx = scenes.firstIndex(where: { $0.id == scene.id }) {
            scenes[idx] = updated
        } else {
            scenes.insert(updated, at: 0)
            createSceneDirectory(updated)
        }
        scenes = sorted(scenes)
        saveAll()
    }

    func delete(_ scene: ScenePreset) {
        scenes.removeAll { $0.id == scene.id }
        if let dir = scene.sceneDirectory(vault: VaultManager.shared) {
            try? FileManager.default.removeItem(at: dir)
        }
        if activeScene?.id == scene.id { activeScene = nil }
        saveAll()
    }

    func setActive(_ scene: ScenePreset?) {
        activeScene = scene
        if var s = scene, let idx = scenes.firstIndex(where: { $0.id == s.id }) {
            s.lastUsedAt = Date()
            s.usageCount += 1
            scenes[idx] = s
            saveAll()
        }
    }

    func toggleFavorite(_ scene: ScenePreset) {
        guard let idx = scenes.firstIndex(where: { $0.id == scene.id }) else { return }
        scenes[idx].isFavorite.toggle()
        scenes = sorted(scenes)
        saveAll()
    }

    // MARK: - Reference Image

    func saveReferenceImage(_ image: NSImage, for scene: ScenePreset) -> Bool {
        guard let dir = scene.sceneDirectory(vault: VaultManager.shared) else { return false }
        let url = dir.appending(path: "reference.png")
        guard let data = image.pngData() else { return false }
        do {
            try data.write(to: url, options: .atomic)
            if let idx = scenes.firstIndex(where: { $0.id == scene.id }) {
                scenes[idx].referenceImageFilename = "reference.png"
                scenes[idx].updatedAt = Date()
                saveAll()
            }
            return true
        } catch { return false }
    }

    func loadReferenceImage(for scene: ScenePreset) -> NSImage? {
        guard let url = scene.referenceImageURL(vault: VaultManager.shared),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return NSImage(contentsOf: url)
    }

    // MARK: - Prompt Injection

    /// Añade el prompt de la escena activa al prompt de sesión.
    func injectActiveScene(into prompt: String) -> String {
        guard let scene = activeScene else { return prompt }
        let scenePrompt = scene.fullScenePrompt
        guard !scenePrompt.isEmpty else { return prompt }
        return prompt.isEmpty ? scenePrompt : "\(prompt), \(scenePrompt)"
    }

    var activeSceneNegative: String {
        activeScene?.basePromptNegative ?? ""
    }

    // MARK: - Filtered List

    var filteredScenes: [ScenePreset] {
        var list = scenes
        if filterFavs { list = list.filter { $0.isFavorite } }
        if let cat = filterCat { list = list.filter { $0.category == cat } }
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            list = list.filter {
                $0.name.lowercased().contains(q) ||
                $0.tags.contains(where: { $0.lowercased().contains(q) }) ||
                $0.category.rawValue.lowercased().contains(q)
            }
        }
        return list
    }

    // MARK: - Private

    private func createSceneDirectory(_ scene: ScenePreset) {
        guard let dir = scene.sceneDirectory(vault: VaultManager.shared) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func sorted(_ list: [ScenePreset]) -> [ScenePreset] {
        list.sorted {
            if $0.isFavorite != $1.isFavorite { return $0.isFavorite }
            return ($0.lastUsedAt ?? $0.createdAt) > ($1.lastUsedAt ?? $1.createdAt)
        }
    }

    // MARK: - Builtin starter scenes

    private func seedBuiltinScenes() {
        guard scenes.isEmpty else { return }

        let starters: [(String, ScenePreset.SceneCategory, ScenePreset.EnvironmentBlock, ScenePreset.LightingBlock, ScenePreset.CameraBlock)] = [
            (
                "Penthouse Sunset",
                .interior,
                .init(locationType: "luxury penthouse", settingStyle: "modern minimalist", timeOfDay: "golden hour sunset", ambientEnergy: "intimate warm", colorGrading: "warm golden tones", props: "floor-to-ceiling windows, city skyline view"),
                .init(style: "soft directional", keyLight: "warm golden backlight through windows", rimLight: true, rimColor: "warm amber"),
                .init(frameType: "medium shot", angle: "eye level", dof: "shallow depth of field", lens: "85mm")
            ),
            (
                "Studio Editorial",
                .studio,
                .init(locationType: "professional photography studio", settingStyle: "clean white cyclorama", timeOfDay: "controlled studio light", ambientEnergy: "professional editorial", colorGrading: "neutral clean"),
                .init(style: "three-point studio lighting", keyLight: "large softbox key light", fillLight: "soft reflector fill", rimLight: true, rimColor: "cool white rim"),
                .init(frameType: "full body shot", angle: "eye level", dof: "deep focus", lens: "85mm", cameraType: "medium format digital")
            ),
            (
                "Neon Nightclub",
                .urban,
                .init(locationType: "upscale nightclub", settingStyle: "cyberpunk futuristic", timeOfDay: "midnight", ambientEnergy: "electric vibrant", colorGrading: "neon teal and magenta", props: "neon lights, fog machine, bar"),
                .init(style: "dramatic low-key", keyLight: "neon magenta side light", fillLight: "teal neon fill", rimLight: true, rimColor: "hot pink", practicals: "neon signs, LED strips"),
                .init(frameType: "medium shot", angle: "low angle", dof: "shallow depth of field", lens: "35mm wide")
            ),
            (
                "Forest Mystical",
                .nature,
                .init(locationType: "ancient mystical forest", settingStyle: "ethereal fantasy", timeOfDay: "golden hour", weather: "light mist", ambientEnergy: "serene mysterious", colorGrading: "warm green tones with golden haze", props: "fallen leaves, moss-covered stones"),
                .init(style: "dappled natural light", keyLight: "warm sunbeams through canopy", fillLight: "soft ambient green fill", rimLight: true, rimColor: "warm golden"),
                .init(frameType: "medium full body", angle: "eye level", dof: "shallow background blur", lens: "85mm")
            ),
            (
                "Boudoir Classic",
                .interior,
                .init(locationType: "elegant boudoir bedroom", settingStyle: "classic romantic", timeOfDay: "late afternoon", ambientEnergy: "intimate sensual", colorGrading: "warm desaturated film tones", props: "silk sheets, velvet curtains, candles, roses"),
                .init(style: "soft rembrandt", keyLight: "warm window light", fillLight: "soft reflector fill", rimLight: false, practicals: "candles"),
                .init(frameType: "three-quarter shot", angle: "eye level", dof: "soft background blur", lens: "85mm", cameraType: "35mm film")
            ),
        ]

        for (name, cat, env, light, cam) in starters {
            var s = ScenePreset(name: name, category: cat, environment: env, lighting: light, camera: cam)
            s.isFavorite = true
            createSceneDirectory(s)
            scenes.append(s)
        }
        saveAll()
    }
}

// MARK: - ScenePickerView (compacto para el center panel)

struct ScenePickerView: View {

    @ObservedObject var engine = SceneEngine.shared
    @State private var expanded   = false
    @State private var editTarget: ScenePreset? = nil

    var body: some View {
        VStack(spacing: 0) {

            // ── Header ──────────────────────────────────────────────
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } }) {
                HStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#f7a26a"))

                    Text("Escena")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)

                    if let active = engine.activeScene {
                        HStack(spacing: 4) {
                            Circle().fill(Color(hex: "#f7a26a")).frame(width: 5, height: 5)
                            Text(active.name)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(Color(hex: "#f7a26a"))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color(hex: "#f7a26a").opacity(0.10))
                        .cornerRadius(4)
                    } else {
                        Text("Ninguna")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Button(action: {
                        let s = engine.create(name: "Nueva escena")
                        editTarget = s
                    }) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain).help("Nueva escena")

                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9)).foregroundColor(.secondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Color.white.opacity(0.03))
            }
            .buttonStyle(.plain)

            if expanded {
                Divider().background(Color.white.opacity(0.06))
                sceneList
            }
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.115))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.07), lineWidth: 1))
        .sheet(item: $editTarget) { s in SceneEditorSheet(scene: s) }
    }

    @ViewBuilder
    var sceneList: some View {
        VStack(spacing: 0) {

            // Search + Filtros
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10)).foregroundColor(.secondary)
                TextField("Buscar escena…", text: $engine.searchText)
                    .textFieldStyle(.plain).font(.system(size: 12)).foregroundColor(.white)
                if !engine.searchText.isEmpty {
                    Button(action: { engine.searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10)).foregroundColor(.secondary)
                    }.buttonStyle(.plain)
                }
                Divider().frame(height: 14).background(Color.white.opacity(0.1))
                Button(action: { engine.filterFavs.toggle() }) {
                    Image(systemName: engine.filterFavs ? "star.fill" : "star")
                        .font(.system(size: 11))
                        .foregroundColor(engine.filterFavs ? .yellow : .secondary)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.white.opacity(0.04))

            // Category pills
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    catPill(nil, label: "Todas")
                    ForEach(ScenePreset.SceneCategory.allCases, id: \.self) { cat in
                        catPill(cat, label: cat.rawValue)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
            }
            .background(Color.white.opacity(0.02))

            if engine.filteredScenes.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "photo.slash")
                        .font(.system(size: 22)).foregroundColor(.white.opacity(0.1))
                    Text("Sin escenas.\nPulsa + para crear una.")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 20)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(engine.filteredScenes) { scene in
                            SceneRowView(scene: scene, onEdit: { editTarget = scene })
                            Divider().background(Color.white.opacity(0.04)).padding(.leading, 40)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }

            if engine.activeScene != nil {
                Divider().background(Color.white.opacity(0.06))
                Button(action: { engine.setActive(nil) }) {
                    Label("Desactivar escena", systemImage: "photo.slash")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
                .buttonStyle(.plain).frame(maxWidth: .infinity).padding(.vertical, 8)
            }
        }
    }

    func catPill(_ cat: ScenePreset.SceneCategory?, label: String) -> some View {
        let isSelected = engine.filterCat == cat
        return Button(action: { engine.filterCat = cat }) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(isSelected ? .white : .secondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(isSelected ? Color(hex: "#f7a26a").opacity(0.25) : Color.white.opacity(0.05))
                .cornerRadius(5)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - SceneRowView

struct SceneRowView: View {

    let scene: ScenePreset
    var onEdit: () -> Void

    @ObservedObject var engine = SceneEngine.shared
    @State private var hovered     = false
    @State private var refImage:   NSImage? = nil

    var isActive: Bool { engine.activeScene?.id == scene.id }

    var body: some View {
        HStack(spacing: 10) {

            // Thumbnail o icono de categoría
            ZStack {
                if let img = refImage {
                    Image(nsImage: img)
                        .resizable().scaledToFill()
                        .frame(width: 30, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(hex: "#f7a26a").opacity(isActive ? 0.4 : 0.15))
                        .frame(width: 30, height: 30)
                    Image(systemName: scene.category.icon)
                        .font(.system(size: 13))
                        .foregroundColor(Color(hex: "#f7a26a"))
                }
                if isActive {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(hex: "#f7a26a"), lineWidth: 2)
                        .frame(width: 30, height: 30)
                }
            }
            .onAppear { refImage = SceneEngine.shared.loadReferenceImage(for: scene) }

            // Info
            VStack(alignment: .leading, spacing: 1) {
                Text(scene.name)
                    .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                    .foregroundColor(isActive ? .white : Color.white.opacity(0.8))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(scene.category.rawValue)
                        .font(.system(size: 9)).foregroundColor(.secondary)
                    if scene.usageCount > 0 {
                        Text("· \(scene.usageCount)×")
                            .font(.system(size: 9)).foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            // Favorite
            Button(action: { engine.toggleFavorite(scene) }) {
                Image(systemName: scene.isFavorite ? "star.fill" : "star")
                    .font(.system(size: 10))
                    .foregroundColor(scene.isFavorite ? .yellow : Color.secondary.opacity(hovered ? 0.8 : 0))
            }.buttonStyle(.plain)

            // Edit
            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .font(.system(size: 10))
                    .foregroundColor(Color.secondary.opacity(hovered ? 0.8 : 0))
            }.buttonStyle(.plain)

            // Activate
            Button(action: { engine.setActive(isActive ? nil : scene) }) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundColor(isActive ? Color(hex: "#f7a26a") : .secondary)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(isActive ? Color(hex: "#f7a26a").opacity(0.06) : hovered ? Color.white.opacity(0.03) : .clear)
        .onHover { hovered = $0 }
    }
}

// MARK: - SceneEditorSheet

struct SceneEditorSheet: View {

    @State var scene: ScenePreset
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var engine = SceneEngine.shared

    @State private var refPreview: NSImage? = nil

    var body: some View {
        VStack(spacing: 0) {

            // Header
            HStack(spacing: 12) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 22))
                    .foregroundColor(Color(hex: "#f7a26a"))
                VStack(alignment: .leading, spacing: 2) {
                    Text(scene.name.isEmpty ? "Nueva escena" : scene.name)
                        .font(.system(size: 15, weight: .bold)).foregroundColor(.white)
                    Text("Preset de escena · SDPipeline Studio")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
                Spacer()
                Button("Cancelar") { dismiss() }.buttonStyle(.plain).foregroundColor(.secondary)
                Button("Guardar") { engine.save(scene); dismiss() }
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Color(hex: "#f7a26a"))
                    .foregroundColor(.black).cornerRadius(6)
                    .buttonStyle(.plain)
            }
            .padding(20).background(Color.white.opacity(0.03))

            Divider().background(Color.white.opacity(0.08))

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    // ── Identidad ────────────────────────────────────
                    section("Identidad") {
                        row("Nombre") {
                            TextField("Penthouse Sunset, Forest Mist…", text: $scene.name)
                                .textFieldStyle(.roundedBorder)
                        }
                        row("Categoría") {
                            Picker("", selection: $scene.category) {
                                ForEach(ScenePreset.SceneCategory.allCases, id: \.self) { cat in
                                    Label(cat.rawValue, systemImage: cat.icon).tag(cat)
                                }
                            }
                            .pickerStyle(.menu).labelsHidden()
                            .frame(maxWidth: .infinity)
                            .background(Color.white.opacity(0.06)).cornerRadius(6)
                        }
                    }

                    // ── Imagen de referencia ─────────────────────────
                    section("Imagen de referencia") {
                        HStack(spacing: 16) {
                            ZStack {
                                if let img = refPreview {
                                    Image(nsImage: img).resizable().scaledToFill()
                                        .frame(width: 80, height: 80)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                } else {
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color.white.opacity(0.05))
                                        .frame(width: 80, height: 80)
                                        .overlay(
                                            Image(systemName: "photo").font(.system(size: 24))
                                                .foregroundColor(.white.opacity(0.15))
                                        )
                                }
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Referencia para img2img / ControlNet")
                                    .font(.system(size: 11)).foregroundColor(.secondary)
                                HStack(spacing: 8) {
                                    Button("Seleccionar…") { selectRefImage() }
                                        .buttonStyle(.plain)
                                        .foregroundColor(Color(hex: "#f7a26a"))
                                        .font(.system(size: 12, weight: .medium))
                                        .padding(.horizontal, 10).padding(.vertical, 5)
                                        .background(Color(hex: "#f7a26a").opacity(0.12))
                                        .cornerRadius(6)
                                    if refPreview != nil {
                                        Button("Eliminar") { refPreview = nil; scene.referenceImageFilename = nil }
                                            .buttonStyle(.plain).foregroundColor(.secondary).font(.system(size: 11))
                                    }
                                }
                            }
                        }
                    }

                    // ── Ambiente ─────────────────────────────────────
                    section("Ambiente") {
                        row("Localización")  { TextField("luxury penthouse, ancient forest…", text: $scene.environment.locationType).textFieldStyle(.roundedBorder) }
                        row("Estilo")        { TextField("modern minimalist, baroque opulent…", text: $scene.environment.settingStyle).textFieldStyle(.roundedBorder) }
                        row("Momento")       { TextField("golden hour, midnight, midday…", text: $scene.environment.timeOfDay).textFieldStyle(.roundedBorder) }
                        row("Clima")         { TextField("clear sky, light rain, foggy…", text: $scene.environment.weather).textFieldStyle(.roundedBorder) }
                        row("Energía")       { TextField("serene, electric, intimate…", text: $scene.environment.ambientEnergy).textFieldStyle(.roundedBorder) }
                        row("Color grading") { TextField("warm tones, teal-orange…", text: $scene.environment.colorGrading).textFieldStyle(.roundedBorder) }
                        row("Props")         { TextField("silk sheets, champagne glass…", text: $scene.environment.props).textFieldStyle(.roundedBorder) }
                        row("Extra")         { TextField("tokens adicionales…", text: $scene.environment.extra).textFieldStyle(.roundedBorder) }
                    }

                    // ── Iluminación ───────────────────────────────────
                    section("Iluminación") {
                        row("Estilo")       { TextField("soft rembrandt, hard chiaroscuro…", text: $scene.lighting.style).textFieldStyle(.roundedBorder) }
                        row("Key light")    { TextField("warm golden backlight…", text: $scene.lighting.keyLight).textFieldStyle(.roundedBorder) }
                        row("Fill light")   { TextField("soft cool fill…", text: $scene.lighting.fillLight).textFieldStyle(.roundedBorder) }
                        row("Prácticas")    { TextField("candles, neon signs, LED…", text: $scene.lighting.practicals).textFieldStyle(.roundedBorder) }
                        HStack {
                            Text("Rim light").font(.system(size: 11)).foregroundColor(.secondary)
                            Spacer()
                            Toggle("", isOn: $scene.lighting.rimLight).toggleStyle(.switch).labelsHidden().scaleEffect(0.8)
                        }
                        if scene.lighting.rimLight {
                            row("Color rim") { TextField("warm amber, cool blue…", text: $scene.lighting.rimColor).textFieldStyle(.roundedBorder) }
                        }
                        row("Extra") { TextField("tokens adicionales…", text: $scene.lighting.extra).textFieldStyle(.roundedBorder) }
                    }

                    // ── Cámara ────────────────────────────────────────
                    section("Cámara") {
                        row("Encuadre")     { TextField("medium shot, full body, close-up…", text: $scene.camera.frameType).textFieldStyle(.roundedBorder) }
                        row("Ángulo")       { TextField("eye level, low angle, bird's eye…", text: $scene.camera.angle).textFieldStyle(.roundedBorder) }
                        row("Profundidad")  { TextField("shallow depth of field, deep focus…", text: $scene.camera.dof).textFieldStyle(.roundedBorder) }
                        row("Lente")        { TextField("85mm, 35mm wide…", text: $scene.camera.lens).textFieldStyle(.roundedBorder) }
                        row("Cámara")       { TextField("35mm film, medium format digital…", text: $scene.camera.cameraType).textFieldStyle(.roundedBorder) }
                        row("Extra")        { TextField("tokens adicionales…", text: $scene.camera.extra).textFieldStyle(.roundedBorder) }
                    }

                    // ── Prompts ────────────────────────────────────────
                    section("Prompts base") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Positivo").font(.system(size: 11)).foregroundColor(.secondary)
                            TextEditor(text: $scene.basePromptPositive)
                                .font(.system(size: 12)).scrollContentBackground(.hidden)
                                .foregroundColor(Color(red: 0.85, green: 0.95, blue: 0.78))
                                .frame(minHeight: 50).padding(8)
                                .background(Color.white.opacity(0.04)).cornerRadius(6)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Negativo").font(.system(size: 11)).foregroundColor(.secondary)
                            TextEditor(text: $scene.basePromptNegative)
                                .font(.system(size: 12)).scrollContentBackground(.hidden)
                                .foregroundColor(Color(red: 1, green: 0.6, blue: 0.55))
                                .frame(minHeight: 40).padding(8)
                                .background(Color.white.opacity(0.04)).cornerRadius(6)
                        }
                        if !scene.fullScenePrompt.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Preview prompt generado:").font(.system(size: 10)).foregroundColor(.secondary)
                                Text(scene.fullScenePrompt)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(Color(hex: "#f7a26a").opacity(0.85))
                                    .padding(8).background(Color.black.opacity(0.25)).cornerRadius(6)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 580, height: 720)
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
        .onAppear { refPreview = SceneEngine.shared.loadReferenceImage(for: scene) }
    }

    // MARK: - Helpers

    private func selectRefImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .webP]
        panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        panel.title = "Seleccionar referencia para \(scene.name)"
        guard panel.runModal() == .OK, let url = panel.url,
              let img = NSImage(contentsOf: url) else { return }
        refPreview = img
        _ = SceneEngine.shared.saveReferenceImage(img, for: scene)
    }

    @ViewBuilder
    func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(.secondary).tracking(1)
            VStack(alignment: .leading, spacing: 8) { content() }
                .padding(12).background(Color.white.opacity(0.03)).cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.06), lineWidth: 1))
        }
    }

    @ViewBuilder
    func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundColor(.secondary)
            content()
        }
    }
}
