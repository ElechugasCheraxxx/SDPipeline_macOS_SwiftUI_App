import Foundation
import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers

// MARK: - CharacterEngine
// CharacterProfile is defined in Models.swift (single source of truth)

@MainActor
final class CharacterEngine: ObservableObject {

    static let shared = CharacterEngine()
    private init() { loadAll() }

    // MARK: - State

    @Published var characters:     [CharacterProfile] = []
    @Published var activeCharacter: CharacterProfile? = nil
    @Published var searchText:     String            = ""
    @Published var filterFavorites: Bool             = false

    // MARK: - Persistence

    private let indexFilename = "characters_index.json"

    private var indexURL: URL? {
        VaultManager.shared.personajesURL?.appending(path: indexFilename)
    }

    func loadAll() {
        guard let url  = indexURL,
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder.iso8601.decode([CharacterProfile].self, from: data)
        else { return }
        characters = list.sorted {
            if $0.isFavorite != $1.isFavorite { return $0.isFavorite }
            return ($0.lastUsedAt ?? $0.createdAt) > ($1.lastUsedAt ?? $1.createdAt)
        }
    }

    private func saveAll() {
        guard let url = indexURL else { return }
        // Asegurar directorio
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder.pretty.encode(characters) else { return }
        try? data.write(to: url, options: Data.WritingOptions.atomic)
    }

    // MARK: - CRUD

    @discardableResult
    func create(name: String) -> CharacterProfile {
        let c = CharacterProfile(name: name)
        characters.insert(c, at: 0)
        createCharacterDirectory(c)
        saveAll()
        return c
    }

    func save(_ character: CharacterProfile) {
        if let idx = characters.firstIndex(where: { $0.id == character.id }) {
            characters[idx] = character
        } else {
            characters.insert(character, at: 0)
            createCharacterDirectory(character)
        }
        saveAll()
    }

    func delete(_ character: CharacterProfile) {
        characters.removeAll { $0.id == character.id }
        // Eliminar carpeta del personaje del vault
        if let dir = character.characterDirectory(vault: VaultManager.shared) {
            try? FileManager.default.removeItem(at: dir)
        }
        if activeCharacter?.id == character.id { activeCharacter = nil }
        saveAll()
    }

    func setActive(_ character: CharacterProfile?) {
        activeCharacter = character
        // Registrar uso
        if var c = character,
           let idx = characters.firstIndex(where: { $0.id == c.id }) {
            c.lastUsedAt = Date()
            c.totalGenerations += 1
            characters[idx] = c
            saveAll()
        }
    }

    func toggleFavorite(_ character: CharacterProfile) {
        guard let idx = characters.firstIndex(where: { $0.id == character.id }) else { return }
        characters[idx].isFavorite.toggle()
        sortCharacters()
        saveAll()
    }

    // MARK: - Base Image

    func saveBaseImage(_ image: NSImage, for character: CharacterProfile) -> Bool {
        guard let dir = character.characterDirectory(vault: VaultManager.shared) else { return false }
        let imgURL = dir.appending(path: "base.png")
        guard let data = image.pngData() else { return false }
        do {
            try data.write(to: imgURL, options: Data.WritingOptions.atomic)
            // Actualizar perfil con el filename
            if let idx = characters.firstIndex(where: { $0.id == character.id }) {
                characters[idx].baseImageFilename = "base.png"
                characters[idx].updatedAt = Date()
                saveAll()
            }
            return true
        } catch {
            print("⚠️ CharacterEngine: error guardando imagen base: \(error)")
            return false
        }
    }

    func loadBaseImage(for character: CharacterProfile) -> NSImage? {
        guard let url = character.baseImageURL(vault: VaultManager.shared),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return NSImage(contentsOf: url)
    }

    // MARK: - Prompt Injection

    /// Prepender el prompt del personaje activo al prompt de sesión.
    func injectActiveCharacter(into sessionPrompt: String) -> String {
        guard let character = activeCharacter else { return sessionPrompt }
        let charPrompt = character.fullPositivePrompt
        guard !charPrompt.isEmpty else { return sessionPrompt }

        // Personaje al frente + prompt de sesión detrás
        return sessionPrompt.isEmpty
            ? charPrompt
            : "\(charPrompt), \(sessionPrompt)"
    }

    /// Negative prompt del personaje activo.
    var activeCharacterNegative: String {
        activeCharacter?.basePromptNegative ?? ""
    }

    // MARK: - LoRA Sync

    /// Aplicar LoRAs del personaje activo al LoRAManager.
    func applyCharacterLoRAs() {
        guard let character = activeCharacter else { return }
        // Limpiar selección actual
        LoRAManager.shared.clearSelection()
        // Añadir los LoRAs del personaje
        for linked in character.linkedLoRAs {
            if let lora = LoRAManager.shared.availableLoRAs.first(where: {
                $0.name == linked.loraName
            }) {
                LoRAManager.shared.selectLoRA(lora, weight: linked.defaultWeight)
            }
        }
    }

    // MARK: - Seed Pinning

    func pinSeed(_ seed: Int, to characterID: UUID) {
        guard let idx = characters.firstIndex(where: { $0.id == characterID }) else { return }
        if !characters[idx].pinnedSeeds.contains(seed) {
            characters[idx].pinnedSeeds.append(seed)
            saveAll()
        }
    }

    func unpinSeed(_ seed: Int, from characterID: UUID) {
        guard let idx = characters.firstIndex(where: { $0.id == characterID }) else { return }
        characters[idx].pinnedSeeds.removeAll { $0 == seed }
        saveAll()
    }

    // MARK: - Filtered List

    var filteredCharacters: [CharacterProfile] {
        var list = characters
        if filterFavorites { list = list.filter { $0.isFavorite } }
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            list = list.filter {
                $0.name.lowercased().contains(q) ||
                $0.archetype.lowercased().contains(q) ||
                $0.tags.contains(where: { $0.lowercased().contains(q) })
            }
        }
        return list
    }

    // MARK: - Private

    private func createCharacterDirectory(_ character: CharacterProfile) {
        guard let dir = character.characterDirectory(vault: VaultManager.shared) else { return }
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
    }

    private func sortCharacters() {
        characters.sort {
            if $0.isFavorite != $1.isFavorite { return $0.isFavorite }
            return ($0.lastUsedAt ?? $0.createdAt) > ($1.lastUsedAt ?? $1.createdAt)
        }
    }
}

// MARK: - CharacterPickerView
// Vista compacta para el center panel — selector + indicador de activo.

struct CharacterPickerView: View {

    @ObservedObject var engine = CharacterEngine.shared
    @State private var showDetail  = false
    @State private var editTarget: CharacterProfile? = nil

    var body: some View {
        VStack(spacing: 0) {

            // Header
            Button(action: { showDetail.toggle() }) {
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#3de3c0"))

                    Text("Personaje")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)

                    // Badge de activo
                    if let active = engine.activeCharacter {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color(hex: "#3de3c0"))
                                .frame(width: 5, height: 5)
                            Text(active.name)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(Color(hex: "#3de3c0"))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color(hex: "#3de3c0").opacity(0.10))
                        .cornerRadius(4)
                    } else {
                        Text("Ninguno")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    // Nuevo personaje rápido
                    Button(action: {
                        let c = engine.create(name: "Nuevo personaje")
                        editTarget = c
                    }) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Crear nuevo personaje")

                    Image(systemName: showDetail ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Color.white.opacity(0.03))
            }
            .buttonStyle(.plain)

            if showDetail {
                Divider().background(Color.white.opacity(0.06))
                characterList
            }
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.115))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.07), lineWidth: 1))
        .sheet(item: $editTarget) { c in
            CharacterEditorSheet(character: c)
        }
    }

    @ViewBuilder
    var characterList: some View {
        VStack(spacing: 0) {
            // Search
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10)).foregroundColor(.secondary)
                TextField("Buscar…", text: $engine.searchText)
                    .textFieldStyle(.plain).font(.system(size: 12)).foregroundColor(.white)
                if !engine.searchText.isEmpty {
                    Button(action: { engine.searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10)).foregroundColor(.secondary)
                    }.buttonStyle(.plain)
                }
                Divider().frame(height: 14).background(Color.white.opacity(0.1))
                Button(action: { engine.filterFavorites.toggle() }) {
                    Image(systemName: engine.filterFavorites ? "star.fill" : "star")
                        .font(.system(size: 11))
                        .foregroundColor(engine.filterFavorites ? .yellow : .secondary)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.white.opacity(0.04))

            if engine.filteredCharacters.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "person.slash")
                        .font(.system(size: 22)).foregroundColor(.white.opacity(0.1))
                    Text("Sin personajes.\nPulsa + para crear uno.")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 20)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(engine.filteredCharacters) { character in
                            CharacterRowView(
                                character: character,
                                onEdit: { editTarget = character }
                            )
                            Divider().background(Color.white.opacity(0.04)).padding(.leading, 40)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }

            // Desactivar personaje actual
            if engine.activeCharacter != nil {
                Divider().background(Color.white.opacity(0.06))
                Button(action: { engine.setActive(nil) }) {
                    Label("Desactivar personaje", systemImage: "person.slash")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
        }
    }
}

// MARK: - CharacterRowView

struct CharacterRowView: View {

    let character: CharacterProfile
    var onEdit: () -> Void

    @ObservedObject var engine = CharacterEngine.shared
    @State private var hovered = false
    @State private var baseImage: NSImage? = nil

    var isActive: Bool { engine.activeCharacter?.id == character.id }

    var body: some View {
        HStack(spacing: 10) {
            // Avatar (imagen base o inicial)
            ZStack {
                if let img = baseImage {
                    Image(nsImage: img)
                        .resizable().scaledToFill()
                        .frame(width: 30, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            LinearGradient(
                                colors: [Color(hex: "#7c6af7").opacity(0.5), Color(hex: "#3de3c0").opacity(0.4)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 30, height: 30)
                    Text(String(character.name.prefix(1).uppercased()))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                }

                if isActive {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(hex: "#3de3c0"), lineWidth: 2)
                        .frame(width: 30, height: 30)
                }
            }
            .onAppear { baseImage = CharacterEngine.shared.loadBaseImage(for: character) }

            // Info
            VStack(alignment: .leading, spacing: 1) {
                Text(character.name)
                    .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                    .foregroundColor(isActive ? .white : Color.white.opacity(0.8))
                    .lineLimit(1)
                if !character.archetype.isEmpty {
                    Text(character.archetype)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // LoRA badge
            if !character.linkedLoRAs.isEmpty {
                Text("\(character.linkedLoRAs.count) LoRA")
                    .font(.system(size: 9))
                    .foregroundColor(Color(hex: "#7c6af7"))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color(hex: "#7c6af7").opacity(0.12))
                    .cornerRadius(4)
            }

            // Fav
            Button(action: { engine.toggleFavorite(character) }) {
                Image(systemName: character.isFavorite ? "star.fill" : "star")
                    .font(.system(size: 10))
                    .foregroundColor(character.isFavorite ? .yellow : Color.secondary.opacity(hovered ? 0.8 : 0))
            }.buttonStyle(.plain)

            // Edit
            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .font(.system(size: 10))
                    .foregroundColor(Color.secondary.opacity(hovered ? 0.8 : 0))
            }.buttonStyle(.plain)

            // Select / Active
            Button(action: {
                if isActive {
                    engine.setActive(nil)
                } else {
                    engine.setActive(character)
                    engine.applyCharacterLoRAs()
                }
            }) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundColor(isActive ? Color(hex: "#3de3c0") : .secondary)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(
            isActive
                ? Color(hex: "#3de3c0").opacity(0.06)
                : hovered ? Color.white.opacity(0.03) : Color.clear
        )
        .onHover { hovered = $0 }
    }
}

// MARK: - CharacterEditorSheet

struct CharacterEditorSheet: View {

    @State var character: CharacterProfile
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var engine  = CharacterEngine.shared
    @ObservedObject var loraManager = LoRAManager.shared

    @State private var baseImagePreview: NSImage? = nil
    @State private var newTag: String = ""
    @State private var newPinnedSeed: String = ""
    @State private var loraSearch: String = ""
    @State private var saved = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 22))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color(hex: "#7c6af7"), Color(hex: "#3de3c0")],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(character.name.isEmpty ? "Nuevo personaje" : character.name)
                        .font(.system(size: 15, weight: .bold)).foregroundColor(.white)
                    Text("Perfil de personaje · SDPipeline Studio")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
                Spacer()
                Button("Cancelar") { dismiss() }
                    .buttonStyle(.plain).foregroundColor(.secondary)
                Button("Guardar") {
                    engine.save(character)
                    saved = true
                    dismiss()
                }
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(LinearGradient(
                    colors: [Color(hex: "#7c6af7"), Color(hex: "#3de3c0")],
                    startPoint: .leading, endPoint: .trailing
                ))
                .foregroundColor(.white).cornerRadius(6)
                .buttonStyle(.plain)
            }
            .padding(20).background(Color.white.opacity(0.03))

            Divider().background(Color.white.opacity(0.08))

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    // ── Identidad ────────────────────────────────────
                    editorSection("Identidad") {
                        editorRow("Nombre") {
                            TextField("Valentina, Aurora…", text: $character.name)
                                .textFieldStyle(.roundedBorder).font(.system(size: 13))
                        }
                        editorRow("Arquetipo") {
                            TextField("Latina businesswoman, fantasy elf…", text: $character.archetype)
                                .textFieldStyle(.roundedBorder).font(.system(size: 13))
                        }
                        editorRow("Tags") {
                            VStack(alignment: .leading, spacing: 6) {
                                FlowTagView(tags: character.tags) { tag in
                                    character.tags.removeAll { $0 == tag }
                                }
                                HStack(spacing: 6) {
                                    TextField("Añadir tag…", text: $newTag)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(size: 12))
                                        .frame(maxWidth: 160)
                                        .onSubmit { addTag() }
                                    Button("Añadir", action: addTag)
                                        .buttonStyle(.plain)
                                        .foregroundColor(Color(hex: "#3de3c0"))
                                        .font(.system(size: 11))
                                }
                            }
                        }
                    }

                    // ── Descripción física ────────────────────────────
                    editorSection("Descripción física") {
                        editorRow("Edad") {
                            TextField("25 year old woman", text: $character.physicalDescription.age)
                                .textFieldStyle(.roundedBorder).font(.system(size: 13))
                        }
                        editorRow("Cuerpo") {
                            TextField("curvy, hourglass figure", text: $character.physicalDescription.bodyType)
                                .textFieldStyle(.roundedBorder).font(.system(size: 13))
                        }
                        editorRow("Piel") {
                            TextField("warm olive skin", text: $character.physicalDescription.skinTone)
                                .textFieldStyle(.roundedBorder).font(.system(size: 13))
                        }
                        editorRow("Cabello") {
                            TextField("dark brown wavy hair", text: $character.physicalDescription.hairColor)
                                .textFieldStyle(.roundedBorder).font(.system(size: 13))
                        }
                        editorRow("Ojos") {
                            TextField("green eyes", text: $character.physicalDescription.eyeColor)
                                .textFieldStyle(.roundedBorder).font(.system(size: 13))
                        }
                        editorRow("Rostro") {
                            TextField("sharp jawline, full lips", text: $character.physicalDescription.faceFeatures)
                                .textFieldStyle(.roundedBorder).font(.system(size: 13))
                        }
                        editorRow("Extra") {
                            TextField("Tokens adicionales…", text: $character.physicalDescription.extra)
                                .textFieldStyle(.roundedBorder).font(.system(size: 13))
                        }
                    }

                    // ── Prompt base ────────────────────────────────────
                    editorSection("Prompt base") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Positivo").font(.system(size: 11)).foregroundColor(.secondary)
                            TextEditor(text: $character.basePromptPositive)
                                .font(.system(size: 12))
                                .scrollContentBackground(.hidden)
                                .foregroundColor(Color(red: 0.85, green: 0.95, blue: 0.78))
                                .frame(minHeight: 60)
                                .padding(8)
                                .background(Color.white.opacity(0.04))
                                .cornerRadius(6)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Negativo").font(.system(size: 11)).foregroundColor(.secondary)
                            TextEditor(text: $character.basePromptNegative)
                                .font(.system(size: 12))
                                .scrollContentBackground(.hidden)
                                .foregroundColor(Color(red: 1, green: 0.6, blue: 0.55))
                                .frame(minHeight: 40)
                                .padding(8)
                                .background(Color.white.opacity(0.04))
                                .cornerRadius(6)
                        }
                        // Preview del prompt completo generado
                        if !character.fullPositivePrompt.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Preview del prompt completo:")
                                    .font(.system(size: 10)).foregroundColor(.secondary)
                                Text(character.fullPositivePrompt)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(Color(hex: "#3de3c0").opacity(0.8))
                                    .padding(8)
                                    .background(Color.black.opacity(0.25))
                                    .cornerRadius(6)
                                    .textSelection(.enabled)
                            }
                        }
                    }

                    // ── Imagen base ────────────────────────────────────
                    editorSection("Imagen base") {
                        HStack(spacing: 16) {
                            // Preview
                            ZStack {
                                if let img = baseImagePreview {
                                    Image(nsImage: img)
                                        .resizable().scaledToFill()
                                        .frame(width: 80, height: 80)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                } else {
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color.white.opacity(0.05))
                                        .frame(width: 80, height: 80)
                                        .overlay(
                                            Image(systemName: "person.crop.rectangle")
                                                .font(.system(size: 24))
                                                .foregroundColor(.white.opacity(0.15))
                                        )
                                }
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                Text("Imagen de referencia para img2img y ControlNet")
                                    .font(.system(size: 11)).foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)

                                HStack(spacing: 8) {
                                    Button("Seleccionar…") { selectBaseImage() }
                                        .buttonStyle(.plain)
                                        .foregroundColor(Color(hex: "#3de3c0"))
                                        .font(.system(size: 12, weight: .medium))
                                        .padding(.horizontal, 10).padding(.vertical, 5)
                                        .background(Color(hex: "#3de3c0").opacity(0.12))
                                        .cornerRadius(6)

                                    if baseImagePreview != nil || character.baseImageFilename != nil {
                                        Button("Eliminar") {
                                            baseImagePreview = nil
                                            character.baseImageFilename = nil
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundColor(.secondary)
                                        .font(.system(size: 11))
                                    }
                                }
                            }
                        }
                    }

                    // ── LoRAs vinculados ───────────────────────────────
                    editorSection("LoRAs vinculados") {
                        if loraManager.availableLoRAs.isEmpty {
                            Text("Sin LoRAs cargados. Abre la app con A1111 online y recarga.")
                                .font(.system(size: 11)).foregroundColor(.secondary)
                        } else {
                            // Buscar
                            HStack(spacing: 6) {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 10)).foregroundColor(.secondary)
                                TextField("Buscar LoRA…", text: $loraSearch)
                                    .textFieldStyle(.plain).font(.system(size: 12)).foregroundColor(.white)
                            }
                            .padding(6).background(Color.white.opacity(0.04)).cornerRadius(6)

                            let filtered = loraSearch.isEmpty
                                ? loraManager.availableLoRAs
                                : loraManager.availableLoRAs.filter {
                                    $0.displayName.lowercased().contains(loraSearch.lowercased())
                                }

                            ForEach(filtered.prefix(20)) { lora in
                                let linked = character.linkedLoRAs.first(where: { $0.loraName == lora.name })
                                let isLinked = linked != nil

                                HStack(spacing: 8) {
                                    Button(action: {
                                        if isLinked {
                                            character.linkedLoRAs.removeAll { $0.loraName == lora.name }
                                        } else {
                                            character.linkedLoRAs.append(
                                                CharacterProfile.LinkedLoRA(loraName: lora.name)
                                            )
                                        }
                                    }) {
                                        Image(systemName: isLinked ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 14))
                                            .foregroundColor(isLinked ? Color(hex: "#7c6af7") : .secondary)
                                    }.buttonStyle(.plain)

                                    Text(lora.displayName)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(isLinked ? .white : Color.white.opacity(0.6))
                                        .lineLimit(1)
                                    Spacer()

                                    if isLinked, let idx = character.linkedLoRAs.firstIndex(where: { $0.loraName == lora.name }) {
                                        Slider(
                                            value: $character.linkedLoRAs[idx].defaultWeight,
                                            in: 0.0...1.5, step: 0.05
                                        )
                                        .tint(character.linkedLoRAs[idx].defaultWeight > 1.0 ? .yellow : Color(hex: "#7c6af7"))
                                        .frame(width: 80)

                                        Text(String(format: "%.2f", character.linkedLoRAs[idx].defaultWeight))
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(.secondary)
                                            .frame(width: 28)
                                    }
                                }
                            }
                        }
                    }

                    // ── Checkpoint preferido ───────────────────────────
                    editorSection("Configuración avanzada") {
                        editorRow("Checkpoint preferido") {
                            TextField("nombre_del_modelo.safetensors", text: $character.preferredCheckpoint)
                                .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                        }
                        editorRow("Seeds fijados") {
                            VStack(alignment: .leading, spacing: 6) {
                                if character.pinnedSeeds.isEmpty {
                                    Text("Sin seeds fijados")
                                        .font(.system(size: 11)).foregroundColor(.secondary)
                                } else {
                                    FlowTagView(
                                        tags: character.pinnedSeeds.map { String($0) },
                                        tint: Color(hex: "#7c6af7")
                                    ) { tag in
                                        character.pinnedSeeds.removeAll { String($0) == tag }
                                    }
                                }
                                HStack(spacing: 6) {
                                    TextField("Seed…", text: $newPinnedSeed)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(size: 12, design: .monospaced))
                                        .frame(width: 120)
                                        .onSubmit { addSeed() }
                                    Button("Fijar", action: addSeed)
                                        .buttonStyle(.plain)
                                        .foregroundColor(Color(hex: "#7c6af7"))
                                        .font(.system(size: 11))
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 600, height: 780)
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
        .onAppear {
            baseImagePreview = CharacterEngine.shared.loadBaseImage(for: character)
        }
    }

    // MARK: - Actions

    private func addTag() {
        let t = newTag.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !character.tags.contains(t) else { return }
        character.tags.append(t)
        newTag = ""
    }

    private func addSeed() {
        guard let seed = Int(newPinnedSeed.trimmingCharacters(in: .whitespaces)) else { return }
        if !character.pinnedSeeds.contains(seed) { character.pinnedSeeds.append(seed) }
        newPinnedSeed = ""
    }

    private func selectBaseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .webP]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Seleccionar imagen base de \(character.name)"

        guard panel.runModal() == .OK, let url = panel.url,
              let img = NSImage(contentsOf: url) else { return }

        baseImagePreview = img
        _ = CharacterEngine.shared.saveBaseImage(img, for: character)
    }

    // MARK: - Section helper

    @ViewBuilder
    func editorSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(.secondary)
                .tracking(1)
            VStack(alignment: .leading, spacing: 8) { content() }
                .padding(12)
                .background(Color.white.opacity(0.03))
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.06), lineWidth: 1))
        }
    }

    @ViewBuilder
    func editorRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundColor(.secondary)
            content()
        }
    }
}

// MARK: - FlowTagView (chips inline con wrap)

struct FlowTagView: View {
    let tags: [String]
    var tint: Color = Color(hex: "#3de3c0")
    var onRemove: (String) -> Void

    var body: some View {
        // Wrap manual con HStack + VStack
        GeometryReader { geo in
            self.generateTags(in: geo)
        }
        .frame(minHeight: 24)
    }

    private func generateTags(in geo: GeometryProxy) -> some View {
        var width: CGFloat = 0
        var height: CGFloat = 0
        var rows: [[String]] = [[]]

        for tag in tags {
            let tagWidth: CGFloat = CGFloat(tag.count) * 8 + 32
            if width + tagWidth > geo.size.width {
                width = tagWidth
                height += 26
                rows.append([tag])
            } else {
                width += tagWidth
                rows[rows.count - 1].append(tag)
            }
        }

        return VStack(alignment: .leading, spacing: 4) {
            ForEach(rows.indices, id: \.self) { rowIdx in
                HStack(spacing: 4) {
                    ForEach(rows[rowIdx], id: \.self) { tag in
                        HStack(spacing: 4) {
                            Text(tag).font(.system(size: 10))
                                .foregroundColor(tint)
                            Button(action: { onRemove(tag) }) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundColor(tint.opacity(0.7))
                            }.buttonStyle(.plain)
                        }
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(tint.opacity(0.10))
                        .cornerRadius(5)
                    }
                }
            }
        }
    }
}
