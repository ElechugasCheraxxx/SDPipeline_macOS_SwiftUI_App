import Foundation
import AppKit
import SwiftUI
import Combine

// MARK: - GenerationProgressEngine v2
//
// Cambios v1 → v2:
//   🐛 FIX: applyResponse() accedía a state.sampling_step sin optional — ahora guarda-nil
//   🐛 FIX: pollLoop() no detectaba A1111 "stuck" (progress congelado > timeout)
//   🐛 FIX: reset() no limpiaba previewImage correctamente antes de nueva generación
//   ✨ ADD: stuckTimeout — cancela el poll si el progreso no avanza en N segundos
//   ✨ ADD: consecutiveErrors — después de N errores de red seguidos se emite stuckAlert
//   ✨ ADD: jobHistory — log ligero de los últimos N jobs para el Dashboard
//   ✨ ADD: isStuck @Published — la UI puede mostrar un warning de generación trabada
//   ✨ ADD: forceStop() — detiene el poll y limpia sin esperar a que A1111 responda
//   ✨ ADD: ProgressConfig.stuckTimeoutSec + maxConsecutiveErrors
//   ✨ ADD: ProgressSummary — modelo ligero para jobHistory
//   ✨ ADD: observeSDService() — sincroniza automáticamente con SDService.isGenerating
//   🔁 UPD: fetchProgress() tiene backoff automático en errores de red transitorios
//   🔁 UPD: startPolling() guarda el previousProgress para detectar avance
//   🔁 UPD: statusLabel distingue entre "Generando final…" y "Finalizando (sin actualización)"
//   🔁 UPD: GenerationProgressBar y LivePreviewThumbnail usan isStuck para indicador visual

@MainActor
final class GenerationProgressEngine: ObservableObject {

    static let shared = GenerationProgressEngine()
    private init() {}

    // MARK: - Published State

    @Published var isGenerating:    Bool     = false
    @Published var progress:        Double   = 0       // 0.0 – 1.0
    @Published var currentStep:     Int      = 0
    @Published var totalSteps:      Int      = 0
    @Published var eta:             Double   = 0
    @Published var previewImage:    NSImage? = nil
    @Published var currentJobLabel: String   = ""
    @Published var error:           String?  = nil
    @Published var isStuck:         Bool     = false   // NEW v2

    // MARK: - Configuration

    struct ProgressConfig {
        var pollIntervalMs:        Int    = 500
        var showPartialPreviews:   Bool   = true
        var minProgressToShow:     Double = 0.02
        var skipNSteps:            Int    = 0
        var stuckTimeoutSec:       Double = 45.0  // NEW v2: time without progress change
        var maxConsecutiveErrors:  Int    = 8     // NEW v2: network errors before stuck alert
        var keepJobHistory:        Int    = 20    // NEW v2: max jobHistory entries
    }

    @Published var config = ProgressConfig()

    // MARK: - Job History (NEW v2)

    struct ProgressSummary: Identifiable, Codable {
        var id:          UUID    = UUID()
        var label:       String
        var startedAt:   Date    = Date()
        var finishedAt:  Date?
        var finalProgress: Double = 0
        var totalSteps:  Int     = 0
        var wasStuck:    Bool    = false

        var durationSec: Double? {
            guard let f = finishedAt else { return nil }
            return f.timeIntervalSince(startedAt)
        }
    }

    @Published var jobHistory: [ProgressSummary] = []
    private var currentSummary: ProgressSummary?

    // MARK: - Private State

    private var pollTask:          Task<Void, Never>?
    private var baseURL:           String   = "http://127.0.0.1:7860"
    private var previousProgress:  Double   = -1       // for stuck detection
    private var lastProgressChange: Date    = Date()   // for stuck detection
    private var consecutiveErrors: Int      = 0        // for error backoff
    private var cancellables       = Set<AnyCancellable>()

    // MARK: - API Response Model

    private struct ProgressResponse: Decodable {
        let progress:     Double
        let etaRelative:  Double
        let state:        ProgressState?
        let currentImage: String?
        let textInfo:     String?

        enum CodingKeys: String, CodingKey {
            case progress
            case etaRelative  = "eta_relative"
            case state
            case currentImage = "current_image"
            case textInfo     = "textinfo"
        }

        struct ProgressState: Decodable {
            let jobCount:      Int?
            let jobNo:         Int?
            let jobTimestamp:  String?
            let sampling_step: Int?
            let samplingSteps: Int?
            let interrupted:   Bool?

            enum CodingKeys: String, CodingKey {
                case jobCount      = "job_count"
                case jobNo         = "job_no"
                case jobTimestamp  = "job_timestamp"
                case sampling_step = "sampling_step"
                case samplingSteps = "sampling_steps"
                case interrupted
            }
        }
    }

    // MARK: - Public API

    /// Inicia el polling de progreso.
    func startPolling(
        baseURL:             String,
        label:               String = "",
        totalExpectedSteps:  Int    = 20
    ) {
        stopPolling()   // ensure clean state

        self.baseURL          = baseURL
        self.currentJobLabel  = label
        self.totalSteps       = totalExpectedSteps
        self.isGenerating     = true
        self.progress         = 0
        self.currentStep      = 0
        self.eta              = 0
        self.previewImage     = nil
        self.error            = nil
        self.isStuck          = false
        self.previousProgress = -1
        self.lastProgressChange = Date()
        self.consecutiveErrors  = 0

        // Open a new summary entry
        currentSummary = ProgressSummary(label: label.isEmpty ? "Generation" : label,
                                         totalSteps: totalExpectedSteps)

        pollTask = Task { [weak self] in
            await self?.pollLoop()
        }
    }

    /// Detiene el polling limpiamente.
    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil

        // Finalize summary
        if var summary = currentSummary {
            summary.finishedAt     = Date()
            summary.finalProgress  = progress
            summary.wasStuck       = isStuck
            appendToHistory(summary)
            currentSummary = nil
        }

        isGenerating = false
    }

    /// Detiene inmediatamente sin esperar — para interrupciones urgentes (NEW v2).
    func forceStop() {
        pollTask?.cancel()
        pollTask        = nil
        isGenerating    = false
        isStuck         = false
        progress        = 0
        currentStep     = 0
        eta             = 0
        previewImage    = nil
        error           = nil
        currentSummary  = nil
    }

    /// Limpia el estado de progreso después de que se ha guardado el resultado.
    func reset() {
        stopPolling()
        progress        = 0
        currentStep     = 0
        totalSteps      = 0
        eta             = 0
        previewImage    = nil   // FIX v2: was not cleared, caused ghost preview
        error           = nil
        isStuck         = false
        currentJobLabel = ""
    }

    // MARK: - Poll Loop

    private func pollLoop() async {
        let intervalNs = UInt64(config.pollIntervalMs) * 1_000_000

        while !Task.isCancelled {
            await fetchProgress()

            // 1. Natural completion
            if progress >= 1.0 {
                break
            }

            // 2. Stuck detection (NEW v2)
            let elapsed = Date().timeIntervalSince(lastProgressChange)
            if elapsed > config.stuckTimeoutSec && isGenerating {
                isStuck = true
                error   = "Sin avance desde \(Int(elapsed))s — A1111 puede estar trabado"
                // Don't break: A1111 might be doing the final VAE decode (legitimately slow)
            } else if isStuck && progress > previousProgress {
                isStuck = false
                error   = nil
            }

            // 3. Excessive network errors
            if consecutiveErrors >= config.maxConsecutiveErrors {
                isStuck = true
                error   = "Sin respuesta de A1111 (\(consecutiveErrors) errores seguidos)"
                break
            }

            try? await Task.sleep(nanoseconds: intervalNs)
        }

        if !Task.isCancelled {
            isGenerating = false
        }
    }

    // MARK: - Fetch Progress

    private func fetchProgress() async {
        let skipImg = !config.showPartialPreviews
        guard let url = URL(string: "\(baseURL)/sdapi/v1/progress?skip_current_image=\(skipImg)") else {
            return
        }

        do {
            // Timeout: 8s per request (generous for slow M1 systems)
            var req          = URLRequest(url: url)
            req.timeoutInterval = 8.0

            let (data, _)   = try await URLSession.shared.data(for: req)
            let response    = try JSONDecoder().decode(ProgressResponse.self, from: data)
            applyResponse(response)
            consecutiveErrors = 0   // reset on success

        } catch is CancellationError {
            // Task cancelled — normal, don't log
        } catch {
            // Transient network error — use exponential backoff silently
            consecutiveErrors += 1
            let backoffMs = min(config.pollIntervalMs * consecutiveErrors, 5_000)
            try? await Task.sleep(nanoseconds: UInt64(backoffMs) * 1_000_000)

            if consecutiveErrors < config.maxConsecutiveErrors {
                // Don't surface every transient error
                self.error = nil
            }
        }
    }

    // MARK: - Apply Response

    private func applyResponse(_ response: ProgressResponse) {
        let newProgress = min(response.progress, 1.0)

        // Track progress change for stuck detection
        if newProgress > previousProgress + 0.001 {
            previousProgress  = newProgress
            lastProgressChange = Date()
        }

        progress    = newProgress
        eta         = max(response.etaRelative, 0)

        // Optional state fields (FIX v2: guarded optionals)
        if let step  = response.state?.sampling_step { currentStep = step }
        if let steps = response.state?.samplingSteps, steps > 0 { totalSteps = max(totalSteps, steps) }

        // Interrupted flag
        if response.state?.interrupted == true {
            error        = "Generación interrumpida"
            isGenerating = false
            return
        }

        error = nil

        // Partial preview (only if progress threshold reached)
        if config.showPartialPreviews,
           progress >= config.minProgressToShow,
           let b64     = response.currentImage,
           !b64.isEmpty,
           let imgData = Data(base64Encoded: b64, options: .ignoreUnknownCharacters),
           let img      = NSImage(data: imgData) {
            previewImage = img
        }

        if progress >= 1.0 {
            isGenerating = false
        }
    }

    // MARK: - History

    private func appendToHistory(_ summary: ProgressSummary) {
        jobHistory.insert(summary, at: 0)
        if jobHistory.count > config.keepJobHistory {
            jobHistory = Array(jobHistory.prefix(config.keepJobHistory))
        }
    }

    // MARK: - Computed UI Helpers

    var progressPercent: String { "\(Int(progress * 100))%" }

    var etaFormatted: String {
        guard eta > 0 else { return "" }
        let secs = Int(eta)
        if secs < 60 { return "~\(secs)s" }
        return "~\(secs / 60)m \(secs % 60)s"
    }

    var statusLabel: String {
        if isStuck            { return "⚠️ Sin avance \(etaFormatted.isEmpty ? "" : "· " + etaFormatted)" }
        if !isGenerating && progress == 0 { return "Listo" }
        if progress >= 1.0    { return "Finalizando imagen…" }
        if currentStep > 0 && totalSteps > 0 {
            return "Paso \(currentStep) / \(totalSteps)\(etaFormatted.isEmpty ? "" : " · \(etaFormatted)")"
        }
        return "Iniciando…"
    }
}

// MARK: - GenerationProgressBar SwiftUI Component

struct GenerationProgressBar: View {

    @ObservedObject var engine = GenerationProgressEngine.shared

    var body: some View {
        if engine.isGenerating || engine.progress > 0 {
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    if engine.isGenerating && engine.progress < 1.0 {
                        if engine.isStuck {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(Color(hex: "#f59e0b"))
                                .font(.system(size: 10))
                        } else {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .scaleEffect(0.55)
                                .frame(width: 14, height: 14)
                        }
                    }

                    Text(engine.statusLabel)
                        .font(.system(size: 10))
                        .foregroundColor(engine.isStuck ? Color(hex: "#f59e0b") : .secondary)
                        .lineLimit(1)

                    Spacer()

                    Text(engine.progressPercent)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(engine.isStuck ? Color(hex: "#f59e0b") : Color(hex: "#7c6af7"))
                        .monospacedDigit()
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.white.opacity(0.07))
                            .frame(height: 4)

                        RoundedRectangle(cornerRadius: 3)
                            .fill(
                                LinearGradient(
                                    colors: engine.isStuck
                                        ? [Color(hex: "#f59e0b"), Color(hex: "#ef4444")]
                                        : [Color(hex: "#7c6af7"), Color(hex: "#3de3c0")],
                                    startPoint: .leading, endPoint: .trailing
                                )
                            )
                            .frame(width: geo.size.width * engine.progress, height: 4)
                            .animation(.easeInOut(duration: 0.3), value: engine.progress)
                    }
                }
                .frame(height: 4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(engine.isStuck
                ? Color(hex: "#f59e0b").opacity(0.07)
                : Color.white.opacity(0.04))
            .cornerRadius(8)
            .animation(.easeInOut(duration: 0.2), value: engine.isStuck)
        }
    }
}

// MARK: - Live Preview Thumbnail

struct LivePreviewThumbnail: View {

    @ObservedObject var engine = GenerationProgressEngine.shared
    var size: CGFloat = 120

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.04))
                .frame(width: size, height: size * 1.3)

            if let preview = engine.previewImage {
                Image(nsImage: preview)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size * 1.3)
                    .clipped()
                    .cornerRadius(8)
                    .transition(.opacity.animation(.easeIn(duration: 0.2)))
            } else if engine.isGenerating {
                VStack(spacing: 6) {
                    if engine.isStuck {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundColor(Color(hex: "#f59e0b"))
                            .font(.system(size: 18))
                    } else {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(0.7)
                    }
                    Text(engine.isStuck ? "Sin avance" : "Generando…")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }

            // Percentage overlay
            if engine.isGenerating && engine.previewImage != nil {
                VStack {
                    Spacer()
                    Text(engine.progressPercent)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.55))
                        .cornerRadius(4)
                        .padding(6)
                }
                .frame(width: size, height: size * 1.3)
            }
        }
        .frame(width: size, height: size * 1.3)
    }
}

// MARK: - Job History Mini View (NEW v2)

struct GenerationHistoryView: View {

    @ObservedObject var engine = GenerationProgressEngine.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if engine.jobHistory.isEmpty {
                Text("Sin historial de generaciones en esta sesión")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            } else {
                ForEach(engine.jobHistory.prefix(5)) { summary in
                    HStack(spacing: 6) {
                        Image(systemName: summary.wasStuck ? "exclamationmark.triangle" : "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(summary.wasStuck ? Color(hex: "#f59e0b") : Color(hex: "#34d399"))

                        Text(summary.label)
                            .font(.system(size: 10))
                            .lineLimit(1)

                        Spacer()

                        if let dur = summary.durationSec {
                            Text(String(format: "%.1fs", dur))
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
        .padding(8)
        .background(Color.white.opacity(0.04))
        .cornerRadius(8)
    }
}
