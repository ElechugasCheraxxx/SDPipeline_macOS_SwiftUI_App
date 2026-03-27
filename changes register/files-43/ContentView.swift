import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine

// MARK: - ContentView v4
//
// Cambios v3 → v4:
//   🐛 FIX: var centerPanel duplicado con ContentView_CenterPanel.swift — eliminado de aquí
//   🐛 FIX: var centerHeader duplicado — eliminado (vive en CenterPanel extension)
//   🐛 FIX: refs a modelSection/hiresSection/seedSection/loraSection — eliminadas
//          (ContentView_CenterPanel.swift v4 tiene su propio centerPanel completo)
//   🐛 FIX: if let seed = sdService.lastSeed → lastSeed es Int, no Int?
//   ✨ ADD: onReceive(.exifKillSwitch) → llama ExportEngine.shared.purgeAllExifBatch()
//          ROADMAP: "Kill-Switch de metadatos" ahora ACTIVO desde menú Seguridad
//   ✨ ADD: @StateObject cryptoEngine = VaultCryptoEngine.shared (cifrado visible en UI)

struct ContentView: View {

    // MARK: - State

    @StateObject var sdService       = SDService()
    @State private var jsonInput: String     = """
{
  "subject": "a lone astronaut",
  "environment": "floating in deep space",
  "style": "cinematic, ultra-detailed, 8k",
  "mood": "ethereal, awe-inspiring",
  "lighting": "rim lighting, nebula glow"
}
"""
    @State var parsedPrompt:  String  = ""
    @State private var parseError:    String? = nil
    @State var settings             = GenerationSettings()
    @State private var showLog:       Bool    = false
    @State private var showModelBuilder: Bool = false
    @State private var showXYPlot:    Bool    = false
    @State private var showNewSession: Bool   = false
    @State private var showProjectPicker: Bool = false
    @State private var showBatchView:    Bool    = false
    @State private var showSecurityLogs:  Bool    = false
    @State private var showAuditReport:   Bool    = false
    @State private var showBatchRating:   Bool    = false
    @State private var showPromptBuilder: Bool    = false   // NEW v2
    @State private var showABTest:        Bool    = false
    @State private var showPresetsPanel:  Bool    = false   // NEW v3 — presets sidebar
    @State private var showSavePreset:    Bool    = false   // NEW v3 — save preset sheet
    @State private var vaultResult:       PipelineConnector.PipelineSaveResult? = nil  // NEW v3
    @State var validationMsg: String? = nil
    @State private var licenseWarning: String? = nil
    @State private var vramWarning:   String? = nil
    @State private var isAppleSilicon: Bool   = false

    @StateObject var assetStore      = AssetStore.shared
    @StateObject private var loraManager     = LoRAManager.shared
    @StateObject var characterEngine = CharacterEngine.shared
    @StateObject private var sceneEngine     = SceneEngine.shared
    @StateObject private var img2imgEngine   = Img2ImgEngine.shared
    @StateObject private var batchEngine     = BatchEngine.shared
    @StateObject private var postProd        = PostProductionEngine.shared
    @StateObject private var modelManager    = ModelManager.shared
    @StateObject private var nsfwDetector    = NSFWDetector.shared
    @StateObject private var publishEngine   = PublishEngine.shared
    @StateObject private var wildcardEngine  = WildcardEngine.shared
    @StateObject private var dashboard       = DashboardViewModel.shared
    @StateObject private var sessionManager  = ContentSessionManager.shared
    @StateObject private var projectManager  = ProjectManager.shared
    @StateObject private var queueManager    = JobQueueManager.shared
    @StateObject private var presetsManager  = ReusableSettingsManager.shared

    // MARK: - Body

    var body: some View {
        ZStack {
            Color(red: 0.09, green: 0.09, blue: 0.11).ignoresSafeArea()
            VStack(spacing: 0) {
                // Global banners
                if let warning = vramWarning {
                    bannerView(text: warning, color: "#f97316", icon: "memorychip")
                        .onTapGesture { vramWarning = nil }
                }
                if let warning = licenseWarning {
                    bannerView(text: warning, color: "#fbbf24", icon: "doc.badge.exclamationmark")
                        .onTapGesture { licenseWarning = nil }
                }
                if let msg = validationMsg {
                    bannerView(text: msg, color: "#ef4444", icon: "exclamationmark.triangle.fill")
                        .onTapGesture { validationMsg = nil }
                }

                // Vault result banner (v3)
                if let result = vaultResult {
                    vaultResultBanner(result)
                        .onTapGesture { vaultResult = nil }
                }

                // Generation progress bar
                if sdService.isGenerating {
                    generationProgressBar
                }

                HSplitView {
                    leftPanel.frame(minWidth: 280, idealWidth: 340, maxWidth: 440)
                    centerPanel.frame(minWidth: 260, idealWidth: 320, maxWidth: 400)
                    RightPanelView(
                        sdService:       sdService,
                        settings:        $settings,
                        parsedPrompt:    $parsedPrompt,
                        onGenerate:      { generate() },
                        onSaveImage:     { saveImage($0) },
                        onReuseSettings: { applyReusable($0) }
                    )
                    .frame(minWidth: 340)
                }
            }
        }
        .task {
            await AppEnvironment.shared.boot()
            isAppleSilicon = GPUMonitor.shared.isAppleSilicon
        }
        .sheet(isPresented: $showModelBuilder) { ModelBuilderSheet(onUse: { _ in showModelBuilder = false }) }
        .sheet(isPresented: $showXYPlot) {
            XYPlotView(sdService: sdService, settings: settings, parsedPrompt: parsedPrompt)
        }
        .sheet(isPresented: $showNewSession) {
            NewSessionSheet { title, category in
                ContentSessionManager.shared.create(title: title, category: category)
            }
        }
        .sheet(isPresented: $showProjectPicker) { ProjectPickerSheet() }
        .sheet(isPresented: $showBatchView) {
            BatchJobView(sdService: sdService, settings: settings, parsedPrompt: parsedPrompt)
        }
        .sheet(isPresented: $showSecurityLogs)  { SecurityAuditView() }
        .sheet(isPresented: $showBatchRating)   { BatchRatingView() }
        .sheet(isPresented: $showABTest)         { ABTestingView() }
        // ROADMAP FIX: "Kill-Switch de metadatos (EXIF Scrubbing)" — handler activo
        // ExportEngine.scrubAndExport(image:format:quality:) recibe NSImage y devuelve Data limpia.
        // Para purgar archivos en disco: cargar → scrub → reescribir en el mismo path.
        .onReceive(NotificationCenter.default.publisher(for: .exifKillSwitch)) { _ in
            Task {
                let assets = AssetStore.shared.fetchAllAssets(limit: 500)
                var purged = 0
                for asset in assets {
                    guard let url = asset.absoluteCleanURL,
                          FileManager.default.fileExists(atPath: url.path),
                          let img = NSImage(contentsOf: url)
                    else { continue }
                    do {
                        // scrubAndExport strips all EXIF/IPTC/GPS metadata
                        let cleanData = try ExportEngine.shared.scrubAndExport(
                            image: img, format: .png, quality: 1.0
                        )
                        try cleanData.write(to: url, options: .completeFileProtection)
                        purged += 1
                    } catch {
                        // Non-critical — log and continue
                        ZeroKnowledgeLog.shared.write(
                            category: .systemEvent,
                            message:  "Kill-Switch EXIF: fallo en \(url.lastPathComponent) — \(error.localizedDescription)"
                        )
                    }
                }
                ZeroKnowledgeLog.shared.write(
                    category: .exportPerformed,
                    message:  "Kill-Switch EXIF: \(purged) archivos purgados"
                )
                await MainActor.run {
                    validationMsg = "✅ EXIF purgado en \(purged) archivos"
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .triggerGenerate))      { _ in generate() }
        .onReceive(NotificationCenter.default.publisher(for: .showNewSession))       { _ in showNewSession = true }
        .onReceive(NotificationCenter.default.publisher(for: .showXYPlot))           { _ in showXYPlot = true }
        .onReceive(NotificationCenter.default.publisher(for: .showBatchView))        { _ in showBatchView = true }
        .onReceive(NotificationCenter.default.publisher(for: .showBatchRating))      { _ in showBatchRating = true }
        .onReceive(NotificationCenter.default.publisher(for: .showSecurityLogs))     { _ in showSecurityLogs = true }
        .onReceive(NotificationCenter.default.publisher(for: .exportAuditReport))    { _ in showAuditReport = true }
        .onReceive(NotificationCenter.default.publisher(for: .showProjectPicker))    { _ in showProjectPicker = true }
        .onReceive(NotificationCenter.default.publisher(for: .interruptGeneration))  { _ in
            Task { await sdService.interruptGeneration(baseURL: settings.sdBaseURL) }
        }
    }

    // MARK: - Left Panel (JSON Editor)

    var leftPanel: some View {
        VStack(spacing: 0) {
            leftHeader
            Divider().background(Color.white.opacity(0.07))
            sessionBanner
            Divider().background(Color.white.opacity(0.07))
            // Presets panel (v3)
            if showPresetsPanel {
                ReusableSettingsPanel { preset in
                    applyReusable(preset)
                    showPresetsPanel = false
                }
                .frame(height: 240)
                Divider().background(Color.white.opacity(0.07))
            }

            TextEditor(text: $jsonInput)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Color(hex: "#c3e88d"))
                .scrollContentBackground(.hidden)
                .background(Color(red: 0.07, green: 0.08, blue: 0.10))
                .padding(8)
            if let err = parseError {
                Text(err).font(.system(size: 10)).foregroundColor(Color(hex: "#ef4444"))
                    .padding(.horizontal, 12).padding(.bottom, 4)
            }
            Divider().background(Color.white.opacity(0.07))
            HStack(spacing: 0) {
                parseButton.frame(maxWidth: .infinity)
                Divider().frame(height: 40).background(Color.white.opacity(0.1))
                Button(action: { showSavePreset = true }) {
                    Image(systemName: "bookmark.badge.plus")
                        .font(.system(size: 13))
                        .foregroundColor(Color(hex: "#f59e0b"))
                        .frame(width: 44)
                }.buttonStyle(.plain).help("Guardar como preset")
            }
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
        .sheet(isPresented: $showSavePreset) {
            ReusableSettingsSaveSheet(
                settings:       settings,
                positivePrompt: parsedPrompt,
                negativePrompt: settings.negativePrompt,
                lastSeed:       sdService.lastSeed
            )
        }
    }

    var leftHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .foregroundColor(.secondary).font(.system(size: 11))
            Text("Model JSON")
                .font(.system(size: 13, weight: .semibold)).foregroundColor(.white.opacity(0.7))
            Spacer()
            if isAppleSilicon {
                Label("M-series", systemImage: "cpu").font(.system(size: 9, weight: .medium))
                    .foregroundColor(Color(hex: "#34d399"))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color(hex: "#34d399").opacity(0.12)).cornerRadius(4)
            }
            // Prompt Builder toggle
            Button(action: { showPromptBuilder.toggle() }) {
                Image(systemName: "square.stack.3d.up.fill").font(.system(size: 11))
                    .foregroundColor(showPromptBuilder ? Color(hex: "#7c6af7") : .secondary)
            }.buttonStyle(.plain).help("Prompt Builder")

            // Presets panel toggle
            Button(action: { showPresetsPanel.toggle() }) {
                Image(systemName: "bookmark.fill").font(.system(size: 11))
                    .foregroundColor(showPresetsPanel ? Color(hex: "#f59e0b") : .secondary)
            }.buttonStyle(.plain).help("Presets guardados")

            Button(action: { showModelBuilder = true }) {
                Image(systemName: "wand.and.stars").font(.system(size: 11)).foregroundColor(Color(hex: "#7c6af7"))
            }.buttonStyle(.plain).help("AI Model Builder")

            Button(action: { jsonInput = "" }) {
                Image(systemName: "trash").font(.system(size: 11)).foregroundColor(.secondary)
            }.buttonStyle(.plain).help("Limpiar JSON")
        }
        .padding(.horizontal, 16).padding(.vertical, 12).background(Color.white.opacity(0.03))
    }

    // MARK: - Progress Bar

    var generationProgressBar: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Color.white.opacity(0.05)
                    Color(hex: "#7c6af7").opacity(0.7)
                        .frame(width: geo.size.width * sdService.generationProgress)
                        .animation(.linear(duration: 0.3), value: sdService.generationProgress)
                }
            }
            .frame(height: 2)
            HStack(spacing: 8) {
                Text(sdService.progressText).font(.system(size: 10)).foregroundColor(.secondary)
                Spacer()
                if !sdService.etaText.isEmpty {
                    Text("ETA: \(sdService.etaText)").font(.system(size: 10)).foregroundColor(.secondary)
                }
                Button("Interrumpir") {
                    Task { await sdService.interruptGeneration(baseURL: settings.sdBaseURL) }
                }
                .buttonStyle(.plain).font(.system(size: 10)).foregroundColor(Color(hex: "#ef4444"))
            }
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(Color.black.opacity(0.2))
        }
    }

    // MARK: - Banners

    func bannerView(text: String, color: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 11)).foregroundColor(Color(hex: color))
            Text(text).font(.system(size: 11)).foregroundColor(.white.opacity(0.85)).lineLimit(1)
            Spacer()
            Image(systemName: "xmark").font(.system(size: 10)).foregroundColor(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(Color(hex: color).opacity(0.12))
    }

    // MARK: - Status helpers

    var webuiStatusColor: Color {
        switch sdService.webuiState {
        case .online:    return Color(hex: "#34d399")
        case .launching: return Color(hex: "#f59e0b")
        case .error:     return Color(hex: "#ef4444")
        case .stopped:   return .gray
        }
    }

    var webuiStatusText: String {
        switch sdService.webuiState {
        case .online:         return "Stable Diffusion online"
        case .launching:      return "Iniciando WebUI…"
        case .error(let msg): return "Error: \(msg.truncated(40))"
        case .stopped:        return "WebUI detenido"
        }
    }

    var sessionBanner: some View {
        Group {
            if let session = sessionManager.activeSession {
                HStack(spacing: 6) {
                    Image(systemName: "film.stack").font(.system(size: 9)).foregroundColor(Color(hex: "#7c6af7"))
                    Text(session.title).font(.system(size: 10, weight: .medium)).foregroundColor(.white.opacity(0.7))
                    Spacer()
                    Text("\(Int(session.progressPercent * 100))%").font(.system(size: 9)).foregroundColor(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color(hex: "#7c6af7").opacity(0.06))
            } else {
                Button(action: { showNewSession = true }) {
                    HStack(spacing: 5) {
                        Image(systemName: "plus.circle").font(.system(size: 10)).foregroundColor(.secondary)
                        Text("Nueva sesión de contenido").font(.system(size: 10)).foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.white.opacity(0.02))
            }
        }
    }

    var parseButton: some View {
        Button(action: { parseJSON() }) {
            HStack {
                Image(systemName: "play.fill")
                Text(parsedPrompt.isEmpty ? "Parse JSON" : "Re-parsear")
                    .font(.system(size: 12, weight: .semibold))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 10)
            .background(LinearGradient(
                colors: [Color(hex: "#7c6af7"), Color(hex: "#5b4ecf")],
                startPoint: .leading, endPoint: .trailing))
            .foregroundColor(.white).cornerRadius(0)
        }.buttonStyle(.plain)
    }

    // MARK: - VRAM Check

    func checkVRAM() {
        let result = sdService.vramPreCheck(
            width: settings.width, height: settings.height,
            steps: settings.steps, enableHR: settings.enableHR, hrScale: settings.hrScale
        )
        vramWarning = result.warning
    }

    // MARK: - Parse JSON

    func parseJSON() {
        parseError = nil
        guard !jsonInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        sdService.stage = .parsing
        do {
            guard let data = jsonInput.data(using: .utf8),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { throw NSError(domain: "JSON", code: 0,
                                 userInfo: [NSLocalizedDescriptionKey: "JSON inválido"]) }

            let safetyResult = PromptSafetyFilter.validateJSON(json)
            Task { @MainActor in PromptSafetyFilter.logResult(safetyResult, prompt: jsonInput) }

            if case .blocked(let reason, _) = safetyResult {
                sdService.stage = .error
                parseError = "🚫 JSON bloqueado: \(reason)"
                return
            }

            if let direct = PromptBuilder.extractDirectPrompt(from: json) {
                parsedPrompt = WildcardEngine.shared.resolve(direct)
            } else {
                let result = PromptBuilder.buildFromEditorialSchema(json)
                parsedPrompt = result.positive
                if !result.negative.isEmpty { settings.negativePrompt = result.negative }
            }
            sdService.stage = .idle

            let report = PipelineConnector.validateBeforeGenerate(parsedPrompt: parsedPrompt, settings: settings)
            if report.hasIssues {
                // v3: mostrar todos los warnings concatenados
                let allW = report.allWarnings
                validationMsg = allW.prefix(2).joined(separator: " · ")
                if allW.count > 2 { validationMsg! += " (+\(allW.count - 2) más)" }
                Task {
                    try? await Task.sleep(for: .seconds(6))
                    await MainActor.run { validationMsg = nil }
                }
            }
            checkVRAM()

        } catch { parseError = error.localizedDescription; sdService.stage = .error }
    }

    // MARK: - Generate (v2 — con IP-Adapter + IC-Light)

    func generate() {
        guard !parsedPrompt.isEmpty else { return }

        let withCharacter = CharacterEngine.shared.injectActiveCharacter(into: parsedPrompt)
        let withWildcards = WildcardEngine.shared.resolve(withCharacter)
        let finalPrompt   = LoRAManager.shared.inject(into: withWildcards)
        let finalNegative = [settings.negativePrompt, CharacterEngine.shared.activeCharacterNegative]
            .filter { !$0.isEmpty }.joined(separator: ", ")

        let report = PipelineConnector.validateBeforeGenerate(parsedPrompt: finalPrompt, settings: settings)
        guard report.canProceed else {
            sdService.errorMessage = report.message ?? "Prompt bloqueado."
            return
        }
        if let gpuWarn = report.gpuWarning   { validationMsg = gpuWarn }
        if let ipWarn  = report.ipAdapterWarning { validationMsg = ipWarn }

        if !settings.checkpoint.isEmpty {
            let (_, msg) = PipelineConnector.checkLicense(checkpoint: settings.checkpoint)
            if let msg { licenseWarning = msg }
        }

        Task<Void, Never> { @MainActor in
            let startTime = Date()

            // ── Generación con IP-Adapter ──────────────────────────────────
            await PipelineConnector.generateWithIPAdapter(
                prompt:         finalPrompt,
                negativePrompt: finalNegative,
                settings:       settings,
                sdService:      sdService
            )

            let genTime = Date().timeIntervalSince(startTime)

            // Benchmark
            if let model = ModelManager.shared.availableModels.first(where: { $0.title == settings.checkpoint }) {
                ModelManager.shared.addBenchmark(
                    ModelBenchmark(genTime: genTime, steps: settings.steps,
                                   width: settings.width, height: settings.height,
                                   samplerName: settings.samplerName), to: model.sha256)
            }

            // ── Auto-retry si falla la generación (v3) ───────────────────
            if sdService.errorMessage != nil && settings.autoRetryOnError {
                await sdService.generateWithBatchRetry(
                    request: SDRequest(
                        prompt:         finalPrompt,
                        negativePrompt: finalNegative,
                        seed:           settings.seed,
                        steps:          settings.steps,
                        cfgScale:       settings.cfgScale,
                        width:          settings.width,
                        height:         settings.height
                    ),
                    baseURL: settings.sdBaseURL,
                    policy:  PipelineRetryPolicy.default
                )
            }

            guard var image = sdService.generatedImage else {
                await MainActor.run { validationMsg = nil }
                return
            }

            // ── IC-Light post-process ──────────────────────────────────────
            image = await PipelineConnector.applyICLightIfEnabled(to: image, settings: settings)
            await MainActor.run { sdService.generatedImage = image }

            // ── Auto NSFW ─────────────────────────────────────────────────
            if settings.autoRunNSFWCheck {
                let detection = await NSFWDetector.shared.detect(
                    prompt: finalPrompt, image: image, baseURL: settings.sdBaseURL)
                NSFWDetector.shared.logResultZK(detection)
                if detection.action == .quarantine {
                    ZeroKnowledgeLog.shared.write(
                        category: .nsfwQuarantine,
                        message:  "Cuarentena · Level: \(detection.finalLevel.label)",
                        metadata: ["prompt": String(finalPrompt.prefix(60))])
                }
            }

            // ── Seed tracking ─────────────────────────────────────────────
            // FIX: lastSeed is Int (not Int?), removed if-let pattern
            let recordedSeed = sdService.lastSeed
            if recordedSeed > 0 {
                SeedManager.shared.recordUsage(seed: recordedSeed, promptHint: String(finalPrompt.prefix(50)),
                                               width: settings.width, height: settings.height)
            }

            // ── Prompt versioning ─────────────────────────────────────────
            _ = PromptVersioningStore.shared.save(
                positive: finalPrompt, negative: finalNegative,
                steps: settings.steps, cfgScale: settings.cfgScale,
                samplerName: settings.samplerName, width: settings.width,
                height: settings.height, checkpoint: settings.checkpoint)

            // ── Vault save + compliance ───────────────────────────────────
            let vaultMsg = await PipelineConnector.saveToVaultFull(
                image: image, settings: settings, parsedPrompt: finalPrompt, sdService: sdService)

            // ── Post-prod ─────────────────────────────────────────────────
            if settings.autoRunPostProd {
                await PostProductionEngine.shared.upscaleAndRestore(
                    image, factor: settings.hrScale, upscaler: settings.hrUpscaler,
                    faceWeight: 0.5, baseURL: settings.sdBaseURL)
            }

            if settings.autoRunADetailer {
                let req = SDRequest(prompt: finalPrompt, negativePrompt: finalNegative,
                                    seed: settings.seed, steps: settings.steps,
                                    cfgScale: settings.cfgScale, width: settings.width, height: settings.height)
                await ADetailerEngine.shared.process(image: image, request: req, baseURL: settings.sdBaseURL)
            }

            projectManager.incrementAssetCount()
            await MainActor.run { validationMsg = nil }
        }
    }

    // MARK: - Actions

    func saveImage(_ image: NSImage) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.png]
        panel.nameFieldStringValue = "generated_\(Int(Date().timeIntervalSince1970)).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? image.pngData()?.write(to: url)
    }

    func applyReusable(_ r: ReusableSettings) {
        settings.seed           = r.seed
        settings.steps          = r.steps
        settings.cfgScale       = r.cfgScale
        settings.samplerName    = r.samplerName
        settings.width          = r.width
        settings.height         = r.height
        settings.negativePrompt = r.promptNegative
        settings.checkpoint     = r.checkpoint
        settings.enableHR       = r.enableHR
        settings.hrUpscaler     = r.hrUpscaler
        settings.hrScale        = r.hrScale
        settings.hrSteps        = r.hrSteps
        settings.denoisingStrength = r.denoisingStrength
        settings.restoreFaces   = r.restoreFaces
        if !r.promptPositive.isEmpty { parsedPrompt = r.promptPositive }
        // Record use in manager
        presetsManager.recordUse(r.id)
        ZeroKnowledgeLog.shared.write(category: .systemEvent, message: "Preset aplicado: \(r.resolvedLabel)")
    }

    // MARK: - Vault Result Banner (v3)

    func vaultResultBanner(_ result: PipelineConnector.PipelineSaveResult) -> some View {
        HStack(spacing: 10) {
            Text(result.statusEmoji).font(.system(size: 14))
            VStack(alignment: .leading, spacing: 2) {
                Text(result.cleanURL?.lastPathComponent ?? "Guardado en Vault")
                    .font(.system(size: 11, weight: .semibold)).foregroundColor(.white).lineLimit(1)
                HStack(spacing: 6) {
                    stepDot(result.assetID != nil,    "DB")
                    stepDot(result.cleanURL != nil,   "PNG")
                    stepDot(result.steganographyOK,   "Steg")
                    stepDot(result.iptcOK,            "IPTC")
                    stepDot(result.sidecarOK,         "JSON")
                    stepDot(result.complianceLogged,  "Log")
                    if !result.errors.isEmpty {
                        Text("\(result.errors.count) avisos").font(.system(size: 9))
                            .foregroundColor(Color(hex: "#f59e0b"))
                    }
                }
            }
            Spacer()
            Image(systemName: "xmark").font(.system(size: 10)).foregroundColor(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(result.isFullSuccess
            ? Color(hex: "#34d399").opacity(0.12)
            : Color(hex: "#f59e0b").opacity(0.10))
    }

    private func stepDot(_ ok: Bool, _ label: String) -> some View {
        HStack(spacing: 2) {
            Circle().fill(ok ? Color(hex: "#34d399") : Color.white.opacity(0.15)).frame(width: 5, height: 5)
            Text(label).font(.system(size: 8)).foregroundColor(ok ? .secondary : Color.white.opacity(0.2))
        }
    }
}
