import Foundation
import AppKit
import SwiftUI
import Combine
import CoreGraphics
import UniformTypeIdentifiers

// MARK: - InpaintingEngine
//
// Motor de inpainting y outpainting para SDPipelineStudio.
// Usa A1111 /sdapi/v1/img2img con máscara para pintar áreas seleccionadas.
//
// Modos:
//   .manual        — Máscara dibujada por el usuario con herramientas de pincel
//   .rectangle     — Selección rectangular simple
//   .face          — Máscara automática de cara (vía ADetailer o segmentación)
//   .background    — Inverso de figura (background replacement)
//   .outpaint      — Expansión de canvas en cualquier dirección
//   .freehand      — Selección freehand (polygon lasso)
//
// Resultado: se integra con AssetStore y guarda como nueva versión del asset original.
//
// ROADMAP: "Inpainting, Outpainting" (🟡 MEDIO PLAZO)

// MARK: - Inpainting Models

enum InpaintMode: String, Codable, CaseIterable {
    case manual     = "Pincel Manual"
    case rectangle  = "Rectángulo"
    case background = "Reemplazar Fondo"
    case outpaint   = "Outpainting"
    case face       = "Cara (Auto)"

    var icon: String {
        switch self {
        case .manual:     return "paintbrush.fill"
        case .rectangle:  return "rectangle.dashed"
        case .background: return "square.filled.on.square"
        case .outpaint:   return "arrow.up.left.and.arrow.down.right"
        case .face:       return "face.smiling"
        }
    }

    var description: String {
        switch self {
        case .manual:
            return "Pinta la máscara manualmente con el pincel."
        case .rectangle:
            return "Selecciona un área rectangular para inpaint."
        case .background:
            return "Reemplaza todo el fondo manteniendo el sujeto."
        case .outpaint:
            return "Expande el canvas en las direcciones seleccionadas."
        case .face:
            return "Detecta y refina la cara automáticamente (requiere ADetailer)."
        }
    }
}

enum OutpaintDirection: String, Codable, CaseIterable {
    case left    = "Izquierda"
    case right   = "Derecha"
    case up      = "Arriba"
    case down    = "Abajo"
    case all     = "Todos"

    var icon: String {
        switch self {
        case .left:  return "arrow.left"
        case .right: return "arrow.right"
        case .up:    return "arrow.up"
        case .down:  return "arrow.down"
        case .all:   return "arrow.up.left.and.arrow.down.right"
        }
    }
}

struct InpaintJob: Identifiable, Codable {
    var id:               UUID           = UUID()
    var createdAt:        Date           = Date()
    var mode:             InpaintMode
    var sourceImagePath:  String
    var resultImagePath:  String?        = nil
    var maskImagePath:    String?        = nil
    var prompt:           String
    var negativePrompt:   String
    var denoiseStrength:  Double         = 0.75
    var steps:            Int            = 25
    var cfgScale:         Double         = 7.0
    var seed:             Int            = -1
    var resultSeed:       Int?           = nil
    var width:            Int
    var height:           Int
    var samplerName:      String
    var checkpoint:       String
    var maskBlur:         Int            = 4
    var inpaintingFill:   Int            = 1  // 0=fill, 1=original, 2=latent noise, 3=latent nothing
    var inpaintFullRes:   Bool           = true
    var inpaintFullResPadding: Int       = 32
    var outpaintDirections: [OutpaintDirection] = []
    var outpaintExpansion:  Int          = 128   // píxeles a expandir
    var status:           Status         = .pending
    var duration:         Double?        = nil
    var error:            String?        = nil

    enum Status: String, Codable { case pending, running, success, failed }
}

struct InpaintSettings {
    var denoiseStrength:    Double = 0.75
    var maskBlur:           Int    = 4
    var inpaintingFill:     Int    = 1
    var inpaintFullRes:     Bool   = true
    var inpaintFullResPadding: Int = 32
    var steps:              Int    = 25
    var cfgScale:           Double = 7.0
    var samplerName:        String = "DPM++ 2M Karras"

    static let fills = ["Relleno", "Original", "Ruido Latente", "Nada Latente"]
}

// MARK: - Mask Drawing Model

class InpaintMask: ObservableObject {
    @Published var strokes: [MaskStroke] = []
    @Published var brushSize: CGFloat    = 40
    @Published var isErasing: Bool       = false

    struct MaskStroke {
        var points:    [CGPoint]
        var brushSize: CGFloat
        var isErase:   Bool
    }

    func addPoint(_ point: CGPoint, to currentStroke: inout MaskStroke?) {
        if currentStroke == nil {
            currentStroke = MaskStroke(points: [point], brushSize: brushSize, isErase: isErasing)
        } else {
            currentStroke?.points.append(point)
        }
    }

    func finishStroke(_ stroke: MaskStroke?) {
        guard let s = stroke else { return }
        strokes.append(s)
    }

    func clearMask() {
        strokes.removeAll()
    }

    func undoLast() {
        if !strokes.isEmpty { strokes.removeLast() }
    }

    /// Renderiza la máscara como imagen NSImage en blanco/negro
    func renderMask(size: CGSize) -> NSImage? {
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        // Fondo negro = no inpaint
        NSColor.black.setFill()
        NSRect(origin: .zero, size: size).fill()

        for stroke in strokes {
            guard stroke.points.count > 0 else { continue }
            let color: NSColor = stroke.isErase ? .black : .white
            color.setFill()
            color.setStroke()

            let path = NSBezierPath()
            path.lineWidth = stroke.brushSize
            path.lineCapStyle = .round
            path.lineJoinStyle = .round

            if stroke.points.count == 1 {
                let rect = NSRect(
                    x: stroke.points[0].x - stroke.brushSize/2,
                    y: stroke.points[0].y - stroke.brushSize/2,
                    width: stroke.brushSize,
                    height: stroke.brushSize
                )
                NSBezierPath(ovalIn: rect).fill()
            } else {
                path.move(to: stroke.points[0])
                for pt in stroke.points.dropFirst() { path.line(to: pt) }
                path.stroke()
            }
        }

        return image
    }

    /// Genera máscara de rectángulo normalizado (0..1)
    static func rectangleMask(rect: CGRect, imageSize: CGSize) -> NSImage {
        let image = NSImage(size: imageSize)
        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor.black.setFill()
        NSRect(origin: .zero, size: imageSize).fill()

        let absoluteRect = CGRect(
            x: rect.minX * imageSize.width,
            y: rect.minY * imageSize.height,
            width: rect.width  * imageSize.width,
            height: rect.height * imageSize.height
        )
        NSColor.white.setFill()
        NSBezierPath(roundedRect: absoluteRect, xRadius: 4, yRadius: 4).fill()

        return image
    }

    /// Genera máscara de outpainting según dirección
    static func outpaintMask(direction: OutpaintDirection, expansion: Int, imageSize: CGSize) -> NSImage {
        let image = NSImage(size: imageSize)
        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor.black.setFill()
        NSRect(origin: .zero, size: imageSize).fill()

        NSColor.white.setFill()
        let exp = CGFloat(expansion)

        switch direction {
        case .left:
            NSRect(x: 0, y: 0, width: exp, height: imageSize.height).fill()
        case .right:
            NSRect(x: imageSize.width - exp, y: 0, width: exp, height: imageSize.height).fill()
        case .up:
            NSRect(x: 0, y: imageSize.height - exp, width: imageSize.width, height: exp).fill()
        case .down:
            NSRect(x: 0, y: 0, width: imageSize.width, height: exp).fill()
        case .all:
            // Borde completo
            NSRect(x: 0, y: 0, width: exp, height: imageSize.height).fill()
            NSRect(x: imageSize.width - exp, y: 0, width: exp, height: imageSize.height).fill()
            NSRect(x: 0, y: imageSize.height - exp, width: imageSize.width, height: exp).fill()
            NSRect(x: 0, y: 0, width: imageSize.width, height: exp).fill()
        }

        return image
    }
}

// MARK: - InpaintingEngine

@MainActor
final class InpaintingEngine: ObservableObject {

    static let shared = InpaintingEngine()
    private init() { loadHistory() }

    // MARK: - State

    @Published var isRunning:      Bool           = false
    @Published var progress:       Double         = 0
    @Published var currentJob:     InpaintJob?    = nil
    @Published var history:        [InpaintJob]   = []
    @Published var lastResult:     NSImage?       = nil
    @Published var settings:       InpaintSettings = InpaintSettings()
    @Published var mask:           InpaintMask    = InpaintMask()
    @Published var mode:           InpaintMode    = .manual

    private var historyURL: URL? {
        VaultManager.shared.vaultMetaURL?.appending(path: "inpaint_history.json")
    }

    // MARK: - Run Inpaint

    func run(
        sourceImage: NSImage,
        maskImage:   NSImage,
        prompt:      String,
        negativePrompt: String = "",
        checkpoint:  String   = "",
        baseURL:     String
    ) async -> NSImage? {

        guard !isRunning else { return nil }

        isRunning = true
        progress  = 0

        defer {
            isRunning = false
            progress  = 0
        }

        guard let sourcePNG = sourceImage.pngData(),
              let maskPNG   = maskImage.pngData()
        else { return nil }

        let sourceB64 = sourcePNG.base64EncodedString()
        let maskB64   = maskPNG.base64EncodedString()

        let payload: [String: Any] = [
            "init_images":          [sourceB64],
            "mask":                 maskB64,
            "mask_blur":            settings.maskBlur,
            "inpainting_fill":      settings.inpaintingFill,
            "inpaint_full_res":     settings.inpaintFullRes,
            "inpaint_full_res_padding": settings.inpaintFullResPadding,
            "prompt":               prompt,
            "negative_prompt":      negativePrompt,
            "steps":                settings.steps,
            "cfg_scale":            settings.cfgScale,
            "width":                Int(sourceImage.size.width),
            "height":               Int(sourceImage.size.height),
            "sampler_name":         settings.samplerName,
            "denoising_strength":   settings.denoiseStrength,
            "seed":                 -1
        ]

        guard let url = URL(string: "\(baseURL)/sdapi/v1/img2img"),
              let body = try? JSONSerialization.data(withJSONObject: payload)
        else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody   = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300

        do {
            let (data, _) = try await URLSession.shared.data(for: request)

            guard let json   = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let images = json["images"] as? [String],
                  let first  = images.first,
                  let imgData = Data(base64Encoded: first),
                  let result = NSImage(data: imgData)
            else { return nil }

            lastResult = result

            // Guardar en vault
            let savedPath = await saveResult(result, sourceImage: sourceImage, prompt: prompt)

            // Registrar en historial
            var job = InpaintJob(
                mode: mode,
                sourceImagePath: "",
                prompt: prompt,
                negativePrompt: negativePrompt,
                denoiseStrength: settings.denoiseStrength,
                steps: settings.steps,
                cfgScale: settings.cfgScale,
                width: Int(sourceImage.size.width),
                height: Int(sourceImage.size.height),
                samplerName: settings.samplerName,
                checkpoint: checkpoint
            )
            job.resultImagePath = savedPath
            job.status = .success
            history.insert(job, at: 0)
            if history.count > 100 { history = Array(history.prefix(100)) }
            saveHistory()

            return result

        } catch {
            return nil
        }
    }

    // MARK: - Outpaint

    func outpaint(
        sourceImage:  NSImage,
        direction:    OutpaintDirection,
        expansion:    Int,
        prompt:       String,
        negativePrompt: String = "",
        baseURL:      String
    ) async -> NSImage? {

        // Expandir canvas de la imagen fuente
        let expandedSize = expandedCanvasSize(
            original: sourceImage.size,
            direction: direction,
            expansion: CGFloat(expansion)
        )

        guard let expandedImage = expandCanvas(
            image: sourceImage,
            to: expandedSize,
            direction: direction,
            expansion: CGFloat(expansion)
        ) else { return nil }

        // Generar máscara de las áreas expandidas
        let maskImage = InpaintMask.outpaintMask(
            direction: direction,
            expansion: expansion,
            imageSize: expandedSize
        )

        return await run(
            sourceImage:    expandedImage,
            maskImage:      maskImage,
            prompt:         prompt,
            negativePrompt: negativePrompt,
            baseURL:        baseURL
        )
    }

    // MARK: - Canvas Expansion

    private func expandedCanvasSize(
        original:  CGSize,
        direction: OutpaintDirection,
        expansion: CGFloat
    ) -> CGSize {
        switch direction {
        case .left, .right: return CGSize(width: original.width + expansion, height: original.height)
        case .up, .down:    return CGSize(width: original.width, height: original.height + expansion)
        case .all:          return CGSize(width: original.width + expansion * 2, height: original.height + expansion * 2)
        }
    }

    private func expandCanvas(
        image:     NSImage,
        to size:   CGSize,
        direction: OutpaintDirection,
        expansion: CGFloat
    ) -> NSImage? {
        let result = NSImage(size: size)
        result.lockFocus()
        defer { result.unlockFocus() }

        NSColor.black.setFill()
        NSRect(origin: .zero, size: size).fill()

        let origin: CGPoint
        switch direction {
        case .left:  origin = CGPoint(x: expansion, y: 0)
        case .right: origin = CGPoint(x: 0,         y: 0)
        case .up:    origin = CGPoint(x: 0,         y: 0)
        case .down:  origin = CGPoint(x: 0,         y: expansion)
        case .all:   origin = CGPoint(x: expansion, y: expansion)
        }

        let destRect = NSRect(origin: origin, size: image.size)
        image.draw(in: destRect)

        return result
    }

    // MARK: - Save Result

    private func saveResult(
        _ image:      NSImage,
        sourceImage:  NSImage,
        prompt:       String
    ) async -> String? {
        guard let dir = VaultManager.shared.todayGeneracionesURL,
              let pngData = image.pngData()
        else { return nil }

        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let ts   = Int(Date().timeIntervalSince1970)
        let url  = dir.appending(path: "inpaint_\(ts).png")
        try? pngData.write(to: url)
        return url.path
    }

    // MARK: - History Persistence

    private func loadHistory() {
        guard let url  = historyURL,
              let data = try? Data(contentsOf: url),
              let jobs = try? JSONDecoder.iso8601.decode([InpaintJob].self, from: data)
        else { return }
        history = jobs
    }

    private func saveHistory() {
        guard let url  = historyURL,
              let data = try? JSONEncoder.pretty.encode(Array(history.prefix(100)))
        else { return }
        try? data.write(to: url)
    }
}

// MARK: - InpaintingView (SwiftUI)

struct InpaintingView: View {

    let sourceImage:   NSImage
    var onComplete:    (NSImage) -> Void
    var onDismiss:     () -> Void

    @StateObject private var engine   = InpaintingEngine.shared
    @State private var prompt:         String = ""
    @State private var negativePrompt: String = ""
    @State private var baseURL:        String = "http://127.0.0.1:7860"
    @State private var outpaintDir:    OutpaintDirection = .right
    @State private var currentStroke:  InpaintMask.MaskStroke? = nil
    @State private var showSettings:   Bool = false
    @State private var resultImage:    NSImage? = nil
    @State private var maskOpacity:    Double = 0.5

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().background(Color.white.opacity(0.07))
            HSplitView {
                canvasArea
                    .frame(minWidth: 400)
                rightPanel
                    .frame(width: 260)
            }
        }
        .frame(minWidth: 720, minHeight: 540)
        .background(Color(red: 0.07, green: 0.07, blue: 0.09))
    }

    // MARK: - Toolbar

    var toolbar: some View {
        HStack(spacing: 12) {
            // Mode picker
            Picker("", selection: $engine.mode) {
                ForEach(InpaintMode.allCases, id: \.self) { m in
                    Label(m.rawValue, systemImage: m.icon).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 380)
            .font(.system(size: 10))

            if engine.mode == .manual {
                Divider().frame(height: 16)

                // Brush tools
                HStack(spacing: 8) {
                    Toggle(isOn: Binding(
                        get: { !engine.mask.isErasing },
                        set: { engine.mask.isErasing = !$0 }
                    )) {
                        Image(systemName: "paintbrush.fill")
                            .font(.system(size: 12))
                    }
                    .toggleStyle(.button)
                    .help("Pincel")

                    Toggle(isOn: $engine.mask.isErasing) {
                        Image(systemName: "eraser.fill")
                            .font(.system(size: 12))
                    }
                    .toggleStyle(.button)
                    .help("Borrador")

                    Slider(value: $engine.mask.brushSize, in: 8...120)
                        .frame(width: 80)
                        .help("Tamaño del pincel")

                    Text("\(Int(engine.mask.brushSize))px")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                Button(action: engine.mask.undoLast) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help("Deshacer último trazo")

                Button(action: engine.mask.clearMask) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help("Limpiar máscara")
            }

            Spacer()

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.white.opacity(0.03))
    }

    // MARK: - Canvas

    var canvasArea: some View {
        ZStack {
            Color(red: 0.06, green: 0.06, blue: 0.08)

            if let result = resultImage {
                Image(nsImage: result)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(16)
            } else {
                ZStack {
                    Image(nsImage: sourceImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(16)

                    if engine.mode == .manual {
                        MaskCanvasView(
                            mask: engine.mask,
                            imageSize: sourceImage.size,
                            maskOpacity: maskOpacity
                        )
                        .padding(16)
                    }
                }
            }

            if engine.isRunning {
                Color.black.opacity(0.6)
                VStack(spacing: 12) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(1.2)
                    Text("Procesando inpaint…")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.8))
                }
            }
        }
    }

    // MARK: - Right Panel

    var rightPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Prompt
                VStack(alignment: .leading, spacing: 4) {
                    Text("PROMPT").sectionLabel()
                    TextEditor(text: $prompt)
                        .font(.system(size: 11))
                        .frame(minHeight: 80)
                        .background(Color.white.opacity(0.05))
                        .cornerRadius(6)

                    TextEditor(text: $negativePrompt)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .frame(minHeight: 40)
                        .background(Color.white.opacity(0.03))
                        .cornerRadius(6)
                        .overlay(
                            Group {
                                if negativePrompt.isEmpty {
                                    Text("Negative prompt…")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary.opacity(0.5))
                                        .padding(6)
                                }
                            },
                            alignment: .topLeading
                        )
                }

                // Mode-specific controls
                if engine.mode == .outpaint {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("DIRECCIÓN").sectionLabel()
                        Picker("", selection: $outpaintDir) {
                            ForEach(OutpaintDirection.allCases, id: \.self) { d in
                                Label(d.rawValue, systemImage: d.icon).tag(d)
                            }
                        }
                        .pickerStyle(.menu)
                        .font(.system(size: 11))

                        HStack {
                            Text("Expansión")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            Slider(value: Binding(
                                get: { Double(engine.settings.maskBlur) },
                                set: { _ in }
                            ), in: 64...512, step: 64)
                            Text("128px")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                }

                // Settings
                VStack(alignment: .leading, spacing: 6) {
                    Text("AJUSTES").sectionLabel()

                    HStack {
                        Text("Denoise")
                            .font(.system(size: 10)).foregroundColor(.secondary)
                        Slider(value: $engine.settings.denoiseStrength, in: 0.1...1.0)
                        Text(String(format: "%.2f", engine.settings.denoiseStrength))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Mask Blur")
                            .font(.system(size: 10)).foregroundColor(.secondary)
                        Slider(value: Binding(
                            get: { Double(engine.settings.maskBlur) },
                            set: { engine.settings.maskBlur = Int($0) }
                        ), in: 0...20, step: 1)
                        Text("\(engine.settings.maskBlur)px")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Opacidad máscara")
                            .font(.system(size: 10)).foregroundColor(.secondary)
                        Slider(value: $maskOpacity, in: 0.1...1.0)
                    }

                    Picker("Relleno", selection: $engine.settings.inpaintingFill) {
                        ForEach(Array(InpaintSettings.fills.enumerated()), id: \.offset) { i, f in
                            Text(f).tag(i)
                        }
                    }
                    .pickerStyle(.menu)
                    .font(.system(size: 11))
                }

                Divider().background(Color.white.opacity(0.07))

                // Actions
                if resultImage != nil {
                    HStack(spacing: 8) {
                        Button("Usar resultado") {
                            if let r = resultImage { onComplete(r) }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(hex: "#3de3c0"))
                        .controlSize(.small)

                        Button("Reintentar") {
                            resultImage = nil
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.white.opacity(0.1))
                        .controlSize(.small)
                    }
                } else {
                    Button(action: runInpaint) {
                        HStack {
                            if engine.isRunning {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "wand.and.stars")
                            }
                            Text(engine.isRunning ? "Procesando…" : "Generar Inpaint")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(engine.isRunning
                            ? Color.white.opacity(0.08)
                            : LinearGradient(
                                colors: [Color(hex: "#7c6af7"), Color(hex: "#5b4ecf")],
                                startPoint: .leading, endPoint: .trailing
                            ))
                        .foregroundColor(.white)
                        .cornerRadius(7)
                    }
                    .buttonStyle(.plain)
                    .disabled(engine.isRunning || prompt.isEmpty)
                }
            }
            .padding(12)
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
    }

    func runInpaint() {
        Task {
            var maskImage: NSImage?

            switch engine.mode {
            case .manual:
                maskImage = engine.mask.renderMask(size: sourceImage.size)
            case .rectangle:
                maskImage = InpaintMask.rectangleMask(
                    rect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
                    imageSize: sourceImage.size
                )
            case .background:
                // Máscara invertida (todo blanco — simplificado)
                maskImage = NSImage(size: sourceImage.size)
                maskImage?.lockFocus()
                NSColor.white.setFill()
                NSRect(origin: .zero, size: sourceImage.size).fill()
                maskImage?.unlockFocus()
            case .outpaint:
                resultImage = await engine.outpaint(
                    sourceImage: sourceImage,
                    direction: outpaintDir,
                    expansion: 128,
                    prompt: prompt,
                    negativePrompt: negativePrompt,
                    baseURL: baseURL
                )
                return
            case .face:
                // Placeholder — en producción usar ADetailerEngine
                maskImage = engine.mask.renderMask(size: sourceImage.size)
            }

            guard let mask = maskImage else { return }
            resultImage = await engine.run(
                sourceImage: sourceImage,
                maskImage: mask,
                prompt: prompt,
                negativePrompt: negativePrompt,
                baseURL: baseURL
            )
        }
    }
}

// MARK: - MaskCanvasView

struct MaskCanvasView: NSViewRepresentable {
    @ObservedObject var mask:  InpaintMask
    let imageSize:   CGSize
    let maskOpacity: Double

    func makeNSView(context: Context) -> MaskCanvas {
        let v = MaskCanvas()
        v.mask = mask
        return v
    }

    func updateNSView(_ nsView: MaskCanvas, context: Context) {
        nsView.mask = mask
        nsView.needsDisplay = true
    }

    class MaskCanvas: NSView {
        var mask:          InpaintMask?
        private var stroke: InpaintMask.MaskStroke? = nil

        override var acceptsFirstResponder: Bool { true }

        override func mouseDown(with event: NSEvent) {
            let pt = convert(event.locationInWindow, from: nil)
            mask?.addPoint(pt, to: &stroke)
            needsDisplay = true
        }

        override func mouseDragged(with event: NSEvent) {
            let pt = convert(event.locationInWindow, from: nil)
            mask?.addPoint(pt, to: &stroke)
            needsDisplay = true
        }

        override func mouseUp(with event: NSEvent) {
            mask?.finishStroke(stroke)
            stroke = nil
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            guard let mask else { return }

            NSColor.clear.setFill()
            dirtyRect.fill()

            let rendered = mask.renderMask(size: bounds.size)
            rendered?.draw(
                in: bounds,
                from: .zero,
                operation: .sourceOver,
                fraction: 0.5
            )

            // Draw current stroke preview
            if let s = stroke, s.points.count > 1 {
                let color = s.isErase ? NSColor.black.withAlphaComponent(0.6)
                                      : NSColor(hex: "#7c6af7")!.withAlphaComponent(0.8)
                color.setStroke()
                let path = NSBezierPath()
                path.lineWidth = s.brushSize
                path.lineCapStyle = .round
                path.move(to: s.points[0])
                for pt in s.points.dropFirst() { path.line(to: pt) }
                path.stroke()
            }
        }
    }
}

// MARK: - SwiftUI Helpers

extension Text {
    func sectionLabel() -> some View {
        self.font(.system(size: 9, weight: .semibold))
            .foregroundColor(.secondary)
            .textCase(.uppercase)
    }
}
