import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    // MARK: - State
    @StateObject private var sdService = SDService()
    @State private var jsonInput: String = """
{
  // NOTESE QUE ESTO ES UN EJEMPLO DE UN JSON //

  "subject": "a lone astronaut",
  "environment": "floating in deep space",
  "style": "cinematic, ultra-detailed, 8k",
  "mood": "ethereal, awe-inspiring",
  "lighting": "rim lighting, nebula glow"
}
"""
    @State private var parsedPrompt: String = ""
    @State private var parseError: String?
    @State private var settings = GenerationSettings()
    @State private var showLog: Bool = false
    @State private var showModelBuilder: Bool = false
    @StateObject private var assetStore = AssetStore.shared
    @StateObject private var loraManager = LoRAManager.shared
    @StateObject private var characterEngine = CharacterEngine.shared
    @StateObject private var sceneEngine = SceneEngine.shared

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
                .frame(minWidth: 360, maxWidth: CGFloat.infinity)
            }
        }
        .task {
            sdService.launchWebUI(
                scriptPath: settings.webuiScriptPath,
                baseURL: settings.sdBaseURL
            )

            GPUMonitor.shared.configure(baseURL: settings.sdBaseURL)
            LoRAManager.shared.configure(baseURL: settings.sdBaseURL)
        }
        .onChange(of: sdService.webuiState) { _, state in
            if case .online = state {
                GPUMonitor.shared.startPolling(interval: 6)
                Task { await LoRAManager.shared.fetchLoRAs() }
            }
        }
        .sheet(isPresented: $showLog) { logSheet }
        .sheet(isPresented: $showModelBuilder) {           // ← NEW
            ModelBuilderSheet { json in
                jsonInput = json
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { parseJSON() }
            }
        }
    }

    // MARK: - Left Panel
    var leftPanel: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header + Model Builder button
            HStack(spacing: 8) {
                Image(systemName: "curlybraces").foregroundColor(.secondary).font(.system(size: 13))
                Text("JSON Input").font(.system(size: 13, weight: .semibold)).foregroundColor(.white.opacity(0.7))
                Spacer()
                Button(action: { showModelBuilder = true }) {
                    HStack(spacing: 5) {
                        Image(systemName: "wand.and.sparkles").font(.system(size: 10, weight: .semibold))
                        Text("Model Builder").font(.system(size: 10, weight: .bold))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(
                        LinearGradient(
                            colors: [Color(red: 0.49, green: 0.42, blue: 0.97),
                                     Color(red: 0.24, green: 0.89, blue: 0.75)],
                            startPoint: .leading, endPoint: .trailing)
                    )
                    .foregroundColor(.white).cornerRadius(6)
                }
                .buttonStyle(.plain).help("Abrir AI Model Builder")
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.03))

            webuiStatusBar
            Divider().background(Color.white.opacity(0.07))

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
            ZStack {
                if case .launching = sdService.webuiState {
                    Circle().fill(dotColor.opacity(0.3)).frame(width: 14, height: 14)
                        .scaleEffect(sdService.webuiState == .launching ? 1.6 : 1.0)
                        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                                   value: sdService.webuiState == .launching)
                }
                Circle().fill(dotColor).frame(width: 7, height: 7)
            }
            Text(label).font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
                .lineLimit(1).truncationMode(.tail)
            Spacer()
            Button(action: { showLog = true }) {
                Image(systemName: "text.alignleft").font(.system(size: 11))
            }.buttonStyle(.plain).foregroundColor(.secondary).help("Show webui.sh output log")

            Button(action: relaunchWebUI) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold))
                    Text("Re-launch").font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color(red: 0.2, green: 0.22, blue: 0.28))
                .foregroundColor(.secondary).cornerRadius(5)
            }.buttonStyle(.plain).help("Kill and re-launch webui.sh --api")
            Divider().frame(height: 14).background(Color.white.opacity(0.15))
            GPUMonitorBar()
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    // MARK: - Log Sheet
    var logSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("webui.sh — output log").font(.system(size: 13, weight: .semibold)).foregroundColor(.white.opacity(0.8))
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
                        .frame(maxWidth: .infinity, alignment: .leading).padding(14).id("logBottom")
                }
                .onChange(of: sdService.webuiLog) { _, _ in proxy.scrollTo("logBottom", anchor: .bottom) }
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
                CharacterPickerView()
                    .padding(.horizontal, 4)
                ScenePickerView()
                    .padding(.horizontal, 4)
                Divider().background(Color.white.opacity(0.07))
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        label("Prompt")
                        TextEditor(text: $parsedPrompt).font(.system(size: 13))
                            .scrollContentBackground(.hidden).foregroundColor(.white.opacity(0.9))
                            .frame(minHeight: 100).padding(10).background(Color.white.opacity(0.05)).cornerRadius(8)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1), lineWidth: 1))
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        label("Negative Prompt")
                        TextEditor(text: $settings.negativePrompt).font(.system(size: 12))
                            .scrollContentBackground(.hidden).foregroundColor(Color(red: 1, green: 0.6, blue: 0.55))
                            .frame(minHeight: 60).padding(10).background(Color.white.opacity(0.04)).cornerRadius(8)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 1))
                    }
                    Divider().background(Color.white.opacity(0.07))
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            label("Steps: \(settings.steps)")
                            Slider(value: Binding(get: { Double(settings.steps) }, set: { settings.steps = Int($0) }), in: 1...150, step: 1)
                                .tint(Color(red: 0.35, green: 0.6, blue: 1.0))
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            label(String(format: "CFG: %.1f", settings.cfgScale))
                            Slider(value: $settings.cfgScale, in: 1...30, step: 0.5).tint(Color(red: 0.7, green: 0.45, blue: 1.0))
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        label("Sampler")
                        Picker("", selection: $settings.samplerName) {
                            ForEach(GenerationSettings.samplers, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.menu).labelsHidden().frame(maxWidth: .infinity)
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
                                .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced)).frame(maxWidth: .infinity)
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
                            TextField("~/automatic1111/stable-diffusion-webui/webui.sh", text: $settings.webuiScriptPath)
                                .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
                            Button(action: browseWebUIScript) {
                                Image(systemName: "folder").font(.system(size: 12))
                            }.buttonStyle(.plain).foregroundColor(.secondary).help("Browse for webui.sh")
                        }
                    }

                    Divider().background(Color.white.opacity(0.07))

                    // ── Hires Fix ────────────────────────────────────
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            label("Hires Fix")
                            Spacer()
                            Toggle("", isOn: $settings.enableHR)
                                .toggleStyle(.switch).labelsHidden()
                                .scaleEffect(0.8)
                        }
                        if settings.enableHR {
                            VStack(alignment: .leading, spacing: 8) {
                                VStack(alignment: .leading, spacing: 4) {
                                    label("Upscaler")
                                    Picker("", selection: $settings.hrUpscaler) {
                                        ForEach(GenerationSettings.hrUpscalers, id: \.self) { Text($0).tag($0) }
                                    }
                                    .pickerStyle(.menu).labelsHidden()
                                    .frame(maxWidth: .infinity)
                                    .background(Color.white.opacity(0.06)).cornerRadius(6)
                                }
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        label(String(format: "Scale ×%.1f", settings.hrScale))
                                        Slider(value: $settings.hrScale, in: 1.25...4.0, step: 0.25)
                                            .tint(Color(red: 0.24, green: 0.89, blue: 0.75))
                                    }
                                    VStack(alignment: .leading, spacing: 4) {
                                        label(String(format: "Denoise %.2f", settings.denoisingStrength))
                                        Slider(value: $settings.denoisingStrength, in: 0.1...0.9, step: 0.05)
                                            .tint(Color(red: 0.49, green: 0.42, blue: 0.97))
                                    }
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    label("HR Steps: \(settings.hrSteps)")
                                    Slider(value: Binding(
                                        get: { Double(settings.hrSteps) },
                                        set: { settings.hrSteps = Int($0) }
                                    ), in: 5...50, step: 1)
                                    .tint(Color(red: 1, green: 0.67, blue: 0.42))
                                }
                            }
                            .padding(10)
                            .background(Color.white.opacity(0.03))
                            .cornerRadius(8)
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(Color(red: 0.24, green: 0.89, blue: 0.75).opacity(0.2), lineWidth: 1))
                        }
                    }

                    // ── Restore Faces ─────────────────────────────────
                    HStack {
                        label("Restore Faces")
                        Spacer()
                        Toggle("", isOn: $settings.restoreFaces)
                            .toggleStyle(.switch).labelsHidden().scaleEffect(0.8)
                    }
                }.padding(16)
            }
            Divider().background(Color.white.opacity(0.07))
            LoRAManagerView()
                .padding(.horizontal, 4)
            Button(action: generate) {
                HStack(spacing: 8) {
                    if sdService.isGenerating { ProgressView().scaleEffect(0.7).progressViewStyle(.circular) }
                    else { Image(systemName: "sparkles") }
                    Text(sdService.isGenerating ? sdService.progressText : "Generate Image")
                        .font(.system(size: 13, weight: .semibold))
                }
                .frame(maxWidth: .infinity).padding(.vertical, 11)
                .background(sdService.isGenerating ? Color(red: 0.25, green: 0.25, blue: 0.28) : Color(red: 0.55, green: 0.25, blue: 0.9))
                .foregroundColor(.white).cornerRadius(8)
                .animation(.easeInOut(duration: 0.2), value: sdService.isGenerating)
            }
            .buttonStyle(.plain).disabled(sdService.isGenerating || parsedPrompt.isEmpty).padding(14)
        }
        .background(Color(red: 0.1, green: 0.1, blue: 0.13))
        .onChange(of: settings.sdBaseURL) { _, newURL in
            GPUMonitor.shared.configure(baseURL: newURL)
            LoRAManager.shared.configure(baseURL: newURL)
        }
    }

    // MARK: - Sub-views
    // NOTE: rightPanel ha sido reemplazado por RightPanelView (Output + Galería tabs)

    @ViewBuilder var stageBadge: some View {
        let (color, text): (Color, String) = {
            switch sdService.stage {
            case .idle: return (.gray, "Idle"); case .parsing: return (.blue, "Parsing")
            case .building: return (.cyan, "Building"); case .sending: return (.orange, "Sending")
            case .receiving: return (.yellow, "Receiving"); case .done: return (.green, "Done ✓")
            case .error: return (.red, "Error")
            }
        }()
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 11, weight: .medium)).foregroundColor(color)
        }
        .padding(.horizontal, 9).padding(.vertical, 4).background(color.opacity(0.12)).cornerRadius(20)
    }

    var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "wand.and.sparkles").font(.system(size: 52)).foregroundColor(Color.white.opacity(0.1))
            Text("Paste JSON → Parse → Generate").font(.system(size: 14)).foregroundColor(Color.white.opacity(0.2))
        }
    }

    var generatingView: some View {
        VStack(spacing: 20) {
            ZStack {
                ForEach(0..<3) { i in
                    Circle().stroke(Color(red: 0.55, green: 0.25, blue: 0.9).opacity(0.3 - Double(i) * 0.08), lineWidth: 1.5)
                        .frame(width: CGFloat(60 + i * 30), height: CGFloat(60 + i * 30))
                        .scaleEffect(sdService.isGenerating ? 1.15 : 1.0)
                        .animation(.easeInOut(duration: 1.2 + Double(i) * 0.3).repeatForever(autoreverses: true).delay(Double(i) * 0.2), value: sdService.isGenerating)
                }
                ProgressView().scaleEffect(1.2).progressViewStyle(.circular)
            }
            .frame(width: 120, height: 120)
            Text(sdService.progressText).font(.system(size: 13, weight: .medium)).foregroundColor(.white.opacity(0.5))
        }
    }

    func errorView(_ msg: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 36)).foregroundColor(Color(red: 1, green: 0.45, blue: 0.4))
            Text("Generation Failed").font(.system(size: 14, weight: .semibold)).foregroundColor(.white.opacity(0.7))
            Text(msg).font(.system(size: 12)).foregroundColor(.secondary).multilineTextAlignment(.center).frame(maxWidth: 300)
        }.padding(32)
    }

    // MARK: - Helpers

    func panelHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundColor(.secondary).font(.system(size: 13))
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(.white.opacity(0.7))
        }
        .padding(.horizontal, 16).padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.03))
    }

    func label(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
            .textCase(.uppercase).tracking(0.5)
    }

    // MARK: - Actions

    /// Aplica ReusableSettings desde la galería al pipeline activo.
    func applyReusable(_ r: ReusableSettings) {
        settings.seed          = r.seed
        settings.steps         = r.steps
        settings.cfgScale      = r.cfgScale
        settings.samplerName   = r.samplerName
        settings.width         = r.width
        settings.height        = r.height
        settings.negativePrompt = r.promptNegative
        if !r.promptPositive.isEmpty {
            parsedPrompt = r.promptPositive
        }
        // Registrar uso del seed en SeedManager
        SeedManager.shared.incrementUsage(seed: r.seed)
    }

    func parseJSON() {
        guard let data = jsonInput.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) else {
            parseError = "Invalid string encoding"; return
        }
        do {
            sdService.stage = .parsing
            let json = try JSONSerialization.jsonObject(with: data)
            parseError = nil; sdService.stage = .building

            // If bare "prompt" key → use directly
            if let direct = PromptBuilder.extractDirectPrompt(from: json) {
                parsedPrompt = direct
            } else {
                // Try editorial schema first, fall back to flat
                let result = PromptBuilder.buildFromEditorialSchema(json)
                parsedPrompt = result.positive
                // Auto-fill negative prompt if builder returned one and field is default/empty
                if !result.negative.isEmpty {
                    settings.negativePrompt = result.negative
                }
            }
            sdService.stage = .idle
        } catch { parseError = error.localizedDescription; sdService.stage = .error }
    }

    func generate() {

        guard !parsedPrompt.isEmpty else { return }

        GPUMonitor.shared.runPreCheck(
            requestedWidth:  settings.width,
            requestedHeight: settings.height
        )

        // Inyectar personaje activo + LoRAs seleccionados
        let withCharacter = CharacterEngine.shared.injectActiveCharacter(into: parsedPrompt)
        let finalPrompt   = LoRAManager.shared.inject(into: withCharacter)

        // Combinar negativos
        let finalNegative = [
            settings.negativePrompt,
            CharacterEngine.shared.activeCharacterNegative
        ]
        .filter { !$0.isEmpty }
        .joined(separator: ", ")

        let req = SDRequest(
            prompt:           finalPrompt,
            negativePrompt:   finalNegative,
            seed:             settings.seed,
            steps:            settings.steps,
            cfgScale:         settings.cfgScale,
            width:            settings.width,
            height:           settings.height,
            samplerName:      settings.samplerName,
            enableHR:         settings.enableHR,
            hrUpscaler:       settings.hrUpscaler,
            hrScale:          settings.hrScale,
            hrSecondPassSteps: settings.hrSteps,
            denoisingStrength: settings.denoisingStrength,
            restoreFaces:     settings.restoreFaces
        )

        Task {
            await sdService.generate(request: req, baseURL: settings.sdBaseURL)
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
        panel.allowedContentTypes = [UTType.png]
        panel.nameFieldStringValue = "sd_output_\(Int(Date().timeIntervalSince1970)).png"
        if panel.runModal() == .OK, let url = panel.url {
            if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
               let png = bitmap.representation(using: .png, properties: [:]) { try? png.write(to: url) }
        }
    }
}

#Preview {
    ContentView().frame(width: 1200, height: 780)
}
