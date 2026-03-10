import Foundation
import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers

// MARK: - Img2ImgEngine
//
// Pipeline completo de imagen-a-imagen via A1111 /sdapi/v1/img2img
//
// Modos:
//   .refine         — Refinamiento suave de una imagen existente (denoise bajo)
//   .characterFix   — Character consistency: guía visual con imagen base del personaje
//   .sceneFit       — Aplicar estética de escena de referencia (style transfer light)
//   .inpaintManual  — Inpainting con máscara manual (preparado para ControlNet)
//   .hiresFix       — Hi-res fix manual vía img2img (backup si A1111 hires.fix falla)
//
// Persistencia: cada job guarda sidecar JSON en el vault (misma lógica que txt2img)
// Compatibilidad: el output es un GeneratedImage compatible con RightPanelView

// MARK: - Models

enum Img2ImgMode: String, Codable, CaseIterable {
    case refine        = "Refinar"
    case characterFix  = "Character Fix"
    case sceneFit      = "Scene Fit"
    case hiresFix      = "Hi-Res Fix"

    var icon: String {
        switch self {
        case .refine:       return "wand.and.stars"
        case .characterFix: return "person.crop.square.filled.and.at.rectangle"
        case .sceneFit:     return "photo.on.rectangle.angled"
        case .hiresFix:     return "arrow.up.left.and.arrow.down.right"
        }
    }

    var defaultDenoise: Double {
        switch self {
        case .refine:       return 0.45
        case .characterFix: return 0.55
        case .sceneFit:     return 0.60
        case .hiresFix:     return 0.40
        }
    }

    var description: String {
        switch self {
        case .refine:
            return "Refinamiento suave. Mantiene composición, mejora calidad."
        case .characterFix:
            return "Guía la generación con la imagen base del personaje activo."
        case .sceneFit:
            return "Transfiere la estética de la escena de referencia."
        case .hiresFix:
            return "Sube resolución manteniendo detalles. Denoise bajo."
        }
    }
}

struct Img2ImgJob: Identifiable, Codable {
    var id:               UUID       = UUID()
    var createdAt:        Date       = Date()
    var mode:             Img2ImgMode
    var sourceImagePath:  String
    var resultImagePath:  String?    = nil
    var prompt:           String
    var negativePrompt:   String
    var denoiseStrength:  Double
    var steps:            Int
    var cfgScale:         Double
    var seed:             Int        = -1
    var resultSeed:       Int?       = nil
    var width:            Int
    var height:           Int
    var samplerName:      String
    var checkpoint:       String
    var characterID:      UUID?      = nil
    var sceneID:          UUID?      = nil
    var duration:         Double?    = nil
    var status:           JobStatus  = .pending

    enum JobStatus: String, Codable {
        case pending, running, success, failed
    }
}

// MARK: - Img2ImgSettings

struct Img2ImgSettings {
    var mode:            Img2ImgMode = .refine
    var denoiseStrength: Double      = 0.45
    var steps:           Int         = 25
    var cfgScale:        Double      = 7.0
    var seed:            Int         = -1
    var width:           Int         = 512
    var height:          Int         = 768
    var samplerName:     String      = "DPM++ 2M Karras"
    var resizeMode:      Int         = 1   // 0=Just resize, 1=Crop+resize, 2=Resize+fill
    var maskBlur:        Int         = 4
}

// MARK: - Img2ImgEngine

@MainActor
final class Img2ImgEngine: ObservableObject {

    static let shared = Img2ImgEngine()
    private init() { loadHistory() }

    // MARK: - State

    @Published var isGenerating:   Bool             = false
    @Published var progress:       Double           = 0
    @Published var progressText:   String           = ""
    @Published var resultImage:    NSImage?         = nil
    @Published var lastJob:        Img2ImgJob?      = nil
    @Published var jobHistory:     [Img2ImgJob]     = []
    @Published var errorMessage:   String?          = nil

    private var progressTask: Task<Void, Never>?

    // MARK: - Public API

    /// Genera img2img con imagen de entrada explícita
    func generate(
        sourceImage:  NSImage,
        prompt:       String,
        negative:     String       = "",
        settings:     Img2ImgSettings,
        baseURL:      String,
        checkpoint:   String       = "",
        characterID:  UUID?        = nil,
        sceneID:      UUID?        = nil
    ) async {
        guard !isGenerating else { return }
        errorMessage = nil
        resultImage  = nil
        isGenerating = true
        progress     = 0
        progressText = "Preparando img2img…"

        let startTime = Date()

        var job = Img2ImgJob(
            mode:             settings.mode,
            sourceImagePath:  "(en memoria)",
            prompt:           prompt,
            negativePrompt:   negative,
            denoiseStrength:  settings.denoiseStrength,
            steps:            settings.steps,
            cfgScale:         settings.cfgScale,
            seed:             settings.seed,
            width:            settings.width,
            height:           settings.height,
            samplerName:      settings.samplerName,
            checkpoint:       checkpoint,
            characterID:      characterID,
            sceneID:          sceneID,
            status:           .running
        )

        startProgressPolling(baseURL: baseURL, totalSteps: settings.steps)

        do {
            let b64 = try imageToBase64(sourceImage)
            let payload = buildPayload(
                initImage:  b64,
                prompt:     prompt,
                negative:   negative,
                settings:   settings
            )

            let url    = URL(string: "\(baseURL)/sdapi/v1/img2img")!
            var req    = URLRequest(url: url, timeoutInterval: 300)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody  = try JSONSerialization.data(withJSONObject: payload)

            let (data, resp) = try await URLSession.shared.data(for: req)
            stopProgressPolling()

            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                throw Img2ImgError.badResponse((resp as? HTTPURLResponse)?.statusCode ?? -1)
            }

            guard let json       = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let images      = json["images"] as? [String],
                  let firstB64    = images.first,
                  let imgData     = Data(base64Encoded: firstB64),
                  let resultNSImg = NSImage(data: imgData)
            else {
                throw Img2ImgError.noImageInResponse
            }

            // Extraer seed del info JSON
            var resultSeed: Int? = nil
            if let infoStr = json["info"] as? String,
               let infoData = infoStr.data(using: .utf8),
               let infoJSON = try? JSONSerialization.jsonObject(with: infoData) as? [String: Any],
               let seed     = infoJSON["seed"] as? Int {
                resultSeed = seed
            }

            // Guardar resultado en vault
            let savedPath = await saveResult(resultNSImg, job: job)

            job.resultImagePath = savedPath
            job.resultSeed      = resultSeed
            job.duration        = Date().timeIntervalSince(startTime)
            job.status          = .success

            resultImage = resultNSImg

            // Registrar seed si hay resultado
            if let seed = resultSeed, seed > 0 {
                SeedManager.shared.recordUsage(
                    seed:       seed,
                    promptHint: String(prompt.prefix(50)),
                    width:      settings.width,
                    height:     settings.height
                )
            }

        } catch {
            stopProgressPolling()
            job.status    = .failed
            errorMessage  = error.localizedDescription
            progressText  = "Error: \(error.localizedDescription)"
        }

        lastJob = job
        addToHistory(job)
        isGenerating = false
        if job.status == .success { progress = 1.0; progressText = "Listo ✓" }
    }

    /// Convenience: usar imagen base del personaje activo
    func generateFromActiveCharacter(
        prompt:      String,
        negative:    String,
        settings:    Img2ImgSettings,
        baseURL:     String,
        checkpoint:  String
    ) async {
        guard let character = CharacterEngine.shared.activeCharacter else {
            errorMessage = "No hay personaje activo. Selecciona un personaje primero."
            return
        }
        guard let baseImg = CharacterEngine.shared.loadBaseImage(for: character) else {
            errorMessage = "El personaje '\(character.name)' no tiene imagen base. Añádela en el editor."
            return
        }

        var s = settings
        s.mode = .characterFix

        await generate(
            sourceImage:  baseImg,
            prompt:       prompt,
            negative:     negative,
            settings:     s,
            baseURL:      baseURL,
            checkpoint:   checkpoint,
            characterID:  character.id
        )
    }

    /// Convenience: usar imagen de referencia de la escena activa
    func generateFromActiveScene(
        prompt:      String,
        negative:    String,
        settings:    Img2ImgSettings,
        baseURL:     String,
        checkpoint:  String
    ) async {
        guard let scene = SceneEngine.shared.activeScene else {
            errorMessage = "No hay escena activa."
            return
        }
        guard let refImg = SceneEngine.shared.loadReferenceImage(for: scene) else {
            errorMessage = "La escena '\(scene.name)' no tiene imagen de referencia."
            return
        }

        var s = settings
        s.mode = .sceneFit

        await generate(
            sourceImage: refImg,
            prompt:      prompt,
            negative:    negative,
            settings:    s,
            baseURL:     baseURL,
            checkpoint:  checkpoint,
            sceneID:     scene.id
        )
    }

    /// Refinar imagen existente (desde galería o resultado anterior)
    func refine(
        image:       NSImage,
        prompt:      String,
        negative:    String,
        denoise:     Double  = 0.40,
        settings:    Img2ImgSettings,
        baseURL:     String,
        checkpoint:  String
    ) async {
        var s = settings
        s.mode            = .refine
        s.denoiseStrength = denoise

        await generate(
            sourceImage: image,
            prompt:      prompt,
            negative:    negative,
            settings:    s,
            baseURL:     baseURL,
            checkpoint:  checkpoint
        )
    }

    // MARK: - Progress Polling

    private func startProgressPolling(baseURL: String, totalSteps: Int) {
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
        if eta > 0 {
            progressText = "Generando… \(Int(pct * 100))%  (ETA \(String(format: "%.1f", eta))s)"
        } else if pct > 0 {
            progressText = "Generando… \(Int(pct * 100))%"
        }
    }

    // MARK: - Payload Builder

    private func buildPayload(
        initImage: String,
        prompt:    String,
        negative:  String,
        settings:  Img2ImgSettings
    ) -> [String: Any] {
        [
            "init_images":       [initImage],
            "prompt":            prompt,
            "negative_prompt":   negative,
            "denoising_strength": settings.denoiseStrength,
            "steps":             settings.steps,
            "cfg_scale":         settings.cfgScale,
            "seed":              settings.seed,
            "width":             settings.width,
            "height":            settings.height,
            "sampler_name":      settings.samplerName,
            "resize_mode":       settings.resizeMode,
            "mask_blur":         settings.maskBlur,
            "inpaint_full_res":  false,
            "send_images":       true,
            "save_images":       false
        ]
    }

    // MARK: - Helpers

    private func imageToBase64(_ image: NSImage) throws -> String {
        guard let tiff = image.tiffRepresentation,
              let bmp  = NSBitmapImageRep(data: tiff),
              let png  = bmp.representation(using: .png, properties: [:])
        else { throw Img2ImgError.imageConversionFailed }
        return png.base64EncodedString()
    }

    private func saveResult(_ image: NSImage, job: Img2ImgJob) async -> String? {
        guard let outputDir = VaultManager.shared.generacionesURL else { return nil }
        let subdir = outputDir.appending(path: "img2img")
        try? FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)

        let filename  = "i2i_\(Int(Date().timeIntervalSince1970))_\(UUID().uuidString.prefix(8)).png"
        let fileURL   = subdir.appending(path: filename)

        guard let tiff = image.tiffRepresentation,
              let bmp  = NSBitmapImageRep(data: tiff),
              let png  = bmp.representation(using: .png, properties: [:])
        else { return nil }

        try? png.write(to: fileURL, options: .atomic)

        // Sidecar JSON
        let sidecar: [String: Any] = [
            "type":       "img2img",
            "mode":       job.mode.rawValue,
            "prompt":     job.prompt,
            "negative":   job.negativePrompt,
            "denoise":    job.denoiseStrength,
            "seed":       job.resultSeed ?? -1,
            "steps":      job.steps,
            "cfg":        job.cfgScale,
            "sampler":    job.samplerName,
            "width":      job.width,
            "height":     job.height,
            "checkpoint": job.checkpoint,
            "createdAt":  ISO8601DateFormatter().string(from: job.createdAt)
        ]
        if let sidecarData = try? JSONSerialization.data(withJSONObject: sidecar, options: .prettyPrinted) {
            let sidecarURL = subdir.appending(path: filename.replacingOccurrences(of: ".png", with: ".json"))
            try? sidecarData.write(to: sidecarURL, options: .atomic)
        }

        return fileURL.path
    }

    // MARK: - History

    private let historyKey = "img2img_job_history"

    private func addToHistory(_ job: Img2ImgJob) {
        jobHistory.insert(job, at: 0)
        if jobHistory.count > 100 { jobHistory = Array(jobHistory.prefix(100)) }
        saveHistory()
    }

    private func saveHistory() {
        guard let url = historyURL,
              let data = try? JSONEncoder.pretty.encode(jobHistory)
        else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func loadHistory() {
        guard let url  = historyURL,
              let data = try? Data(contentsOf: url),
              let jobs = try? JSONDecoder.iso8601.decode([Img2ImgJob].self, from: data)
        else { return }
        jobHistory = jobs
    }

    private var historyURL: URL? {
        VaultManager.shared.vaultMetaURL?.appending(path: "img2img_history.json")
    }
}

// MARK: - Errors

enum Img2ImgError: LocalizedError {
    case badResponse(Int)
    case noImageInResponse
    case imageConversionFailed

    var errorDescription: String? {
        switch self {
        case .badResponse(let code):  return "A1111 respondió con código \(code)"
        case .noImageInResponse:      return "No se recibió imagen en la respuesta"
        case .imageConversionFailed:  return "Error convirtiendo imagen a base64"
        }
    }
}

// MARK: - Img2ImgView (Panel completo)

struct Img2ImgView: View {

    @ObservedObject var engine   = Img2ImgEngine.shared
    @ObservedObject var charEng  = CharacterEngine.shared
    @ObservedObject var sceneEng = SceneEngine.shared

    @Binding var baseURL:    String
    @Binding var checkpoint: String
    @Binding var prompt:     String
    @Binding var negative:   String

    @State private var settings    = Img2ImgSettings()
    @State private var sourceImage: NSImage? = nil
    @State private var sourceLabel: String   = "Ninguna"
    @State private var showHistory = false

    var body: some View {
        VStack(spacing: 0) {

            // ── Header ───────────────────────────────────────────────
            HStack(spacing: 10) {
                Image(systemName: "wand.and.stars.inverse")
                    .font(.system(size: 14))
                    .foregroundColor(Color(hex: "#a78bfa"))
                Text("Img2Img")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Button(action: { showHistory.toggle() }) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 12))
                        .foregroundColor(showHistory ? Color(hex: "#a78bfa") : .secondary)
                }
                .buttonStyle(.plain).help("Historial")
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(Color.white.opacity(0.03))

            Divider().background(Color.white.opacity(0.07))

            if showHistory {
                historyPanel
            } else {
                mainPanel
            }
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: "#a78bfa").opacity(0.2), lineWidth: 1))
    }

    // MARK: - Main Panel

    var mainPanel: some View {
        ScrollView {
            VStack(spacing: 14) {

                // ── Modo ─────────────────────────────────────────────
                modePicker

                // ── Fuente de imagen ─────────────────────────────────
                imageSourcePicker

                // ── Configuración ────────────────────────────────────
                configPanel

                // ── Prompt override (opcional) ───────────────────────
                promptOverride

                // ── Acción ───────────────────────────────────────────
                generateButton

                // ── Resultado ────────────────────────────────────────
                if engine.isGenerating || engine.resultImage != nil {
                    resultPanel
                }

                if let err = engine.errorMessage {
                    Text("⚠ \(err)")
                        .font(.system(size: 11))
                        .foregroundColor(Color(red: 1, green: 0.45, blue: 0.45))
                        .padding(8)
                        .background(Color.red.opacity(0.08))
                        .cornerRadius(6)
                }
            }
            .padding(14)
        }
    }

    // MARK: - Mode Picker

    var modePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            label("Modo")
            HStack(spacing: 6) {
                ForEach(Img2ImgMode.allCases, id: \.self) { mode in
                    Button(action: {
                        settings.mode = mode
                        settings.denoiseStrength = mode.defaultDenoise
                    }) {
                        VStack(spacing: 4) {
                            Image(systemName: mode.icon)
                                .font(.system(size: 13))
                            Text(mode.rawValue)
                                .font(.system(size: 9, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(settings.mode == mode
                            ? Color(hex: "#a78bfa").opacity(0.25)
                            : Color.white.opacity(0.04))
                        .foregroundColor(settings.mode == mode
                            ? Color(hex: "#a78bfa")
                            : .secondary)
                        .cornerRadius(7)
                        .overlay(RoundedRectangle(cornerRadius: 7)
                            .stroke(settings.mode == mode
                                ? Color(hex: "#a78bfa").opacity(0.5)
                                : Color.clear, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(settings.mode.description)
                .font(.system(size: 10)).foregroundColor(.secondary)
        }
    }

    // MARK: - Image Source Picker

    var imageSourcePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            label("Imagen fuente")

            // Quick source buttons
            HStack(spacing: 6) {

                // Desde personaje activo
                sourceButton(
                    icon:    "person.crop.square.filled.and.at.rectangle",
                    label:   charEng.activeCharacter?.name ?? "Personaje",
                    enabled: charEng.activeCharacter != nil,
                    color:   Color(hex: "#3de3c0")
                ) {
                    if let char = charEng.activeCharacter,
                       let img  = CharacterEngine.shared.loadBaseImage(for: char) {
                        sourceImage = img
                        sourceLabel = char.name
                    }
                }

                // Desde escena activa
                sourceButton(
                    icon:    "photo.on.rectangle.angled",
                    label:   sceneEng.activeScene?.name ?? "Escena",
                    enabled: sceneEng.activeScene != nil,
                    color:   Color(hex: "#f7a26a")
                ) {
                    if let scene = sceneEng.activeScene,
                       let img   = SceneEngine.shared.loadReferenceImage(for: scene) {
                        sourceImage = img
                        sourceLabel = scene.name
                    }
                }

                // Desde resultado anterior
                sourceButton(
                    icon:    "arrow.uturn.backward.circle",
                    label:   "Anterior",
                    enabled: engine.resultImage != nil,
                    color:   Color(hex: "#a78bfa")
                ) {
                    if let prev = engine.resultImage {
                        sourceImage = prev
                        sourceLabel = "Resultado anterior"
                    }
                }

                // Desde archivo
                sourceButton(
                    icon:    "folder",
                    label:   "Archivo",
                    enabled: true,
                    color:   .secondary
                ) { pickImage() }
            }

            // Preview de imagen fuente
            if let img = sourceImage {
                HStack(spacing: 10) {
                    Image(nsImage: img)
                        .resizable().scaledToFill()
                        .frame(width: 50, height: 50)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sourceLabel)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white)
                        Text("\(Int(img.size.width))×\(Int(img.size.height))")
                            .font(.system(size: 10)).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: { sourceImage = nil; sourceLabel = "Ninguna" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14)).foregroundColor(.secondary)
                    }.buttonStyle(.plain)
                }
                .padding(10)
                .background(Color.white.opacity(0.04))
                .cornerRadius(8)
            }
        }
    }

    func sourceButton(icon: String, label: String, enabled: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                Text(label)
                    .font(.system(size: 9))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 8)
            .foregroundColor(enabled ? color : color.opacity(0.3))
            .background(enabled ? color.opacity(0.08) : Color.white.opacity(0.02))
            .cornerRadius(7)
        }
        .buttonStyle(.plain).disabled(!enabled)
    }

    // MARK: - Config Panel

    var configPanel: some View {
        VStack(spacing: 10) {
            // Denoise
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    label("Fuerza de cambio (denoise)")
                    Spacer()
                    Text(String(format: "%.2f", settings.denoiseStrength))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color(hex: "#a78bfa"))
                }
                Slider(value: $settings.denoiseStrength, in: 0.05...1.0, step: 0.05)
                    .accentColor(Color(hex: "#a78bfa"))
                HStack {
                    Text("Sutil").font(.system(size: 9)).foregroundColor(.secondary)
                    Spacer()
                    Text("Radical").font(.system(size: 9)).foregroundColor(.secondary)
                }
            }

            HStack(spacing: 12) {
                // Steps
                VStack(alignment: .leading, spacing: 4) {
                    label("Steps")
                    Stepper(value: $settings.steps, in: 10...60, step: 5) {
                        Text("\(settings.steps)")
                            .font(.system(size: 12, design: .monospaced)).foregroundColor(.white)
                    }
                }
                Divider().frame(height: 30).background(Color.white.opacity(0.08))
                // CFG
                VStack(alignment: .leading, spacing: 4) {
                    label("CFG")
                    Stepper(value: $settings.cfgScale, in: 1...20, step: 0.5) {
                        Text(String(format: "%.1f", settings.cfgScale))
                            .font(.system(size: 12, design: .monospaced)).foregroundColor(.white)
                    }
                }
            }
            .padding(10).background(Color.white.opacity(0.03)).cornerRadius(8)

            // Dimensiones
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    label("Ancho")
                    dimensionPicker($settings.width)
                }
                VStack(alignment: .leading, spacing: 4) {
                    label("Alto")
                    dimensionPicker($settings.height)
                }
                VStack(alignment: .leading, spacing: 4) {
                    label("Resize")
                    Picker("", selection: $settings.resizeMode) {
                        Text("Fit").tag(0)
                        Text("Crop").tag(1)
                        Text("Fill").tag(2)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .frame(width: 100)
                }
            }
        }
        .padding(12).background(Color.white.opacity(0.03)).cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }

    func dimensionPicker(_ binding: Binding<Int>) -> some View {
        Picker("", selection: binding) {
            ForEach([512, 640, 768, 896, 1024], id: \.self) { v in
                Text("\(v)").tag(v)
            }
        }
        .pickerStyle(.menu).labelsHidden()
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.06)).cornerRadius(6)
    }

    // MARK: - Prompt Override

    var promptOverride: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                label("Prompt (usa el de la sesión si está vacío)")
                Spacer()
                Button("Usar sesión") {
                    // prompt y negative ya están como bindings del ContentView
                }
                .buttonStyle(.plain).font(.system(size: 10)).foregroundColor(Color(hex: "#a78bfa"))
            }
            Text("Prompt y negativo vienen del panel principal. Img2Img los hereda automáticamente.")
                .font(.system(size: 10)).foregroundColor(.secondary)
        }
    }

    // MARK: - Generate Button

    var generateButton: some View {
        Button(action: { Task { await runGeneration() } }) {
            HStack(spacing: 8) {
                if engine.isGenerating {
                    ProgressView().controlSize(.small).tint(.white)
                    Text(engine.progressText.isEmpty ? "Generando…" : engine.progressText)
                        .font(.system(size: 12, weight: .semibold))
                } else {
                    Image(systemName: settings.mode.icon)
                    Text("Generar · \(settings.mode.rawValue)")
                        .font(.system(size: 13, weight: .bold))
                }
            }
            .frame(maxWidth: .infinity).padding(.vertical, 12)
            .background(canGenerate
                ? LinearGradient(colors: [Color(hex: "#a78bfa"), Color(hex: "#7c6af7")],
                                 startPoint: .leading, endPoint: .trailing)
                : LinearGradient(colors: [Color.gray.opacity(0.3), Color.gray.opacity(0.3)],
                                 startPoint: .leading, endPoint: .trailing))
            .foregroundColor(.white)
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
        .disabled(!canGenerate || engine.isGenerating)
    }

    var canGenerate: Bool { sourceImage != nil && !prompt.isEmpty }

    // MARK: - Result Panel

    var resultPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                label("Resultado")
                Spacer()
                if let job = engine.lastJob, let seed = job.resultSeed {
                    Text("Seed: \(seed)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            if engine.isGenerating {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04))
                        .frame(height: 160)
                    VStack(spacing: 10) {
                        ProgressView(value: engine.progress)
                            .frame(width: 180).accentColor(Color(hex: "#a78bfa"))
                        Text(engine.progressText).font(.system(size: 11)).foregroundColor(.secondary)
                    }
                }
            } else if let img = engine.resultImage {
                Image(nsImage: img)
                    .resizable().scaledToFit()
                    .frame(maxHeight: 280)
                    .cornerRadius(10)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: "#a78bfa").opacity(0.3), lineWidth: 1))

                HStack(spacing: 8) {
                    // Reutilizar como fuente para nueva iteración
                    Button(action: { sourceImage = img; sourceLabel = "Resultado anterior" }) {
                        Label("Re-iterar", systemImage: "arrow.uturn.backward.circle")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color(hex: "#a78bfa").opacity(0.12))
                    .foregroundColor(Color(hex: "#a78bfa")).cornerRadius(6)

                    // Guardar en vault
                    Button(action: { saveResultToVault() }) {
                        Label("Guardar", systemImage: "arrow.down.circle")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.white.opacity(0.06))
                    .foregroundColor(.white).cornerRadius(6)

                    Spacer()

                    if let job = engine.lastJob, let dur = job.duration {
                        Text(String(format: "%.1fs", dur))
                            .font(.system(size: 10)).foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(12).background(Color.white.opacity(0.03)).cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(hex: "#a78bfa").opacity(0.15), lineWidth: 1))
    }

    // MARK: - History Panel

    var historyPanel: some View {
        Group {
            if engine.jobHistory.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 28)).foregroundColor(.white.opacity(0.08))
                    Text("Sin historial").font(.system(size: 12)).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity).padding(40)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(engine.jobHistory.prefix(30)) { job in
                            historyRow(job)
                            Divider().background(Color.white.opacity(0.04))
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    func historyRow(_ job: Img2ImgJob) -> some View {
        HStack(spacing: 10) {
            Image(systemName: job.mode.icon)
                .font(.system(size: 12))
                .foregroundColor(job.status == .success ? Color(hex: "#a78bfa") : .red)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(job.mode.rawValue).font(.system(size: 11, weight: .medium)).foregroundColor(.white)
                Text(job.prompt.truncated(40)).font(.system(size: 10)).foregroundColor(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: "%.2f dn", job.denoiseStrength))
                    .font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary)
                if let dur = job.duration {
                    Text(String(format: "%.1fs", dur))
                        .font(.system(size: 9)).foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
    }

    // MARK: - Actions

    private func runGeneration() async {
        guard let src = sourceImage else { return }

        switch settings.mode {
        case .characterFix:
            await engine.generateFromActiveCharacter(
                prompt: prompt, negative: negative,
                settings: settings, baseURL: baseURL, checkpoint: checkpoint
            )
        case .sceneFit:
            await engine.generateFromActiveScene(
                prompt: prompt, negative: negative,
                settings: settings, baseURL: baseURL, checkpoint: checkpoint
            )
        default:
            await engine.generate(
                sourceImage: src, prompt: prompt, negative: negative,
                settings: settings, baseURL: baseURL, checkpoint: checkpoint
            )
        }
    }

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .webP]
        panel.canChooseFiles = true
        panel.title = "Seleccionar imagen fuente"
        guard panel.runModal() == .OK,
              let url = panel.url,
              let img = NSImage(contentsOf: url) else { return }
        sourceImage = img
        sourceLabel = url.lastPathComponent
    }

    private func saveResultToVault() {
        guard let img = engine.resultImage,
              let job = engine.lastJob else { return }
        Task {
            let req = SDRequest(
                prompt:            job.prompt,
                negativePrompt:    job.negativePrompt,
                seed:              job.resultSeed ?? -1,
                steps:             job.steps,
                cfgScale:          job.cfgScale,
                width:             job.width,
                height:             job.height,
                samplerName:       job.samplerName,
                enableHR:          false,
                hrUpscaler:        "",
                hrScale:           1.0,
                hrSecondPassSteps: 0,
                denoisingStrength: job.denoiseStrength,
                restoreFaces:      false
            )
            await AssetStore.shared.saveAsset(
                image:      img,
                request:    req,
                seed:       job.resultSeed,
                sessionTag: "img2img"
            )
        }
    }

    // MARK: - Label helper

    func label(_ text: String) -> some View {
        Text(text).font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
    }
}
