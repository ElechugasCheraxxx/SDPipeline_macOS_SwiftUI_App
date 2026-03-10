import Foundation
import AppKit
import SwiftUI
import Combine

// MARK: - GenerationProgressMonitor
//
// Monitoriza el progreso de generación en tiempo real vía /sdapi/v1/progress.
// Extrae:
//   - Porcentaje de progreso (0-100%)
//   - ETA en segundos
//   - Preview de imagen en curso (current_image, base64)
//   - Job UUID actual (job)
//   - Número de step actual y total
//   - Sampling info (sampler, steps)
//
// Flujo:
//   1. Llamar start(baseURL:) al iniciar una generación
//   2. El timer polla /sdapi/v1/progress cada 1 segundo
//   3. La UI observa los @Published para actualizar
//   4. Llamar stop() al finalizar la generación
//
// ROADMAP: "Previews en tiempo real durante generación" (🟡 MEDIO PLAZO)

@MainActor
final class GenerationProgressMonitor: ObservableObject {

    static let shared = GenerationProgressMonitor()
    private init() {}

    // MARK: - Published State

    @Published var progress:         Double     = 0       // 0.0 – 1.0
    @Published var progressPercent:  Int        = 0       // 0 – 100
    @Published var eta:              Double     = 0       // segundos
    @Published var currentStep:      Int        = 0
    @Published var totalSteps:       Int        = 0
    @Published var previewImage:     NSImage?   = nil
    @Published var jobID:            String     = ""
    @Published var isPolling:        Bool       = false
    @Published var samplerName:      String     = ""
    @Published var progressText:     String     = ""

    // MARK: - Private

    private var pollTask: Task<Void, Never>? = nil
    private var pollInterval: TimeInterval   = 1.0

    // MARK: - Public API

    func start(baseURL: String, interval: TimeInterval = 1.0) {
        guard !isPolling else { return }
        isPolling    = true
        pollInterval = interval
        reset()
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.poll(baseURL: baseURL)
                try? await Task.sleep(nanoseconds: UInt64(self.pollInterval * 1_000_000_000))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask  = nil
        isPolling = false
    }

    func reset() {
        progress        = 0
        progressPercent = 0
        eta             = 0
        currentStep     = 0
        totalSteps      = 0
        previewImage    = nil
        jobID           = ""
        progressText    = ""
        samplerName     = ""
    }

    // MARK: - Polling

    private func poll(baseURL: String) async {
        guard let url = URL(string: "\(baseURL)/sdapi/v1/progress?skip_current_image=false") else { return }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        // Progress
        let pct = json["progress"] as? Double ?? 0
        progress        = min(pct, 0.99)
        progressPercent = Int(pct * 100)

        // ETA
        eta = json["eta_relative"] as? Double ?? 0

        // Job
        jobID = json["current_job"] as? String ?? jobID

        // State block (steps info)
        if let state = json["state"] as? [String: Any] {
            currentStep = state["sampling_step"]  as? Int ?? currentStep
            totalSteps  = state["sampling_steps"] as? Int ?? totalSteps
            samplerName = state["sampler_name"]   as? String ?? samplerName
        }

        // Build progress text
        if pct > 0 {
            if eta > 0 {
                progressText = "Generando… \(progressPercent)%  — ETA \(String(format: "%.0f", eta))s"
            } else {
                progressText = "Generando… \(progressPercent)%"
            }
            if currentStep > 0 && totalSteps > 0 {
                progressText += "  (\(currentStep)/\(totalSteps) steps)"
            }
        } else {
            progressText = "Iniciando generación…"
        }

        // Live preview image
        if let previewB64 = json["current_image"] as? String,
           !previewB64.isEmpty,
           let imgData = Data(base64Encoded: previewB64),
           let nsImg   = NSImage(data: imgData) {
            previewImage = nsImg
        }
    }
}

// MARK: - GenerationProgressView
// Panel de progreso con preview en tiempo real.

struct GenerationProgressView: View {

    @ObservedObject var monitor = GenerationProgressMonitor.shared
    var onCancel: (() -> Void)? = nil
    var showPreview: Bool = true

    var body: some View {
        VStack(spacing: 12) {

            // Ring + percentage
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.06), lineWidth: 10)
                    .frame(width: 100, height: 100)

                Circle()
                    .trim(from: 0, to: monitor.progress)
                    .stroke(
                        LinearGradient(
                            colors: [Color(hex: "#7c6af7"), Color(hex: "#3de3c0")],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        style: StrokeStyle(lineWidth: 10, lineCap: .round)
                    )
                    .frame(width: 100, height: 100)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.4), value: monitor.progress)

                VStack(spacing: 2) {
                    Text("\(monitor.progressPercent)%")
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    if monitor.eta > 0 {
                        Text("\(String(format: "%.0f", monitor.eta))s")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
            }

            // Progress text
            Text(monitor.progressText)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)

            // Steps detail
            if monitor.totalSteps > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "waveform").font(.system(size: 10)).foregroundColor(.secondary)
                    Text("Step \(monitor.currentStep) / \(monitor.totalSteps)")
                        .font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                    if !monitor.samplerName.isEmpty {
                        Text("·").foregroundColor(.secondary)
                        Text(monitor.samplerName).font(.system(size: 10)).foregroundColor(.secondary)
                    }
                }
            }

            // Live preview image
            if showPreview, let preview = monitor.previewImage {
                Image(nsImage: preview)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 200)
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(hex: "#7c6af7").opacity(0.3), lineWidth: 1)
                    )
                    .transition(.opacity.animation(.easeInOut(duration: 0.3)))
            } else if showPreview && monitor.isPolling {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.04))
                    .frame(height: 160)
                    .overlay(
                        VStack(spacing: 8) {
                            ProgressView().scaleEffect(0.8)
                            Text("Esperando preview…")
                                .font(.system(size: 10)).foregroundColor(.secondary)
                        }
                    )
            }

            // Cancel button
            if let cancel = onCancel {
                Button(action: cancel) {
                    HStack(spacing: 6) {
                        Image(systemName: "stop.fill").font(.system(size: 10))
                        Text("Interrumpir")
                    }
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .background(Color.red.opacity(0.15))
                    .foregroundColor(.red).cornerRadius(6)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}

// MARK: - CompactProgressBar
// Versión compacta para el panel de output (StatusBar area).

struct CompactProgressBar: View {

    @ObservedObject var monitor = GenerationProgressMonitor.shared

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                // Animated spinner dot
                Circle()
                    .fill(Color(hex: "#7c6af7"))
                    .frame(width: 6, height: 6)
                    .opacity(monitor.isPolling ? 1 : 0)

                Text(monitor.progressText.isEmpty ? "Listo" : monitor.progressText)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .animation(nil, value: monitor.progressText)

                Spacer()

                if monitor.progressPercent > 0 {
                    Text("\(monitor.progressPercent)%")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(Color(hex: "#7c6af7"))
                }
            }

            if monitor.isPolling && monitor.progress > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.white.opacity(0.06))
                            .frame(height: 3)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(
                                LinearGradient(
                                    colors: [Color(hex: "#7c6af7"), Color(hex: "#3de3c0")],
                                    startPoint: .leading, endPoint: .trailing
                                )
                            )
                            .frame(width: geo.size.width * monitor.progress, height: 3)
                            .animation(.easeInOut(duration: 0.3), value: monitor.progress)
                    }
                }
                .frame(height: 3)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
}

// MARK: - LivePreviewThumbnail
// Miniatura que muestra el preview en tiempo real en la esquina.

struct LivePreviewThumbnail: View {

    @ObservedObject var monitor = GenerationProgressMonitor.shared
    @State private var isExpanded = false

    var body: some View {
        Group {
            if monitor.isPolling, let preview = monitor.previewImage {
                Button(action: { isExpanded.toggle() }) {
                    Image(nsImage: preview)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 48, height: 48)
                        .clipped()
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(hex: "#7c6af7").opacity(0.5), lineWidth: 1.5)
                        )
                        .shadow(color: .black.opacity(0.4), radius: 4)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $isExpanded, arrowEdge: .leading) {
                    GenerationProgressView(showPreview: true)
                        .frame(width: 280)
                        .padding(8)
                        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
                }
            }
        }
    }
}
