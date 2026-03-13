import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine

struct ContentView: View {

    // MARK: - State
    @StateObject private var sdService       = SDService()
    @State private var jsonInput: String     = """
{
  "subject": "a lone astronaut",
  "environment": "floating in deep space",
  "style": "cinematic, ultra-detailed, 8k",
  "mood": "ethereal, awe-inspiring",
  "lighting": "rim lighting, nebula glow"
}
"""
    @State private var parsedPrompt:  String  = ""
    @State private var parseError:    String? = nil
    @State private var settings             = GenerationSettings()
    @State private var showLog:       Bool    = false
    @State private var showModelBuilder: Bool = false
    @State private var showXYPlot:    Bool    = false
    @State private var showNewSession: Bool   = false
    @State private var showProjectPicker: Bool = false
    @State private var showBatchView: Bool    = false
    @State private var validationMsg: String? = nil
    @State private var licenseWarning: String? = nil
    @State private var vramWarning:   String? = nil
    @State private var isAppleSilicon: Bool   = false

    @StateObject private var assetStore      = AssetStore.shared
    @StateObject private var loraManager     = LoRAManager.shared
    @StateObject private var characterEngine = CharacterEngine.shared
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
                    .frame(minWidth: 360, maxWidth: .infinity)
                }
            }
        }
        .task {
            isAppleSilicon = GPUMonitor.shared.isAppleSilicon
            projectManager.createDefaultProjectIfNeeded()
            sdService.launchWebUI(
                scriptPath:    settings.webuiScriptPath,
                baseURL:       settings.sdBaseURL,
                appleM1Mode:   isAppleSilicon
            )
            GPUMonitor.shared.configure(baseURL: settings.sdBaseURL)
            LoRAManager.shared.configure(baseURL: settings.sdBaseURL)
            if !settings.sdBaseURL.isEmpty {
                await ModelManager.shared.fetchModels(baseURL: settings.sdBaseURL)
            }
        }
        .onChange(of: sdService.webuiState) { _, state in
            if case .online = state {
                GPUMonitor.shared.startPolling(interval: 6)
                Task {
                    await LoRAManager.shared.fetchLoRAs()
                    await ModelManager.shared.fetchModels(baseURL: settings.sdBaseURL)
                }
            }
        }
        .onChange(of: settings.checkpoint) { _, checkpoint in
            guard !checkpoint.isEmpty else { licenseWarning = nil; return }
            let (_, msg) = PipelineConnector.checkLicense(checkpoint: checkpoint)
            licenseWarning = msg
        }
        .onChange(of: settings.width) { _, _ in checkVRAM() }
        .onChange(of: settings.height) { _, _ in checkVRAM() }
        .onChange(of: settings.enableHR) { _, _ in checkVRAM() }
        .onReceive(NotificationCenter.default.publisher(for: .projectDidChange)) { note in
            if let project = note.object as? ProjectManager.Project {
                settings.checkpoint  = project.defaultCheckpoint
                settings.sdBaseURL   = project.defaultBaseURL
                settings.width       = project.defaultWidth
                settings.height      = project.defaultHeight
                settings.samplerName = project.defaultSampler
                settings.steps       = project.defaultSteps
                settings.cfgScale    = project.defaultCFG
                if !project.defaultNegative.isEmpty {
                    settings.negativePrompt = project.defaultNegative
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .triggerGenerate)) { _ in
            generate()
        }
        .onReceive(NotificationCenter.default.publisher(for: .interruptGeneration)) { _ in
            Task { await sdService.interruptGeneration(baseURL: settings.sdBaseURL) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showXYPlot))     { _ in showXYPlot    = true }
        .onReceive(NotificationCenter.default.publisher(for: .showBatchView))  { _ in showBatchView = true }
        .onReceive(NotificationCenter.default.publisher(for: .showNewSession)) { _ in showNewSession = true }
        .onReceive(NotificationCenter.default.publisher(for: .exifKillSwitch)) { _ in runEXIFKillSwitch() }
        .sheet(isPresented: $showLog)          { logSheet }
        .sheet(isPresented: $showModelBuilder) {
            ModelBuilderSheet { json in
                jsonInput = json
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { parseJSON() }
            }
        }
        .sheet(isPresented: $showXYPlot) {
            XYPlotView(sdService: sdService, settings: settings, parsedPrompt: parsedPrompt)
                .frame(width: 700, height: 580)
        }
        .sheet(isPresented: $showBatchView) {
            BatchJobView().frame(width: 720, height: 560)
        }
        .sheet(isPresented: $showNewSession) {
            NewSessionSheet { title, category in
                sessionManager.create(title: title, category: category, platform: .onlyfans)
                showNewSession = false
            }
        }
        .sheet(isPresented: $showProjectPicker) {
            ProjectPickerSheet()
        }
    }

    // MARK: - Generation Progress Bar

    var generationProgressBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ProgressView(value: sdService.generationProgress)
                    .progressViewStyle(.linear)
                    .tint(Color(hex: "#7c6af7"))
                    .frame(maxWidth: .infinity)

                if !sdService.etaText.isEmpty {
                    Text(sdService.etaText)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 50, alignment: .trailing)
                }

                // Live preview thumbnail
                if let preview = sdService.livePreviewImage {
                    Image(nsImage: preview)
                        .resizable().scaledToFill()
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                // Interrupt button
                Button(action: {
                    Task { await sdService.interruptGeneration(baseURL: settings.sdBaseURL) }
                }) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "#ef4444"))
                }
                .buttonStyle(.plain)
                .help("Interrumpir generación (⌘.)")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)

            Text(sdService.progressText)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.bottom, 4)
        }
        .background(Color.black.opacity(0.25))
    }

    // MARK: - Banner

    func bannerView(text: String, color: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(Color(hex: color))
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(2)
            Spacer()
            Image(systemName: "xmark")
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(Color(hex: color).opacity(0.12))
    }

    // MARK: - Left Panel (JSON input)

    var leftPanel: some View {
        VStack(spacing: 0) {
            leftHeader
            Divider().background(Color.white.opacity(0.07))
            sessionBanner
            Divider().background(Color.white.opacity(0.07))
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
            parseButton
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
    }

    var leftHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .foregroundColor(.secondary).font(.system(size: 11))
            Text("Model JSON")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))
            Spacer()
            if isAppleSilicon {
                Label("M-series", systemImage: "cpu")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(Color(hex: "#34d399"))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color(hex: "#34d399").opacity(0.12))
                    .cornerRadius(4)
            }
            Button(action: { showModelBuilder = true }) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#7c6af7"))
            }.buttonStyle(.plain).help("AI Model Builder")

            Button(action: { jsonInput = "" }) {
                Image(systemName: "trash")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }.buttonStyle(.plain).help("Limpiar JSON")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Color.white.opacity(0.03))
    }

    // MARK: - Center Panel (settings)

    var centerPanel: some View {
        VStack(spacing: 0) {
            centerHeader
            Divider().background(Color.white.opacity(0.07))
            ScrollView {
                VStack(spacing: 14) {
                    promptSection
                    generationParamsSection
                    modelSection
                    pipelineFlagsSection
                    hiresSection
                    seedSection
                    loraSection
                    characterSection
                }
                .padding(14)
            }
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
    }

    var centerHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "slider.horizontal.3")
                .foregroundColor(.secondary).font(.system(size: 12))
            Text("Pipeline Settings")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))
            Spacer()
            // SD status dot
            Circle()
                .fill(webuiStatusColor)
                .frame(width: 7, height: 7)
                .help(webuiStatusText)
            Button(action: { showLog = true }) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 12)).foregroundColor(.secondary)
            }.buttonStyle(.plain).help("Security Logs")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Color.white.opacity(0.03))
    }

    // MARK: - Pipeline Flags Section

    var pipelineFlagsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Post-Generation Pipeline", icon: "arrow.triangle.2.circlepath")
            VStack(spacing: 6) {
                flagRow(
                    "Auto NSFW Check",
                    icon: "eye.slash",
                    binding: $settings.autoRunNSFWCheck,
                    description: "Detecta y cuarentena automáticamente"
                )
                flagRow(
                    "Auto ADetailer",
                    icon: "face.smiling",
                    binding: $settings.autoRunADetailer,
                    description: "Refina rostros y manos post-generación"
                )
                flagRow(
                    "Auto Post-Prod",
                    icon: "sparkles",
                    binding: $settings.autoRunPostProd,
                    description: "Upscale + restauración automática"
                )
            }
            .padding(10)
            .background(Color.white.opacity(0.03))
            .cornerRadius(8)
        }
    }

    func flagRow(_ label: String, icon: String, binding: Binding<Bool>, description: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(binding.wrappedValue ? Color(hex: "#7c6af7") : .secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 11, weight: .medium)).foregroundColor(.white)
                Text(description).font(.system(size: 9)).foregroundColor(.secondary)
            }
            Spacer()
            Toggle("", isOn: binding)
                .toggleStyle(.switch)
                .scaleEffect(0.7)
                .tint(Color(hex: "#7c6af7"))
        }
    }

    // MARK: - Reusable section label

    func sectionLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 10)).foregroundColor(.secondary)
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
        }
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
        case .online:          return "Stable Diffusion online"
        case .launching:       return "Iniciando WebUI…"
        case .error(let msg):  return "Error: \(msg.truncated(40))"
        case .stopped:         return "WebUI detenido"
        }
    }

    var sessionBanner: some View {
        Group {
            if let session = sessionManager.activeSession {
                HStack(spacing: 6) {
                    Image(systemName: "film.stack").font(.system(size: 9))
                        .foregroundColor(Color(hex: "#7c6af7"))
                    Text(session.title)
                        .font(.system(size: 10, weight: .medium)).foregroundColor(.white.opacity(0.7))
                    Spacer()
                    Text("\(Int(session.progressPercent * 100))%")
                        .font(.system(size: 9)).foregroundColor(.secondary)
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
        }
        .buttonStyle(.plain)
    }

    // Placeholder sections — full implementations exist in production ContentView
    var promptSection: some View        { EmptyView() }
    var generationParamsSection: some View { EmptyView() }
    var modelSection: some View         { EmptyView() }
    var hiresSection: some View         { EmptyView() }
    var seedSection: some View          { EmptyView() }
    var loraSection: some View          { EmptyView() }
    var characterSection: some View     { EmptyView() }
    var logSheet: some View             { EmptyView() }

    // MARK: - VRAM Check

    func checkVRAM() {
        let result = sdService.vramPreCheck(
            width:    settings.width,
            height:   settings.height,
            steps:    settings.steps,
            enableHR: settings.enableHR,
            hrScale:  settings.hrScale
        )
        vramWarning = result.warning
    }

    // MARK: - EXIF Kill Switch

    func runEXIFKillSwitch() {
        let assets = assetStore.fetchAllAssets(limit: 1000)
        var scrubbed = 0
        for asset in assets {
            guard let url = asset.absoluteImageURL else { continue }
            // ExportEngine handles EXIF scrubbing via removePNGTextChunks
            if let data = try? Data(contentsOf: url) {
                let clean = ExportEngine.shared.scrubMetadata(from: data)
                try? clean.write(to: url, options: .atomic)
                scrubbed += 1
            }
        }
        ZeroKnowledgeLog.shared.write(
            category: .exportPerformed,
            message:  "EXIF Kill-Switch: scrubbed \(scrubbed) files"
        )
    }

    // MARK: - Actions

    func parseJSON() {
        parseError = nil
        guard !jsonInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        sdService.stage = .parsing
        do {
            guard let data = jsonInput.data(using: .utf8),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { throw NSError(domain: "JSON", code: 0, userInfo: [NSLocalizedDescriptionKey: "JSON inválido"]) }

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
                validationMsg = report.gpuWarning ?? report.message
                Task {
                    try? await Task.sleep(for: .seconds(5))
                    await MainActor.run { validationMsg = nil }
                }
            }

            // VRAM check after parse
            checkVRAM()

        } catch { parseError = error.localizedDescription; sdService.stage = .error }
    }

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
        if let gpuWarn = report.gpuWarning { validationMsg = gpuWarn }

        if !settings.checkpoint.isEmpty {
            let (_, msg) = PipelineConnector.checkLicense(checkpoint: settings.checkpoint)
            if let msg { licenseWarning = msg }
        }

        let req = SDRequest(
            prompt: finalPrompt, negativePrompt: finalNegative,
            seed: settings.seed, steps: settings.steps, cfgScale: settings.cfgScale,
            width: settings.width, height: settings.height, samplerName: settings.samplerName,
            enableHR: settings.enableHR, hrUpscaler: settings.hrUpscaler,
            hrScale: settings.hrScale, hrSecondPassSteps: settings.hrSteps,
            denoisingStrength: settings.denoisingStrength, restoreFaces: settings.restoreFaces
        )

        Task {
            let startTime = Date()
            await sdService.generate(request: req, baseURL: settings.sdBaseURL)
            let genTime = Date().timeIntervalSince(startTime)

            // Benchmark
            if let model = ModelManager.shared.availableModels.first(where: { $0.title == settings.checkpoint }) {
                ModelManager.shared.addBenchmark(
                    ModelBenchmark(genTime: genTime, steps: settings.steps,
                                   width: settings.width, height: settings.height,
                                   samplerName: settings.samplerName), to: model.sha256)
            }

            guard let image = sdService.generatedImage else {
                await MainActor.run { validationMsg = nil }
                return
            }

            // Auto NSFW Check
            if settings.autoRunNSFWCheck {
                let detection = await NSFWDetector.shared.detect(
                    prompt: finalPrompt, image: image, baseURL: settings.sdBaseURL)
                NSFWDetector.shared.logResultZK(detection)
                if detection.action == .quarantine {
                    ZeroKnowledgeLog.shared.write(
                        category: .nsfwQuarantine,
                        message: "Cuarentena · Level: \(detection.finalLevel.label)",
                        metadata: ["prompt": String(finalPrompt.prefix(60))])
                }
            }

            // Seed tracking
            if let seed = sdService.lastSeed, seed > 0 {
                SeedManager.shared.recordUsage(seed: seed, promptHint: String(finalPrompt.prefix(50)),
                                               width: settings.width, height: settings.height)
            }

            // Prompt versioning
            _ = PromptVersioningStore.shared.save(
                positive: finalPrompt, negative: finalNegative,
                steps: settings.steps, cfgScale: settings.cfgScale,
                samplerName: settings.samplerName, width: settings.width,
                height: settings.height, checkpoint: settings.checkpoint)

            // Vault save (async, handled by PipelineConnector)
            let vaultMsg = await PipelineConnector.saveToVaultFull(
                image: image, settings: settings, parsedPrompt: finalPrompt, sdService: sdService)

            // Auto Post-Prod
            if settings.autoRunPostProd {
                await PostProductionEngine.shared.upscaleAndRestore(
                    image, factor: settings.hrScale, upscaler: settings.hrUpscaler,
                    faceWeight: 0.5, baseURL: settings.sdBaseURL)
            }

            // Auto ADetailer
            if settings.autoRunADetailer {
                // ADetailer runs through the queue
                let adetailerReq = req
                await ADetailerEngine.shared.process(image: image, request: adetailerReq, baseURL: settings.sdBaseURL)
            }

            projectManager.incrementAssetCount()
            await MainActor.run { validationMsg = nil }

            print("✅ Generation complete: \(vaultMsg)")
        }
    }

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
        if !r.promptPositive.isEmpty { parsedPrompt = r.promptPositive }
    }
}
