import Foundation
import AppKit
import SwiftUI
import Combine

// MARK: - BatchEngine
//
// Procesa múltiples jobs txt2img en cola secuencial.
// Cada job puede tener prompt/seed/settings independientes.
// Resultado: grid de imágenes con metadatos, guardado en vault.
//
// Modos:
//   .promptVariations  — mismo seed, prompts distintos
//   .seedVariations    — mismo prompt, seeds distintos
//   .fullMatrix        — N prompts × M seeds (N×M imágenes)
//   .manual            — lista de jobs completamente independientes

// MARK: - Models

enum BatchMode: String, Codable, CaseIterable {
    case promptVariations = "Variaciones de Prompt"
    case seedVariations   = "Variaciones de Seed"
    case fullMatrix       = "Matriz Completa"
    case manual           = "Manual"

    var icon: String {
        switch self {
        case .promptVariations: return "text.alignleft"
        case .seedVariations:   return "number.square"
        case .fullMatrix:       return "grid"
        case .manual:           return "list.bullet"
        }
    }
}

struct BatchItem: Identifiable, Codable {
    var id:             UUID    = UUID()
    var prompt:         String
    var negativePrompt: String  = ""
    var seed:           Int     = -1
    var steps:          Int     = 20
    var cfgScale:       Double  = 7.0
    var width:          Int     = 512
    var height:         Int     = 768
    var samplerName:    String  = "DPM++ 2M Karras"
    var checkpoint:     String  = ""
    var label:          String  = ""     // etiqueta opcional para la celda del grid
}

struct BatchResult: Identifiable, Codable {
    var id:         UUID    = UUID()
    var itemID:     UUID
    var image:      Data?   = nil        // PNG en memoria para el grid
    var savedPath:  String? = nil
    var resultSeed: Int?    = nil
    var duration:   Double  = 0
    var error:      String? = nil
    var status:     Status  = .pending

    enum Status: String, Codable { case pending, running, success, failed }
}

struct BatchJob: Identifiable, Codable {
    var id:         UUID        = UUID()
    var createdAt:  Date        = Date()
    var mode:       BatchMode
    var items:      [BatchItem]
    var results:    [BatchResult] = []
    var baseURL:    String
    var label:      String      = ""
    var status:     Status      = .pending
    var totalDone:  Int         = 0

    enum Status: String, Codable { case pending, running, done, cancelled }

    var totalCount:    Int { items.count }
    var successCount:  Int { results.filter { $0.status == .success }.count }
    var failedCount:   Int { results.filter { $0.status == .failed  }.count }
    var progress:      Double {
        guard totalCount > 0 else { return 0 }
        return Double(totalDone) / Double(totalCount)
    }
}

// MARK: - BatchEngine

@MainActor
final class BatchEngine: ObservableObject {

    static let shared = BatchEngine()
    private init() { loadHistory() }

    // MARK: - State

    @Published var isRunning:      Bool         = false
    @Published var currentJob:     BatchJob?    = nil
    @Published var currentIndex:   Int          = 0
    @Published var progressText:   String       = ""
    @Published var gridImages:     [UUID: NSImage] = [:]    // itemID → imagen
    @Published var jobHistory:     [BatchJob]   = []
    @Published var errorMessage:   String?      = nil

    private var cancelRequested = false

    // MARK: - Public API

    /// Construir job desde variaciones de prompt
    func makePromptVariationsJob(
        prompts:   [String],
        negative:  String,
        seed:      Int    = -1,
        steps:     Int    = 20,
        cfg:       Double = 7.0,
        width:     Int    = 512,
        height:    Int    = 768,
        sampler:   String = "DPM++ 2M Karras",
        baseURL:   String
    ) -> BatchJob {
        let items = prompts.enumerated().map { i, p in
            BatchItem(prompt: p, negativePrompt: negative, seed: seed,
                     steps: steps, cfgScale: cfg, width: width, height: height,
                     samplerName: sampler, label: "Prompt \(i+1)")
        }
        return BatchJob(mode: .promptVariations, items: items, baseURL: baseURL,
                       label: "Variaciones × \(prompts.count)")
    }

    /// Construir job desde variaciones de seed
    func makeSeedVariationsJob(
        prompt:    String,
        negative:  String,
        seeds:     [Int],
        steps:     Int    = 20,
        cfg:       Double = 7.0,
        width:     Int    = 512,
        height:    Int    = 768,
        sampler:   String = "DPM++ 2M Karras",
        baseURL:   String
    ) -> BatchJob {
        let items = seeds.map { seed in
            BatchItem(prompt: prompt, negativePrompt: negative, seed: seed,
                     steps: steps, cfgScale: cfg, width: width, height: height,
                     samplerName: sampler, label: "Seed \(seed)")
        }
        return BatchJob(mode: .seedVariations, items: items, baseURL: baseURL,
                       label: "Seeds × \(seeds.count)")
    }

    /// Construir matriz completa (prompts × seeds)
    func makeMatrixJob(
        prompts:   [String],
        negative:  String,
        seeds:     [Int],
        steps:     Int    = 20,
        cfg:       Double = 7.0,
        width:     Int    = 512,
        height:    Int    = 768,
        sampler:   String = "DPM++ 2M Karras",
        baseURL:   String
    ) -> BatchJob {
        var items: [BatchItem] = []
        for (pi, prompt) in prompts.enumerated() {
            for (si, seed) in seeds.enumerated() {
                items.append(BatchItem(
                    prompt: prompt, negativePrompt: negative, seed: seed,
                    steps: steps, cfgScale: cfg, width: width, height: height,
                    samplerName: sampler, label: "P\(pi+1)·S\(si+1)"
                ))
            }
        }
        return BatchJob(mode: .fullMatrix, items: items, baseURL: baseURL,
                       label: "\(prompts.count)×\(seeds.count) Matriz")
    }

    /// Ejecutar un job
    func run(_ job: BatchJob) async {
        guard !isRunning else { return }
        isRunning      = true
        cancelRequested = false
        errorMessage   = nil
        gridImages     = [:]
        currentIndex   = 0

        var activeJob  = job
        activeJob.status  = .running
        activeJob.results = job.items.map { BatchResult(itemID: $0.id) }
        currentJob     = activeJob

        for (index, item) in activeJob.items.enumerated() {
            if cancelRequested { break }

            currentIndex = index
            progressText = "[\(index+1)/\(activeJob.items.count)] \(item.label.isEmpty ? "Generando…" : item.label)"

            // Marcar como running
            activeJob.results[index].status = .running
            currentJob = activeJob

            let start = Date()
            do {
                let (image, seed) = try await generateSingle(item: item, baseURL: activeJob.baseURL)

                // Guardar en vault
                let savedPath = await saveToVault(image: image, item: item, seed: seed)

                // Actualizar resultado
                activeJob.results[index].status    = .success
                activeJob.results[index].resultSeed = seed
                activeJob.results[index].savedPath  = savedPath
                activeJob.results[index].duration   = Date().timeIntervalSince(start)
                activeJob.results[index].image      = image.pngData()

                // Grid
                gridImages[item.id] = image

                // Registrar seed
                if let s = seed, s > 0 {
                    SeedManager.shared.recordUsage(
                        seed: s,
                        promptHint: String(item.prompt.prefix(50)),
                        width: item.width, height: item.height
                    )
                }

            } catch {
                activeJob.results[index].status   = .failed
                activeJob.results[index].error    = error.localizedDescription
                activeJob.results[index].duration = Date().timeIntervalSince(start)
            }

            activeJob.totalDone = index + 1
            currentJob = activeJob
        }

        activeJob.status = cancelRequested ? .cancelled : .done
        currentJob = activeJob
        addToHistory(activeJob)
        isRunning = false
        progressText = cancelRequested
            ? "Cancelado (\(activeJob.successCount)/\(activeJob.totalCount))"
            : "Completado ✓ \(activeJob.successCount)/\(activeJob.totalCount)"
    }

    func cancel() { cancelRequested = true }

    // MARK: - Private

    private func generateSingle(item: BatchItem, baseURL: String) async throws -> (NSImage, Int?) {
        let payload: [String: Any] = [
            "prompt":           item.prompt,
            "negative_prompt":  item.negativePrompt,
            "seed":             item.seed,
            "steps":            item.steps,
            "cfg_scale":        item.cfgScale,
            "width":            item.width,
            "height":           item.height,
            "sampler_name":     item.samplerName,
            "send_images":      true,
            "save_images":      false
        ]

        let url    = URL(string: "\(baseURL)/sdapi/v1/txt2img")!
        var req    = URLRequest(url: url, timeoutInterval: 300)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody  = try JSONSerialization.data(withJSONObject: payload)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw BatchError.badResponse
        }
        guard let json    = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let images   = json["images"] as? [String],
              let b64      = images.first,
              let imgData  = Data(base64Encoded: b64),
              let nsImage  = NSImage(data: imgData)
        else { throw BatchError.noImage }

        var resultSeed: Int? = nil
        if let infoStr = json["info"] as? String,
           let infoData = infoStr.data(using: .utf8),
           let infoJSON = try? JSONSerialization.jsonObject(with: infoData) as? [String: Any],
           let s        = infoJSON["seed"] as? Int {
            resultSeed = s
        }
        return (nsImage, resultSeed)
    }

    private func saveToVault(image: NSImage, item: BatchItem, seed: Int?) async -> String? {
        guard let dir = VaultManager.shared.generacionesURL else { return nil }
        let subdir  = dir.appending(path: "batch")
        try? FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        let filename = "batch_\(Int(Date().timeIntervalSince1970))_\(UUID().uuidString.prefix(6)).png"
        let fileURL  = subdir.appending(path: filename)
        guard let tiff = image.tiffRepresentation,
              let bmp  = NSBitmapImageRep(data: tiff),
              let png  = bmp.representation(using: .png, properties: [:]) else { return nil }
        try? png.write(to: fileURL, options: .atomic)

        // Sidecar
        let sidecar: [String: Any] = [
            "type": "batch", "prompt": item.prompt,
            "negative": item.negativePrompt, "seed": seed ?? -1,
            "steps": item.steps, "cfg": item.cfgScale,
            "sampler": item.samplerName, "width": item.width, "height": item.height,
            "label": item.label
        ]
        if let sd = try? JSONSerialization.data(withJSONObject: sidecar, options: .prettyPrinted) {
            let sc = subdir.appending(path: filename.replacingOccurrences(of: ".png", with: ".json"))
            try? sd.write(to: sc, options: .atomic)
        }
        return fileURL.path
    }

    // MARK: - History

    private func addToHistory(_ job: BatchJob) {
        var j = job; j.results = j.results.map { var r = $0; r.image = nil; return r } // no guardar PNGs en history
        jobHistory.insert(j, at: 0)
        if jobHistory.count > 50 { jobHistory = Array(jobHistory.prefix(50)) }
        saveHistory()
    }

    private func saveHistory() {
        guard let url  = historyURL,
              let data = try? JSONEncoder.pretty.encode(jobHistory) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func loadHistory() {
        guard let url  = historyURL,
              let data = try? Data(contentsOf: url),
              let jobs = try? JSONDecoder.iso8601.decode([BatchJob].self, from: data) else { return }
        jobHistory = jobs
    }

    private var historyURL: URL? {
        VaultManager.shared.vaultMetaURL?.appending(path: "batch_history.json")
    }
}

enum BatchError: LocalizedError {
    case badResponse, noImage
    var errorDescription: String? {
        switch self {
        case .badResponse: return "A1111 respondió con error"
        case .noImage:     return "No se recibió imagen"
        }
    }
}

// MARK: - BatchBuilderView

struct BatchBuilderView: View {

    @ObservedObject var engine = BatchEngine.shared
    @Binding var basePrompt:    String
    @Binding var baseNegative:  String
    @Binding var baseURL:       String
    @Binding var width:         Int
    @Binding var height:        Int

    @State private var mode:         BatchMode = .seedVariations
    @State private var promptLines:  String    = ""
    @State private var seedInput:    String    = ""
    @State private var steps:        Int       = 20
    @State private var cfg:          Double    = 7.0
    @State private var sampler:      String    = "DPM++ 2M Karras"
    @State private var showGrid:     Bool      = false

    var body: some View {
        VStack(spacing: 0) {

            // Header
            HStack(spacing: 10) {
                Image(systemName: "square.grid.3x3.fill")
                    .font(.system(size: 14)).foregroundColor(Color(hex: "#60a5fa"))
                Text("Batch")
                    .font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                Spacer()
                if engine.isRunning {
                    Button("Cancelar") { engine.cancel() }
                        .buttonStyle(.plain).foregroundColor(.red)
                        .font(.system(size: 12, weight: .medium))
                }
                Button(action: { showGrid.toggle() }) {
                    Image(systemName: showGrid ? "slider.horizontal.3" : "square.grid.3x3")
                        .font(.system(size: 12))
                        .foregroundColor(showGrid ? Color(hex: "#60a5fa") : .secondary)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(Color.white.opacity(0.03))

            Divider().background(Color.white.opacity(0.07))

            if showGrid {
                batchGrid
            } else {
                builderPanel
            }
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(Color(hex: "#60a5fa").opacity(0.2), lineWidth: 1))
    }

    // MARK: - Builder Panel

    var builderPanel: some View {
        ScrollView {
            VStack(spacing: 14) {

                // Modo
                VStack(alignment: .leading, spacing: 6) {
                    sectionLabel("Modo")
                    HStack(spacing: 6) {
                        ForEach(BatchMode.allCases, id: \.self) { m in
                            Button(action: { mode = m }) {
                                VStack(spacing: 3) {
                                    Image(systemName: m.icon).font(.system(size: 12))
                                    Text(m.rawValue).font(.system(size: 8)).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity).padding(.vertical, 8)
                                .background(mode == m
                                    ? Color(hex: "#60a5fa").opacity(0.2) : Color.white.opacity(0.04))
                                .foregroundColor(mode == m ? Color(hex: "#60a5fa") : .secondary)
                                .cornerRadius(7)
                            }.buttonStyle(.plain)
                        }
                    }
                }

                // Prompts input
                if mode == .promptVariations || mode == .fullMatrix {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            sectionLabel("Prompts (uno por línea)")
                            Spacer()
                            Text("\(promptLines.split(separator: "\n", omittingEmptySubsequences: true).count) prompts")
                                .font(.system(size: 10)).foregroundColor(Color(hex: "#60a5fa"))
                        }
                        TextEditor(text: $promptLines)
                            .font(.system(size: 11, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .foregroundColor(.white.opacity(0.9))
                            .frame(minHeight: 80).padding(8)
                            .background(Color.white.opacity(0.04)).cornerRadius(6)
                        Button("Usar prompt de sesión") { promptLines = basePrompt }
                            .buttonStyle(.plain).font(.system(size: 10))
                            .foregroundColor(Color(hex: "#60a5fa"))
                    }
                }

                // Seeds input
                if mode == .seedVariations || mode == .fullMatrix {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            sectionLabel("Seeds (separados por coma)")
                            Spacer()
                            Button("Generar 5 random") {
                                let randoms = (0..<5).map { _ in Int.random(in: 1...999999999) }
                                seedInput = randoms.map { String($0) }.joined(separator: ", ")
                            }
                            .buttonStyle(.plain).font(.system(size: 10))
                            .foregroundColor(Color(hex: "#60a5fa"))
                        }
                        TextField("1234, 5678, 9012…", text: $seedInput)
                            .textFieldStyle(.roundedBorder).font(.system(size: 12))
                    }
                }

                // Config
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        sectionLabel("Steps")
                        Stepper(value: $steps, in: 10...60, step: 5) {
                            Text("\(steps)").font(.system(size: 12, design: .monospaced)).foregroundColor(.white)
                        }
                    }
                    Divider().frame(height: 30).background(Color.white.opacity(0.08))
                    VStack(alignment: .leading, spacing: 4) {
                        sectionLabel("CFG")
                        Stepper(value: $cfg, in: 1...20, step: 0.5) {
                            Text(String(format: "%.1f", cfg))
                                .font(.system(size: 12, design: .monospaced)).foregroundColor(.white)
                        }
                    }
                }
                .padding(10).background(Color.white.opacity(0.03)).cornerRadius(8)

                // Resumen
                if itemCount > 0 {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle").font(.system(size: 11))
                            .foregroundColor(Color(hex: "#60a5fa"))
                        Text("\(itemCount) imagen\(itemCount > 1 ? "es" : "") a generar")
                            .font(.system(size: 12)).foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(8).background(Color(hex: "#60a5fa").opacity(0.08)).cornerRadius(6)
                }

                // Progress
                if engine.isRunning, let job = engine.currentJob {
                    VStack(spacing: 6) {
                        ProgressView(value: job.progress)
                            .accentColor(Color(hex: "#60a5fa"))
                        Text(engine.progressText)
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    .padding(10).background(Color.white.opacity(0.03)).cornerRadius(8)
                } else if !engine.progressText.isEmpty {
                    Text(engine.progressText)
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }

                // Run button
                Button(action: { Task { await runBatch() } }) {
                    HStack(spacing: 8) {
                        if engine.isRunning {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Image(systemName: "play.fill")
                        }
                        Text(engine.isRunning ? "Procesando…" : "Ejecutar Batch · \(itemCount) imgs")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(canRun
                        ? LinearGradient(colors: [Color(hex: "#60a5fa"), Color(hex: "#3b82f6")],
                                        startPoint: .leading, endPoint: .trailing)
                        : LinearGradient(colors: [.gray.opacity(0.3), .gray.opacity(0.3)],
                                        startPoint: .leading, endPoint: .trailing))
                    .foregroundColor(.white).cornerRadius(10)
                }
                .buttonStyle(.plain).disabled(!canRun || engine.isRunning)
            }
            .padding(14)
        }
    }

    // MARK: - Grid

    var batchGrid: some View {
        Group {
            if engine.gridImages.isEmpty && !engine.isRunning {
                VStack(spacing: 12) {
                    Image(systemName: "square.grid.3x3").font(.system(size: 32))
                        .foregroundColor(.white.opacity(0.08))
                    Text("Ejecuta un batch para ver el grid")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity).padding(40)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], spacing: 8) {
                        ForEach(engine.currentJob?.items ?? []) { item in
                            gridCell(item: item)
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    func gridCell(item: BatchItem) -> some View {
        let result = engine.currentJob?.results.first(where: { $0.itemID == item.id })
        let image  = engine.gridImages[item.id]

        return ZStack(alignment: .bottomLeading) {
            if let img = image {
                Image(nsImage: img).resizable().scaledToFill()
                    .frame(width: 140, height: 140).clipped()
            } else {
                RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04))
                    .frame(width: 140, height: 140)
                    .overlay(
                        Group {
                            if result?.status == .running {
                                ProgressView().controlSize(.small)
                            } else if result?.status == .failed {
                                Image(systemName: "xmark.circle").foregroundColor(.red)
                                    .font(.system(size: 20))
                            } else {
                                Image(systemName: "clock").foregroundColor(.secondary)
                                    .font(.system(size: 18))
                            }
                        }
                    )
            }

            // Label overlay
            if !item.label.isEmpty || result?.resultSeed != nil {
                VStack(alignment: .leading, spacing: 1) {
                    if !item.label.isEmpty {
                        Text(item.label).font(.system(size: 9, weight: .semibold))
                    }
                    if let seed = result?.resultSeed {
                        Text("🌱 \(seed)").font(.system(size: 8, design: .monospaced))
                    }
                }
                .foregroundColor(.white)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Color.black.opacity(0.6))
                .cornerRadius(4).padding(4)
            }
        }
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(result?.status == .success ? Color(hex: "#60a5fa").opacity(0.4) : Color.clear, lineWidth: 1.5))
    }

    // MARK: - Computed

    var parsedPrompts: [String] {
        promptLines.split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var parsedSeeds: [Int] {
        seedInput.split(separator: ",").compactMap {
            Int($0.trimmingCharacters(in: .whitespaces))
        }
    }

    var itemCount: Int {
        switch mode {
        case .promptVariations: return max(parsedPrompts.count, 1)
        case .seedVariations:   return max(parsedSeeds.count,   1)
        case .fullMatrix:       return max(parsedPrompts.count, 1) * max(parsedSeeds.count, 1)
        case .manual:           return engine.currentJob?.items.count ?? 0
        }
    }

    var canRun: Bool {
        switch mode {
        case .promptVariations: return !parsedPrompts.isEmpty
        case .seedVariations:   return !parsedSeeds.isEmpty
        case .fullMatrix:       return !parsedPrompts.isEmpty && !parsedSeeds.isEmpty
        case .manual:           return true
        }
    }

    // MARK: - Run

    private func runBatch() async {
        var job: BatchJob
        let prompt = parsedPrompts.first ?? basePrompt

        switch mode {
        case .promptVariations:
            job = engine.makePromptVariationsJob(
                prompts: parsedPrompts, negative: baseNegative, steps: steps,
                cfg: cfg, width: width, height: height, baseURL: baseURL)
        case .seedVariations:
            job = engine.makeSeedVariationsJob(
                prompt: prompt, negative: baseNegative, seeds: parsedSeeds,
                steps: steps, cfg: cfg, width: width, height: height, baseURL: baseURL)
        case .fullMatrix:
            job = engine.makeMatrixJob(
                prompts: parsedPrompts, negative: baseNegative, seeds: parsedSeeds,
                steps: steps, cfg: cfg, width: width, height: height, baseURL: baseURL)
        case .manual:
            return
        }

        showGrid = true
        await engine.run(job)
    }

    func sectionLabel(_ t: String) -> some View {
        Text(t).font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
    }
}
