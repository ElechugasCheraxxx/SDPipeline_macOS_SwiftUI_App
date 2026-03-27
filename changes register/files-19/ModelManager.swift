import Foundation
import AppKit
import SwiftUI
import Combine

// MARK: - ModelManager
//
// Gestiona los checkpoints de Stable Diffusion vía A1111 API:
//   - Fetch /sdapi/v1/sd-models
//   - Switch model via /sdapi/v1/options
//   - Private registry: metadatos locales por modelo (notas, tags, benchmarks, licencia)
//   - Benchmarks: tiempo de generación, VRAM estimada, calidad subjetiva
//
// Persistencia: JSON en Vault/models_registry.json

// MARK: - Models

struct SDModelInfo: Codable, Identifiable, Hashable {
    var id:             String  { sha256 }
    var title:          String               // nombre completo con hash
    var modelName:      String               // nombre limpio
    var sha256:         String
    var filename:       String
    var config:         String?

    // Campos de API
    enum CodingKeys: String, CodingKey {
        case title, modelName = "model_name", sha256, filename, config
    }

    func hash(into hasher: inout Hasher) { hasher.combine(sha256) }
}

struct ModelRecord: Codable, Identifiable {
    var id:            UUID    = UUID()
    var sha256:        String               // llave — matchea SDModelInfo.sha256
    var modelName:     String

    // Metadatos privados
    var notes:         String  = ""
    var tags:          [String] = []
    var isPrivate:     Bool    = false      // ¿aparece en el registry privado?
    var isFavorite:    Bool    = false
    var licenseURL:    String  = ""
    var baseModel:     String  = ""         // "SD 1.5", "SDXL", "Pony", etc.
    var triggerWords:  [String] = []        // palabras clave del modelo
    var nsfw:          Bool    = false      // ¿modelo NSFW?
    var addedAt:       Date    = Date()
    var lastUsedAt:    Date?   = nil
    var usageCount:    Int     = 0

    // Benchmarks
    var benchmarks:    [ModelBenchmark] = []
    var avgGenTime:    Double?          = nil  // segundos
    var estimatedVRAM: Double?          = nil  // GB

    var latestBenchmark: ModelBenchmark? { benchmarks.last }
}

struct ModelBenchmark: Codable, Identifiable {
    var id:          UUID   = UUID()
    var date:        Date   = Date()
    var genTime:     Double              // segundos
    var steps:       Int
    var width:       Int
    var height:      Int
    var samplerName: String
    var rating:      Int    = 0         // 1-5 calidad subjetiva
    var notes:       String = ""
}

// MARK: - ModelManager

@MainActor
final class ModelManager: ObservableObject {

    static let shared = ModelManager()
    private init() { loadRegistry() }

    // MARK: - State

    @Published var availableModels: [SDModelInfo]   = []
    @Published var activeModelName: String          = ""
    @Published var registry:        [ModelRecord]   = []
    @Published var isLoading:       Bool            = false
    @Published var isSwitching:     Bool            = false
    @Published var errorMessage:    String?         = nil
    @Published var searchText:      String          = ""
    @Published var filterFavs:      Bool            = false
    @Published var filterPrivate:   Bool            = false

    // MARK: - API

    func fetchModels(baseURL: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        async let modelsTask  = fetchModelList(baseURL: baseURL)
        async let optionsTask = fetchCurrentModel(baseURL: baseURL)

        let (models, current) = await (modelsTask, optionsTask)
        availableModels = models.sorted { $0.modelName < $1.modelName }
        activeModelName = current

        // Auto-registrar modelos nuevos
        for m in models {
            if !registry.contains(where: { $0.sha256 == m.sha256 }) {
                let rec = ModelRecord(sha256: m.sha256, modelName: m.modelName)
                registry.append(rec)
            }
        }
        saveRegistry()
    }

    private func fetchModelList(baseURL: String) async -> [SDModelInfo] {
        guard let url = URL(string: "\(baseURL)/sdapi/v1/sd-models") else { return [] }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let models = try? JSONDecoder().decode([SDModelInfo].self, from: data)
        else { return [] }
        return models
    }

    private func fetchCurrentModel(baseURL: String) async -> String {
        guard let url = URL(string: "\(baseURL)/sdapi/v1/options") else { return "" }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["sd_model_checkpoint"] as? String
        else { return "" }
        return name
    }

    func switchModel(_ model: SDModelInfo, baseURL: String) async {
        guard !isSwitching else { return }
        isSwitching  = true
        errorMessage = nil

        let payload: [String: Any] = ["sd_model_checkpoint": model.title]
        guard let url  = URL(string: "\(baseURL)/sdapi/v1/options"),
              let body = try? JSONSerialization.data(withJSONObject: payload)
        else { isSwitching = false; return }

        var req = URLRequest(url: url, timeoutInterval: 120)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody  = body

        if let (_, resp) = try? await URLSession.shared.data(for: req),
           let http = resp as? HTTPURLResponse, http.statusCode == 200 {
            activeModelName = model.title
            // Actualizar último uso en registry
            updateUsage(sha256: model.sha256)
        } else {
            errorMessage = "No se pudo cambiar el modelo. A1111 puede estar generando."
        }
        isSwitching = false
    }

    // MARK: - Registry

    func record(for sha256: String) -> ModelRecord? {
        registry.first { $0.sha256 == sha256 }
    }

    func updateRecord(_ record: ModelRecord) {
        if let idx = registry.firstIndex(where: { $0.sha256 == record.sha256 }) {
            registry[idx] = record
        } else {
            registry.append(record)
        }
        saveRegistry()
    }

    func toggleFavorite(_ sha256: String) {
        guard let idx = registry.firstIndex(where: { $0.sha256 == sha256 }) else { return }
        registry[idx].isFavorite.toggle()
        saveRegistry()
    }

    func addBenchmark(_ benchmark: ModelBenchmark, to sha256: String) {
        guard let idx = registry.firstIndex(where: { $0.sha256 == sha256 }) else { return }
        registry[idx].benchmarks.append(benchmark)
        // Recalcular promedio
        let times = registry[idx].benchmarks.map { $0.genTime }
        registry[idx].avgGenTime = times.reduce(0, +) / Double(times.count)
        saveRegistry()
    }

    private func updateUsage(sha256: String) {
        guard let idx = registry.firstIndex(where: { $0.sha256 == sha256 }) else { return }
        registry[idx].lastUsedAt  = Date()
        registry[idx].usageCount += 1
        saveRegistry()
    }

    // MARK: - Filtered List

    var filteredModels: [SDModelInfo] {
        var list = availableModels
        if filterFavs {
            let favSHA = Set(registry.filter { $0.isFavorite }.map { $0.sha256 })
            list = list.filter { favSHA.contains($0.sha256) }
        }
        if filterPrivate {
            let privSHA = Set(registry.filter { $0.isPrivate }.map { $0.sha256 })
            list = list.filter { privSHA.contains($0.sha256) }
        }
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            list = list.filter { $0.modelName.lowercased().contains(q) }
        }
        return list
    }

    // MARK: - Persistence

    private func saveRegistry() {
        guard let url  = registryURL,
              let data = try? JSONEncoder.pretty.encode(registry) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func loadRegistry() {
        guard let url  = registryURL,
              let data = try? Data(contentsOf: url),
              let recs = try? JSONDecoder.iso8601.decode([ModelRecord].self, from: data)
        else { return }
        registry = recs
    }

    private var registryURL: URL? {
        VaultManager.shared.vaultMetaURL?.appending(path: "models_registry.json")
    }
}

// MARK: - ModelManagerView

struct ModelManagerView: View {

    @ObservedObject var manager  = ModelManager.shared
    @Binding var baseURL:          String
    @State private var editTarget: ModelRecord? = nil
    @State private var expanded    = false

    var body: some View {
        VStack(spacing: 0) {

            // Header colapsable
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } }) {
                HStack(spacing: 8) {
                    Image(systemName: "cpu")
                        .font(.system(size: 11)).foregroundColor(Color(hex: "#f472b6"))
                    Text("Modelos")
                        .font(.system(size: 12, weight: .semibold)).foregroundColor(.white)

                    if !manager.activeModelName.isEmpty {
                        HStack(spacing: 4) {
                            Circle().fill(Color(hex: "#f472b6")).frame(width: 5, height: 5)
                            Text(cleanModelName(manager.activeModelName))
                                .font(.system(size: 10)).foregroundColor(Color(hex: "#f472b6"))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color(hex: "#f472b6").opacity(0.10)).cornerRadius(4)
                    }

                    Spacer()

                    if manager.isSwitching {
                        ProgressView().controlSize(.mini)
                    }

                    Button(action: { Task { await manager.fetchModels(baseURL: baseURL) } }) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 10)).foregroundColor(.secondary)
                    }.buttonStyle(.plain).help("Recargar modelos")

                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9)).foregroundColor(.secondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Color.white.opacity(0.03))
            }
            .buttonStyle(.plain)

            if expanded {
                Divider().background(Color.white.opacity(0.06))

                // Filtros
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundColor(.secondary)
                    TextField("Buscar modelo…", text: $manager.searchText)
                        .textFieldStyle(.plain).font(.system(size: 12)).foregroundColor(.white)
                    Divider().frame(height: 14).background(Color.white.opacity(0.1))
                    Button(action: { manager.filterFavs.toggle() }) {
                        Image(systemName: manager.filterFavs ? "star.fill" : "star")
                            .font(.system(size: 11))
                            .foregroundColor(manager.filterFavs ? .yellow : .secondary)
                    }.buttonStyle(.plain)
                    Button(action: { manager.filterPrivate.toggle() }) {
                        Image(systemName: manager.filterPrivate ? "lock.fill" : "lock")
                            .font(.system(size: 11))
                            .foregroundColor(manager.filterPrivate ? Color(hex: "#f472b6") : .secondary)
                    }.buttonStyle(.plain).help("Solo privados")
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.white.opacity(0.04))

                if manager.isLoading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Cargando modelos…").font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(20)
                } else if manager.filteredModels.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "cpu.fill").font(.system(size: 22))
                            .foregroundColor(.white.opacity(0.08))
                        Text("Sin modelos. Pulsa ↺ para cargar.")
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(20)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(manager.filteredModels) { model in
                                ModelRowView(
                                    model: model,
                                    record: manager.record(for: model.sha256),
                                    isActive: model.title == manager.activeModelName,
                                    onSwitch: { Task { await manager.switchModel(model, baseURL: baseURL) } },
                                    onEdit: {
                                        if let rec = manager.record(for: model.sha256) {
                                            editTarget = rec
                                        } else {
                                            let rec = ModelRecord(sha256: model.sha256, modelName: model.modelName)
                                            editTarget = rec
                                        }
                                    },
                                    onFav: { manager.toggleFavorite(model.sha256) }
                                )
                                Divider().background(Color.white.opacity(0.04))
                            }
                        }
                    }
                    .frame(maxHeight: 220)
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
        .sheet(item: $editTarget) { rec in ModelRecordEditor(record: rec) }
        .task {
            if manager.availableModels.isEmpty {
                await manager.fetchModels(baseURL: baseURL)
            }
        }
    }

    func cleanModelName(_ t: String) -> String {
        // "modelname.safetensors [abc123]" → "modelname"
        t.components(separatedBy: " [").first?
         .components(separatedBy: ".").first ?? t
    }
}

// MARK: - ModelRowView

struct ModelRowView: View {

    let model:    SDModelInfo
    let record:   ModelRecord?
    let isActive: Bool
    var onSwitch: () -> Void
    var onEdit:   () -> Void
    var onFav:    () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            // Indicador activo
            Circle()
                .fill(isActive ? Color(hex: "#f472b6") : Color.white.opacity(0.1))
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.modelName)
                    .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                    .foregroundColor(isActive ? .white : Color.white.opacity(0.75))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let rec = record {
                        if !rec.baseModel.isEmpty {
                            Text(rec.baseModel).font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                        if rec.nsfw {
                            Text("NSFW").font(.system(size: 8, weight: .bold))
                                .foregroundColor(Color(hex: "#f472b6"))
                        }
                        if let avg = rec.avgGenTime {
                            Text("~\(String(format: "%.0f", avg))s")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        if rec.usageCount > 0 {
                            Text("×\(rec.usageCount)")
                                .font(.system(size: 9)).foregroundColor(.secondary.opacity(0.6))
                        }
                    }
                }
            }

            Spacer()

            if hovered || isActive {
                Button(action: onFav) {
                    Image(systemName: record?.isFavorite == true ? "star.fill" : "star")
                        .font(.system(size: 10))
                        .foregroundColor(record?.isFavorite == true ? .yellow : .secondary)
                }.buttonStyle(.plain)

                Button(action: onEdit) {
                    Image(systemName: "pencil").font(.system(size: 10)).foregroundColor(.secondary)
                }.buttonStyle(.plain)
            }

            Button(action: onSwitch) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundColor(isActive ? Color(hex: "#f472b6") : .secondary)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(isActive ? Color(hex: "#f472b6").opacity(0.06) : hovered ? Color.white.opacity(0.03) : .clear)
        .onHover { hovered = $0 }
    }
}

// MARK: - ModelRecordEditor

struct ModelRecordEditor: View {

    @State var record: ModelRecord
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "cpu").font(.system(size: 20)).foregroundColor(Color(hex: "#f472b6"))
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.modelName).font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                    Text("Registry privado · SDPipeline").font(.system(size: 11)).foregroundColor(.secondary)
                }
                Spacer()
                Button("Cancelar") { dismiss() }.buttonStyle(.plain).foregroundColor(.secondary)
                Button("Guardar") { ModelManager.shared.updateRecord(record); dismiss() }
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Color(hex: "#f472b6")).foregroundColor(.black).cornerRadius(6)
                    .buttonStyle(.plain)
            }
            .padding(20).background(Color.white.opacity(0.03))

            Divider().background(Color.white.opacity(0.08))

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    group("Metadatos") {
                        row("Base Model") { TextField("SD 1.5, SDXL, Pony…", text: $record.baseModel).textFieldStyle(.roundedBorder) }
                        row("Licencia URL") { TextField("https://…", text: $record.licenseURL).textFieldStyle(.roundedBorder) }
                        row("Notas") {
                            TextEditor(text: $record.notes).scrollContentBackground(.hidden)
                                .foregroundColor(.white).font(.system(size: 12))
                                .frame(minHeight: 60).padding(8)
                                .background(Color.white.opacity(0.04)).cornerRadius(6)
                        }
                    }
                    group("Flags") {
                        HStack {
                            Text("NSFW").font(.system(size: 12)).foregroundColor(.secondary)
                            Spacer()
                            Toggle("", isOn: $record.nsfw).toggleStyle(.switch).labelsHidden().scaleEffect(0.8)
                        }
                        HStack {
                            Text("Privado (Registry)").font(.system(size: 12)).foregroundColor(.secondary)
                            Spacer()
                            Toggle("", isOn: $record.isPrivate).toggleStyle(.switch).labelsHidden().scaleEffect(0.8)
                        }
                    }
                    group("Trigger Words") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Una por línea").font(.system(size: 10)).foregroundColor(.secondary)
                            TextEditor(text: Binding(
                                get: { record.triggerWords.joined(separator: "\n") },
                                set: { record.triggerWords = $0.split(separator: "\n").map(String.init) }
                            ))
                            .scrollContentBackground(.hidden).foregroundColor(.white)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(minHeight: 50).padding(8)
                            .background(Color.white.opacity(0.04)).cornerRadius(6)
                        }
                    }
                    if !record.benchmarks.isEmpty {
                        group("Benchmarks (\(record.benchmarks.count))") {
                            ForEach(record.benchmarks.suffix(5)) { b in
                                HStack {
                                    Text(b.date, style: .date).font(.system(size: 10)).foregroundColor(.secondary)
                                    Spacer()
                                    Text("\(String(format: "%.1f", b.genTime))s").font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                                    Text("\(b.width)×\(b.height)").font(.system(size: 10)).foregroundColor(.secondary)
                                    HStack(spacing: 2) {
                                        ForEach(1...5, id: \.self) { i in
                                            Image(systemName: i <= b.rating ? "star.fill" : "star")
                                                .font(.system(size: 8)).foregroundColor(i <= b.rating ? .yellow : .secondary.opacity(0.3))
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 500, height: 520)
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
    }

    func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 10, weight: .bold)).foregroundColor(.secondary).tracking(1)
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
