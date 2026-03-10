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
    @State private var validationMsg: String? = nil
    @State private var licenseWarning: String? = nil

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

    // MARK: - Body

    var body: some View {
        ZStack {
            Color(red: 0.09, green: 0.09, blue: 0.11).ignoresSafeArea()
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
        .task {
            // Init systems
            projectManager.createDefaultProjectIfNeeded()
            sdService.launchWebUI(scriptPath: settings.webuiScriptPath, baseURL: settings.sdBaseURL)
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
            // License check on checkpoint change
            guard !checkpoint.isEmpty else { licenseWarning = nil; return }
            let (_, msg) = PipelineConnector.checkLicense(checkpoint: checkpoint)
            licenseWarning = msg
        }
        .onReceive(NotificationCenter.default.publisher(for: .projectDidChange)) { note in
            if let project = note.object as? ProjectManager.Project {
                // Apply project default settings
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
        .sheet(isPresented: $showLog)          { logSheet }
        .sheet(isPresented: $showModelBuilder) {
            ModelBuilderSheet { json in
                jsonInput = json
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { parseJSON() }
            }
        }
        .sheet(isPresented: $showXYPlot) {
            XYPlotView(
                sdService:    sdService,
                settings:     settings,
                parsedPrompt: parsedPrompt
            )
            .frame(width: 700, height: 580)
        }
        .sheet(isPresented: $showNewSession) {
            NewSessionSheet { title, category in
                let session = ContentSessionManager.shared.create(
                    title:    title,
                    category: category
                )
                ContentSessionManager.shared.setActive(session)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showXYPlot))     { _ in showXYPlot    = true }
        .onReceive(NotificationCenter.default.publisher(for: .showNewSession)) { _ in showNewSession = true }
    }

    // MARK: - Left Panel

    var leftPanel: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header with project badge
            HStack(spacing: 8) {
                Image(systemName: "curlybraces")
                    .foregroundColor(.secondary).font(.system(size: 13))
                Text("JSON Input")
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(.white.opacity(0.7))
                Spacer()
                // Project badge
                ProjectBadge()
                // Model Builder button
                Button(action: { showModelBuilder = true }) {
                    HStack(spacing: 5) {
                        Image(systemName: "wand.and.sparkles").font(.system(size: 10, weight: .semibold))
                        Text("Model Builder").font(.system(size: 10, weight: .bold))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(LinearGradient(
                        colors: [Color(hex: "#7c6af7"), Color(hex: "#3de3c0")],
                        startPoint: .leading, endPoint: .trailing))
                    .foregroundColor(.white).cornerRadius(6)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.03))

            webuiStatusBar
            Divider().background(Color.white.opacity(0.07))

            sessionBanner
            Divider().background(Color.white.opacity(0.05))

            // License warning
            if let licenseWarn = licenseWarning {
                HStack(spacing: 6) {
                    Image(systemName: "doc.badge.exclamationmark")
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "#f59e0b"))
                    Text(licenseWarn)
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "#f59e0b"))
                        .lineLimit(2)
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Color(hex: "#f59e0b").opacity(0.08))
                Divider().background(Color.white.opacity(0.05))
            }

            // JSON editor
            ScrollView {
                TextEditor(text: $jsonInput)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .foregroundColor(Color(red: 0.85, green: 0.95, blue: 0.78))
                    .frame(minHeight: 360).padding(12)
            }
            .background(Color(red: 0.09, green: 0.09, blue: 0.11))

            // Parse error banner
            if let err = parseError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 11)).foregroundColor(Color(hex: "#ef4444"))
                    Text(err).font(.system(size: 10)).foregroundColor(Color(hex: "#ef4444"))
                        .lineLimit(2)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color(hex: "#ef4444").opacity(0.08))
            }

            // Validation message
            if let msg = validationMsg {
                HStack(spacing: 6) {
                    Image(systemName: msg.hasPrefix("🚫") ? "xmark.shield.fill" : "exclamationmark.shield")
                        .font(.system(size: 10))
                        .foregroundColor(msg.hasPrefix("🚫") ? Color(hex: "#ef4444") : Color(hex: "#f59e0b"))
                    Text(msg).font(.system(size: 10))
                        .foregroundColor(msg.hasPrefix("🚫") ? Color(hex: "#ef4444") : Color(hex: "#f59e0b"))
                        .lineLimit(2)
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background((msg.hasPrefix("🚫") ? Color(hex: "#ef4444") : Color(hex: "#f59e0b")).opacity(0.08))
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.easeInOut, value: validationMsg)
            }

            Divider().background(Color.white.opacity(0.07))
            parseButton
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
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

    // MARK: - Helpers (stubs for compilation — real implementations from ContentView)

    var webuiStatusBar: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(webuiStatusColor)
                .frame(width: 6, height: 6)
            Text(webuiStatusText)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(Color.white.opacity(0.02))
    }

    var webuiStatusColor: Color {
        switch sdService.webuiState {
        case .online:   return Color(hex: "#34d399")
        case .launching: return Color(hex: "#f59e0b")
        case .error:    return Color(hex: "#ef4444")
        case .stopped:  return .gray
        }
    }

    var webuiStatusText: String {
        switch sdService.webuiState {
        case .online:   return "Stable Diffusion online"
        case .launching: return "Iniciando WebUI…"
        case .error(let msg): return "Error: \(msg.truncated(40))"
        case .stopped:  return "WebUI detenido"
        }
    }

    var sessionBanner: some View {
        Group {
            if let session = sessionManager.activeSession {
                HStack(spacing: 6) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 9))
                        .foregroundColor(Color(hex: "#7c6af7"))
                    Text(session.title)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                    Spacer()
                    Text("\(Int(session.progressPercent * 100))%")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Button(action: { showNewSession = true }) {
                        Image(systemName: "plus")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color(hex: "#7c6af7").opacity(0.06))
            } else {
                Button(action: { showNewSession = true }) {
                    HStack(spacing: 5) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Text("Nueva sesión de contenido")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
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

    var centerHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "slider.horizontal.3")
                .foregroundColor(.secondary).font(.system(size: 12))
            Text("Pipeline Settings")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))
            Spacer()
            // Log button
            Button(action: { showLog = true }) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Color.white.opacity(0.03))
    }

    // These sections are left as stubs — they exist in the original ContentView
    // and only the new additions (ProjectBadge, licenseWarning, projectDidChange handler)
    // are the actual new code in this file.
    var promptSection: some View        { EmptyView() }
    var generationParamsSection: some View { EmptyView() }
    var modelSection: some View         { EmptyView() }
    var hiresSection: some View         { EmptyView() }
    var seedSection: some View          { EmptyView() }
    var loraSection: some View          { EmptyView() }
    var characterSection: some View     { EmptyView() }
    var logSheet: some View             { EmptyView() }

    // MARK: - Actions

    func parseJSON() {
        parseError = nil
        guard !jsonInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        sdService.stage = .parsing
        do {
            guard let data = jsonInput.data(using: .utf8),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { throw NSError(domain: "JSON", code: 0, userInfo: [NSLocalizedDescriptionKey: "JSON inválido"]) }

            // Safety check on JSON
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

            // Validation feedback
            let report = PipelineConnector.validateBeforeGenerate(
                parsedPrompt: parsedPrompt, settings: settings)
            if report.hasIssues {
                validationMsg = report.gpuWarning ?? report.message
                Task {
                    try? await Task.sleep(for: .seconds(5))
                    await MainActor.run { validationMsg = nil }
                }
            }
        } catch { parseError = error.localizedDescription; sdService.stage = .error }
    }

    func generate() {
        guard !parsedPrompt.isEmpty else { return }

        let withCharacter = CharacterEngine.shared.injectActiveCharacter(into: parsedPrompt)
        let withWildcards = WildcardEngine.shared.resolve(withCharacter)
        let finalPrompt   = LoRAManager.shared.inject(into: withWildcards)
        let finalNegative = [settings.negativePrompt, CharacterEngine.shared.activeCharacterNegative]
            .filter { !$0.isEmpty }.joined(separator: ", ")

        // Validation (safety + GPU)
        let report = PipelineConnector.validateBeforeGenerate(
            parsedPrompt: finalPrompt, settings: settings)
        guard report.canProceed else {
            sdService.errorMessage = report.message ?? "Prompt bloqueado."
            return
        }
        if let gpuWarn = report.gpuWarning {
            validationMsg = gpuWarn
        }

        // License check
        if !settings.checkpoint.isEmpty {
            let (safe, msg) = PipelineConnector.checkLicense(checkpoint: settings.checkpoint)
            if !safe {
                licenseWarning = msg
                // Don't block generation for license warnings — just inform
            }
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

            // NSFW detection
            let detection = await NSFWDetector.shared.detect(
                prompt: finalPrompt, image: sdService.generatedImage, baseURL: settings.sdBaseURL)
            NSFWDetector.shared.logResultZK(detection)
            if detection.action == .quarantine {
                ZeroKnowledgeLog.shared.write(
                    category: .nsfwQuarantine,
                    message: "Cuarentena · Level: \(detection.finalLevel.label)",
                    metadata: ["triggers": detection.triggerWords.joined(separator: ","),
                               "prompt": String(finalPrompt.prefix(60))])
            }

            // Seed tracking
            if let seed = sdService.lastSeed, seed > 0 {
                SeedManager.shared.recordUsage(seed: seed, promptHint: String(finalPrompt.prefix(50)),
                                               width: settings.width, height: settings.height)
            }

            // Prompt versioning
            if sdService.generatedImage != nil {
                _ = PromptVersioningStore.shared.save(
                    positive: finalPrompt, negative: finalNegative,
                    steps: settings.steps, cfgScale: settings.cfgScale,
                    samplerName: settings.samplerName, width: settings.width,
                    height: settings.height, checkpoint: settings.checkpoint)

                // Increment project asset count
                projectManager.incrementAssetCount()
            }

            await MainActor.run { validationMsg = nil }
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
