import Foundation
import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers

// MARK: - InpaintingEngine
//
// Pipeline completo de Inpainting y Outpainting vía A1111 /sdapi/v1/img2img.
//
// Modos:
//   .inpaint     — Rellenar zona enmascarada con nueva generación
//   .inpaintFill — Inpaint + fill con contenido original (smooth blend)
//   .outpaint    — Extender canvas hacia los bordes
//   .objectErase — Borrar objeto (mask) y rellenar con fondo
//
// La máscara es una imagen PNG en escala de grises:
//   - Blanco (255) = zona a modificar
//   - Negro (0)    = zona a preservar
//
// Integra con ControlNet para mejores resultados con inpainting guided.
//
// ROADMAP: "Inpainting, Outpainting, object detection" (🟡 MEDIO PLAZO)

// MARK: - Models

enum InpaintMode: String, Codable, CaseIterable, Identifiable {
    case inpaint     = "Inpaint"
    case inpaintFill = "Inpaint Fill"
    case outpaint    = "Outpaint"
    case objectErase = "Borrar objeto"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .inpaint:     return "paintbrush.pointed.fill"
        case .inpaintFill: return "rectangle.portrait.fill"
        case .outpaint:    return "arrow.up.left.and.arrow.down.right"
        case .objectErase: return "eraser.fill"
        }
    }

    var description: String {
        switch self {
        case .inpaint:     return "Pinta sobre la zona enmascarada con nueva generación."
        case .inpaintFill: return "Rellena con contenido original suavizado antes de inpaintar."
        case .outpaint:    return "Extiende el lienzo añadiendo contenido en los bordes."
        case .objectErase: return "Elimina el objeto enmascarado y rellena con el fondo."
        }
    }

    var defaultDenoise: Double {
        switch self {
        case .inpaint:     return 0.75
        case .inpaintFill: return 0.85
        case .outpaint:    return 0.90
        case .objectErase: return 0.80
        }
    }
}

struct InpaintSettings {
    var mode:               InpaintMode = .inpaint
    var denoiseStrength:    Double      = 0.75
    var maskBlur:           Int         = 4
    var inpaintFull:        Bool        = false     // inpaint_full_res
    var inpaintPadding:     Int         = 32        // inpaint_full_res_padding
    var maskMode:           Int         = 0         // 0=inpaint masked, 1=inpaint not masked
    var samplerName:        String      = "DPM++ 2M Karras"
    var steps:              Int         = 30
    var cfgScale:           Double      = 7.0
    var seed:               Int         = -1
    var width:              Int         = 512
    var height:             Int         = 768

    // Outpaint-specific
    var outpaintDirection:  OutpaintDirection = .all
    var outpaintPixels:     Int              = 128

    enum OutpaintDirection: String, Codable, CaseIterable {
        case all    = "Todos los lados"
        case right  = "Derecha"
        case left   = "Izquierda"
        case top    = "Arriba"
        case bottom = "Abajo"
    }
}

struct InpaintResult: Identifiable {
    let id            = UUID()
    let sourceImage:  NSImage
    let maskImage:    NSImage
    let resultImage:  NSImage
    let mode:         InpaintMode
    let prompt:       String
    let seed:         Int?
    let duration:     Double
    var savedPath:    String? = nil
}

// MARK: - InpaintingEngine

@MainActor
final class InpaintingEngine: ObservableObject {

    static let shared = InpaintingEngine()
    private init() {}

    // MARK: - State

    @Published var isProcessing:  Bool           = false
    @Published var progress:      Double         = 0
    @Published var progressText:  String         = ""
    @Published var result:        InpaintResult? = nil
    @Published var errorMessage:  String?        = nil
    @Published var history:       [InpaintResult] = []

    private var progressTask: Task<Void, Never>? = nil

    // MARK: - Main API

    func inpaint(
        sourceImage: NSImage,
        maskImage:   NSImage,
        prompt:      String,
        negative:    String  = "",
        settings:    InpaintSettings,
        baseURL:     String
    ) async {
        guard !isProcessing else { return }
        isProcessing = true
        errorMessage = nil
        result       = nil
        progress     = 0
        progressText = "Preparando inpainting…"

        let startTime = Date()

        do {
            let sourceB64 = try imageToBase64(sourceImage)
            let maskB64   = try imageToBase64(maskImage)

            startProgressPolling(baseURL: baseURL)

            let payload = buildPayload(
                initImageB64: sourceB64,
                maskB64:      maskB64,
                prompt:       prompt,
                negative:     negative,
                settings:     settings
            )

            let url = URL(string: "\(baseURL)/sdapi/v1/img2img")!
            var req = URLRequest(url: url, timeoutInterval: 300)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody  = try JSONSerialization.data(withJSONObject: payload)

            let (data, resp) = try await URLSession.shared.data(for: req)
            stopProgressPolling()

            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                throw InpaintError.badResponse((resp as? HTTPURLResponse)?.statusCode ?? -1)
            }

            guard let json     = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let images    = json["images"] as? [String],
                  let firstB64  = images.first,
                  let imgData   = Data(base64Encoded: firstB64),
                  let resultImg = NSImage(data: imgData)
            else { throw InpaintError.noImage }

            var resultSeed: Int? = nil
            if let infoStr = json["info"] as? String,
               let infoData = infoStr.data(using: .utf8),
               let infoJSON = try? JSONSerialization.jsonObject(with: infoData) as? [String: Any],
               let seed = infoJSON["seed"] as? Int {
                resultSeed = seed
            }

            let savedPath = saveResult(resultImg, mode: settings.mode)

            let inpaintResult = InpaintResult(
                sourceImage: sourceImage,
                maskImage:   maskImage,
                resultImage: resultImg,
                mode:        settings.mode,
                prompt:      prompt,
                seed:        resultSeed,
                duration:    Date().timeIntervalSince(startTime),
                savedPath:   savedPath
            )

            result = inpaintResult
            history.insert(inpaintResult, at: 0)
            if history.count > 50 { history = Array(history.prefix(50)) }

            progress = 1.0
            progressText = "\(settings.mode.rawValue) completado ✓"

            if let seed = resultSeed, seed > 0 {
                SeedManager.shared.recordUsage(
                    seed: seed,
                    promptHint: String(prompt.prefix(50)),
                    width: settings.width, height: settings.height
                )
            }

        } catch {
            stopProgressPolling()
            errorMessage = error.localizedDescription
            progressText = "Error: \(error.localizedDescription)"
        }

        isProcessing = false
    }

    // MARK: - Outpaint Convenience

    func outpaint(
        sourceImage: NSImage,
        prompt:      String,
        negative:    String  = "",
        direction:   InpaintSettings.OutpaintDirection = .all,
        pixels:      Int     = 128,
        baseURL:     String
    ) async {
        let mask = generateOutpaintMask(for: sourceImage, direction: direction, pixels: pixels)
        var settings        = InpaintSettings()
        settings.mode       = .outpaint
        settings.denoiseStrength = 0.90
        settings.outpaintDirection = direction
        settings.outpaintPixels    = pixels
        settings.width  = Int(sourceImage.size.width) + (direction == .all ? pixels * 2 : (direction == .left || direction == .right ? pixels : 0))
        settings.height = Int(sourceImage.size.height) + (direction == .all ? pixels * 2 : (direction == .top || direction == .bottom ? pixels : 0))

        // Expand source canvas
        let expanded = expandCanvas(sourceImage, direction: direction, pixels: pixels)

        await inpaint(
            sourceImage: expanded,
            maskImage:   mask,
            prompt:      prompt,
            negative:    negative,
            settings:    settings,
            baseURL:     baseURL
        )
    }

    // MARK: - Payload Builder

    private func buildPayload(
        initImageB64: String,
        maskB64:      String,
        prompt:       String,
        negative:     String,
        settings:     InpaintSettings
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "init_images":         [initImageB64],
            "mask":                maskB64,
            "prompt":              prompt,
            "negative_prompt":     negative,
            "denoising_strength":  settings.denoiseStrength,
            "mask_blur":           settings.maskBlur,
            "inpaint_full_res":    settings.inpaintFull,
            "inpaint_full_res_padding": settings.inpaintPadding,
            "inpainting_mask_invert": settings.maskMode,
            "inpainting_fill":     settings.mode == .inpaintFill ? 1 : 0,
            "steps":               settings.steps,
            "cfg_scale":           settings.cfgScale,
            "seed":                settings.seed,
            "width":               settings.width,
            "height":              settings.height,
            "sampler_name":        settings.samplerName,
            "resize_mode":         1,
            "send_images":         true,
            "save_images":         false
        ]

        // Inject ControlNet if enabled
        if let cnPayload = ControlNetEngine.shared.alwaysonScriptsPayload() {
            payload["alwayson_scripts"] = cnPayload
        }

        return payload
    }

    // MARK: - Mask Generators

    /// Genera una máscara blanca en los bordes para outpainting.
    func generateOutpaintMask(
        for image: NSImage,
        direction: InpaintSettings.OutpaintDirection,
        pixels: Int
    ) -> NSImage {
        let origW = Int(image.size.width)
        let origH = Int(image.size.height)

        let newW = origW + (direction == .all || direction == .left || direction == .right ? pixels * (direction == .all ? 2 : 1) : 0)
        let newH = origH + (direction == .all || direction == .top || direction == .bottom ? pixels * (direction == .all ? 2 : 1) : 0)

        let size   = NSSize(width: newW, height: newH)
        let result = NSImage(size: size)
        result.lockFocus()

        NSColor.black.setFill()
        NSRect(origin: .zero, size: size).fill()

        NSColor.white.setFill()
        let paddingX = (direction == .all || direction == .left) ? pixels : 0
        let paddingY = (direction == .all || direction == .bottom) ? pixels : 0

        switch direction {
        case .all:
            NSRect(origin: .zero, size: NSSize(width: pixels, height: newH)).fill()
            NSRect(origin: NSPoint(x: newW - pixels, y: 0), size: NSSize(width: pixels, height: newH)).fill()
            NSRect(origin: .zero, size: NSSize(width: newW, height: pixels)).fill()
            NSRect(origin: NSPoint(x: 0, y: newH - pixels), size: NSSize(width: newW, height: pixels)).fill()
        case .right:
            NSRect(origin: NSPoint(x: newW - pixels, y: 0), size: NSSize(width: pixels, height: newH)).fill()
        case .left:
            NSRect(origin: .zero, size: NSSize(width: pixels, height: newH)).fill()
        case .top:
            NSRect(origin: NSPoint(x: 0, y: newH - pixels), size: NSSize(width: newW, height: pixels)).fill()
        case .bottom:
            NSRect(origin: .zero, size: NSSize(width: newW, height: pixels)).fill()
        }

        result.unlockFocus()
        return result
    }

    /// Expande el canvas pegando la imagen en el centro del nuevo lienzo más grande.
    private func expandCanvas(_ image: NSImage, direction: InpaintSettings.OutpaintDirection, pixels: Int) -> NSImage {
        let origW = image.size.width
        let origH = image.size.height

        let newW = origW + CGFloat((direction == .all || direction == .left || direction == .right) ? pixels * (direction == .all ? 2 : 1) : 0)
        let newH = origH + CGFloat((direction == .all || direction == .top || direction == .bottom) ? pixels * (direction == .all ? 2 : 1) : 0)

        let result = NSImage(size: NSSize(width: newW, height: newH))
        result.lockFocus()

        NSColor.black.setFill()
        NSRect(origin: .zero, size: NSSize(width: newW, height: newH)).fill()

        let offsetX = (direction == .all || direction == .left) ? CGFloat(pixels) : 0
        let offsetY = (direction == .all || direction == .bottom) ? CGFloat(pixels) : 0
        image.draw(in: NSRect(x: offsetX, y: offsetY, width: origW, height: origH))

        result.unlockFocus()
        return result
    }

    // MARK: - Progress Polling

    private func startProgressPolling(baseURL: String) {
        progressTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard !Task.isCancelled else { break }
                await self.fetchProgress(baseURL: baseURL)
            }
        }
    }

    private func stopProgressPolling() {
        progressTask?.cancel()
        progressTask = nil
    }

    private func fetchProgress(baseURL: String) async {
        guard let url = URL(string: "\(baseURL)/sdapi/v1/progress") else { return }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        let pct = json["progress"] as? Double ?? 0
        let eta = json["eta_relative"] as? Double ?? 0
        progress = min(pct, 0.99)
        if pct > 0 {
            progressText = eta > 0
                ? "Procesando… \(Int(pct*100))% (ETA \(String(format: "%.1f", eta))s)"
                : "Procesando… \(Int(pct*100))%"
        }
    }

    // MARK: - Helpers

    private func imageToBase64(_ image: NSImage) throws -> String {
        guard let tiff = image.tiffRepresentation,
              let bmp  = NSBitmapImageRep(data: tiff),
              let png  = bmp.representation(using: .png, properties: [:])
        else { throw InpaintError.imageConversionFailed }
        return png.base64EncodedString()
    }

    private func saveResult(_ image: NSImage, mode: InpaintMode) -> String? {
        guard let dir = VaultManager.shared.masterPicksURL else { return nil }
        let subdir = dir.appending(path: "inpaint")
        try? FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        let filename = "inpaint_\(mode.rawValue.lowercased().replacingOccurrences(of: " ", with: "_"))_\(Int(Date().timeIntervalSince1970)).png"
        let url = subdir.appending(path: filename)
        guard let tiff = image.tiffRepresentation,
              let bmp  = NSBitmapImageRep(data: tiff),
              let png  = bmp.representation(using: .png, properties: [:])
        else { return nil }
        try? png.write(to: url, options: .atomic)
        return url.path
    }
}

// MARK: - Errors

enum InpaintError: LocalizedError {
    case badResponse(Int), noImage, imageConversionFailed
    var errorDescription: String? {
        switch self {
        case .badResponse(let c): return "A1111 respondió \(c)"
        case .noImage:            return "No se recibió imagen procesada"
        case .imageConversionFailed: return "Error convirtiendo imagen a base64"
        }
    }
}

// MARK: - InpaintingView

struct InpaintingView: View {

    @ObservedObject var engine = InpaintingEngine.shared
    @Binding var baseURL:    String
    @Binding var prompt:     String
    @Binding var negative:   String

    @State private var sourceImage:  NSImage? = nil
    @State private var maskImage:    NSImage? = nil
    @State private var settings      = InpaintSettings()
    @State private var showHistory   = false
    @State private var isDrawingMask = false

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider().background(Color.white.opacity(0.07))

            if showHistory {
                historyPanel
            } else {
                mainPanel
            }
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(Color(hex: "#f472b6").opacity(0.2), lineWidth: 1))
    }

    // MARK: - Header

    var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "paintbrush.pointed.fill")
                .font(.system(size: 14))
                .foregroundColor(Color(hex: "#f472b6"))
            Text("Inpainting / Outpainting")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
            Spacer()
            Button(action: { showHistory.toggle() }) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 12))
                    .foregroundColor(showHistory ? Color(hex: "#f472b6") : .secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Color.white.opacity(0.03))
    }

    // MARK: - Main Panel

    var mainPanel: some View {
        ScrollView {
            VStack(spacing: 14) {

                // Mode selector
                VStack(alignment: .leading, spacing: 6) {
                    sLabel("Modo")
                    HStack(spacing: 6) {
                        ForEach(InpaintMode.allCases) { mode in
                            Button(action: {
                                settings.mode = mode
                                settings.denoiseStrength = mode.defaultDenoise
                            }) {
                                VStack(spacing: 4) {
                                    Image(systemName: mode.icon).font(.system(size: 13))
                                    Text(mode.rawValue).font(.system(size: 9)).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity).padding(.vertical, 8)
                                .background(settings.mode == mode
                                    ? Color(hex: "#f472b6").opacity(0.2) : Color.white.opacity(0.04))
                                .foregroundColor(settings.mode == mode ? Color(hex: "#f472b6") : .secondary)
                                .cornerRadius(7)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Text(settings.mode.description)
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }

                // Image sources
                HStack(spacing: 10) {
                    imageDropZone(
                        label: "Imagen fuente",
                        image: sourceImage,
                        icon:  "photo",
                        color: Color(hex: "#7c6af7")
                    ) { pickImage(isMask: false) }

                    imageDropZone(
                        label: settings.mode == .outpaint ? "Auto-generada" : "Máscara (blanco=modificar)",
                        image: maskImage,
                        icon:  "paintbrush.fill",
                        color: Color(hex: "#f472b6"),
                        disabled: settings.mode == .outpaint
                    ) {
                        if settings.mode != .outpaint { pickImage(isMask: true) }
                    }
                }

                // Outpaint direction
                if settings.mode == .outpaint {
                    VStack(alignment: .leading, spacing: 6) {
                        sLabel("Dirección")
                        Picker("", selection: $settings.outpaintDirection) {
                            ForEach(InpaintSettings.OutpaintDirection.allCases, id: \.self) {
                                Text($0.rawValue).tag($0)
                            }
                        }
                        .pickerStyle(.segmented).labelsHidden()
                        HStack {
                            sLabel("Píxeles a añadir: \(settings.outpaintPixels)")
                            Spacer()
                        }
                        Slider(value: Binding(
                            get: { Double(settings.outpaintPixels) },
                            set: { settings.outpaintPixels = Int($0) }
                        ), in: 64...512, step: 64)
                        .accentColor(Color(hex: "#f472b6"))
                    }
                    .padding(10).background(Color.white.opacity(0.03)).cornerRadius(8)
                }

                // Config
                VStack(spacing: 10) {
                    // Denoise
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            sLabel("Denoising (\(String(format: "%.2f", settings.denoiseStrength)))")
                            Spacer()
                        }
                        Slider(value: $settings.denoiseStrength, in: 0.1...1.0, step: 0.05)
                            .accentColor(Color(hex: "#f472b6"))
                    }

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            sLabel("Steps")
                            Stepper(value: $settings.steps, in: 10...60, step: 5) {
                                Text("\(settings.steps)")
                                    .font(.system(size: 12, design: .monospaced)).foregroundColor(.white)
                            }
                        }
                        Divider().frame(height: 30).background(Color.white.opacity(0.08))
                        VStack(alignment: .leading, spacing: 4) {
                            sLabel("Mask Blur")
                            Stepper(value: $settings.maskBlur, in: 0...16, step: 1) {
                                Text("\(settings.maskBlur)")
                                    .font(.system(size: 12, design: .monospaced)).foregroundColor(.white)
                            }
                        }
                    }
                    .padding(10).background(Color.white.opacity(0.03)).cornerRadius(8)
                }

                // Progress
                if engine.isProcessing {
                    VStack(spacing: 6) {
                        ProgressView(value: engine.progress).accentColor(Color(hex: "#f472b6"))
                        Text(engine.progressText).font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    .padding(10).background(Color.white.opacity(0.03)).cornerRadius(8)
                }

                // Result
                if let res = engine.result {
                    VStack(spacing: 8) {
                        Image(nsImage: res.resultImage)
                            .resizable().scaledToFit()
                            .frame(maxHeight: 240)
                            .cornerRadius(8)
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(Color(hex: "#f472b6").opacity(0.3), lineWidth: 1))
                        HStack {
                            if let seed = res.seed {
                                Text("Seed: \(seed)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Text(String(format: "%.1fs", res.duration))
                                .font(.system(size: 10)).foregroundColor(.secondary)

                            // Usar resultado como nueva fuente
                            Button(action: {
                                sourceImage = res.resultImage
                                maskImage   = nil
                            }) {
                                Label("Re-usar", systemImage: "arrow.uturn.backward")
                                    .font(.system(size: 10))
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(Color(hex: "#f472b6"))
                        }
                    }
                    .padding(10).background(Color.white.opacity(0.03)).cornerRadius(8)
                }

                if let err = engine.errorMessage {
                    Text("⚠ \(err)")
                        .font(.system(size: 11))
                        .foregroundColor(Color(red: 1, green: 0.45, blue: 0.45))
                        .padding(8).background(Color.red.opacity(0.08)).cornerRadius(6)
                }

                // CTA
                Button(action: { Task { await runInpaint() } }) {
                    HStack(spacing: 8) {
                        if engine.isProcessing {
                            ProgressView().controlSize(.small).tint(.white)
                            Text("Procesando…")
                        } else {
                            Image(systemName: settings.mode.icon)
                            Text("\(settings.mode.rawValue)")
                        }
                    }
                    .font(.system(size: 13, weight: .bold))
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(canProcess
                        ? LinearGradient(colors: [Color(hex: "#f472b6"), Color(hex: "#db2777")],
                                         startPoint: .leading, endPoint: .trailing)
                        : LinearGradient(colors: [.gray.opacity(0.3), .gray.opacity(0.3)],
                                         startPoint: .leading, endPoint: .trailing))
                    .foregroundColor(.white).cornerRadius(10)
                }
                .buttonStyle(.plain).disabled(!canProcess || engine.isProcessing)
            }
            .padding(14)
        }
    }

    var canProcess: Bool {
        guard sourceImage != nil else { return false }
        if settings.mode == .outpaint { return true }
        return maskImage != nil
    }

    // MARK: - History Panel

    var historyPanel: some View {
        Group {
            if engine.history.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 28)).foregroundColor(.white.opacity(0.08))
                    Text("Sin historial").font(.system(size: 12)).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity).padding(40)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(engine.history.prefix(20)) { item in
                            historyRow(item)
                        }
                    }
                    .padding(10)
                }
            }
        }
    }

    func historyRow(_ item: InpaintResult) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: item.resultImage)
                .resizable().scaledToFill()
                .frame(width: 50, height: 50)
                .cornerRadius(6).clipped()
            VStack(alignment: .leading, spacing: 2) {
                Text(item.mode.rawValue)
                    .font(.system(size: 11, weight: .medium)).foregroundColor(.white)
                Text(item.prompt.truncated(40))
                    .font(.system(size: 10)).foregroundColor(.secondary)
                Text(String(format: "%.1fs", item.duration))
                    .font(.system(size: 9)).foregroundColor(.secondary.opacity(0.6))
            }
            Spacer()
            Button(action: {
                sourceImage = item.resultImage
                maskImage   = nil
                showHistory = false
            }) {
                Image(systemName: "arrow.uturn.backward").font(.system(size: 11))
                    .foregroundColor(Color(hex: "#f472b6"))
            }
            .buttonStyle(.plain)
        }
        .padding(8).background(Color.white.opacity(0.04)).cornerRadius(8)
    }

    // MARK: - Helpers

    func imageDropZone(
        label: String,
        image: NSImage?,
        icon:  String,
        color: Color,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                if let img = image {
                    Image(nsImage: img)
                        .resizable().scaledToFill()
                        .frame(height: 80).clipped()
                        .cornerRadius(6)
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.04))
                        .frame(height: 80)
                        .overlay(
                            VStack(spacing: 4) {
                                Image(systemName: icon).font(.system(size: 18))
                                    .foregroundColor(disabled ? .secondary : color)
                                Text(label).font(.system(size: 9)).foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                        )
                }
                Text(label)
                    .font(.system(size: 9)).foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .disabled(disabled)
    }

    private func pickImage(isMask: Bool) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.canChooseFiles = true
        panel.title = isMask ? "Seleccionar máscara" : "Seleccionar imagen fuente"
        guard panel.runModal() == .OK,
              let url = panel.url,
              let img = NSImage(contentsOf: url) else { return }
        if isMask { maskImage = img } else { sourceImage = img }
    }

    private func runInpaint() async {
        guard let src = sourceImage else { return }

        if settings.mode == .outpaint {
            await engine.outpaint(
                sourceImage: src,
                prompt:      prompt,
                negative:    negative,
                direction:   settings.outpaintDirection,
                pixels:      settings.outpaintPixels,
                baseURL:     baseURL
            )
        } else {
            guard let mask = maskImage else { return }
            await engine.inpaint(
                sourceImage: src,
                maskImage:   mask,
                prompt:      prompt,
                negative:    negative,
                settings:    settings,
                baseURL:     baseURL
            )
        }
    }

    func sLabel(_ t: String) -> some View {
        Text(t).font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
    }
}
