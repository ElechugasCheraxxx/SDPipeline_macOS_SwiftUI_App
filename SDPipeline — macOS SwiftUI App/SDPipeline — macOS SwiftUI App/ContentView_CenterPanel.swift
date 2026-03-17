import SwiftUI
import AppKit

// MARK: - ContentView+CenterPanel v4
//
// Cambios v3 → v4:
//   ✨ ADD: livePreviewSection — thumbnail parcial durante generación + barra de progreso mejorada
//   ✨ ADD: exportQuickSection — acceso rápido a exportar la imagen actual desde el panel central
//   ✨ ADD: rateLimiterStatusRow — indicador del estado del rate limiter en pipelineFlagsSection
//   ✨ ADD: generationMetricsRow — muestra métricas post-generación (seed, tiempo, pasos reales)
//   🔁 UPD: centerPanel ahora incluye livePreviewSection encima del generateButton
//   🔁 UPD: pipelineFlagsSection incluye fila de rate limiter y live preview toggle

extension ContentView {

    // MARK: - Center Panel Assembly

    var centerPanel: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {

                // ── Prompt ──────────────────────────────────────────────────
                promptSection

                // ── Settings rápidos (pasos, CFG, seed, tamaño) ────────────
                generationParamsSection

                // ── Presets favoritos (si hay) ─────────────────────────────
                presetsQuickSection

                // ── Pipeline flags ─────────────────────────────────────────
                pipelineFlagsSection

                // ── Personaje activo ───────────────────────────────────────
                characterSection

                // ── Live Preview (NUEVO v4) ─────────────────────────────────
                livePreviewSection

                // ── Validaciones ────────────────────────────────────────────
                validationSection

                // ── Export rápido post-generación (NUEVO v4) ────────────────
                exportQuickSection

                Spacer(minLength: 20)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
        }
    }

    // MARK: - Prompt Section (v3 compat)

    var promptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Prompt", icon: "text.bubble.fill")
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Positivo").font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Color(hex: "#34d399"))
                    Spacer()
                    if CharacterEngine.shared.activeCharacter != nil {
                        Label("Personaje activo", systemImage: "person.fill")
                            .font(.system(size: 9)).foregroundColor(Color(hex: "#7c6af7"))
                    }
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
                        .font(.system(size: 10)).foregroundColor(.white)
                        .scrollContentBackground(.hidden)
                        .background(Color.white.opacity(0.04))
                        .frame(minHeight: 56, maxHeight: 100)
                        .cornerRadius(6)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Negativo").font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Color(hex: "#f87171"))
                TextEditor(text: $settings.negativePrompt)
                    .font(.system(size: 10)).foregroundColor(.secondary)
                    .scrollContentBackground(.hidden)
                    .background(Color.white.opacity(0.03))
                    .frame(minHeight: 36, maxHeight: 60)
                    .cornerRadius(6)
            }
        }
    }

    // MARK: - Generation Params Section

    var generationParamsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Parámetros", icon: "slider.horizontal.3")

            VStack(spacing: 6) {
                sliderRow("Pasos",   value: Binding(get: { Double(settings.steps) }, set: { settings.steps = Int($0) }),
                          range: 10...80, format: "%.0f")
                sliderRow("CFG",     value: $settings.cfgScale, range: 1...20, format: "%.1f")

                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("ANCHO").font(.system(size: 8, weight: .semibold)).foregroundColor(.secondary).tracking(1)
                        Picker("", selection: $settings.width) {
                            Text("512").tag(512); Text("640").tag(640)
                            Text("768").tag(768); Text("832").tag(832)
                            Text("1024").tag(1024)
                        }
                        .pickerStyle(.menu).font(.system(size: 10)).frame(maxWidth: .infinity)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("ALTO").font(.system(size: 8, weight: .semibold)).foregroundColor(.secondary).tracking(1)
                        Picker("", selection: $settings.height) {
                            Text("512").tag(512); Text("640").tag(640)
                            Text("768").tag(768); Text("832").tag(832)
                            Text("1024").tag(1024)
                        }
                        .pickerStyle(.menu).font(.system(size: 10)).frame(maxWidth: .infinity)
                    }
                }

                HStack(spacing: 6) {
                    Text("Seed").font(.system(size: 9)).foregroundColor(.secondary).frame(width: 56, alignment: .leading)
                    TextField("-1", value: $settings.seed, formatter: NumberFormatter())
                        .textFieldStyle(.plain).font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.white.opacity(0.05)).cornerRadius(5)
                    Button(action: { settings.seed = -1 }) {
                        Image(systemName: "shuffle").font(.system(size: 10)).foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    if sdService.lastSeed > 0 {
                        Button(action: { settings.seed = sdService.lastSeed }) {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.counterclockwise").font(.system(size: 9))
                                Text("\(sdService.lastSeed)").font(.system(size: 9, design: .monospaced))
                            }
                            .foregroundColor(Color(hex: "#7c6af7"))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(10).background(Color.white.opacity(0.03)).cornerRadius(8)
        }
    }

    // MARK: - Live Preview Section (NEW v4)

    @ViewBuilder
    var livePreviewSection: some View {
        let engine = GenerationProgressEngine.shared
        let showLivePreviews = UserDefaults.standard.bool(forKey: "gen.showPartialPreviews")

        if engine.isGenerating || (engine.progress > 0 && engine.progress < 1.0) {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("Generando…", icon: "waveform.path.ecg")

                HStack(alignment: .top, spacing: 12) {
                    // Thumbnail parcial
                    if showLivePreviews {
                        LivePreviewThumbnail(engine: engine, size: 80)
                            .animation(.easeInOut(duration: 0.3), value: engine.previewImage != nil)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        // Barra de progreso avanzada
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(engine.statusLabel)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                Spacer()
                                Text(engine.progressPercent)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(Color(hex: "#7c6af7"))
                                    .monospacedDigit()
                            }
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.white.opacity(0.07))
                                        .frame(height: 5)
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(LinearGradient(
                                            colors: [Color(hex: "#7c6af7"), Color(hex: "#3de3c0")],
                                            startPoint: .leading, endPoint: .trailing))
                                        .frame(width: geo.size.width * engine.progress, height: 5)
                                        .animation(.easeInOut(duration: 0.35), value: engine.progress)
                                }
                            }
                            .frame(height: 5)
                        }

                        // Métricas en tiempo real
                        HStack(spacing: 12) {
                            if engine.totalSteps > 0 {
                                metricPill(
                                    icon: "arrow.trianglehead.2.clockwise",
                                    value: "\(engine.currentStep)/\(engine.totalSteps)",
                                    label: "pasos"
                                )
                            }
                            if !engine.etaFormatted.isEmpty {
                                metricPill(
                                    icon: "timer",
                                    value: engine.etaFormatted,
                                    label: "restante"
                                )
                            }
                        }

                        // Botón interrumpir
                        Button(action: {
                            Task { await sdService.interruptGeneration(baseURL: settings.sdBaseURL) }
                            engine.stopPolling()
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "stop.fill").font(.system(size: 9))
                                Text("Interrumpir").font(.system(size: 10))
                            }
                            .foregroundColor(Color(hex: "#ef4444"))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
                .background(Color(hex: "#7c6af7").opacity(0.07))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(hex: "#7c6af7").opacity(0.15), lineWidth: 1)
                )
            }
        }
    }

    // MARK: - Generation Metrics Row (post-gen)

    @ViewBuilder
    var generationMetricsSection: some View {
        if sdService.lastSeed > 0 && !sdService.isGenerating {
            HStack(spacing: 10) {
                metricPill(icon: "number", value: "\(sdService.lastSeed)", label: "seed")
                if sdService.generationDuration > 0 {
                    metricPill(icon: "stopwatch", value: String(format: "%.1fs", sdService.generationDuration), label: "duración")
                }
            }
            .padding(.vertical, 4)
        }
    }

    func metricPill(icon: String, value: String, label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9)).foregroundColor(.secondary)
            Text(value).font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundColor(.white)
            Text(label).font(.system(size: 8)).foregroundColor(.secondary)
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(Color.white.opacity(0.05))
        .cornerRadius(5)
    }

    // MARK: - Export Quick Section (NEW v4)

    @ViewBuilder
    var exportQuickSection: some View {
        if sdService.generatedImage != nil, !sdService.isGenerating {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("Export Rápido", icon: "square.and.arrow.up")

                HStack(spacing: 8) {
                    // Export limpio (sin watermark)
                    exportQuickButton(
                        label: "Export Limpio",
                        icon: "doc.fill",
                        color: "#3de3c0"
                    ) {
                        exportCurrentImage(withWatermark: false)
                    }

                    // Export preview (con watermark)
                    exportQuickButton(
                        label: "Preview WM",
                        icon: "pencil.and.outline",
                        color: "#7c6af7"
                    ) {
                        exportCurrentImage(withWatermark: true)
                    }

                    // Agregar a lote
                    exportQuickButton(
                        label: "Al Lote",
                        icon: "plus.rectangle.on.rectangle",
                        color: "#f59e0b"
                    ) {
                        enqueueCurrentImageForBatch()
                    }
                }

                // Estado del batch si hay jobs
                if ExportBatchCoordinator.shared.pendingCount > 0 || ExportBatchCoordinator.shared.isRunning {
                    ExportBatchProgressView()
                }
            }
        }
    }

    func exportQuickButton(label: String, icon: String, color: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: color))
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(Color(hex: color).opacity(0.10))
            .cornerRadius(7)
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color(hex: color).opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Export Actions

    func exportCurrentImage(withWatermark: Bool) {
        guard let asset = assetStore.recentAssets.last else { return }
        Task {
            do {
                _ = try await ExportEngine.shared.export(asset: asset, addWatermark: withWatermark)
                let label  = withWatermark ? "preview" : "limpia"
                validationMsg = "✓ Imagen \(label) exportada"
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { validationMsg = nil }
            } catch {
                validationMsg = "Error export: \(error.localizedDescription)"
            }
        }
    }

    func enqueueCurrentImageForBatch() {
        let pending = assetStore.recentAssets.filter {
            $0.statusEnum == .approved || $0.statusEnum == .draft
        }
        guard !pending.isEmpty else { return }
        ExportBatchCoordinator.shared.enqueue(assets: pending, setLabel: "Lote rápido")
        if !ExportBatchCoordinator.shared.isRunning {
            ExportBatchCoordinator.shared.start()
        }
    }

    // MARK: - Pipeline Flags Section (v4 — rate limiter row added)

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
                flagRow("ControlNet",        icon: "network",         binding: Binding(
                    get: { ControlNetEngine.shared.isEnabled },
                    set: { ControlNetEngine.shared.isEnabled = $0 }
                ), description: "Control pose/depth/edge · \(ControlNetEngine.shared.activeUnits.filter { $0.enabled }.count) unidades activas")
                flagRow("Auto-Retry (x3)",   icon: "arrow.counterclockwise.circle", binding: $settings.autoRetryOnError, description: "Reintenta la generación si falla")
                flagRow("Live Preview",      icon: "eye.fill",       binding: Binding(
                    get: { UserDefaults.standard.bool(forKey: "gen.showPartialPreviews") },
                    set: {
                        UserDefaults.standard.set($0, forKey: "gen.showPartialPreviews")
                        GenerationProgressEngine.shared.config.showPartialPreviews = $0
                    }
                ), description: "Muestra el preview parcial durante la generación")

                // Rate Limiter status (NEW v4)
                rateLimiterStatusRow
            }
            .padding(10).background(Color.white.opacity(0.03)).cornerRadius(8)
        }
    }

    @ViewBuilder
    var rateLimiterStatusRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "speedometer")
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#3de3c0"))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text("Rate Limiter API").font(.system(size: 11, weight: .medium)).foregroundColor(.white)
                Text("Protege A1111 de saturación en batch").font(.system(size: 9)).foregroundColor(.secondary)
            }
            Spacer()
            // Indicador de estado del circuit breaker
            Circle()
                .fill(circuitBreakerColor)
                .frame(width: 7, height: 7)
        }
    }

    var circuitBreakerColor: Color {
        // Verde = closed, amarillo = halfOpen, rojo = open
        // Se lee de UserDefaults como proxy (el actor no es MainActor)
        let isOK = UserDefaults.standard.bool(forKey: "rateLimiter.circuitOK")
        return isOK ? Color(hex: "#3de3c0") : Color(hex: "#ef4444")
    }

    // MARK: - Character Section (v3 compat)

    var characterSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Personaje Activo", icon: "person.fill")
            if let activeChar = characterEngine.activeCharacter {
                HStack(spacing: 8) {
                    if let path = activeChar.baseImagePath, let img = NSImage(contentsOfFile: path) {
                        Image(nsImage: img).resizable().scaledToFill()
                            .frame(width: 32, height: 32).clipped().cornerRadius(6)
                    } else {
                        RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06))
                            .frame(width: 32, height: 32)
                            .overlay(Image(systemName: "person.fill").font(.system(size: 14)).foregroundColor(.secondary))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(activeChar.name).font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
                        Text(activeChar.preferredCheckpoint.isEmpty ? "Sin modelo asignado" : activeChar.preferredCheckpoint)
                            .font(.system(size: 9)).foregroundColor(.secondary)
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
                                    RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.06))
                                        .frame(width: 36, height: 36)
                                        .overlay(Group {
                                            if let path = char.baseImagePath, let img = NSImage(contentsOfFile: path) {
                                                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill).clipped()
                                            } else {
                                                Image(systemName: "person.fill").font(.system(size: 14)).foregroundColor(.secondary)
                                            }
                                        })
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

    // MARK: - Validation Section (v3 compat)

    @ViewBuilder
    var validationSection: some View {
        let report = PipelineConnector.validateBeforeGenerate(parsedPrompt: parsedPrompt, settings: settings)
        if report.hasIssues {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10)).foregroundColor(Color(hex: "#f59e0b"))
                    Text("Advertencias de Pipeline")
                        .font(.system(size: 10, weight: .semibold)).foregroundColor(Color(hex: "#f59e0b"))
                    Spacer()
                    if report.blocked {
                        Text("BLOQUEADO").font(.system(size: 8, weight: .bold))
                            .foregroundColor(.white).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color(hex: "#ef4444")).cornerRadius(4)
                    }
                }
                ForEach(report.allWarnings.prefix(4), id: \.self) { warning in
                    HStack(spacing: 6) {
                        Circle().fill(Color(hex: "#f59e0b").opacity(0.6)).frame(width: 4, height: 4)
                        Text(warning).font(.system(size: 9)).foregroundColor(.secondary).lineLimit(2)
                    }
                }
            }
            .padding(10)
            .background(Color(hex: "#f59e0b").opacity(0.08))
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(hex: "#f59e0b").opacity(0.2), lineWidth: 1))
        }
    }

    // MARK: - Presets Quick Section (v3 compat)

    @ViewBuilder
    var presetsQuickSection: some View {
        let favs = ReusableSettingsManager.shared.presets.filter { $0.isFavorite }.prefix(3)
        if !favs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    sectionLabel("Presets Favoritos", icon: "star.fill")
                    Spacer()
                    Text("\(ReusableSettingsManager.shared.presets.count) guardados")
                        .font(.system(size: 9)).foregroundColor(.secondary)
                }
                VStack(spacing: 4) {
                    ForEach(Array(favs)) { preset in
                        Button(action: { applyReusable(preset) }) {
                            HStack(spacing: 8) {
                                Image(systemName: "star.fill").font(.system(size: 9))
                                    .foregroundColor(Color(hex: "#f59e0b"))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(preset.resolvedLabel)
                                        .font(.system(size: 10, weight: .medium)).foregroundColor(.white).lineLimit(1)
                                    Text(preset.summaryLabel)
                                        .font(.system(size: 9)).foregroundColor(.secondary)
                                }
                                Spacer()
                                Image(systemName: "arrow.right.circle").font(.system(size: 10))
                                    .foregroundColor(Color(hex: "#7c6af7"))
                            }
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(Color.white.opacity(0.04)).cornerRadius(7)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(10).background(Color.white.opacity(0.03)).cornerRadius(8)
        }
    }

    func sectionLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 10)).foregroundColor(.secondary)
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
        }
    }
}

// MARK: - GenerationSettings static catalogs (v4)
// NOTE: autoRetryOnError, autoRunICLight, autoRunNSFWCheck are stored properties in Models.swift

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

