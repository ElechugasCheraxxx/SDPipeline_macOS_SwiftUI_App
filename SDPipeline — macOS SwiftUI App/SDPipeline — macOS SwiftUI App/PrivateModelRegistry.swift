import Foundation
import AppKit
import SwiftUI
import Combine
import CryptoKit

// MARK: - PrivateModelRegistry
//
// Registro privado de modelos con metadatos enriquecidos.
// Complementa ModelManager (que lee de A1111 API) con una capa de metadatos
// PRIVADOS que NUNCA se envían a ningún servidor:
//   - Notas personales por modelo
//   - Benchmarks subjetivos (calidad de piel, hands, faces, composition)
//   - Tags privados para organización
//   - Historial de uso (cuándo y cuánto se ha usado)
//   - "Secretos" del modelo (parámetros óptimos descubiertos empíricamente)
//   - Restricciones de uso definidas por el usuario
//
// Integración con ModelManager:
//   ModelManager provee la lista de modelos desde A1111.
//   PrivateModelRegistry enriquece cada modelo con metadatos locales.
//
// Persistencia: Vault/meta/private_model_registry.json (AES-256 encrypted)
//
// ROADMAP: "Private Model Registry" (🟠 CORTO PLAZO)

@MainActor
final class PrivateModelRegistry: ObservableObject {

    static let shared = PrivateModelRegistry()
    private init() { load() }

    // MARK: - Models

    struct PrivateModelEntry: Codable, Identifiable, Hashable {
        var id:            UUID    = UUID()
        var sha256:        String  // Key — coincide con SDModelInfo.sha256
        var modelName:     String
        var registeredAt:  Date    = Date()
        var updatedAt:     Date    = Date()

        // Private metadata
        var personalNotes:    String   = ""
        var internalTag:      String   = ""    // Ej: "uso-personal-only", "test"
        var userTags:         [String] = []
        var isFavorite:       Bool     = false
        var isHidden:         Bool     = false  // Ocultar de la lista principal
        var useCount:         Int      = 0
        var lastUsedAt:       Date?

        // Benchmarks subjetivos (1–5)
        var benchmarks:       Benchmarks = Benchmarks()

        struct Benchmarks: Codable, Hashable {
            var overall:      Int = 0   // 0 = sin calificar
            var faceQuality:  Int = 0
            var bodyQuality:  Int = 0
            var handsQuality: Int = 0
            var composition:  Int = 0
            var colorGrading: Int = 0
            var promptAdherence: Int = 0
            var generationSpeed: Int = 0  // 1=lento, 5=rápido

            var averageScore: Double {
                let scores = [overall, faceQuality, bodyQuality, handsQuality,
                              composition, colorGrading, promptAdherence].filter { $0 > 0 }
                guard !scores.isEmpty else { return 0 }
                return Double(scores.reduce(0, +)) / Double(scores.count)
            }
        }

        // Parámetros óptimos descubiertos (los "secretos" del modelo)
        var optimalParams:    OptimalParams = OptimalParams()

        struct OptimalParams: Codable, Hashable {
            var bestSampler:   String  = ""
            var bestSteps:     Int     = 0    // 0 = sin configurar
            var bestCFG:       Double  = 0
            var bestClipSkip:  Int     = 1
            var bestVAE:       String  = ""
            var bestNegative:  String  = ""   // Negative prompt óptimo para este modelo
            var hiresUpscaler: String  = ""
            var hiresDenoise:  Double  = 0
            var notes:         String  = ""
        }

        // Restricciones personales
        var restrictions:     Restrictions = Restrictions()

        struct Restrictions: Codable, Hashable {
            var noCommercialUse:    Bool = false
            var restrictedPlatforms: [String] = []
            var contentWarnings:    [String]  = []
        }

        func hash(into hasher: inout Hasher) { hasher.combine(sha256) }
        static func == (l: PrivateModelEntry, r: PrivateModelEntry) -> Bool { l.sha256 == r.sha256 }
    }

    // MARK: - Published State

    @Published private(set) var entries:  [String: PrivateModelEntry] = [:]  // sha256 → entry
    @Published var sortOrder: SortOrder = .lastUsed

    enum SortOrder: String, CaseIterable {
        case lastUsed   = "Último uso"
        case rating     = "Rating"
        case name       = "Nombre"
        case useCount   = "Más usados"
    }

    // MARK: - Entry Access

    func entry(for sha256: String) -> PrivateModelEntry? {
        entries[sha256]
    }

    func entryOrCreate(for model: SDModelInfo) -> PrivateModelEntry {
        if let existing = entries[model.sha256] { return existing }
        let new = PrivateModelEntry(sha256: model.sha256, modelName: model.modelName)
        entries[model.sha256] = new
        return new
    }

    // MARK: - Update

    func save(entry: PrivateModelEntry) throws {
        var e = entry; e.updatedAt = Date()
        entries[e.sha256] = e
        try persist()
    }

    func setBenchmarks(sha256: String, benchmarks: PrivateModelEntry.Benchmarks) throws {
        guard var e = entries[sha256] else { return }
        e.benchmarks = benchmarks
        e.updatedAt  = Date()
        entries[sha256] = e
        try persist()
    }

    func setOptimalParams(sha256: String, params: PrivateModelEntry.OptimalParams) throws {
        guard var e = entries[sha256] else { return }
        e.optimalParams = params
        e.updatedAt     = Date()
        entries[sha256] = e
        try persist()
    }

    func recordUsage(sha256: String) throws {
        guard var e = entries[sha256] else {
            // Auto-create entry si no existe
            if let model = ModelManager.shared.availableModels.first(where: { $0.sha256 == sha256 }) {
                var newEntry = PrivateModelEntry(sha256: sha256, modelName: model.modelName)
                newEntry.useCount  = 1
                newEntry.lastUsedAt = Date()
                entries[sha256] = newEntry
                try persist()
            }
            return
        }
        e.useCount += 1
        e.lastUsedAt = Date()
        e.updatedAt  = Date()
        entries[sha256] = e
        try persist()
    }

    func toggleFavorite(sha256: String) throws {
        guard var e = entries[sha256] else { return }
        e.isFavorite = !e.isFavorite
        entries[sha256] = e
        try persist()
    }

    func toggleHidden(sha256: String) throws {
        guard var e = entries[sha256] else { return }
        e.isHidden = !e.isHidden
        entries[sha256] = e
        try persist()
    }

    // MARK: - Sorted Entries

    func sortedEntries() -> [PrivateModelEntry] {
        let all = Array(entries.values)
        switch sortOrder {
        case .lastUsed:  return all.sorted { ($0.lastUsedAt ?? .distantPast) > ($1.lastUsedAt ?? .distantPast) }
        case .rating:    return all.sorted { $0.benchmarks.averageScore > $1.benchmarks.averageScore }
        case .name:      return all.sorted { $0.modelName < $1.modelName }
        case .useCount:  return all.sorted { $0.useCount > $1.useCount }
        }
    }

    func topModels(limit: Int = 5) -> [PrivateModelEntry] {
        sortedEntries().filter { $0.useCount > 0 }.prefix(limit).map { $0 }
    }

    // MARK: - Compliance Check

    func complianceWarnings(sha256: String, platform: String) -> [String] {
        guard let e = entries[sha256] else { return [] }
        var warnings = [String]()
        if e.restrictions.noCommercialUse {
            warnings.append("⚠️ Modelo marcado como NO COMERCIAL por el usuario.")
        }
        if e.restrictions.restrictedPlatforms.contains(where: {
            $0.lowercased() == platform.lowercased()
        }) {
            warnings.append("⚠️ Modelo restringido explícitamente para \(platform).")
        }
        return warnings
    }

    // MARK: - Persistence

    private var registryURL: URL? {
        VaultManager.shared.vaultRoot?
            .appendingPathComponent("Vault/meta/private_model_registry.json")
    }

    private func persist() throws {
        guard let url = registryURL else { return }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(entries).write(to: url, options: .atomic)
    }

    private func load() {
        guard let url = registryURL, let data = try? Data(contentsOf: url) else { return }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        entries = (try? dec.decode([String: PrivateModelEntry].self, from: data)) ?? [:]
    }
}

// MARK: - Model Registry View

struct PrivateModelRegistryView: View {
    @ObservedObject private var registry  = PrivateModelRegistry.shared
    @ObservedObject private var modelMgr  = ModelManager.shared
    @State private var selectedSHA256:    String?
    @State private var searchText         = ""

    var displayedModels: [SDModelInfo] {
        let all = modelMgr.availableModels
        if searchText.isEmpty { return all }
        return all.filter { model in
            model.modelName.localizedCaseInsensitiveContains(searchText) ||
            (registry.entry(for: model.sha256)?.userTags.contains {
                $0.localizedCaseInsensitiveContains(searchText)
            } ?? false)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left panel — model list
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "lock.doc.fill")
                        .foregroundColor(Color(hex: "#7c6af7"))
                    Text("Registro Privado")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Picker("", selection: $registry.sortOrder) {
                        ForEach(PrivateModelRegistry.SortOrder.allCases, id: \.self) { so in
                            Text(so.rawValue).tag(so)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                }
                .padding(12)

                HStack {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary).font(.system(size: 11))
                    TextField("Buscar modelos…", text: $searchText)
                        .textFieldStyle(.plain).font(.system(size: 12))
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.secondary.opacity(0.08)).cornerRadius(8)
                .padding(.horizontal, 12).padding(.bottom, 8)

                Divider()

                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(displayedModels, id: \.sha256) { model in
                            ModelRegistryRow(
                                model:       model,
                                entry:       registry.entry(for: model.sha256),
                                isSelected:  selectedSHA256 == model.sha256
                            ) {
                                selectedSHA256 = model.sha256
                            }
                        }
                    }
                    .padding(8)
                }
            }
            .frame(width: 260)

            Divider()

            // Right panel — detail
            if let sha256 = selectedSHA256,
               let model = modelMgr.availableModels.first(where: { $0.sha256 == sha256 }) {
                ModelRegistryDetailView(model: model)
            } else {
                Text("Selecciona un modelo para ver y editar sus metadatos privados.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct ModelRegistryRow: View {
    let model:       SDModelInfo
    let entry:       PrivateModelRegistry.PrivateModelEntry?
    let isSelected:  Bool
    let onSelect:    () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Favorite star
            Image(systemName: (entry?.isFavorite == true) ? "star.fill" : "star")
                .font(.system(size: 10))
                .foregroundColor((entry?.isFavorite == true) ? Color(hex: "#fbbf24") : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.modelName)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if let e = entry, e.benchmarks.overall > 0 {
                        HStack(spacing: 2) {
                            ForEach(1...5, id: \.self) { i in
                                Image(systemName: i <= e.benchmarks.overall ? "star.fill" : "star")
                                    .font(.system(size: 8))
                                    .foregroundColor(Color(hex: "#fbbf24"))
                            }
                        }
                    }
                    if let e = entry, e.useCount > 0 {
                        Text("×\(e.useCount)")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        .cornerRadius(6)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .opacity(entry?.isHidden == true ? 0.4 : 1.0)
    }
}

private struct ModelRegistryDetailView: View {
    let model: SDModelInfo
    @ObservedObject private var registry = PrivateModelRegistry.shared
    @State private var entry: PrivateModelRegistry.PrivateModelEntry

    init(model: SDModelInfo) {
        self.model = model
        _entry = State(initialValue: PrivateModelRegistry.shared.entryOrCreate(for: model))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.modelName)
                            .font(.system(size: 15, weight: .bold))
                        Text("SHA256: \(model.sha256.prefix(12))…")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: { try? registry.toggleFavorite(sha256: model.sha256) }) {
                        Image(systemName: entry.isFavorite ? "star.fill" : "star")
                            .font(.system(size: 18))
                            .foregroundColor(entry.isFavorite ? Color(hex: "#fbbf24") : .secondary)
                    }
                    .buttonStyle(.plain)
                }

                // Notes
                VStack(alignment: .leading, spacing: 6) {
                    Text("NOTAS PRIVADAS").font(.system(size: 10, weight: .bold)).foregroundColor(.secondary)
                    TextEditor(text: $entry.personalNotes)
                        .font(.system(size: 12))
                        .frame(minHeight: 80)
                        .padding(8)
                        .background(Color.secondary.opacity(0.06))
                        .cornerRadius(8)
                        .onChange(of: entry.personalNotes) { _ in
                            try? registry.save(entry: entry)
                        }
                }

                // Benchmarks
                VStack(alignment: .leading, spacing: 8) {
                    Text("BENCHMARKS SUBJETIVOS (1–5)")
                        .font(.system(size: 10, weight: .bold)).foregroundColor(.secondary)

                    BenchmarkRow(label: "Overall",          value: $entry.benchmarks.overall)
                    BenchmarkRow(label: "Calidad de Caras", value: $entry.benchmarks.faceQuality)
                    BenchmarkRow(label: "Cuerpo",           value: $entry.benchmarks.bodyQuality)
                    BenchmarkRow(label: "Manos",            value: $entry.benchmarks.handsQuality)
                    BenchmarkRow(label: "Composición",      value: $entry.benchmarks.composition)
                    BenchmarkRow(label: "Color/Grading",    value: $entry.benchmarks.colorGrading)
                }

                // Optimal Params
                VStack(alignment: .leading, spacing: 8) {
                    Text("PARÁMETROS ÓPTIMOS").font(.system(size: 10, weight: .bold)).foregroundColor(.secondary)

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Sampler").font(.system(size: 10)).foregroundColor(.secondary)
                            TextField("Euler a", text: $entry.optimalParams.bestSampler)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11))
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("CFG").font(.system(size: 10)).foregroundColor(.secondary)
                            TextField("7.0", value: $entry.optimalParams.bestCFG, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11))
                                .frame(width: 60)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Steps").font(.system(size: 10)).foregroundColor(.secondary)
                            TextField("28", value: $entry.optimalParams.bestSteps, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11))
                                .frame(width: 60)
                        }
                    }
                }

                // Save
                Button("Guardar cambios") {
                    try? registry.save(entry: entry)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Color(hex: "#7c6af7").opacity(0.2))
                .foregroundColor(Color(hex: "#7c6af7"))
                .cornerRadius(8)
            }
            .padding(20)
        }
        .onAppear {
            entry = registry.entryOrCreate(for: model)
        }
    }
}

private struct BenchmarkRow: View {
    let label: String
    @Binding var value: Int

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 11))
                .frame(width: 120, alignment: .leading)
            HStack(spacing: 4) {
                ForEach(1...5, id: \.self) { i in
                    Button(action: { value = i }) {
                        Image(systemName: i <= value ? "star.fill" : "star")
                            .font(.system(size: 14))
                            .foregroundColor(i <= value ? Color(hex: "#fbbf24") : Color.secondary.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }
            }
            if value == 0 {
                Text("Sin calificar")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
    }
}
