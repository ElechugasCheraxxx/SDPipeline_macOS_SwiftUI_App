import Combine
import SwiftUI
import AppKit

// MARK: - BatchJobView
//
// UI completa para el motor de batch processing.
// Permite crear, monitorear y revisar jobs de batch.
// Se integra en el panel derecho de ContentView como tab adicional.

struct BatchJobView: View {

    @ObservedObject var engine = BatchEngine.shared
    @ObservedObject var sdService: SDService
    var settings: GenerationSettings
    var parsedPrompt: String

    @State private var selectedMode: BatchMode = .promptVariations
    @State private var variationCount: Int = 4
    @State private var seedCount: Int = 6
    @State private var customPrompts: String = ""
    @State private var activeJobID: UUID? = nil
    @State private var showGrid: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider().background(Color.white.opacity(0.06))

            if engine.isRunning {
                runningPanel
            } else if let job = engine.jobHistory.first, showGrid {
                gridResultPanel(job)
            } else {
                configPanel
            }
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
    }

    // MARK: - Header

    var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.grid.3x3.fill")
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "#7c6af7"))
            Text("Batch Generator")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
            Spacer()
            if !engine.completedJobs.isEmpty {
                Button(action: { showGrid.toggle() }) {
                    Image(systemName: showGrid ? "gear" : "photo.stack")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.white.opacity(0.03))
    }

    // MARK: - Config Panel

    var configPanel: some View {
        ScrollView {
            VStack(spacing: 16) {

                // Mode selector
                VStack(alignment: .leading, spacing: 6) {
                    Text("Modo de batch")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                    Picker("", selection: $selectedMode) {
                        ForEach(BatchMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                // Mode-specific config
                switch selectedMode {
                case .promptVariations:
                    promptVariationsConfig
                case .seedVariations:
                    seedExplorationConfig
                case .matrix:
                    matrixConfig
                case .characterStudy:
                    characterStudyConfig
                }

                Divider().background(Color.white.opacity(0.07))

                // Action buttons
                HStack(spacing: 10) {
                    Button(action: startBatch) {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 11))
                            Text("Iniciar Batch")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(LinearGradient(
                            colors: [Color(hex: "#7c6af7"), Color(hex: "#3de3c0")],
                            startPoint: .leading, endPoint: .trailing
                        ))
                        .foregroundColor(.white).cornerRadius(7)
                    }
                    .buttonStyle(.plain)
                    .disabled(parsedPrompt.isEmpty)
                }

                if !engine.completedJobs.isEmpty {
                    historySection
                }
            }
            .padding(14)
        }
    }

    // MARK: - Mode Configs

    var promptVariationsConfig: some View {
        VStack(alignment: .leading, spacing: 10) {
            modeDescription(
                icon: "text.bubble.fill",
                title: "Variaciones de prompt",
                subtitle: "Genera múltiples imágenes con el mismo prompt base, variando semillas. Útil para encontrar la mejor composición."
            )
            countStepper("Cantidad de variaciones", count: $variationCount, range: 2...16)
        }
    }

    var seedExplorationConfig: some View {
        VStack(alignment: .leading, spacing: 10) {
            modeDescription(
                icon: "die.face.5.fill",
                title: "Exploración de seeds",
                subtitle: "Genera N imágenes con seeds secuenciales para explorar el espacio del modelo."
            )
            countStepper("Cantidad de seeds", count: $seedCount, range: 2...20)
        }
    }

    var matrixConfig: some View {
        VStack(alignment: .leading, spacing: 10) {
            modeDescription(
                icon: "tablecells.fill",
                title: "Matriz de prompts",
                subtitle: "Introduce múltiples prompts (uno por línea) para comparar resultados."
            )
            VStack(alignment: .leading, spacing: 4) {
                Text("Prompts (uno por línea)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                TextEditor(text: $customPrompts)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white)
                    .frame(height: 80)
                    .background(Color.white.opacity(0.04))
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.08), lineWidth: 1))
                    .scrollContentBackground(.hidden)
                Text("\(customPrompts.split(separator: "\n").filter { !$0.isEmpty }.count) prompts")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        }
    }

    var characterStudyConfig: some View {
        VStack(alignment: .leading, spacing: 10) {
            modeDescription(
                icon: "person.fill.viewfinder",
                title: "Character study",
                subtitle: "Genera poses/expresiones variadas del personaje activo usando el prompt base."
            )
            if let char = CharacterEngine.shared.activeCharacter {
                HStack(spacing: 8) {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(Color(hex: "#7c6af7"))
                    VStack(alignment: .leading) {
                        Text(char.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                        Text("Personaje activo")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(10)
                .background(Color(hex: "#7c6af7").opacity(0.08))
                .cornerRadius(8)
                countStepper("Variaciones de personaje", count: $variationCount, range: 2...12)
            } else {
                Text("⚠️ No hay personaje activo. Selecciona uno en el panel izquierdo.")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#fbbf24"))
                    .padding(10)
                    .background(Color(hex: "#fbbf24").opacity(0.06))
                    .cornerRadius(6)
            }
        }
    }

    // MARK: - Running Panel

    var runningPanel: some View {
        VStack(spacing: 20) {
            Spacer()

            // Animated progress ring
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.06), lineWidth: 8)
                    .frame(width: 90, height: 90)
                Circle()
                    .trim(from: 0, to: engine.progress)
                    .stroke(
                        LinearGradient(
                            colors: [Color(hex: "#7c6af7"), Color(hex: "#3de3c0")],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .frame(width: 90, height: 90)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.3), value: engine.progress)

                VStack(spacing: 2) {
                    Text("\(Int(engine.progress * 100))%")
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    Text("\(engine.completedCount)/\(engine.totalCount)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }

            Text(engine.progressText)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            // Thumbnail preview del último completado
            if let last = engine.completedResults.last?.image {
                Image(nsImage: last)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 120)
                    .cornerRadius(6)
                    .transition(.opacity)
            }

            Button(action: { engine.cancel() }) {
                HStack(spacing: 6) {
                    Image(systemName: "stop.fill").font(.system(size: 10))
                    Text("Cancelar batch")
                }
                .padding(.horizontal, 16).padding(.vertical, 7)
                .background(Color.red.opacity(0.15))
                .foregroundColor(.red).cornerRadius(6)
            }
            .buttonStyle(.plain)

            Spacer()
        }
    }

    // MARK: - Grid Result Panel

    func gridResultPanel(_ job: BatchJob) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Resultado: \(job.items.count) imágenes")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: { showGrid = false }) {
                    Image(systemName: "xmark.circle").font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)

            let cols = 3
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: cols), spacing: 4) {
                    ForEach(job.results) { result in
                        batchThumbnail(result: result, job: job)
                    }
                }
                .padding(8)
            }
        }
    }

    func batchThumbnail(result: BatchResult, job: BatchJob) -> some View {
        ZStack(alignment: .bottomTrailing) {
            let nsImage = result.image.flatMap { NSImage(data: $0) }
                ?? engine.gridImages[result.itemID]
            if let img = nsImage {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(height: 100)
                    .clipped()
                    .cornerRadius(4)
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.04))
                    .frame(height: 100)
                    .overlay(
                        Image(systemName: result.status == .failed ? "xmark" : "clock")
                            .foregroundColor(.secondary)
                    )
            }
            if let seed = result.resultSeed {
                Text("\(seed)")
                    .font(.system(size: 7, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .background(Color.black.opacity(0.5))
                    .cornerRadius(3)
                    .padding(3)
            }
        }
    }

    // MARK: - History Section

    var historySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Historial de batch")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
            ForEach(engine.jobHistory.prefix(5)) { job in
                HStack(spacing: 8) {
                    Image(systemName: job.status == .done ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(job.status == .done ? Color(hex: "#34d399") : .red)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(job.label.isEmpty ? job.mode.rawValue : job.label)
                            .font(.system(size: 11)).foregroundColor(.white).lineLimit(1)
                        Text("\(job.items.count) imágenes · \(job.createdAt.shortDisplay)")
                            .font(.system(size: 9)).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: {
                        engine.loadCompletedResults(from: job)
                        showGrid = true
                    }) {
                        Image(systemName: "eye").font(.system(size: 10)).foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.white.opacity(0.03))
                .cornerRadius(6)
            }
        }
    }

    // MARK: - Actions

    func startBatch() {
        Task {
            let url = settings.sdBaseURL
            switch selectedMode {
            case .promptVariations:
                // Generar variationCount copies del mismo prompt con seeds aleatorios
                let prompts = Array(repeating: parsedPrompt, count: variationCount)
                let job = engine.makePromptVariationsJob(
                    prompts:  prompts,
                    negative: settings.negativePrompt,
                    seed:     -1,
                    steps:    settings.steps,
                    cfg:      settings.cfgScale,
                    width:    settings.width,
                    height:   settings.height,
                    sampler:  settings.samplerName,
                    baseURL:  url
                )
                await engine.run(job)

            case .seedVariations:
                // Generar seedCount seeds secuenciales desde el seed actual
                let baseSeed = settings.seed > 0 ? settings.seed : Int.random(in: 1...999999)
                let seeds = (0..<seedCount).map { baseSeed + $0 }
                let job = engine.makeSeedVariationsJob(
                    prompt:   parsedPrompt,
                    negative: settings.negativePrompt,
                    seeds:    seeds,
                    steps:    settings.steps,
                    cfg:      settings.cfgScale,
                    width:    settings.width,
                    height:   settings.height,
                    sampler:  settings.samplerName,
                    baseURL:  url
                )
                await engine.run(job)

            case .matrix:
                let prompts = customPrompts.split(separator: "\n")
                    .map { String($0).trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                guard !prompts.isEmpty else { return }
                let seeds = [-1, -1, -1] // 3 seeds aleatorios por prompt
                let job = engine.makeMatrixJob(
                    prompts:  prompts,
                    negative: settings.negativePrompt,
                    seeds:    seeds,
                    steps:    settings.steps,
                    cfg:      settings.cfgScale,
                    width:    settings.width,
                    height:   settings.height,
                    sampler:  settings.samplerName,
                    baseURL:  url
                )
                await engine.run(job)

            case .characterStudy:
                guard let char = CharacterEngine.shared.activeCharacter else { return }
                let injected = CharacterEngine.shared.injectActiveCharacter(into: parsedPrompt)
                let prompts  = Array(repeating: injected, count: variationCount)
                let job = engine.makePromptVariationsJob(
                    prompts:  prompts,
                    negative: CharacterEngine.shared.activeCharacterNegative,
                    seed:     -1,
                    steps:    settings.steps,
                    cfg:      settings.cfgScale,
                    width:    settings.width,
                    height:   settings.height,
                    sampler:  settings.samplerName,
                    baseURL:  url
                )
                var labeledJob = job
                labeledJob = BatchJob(mode: job.mode, items: job.items, results: job.results,
                                      baseURL: url, label: "Character Study · \(char.name)",
                                      status: job.status, totalDone: job.totalDone)
                await engine.run(labeledJob)
            }

            showGrid = true
        }
    }

    // MARK: - Sub-components

    func modeDescription(icon: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(Color(hex: "#7c6af7").opacity(0.8))
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.03))
        .cornerRadius(8)
    }

    func countStepper(_ label: String, count: Binding<Int>, range: ClosedRange<Int>) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
            Stepper(value: count, in: range) {
                Text("\(count.wrappedValue)")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                    .frame(width: 30)
            }
        }
    }
}

// MARK: - BatchEngine extension (helpers para BatchJobView)

extension BatchEngine {
    /// Total de ítems en el job actual.
    var totalCount: Int { currentJob?.totalCount ?? 0 }
    /// Ítems completados en el job actual.
    var completedCount: Int { currentJob?.totalDone ?? 0 }
    /// Progreso del job actual.
    var progress: Double { currentJob?.progress ?? 0 }
    /// Jobs completados (alias para jobHistory).
    var completedJobs: [BatchJob] { jobHistory }
    /// Resultados del último job completado como imágenes.
    var completedResults: [(image: NSImage?, seed: Int?, status: BatchResult.Status)] {
        (currentJob ?? jobHistory.first).map { job in
            job.results.map { result in
                let img = result.image.flatMap { NSImage(data: $0) }
                return (image: img, seed: result.resultSeed, status: result.status)
            }
        } ?? []
    }
    func loadCompletedResults(from job: BatchJob) {
        objectWillChange.send()
    }
}

// (BatchJob.Status ya está definido como enum anidado en BatchEngine.swift)
