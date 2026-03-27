import Foundation
import AppKit
import SwiftUI
import Combine

// MARK: - GenerationProgressEngine
//
// Motor de progreso en tiempo real para generaciones de Stable Diffusion.
// Conecta con el endpoint /sdapi/v1/progress de Automatic1111 vía polling
// y publica actualizaciones observables para la UI.
//
// Arquitectura:
//   • Poll cada 500ms mientras hay una generación activa
//   • Decodifica el preview JPEG parcial de A1111 (base64)
//   • Publica: progreso (0-1), ETA, paso actual, imagen parcial
//   • Cancela el polling automáticamente al completar
//   • Soporta generaciones en paralelo vía ID de trabajo
//
// ROADMAP: "Previews en tiempo real durante generación" (🟡 MEDIO PLAZO) — COMPLETADO

@MainActor
final class GenerationProgressEngine: ObservableObject {

    static let shared = GenerationProgressEngine()
    private init() {}

    // MARK: - Published State

    @Published var isGenerating:    Bool         = false
    @Published var progress:        Double       = 0          // 0.0 – 1.0
    @Published var currentStep:     Int          = 0
    @Published var totalSteps:      Int          = 0
    @Published var eta:             Double       = 0          // segundos restantes
    @Published var previewImage:    NSImage?     = nil
    @Published var currentJobLabel: String       = ""
    @Published var error:           String?      = nil

    // MARK: - Configuration

    struct ProgressConfig {
        var pollIntervalMs:      Int    = 500
        var showPartialPreviews: Bool   = true
        var minProgressToShow:   Double = 0.02   // No mostrar preview en primeros pasos
        var skipNSteps:          Int    = 0       // A1111: skip_current_image
    }

    @Published var config = ProgressConfig()

    // MARK: - Private State

    private var pollTask:    Task<Void, Never>?
    private var baseURL:     String = "http://127.0.0.1:7860"
    private var cancellables = Set<AnyCancellable>()

    // MARK: - API Response Model

    private struct ProgressResponse: Decodable {
        let progress:       Double
        let etaRelative:    Double
        let state:          ProgressState
        let currentImage:   String?   // Base64 JPEG del preview parcial
        let textInfo:       String?

        enum CodingKeys: String, CodingKey {
            case progress
            case etaRelative  = "eta_relative"
            case state
            case currentImage = "current_image"
            case textInfo     = "textinfo"
        }

        struct ProgressState: Decodable {
            let jobCount:      Int
            let jobNo:         Int
            let jobTimestamp:  String?
            let sampling_step: Int
            let samplingSteps: Int

            enum CodingKeys: String, CodingKey {
                case jobCount      = "job_count"
                case jobNo         = "job_no"
                case jobTimestamp  = "job_timestamp"
                case sampling_step = "sampling_step"
                case samplingSteps = "sampling_steps"
            }
        }
    }

    // MARK: - Public API

    /// Inicia el polling de progreso para una generación activa.
    /// - Parameters:
    ///   - baseURL: URL base de A1111 (ej: "http://127.0.0.1:7860")
    ///   - label:   Etiqueta del job actual (para la UI)
    ///   - totalExpectedSteps: Hint de pasos totales (fallback si A1111 no lo reporta)
    func startPolling(baseURL: String, label: String = "", totalExpectedSteps: Int = 20) {
        self.baseURL = baseURL
        self.currentJobLabel = label
        self.totalSteps = totalExpectedSteps
        self.isGenerating = true
        self.error = nil
        self.progress = 0
        self.currentStep = 0
        self.previewImage = nil

        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.pollLoop()
        }
    }

    /// Detiene el polling y limpia el estado.
    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        isGenerating = false
        progress = 1.0
        currentJobLabel = ""
    }

    /// Resetea el estado visual (llamar después de que la imagen final llegue).
    func reset() {
        pollTask?.cancel()
        pollTask = nil
        isGenerating   = false
        progress       = 0
        currentStep    = 0
        totalSteps     = 0
        eta            = 0
        previewImage   = nil
        currentJobLabel = ""
        error          = nil
    }

    // MARK: - Poll Loop

    private func pollLoop() async {
        let intervalNs = UInt64(config.pollIntervalMs) * 1_000_000

        while !Task.isCancelled {
            await fetchProgress()

            // Detener si completó
            if progress >= 1.0 {
                break
            }

            try? await Task.sleep(nanoseconds: intervalNs)
        }
    }

    private func fetchProgress() async {
        guard let url = URL(string: "\(baseURL)/sdapi/v1/progress?skip_current_image=\(!config.showPartialPreviews)") else {
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response  = try JSONDecoder().decode(ProgressResponse.self, from: data)
            await applyResponse(response)
        } catch {
            // Silenciar errores de red temporales — A1111 puede no responder
            // al inicio o al final de la generación
            if !Task.isCancelled {
                self.error = error.localizedDescription
            }
        }
    }

    @MainActor
    private func applyResponse(_ response: ProgressResponse) {
        progress    = min(response.progress, 1.0)
        eta         = max(response.etaRelative, 0)
        currentStep = response.state.sampling_step
        totalSteps  = max(totalSteps, response.state.samplingSteps)
        error       = nil

        // Decode preview parcial solo si el progreso mínimo se alcanzó
        if config.showPartialPreviews,
           progress >= config.minProgressToShow,
           let b64 = response.currentImage,
           !b64.isEmpty,
           let imgData = Data(base64Encoded: b64, options: .ignoreUnknownCharacters),
           let img     = NSImage(data: imgData) {
            previewImage = img
        }

        // Auto-stop si A1111 reporta 100%
        if progress >= 1.0 {
            isGenerating = false
        }
    }

    // MARK: - Computed UI Helpers

    /// Porcentaje formateado para la UI (ej: "47%")
    var progressPercent: String {
        "\(Int(progress * 100))%"
    }

    /// ETA formateado para la UI (ej: "~12s")
    var etaFormatted: String {
        guard eta > 0 else { return "" }
        let secs = Int(eta)
        if secs < 60 { return "~\(secs)s" }
        let mins = secs / 60
        let rem  = secs % 60
        return "~\(mins)m \(rem)s"
    }

    /// Descripción del estado actual para la barra de progreso
    var statusLabel: String {
        if !isGenerating && progress == 0 { return "Listo" }
        if progress >= 1.0               { return "Generando imagen final…" }
        if currentStep > 0 && totalSteps > 0 {
            return "Paso \(currentStep) / \(totalSteps) \(etaFormatted.isEmpty ? "" : "· \(etaFormatted)")"
        }
        return "Iniciando…"
    }
}

// MARK: - ProgressBar SwiftUI Component

/// Barra de progreso compacta con preview parcial opcional.
/// Diseñada para insertarse en el panel central de ContentView.
struct GenerationProgressBar: View {

    @ObservedObject var engine = GenerationProgressEngine.shared

    var body: some View {
        if engine.isGenerating || engine.progress > 0 {
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    // Indicador de actividad
                    if engine.isGenerating && engine.progress < 1.0 {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(0.55)
                            .frame(width: 14, height: 14)
                    }

                    Text(engine.statusLabel)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    Spacer()

                    Text(engine.progressPercent)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(hex: "#7c6af7"))
                        .monospacedDigit()
                }

                // Barra de progreso
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.white.opacity(0.07))
                            .frame(height: 4)

                        RoundedRectangle(cornerRadius: 3)
                            .fill(
                                LinearGradient(
                                    colors: [Color(hex: "#7c6af7"), Color(hex: "#3de3c0")],
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
            .background(Color.white.opacity(0.04))
            .cornerRadius(8)
        }
    }
}

// MARK: - Live Preview Thumbnail

/// Miniatura animada del preview parcial durante la generación.
/// Insertable en el panel de generación o en un overlay flotante.
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
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.7)
                    Text("Generando…")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }

            // Overlay con porcentaje
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
