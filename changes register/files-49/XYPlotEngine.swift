import Foundation
import AppKit
import SwiftUI
import Combine

// MARK: - XYPlotEngine
//
// Motor de exploración matricial X/Y(/Z) para Stable Diffusion.
// Genera una grilla de imágenes variando dos o tres parámetros:
//   - Steps × CFG Scale
//   - Sampler × Seed
//   - Checkpoint × LoRA weight
//   - Prompt variant × Seed
//   - Denoising × Steps (para img2img)
//   - Cualquier combinación definida por el usuario
//
// Integra con BatchEngine para la ejecución y AssetStore para persistencia.
// La grilla resultante se renderiza como una imagen compuesta y se guarda en Vault.
//
// ROADMAP: "X/Y/Z Plot integration" (🟡 MEDIO PLAZO)

// MARK: - Models

enum XYAxis: String, Codable, CaseIterable, Identifiable {
    case steps           = "Steps"
    case cfgScale        = "CFG Scale"
    case seed            = "Seed"
    case sampler         = "Sampler"
    case checkpoint      = "Checkpoint"
    case denoise         = "Denoising"
    case loraWeight      = "LoRA Weight"
    case promptVariant   = "Prompt Variant"
    case width           = "Width"
    case height          = "Height"

    var id: String { rawValue }

    var defaultValues: [String] {
        switch self {
        case .steps:          return ["15", "20", "28", "35"]
        case .cfgScale:       return ["5", "7", "9", "12"]
        case .seed:           return ["-1", "-1", "-1", "-1"]
        case .sampler:        return ["DPM++ 2M Karras", "Euler a", "DDIM", "DPM++ SDE Karras"]
        case .checkpoint:     return []
        case .denoise:        return ["0.3", "0.5", "0.7", "0.9"]
        case .loraWeight:     return ["0.4", "0.6", "0.8", "1.0"]
        case .promptVariant:  return []
        case .width:          return ["512", "640", "768", "1024"]
        case .height:         return ["512", "640", "768", "1024"]
        }
    }
}

struct XYPlotConfig: Codable, Identifiable {
    var id:       UUID   = UUID()
    var name:     String = "X/Y Plot"
    var createdAt: Date  = Date()

    var xAxis:    XYAxis = .steps
    var xValues:  [String] = XYAxis.steps.defaultValues

    var yAxis:    XYAxis = .cfgScale
    var yValues:  [String] = XYAxis.cfgScale.defaultValues

    var zAxis:    XYAxis? = nil
    var zValues:  [String] = []

    // Total de combinaciones
    var totalCount: Int {
        let base = xValues.count * yValues.count
        return zAxis != nil ? base * max(1, zValues.count) : base
    }

    // Límite de seguridad
    var isOverLimit: Bool { totalCount > 64 }
}

struct XYPlotResult: Identifiable {
    let id         = UUID()
    let config:    XYPlotConfig
    let images:    [[NSImage]]          // [yIndex][xIndex]
    let compositeImage: NSImage?
    let generatedAt: Date = Date()
    var assetPath: String? = nil
}

// MARK: - XYPlotEngine

@MainActor
final class XYPlotEngine: ObservableObject {

    static let shared = XYPlotEngine()
    private init() {}

    // MARK: - State

    @Published var isRunning:      Bool          = false
    @Published var progress:       Double        = 0     // 0…1
    @Published var progressText:   String        = ""
    @Published var completedCount: Int           = 0
    @Published var lastResult:     XYPlotResult? = nil
    @Published var history:        [XYPlotResult] = []

    private var cancelRequested = false

    // MARK: - Public API

    func cancel() {
        cancelRequested = true
    }

    /// Ejecutar el plot completo.
    func run(
        config:       XYPlotConfig,
        baseSettings: GenerationSettings,
        basePrompt:   String,
        sdService:    SDService
    ) async {

        guard !config.xValues.isEmpty, !config.yValues.isEmpty else { return }
        guard !config.isOverLimit else {
            progressText = "⚠️ Límite excedido (\(config.totalCount) imágenes). Máx 64."
            return
        }

        isRunning      = true
        cancelRequested = false
        completedCount  = 0
        let total       = config.totalCount
        progress        = 0
        progressText    = "Iniciando X/Y Plot (\(total) imágenes)…"

        // Estructurar imágenes en grilla [yIndex][xIndex]
        var grid: [[NSImage]] = Array(
            repeating: Array(repeating: NSImage(), count: config.xValues.count),
            count: config.yValues.count
        )

        for (yi, yVal) in config.yValues.enumerated() {
            if cancelRequested { break }
            for (xi, xVal) in config.xValues.enumerated() {
                if cancelRequested { break }

                progressText = "Generando [\(xi+1)/\(config.xValues.count)] × [\(yi+1)/\(config.yValues.count)] — \(config.xAxis.rawValue):\(xVal) / \(config.yAxis.rawValue):\(yVal)"

                var settings = baseSettings
                var prompt   = basePrompt

                applyAxisValue(config.xAxis, value: xVal, settings: &settings, prompt: &prompt)
                applyAxisValue(config.yAxis, value: yVal, settings: &settings, prompt: &prompt)

                let req = buildRequest(settings: settings, prompt: prompt)
                await sdService.generate(request: req, baseURL: baseSettings.sdBaseURL)

                if let img = sdService.generatedImage {
                    grid[yi][xi] = img
                }

                completedCount += 1
                progress = Double(completedCount) / Double(total)
            }
        }

        if cancelRequested {
            progressText = "Plot cancelado (\(completedCount)/\(total))"
            isRunning = false
            return
        }

        // Componer grilla en imagen única
        progressText = "Componiendo grilla…"
        let composite = await Task.detached(priority: .userInitiated) {
            await MainActor.run {
            composeGrid(
                images:  grid,
                xLabels: config.xValues,
                yLabels: config.yValues,
                xAxisLabel: config.xAxis.rawValue,
                yAxisLabel: config.yAxis.rawValue
            )
            }
        }.value

        let result = XYPlotResult(
            config:         config,
            images:         grid,
            compositeImage: composite
        )

        // Guardar imagen compuesta en vault
        if let composite,
           let pngData = composite.pngData(),
           let dir = VaultManager.shared.vaultMetaURL?.appending(path: "XYPlots") {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let fname = "xyplot_\(Int(Date().timeIntervalSince1970)).png"
            let url   = dir.appending(path: fname)
            try? pngData.write(to: url, options: .atomic)
        }

        lastResult = result
        history.insert(result, at: 0)
        if history.count > 20 { history = Array(history.prefix(20)) }

        progressText = "✓ X/Y Plot completado — \(completedCount) imágenes"
        isRunning = false
    }

    // MARK: - Axis Application

    private func applyAxisValue(
        _ axis: XYAxis,
        value: String,
        settings: inout GenerationSettings,
        prompt: inout String
    ) {
        switch axis {
        case .steps:
            settings.steps = Int(value) ?? settings.steps
        case .cfgScale:
            settings.cfgScale = Double(value) ?? settings.cfgScale
        case .seed:
            settings.seed = Int(value) ?? -1
        case .sampler:
            settings.samplerName = value
        case .checkpoint:
            settings.checkpoint = value
        case .denoise:
            settings.denoisingStrength = Double(value) ?? settings.denoisingStrength
        case .loraWeight:
            // Aplica el peso al primer LoRA seleccionado
            if let first = LoRAManager.shared.selectedLoRAs.first {
                LoRAManager.shared.updateWeight(id: first.id, weight: Double(value) ?? 0.8)
            }
            prompt = LoRAManager.shared.inject(into: prompt)
        case .promptVariant:
            prompt = value
        case .width:
            settings.width = Int(value) ?? settings.width
        case .height:
            settings.height = Int(value) ?? settings.height
        }
    }

    private func buildRequest(settings: GenerationSettings, prompt: String) -> SDRequest {
        SDRequest(
            prompt:            prompt,
            negativePrompt:    settings.negativePrompt,
            seed:              settings.seed,
            steps:             settings.steps,
            cfgScale:          settings.cfgScale,
            width:             settings.width,
            height:            settings.height,
            samplerName:       settings.samplerName,
            enableHR:          false,   // HiRes off en plots para velocidad
            denoisingStrength: settings.denoisingStrength,
            restoreFaces:      false
        )
    }
}

// MARK: - Grid Composition (nonisolated para Task.detached)

private func composeGrid(
    images: [[NSImage]],
    xLabels: [String],
    yLabels: [String],
    xAxisLabel: String,
    yAxisLabel: String
) -> NSImage? {

    guard !images.isEmpty, !images[0].isEmpty else { return nil }

    let cellW: CGFloat    = images[0][0].size.width.clamped(to: 128...512)
    let cellH: CGFloat    = images[0][0].size.height.clamped(to: 128...512)
    let labelW: CGFloat   = 80
    let labelH: CGFloat   = 36
    let cols  = images[0].count
    let rows  = images.count

    let totalW = labelW + CGFloat(cols) * cellW
    let totalH = labelH + CGFloat(rows) * cellH

    let resultImage = NSImage(size: CGSize(width: totalW, height: totalH))
    resultImage.lockFocus()

    // Background
    NSColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1).setFill()
    NSRect(origin: .zero, size: CGSize(width: totalW, height: totalH)).fill()

    // Draw cells
    for (ri, row) in images.enumerated() {
        for (ci, img) in row.enumerated() {
            let x = labelW + CGFloat(ci) * cellW
            let y = totalH - labelH - CGFloat(ri + 1) * cellH
            img.draw(in: NSRect(x: x, y: y, width: cellW, height: cellH))
        }
    }

    // X labels
    let labelAttrs: [NSAttributedString.Key: Any] = [
        .font:            NSFont.monospacedSystemFont(ofSize: 9, weight: .medium),
        .foregroundColor: NSColor.white.withAlphaComponent(0.6)
    ]
    for (ci, label) in xLabels.enumerated() {
        let x = labelW + CGFloat(ci) * cellW + cellW / 2 - 30
        let y = totalH - labelH + 8
        (label as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: labelAttrs)
    }

    // Y labels
    for (ri, label) in yLabels.enumerated() {
        let x: CGFloat = 4
        let y = totalH - labelH - CGFloat(ri + 1) * cellH + cellH / 2 - 6
        (label as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: labelAttrs)
    }

    resultImage.unlockFocus()
    return resultImage
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - XYPlotView

struct XYPlotView: View {

    @StateObject private var engine = XYPlotEngine.shared
    @ObservedObject var sdService: SDService
    var settings: GenerationSettings
    var parsedPrompt: String

    @State private var config = XYPlotConfig()
    @State private var showConfig = true

    var body: some View {
        VStack(spacing: 0) {

            // Header
            HStack(spacing: 10) {
                Image(systemName: "grid.circle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: "#7c6af7"))
                Text("X/Y Plot Explorer")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Button(action: { showConfig.toggle() }) {
                    Image(systemName: showConfig ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color.white.opacity(0.03))

            Divider().background(Color.white.opacity(0.06))

            if showConfig {
                configPanel
            }

            Divider().background(Color.white.opacity(0.06))

            if engine.isRunning {
                runningPanel
            } else if let result = engine.lastResult {
                resultPanel(result)
            } else {
                emptyState
            }
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
    }

    // MARK: - Config Panel

    var configPanel: some View {
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                axisSelector(label: "Eje X", axis: $config.xAxis, values: $config.xValues)
                axisSelector(label: "Eje Y", axis: $config.yAxis, values: $config.yValues)
            }

            // Info + Run button
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(config.totalCount) imágenes")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(config.isOverLimit ? Color(hex: "#ef4444") : .white)
                    if config.isOverLimit {
                        Text("Máximo 64 por seguridad")
                            .font(.system(size: 9))
                            .foregroundColor(Color(hex: "#ef4444"))
                    }
                }
                Spacer()
                Button(action: {
                    Task {
                        await engine.run(
                            config:       config,
                            baseSettings: settings,
                            basePrompt:   parsedPrompt,
                            sdService:    sdService
                        )
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10))
                        Text("Ejecutar Plot")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(config.isOverLimit ? Color.gray : Color(hex: "#7c6af7"))
                    .foregroundColor(.white).cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(config.isOverLimit || parsedPrompt.isEmpty)
            }
        }
        .padding(14)
    }

    func axisSelector(label: String, axis: Binding<XYAxis>, values: Binding<[String]>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)

            Picker(label, selection: axis) {
                ForEach(XYAxis.allCases) { a in
                    Text(a.rawValue).tag(a)
                }
            }
            .pickerStyle(.menu).labelsHidden()
            .onChange(of: axis.wrappedValue) { _, newAxis in
                values.wrappedValue = newAxis.defaultValues
            }

            // Values editor mini (comma-separated)
            let binding = Binding<String>(
                get:  { values.wrappedValue.joined(separator: ", ") },
                set:  { values.wrappedValue = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
            )
            TextField("Valores (separados por coma)", text: binding)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 10, design: .monospaced))
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Running Panel

    var runningPanel: some View {
        VStack(spacing: 16) {
            ProgressView(value: engine.progress)
                .progressViewStyle(.linear)
                .tint(Color(hex: "#7c6af7"))
                .padding(.horizontal, 20)

            Text(engine.progressText)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Text("\(engine.completedCount)/\(config.totalCount)")
                .font(.system(size: 24, weight: .bold, design: .monospaced))
                .foregroundColor(.white)

            Button(action: { engine.cancel() }) {
                Label("Cancelar", systemImage: "stop.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Result Panel

    func resultPanel(_ result: XYPlotResult) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Resultado: \(result.config.xAxis.rawValue) × \(result.config.yAxis.rawValue)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                if let img = result.compositeImage {
                    Button(action: {
                        let panel = NSSavePanel()
                        panel.nameFieldStringValue = "xyplot.png"
                        panel.allowedContentTypes = [.png]
                        if panel.runModal() == .OK, let url = panel.url,
                           let data = img.pngData() {
                            try? data.write(to: url)
                        }
                    }) {
                        Label("Exportar", systemImage: "square.and.arrow.down")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(Color(hex: "#7c6af7"))
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)

            if let composite = result.compositeImage {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: composite)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(8)
                }
            }
        }
    }

    var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "grid.circle")
                .font(.system(size: 40))
                .foregroundColor(.white.opacity(0.08))
            Text("Configura los ejes y ejecuta el plot")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
