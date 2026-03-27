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
    @State private var validationMsg: String? = nil

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
        .sheet(isPresented: $showLog)          { logSheet }
        .sheet(isPresented: $showModelBuilder) {
            ModelBuilderSheet { json in
                jsonInput = json
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { parseJSON() }
            }
        }
        // FIX v4: XYPlotView necesita sdService + settings + parsedPrompt
        .sheet(isPresented: $showXYPlot) {
            XYPlotView(
                sdService:    sdService,
                settings:     settings,
                parsedPrompt: parsedPrompt
            )
            .frame(width: 700, height: 580)
        }
        // FIX v4: ContentSessionManager.newSession() → .create()
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

            // Header
            HStack(spacing: 8) {
                Image(systemName: "curlybraces")
                    .foregroundColor(.secondary).font(.system(size: 13))
                Text("JSON Input")
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(.white.opacity(0.7))
                Spacer()
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

            // Active session banner
            sessionBanner
            Divider().background(Color.white.opacity(0.05))

            // JSON editor
            ScrollView {
                TextEditor(text: $jsonInput)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .foregroundColor(Color(red: 0.85, green: 0.95, blue: 0.78))
                    .frame(minHeight: 360).padding(12)
                    .onChange(of: jsonInput) { _, _ in parseError = nil }
            }
            .background(Color(red: 0.07, green: 0.08, blue: 0.09))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(parseError != nil ? Color.red.opacity(0.5) : Color.white.opacity(0.06), lineWidth: 1)
                .padding(8))

            if let err = parseError {
                Text("⚠ \(err)").font(.system(size: 11))
                    .foregroundColor(Color(red: 1, green: 0.45, blue: 0.4))
                    .padding(.horizontal, 16).padding(.top, 6)
            }

            if let msg = validationMsg {
                HStack(spacing: 5) {
                    Image(systemName: msg.hasPrefix("🚫") ? "xmark.shield" : "exclamationmark.triangle")
                        .font(.system(size: 10))
                    Text(msg).font(.system(size: 11)).lineLimit(2)
                }
                .foregroundColor(msg.hasPrefix("🚫") ? Color(hex: "#ef4444") : .orange)
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(Color.white.opacity(0.04))
            }

            Button(action: parseJSON) {
                HStack(spacing: 8) {
                    Image(systemName: "wand.and.stars")
                    Text("Parse & Build Prompt").font(.system(size: 13, weight: .semibold))
                }
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(Color(red: 0.2, green: 0.45, blue: 0.9))
                .foregroundColor(.white).cornerRadius(8)
            }
            .buttonStyle(.plain).padding(14)
        }
        .background(Color(red: 0.1, green: 0.1, blue: 0.13))
    }

    // MARK: - Session Banner

    @ViewBuilder
    var sessionBanner: some View {
        if let session = sessionManager.activeSession {
            HStack(spacing: 6) {
                Circle().fill(Color(hex: "#34d399")).frame(width: 6, height: 6)
                Text(session.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.75)).lineLimit(1)
                Spacer()
                Text("\(session.assetCount)/\(session.targetAssetCount)")
                    .font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                Button(action: { showNewSession = true }) {
                    Image(systemName: "plus.circle").font(.system(size: 11))
                        .foregroundColor(.secondary)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(Color(hex: "#34d399").opacity(0.06))
        } else {
            Button(action: { showNewSession = true }) {
                HStack(spacing: 5) {
                    Image(systemName: "plus.circle").font(.system(size: 10))
                    Text("Iniciar sesión de contenido").font(.system(size: 11))
                }
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 6)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - WebUI Status Bar

    @ViewBuilder
    var webuiStatusBar: some View {
        let (dotColor, label): (Color, String) = {
            switch sdService.webuiState {
            case .stopped:        return (.gray,   "SD Stopped")
            case .launching:      return (.orange, "Launching…")
            case .online:         return (.green,  "SD Online")
            case .error(let msg): return (.red,    "Error: \(msg)")
            }
        }()
        HStack(spacing: 6) {
            Circle().fill(dotColor).frame(width: 7, height: 7)
            Text(label).font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
                .lineLimit(1).truncationMode(.tail)
            Spacer()
            Button(action: { showLog = true }) {
                Image(systemName: "text.alignleft").font(.system(size: 11))
            }.buttonStyle(.plain).foregroundColor(.secondary)
            Button(action: relaunchWebUI) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold))
                    Text("Re-launch").font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color(red: 0.2, green: 0.22, blue: 0.28))
                .foregroundColor(.secondary).cornerRadius(5)
            }.buttonStyle(.plain)
            Divider().frame(height: 14).background(Color.white.opacity(0.15))
            GPUMonitorBar()
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    // MARK: - Log Sheet

    var logSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("webui.sh — output log")
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(.white.opacity(0.8))
                Spacer()
                Button("Close") { showLog = false }.buttonStyle(.plain).foregroundColor(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 12).background(Color.white.opacity(0.04))
            Divider().background(Color.white.opacity(0.08))
            ScrollViewReader { proxy in
                ScrollView {
                    Text(sdService.webuiLog.isEmpty ? "(no output yet)" : sdService.webuiLog)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(Color(red: 0.75, green: 0.95, blue: 0.7))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(14).id("bot")
                }
                .onChange(of: sdService.webuiLog) { _, _ in proxy.scrollTo("bot", anchor: .bottom) }
            }
            .background(Color(red: 0.07, green: 0.08, blue: 0.09))
        }
        .frame(width: 680, height: 420).background(Color(red: 0.1, green: 0.1, blue: 0.13))
    }

    // MARK: - Center Panel

    var centerPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader("Prompt & Settings", icon: "slider.horizontal.3")
            ScrollView {
                PromptVersionPickerView(
                    selectedPositive: $parsedPrompt,
                    selectedNegative: $settings.negativePrompt
                ).padding(.horizontal, 4)
                Divider().background(Color.white.opacity(0.07))

                CharacterPickerView().padding(.horizontal, 4)
                ScenePickerView().padding(.horizontal, 4)
                ModelManagerView(baseURL: $settings.sdBaseURL).padding(.horizontal, 4)
                Divider().background(Color.white.opacity(0.07))

                BatchBuilderView(
                    basePrompt:   $parsedPrompt,
                    baseNegative: $settings.negativePrompt,
                    baseURL:      $settings.sdBaseURL,
                    width:        $settings.width,
                    height:       $settings.height
                ).padding(.horizontal, 4)
                Divider().background(Color.white.opacity(0.07))

                PostProductionView(
                    baseURL:     $settings.sdBaseURL,
                    sourceImage: sdService.generatedImage
                ).padding(.horizontal, 4)
                Divider().background(Color.white.opacity(0.07))

                VStack(alignment: .leading, spacing: 16) {
                    // Prompt
                    VStack(alignment: .leading, spacing: 6) {
                        label("Prompt")
                        TextEditor(text: $parsedPrompt)
                            .font(.system(size: 13)).scrollContentBackground(.hidden)
                            .foregroundColor(.white.opacity(0.9)).frame(minHeight: 100)
                            .padding(10).background(Color.white.opacity(0.05)).cornerRadius(8)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1), lineWidth: 1))
                    }
                    // Negative
                    VStack(alignment: .leading, spacing: 6) {
                        label("Negative Prompt")
                        TextEditor(text: $settings.negativePrompt)
                            .font(.system(size: 12)).scrollContentBackground(.hidden)
                            .foregroundColor(Color(red: 1, green: 0.6, blue: 0.55)).frame(minHeight: 60)
                            .padding(10).background(Color.white.opacity(0.04)).cornerRadius(8)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 1))
                    }
                    Divider().background(Color.white.opacity(0.07))
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            label("Steps: \(settings.steps)")
                            Slider(value: Binding(
                                get: { Double(settings.steps) },
                                set: { settings.steps = Int($0) }
                            ), in: 1...150, step: 1).tint(Color(red: 0.35, green: 0.6, blue: 1.0))
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            label(String(format: "CFG: %.1f", settings.cfgScale))
                            Slider(value: $settings.cfgScale, in: 1...30, step: 0.5)
                                .tint(Color(red: 0.7, green: 0.45, blue: 1.0))
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        label("Sampler")
                        Picker("", selection: $settings.samplerName) {
                            ForEach(GenerationSettings.samplers, id: \.self) { Text($0).tag($0) }
                        }.pickerStyle(.menu).labelsHidden().frame(maxWidth: .infinity)
                        .background(Color.white.opacity(0.06)).cornerRadius(6)
                    }
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            label("Width")
                            Stepper("\(settings.width)", value: $settings.width, in: 64...2048, step: 64)
                                .font(.system(size: 12, design: .monospaced))
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            label("Height")
                            Stepper("\(settings.height)", value: $settings.height, in: 64...2048, step: 64)
                                .font(.system(size: 12, design: .monospaced))
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        label("Seed (-1 = random)")
                        HStack {
                            TextField("-1", value: $settings.seed, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced)).frame(maxWidth: .infinity)
                            Button("🎲") { settings.seed = Int.random(in: 0...Int(Int32.max)) }
                                .buttonStyle(.plain).font(.system(size: 16))
                        }
                    }
                    Divider().background(Color.white.opacity(0.07))
                    VStack(alignment: .leading, spacing: 6) {
                        label("SD API Base URL")
                        TextField("http://127.0.0.1:7860", text: $settings.sdBaseURL)
                            .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        label("webui.sh Path")
                        HStack(spacing: 6) {
                            TextField("~/automatic1111/…/webui.sh", text: $settings.webuiScriptPath)
                                .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
                            Button(action: browseWebUIScript) {
                                Image(systemName: "folder").font(.system(size: 12))
                            }.buttonStyle(.plain).foregroundColor(.secondary)
                        }
                    }
                    Divider().background(Color.white.opacity(0.07))
                    hiresFixSection
                    HStack {
                        label("Restore Faces"); Spacer()
                        Toggle("", isOn: $settings.restoreFaces)
                            .toggleStyle(.switch).labelsHidden().scaleEffect(0.8)
                    }
                }
                .padding(16)
            }
            Divider().background(Color.white.opacity(0.07))
            Img2ImgView(
                baseURL: $settings.sdBaseURL, checkpoint: $settings.checkpoint,
                prompt: $parsedPrompt, negative: $settings.negativePrompt
            ).padding(.horizontal, 4)
            LoRAManagerView().padding(.horizontal, 4)
            Button(action: generate) {
                HStack(spacing: 8) {
                    if sdService.isGenerating {
                        ProgressView().scaleEffect(0.7).progressViewStyle(.circular)
                    } else { Image(systemName: "sparkles") }
                    Text(sdService.isGenerating ? sdService.progressText : "Generate Image")
                        .font(.system(size: 13, weight: .semibold))
                }
                .frame(maxWidth: .infinity).padding(.vertical, 11)
                .background(sdService.isGenerating
                    ? Color(red: 0.25, green: 0.25, blue: 0.28) : Color(red: 0.55, green: 0.25, blue: 0.9))
                .foregroundColor(.white).cornerRadius(8)
                .animation(.easeInOut(duration: 0.2), value: sdService.isGenerating)
            }
            .buttonStyle(.plain)
            .disabled(sdService.isGenerating || parsedPrompt.isEmpty)
            .padding(14)
        }
        .background(Color(red: 0.1, green: 0.1, blue: 0.13))
        .onChange(of: settings.sdBaseURL) { _, newURL in
            GPUMonitor.shared.configure(baseURL: newURL)
            LoRAManager.shared.configure(baseURL: newURL)
        }
    }

    // MARK: - Hires Fix

    var hiresFixSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                label("Hires Fix"); Spacer()
                Toggle("", isOn: $settings.enableHR).toggleStyle(.switch).labelsHidden().scaleEffect(0.8)
            }
            if settings.enableHR {
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        label("Upscaler")
                        Picker("", selection: $settings.hrUpscaler) {
                            ForEach(GenerationSettings.hrUpscalers, id: \.self) { Text($0).tag($0) }
                        }.pickerStyle(.menu).labelsHidden().frame(maxWidth: .infinity)
                        .background(Color.white.opacity(0.06)).cornerRadius(6)
                    }
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            label(String(format: "Scale ×%.1f", settings.hrScale))
                            Slider(value: $settings.hrScale, in: 1.25...4.0, step: 0.25)
                                .tint(Color(hex: "#3de3c0"))
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            label(String(format: "Denoise %.2f", settings.denoisingStrength))
                            Slider(value: $settings.denoisingStrength, in: 0.1...0.9, step: 0.05)
                                .tint(Color(hex: "#7c6af7"))
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        label("HR Steps: \(settings.hrSteps)")
                        Slider(value: Binding(
                            get: { Double(settings.hrSteps) },
                            set: { settings.hrSteps = Int($0) }
                        ), in: 5...50, step: 1).tint(.orange)
                    }
                }
                .padding(10).background(Color.white.opacity(0.03)).cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(hex: "#3de3c0").opacity(0.2), lineWidth: 1))
            }
        }
    }

    // MARK: - Helpers

    func panelHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundColor(.secondary).font(.system(size: 13))
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(.white.opacity(0.7))
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.03))
    }

    func label(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
            .textCase(.uppercase).tracking(0.5)
    }

    // MARK: - Actions

    func applyReusable(_ r: ReusableSettings) {
        settings.seed           = r.seed
        settings.steps          = r.steps
        settings.cfgScale       = r.cfgScale
        settings.samplerName    = r.samplerName
        settings.width          = r.width
        settings.height         = r.height
        settings.negativePrompt = r.promptNegative
        if !r.promptPositive.isEmpty { parsedPrompt = r.promptPositive }
        SeedManager.shared.incrementUsage(seed: r.seed)
    }

    func parseJSON() {
        guard let data = jsonInput.trimmingCharacters(in: .whitespacesAndNewlines)
            .data(using: .utf8) else { parseError = "Invalid encoding"; return }
        do {
            sdService.stage = .parsing
            let json = try JSONSerialization.jsonObject(with: data)
            parseError = nil; sdService.stage = .building
            if let direct = PromptBuilder.extractDirectPrompt(from: json) {
                parsedPrompt = direct
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

        let report = PipelineConnector.validateBeforeGenerate(
            parsedPrompt: finalPrompt, settings: settings)
        guard report.canProceed else {
            sdService.errorMessage = report.message ?? "Prompt bloqueado."; return
        }
        if let gpuWarn = report.gpuWarning { validationMsg = gpuWarn }

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

            if let model = ModelManager.shared.availableModels.first(where: { $0.title == settings.checkpoint }) {
                ModelManager.shared.addBenchmark(
                    ModelBenchmark(genTime: genTime, steps: settings.steps,
                                   width: settings.width, height: settings.height,
                                   samplerName: settings.samplerName), to: model.sha256)
            }

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

            if let seed = sdService.lastSeed, seed > 0 {
                SeedManager.shared.recordUsage(seed: seed, promptHint: String(finalPrompt.prefix(50)),
                                               width: settings.width, height: settings.height)
            }
            if sdService.generatedImage != nil {
                _ = PromptVersioningStore.shared.save(
                    positive: finalPrompt, negative: finalNegative,
                    steps: settings.steps, cfgScale: settings.cfgScale,
                    samplerName: settings.samplerName, width: settings.width,
                    height: settings.height, checkpoint: settings.checkpoint)
            }
            await MainActor.run { validationMsg = nil }
        }
    }

    func relaunchWebUI() {
        sdService.launchWebUI(scriptPath: settings.webuiScriptPath, baseURL: settings.sdBaseURL)
    }

    func browseWebUIScript() {
        let panel = NSOpenPanel()
        panel.title = "Select webui.sh"
        panel.allowedContentTypes = [.shellScript, .unixExecutable]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { settings.webuiScriptPath = url.path }
    }

    func saveImage(_ image: NSImage) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "sd_output_\(Int(Date().timeIntervalSince1970)).png"
        if panel.runModal() == .OK, let url = panel.url {
            image.pngData().map { try? $0.write(to: url) }
        }
    }
}

// MARK: - NewSessionSheet

struct NewSessionSheet: View {
    let onConfirm: (String, ContentSessionManager.ContentSession.SessionCategory) -> Void

    @State private var title:    String = ""
    @State private var category: ContentSessionManager.ContentSession.SessionCategory = .editorial
    @State private var platform: ContentSessionManager.ContentSession.TargetPlatform  = .onlyfans
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Text("Nueva Sesión de Contenido")
                .font(.system(size: 15, weight: .bold)).foregroundColor(.white)

            VStack(alignment: .leading, spacing: 6) {
                Text("Título").font(.system(size: 11)).foregroundColor(.secondary)
                TextField("ej: Beach Editorial Marzo 2025", text: $title)
                    .textFieldStyle(.roundedBorder).font(.system(size: 13))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Categoría").font(.system(size: 11)).foregroundColor(.secondary)
                Picker("", selection: $category) {
                    ForEach(ContentSessionManager.ContentSession.SessionCategory.allCases, id: \.self) {
                        Text($0.rawValue).tag($0)
                    }
                }.pickerStyle(.segmented)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Plataforma").font(.system(size: 11)).foregroundColor(.secondary)
                Picker("", selection: $platform) {
                    ForEach(ContentSessionManager.ContentSession.TargetPlatform.allCases, id: \.self) {
                        Text($0.rawValue).tag($0)
                    }
                }.pickerStyle(.segmented)
            }
            HStack {
                Button("Cancelar") { dismiss() }.buttonStyle(.plain).foregroundColor(.secondary)
                Spacer()
                Button("Crear") {
                    guard !title.isEmpty else { return }
                    onConfirm(title, category)
                    dismiss()
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16).padding(.vertical, 7)
                .background(Color(hex: "#7c6af7")).foregroundColor(.white).cornerRadius(7)
                .disabled(title.isEmpty)
            }
        }
        .padding(24).frame(width: 400)
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
    }
}

#Preview {
    ContentView().frame(width: 1400, height: 860)
}
