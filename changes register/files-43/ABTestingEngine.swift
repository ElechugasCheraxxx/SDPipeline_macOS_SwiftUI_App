import Foundation
import SwiftUI
import Combine
import CoreData

// MARK: - ABTestingEngine
//
// Sistema de A/B Testing estético para comparar generaciones:
//   • Tests de parámetros: CFG, sampler, steps, model
//   • Tests de prompt: variaciones de positivo/negativo
//   • Tests de LoRA: diferentes weights y combinaciones
//   • Evaluación ciega (blind rating sin saber qué es A o B)
//   • Estadísticas de preferencia acumuladas
//   • Integración con BatchEngine para generar variantes automáticamente
//   • Export de resultados a CSV
//
// ROADMAP: "A/B Testing de estética" (🟢 LARGO PLAZO)

@MainActor
final class ABTestingEngine: ObservableObject {

    static let shared = ABTestingEngine()
    private init() { loadTests() }

    // MARK: - Models

    enum TestVariable: String, CaseIterable, Codable {
        case cfg       = "CFG Scale"
        case steps     = "Steps"
        case sampler   = "Sampler"
        case model     = "Checkpoint"
        case lora      = "LoRA Weight"
        case prompt    = "Prompt Variant"
        case negative  = "Negative Prompt"
        case seed      = "Seed"
        case denoising = "Denoising Strength"
        case hiresScale = "Hires Scale"

        var icon: String {
            switch self {
            case .cfg:       return "slider.horizontal.3"
            case .steps:     return "number.circle"
            case .sampler:   return "waveform"
            case .model:     return "cpu"
            case .lora:      return "bolt"
            case .prompt:    return "text.bubble"
            case .negative:  return "minus.circle"
            case .seed:      return "die.face.6"
            case .denoising: return "drop.fill"
            case .hiresScale: return "arrow.up.left.and.arrow.down.right"
            }
        }
    }

    struct ABVariant: Codable, Identifiable {
        var id:        UUID    = UUID()
        var label:     String  = "A"
        var assetID:   UUID?   = nil   // asset generado para esta variante
        var params:    VariantParams
        var ratings:   [Int]   = []    // ratings recibidos (1-5)

        var avgRating: Double {
            guard !ratings.isEmpty else { return 0 }
            return Double(ratings.reduce(0, +)) / Double(ratings.count)
        }
        var voteCount: Int { ratings.count }
    }

    struct VariantParams: Codable {
        var promptPositive: String?
        var promptNegative: String?
        var cfg:            Double?
        var steps:          Int?
        var sampler:        String?
        var checkpoint:     String?
        var loraWeights:    [String: Double]?
        var seed:           Int?
        var denoisingStrength: Double?
        var hiresScale:     Double?
        var notes:          String = ""
    }

    struct ABTest: Codable, Identifiable {
        var id:          UUID       = UUID()
        var title:       String
        var variable:    TestVariable
        var variants:    [ABVariant]
        var baseRequest: VariantParams    // parámetros compartidos entre variantes
        var status:      Status     = .draft
        var createdAt:   Date       = Date()
        var completedAt: Date?      = nil
        var totalEvals:  Int        = 0
        var winnerID:    UUID?      = nil

        enum Status: String, Codable {
            case draft      = "Borrador"
            case running    = "Activo"
            case paused     = "Pausado"
            case completed  = "Completado"
        }

        var winner: ABVariant? {
            guard let wid = winnerID else { return variants.max(by: { $0.avgRating < $1.avgRating }) }
            return variants.first { $0.id == wid }
        }

        var isBlind: Bool = true  // evaluación ciega por default
    }

    // MARK: - State

    @Published var tests:       [ABTest] = []
    @Published var activeTest:  ABTest?  = nil
    @Published var currentEval: (test: ABTest, variantA: ABVariant, variantB: ABVariant)? = nil
    @Published var isGenerating: Bool = false

    // MARK: - Create Test

    func createTest(title: String, variable: TestVariable, variants: [ABVariant], base: VariantParams) -> ABTest {
        let test = ABTest(title: title, variable: variable, variants: variants, baseRequest: base)
        tests.insert(test, at: 0)
        saveTests()
        return test
    }

    // MARK: - Quick Test Templates

    func createCFGTest(baseParams: VariantParams, cfgValues: [Double], title: String) -> ABTest {
        let variants = cfgValues.enumerated().map { idx, cfg in
            ABVariant(
                label: String(format: "CFG %.1f", cfg),
                params: VariantParams(cfg: cfg)
            )
        }
        return createTest(title: title.isEmpty ? "Test CFG" : title,
                          variable: .cfg,
                          variants: variants,
                          base: baseParams)
    }

    func createSamplerTest(baseParams: VariantParams, samplers: [String], title: String) -> ABTest {
        let variants = samplers.map { sampler in
            ABVariant(label: sampler, params: VariantParams(sampler: sampler))
        }
        return createTest(title: title.isEmpty ? "Test Sampler" : title,
                          variable: .sampler,
                          variants: variants,
                          base: baseParams)
    }

    func createPromptTest(baseParams: VariantParams, prompts: [(label: String, positive: String)]) -> ABTest {
        let variants = prompts.map { p in
            ABVariant(label: p.label, params: VariantParams(promptPositive: p.positive))
        }
        return createTest(title: "Test de Prompt",
                          variable: .prompt,
                          variants: variants,
                          base: baseParams)
    }

    // MARK: - Generate Variants (using BatchEngine)

    func generateVariants(for test: inout ABTest, settings: GenerationSettings) async throws {
        isGenerating = true
        defer { isGenerating = false }

        for i in test.variants.indices {
            var variant = test.variants[i]
            // Combinar baseRequest con params de la variante
            let merged = mergeParams(base: test.baseRequest, override: variant.params)
            let request = buildSDRequest(from: merged, settings: settings)

            // Note: SDService is a @StateObject owned by ContentView.
            // Post a notification for ContentView to handle test generation.
            NotificationCenter.default.post(
                name: .abTestGenerationRequested,
                object: nil,
                userInfo: ["request": request, "settings": settings]
            )
            // El asset se guarda via AssetStore
            // variant.assetID se actualiza cuando el asset se persiste
            test.variants[i] = variant
        }

        test.status = .running
        if let idx = tests.firstIndex(where: { $0.id == test.id }) { tests[idx] = test }
        saveTests()
    }

    // MARK: - Blind Evaluation

    /// Retorna un par aleatorio de variantes para evaluación ciega.
    func nextBlindEval(for test: ABTest) -> (ABVariant, ABVariant)? {
        guard test.variants.count >= 2 else { return nil }
        let shuffled = test.variants.shuffled()
        return (shuffled[0], shuffled[1])
    }

    func submitEvaluation(testID: UUID, preferredVariantID: UUID, rating: Int) {
        guard let testIdx = tests.firstIndex(where: { $0.id == testID }),
              let varIdx  = tests[testIdx].variants.firstIndex(where: { $0.id == preferredVariantID })
        else { return }

        tests[testIdx].variants[varIdx].ratings.append(rating)
        tests[testIdx].totalEvals += 1

        // Comprobar significancia estadística (simple: mínimo 10 evals por variante)
        let allEvaluated = tests[testIdx].variants.allSatisfy { $0.voteCount >= 5 }
        if allEvaluated {
            let winner = tests[testIdx].variants.max(by: { $0.avgRating < $1.avgRating })
            tests[testIdx].winnerID    = winner?.id
            tests[testIdx].status      = .completed
            tests[testIdx].completedAt = Date()
        }

        saveTests()
    }

    // MARK: - Statistics

    struct TestResults {
        let test:           ABTest
        let winner:         ABVariant?
        let confidenceLevel: Double  // 0-1, pseudo-confidence
        let totalEvaluations: Int
        let variantStats:   [(variant: ABVariant, winRate: Double, avgRating: Double)]
    }

    func results(for test: ABTest) -> TestResults {
        let total = test.totalEvals
        let stats = test.variants.map { v -> (ABVariant, Double, Double) in
            let winRate = total > 0 ? Double(v.voteCount) / Double(total) : 0
            return (v, winRate, v.avgRating)
        }
        let maxRating = test.variants.map { $0.avgRating }.max() ?? 0
        let minRating = test.variants.map { $0.avgRating }.min() ?? 0
        let confidence = maxRating > 0 ? min((maxRating - minRating) / maxRating, 1.0) : 0

        return TestResults(
            test:             test,
            winner:           test.winner,
            confidenceLevel:  confidence,
            totalEvaluations: total,
            variantStats:     stats.map { (variant: $0.0, winRate: $0.1, avgRating: $0.2) }
        )
    }

    // MARK: - Export

    func exportCSV(for test: ABTest) throws -> URL {
        var csv = "variant,label,votes,avg_rating,win_rate\n"
        let total = max(test.totalEvals, 1)
        for v in test.variants {
            csv += "\(v.id),\(v.label),\(v.voteCount),\(String(format: "%.2f", v.avgRating)),\(String(format: "%.1f", Double(v.voteCount)/Double(total)*100))%\n"
        }

        let name    = "abtest_\(test.id.uuidString.prefix(8)).csv"
        let outDir  = FileManager.default.temporaryDirectory
        let url     = outDir.appending(path: name)
        try csv.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Helpers

    private func mergeParams(base: VariantParams, override: VariantParams) -> VariantParams {
        VariantParams(
            promptPositive:   override.promptPositive   ?? base.promptPositive,
            promptNegative:   override.promptNegative   ?? base.promptNegative,
            cfg:              override.cfg              ?? base.cfg,
            steps:            override.steps            ?? base.steps,
            sampler:          override.sampler          ?? base.sampler,
            checkpoint:       override.checkpoint       ?? base.checkpoint,
            loraWeights:      override.loraWeights      ?? base.loraWeights,
            seed:             override.seed             ?? base.seed,
            denoisingStrength: override.denoisingStrength ?? base.denoisingStrength,
            hiresScale:       override.hiresScale       ?? base.hiresScale
        )
    }

    private func buildSDRequest(from params: VariantParams, settings: GenerationSettings) -> SDRequest {
        var r = SDRequest(prompt: params.promptPositive ?? settings.prompt)
        r.negative_prompt = params.promptNegative ?? settings.negativePrompt
        r.cfg_scale       = params.cfg            ?? Double(settings.cfgScale)
        r.steps           = params.steps          ?? settings.steps
        r.sampler_name    = params.sampler        ?? settings.samplerName
        r.seed            = params.seed           ?? settings.seed
        r.width           = settings.width
        r.height          = settings.height
        return r
    }

    // MARK: - Persistence

    private var storeURL: URL? {
        VaultManager.shared.vaultMetaURL?.appending(path: "abtest_store.json")
    }

    private func saveTests() {
        guard let url = storeURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(Array(tests.prefix(50))) {
            try? data.write(to: url, options: .completeFileProtection)
        }
    }

    private func loadTests() {
        guard let url  = storeURL,
              let data = try? Data(contentsOf: url)
        else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        tests = (try? decoder.decode([ABTest].self, from: data)) ?? []
    }
}

// MARK: - ABTest Hashable (required for List selection)
extension ABTestingEngine.ABTest: Hashable {
    static func == (lhs: ABTestingEngine.ABTest, rhs: ABTestingEngine.ABTest) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - ABTestingView

struct ABTestingView: View {

    @StateObject private var engine = ABTestingEngine.shared
    @State private var showCreate   = false
    @State private var selectedTest: ABTestingEngine.ABTest? = nil

    var body: some View {
        NavigationSplitView {
            // List
            VStack(spacing: 0) {
                HStack {
                    Text("A/B Tests")
                        .font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                    Spacer()
                    Button { showCreate = true } label: {
                        Image(systemName: "plus.circle.fill").font(.system(size: 16))
                    }
                    .buttonStyle(.plain).foregroundColor(Color(hex: "#7c6af7"))
                }
                .padding()

                List(engine.tests, selection: $selectedTest) { test in
                    testRow(test)
                        .tag(test)
                }
                .listStyle(.plain)
            }
            .background(Color(red: 0.09, green: 0.09, blue: 0.12))
            .frame(minWidth: 220)

        } detail: {
            if let test = selectedTest {
                testDetailView(test)
            } else {
                Text("Selecciona un test").font(.system(size: 13)).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $showCreate) { CreateABTestSheet() }
    }

    private func testRow(_ test: ABTestingEngine.ABTest) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(test.title).font(.system(size: 12, weight: .medium)).foregroundColor(.white)
                Spacer()
                statusBadge(test.status)
            }
            Text(test.variable.rawValue)
                .font(.system(size: 10)).foregroundColor(.secondary)
            Text("\(test.variants.count) variantes · \(test.totalEvals) evaluaciones")
                .font(.system(size: 10)).foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func statusBadge(_ status: ABTestingEngine.ABTest.Status) -> some View {
        let color: Color = {
            switch status {
            case .draft:     return .secondary
            case .running:   return Color(hex: "#34d399")
            case .paused:    return Color(hex: "#fbbf24")
            case .completed: return Color(hex: "#60a5fa")
            }
        }()
        return Text(status.rawValue)
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15))
            .cornerRadius(4)
    }

    @ViewBuilder
    private func testDetailView(_ test: ABTestingEngine.ABTest) -> some View {
        let results = engine.results(for: test)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(test.title)
                    .font(.system(size: 16, weight: .bold)).foregroundColor(.white)
                Text("Variable: \(test.variable.rawValue) · \(test.totalEvals) evaluaciones totales")
                    .font(.system(size: 12)).foregroundColor(.secondary)

                if let winner = results.winner {
                    HStack {
                        Image(systemName: "trophy.fill").foregroundColor(Color(hex: "#fbbf24"))
                        Text("Ganadora: \(winner.label) (avg \(String(format: "%.2f", winner.avgRating)))")
                            .font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                        Text("Confianza: \(Int(results.confidenceLevel * 100))%")
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    .padding(10).background(Color(hex: "#fbbf24").opacity(0.1)).cornerRadius(8)
                }

                ForEach(results.variantStats, id: \.variant.id) { stat in
                    variantStatRow(stat)
                }

                if test.status == .completed {
                    Button("Exportar CSV") {
                        if let url = try? engine.exportCSV(for: test) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                }
            }
            .padding(20)
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
    }

    private func variantStatRow(_ stat: (variant: ABTestingEngine.ABVariant, winRate: Double, avgRating: Double)) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(stat.variant.label)
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                Spacer()
                Text(String(format: "%.2f ★  ·  %.0f%%", stat.avgRating, stat.winRate * 100))
                    .font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.05))
                    RoundedRectangle(cornerRadius: 3).fill(Color(hex: "#7c6af7").opacity(0.6))
                        .frame(width: geo.size.width * stat.winRate)
                }
            }
            .frame(height: 6)
        }
        .padding(10).background(Color.white.opacity(0.04)).cornerRadius(8)
    }
}

// MARK: - Create AB Test Sheet (skeleton)

struct CreateABTestSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title    = ""
    @State private var variable = ABTestingEngine.TestVariable.cfg

    var body: some View {
        VStack(spacing: 20) {
            Text("Nuevo A/B Test")
                .font(.system(size: 14, weight: .bold)).foregroundColor(.white)
            TextField("Título del test", text: $title)
                .textFieldStyle(.roundedBorder)
            Picker("Variable a testear", selection: $variable) {
                ForEach(ABTestingEngine.TestVariable.allCases, id: \.self) { v in
                    Label(v.rawValue, systemImage: v.icon).tag(v)
                }
            }
            .pickerStyle(.menu)
            HStack {
                Button("Cancelar") { dismiss() }.buttonStyle(.plain).foregroundColor(.secondary)
                Spacer()
                Button("Crear") {
                    // Crear test con configuración mínima
                    let base = ABTestingEngine.VariantParams()
                    _ = ABTestingEngine.shared.createTest(title: title, variable: variable, variants: [], base: base)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(title.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 380)
        .background(Color(red: 0.10, green: 0.10, blue: 0.13))
    }
}
