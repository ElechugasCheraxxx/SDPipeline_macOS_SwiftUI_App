import Foundation
import AppKit
import SwiftUI
import Combine

// MARK: - EmbeddingManager
//
// Gestiona Textual Inversions y Embeddings de Stable Diffusion.
// Fuente: A1111 /sdapi/v1/embeddings
//
// Funcionalidades:
//   - Fetch de todos los embeddings disponibles en A1111
//   - Registro local con metadatos (descripción, tags, trigger word, checkpoint base)
//   - Búsqueda y filtrado
//   - Favoritos persistidos en UserDefaults
//   - Inyección de tokens en prompts (usar trigger word como <name>)
//   - Estadísticas de uso
//
// Diferencia con LoRA:
//   - Los embeddings usan la sintaxis directa del nombre sin <lora:> wrapper
//   - Se activan simplemente mencionando el trigger word en el prompt
//   - El A1111 los carga automáticamente desde la carpeta /embeddings
//
// ROADMAP: "Soporte para embeddings/textual inversions" (🟡 MEDIO PLAZO)

// MARK: - Models

struct EmbeddingEntry: Identifiable, Codable, Hashable {
    var id:          UUID    = UUID()
    var name:        String               // nombre del archivo (sin extensión)
    var step:        Int?    = nil        // paso de entrenamiento
    var sdCheckpoint: String? = nil       // checkpoint asociado (del API)
    var sdCheckpointName: String? = nil

    // Metadatos locales (editables)
    var displayName: String  = ""
    var description: String  = ""
    var triggerWord: String  = ""        // cómo usarlo en el prompt
    var tags:        [String] = []
    var baseModel:   String  = ""        // "SD 1.5", "SDXL", "Pony", etc.
    var isFavorite:  Bool    = false
    var usageCount:  Int     = 0
    var addedAt:     Date    = Date()
    var lastUsedAt:  Date?   = nil
    var notes:       String  = ""
    var isNSFW:      Bool    = false

    // Computed
    var effectiveTriggerWord: String {
        triggerWord.isEmpty ? name : triggerWord
    }

    var effectiveDisplayName: String {
        displayName.isEmpty ? name : displayName
    }

    func hash(into hasher: inout Hasher) { hasher.combine(name) }
    static func == (lhs: EmbeddingEntry, rhs: EmbeddingEntry) -> Bool { lhs.name == rhs.name }
}

// MARK: - EmbeddingManager

@MainActor
final class EmbeddingManager: ObservableObject {

    static let shared = EmbeddingManager()
    private init() { loadRegistry() }

    // MARK: - State

    @Published var embeddings:      [EmbeddingEntry] = []
    @Published var isLoading:       Bool             = false
    @Published var searchText:      String           = ""
    @Published var filterFavs:      Bool             = false
    @Published var filterNSFW:      Bool             = false
    @Published var errorMessage:    String?          = nil

    // Embeddings activos para inyección
    @Published var activeEmbeddings: [String] = []   // nombres activos

    // MARK: - Fetch from A1111

    func fetchEmbeddings(baseURL: String) async {
        isLoading    = true
        errorMessage = nil
        defer { isLoading = false }

        guard let url = URL(string: "\(baseURL)/sdapi/v1/embeddings") else { return }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            errorMessage = "No se pudo conectar a A1111 para obtener embeddings."
            return
        }

        // A1111 response: { "loaded": { "name": { "step": N, "sd_checkpoint": "...", ... } }, "skipped": {...} }
        var newEmbeddings: [EmbeddingEntry] = []

        if let loaded = json["loaded"] as? [String: Any] {
            for (name, info) in loaded {
                let existing = embeddings.first { $0.name == name }
                var entry = existing ?? EmbeddingEntry(name: name)

                if let dict = info as? [String: Any] {
                    entry.step             = dict["step"] as? Int
                    entry.sdCheckpoint     = dict["sd_checkpoint"] as? String
                    entry.sdCheckpointName = dict["sd_checkpoint_name"] as? String
                }

                newEmbeddings.append(entry)
            }
        }

        // Merge: keep local metadata, update API data
        var merged = embeddings
        for newEntry in newEmbeddings {
            if let idx = merged.firstIndex(where: { $0.name == newEntry.name }) {
                merged[idx].step             = newEntry.step
                merged[idx].sdCheckpoint     = newEntry.sdCheckpoint
                merged[idx].sdCheckpointName = newEntry.sdCheckpointName
            } else {
                merged.append(newEntry)
            }
        }
        embeddings = merged.sorted { $0.name < $1.name }
        saveRegistry()
    }

    // MARK: - CRUD

    func updateEntry(_ entry: EmbeddingEntry) {
        if let idx = embeddings.firstIndex(where: { $0.name == entry.name }) {
            embeddings[idx] = entry
        } else {
            embeddings.append(entry)
        }
        saveRegistry()
    }

    func toggleFavorite(_ name: String) {
        guard let idx = embeddings.firstIndex(where: { $0.name == name }) else { return }
        embeddings[idx].isFavorite.toggle()
        saveRegistry()
    }

    func delete(_ name: String) {
        embeddings.removeAll { $0.name == name }
        activeEmbeddings.removeAll { $0 == name }
        saveRegistry()
    }

    func incrementUsage(_ name: String) {
        guard let idx = embeddings.firstIndex(where: { $0.name == name }) else { return }
        embeddings[idx].usageCount += 1
        embeddings[idx].lastUsedAt  = Date()
        saveRegistry()
    }

    // MARK: - Active Embeddings (Prompt Injection)

    func activate(_ name: String) {
        guard !activeEmbeddings.contains(name) else { return }
        activeEmbeddings.append(name)
    }

    func deactivate(_ name: String) {
        activeEmbeddings.removeAll { $0 == name }
    }

    func toggleActive(_ name: String) {
        if activeEmbeddings.contains(name) { deactivate(name) } else { activate(name) }
    }

    func clearActive() {
        activeEmbeddings.removeAll()
    }

    /// Inyectar embeddings activos en un prompt.
    func inject(into prompt: String) -> String {
        guard !activeEmbeddings.isEmpty else { return prompt }
        let tokens = activeEmbeddings.compactMap { name -> String? in
            let entry = embeddings.first { $0.name == name }
            return entry?.effectiveTriggerWord ?? name
        }
        let injection = tokens.joined(separator: ", ")
        if prompt.isEmpty { return injection }
        return "\(prompt), \(injection)"
    }

    var activeTokensPreview: String {
        activeEmbeddings.compactMap { name in
            embeddings.first { $0.name == name }?.effectiveTriggerWord ?? name
        }
        .joined(separator: ", ")
    }

    // MARK: - Filtered List

    var filteredEmbeddings: [EmbeddingEntry] {
        var list = embeddings
        if filterFavs  { list = list.filter { $0.isFavorite } }
        if !filterNSFW { list = list.filter { !$0.isNSFW } }
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            list = list.filter {
                $0.name.lowercased().contains(q) ||
                $0.displayName.lowercased().contains(q) ||
                $0.triggerWord.lowercased().contains(q) ||
                $0.tags.contains(where: { $0.lowercased().contains(q) })
            }
        }
        return list
    }

    var favorites: [EmbeddingEntry] {
        embeddings.filter { $0.isFavorite }
    }

    // MARK: - Persistence

    private var registryURL: URL? {
        VaultManager.shared.vaultMetaURL?.appending(path: "embeddings_registry.json")
    }

    func saveRegistry() {
        guard let url  = registryURL,
              let data = try? JSONEncoder.pretty.encode(embeddings) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func loadRegistry() {
        guard let url  = registryURL,
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder.iso8601.decode([EmbeddingEntry].self, from: data)
        else { return }
        embeddings = list
    }
}

// MARK: - EmbeddingManagerView

struct EmbeddingManagerView: View {

    @ObservedObject var manager  = EmbeddingManager.shared
    @Binding var baseURL:          String
    @Binding var prompt:           String

    @State private var editTarget: EmbeddingEntry? = nil
    @State private var expanded    = false

    var body: some View {
        VStack(spacing: 0) {
            header

            if expanded {
                Divider().background(Color.white.opacity(0.06))

                // Search + filters
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundColor(.secondary)
                    TextField("Buscar embedding…", text: $manager.searchText)
                        .textFieldStyle(.plain).font(.system(size: 12)).foregroundColor(.white)

                    Button(action: { manager.filterFavs.toggle() }) {
                        Image(systemName: manager.filterFavs ? "star.fill" : "star")
                            .font(.system(size: 11))
                            .foregroundColor(manager.filterFavs ? .yellow : .secondary)
                    }.buttonStyle(.plain)

                    Toggle("NSFW", isOn: $manager.filterNSFW)
                        .toggleStyle(.button)
                        .font(.system(size: 9))
                        .controlSize(.mini)
                        .tint(.red.opacity(0.4))
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.white.opacity(0.04))

                if manager.isLoading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Cargando embeddings…").font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(20)
                } else if manager.filteredEmbeddings.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "text.badge.plus").font(.system(size: 22))
                            .foregroundColor(.white.opacity(0.08))
                        Text("Sin embeddings. Pulsa ↺ para cargar desde A1111.")
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(20)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(manager.filteredEmbeddings) { entry in
                                EmbeddingRowView(
                                    entry:    entry,
                                    isActive: manager.activeEmbeddings.contains(entry.name),
                                    onToggle: { manager.toggleActive(entry.name) },
                                    onFav:    { manager.toggleFavorite(entry.name) },
                                    onEdit:   { editTarget = entry }
                                )
                                Divider().background(Color.white.opacity(0.04))
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                }

                // Active tokens preview
                if !manager.activeEmbeddings.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "text.badge.checkmark").font(.system(size: 10))
                            .foregroundColor(Color(hex: "#34d399"))
                        Text(manager.activeTokensPreview)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Color(hex: "#34d399"))
                            .lineLimit(1)
                        Spacer()
                        Button("Inyectar") {
                            prompt = manager.inject(into: prompt)
                        }
                        .buttonStyle(.plain).font(.system(size: 10))
                        .foregroundColor(Color(hex: "#7c6af7"))

                        Button("Limpiar") { manager.clearActive() }
                            .buttonStyle(.plain).font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color(hex: "#34d399").opacity(0.06))
                }

                if let err = manager.errorMessage {
                    Text("⚠ \(err)").font(.system(size: 10)).foregroundColor(.red.opacity(0.8))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                }
            }
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.115))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.07), lineWidth: 1))
        .sheet(item: $editTarget) { entry in EmbeddingEditorSheet(entry: entry) }
    }

    var header: some View {
        Button(action: { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } }) {
            HStack(spacing: 8) {
                Image(systemName: "text.badge.plus")
                    .font(.system(size: 11)).foregroundColor(Color(hex: "#a78bfa"))
                Text("Embeddings / TI")
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(.white)

                if !manager.activeEmbeddings.isEmpty {
                    Text("\(manager.activeEmbeddings.count) activos")
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color(hex: "#a78bfa").opacity(0.2))
                        .foregroundColor(Color(hex: "#a78bfa")).cornerRadius(4)
                }

                Spacer()

                Button(action: { Task { await manager.fetchEmbeddings(baseURL: baseURL) } }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }.buttonStyle(.plain).help("Recargar embeddings")

                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9)).foregroundColor(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Color.white.opacity(0.03))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - EmbeddingRowView

struct EmbeddingRowView: View {
    let entry:    EmbeddingEntry
    let isActive: Bool
    var onToggle: () -> Void
    var onFav:    () -> Void
    var onEdit:   () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            // Active dot
            Circle()
                .fill(isActive ? Color(hex: "#a78bfa") : Color.white.opacity(0.1))
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.effectiveDisplayName)
                    .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                    .foregroundColor(isActive ? .white : .white.opacity(0.75))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if !entry.baseModel.isEmpty {
                        Text(entry.baseModel).font(.system(size: 9)).foregroundColor(.secondary)
                    }
                    if !entry.triggerWord.isEmpty {
                        Text(entry.triggerWord)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(Color(hex: "#a78bfa").opacity(0.7))
                    }
                    if entry.usageCount > 0 {
                        Text("×\(entry.usageCount)")
                            .font(.system(size: 9)).foregroundColor(.secondary.opacity(0.6))
                    }
                    if entry.isNSFW {
                        Text("NSFW").font(.system(size: 8, weight: .bold))
                            .foregroundColor(Color(hex: "#f472b6"))
                    }
                }
            }

            Spacer()

            if hovered || isActive {
                Button(action: onFav) {
                    Image(systemName: entry.isFavorite ? "star.fill" : "star")
                        .font(.system(size: 10))
                        .foregroundColor(entry.isFavorite ? .yellow : .secondary)
                }.buttonStyle(.plain)

                Button(action: onEdit) {
                    Image(systemName: "pencil").font(.system(size: 10)).foregroundColor(.secondary)
                }.buttonStyle(.plain)
            }

            Button(action: onToggle) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundColor(isActive ? Color(hex: "#a78bfa") : .secondary)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(isActive ? Color(hex: "#a78bfa").opacity(0.06) : hovered ? Color.white.opacity(0.03) : .clear)
        .onHover { hovered = $0 }
    }
}

// MARK: - EmbeddingEditorSheet

struct EmbeddingEditorSheet: View {

    @State var entry: EmbeddingEntry
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "text.badge.plus").font(.system(size: 18))
                    .foregroundColor(Color(hex: "#a78bfa"))
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name).font(.system(size: 13, weight: .bold)).foregroundColor(.white)
                    if let step = entry.step {
                        Text("Step \(step)").font(.system(size: 10)).foregroundColor(.secondary)
                    }
                }
                Spacer()
                Button("Cancelar") { dismiss() }.buttonStyle(.plain).foregroundColor(.secondary)
                Button("Guardar") {
                    EmbeddingManager.shared.updateEntry(entry)
                    dismiss()
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color(hex: "#a78bfa")).foregroundColor(.black).cornerRadius(6)
                .buttonStyle(.plain)
            }
            .padding(18).background(Color.white.opacity(0.03))

            Divider().background(Color.white.opacity(0.07))

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    group("Metadatos") {
                        row("Nombre en display") {
                            TextField(entry.name, text: $entry.displayName).textFieldStyle(.roundedBorder)
                        }
                        row("Trigger word") {
                            TextField("palabra clave para el prompt", text: $entry.triggerWord)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                        }
                        row("Modelo base") {
                            TextField("SD 1.5, SDXL…", text: $entry.baseModel).textFieldStyle(.roundedBorder)
                        }
                        row("Notas") {
                            TextEditor(text: $entry.notes)
                                .scrollContentBackground(.hidden)
                                .foregroundColor(.white).font(.system(size: 12))
                                .frame(minHeight: 50).padding(8)
                                .background(Color.white.opacity(0.04)).cornerRadius(6)
                        }
                    }
                    group("Flags") {
                        HStack {
                            Text("NSFW").font(.system(size: 12)).foregroundColor(.secondary); Spacer()
                            Toggle("", isOn: $entry.isNSFW).toggleStyle(.switch).labelsHidden().scaleEffect(0.8)
                        }
                        HStack {
                            Text("Favorito").font(.system(size: 12)).foregroundColor(.secondary); Spacer()
                            Toggle("", isOn: $entry.isFavorite).toggleStyle(.switch).labelsHidden().scaleEffect(0.8)
                        }
                    }
                    if let cp = entry.sdCheckpointName {
                        group("Info A1111") {
                            HStack {
                                Text("Checkpoint").font(.system(size: 11)).foregroundColor(.secondary)
                                Spacer()
                                Text(cp).font(.system(size: 10, design: .monospaced)).foregroundColor(.white.opacity(0.7))
                            }
                        }
                    }
                }
                .padding(18)
            }
        }
        .frame(width: 440, height: 460)
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
    }

    func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold)).foregroundColor(.secondary).tracking(1)
            VStack(alignment: .leading, spacing: 8) { content() }
                .padding(12).background(Color.white.opacity(0.03)).cornerRadius(8)
        }
    }

    func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundColor(.secondary)
            content()
        }
    }
}
