import SwiftUI
import AppKit

struct ContentView: View {
    // MARK: - State
    @StateObject private var sdService = SDService()
    @State private var jsonInput: String = """
{
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
    @State private var showSettings: Bool = false
    @State private var sdOnline: Bool? = nil

    // MARK: - Body
    var body: some View {
        ZStack {
            Color(red: 0.09, green: 0.09, blue: 0.11).ignoresSafeArea()

            HSplitView {
                // ── LEFT: JSON Input ──────────────────────────────────
                leftPanel
                    .frame(minWidth: 280, idealWidth: 340, maxWidth: 440)

                // ── CENTER: Prompt + Settings ─────────────────────────
                centerPanel
                    .frame(minWidth: 260, idealWidth: 320, maxWidth: 400)

                // ── RIGHT: Image Output ───────────────────────────────
                rightPanel
                    .frame(minWidth: 360, maxWidth: .infinity)
            }
        }
        .task { await checkHealth() }
    }

    // MARK: - Left Panel
    var leftPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader("JSON Input", icon: "curlybraces")

            // Status badge
            HStack(spacing: 6) {
                Circle()
                    .fill(sdOnline == true ? Color.green :
                          sdOnline == false ? Color.red : Color.orange)
                    .frame(width: 7, height: 7)
                Text(sdOnline == true ? "SD Online" :
                     sdOnline == false ? "SD Offline" : "Checking…")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: { Task { await checkHealth() }}) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider().background(Color.white.opacity(0.07))

            // Editor
            ScrollView {
                TextEditor(text: $jsonInput)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .foregroundColor(Color(red: 0.85, green: 0.95, blue: 0.78))
                    .frame(minHeight: 360)
                    .padding(12)
                    .onChange(of: jsonInput) { _ in parseError = nil }
            }
            .background(Color(red: 0.07, green: 0.08, blue: 0.09))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(parseError != nil ? Color.red.opacity(0.5) : Color.white.opacity(0.06),
                            lineWidth: 1)
                    .padding(8)
            )

            if let err = parseError {
                Text("⚠ \(err)")
                    .font(.system(size: 11))
                    .foregroundColor(Color(red: 1, green: 0.45, blue: 0.4))
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
            }

            // Parse button
            Button(action: parseJSON) {
                HStack(spacing: 8) {
                    Image(systemName: "wand.and.stars")
                    Text("Parse & Build Prompt")
                        .font(.system(size: 13, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color(red: 0.2, green: 0.45, blue: 0.9))
                .foregroundColor(.white)
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .padding(14)
        }
        .background(Color(red: 0.1, green: 0.1, blue: 0.13))
    }

    // MARK: - Center Panel
    var centerPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader("Prompt & Settings", icon: "slider.horizontal.3")

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {

                    // Prompt
                    VStack(alignment: .leading, spacing: 6) {
                        label("Prompt")
                        TextEditor(text: $parsedPrompt)
                            .font(.system(size: 13))
                            .scrollContentBackground(.hidden)
                            .foregroundColor(.white.opacity(0.9))
                            .frame(minHeight: 100)
                            .padding(10)
                            .background(Color.white.opacity(0.05))
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
                            )
                    }

                    // Negative prompt
                    VStack(alignment: .leading, spacing: 6) {
                        label("Negative Prompt")
                        TextEditor(text: $settings.negativePrompt)
                            .font(.system(size: 12))
                            .scrollContentBackground(.hidden)
                            .foregroundColor(Color(red: 1, green: 0.6, blue: 0.55))
                            .frame(minHeight: 60)
                            .padding(10)
                            .background(Color.white.opacity(0.04))
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
                            )
                    }

                    Divider().background(Color.white.opacity(0.07))

                    // Steps & CFG
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            label("Steps: \(settings.steps)")
                            Slider(value: Binding(
                                get: { Double(settings.steps) },
                                set: { settings.steps = Int($0) }
                            ), in: 1...150, step: 1)
                            .tint(Color(red: 0.35, green: 0.6, blue: 1.0))
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            label("CFG: \(settings.cfgScale, specifier: "%.1f")")
                            Slider(value: $settings.cfgScale, in: 1...30, step: 0.5)
                                .tint(Color(red: 0.7, green: 0.45, blue: 1.0))
                        }
                    }

                    // Sampler
                    VStack(alignment: .leading, spacing: 6) {
                        label("Sampler")
                        Picker("", selection: $settings.samplerName) {
                            ForEach(GenerationSettings.samplers, id: \.self) { s in
                                Text(s).tag(s)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                        .background(Color.white.opacity(0.06))
                        .cornerRadius(6)
                    }

                    // Resolution
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            label("Width")
                            Stepper("\(settings.width)", value: $settings.width,
                                    in: 64...2048, step: 64)
                                .font(.system(size: 12, design: .monospaced))
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            label("Height")
                            Stepper("\(settings.height)", value: $settings.height,
                                    in: 64...2048, step: 64)
                                .font(.system(size: 12, design: .monospaced))
                        }
                    }

                    // Seed
                    VStack(alignment: .leading, spacing: 6) {
                        label("Seed (-1 = random)")
                        HStack {
                            TextField("-1", value: $settings.seed, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                                .frame(maxWidth: .infinity)
                            Button("🎲") {
                                settings.seed = Int.random(in: 0...Int32.max)
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 16))
                        }
                    }

                    // API URL
                    VStack(alignment: .leading, spacing: 6) {
                        label("SD API Base URL")
                        TextField("http://127.0.0.1:7860", text: $settings.sdBaseURL)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }
                }
                .padding(16)
            }

            Divider().background(Color.white.opacity(0.07))

            // Generate button
            Button(action: generate) {
                HStack(spacing: 8) {
                    if sdService.isGenerating {
                        ProgressView()
                            .scaleEffect(0.7)
                            .progressViewStyle(.circular)
                    } else {
                        Image(systemName: "sparkles")
                    }
                    Text(sdService.isGenerating ? sdService.progressText : "Generate Image")
                        .font(.system(size: 13, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(
                    sdService.isGenerating
                    ? Color(red: 0.25, green: 0.25, blue: 0.28)
                    : Color(red: 0.55, green: 0.25, blue: 0.9)
                )
                .foregroundColor(.white)
                .cornerRadius(8)
                .animation(.easeInOut(duration: 0.2), value: sdService.isGenerating)
            }
            .buttonStyle(.plain)
            .disabled(sdService.isGenerating || parsedPrompt.isEmpty)
            .padding(14)
        }
        .background(Color(red: 0.1, green: 0.1, blue: 0.13))
    }

    // MARK: - Right Panel
    var rightPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with pipeline stage
            HStack {
                Image(systemName: "photo.artframe")
                    .foregroundColor(.secondary)
                Text("Output")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
                Spacer()
                stageBadge
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color.white.opacity(0.03))

            Divider().background(Color.white.opacity(0.07))

            // Image display
            ZStack {
                Color(red: 0.07, green: 0.07, blue: 0.09)

                if let image = sdService.generatedImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(24)
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                } else if sdService.isGenerating {
                    generatingView
                } else if let err = sdService.errorMessage {
                    errorView(err)
                } else {
                    emptyStateView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Bottom bar
            if sdService.stage == .done, let image = sdService.generatedImage {
                Divider().background(Color.white.opacity(0.07))
                HStack(spacing: 16) {
                    if let seed = sdService.lastSeed {
                        Label("Seed: \(seed)", systemImage: "number")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    Text("\(settings.width)×\(settings.height)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button(action: { saveImage(image) }) {
                        Label("Save PNG", systemImage: "square.and.arrow.down")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(Color(red: 0.55, green: 0.8, blue: 1.0))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color(red: 0.15, green: 0.25, blue: 0.4))
                    .cornerRadius(6)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color(red: 0.09, green: 0.09, blue: 0.12))
            }
        }
        .background(Color(red: 0.08, green: 0.08, blue: 0.1))
    }

    // MARK: - Sub-views

    @ViewBuilder
    var stageBadge: some View {
        let (color, text): (Color, String) = {
            switch sdService.stage {
            case .idle:      return (.gray, "Idle")
            case .parsing:   return (.blue, "Parsing")
            case .building:  return (.cyan, "Building")
            case .sending:   return (.orange, "Sending")
            case .receiving: return (.yellow, "Receiving")
            case .done:      return (.green, "Done ✓")
            case .error:     return (.red, "Error")
            }
        }()

        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(color)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(color.opacity(0.12))
        .cornerRadius(20)
    }

    var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "wand.and.sparkles")
                .font(.system(size: 52))
                .foregroundColor(Color.white.opacity(0.1))
            Text("Paste JSON → Parse → Generate")
                .font(.system(size: 14))
                .foregroundColor(Color.white.opacity(0.2))
        }
    }

    var generatingView: some View {
        VStack(spacing: 20) {
            ZStack {
                ForEach(0..<3) { i in
                    Circle()
                        .stroke(
                            Color(red: 0.55, green: 0.25, blue: 0.9).opacity(0.3 - Double(i) * 0.08),
                            lineWidth: 1.5
                        )
                        .frame(width: CGFloat(60 + i * 30), height: CGFloat(60 + i * 30))
                        .scaleEffect(sdService.isGenerating ? 1.15 : 1.0)
                        .animation(
                            .easeInOut(duration: 1.2 + Double(i) * 0.3)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.2),
                            value: sdService.isGenerating
                        )
                }
                ProgressView()
                    .scaleEffect(1.2)
                    .progressViewStyle(.circular)
            }
            .frame(width: 120, height: 120)

            Text(sdService.progressText)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.5))
        }
    }

    func errorView(_ msg: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundColor(Color(red: 1, green: 0.45, blue: 0.4))
            Text("Generation Failed")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))
            Text(msg)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .padding(32)
    }

    // MARK: - Helpers

    func panelHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(.secondary)
                .font(.system(size: 13))
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.03))
    }

    func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.secondary)
            .textCase(.uppercase)
            .tracking(0.5)
    }

    // MARK: - Actions

    func parseJSON() {
        guard let data = jsonInput.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) else {
            parseError = "Invalid string encoding"
            return
        }
        do {
            sdService.stage = .parsing
            let json = try JSONSerialization.jsonObject(with: data)
            parseError = nil
            sdService.stage = .building

            // If the JSON has a "prompt" key, use it directly
            if let direct = PromptBuilder.extractDirectPrompt(from: json) {
                parsedPrompt = direct
            } else {
                parsedPrompt = PromptBuilder.buildPrompt(from: json)
            }
            sdService.stage = .idle
        } catch {
            parseError = error.localizedDescription
            sdService.stage = .error
        }
    }

    func generate() {
        guard !parsedPrompt.isEmpty else { return }
        let req = SDRequest(
            prompt: parsedPrompt,
            negativePrompt: settings.negativePrompt,
            steps: settings.steps,
            cfgScale: settings.cfgScale,
            width: settings.width,
            height: settings.height,
            samplerName: settings.samplerName,
            seed: settings.seed
        )
        Task {
            await sdService.generate(request: req, baseURL: settings.sdBaseURL)
        }
    }

    func checkHealth() async {
        sdOnline = nil
        sdOnline = await sdService.checkHealth(baseURL: settings.sdBaseURL)
    }

    func saveImage(_ image: NSImage) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "sd_output_\(Int(Date().timeIntervalSince1970)).png"
        if panel.runModal() == .OK, let url = panel.url {
            if let tiff = image.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiff),
               let pngData = bitmap.representation(using: .png, properties: [:]) {
                try? pngData.write(to: url)
            }
        }
    }
}

#Preview {
    ContentView()
        .frame(width: 1200, height: 780)
}
