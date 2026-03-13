import Foundation
import AppKit
import SwiftUI
import Combine

// MARK: - LoRAEncapsulationEngine
//
// Motor de encapsulamiento dinámico de pesos LoRA.
// Gestiona "capsules" — combinaciones nombradas de LoRAs con pesos calibrados
// que se aplican como una unidad a personajes, escenas o estilos.
//
// Problema que resuelve:
//   Tener 15+ LoRAs y calibrar manualmente los pesos para cada prompt es
//   tedioso y no reproducible. Las cápsulas encapsulan la "receta" óptima
//   para un resultado consistente.
//
// Conceptos:
//   LoRACapsule — un preset nombrado de LoRAs + pesos + trigger words
//   EncapsulationProfile — cómo los pesos escalan según parámetros del job
//   WeightBlending — mezcla de cápsulas para transiciones estilísticas
//
// Integración:
//   CharacterEngine → capsule de personaje (identity LoRAs)
//   SceneEngine     → capsule de estilo (lighting, environment LoRAs)
//   JobQueueManager → aplica capsule antes de enviar a SDRequest
//
// Persistencia: Vault/meta/lora_capsules.json
//
// ROADMAP: "Encapsulamiento dinámico de pesos LoRA" (🟡 MEDIO PLAZO)

@MainActor
final class LoRAEncapsulationEngine: ObservableObject {

    static let shared = LoRAEncapsulationEngine()
    private init() { load() }

    // MARK: - Models

    struct LoRAWeight: Codable, Identifiable, Hashable {
        var id:        UUID    = UUID()
        var loraName:  String            // A1111 key (sin extensión)
        var weight:    Double = 0.7      // 0.0 – 1.5
        var clipSkip:  Int?              // Override clip skip para este LoRA
        var notes:     String?           // "Face LoRA", "Style enhancer", etc.

        // Peso final después del blending
        var effectiveWeight: Double { weight }

        // Sintaxis A1111: <lora:nombre:peso>
        var a1111Token: String { "<lora:\(loraName):\(String(format: "%.2f", weight))>" }

        func hash(into hasher: inout Hasher) { hasher.combine(id) }
        static func == (l: LoRAWeight, r: LoRAWeight) -> Bool { l.id == r.id }
    }

    struct LoRACapsule: Codable, Identifiable, Hashable {
        var id:              UUID    = UUID()
        var name:            String
        var description:     String  = ""
        var category:        CapsuleCategory
        var tags:            [String] = []
        var isFavorite:      Bool     = false
        var createdAt:       Date     = Date()
        var updatedAt:       Date     = Date()

        // LoRAs en esta cápsula
        var loraWeights:     [LoRAWeight] = []

        // Trigger words que DEBEN añadirse al prompt cuando se activa esta cápsula
        var triggerWords:    [String]  = []

        // Negative trigger words (palabras a EVITAR cuando se usa esta cápsula)
        var antiTriggers:    [String]  = []

        // Parámetros de generación recomendados con esta cápsula
        var recommendedSteps: Int?
        var recommendedCFG:  Double?
        var recommendedSampler: String?

        // Escala dinámica: cómo el peso total escala con la intensidad
        var intensityMode:   IntensityMode  = .fixed

        enum CapsuleCategory: String, Codable, CaseIterable {
            case character    = "Personaje"
            case style        = "Estilo"
            case lighting     = "Iluminación"
            case environment  = "Ambiente"
            case clothing     = "Vestuario"
            case enhancement  = "Mejora"
            case experimental = "Experimental"
        }

        enum IntensityMode: String, Codable, CaseIterable {
            case fixed    = "Fijo"        // Los pesos no cambian con intensidad
            case linear   = "Lineal"      // Escalan linealmente con intensidad (0–1)
            case sigmoid  = "Sigmoide"    // Curva suave (S-curve)
        }

        func hash(into hasher: inout Hasher) { hasher.combine(id) }
        static func == (l: LoRACapsule, r: LoRACapsule) -> Bool { l.id == r.id }

        // Generar tokens A1111 para todos los LoRAs de la cápsula
        func a1111Tokens(intensity: Double = 1.0) -> String {
            loraWeights.map { lw in
                let w: Double
                switch intensityMode {
                case .fixed:   w = lw.weight
                case .linear:  w = lw.weight * intensity
                case .sigmoid: w = lw.weight * (1 / (1 + exp(-10 * (intensity - 0.5))))
                }
                return "<lora:\(lw.loraName):\(String(format: "%.2f", min(1.5, max(0, w))))>"
            }.joined(separator: " ")
        }

        // Trigger words como string
        var triggerWordsString: String { triggerWords.joined(separator: ", ") }
    }

    // MARK: - Blending

    struct CapsuleBlend: Codable, Identifiable {
        var id:         UUID   = UUID()
        var name:       String
        var components: [BlendComponent]
        var createdAt:  Date = Date()

        struct BlendComponent: Codable {
            var capsuleID: UUID
            var blendWeight: Double    // Qué tanto de esta cápsula (0–1)
        }

        // Generar tokens combinando las cápsulas según blendWeight
        func resolve(using capsules: [LoRACapsule]) -> String {
            components.compactMap { comp in
                guard let capsule = capsules.first(where: { $0.id == comp.capsuleID }) else { return nil }
                return capsule.a1111Tokens(intensity: comp.blendWeight)
            }.joined(separator: " ")
        }
    }

    // MARK: - Published State

    @Published private(set) var capsules: [LoRACapsule] = []
    @Published private(set) var blends:   [CapsuleBlend] = []
    @Published var isLoaded = false

    // MARK: - CRUD Capsules

    func addCapsule(_ capsule: LoRACapsule) throws {
        var c = capsule; c.updatedAt = Date()
        capsules.append(c)
        try save()
    }

    func updateCapsule(_ capsule: LoRACapsule) throws {
        guard let idx = capsules.firstIndex(where: { $0.id == capsule.id }) else { return }
        var c = capsule; c.updatedAt = Date()
        capsules[idx] = c
        try save()
    }

    func deleteCapsule(id: UUID) throws {
        capsules.removeAll { $0.id == id }
        blends = blends.map { blend in
            var b = blend
            b.components.removeAll { $0.capsuleID == id }
            return b
        }
        try save()
    }

    func toggleFavorite(id: UUID) throws {
        guard let idx = capsules.firstIndex(where: { $0.id == id }) else { return }
        capsules[idx].isFavorite.toggle()
        try save()
    }

    // MARK: - Blending

    func createBlend(name: String, components: [CapsuleBlend.BlendComponent]) throws -> CapsuleBlend {
        let blend = CapsuleBlend(name: name, components: components)
        blends.append(blend)
        try save()
        return blend
    }

    func resolveBlend(id: UUID, intensity: Double = 1.0) -> String {
        guard let blend = blends.first(where: { $0.id == id }) else { return "" }
        return blend.resolve(using: capsules)
    }

    // MARK: - Apply to Prompt

    struct ResolvedPrompt {
        let positiveWithLoRAs: String       // Prompt + LoRA tokens + trigger words
        let negative:          String       // Negative original (sin cambios)
        let loraTokens:        String       // Solo los tokens <lora:...>
        let triggerWords:      [String]
        let capsuleNames:      [String]
    }

    func applyCapsulesTo(
        prompt: String,
        negative: String,
        capsuleIDs: [UUID],
        intensity: Double = 1.0
    ) -> ResolvedPrompt {
        let activeCapsules = capsuleIDs.compactMap { id in
            capsules.first { $0.id == id }
        }

        let loraTokens   = activeCapsules.map { $0.a1111Tokens(intensity: intensity) }.joined(separator: " ")
        let triggerWords = activeCapsules.flatMap { $0.triggerWords }
        let antiTriggers = Set(activeCapsules.flatMap { $0.antiTriggers })

        // Combinar prompt + trigger words + LoRA tokens
        var positiveTokens = [String]()
        if !prompt.isEmpty         { positiveTokens.append(prompt) }
        if !triggerWords.isEmpty   { positiveTokens.append(triggerWords.joined(separator: ", ")) }
        if !loraTokens.isEmpty     { positiveTokens.append(loraTokens) }

        let finalPositive = positiveTokens.joined(separator: ", ")

        // Añadir anti-triggers al negativo si no están ya
        var negParts = [negative]
        let extraNeg = antiTriggers.filter { term in
            !negative.lowercased().contains(term.lowercased())
        }
        if !extraNeg.isEmpty { negParts.append(extraNeg.joined(separator: ", ")) }

        return ResolvedPrompt(
            positiveWithLoRAs: finalPositive,
            negative:          negParts.filter { !$0.isEmpty }.joined(separator: ", "),
            loraTokens:        loraTokens,
            triggerWords:      triggerWords,
            capsuleNames:      activeCapsules.map { $0.name }
        )
    }

    // MARK: - Auto-detect LoRAs

    /// Analiza un prompt para detectar LoRAs existentes ya incrustados.
    func extractLoRATokens(from prompt: String) -> [LoRAWeight] {
        let pattern = #"<lora:([^:>]+):([0-9.]+)>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range   = NSRange(prompt.startIndex..., in: prompt)
        let matches = regex.matches(in: prompt, range: range)

        return matches.compactMap { match -> LoRAWeight? in
            guard let nameRange   = Range(match.range(at: 1), in: prompt),
                  let weightRange = Range(match.range(at: 2), in: prompt),
                  let weight = Double(prompt[weightRange])
            else { return nil }
            return LoRAWeight(loraName: String(prompt[nameRange]), weight: weight)
        }
    }

    /// Crear una cápsula desde un prompt existente (reverse engineering).
    func capsuleFromPrompt(
        _ prompt: String,
        name: String,
        category: LoRACapsule.CapsuleCategory = .style
    ) -> LoRACapsule {
        let loraWeights = extractLoRATokens(from: prompt)
        return LoRACapsule(
            name:        name,
            category:    category,
            loraWeights: loraWeights
        )
    }

    // MARK: - Quick Create from LoRAManager

    func createFromAvailableLoras(named name: String) -> LoRACapsule {
        // Crear cápsula con todos los LoRAs actualmente cargados en A1111
        // CORRECCIÓN: Se cambió `loras` por `availableLoRAs`
        let weights = LoRAManager.shared.availableLoRAs.map { lora in
            LoRAWeight(loraName: lora.name, weight: 0.7)
        }
        return LoRACapsule(
            name:        name,
            category:    .style,
            loraWeights: weights
        )
    }

    // MARK: - Persistence

    private var capsulesURL: URL? {
        VaultManager.shared.vaultMetaURL?.appending(path: "lora_capsules.json")
    }

    private func save() throws {
        guard let url = capsulesURL else { return }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        struct SavedData: Codable { var capsules: [LoRACapsule]; var blends: [CapsuleBlend] }
        try enc.encode(SavedData(capsules: capsules, blends: blends)).write(to: url, options: .atomic)
    }

    private func load() {
        guard let url = capsulesURL, let data = try? Data(contentsOf: url) else {
            isLoaded = true; return
        }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        struct SavedData: Codable { var capsules: [LoRACapsule]; var blends: [CapsuleBlend] }
        if let saved = try? dec.decode(SavedData.self, from: data) {
            capsules = saved.capsules
            blends   = saved.blends
        }
        isLoaded = true
    }
}

// MARK: - Capsule Manager View

struct LoRACapsuleManagerView: View {
    @ObservedObject private var engine = LoRAEncapsulationEngine.shared
    @State private var selectedCategory: LoRAEncapsulationEngine.LoRACapsule.CapsuleCategory? = nil
    @State private var showCreateSheet = false
    @State private var searchText = ""

    var filteredCapsules: [LoRAEncapsulationEngine.LoRACapsule] {
        var result = engine.capsules
        if let cat = selectedCategory { result = result.filter { $0.category == cat } }
        if !searchText.isEmpty {
            result = result.filter {
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                $0.tags.contains { $0.localizedCaseInsensitiveContains(searchText) }
            }
        }
        return result.sorted { $0.isFavorite && !$1.isFavorite }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "capsule.fill")
                    .foregroundColor(Color(hex: "#7c6af7"))
                Text("Cápsulas LoRA")
                    .font(.system(size: 13, weight: .semibold))
                Text("(\(engine.capsules.count))")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: { showCreateSheet = true }) {
                    Image(systemName: "plus")
                        .font(.system(size: 12))
                        .padding(6)
                        .background(Color(hex: "#7c6af7").opacity(0.2))
                        .cornerRadius(6)
                        .foregroundColor(Color(hex: "#7c6af7"))
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            Divider()

            // Search + Category filter
            VStack(spacing: 8) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                    TextField("Buscar cápsulas…", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(8)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        CategoryChip(label: "Todas", isSelected: selectedCategory == nil) {
                            selectedCategory = nil
                        }
                        ForEach(LoRAEncapsulationEngine.LoRACapsule.CapsuleCategory.allCases, id: \.self) { cat in
                            CategoryChip(label: cat.rawValue, isSelected: selectedCategory == cat) {
                                selectedCategory = selectedCategory == cat ? nil : cat
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            // Capsule list
            if filteredCapsules.isEmpty {
                Text("Sin cápsulas. Crea tu primera cápsula LoRA.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(filteredCapsules) { capsule in
                            CapsuleRow(capsule: capsule)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
            }
        }
    }
}

private struct CapsuleRow: View {
    let capsule: LoRAEncapsulationEngine.LoRACapsule
    @ObservedObject private var engine = LoRAEncapsulationEngine.shared

    var body: some View {
        HStack(spacing: 10) {
            Button(action: { try? engine.toggleFavorite(id: capsule.id) }) {
                Image(systemName: capsule.isFavorite ? "star.fill" : "star")
                    .font(.system(size: 12))
                    .foregroundColor(capsule.isFavorite ? Color(hex: "#fbbf24") : .secondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(capsule.name)
                        .font(.system(size: 12, weight: .semibold))
                    Text(capsule.category.rawValue)
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color(hex: "#7c6af7").opacity(0.15))
                        .foregroundColor(Color(hex: "#7c6af7"))
                        .cornerRadius(4)
                }

                HStack(spacing: 8) {
                    Text("\(capsule.loraWeights.count) LoRAs")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    if !capsule.triggerWords.isEmpty {
                        Text("· \(capsule.triggerWords.prefix(2).joined(separator: ", "))")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer()

            // Copy tokens button
            Button(action: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    capsule.a1111Tokens(), forType: .string
                )
            }) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Copiar tokens LoRA")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.04))
        .cornerRadius(8)
    }
}

private struct CategoryChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isSelected
                    ? Color(hex: "#7c6af7").opacity(0.2)
                    : Color.secondary.opacity(0.08))
                .foregroundColor(isSelected ? Color(hex: "#7c6af7") : .secondary)
                .cornerRadius(20)
        }
        .buttonStyle(.plain)
    }
}
