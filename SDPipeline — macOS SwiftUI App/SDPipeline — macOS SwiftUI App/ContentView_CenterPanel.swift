import SwiftUI
import AppKit

// MARK: - ContentView+CenterPanel
//
// Implementación completa de las secciones del panel central (centerPanel).

extension ContentView {

    // MARK: - Prompt Section

    var promptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Prompt", icon: "text.bubble.fill")

            // Positive
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Positivo").font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Color(hex: "#34d399"))
                    Spacer()
                    // Character injection indicator
                    if CharacterEngine.shared.activeCharacter != nil {
                        Label("Personaje activo", systemImage: "person.fill")
                            .font(.system(size: 9)).foregroundColor(Color(hex: "#7c6af7"))
                    }
                    // IP-Adapter indicator
                    if IPAdapterEngine.shared.isEnabled {
                        Label("IP", systemImage: "person.fill.viewfinder")
                            .font(.system(size: 9)).foregroundColor(Color(hex: "#7c6af7"))
                    }
                }

                if parsedPrompt.isEmpty {
                    Text("Parsea el JSON para generar el prompt…")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.03)).cornerRadius(6)
                } else {
                    TextEditor(text: $parsedPrompt)
                        .font(.system(size: 10))
                        .foregroundColor(.white)
                        .scrollContentBackground(.hidden)
                        .background(Color.white.opacity(0.04))
                        .frame(height: 72)
                        .cornerRadius(6)
                }
            }

            // Negative
            VStack(alignment: .leading, spacing: 4) {
                Text("Negativo").font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Color(hex: "#ef4444"))
                TextEditor(text: $settings.negativePrompt)
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "#f87171"))
                    .scrollContentBackground(.hidden)
                    .background(Color.white.opacity(0.03))
                    .frame(height: 48)
                    .cornerRadius(6)
            }

            // PromptBuilder toggle
            Button(action: { showPromptBuilder.toggle() }) {
                HStack(spacing: 5) {
                    Image(systemName: "square.stack.3d.up.fill").font(.system(size: 10))
                    Text(showPromptBuilder ? "Ocultar Prompt Builder" : "Abrir Prompt Builder")
                        .font(.system(size: 10))
                }
                .foregroundColor(Color(hex: "#7c6af7"))
            }.buttonStyle(.plain)

            if showPromptBuilder {
                PromptBuilderView(
                    positivePrompt: $parsedPrompt,
                    negativePrompt: $settings.negativePrompt
                )
                .frame(height: 320)
                .cornerRadius(8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.easeInOut(duration: 0.2), value: showPromptBuilder)
            }
        }
        .padding(10).background(Color.white.opacity(0.03)).cornerRadius(8)
    }

    // MARK: - Generation Params Section

    var generationParamsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Parámetros", icon: "slider.horizontal.3")

            // Steps + CFG
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Steps").font(.system(size: 9)).foregroundColor(.secondary)
                    HStack(spacing: 4) {
                        Slider(value: Binding(
                            get: { Double(settings.steps) },
                            set: { settings.steps = Int($0) }
                        ), in: 10...150, step: 1)
                        Text("\(settings.steps)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.white).frame(width: 24)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("CFG Scale").font(.system(size: 9)).foregroundColor(.secondary)
                    HStack(spacing: 4) {
                        Slider(value: $settings.cfgScale, in: 1...20, step: 0.5)
                        Text(String(format: "%.1f", settings.cfgScale))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.white).frame(width: 28)
                    }
                }
            }

            // Sampler
            HStack(spacing: 6) {
                Text("Sampler").font(.system(size: 9)).foregroundColor(.secondary).frame(width: 52, alignment: .leading)
                Picker("", selection: $settings.samplerName) {
                    ForEach(GenerationSettings.availableSamplers, id: \.self) { s in
                        Text(s).tag(s)
                    }
                }.pickerStyle(.menu).font(.system(size: 11))
            }

            // Width × Height
            HStack(spacing: 10) {
                dimensionControl("Ancho", value: $settings.width, range: [512, 640, 768, 832, 1024, 1280])
                dimensionControl("Alto",  value: $settings.height, range: [512, 640, 768, 832, 1024, 1280, 1536])
            }
        }
        .padding(10).background(Color.white.opacity(0.03)).cornerRadius(8)
    }

    private func dimensionControl(_ label: String, value: Binding<Int>, range: [Int]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 9)).foregroundColor(.secondary)
            Picker("", selection: value) {
                ForEach(range, id: \.self) { v in Text("\(v)").tag(v) }
            }.pickerStyle(.menu).font(.system(size: 11))
        }.frame(maxWidth: .infinity)
    }

    // MARK: - Model Section

    var modelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Modelo", icon: "cpu.fill")

            // Checkpoint
            HStack(spacing: 6) {
                Text("Checkpoint").font(.system(size: 9)).foregroundColor(.secondary).frame(width: 70, alignment: .leading)
                Picker("", selection: $settings.checkpoint) {
                    Text("— Sin cambio —").tag("")
                    ForEach(ModelManager.shared.availableModels, id: \.title) { m in
                        Text(m.title.components(separatedBy: "/").last ?? m.title).tag(m.title)
                    }
                }.pickerStyle(.menu).font(.system(size: 11))
            }

            // License badge
            if !settings.checkpoint.isEmpty {
                let (safe, msg) = PipelineConnector.checkLicense(checkpoint: settings.checkpoint)
                HStack(spacing: 5) {
                    Image(systemName: safe ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                        .font(.system(size: 10))
                        .foregroundColor(safe ? Color(hex: "#34d399") : Color(hex: "#f59e0b"))
                    Text(msg ?? (safe ? "Licencia OK" : "Sin licencia"))
                        .font(.system(size: 9)).foregroundColor(.secondary)
                }
            }

            // Model benchmarks inline
            if let model = ModelManager.shared.availableModels.first(where: { $0.title == settings.checkpoint }),
               let bench = ModelManager.shared.benchmarks[model.sha256]?.last {
                HStack(spacing: 10) {
                    benchBadge("Última gen", String(format: "%.1fs", bench.genTime))
                    benchBadge("Steps/s",    String(format: "%.1f", Double(bench.steps) / bench.genTime))
                }
            }
        }
        .padding(10).background(Color.white.opacity(0.03)).cornerRadius(8)
    }

    private func benchBadge(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundColor(.white)
            Text(label).font(.system(size: 9)).foregroundColor(.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color.white.opacity(0.04)).cornerRadius(5)
    }

    // MARK: - Hi-Res Section

    var hiresSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("Hi-Res Fix", icon: "arrow.up.left.and.arrow.down.right")
                Spacer()
                Toggle("", isOn: $settings.enableHR)
                    .toggleStyle(.switch).scaleEffect(0.7).tint(Color(hex: "#7c6af7"))
            }

            if settings.enableHR {
                HStack(spacing: 6) {
                    Text("Upscaler").font(.system(size: 9)).foregroundColor(.secondary).frame(width: 56, alignment: .leading)
                    Picker("", selection: $settings.hrUpscaler) {
                        ForEach(GenerationSettings.availableUpscalers, id: \.self) { u in
                            Text(u).tag(u)
                        }
                    }.pickerStyle(.menu).font(.system(size: 11))
                }
                sliderRow("Escala", value: $settings.hrScale, range: 1.25...4.0, format: "%.2fx")
                sliderRow("Denoising", value: $settings.denoisingStrength, range: 0.1...0.9, format: "%.2f")
                HStack(spacing: 4) {
                    Text("Pasos HR").font(.system(size: 9)).foregroundColor(.secondary).frame(width: 56)
                    Slider(value: Binding(
                        get: { Double(settings.hrSteps) },
                        set: { settings.hrSteps = Int($0) }
                    ), in: 5...50, step: 1)
                    Text("\(settings.hrSteps)").font(.system(size: 10, design: .monospaced)).foregroundColor(.white).frame(width: 24)
                }
            }
        }
        .padding(10).background(Color.white.opacity(0.03)).cornerRadius(8)
    }

    // MARK: - Seed Section

    var seedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Seed", icon: "die.face.6.fill")

            HStack(spacing: 8) {
                // Seed field
                TextField("-1 (random)", value: $settings.seed, format: .number)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Color.white.opacity(0.06)).cornerRadius(6)

                // Randomize
                Button(action: { settings.seed = -1 }) {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 11))
                        .foregroundColor(.secondary)
                }.buttonStyle(.plain).help("Seed aleatorio")

                // Lock/unlock
                Button(action: { settings.seed = settings.seed }) {
                    Image(systemName: settings.seed == -1 ? "lock.open" : "lock.fill")
                        .font(.system(size: 11))
                        .foregroundColor(settings.seed == -1 ? .secondary : Color(hex: "#fbbf24"))
                }.buttonStyle(.plain)
            }

            // Favorites
            let favorites = SeedManager.shared.favorites.prefix(5)
            if !favorites.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(favorites) { fav in
                            Button(action: { settings.seed = fav.seed }) {
                                VStack(spacing: 2) {
                                    Text("\(fav.seed)").font(.system(size: 9, design: .monospaced))
                                        .foregroundColor(Color(hex: "#fbbf24"))
                                    if let hint = fav.promptHint {
                                        Text(hint.prefix(12)).font(.system(size: 7)).foregroundColor(.secondary)
                                    }
                                }
                                .padding(.horizontal, 6).padding(.vertical, 4)
                                .background(Color(hex: "#fbbf24").opacity(0.08)).cornerRadius(5)
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(10).background(Color.white.opacity(0.03)).cornerRadius(8)
    }

    // MARK: - LoRA Section

    var loraSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("LoRAs", icon: "bolt.fill")
                Spacer()
                Text("\(loraManager.selectedLoRAs.count) activos")
                    .font(.system(size: 9)).foregroundColor(.secondary)
            }

            if loraManager.availableLoRAs.isEmpty {
                Text("No hay LoRAs disponibles. Verifica la conexión con A1111.")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            } else {
                ForEach($loraManager.selectedLoRAs, id: \.lora.name) { $selection in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(selection.lora.name.components(separatedBy: "/").last ?? selection.lora.name)
                                .font(.system(size: 10, weight: .medium)).foregroundColor(.white).lineLimit(1)
                            Text("Alias: \(selection.lora.alias ?? "—")")
                                .font(.system(size: 8)).foregroundColor(.secondary)
                        }
                        Slider(value: $selection.weight, in: 0...1.5, step: 0.05)
                        Text(String(format: "%.2f", selection.weight))
                            .font(.system(size: 10, design: .monospaced)).foregroundColor(Color(hex: "#7c6af7")).frame(width: 32)
                        Button(action: { loraManager.deselect(selection.lora) }) {
                            Image(systemName: "xmark").font(.system(size: 9)).foregroundColor(.secondary)
                        }.buttonStyle(.plain)
                    }
                    .padding(6).background(Color.white.opacity(0.04)).cornerRadius(6)
                }

                if loraManager.selectedLoRAs.count < 5 {
                    Menu {
                        ForEach(loraManager.availableLoRAs.filter { lora in
                            !loraManager.selectedLoRAs.contains(where: { $0.lora.name == lora.name })
                        }.prefix(20)) { lora in
                            Button(lora.name.components(separatedBy: "/").last ?? lora.name) {
                                loraManager.select(lora, weight: 0.7)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.circle").font(.system(size: 10))
                            Text("Añadir LoRA").font(.system(size: 10))
                        }
                        .foregroundColor(Color(hex: "#7c6af7"))
                    }
                }
            }
        }
        .padding(10).background(Color.white.opacity(0.03)).cornerRadius(8)
    }

    // MARK: - Character Section

    var characterSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("Personaje", icon: "person.fill")
                Spacer()
                if let char = characterEngine.activeCharacter {
                    Text(char.name).font(.system(size: 10)).foregroundColor(Color(hex: "#7c6af7"))
                }
            }

            if let char = characterEngine.activeCharacter {
                HStack(spacing: 10) {
                    if let path = char.baseImagePath, let img = NSImage(contentsOfFile: path) {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                            .frame(width: 44, height: 44).cornerRadius(6).clipped()
                    } else {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.white.opacity(0.06))
                            .frame(width: 44, height: 44)
                            .overlay(Image(systemName: "person").foregroundColor(.secondary))
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(char.name).font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
                        if let cp = char.preferredCheckpoint, !cp.isEmpty {
                            Text(cp.components(separatedBy: "/").last ?? cp)
                                .font(.system(size: 9)).foregroundColor(.secondary)
                        }
                        Button(action: {
                            Task { await IPAdapterEngine.shared.loadFromCharacter(char) }
                        }) {
                            HStack(spacing: 3) {
                                Image(systemName: IPAdapterEngine.shared.isEnabled
                                      ? "person.fill.viewfinder" : "person.fill.viewfinder")
                                    .font(.system(size: 9))
                                    .foregroundColor(IPAdapterEngine.shared.isEnabled
                                                     ? Color(hex: "#7c6af7") : .secondary)
                                Text(IPAdapterEngine.shared.isEnabled ? "FaceID activo" : "Activar FaceID")
                                    .font(.system(size: 9))
                                    .foregroundColor(IPAdapterEngine.shared.isEnabled
                                                     ? Color(hex: "#7c6af7") : .secondary)
                            }
                        }.buttonStyle(.plain)
                    }

                    Spacer()
                    Button(action: { characterEngine.setActive(nil) }) {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundColor(.secondary)
                    }.buttonStyle(.plain)
                }
                .padding(8).background(Color.white.opacity(0.04)).cornerRadius(8)

            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(characterEngine.characters.prefix(6)) { char in
                            Button(action: { characterEngine.setActive(char) }) {
                                VStack(spacing: 4) {
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(Color.white.opacity(0.06))
                                        .frame(width: 36, height: 36)
                                        .overlay(
                                            Group {
                                                if let path = char.baseImagePath, let img = NSImage(contentsOfFile: path) {
                                                    Image(nsImage: img).resizable()
                                                        .aspectRatio(contentMode: .fill)
                                                        .clipped()
                                                } else {
                                                    Image(systemName: "person.fill")
                                                        .font(.system(size: 14)).foregroundColor(.secondary)
                                                }
                                            }
                                        )
                                        .cornerRadius(5)
                                    Text(char.name.prefix(8)).font(.system(size: 8)).foregroundColor(.secondary)
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                }
                if characterEngine.characters.isEmpty {
                    Text("Crea personajes en el motor de personajes.")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }
            }
        }
        .padding(10).background(Color.white.opacity(0.03)).cornerRadius(8)
    }

    // MARK: - Post-Generation Pipeline Flags

    var pipelineFlagsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Pipeline Post-Generación", icon: "arrow.triangle.2.circlepath")
            VStack(spacing: 6) {
                flagRow("Auto NSFW Check",   icon: "eye.slash",      binding: $settings.autoRunNSFWCheck,  description: "Detecta y cuarentena automáticamente")
                flagRow("Auto ADetailer",    icon: "face.smiling",   binding: $settings.autoRunADetailer,   description: "Refina rostros y manos post-generación")
                flagRow("Auto Post-Prod",    icon: "sparkles",       binding: $settings.autoRunPostProd,    description: "Upscale + restauración automática")
                flagRow("IP-Adapter",        icon: "person.fill.viewfinder", binding: Binding(
                    get: { IPAdapterEngine.shared.isEnabled },
                    set: { IPAdapterEngine.shared.isEnabled = $0; IPAdapterEngine.shared.config.enabled = $0 }
                ), description: "Consistencia facial con imagen de referencia")
                flagRow("IC-Light Relight",  icon: "light.max",      binding: $settings.autoRunICLight,    description: "Relight cinemático post-generación")
            }
            .padding(10).background(Color.white.opacity(0.03)).cornerRadius(8)
        }
    }

    // MARK: - Log Sheet

    var logSheet: some View {
        ZeroKnowledgeLogView()
            .frame(minWidth: 600, minHeight: 400)
    }

    // MARK: - Shared helpers

    func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, format: String) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 9)).foregroundColor(.secondary).frame(width: 56, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: format, value.wrappedValue))
                .font(.system(size: 10, design: .monospaced)).foregroundColor(.white).frame(width: 40)
        }
    }

    func flagRow(_ label: String, icon: String, binding: Binding<Bool>, description: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 11))
                .foregroundColor(binding.wrappedValue ? Color(hex: "#7c6af7") : .secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 11, weight: .medium)).foregroundColor(.white)
                Text(description).font(.system(size: 9)).foregroundColor(.secondary)
            }
            Spacer()
            Toggle("", isOn: binding).toggleStyle(.switch).scaleEffect(0.7).tint(Color(hex: "#7c6af7"))
        }
    }

    func sectionLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 10)).foregroundColor(.secondary)
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
        }
    }
}

extension GenerationSettings {
    static let availableSamplers: [String] = [
        "DPM++ 2M Karras", "DPM++ SDE Karras", "DPM++ 2M SDE Exponential",
        "Euler a", "Euler", "DDIM", "UniPC", "LMS Karras",
        "DPM++ 3M SDE Karras", "Heun"
    ]
    static let availableUpscalers: [String] = [
        "4x-UltraSharp", "4x_NMKD-Siax_200k", "ESRGAN_4x",
        "R-ESRGAN 4x+", "R-ESRGAN 4x+ Anime6B", "Lanczos", "Nearest"
    ]
}
