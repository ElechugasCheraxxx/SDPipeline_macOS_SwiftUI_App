import SwiftUI
import AppKit

// MARK: - RightPanelView v5
// Tabs: Output | Galería | Batch | Cola | FaceID | Presets | Publicar | KPIs
// Cambios v4 → v5:
//   + Tab "Presets" — ReusableSettingsPanel integrado
//   + vaultImage() usa saveToVaultAtomic con PipelineSaveResult detallado
//   + vaultResultDetail — banner expandible con steg/iptc/sidecar status
//   + bottomBar "Guardar Preset" shortcut
//   + PipelineRetryPolicy visible en vault message
//   + Tab badge "Presets" muestra cuenta de favoritos

struct RightPanelView: View {

    @ObservedObject var sdService:    SDService
    @Binding       var settings:      GenerationSettings
    @Binding       var parsedPrompt:  String

    var onGenerate:      () -> Void
    var onSaveImage:     (NSImage) -> Void
    var onReuseSettings: (ReusableSettings) -> Void

    @State private var activeTab:    PanelTab = .output
    @State private var vaultMessage: String?  = nil
    @State private var isVaulting:   Bool     = false
    @State private var isRelighting:    Bool     = false
    @State private var showACEScg:      Bool     = false
    @State private var vaultSaveResult: PipelineConnector.PipelineSaveResult? = nil   // v5
    @State private var showSavePreset:  Bool     = false   // v5

    @StateObject private var cinematic    = CinematicFilterEngine.shared
    @StateObject private var queue        = JobQueueManager.shared
    @StateObject private var ipAdapter    = IPAdapterEngine.shared
    @StateObject private var icLight      = ICLightEngine.shared
    @StateObject private var editorBridge   = ExternalEditorBridge.shared
    @StateObject private var presetsManager = ReusableSettingsManager.shared

    enum PanelTab: String, CaseIterable {
        case output   = "Output"
        case gallery  = "Galería"
        case batch    = "Batch"
        case queue    = "Cola"
        case ipadapter = "FaceID"
        case presets  = "Presets"
        case publish  = "Publicar"
        case dashboard = "KPIs"

        var icon: String {
            switch self {
            case .output:    return "photo.artframe"
            case .gallery:   return "photo.stack"
            case .batch:     return "square.grid.3x3.fill"
            case .queue:     return "list.bullet.rectangle"
            case .ipadapter: return "person.fill.viewfinder"
            case .presets:   return "bookmark.fill"
            case .publish:   return "arrow.up.to.line"
            case .dashboard: return "chart.bar.xaxis"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider().background(Color.white.opacity(0.06))
            tabContent
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
        .onChange(of: activeTab) { _, tab in
            if tab == .dashboard { DashboardViewModel.shared.refresh() }
        }
        .sheet(isPresented: $showSavePreset) {
            if let img = sdService.generatedImage {
                ReusableSettingsSaveSheet(
                    settings:       settings,
                    positivePrompt: parsedPrompt,
                    negativePrompt: settings.negativePrompt,
                    lastSeed:       sdService.lastSeed
                )
            }
        }
        .sheet(isPresented: $showACEScg) {
            ACEScgSheet(onApply: { grade in
                if let img = sdService.generatedImage {
                    Task {
                        if let result = try? await ACEScgColorEngine.shared.applyGrade(to: img, grade: grade) {
                            await MainActor.run { sdService.generatedImage = result }
                        }
                    }
                }
            })
        }
    }

    // MARK: - Tab Bar

    var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(PanelTab.allCases, id: \.self) { tab in
                tabButton(tab)
            }
            Spacer()
            if activeTab == .output { stageBadge }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.white.opacity(0.03))
    }

    @ViewBuilder
    func tabButton(_ tab: PanelTab) -> some View {
        Button(action: { activeTab = tab }) {
            HStack(spacing: 4) {
                Image(systemName: tab.icon).font(.system(size: 10))
                Text(tab.rawValue).font(.system(size: 10, weight: activeTab == tab ? .semibold : .regular))
                if tab == .queue { queueBadge }
                if tab == .ipadapter && ipAdapter.isEnabled {
                    Circle().fill(Color(hex: "#7c6af7")).frame(width: 5, height: 5)
                }
                if tab == .presets, presetsManager.favoriteCount > 0 {
                    Text("\(presetsManager.favoriteCount)")
                        .font(.system(size: 7, weight: .bold)).foregroundColor(.white)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color(hex: "#f59e0b")).cornerRadius(4)
                }
            }
            .foregroundColor(activeTab == tab ? .white : .secondary)
            .padding(.horizontal, 7).padding(.vertical, 5)
            .background(activeTab == tab ? Color.white.opacity(0.08) : Color.clear)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    var queueBadge: some View {
        let count = queue.totalQueued
        if count > 0 {
            Text("\(count)")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(Color(hex: "#ef4444"))
                .cornerRadius(4)
        }
    }

    // MARK: - Tab Content

    @ViewBuilder
    var tabContent: some View {
        switch activeTab {
        case .output:
            outputTab
        case .gallery:
            GalleryView(onReuseSettings: { r in onReuseSettings(r); activeTab = .output })
        case .batch:
            BatchJobView(
                sdService: sdService,
                settings: settings.wrappedValue,
                parsedPrompt: parsedPrompt.wrappedValue
            )
        case .queue:
            JobQueueView()
        case .ipadapter:
            ipAdapterTab
        case .presets:
            presetsTab
        case .publish:
            StudioPublishView(images: [sdService.generatedImage].compactMap { $0 })
        case .dashboard:
            DashboardView()
        }
    }

    // MARK: - Output Tab

    var outputTab: some View {
        VStack(spacing: 0) {
            // Image area
            ZStack {
                Color(red: 0.07, green: 0.07, blue: 0.09)
                if let img = sdService.generatedImage {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                        .transition(.opacity.animation(.easeInOut(duration: 0.25)))
                } else if sdService.isGenerating {
                    generatingAnim
                } else if let err = sdService.errorMessage {
                    errorView(err)
                } else {
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()

            // Vault result banner v5 — detallado con pasos
            if let result = vaultSaveResult {
                vaultResultDetailView(result)
                    .onTapGesture {
                        withAnimation { vaultSaveResult = nil; vaultMessage = nil }
                    }
            } else if let msg = vaultMessage {
                Text(msg).font(.system(size: 11, weight: .medium))
                    .foregroundColor(msg.hasPrefix("✓") ? Color(hex: "#34d399") : .orange)
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                    .background(Color.black.opacity(0.35))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.easeInOut, value: vaultMessage)
            }

            // IC-Light relight progress
            if icLight.isProcessing {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.6).progressViewStyle(.circular)
                    Text(icLight.progressText).font(.system(size: 11)).foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color.white.opacity(0.03))
            }

            // Cinematic filter bar
            if sdService.generatedImage != nil { cinematicBar }

            Divider().background(Color.white.opacity(0.06))
            if let img = sdService.generatedImage { bottomBar(img) }
        }
    }

    // MARK: - Presets Tab (v5 NEW)

    var presetsTab: some View {
        ReusableSettingsPanel { preset in
            onReuseSettings(preset)
            withAnimation { activeTab = .output }
        }
    }

    // MARK: - Vault Result Detail Banner (v5 NEW)

    @ViewBuilder
    func vaultResultDetailView(_ result: PipelineConnector.PipelineSaveResult) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(result.statusEmoji).font(.system(size: 15))
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.cleanURL?.lastPathComponent ?? "Guardado en Vault")
                        .font(.system(size: 11, weight: .semibold)).foregroundColor(.white).lineLimit(1)
                    if !result.sha256Clean.isEmpty {
                        Text("SHA-256: \(result.sha256Clean.prefix(16))…")
                            .font(.system(size: 8, design: .monospaced)).foregroundColor(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "xmark").font(.system(size: 9)).foregroundColor(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)

            HStack(spacing: 0) {
                vaultStepCell(result.assetID != nil,   "DB")
                vaultStepCell(result.cleanURL != nil,  "PNG")
                vaultStepCell(result.steganographyOK,  "Steg")
                vaultStepCell(result.iptcOK,           "IPTC")
                vaultStepCell(result.sidecarOK,        "Sidecar")
                vaultStepCell(result.complianceLogged, "Log")
            }
            .padding(.horizontal, 12).padding(.bottom, 7)

            if !result.errors.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(result.errors.prefix(3), id: \.self) { err in
                        Text("⚠️ \(err)").font(.system(size: 9))
                            .foregroundColor(Color(hex: "#f59e0b")).lineLimit(1)
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 6)
            }
        }
        .background(result.isFullSuccess
            ? Color(hex: "#34d399").opacity(0.1)
            : Color(hex: "#f59e0b").opacity(0.08))
    }

    private func vaultStepCell(_ ok: Bool, _ label: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle").font(.system(size: 11))
                .foregroundColor(ok ? Color(hex: "#34d399") : Color.white.opacity(0.15))
            Text(label).font(.system(size: 7)).foregroundColor(ok ? .secondary : Color.white.opacity(0.2))
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - IP-Adapter Tab


    var ipAdapterTab: some View {
        ScrollView {
            VStack(spacing: 12) {
                // Panel principal
                IPAdapterPanel()
                    .padding(.horizontal, 10).padding(.top, 10)

                // IC-Light section
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "light.max").font(.system(size: 12)).foregroundColor(Color(hex: "#fbbf24"))
                        Text("IC-Light Relight").font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                        Spacer()
                        Toggle("", isOn: $icLight.config.enabled)
                            .toggleStyle(.switch).scaleEffect(0.75)
                    }

                    if icLight.config.enabled {
                        // Dirección de luz
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(ICLightEngine.LightingDirection.allCases, id: \.self) { dir in
                                    Button {
                                        icLight.config.direction = dir
                                    } label: {
                                        VStack(spacing: 3) {
                                            Image(systemName: dir.icon).font(.system(size: 12))
                                            Text(dir.displayName).font(.system(size: 9))
                                        }
                                        .foregroundColor(icLight.config.direction == dir ? .white : .secondary)
                                        .padding(.horizontal, 8).padding(.vertical, 6)
                                        .background(icLight.config.direction == dir
                                            ? Color(hex: "#fbbf24").opacity(0.2)
                                            : Color.white.opacity(0.04))
                                        .cornerRadius(6)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        // Light prompt custom
                        TextField("Prompt de luz adicional…", text: $icLight.config.lightPrompt)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11)).foregroundColor(.white)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(Color.white.opacity(0.06)).cornerRadius(6)

                        HStack {
                            Text("Intensidad").font(.system(size: 10)).foregroundColor(.secondary)
                            Slider(value: $icLight.config.strength, in: 0.3...1.0)
                            Text(String(format: "%.2f", icLight.config.strength))
                                .font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary).frame(width: 34)
                        }

                        if !icLight.isInstalled {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle").font(.system(size: 10))
                                    .foregroundColor(Color(hex: "#fbbf24"))
                                Text("IC-Light no detectado — se usará img2img como fallback")
                                    .font(.system(size: 10)).foregroundColor(.secondary)
                            }
                        }

                        // Presets
                        Text("Presets de luz").font(.system(size: 10)).foregroundColor(.secondary)
                        ForEach(ICLightEngine.builtInPresets.prefix(4)) { preset in
                            Button {
                                icLight.applyPreset(preset)
                            } label: {
                                HStack {
                                    Text(preset.name).font(.system(size: 11)).foregroundColor(.white)
                                    Spacer()
                                    Text(preset.description).font(.system(size: 9)).foregroundColor(.secondary).lineLimit(1)
                                }
                                .padding(8).background(Color.white.opacity(0.04)).cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                        }

                        // Apply to current image
                        Button("Aplicar relight a imagen actual") {
                            guard let img = sdService.generatedImage else { return }
                            Task {
                                do {
                                    let result = try await icLight.relight(image: img, config: icLight.config)
                                    await MainActor.run { sdService.generatedImage = result }
                                } catch {
                                    icLight.lastError = error.localizedDescription
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(sdService.generatedImage == nil || icLight.isProcessing)
                    }
                }
                .padding(10).background(Color.white.opacity(0.04)).cornerRadius(8)
                .padding(.horizontal, 10)

                Spacer()
            }
        }
    }

    // MARK: - Cinematic Bar

    var cinematicBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                Button(action: { cinematic.clearFilters() }) {
                    Text("Original").font(.system(size: 9))
                        .foregroundColor(cinematic.activeFilters.isEmpty ? Color(hex: "#3de3c0") : .secondary)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.white.opacity(0.05)).cornerRadius(4)
                }.buttonStyle(.plain)
                ForEach(CinematicPreset.allPresets.prefix(6)) { preset in
                    Button(action: { cinematic.applyPreset(preset) }) {
                        Text(preset.name).font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.65))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Color.white.opacity(0.05)).cornerRadius(4)
                    }.buttonStyle(.plain)
                }
                // ACEScg button
                Button(action: { showACEScg = true }) {
                    HStack(spacing: 3) {
                        Image(systemName: "wand.and.stars").font(.system(size: 8))
                        Text("ACEScg").font(.system(size: 9))
                    }
                    .foregroundColor(Color(hex: "#fbbf24"))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color(hex: "#fbbf24").opacity(0.1)).cornerRadius(4)
                }.buttonStyle(.plain)

                if cinematic.isProcessing {
                    ProgressView().scaleEffect(0.55).progressViewStyle(.circular)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
        }
        .background(Color.white.opacity(0.02))
    }

    // MARK: - Bottom Bar

    func bottomBar(_ image: NSImage) -> some View {
        HStack(spacing: 7) {
            // Seed info
            if let seed = sdService.lastSeed {
                Image(systemName: "dice").font(.system(size: 10)).foregroundColor(.secondary)
                Text("\(seed)").font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                let fav = SeedManager.shared.isFavorite(seed)
                Button(action: {
                    if fav { SeedManager.shared.removeFavorite(seed: seed) }
                    else   { SeedManager.shared.addFavorite(seed: seed, promptHint: parsedPrompt.truncated(40)) }
                }) {
                    Image(systemName: fav ? "star.fill" : "star").font(.system(size: 10))
                        .foregroundColor(fav ? .yellow : .secondary)
                }.buttonStyle(.plain)
                Button(action: { settings.seed = seed }) {
                    Image(systemName: "arrow.uturn.left").font(.system(size: 10)).foregroundColor(.secondary)
                }.buttonStyle(.plain).help("Reusar seed")
            }

            Text("\(settings.width)×\(settings.height)")
                .font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)

            Spacer()

            // External editor
            Button(action: {
                // Open in external editor — asset context needed from gallery
                // For now, opens a panel
                activeTab = .gallery
            }) {
                Image(systemName: "arrow.up.forward.app").font(.system(size: 10)).foregroundColor(.secondary)
            }.buttonStyle(.plain).help("Editar externamente")

            // Save PNG
            Button(action: { onSaveImage(image) }) {
                Image(systemName: "square.and.arrow.down").font(.system(size: 11)).foregroundColor(.secondary)
            }.buttonStyle(.plain).help("Exportar PNG")

            // Refinar
            Button(action: {
                Task {
                    await Img2ImgEngine.shared.refine(
                        image: image,
                        prompt: parsedPrompt,
                        negative: settings.negativePrompt,
                        denoise: 0.40,
                        settings: Img2ImgSettings(),
                        baseURL: settings.sdBaseURL,
                        checkpoint: settings.checkpoint
                    )
                }
            }) {
                HStack(spacing: 3) {
                    Image(systemName: "wand.and.stars").font(.system(size: 10))
                    Text("Refinar").font(.system(size: 11))
                }
                .foregroundColor(.secondary).padding(.horizontal, 7).padding(.vertical, 4)
                .background(Color.white.opacity(0.06)).cornerRadius(5)
            }.buttonStyle(.plain)

            // Guardar Preset (v5)
            Button(action: { showSavePreset = true }) {
                Image(systemName: "bookmark.badge.plus").font(.system(size: 11))
                    .foregroundColor(Color(hex: "#f59e0b"))
            }.buttonStyle(.plain).help("Guardar como preset")

            // Vault
            Button(action: { vaultImage(image) }) {
                HStack(spacing: 4) {
                    if isVaulting { ProgressView().scaleEffect(0.5).progressViewStyle(.circular) }
                    else { Image(systemName: "externaldrive.badge.plus").font(.system(size: 10)) }
                    Text("Vault").font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(.white).padding(.horizontal, 11).padding(.vertical, 6)
                .background(LinearGradient(
                    colors: [Color(hex: "#7c6af7"), Color(hex: "#5b4ecf")],
                    startPoint: .leading, endPoint: .trailing))
                .cornerRadius(7)
            }.buttonStyle(.plain).disabled(isVaulting)
        }
        .padding(.horizontal, 11).padding(.vertical, 8).background(Color.white.opacity(0.03))
    }

    // MARK: - Generating / Empty / Error

    var generatingAnim: some View {
        VStack(spacing: 16) {
            ZStack {
                ForEach(0..<3) { i in
                    Circle().stroke(Color(hex: "#7c6af7").opacity(0.22 - Double(i) * 0.06), lineWidth: 1.5)
                        .frame(width: CGFloat(56 + i * 26), height: CGFloat(56 + i * 26))
                        .scaleEffect(sdService.isGenerating ? 1.12 : 1.0)
                        .animation(.easeInOut(duration: 1.1 + Double(i) * 0.25).repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.2), value: sdService.isGenerating)
                }
                ProgressView().scaleEffect(1.1).progressViewStyle(.circular)
            }
            Text(sdService.progressText).font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.45))
            // IP-Adapter indicator
            if ipAdapter.isEnabled {
                HStack(spacing: 4) {
                    Circle().fill(Color(hex: "#7c6af7")).frame(width: 5, height: 5)
                    Text("IP-Adapter \(ipAdapter.config.model.displayName) activo")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }
            }
        }
    }

    func errorView(_ msg: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 30))
                .foregroundColor(Color(hex: "#ef4444"))
            Text("Error").font(.system(size: 13, weight: .semibold)).foregroundColor(.white.opacity(0.7))
            Text(msg).font(.system(size: 11)).foregroundColor(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 280)
        }.padding(24)
    }

    var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "wand.and.sparkles").font(.system(size: 44))
                .foregroundColor(.white.opacity(0.07))
            Text("JSON → Parse → Generate").font(.system(size: 13))
                .foregroundColor(.white.opacity(0.16))
        }
    }

    // MARK: - Stage Badge

    @ViewBuilder
    var stageBadge: some View {
        let (color, text) = stageInfo
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(text).font(.system(size: 10, weight: .medium)).foregroundColor(color)
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(color.opacity(0.12))
        .cornerRadius(12)
    }

    private var stageInfo: (Color, String) {
        switch sdService.stage {
        case .idle:      return (.gray,   "Idle")
        case .parsing:   return (.blue,   "Parsing")
        case .building:  return (.cyan,   "Building")
        case .sending:   return (.orange, "Sending")
        case .receiving: return (.yellow, "Receiving")
        case .postproc:  return (.purple, "Post‑proc")
        case .saving:    return (.teal,   "Saving")
        case .done:      return (.green,  "Done ✓")
        case .error:     return (.red,    "Error")
        }
    }

    // MARK: - Vault Action

    private func vaultImage(_ image: NSImage) {
        isVaulting = true
        Task {
            // v5: usa saveToVaultAtomic con resultado detallado
            let result = await PipelineConnector.saveToVaultAtomic(
                image: image, settings: settings, parsedPrompt: parsedPrompt, sdService: sdService)
            await MainActor.run {
                withAnimation {
                    vaultSaveResult = result
                    vaultMessage    = nil   // usa el nuevo banner detallado
                }
                isVaulting = false
                Task {
                    try? await Task.sleep(for: .seconds(6))
                    await MainActor.run { withAnimation { vaultSaveResult = nil } }
                }
            }
        }
    }
}

// MARK: - ACEScg Sheet

struct ACEScgSheet: View {
    var onApply: (ACEScgColorEngine.CinematicGrade) -> Void
    @State private var grade = ACEScgColorEngine.CinematicGrade(enabled: true)
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Grade Cinemático ACEScg").font(.system(size: 13, weight: .bold)).foregroundColor(.white)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 15)).foregroundColor(.secondary)
                }.buttonStyle(.plain)
            }
            .padding()
            Divider()
            ScrollView {
                ACEScgPanel(grade: $grade).padding()
            }
            Divider()
            HStack {
                Button("Cancelar") { dismiss() }
                    .buttonStyle(.plain).foregroundColor(.secondary)
                Spacer()
                Button("Aplicar") { onApply(grade); dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 420, height: 580)
        .background(Color(red: 0.10, green: 0.10, blue: 0.13))
    }
}
