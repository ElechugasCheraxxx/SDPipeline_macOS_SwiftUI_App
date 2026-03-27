import SwiftUI
import AppKit

// MARK: - RightPanelView v2
// Añade tab de Batch y mejoras de integración.
// Tabs: Output | Galería | Batch | Publicar | KPIs

struct RightPanelView: View {

    @ObservedObject var sdService:    SDService
    @Binding var settings:            GenerationSettings
    @Binding var parsedPrompt:        String

    var onGenerate:      () -> Void
    var onSaveImage:     (NSImage) -> Void
    var onReuseSettings: (ReusableSettings) -> Void

    @State private var activeTab:     PanelTab = .output
    @State private var isSavingVault: Bool     = false
    @State private var vaultSaveMsg:  String?  = nil

    enum PanelTab: String, CaseIterable {
        case output    = "Output"
        case gallery   = "Galería"
        case batch     = "Batch"
        case publish   = "Publicar"
        case dashboard = "KPIs"

        var icon: String {
            switch self {
            case .output:    return "photo.artframe"
            case .gallery:   return "photo.stack"
            case .batch:     return "square.grid.3x3.fill"
            case .publish:   return "arrow.up.to.line"
            case .dashboard: return "chart.bar.xaxis"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider().background(Color.white.opacity(0.07))

            switch activeTab {
            case .output:
                outputPanel
            case .gallery:
                GalleryView(onReuseSettings: { reusable in
                    applyReusableSettings(reusable)
                    activeTab = .output
                })
            case .batch:
                BatchJobView(
                    sdService:    sdService,
                    settings:     settings,
                    parsedPrompt: parsedPrompt
                )
            case .publish:
                StudioPublishView(images: [sdService.generatedImage].compactMap { $0 })
            case .dashboard:
                DashboardView()
            }
        }
        .background(Color(red: 0.08, green: 0.08, blue: 0.10))
        .onChange(of: sdService.stage) { _, stage in
            if stage == .done {
                Task { AssetStore.shared.fetchRecentAssets() }
                DashboardViewModel.shared.refresh()
            }
        }
    }

    // MARK: - Tab Bar

    var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(PanelTab.allCases, id: \.self) { tab in
                tabButton(tab.rawValue, icon: tab.icon, tab: tab)
            }
            Spacer()
            if activeTab == .output { stageBadge }
        }
        .padding(.horizontal, 14).padding(.vertical, 2)
        .background(Color.white.opacity(0.03))
    }

    func tabButton(_ title: String, icon: String, tab: PanelTab) -> some View {
        Button(action: { activeTab = tab }) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11))
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .foregroundColor(activeTab == tab ? .white : .secondary)
            .background(activeTab == tab ? Color.white.opacity(0.07) : Color.clear)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Output Panel

    var outputPanel: some View {
        VStack(spacing: 0) {
            ZStack {
                Color(red: 0.07, green: 0.07, blue: 0.09)
                if let image = sdService.generatedImage {
                    Image(nsImage: image)
                        .resizable().aspectRatio(contentMode: .fit)
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

            if sdService.stage == .done, let image = sdService.generatedImage {
                Divider().background(Color.white.opacity(0.07))
                bottomBar(image: image)
                if let msg = vaultSaveMsg {
                    Text(msg)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(msg.hasPrefix("✓") ? Color(hex: "#3de3c0") : Color(red: 1, green: 0.45, blue: 0.4))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.3))
                        .transition(.opacity)
                }
            }
        }
    }

    func bottomBar(image: NSImage) -> some View {
        HStack(spacing: 12) {
            if let seed = sdService.lastSeed {
                HStack(spacing: 4) {
                    Label("\(seed)", systemImage: "number")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)

                    Button(action: {
                        SeedManager.shared.addFavorite(
                            seed:       seed,
                            label:      "Seed \(seed)",
                            promptHint: String(parsedPrompt.prefix(50))
                        )
                    }) {
                        Image(systemName: SeedManager.shared.favorites.contains(where: { $0.seed == seed })
                              ? "star.fill" : "star")
                            .font(.system(size: 10))
                            .foregroundColor(
                                SeedManager.shared.favorites.contains(where: { $0.seed == seed })
                                ? .yellow : .secondary
                            )
                    }
                    .buttonStyle(.plain)

                    Button(action: { settings.seed = seed }) {
                        Image(systemName: "arrow.uturn.left")
                            .font(.system(size: 10)).foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain).help("Reutilizar este seed")
                }
            }

            Text("\(settings.width)×\(settings.height)")
                .font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)

            Spacer()

            // Enqueue to batch tab shortcut
            Button(action: { activeTab = .batch }) {
                Image(systemName: "plus.square.on.square")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Ir a Batch con este prompt")

            // Vault save
            Button(action: { saveToVault(image) }) {
                HStack(spacing: 5) {
                    if isSavingVault {
                        ProgressView().scaleEffect(0.6).progressViewStyle(.circular)
                    } else {
                        Image(systemName: "lock.doc.fill").font(.system(size: 11))
                    }
                    Text(isSavingVault ? "Guardando…" : "Vault")
                        .font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(LinearGradient(
                    colors: [Color(hex: "#7c6af7"), Color(hex: "#3de3c0")],
                    startPoint: .leading, endPoint: .trailing
                ))
                .foregroundColor(.white).cornerRadius(6)
            }
            .buttonStyle(.plain).disabled(isSavingVault)

            Button(action: { onSaveImage(image) }) {
                Label("PNG", systemImage: "square.and.arrow.down")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundColor(Color(red: 0.55, green: 0.8, blue: 1.0))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color(red: 0.15, green: 0.25, blue: 0.4)).cornerRadius(6)

            // Refinar
            if let img = sdService.generatedImage {
                Button(action: {
                    Task {
                        var s = Img2ImgSettings()
                        s.denoiseStrength = 0.40
                        s.width  = settings.width
                        s.height = settings.height
                        await Img2ImgEngine.shared.refine(
                            image:      img,
                            prompt:     parsedPrompt,
                            negative:   settings.negativePrompt,
                            settings:   s,
                            baseURL:    settings.sdBaseURL,
                            checkpoint: settings.checkpoint
                        )
                    }
                }) {
                    Label("Refinar", systemImage: "wand.and.stars.inverse")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color(hex: "#a78bfa").opacity(0.12))
                .foregroundColor(Color(hex: "#a78bfa"))
                .cornerRadius(6)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
    }

    // MARK: - Save to Vault

    private func saveToVault(_ image: NSImage) {
        guard !isSavingVault else { return }
        isSavingVault = true
        Task {
            let msg = await PipelineConnector.saveToVaultFull(
                image:        image,
                settings:     settings,
                parsedPrompt: parsedPrompt,
                sdService:    sdService
            )
            if !parsedPrompt.isEmpty {
                PromptVersioningStore.shared.save(
                    positive:    parsedPrompt,
                    negative:    settings.negativePrompt,
                    steps:       settings.steps,
                    cfgScale:    settings.cfgScale,
                    samplerName: settings.samplerName,
                    width:       settings.width,
                    height:      settings.height,
                    checkpoint:  settings.checkpoint
                )
            }
            await MainActor.run {
                isSavingVault = false
                vaultSaveMsg  = msg
            }
            try? await Task.sleep(for: .seconds(3))
            await MainActor.run { vaultSaveMsg = nil }
        }
    }

    // MARK: - Sub-views

    @ViewBuilder var stageBadge: some View {
        let (color, text): (Color, String) = {
            switch sdService.stage {
            case .idle:      return (.gray,   "Idle")
            case .parsing:   return (.blue,   "Parsing")
            case .building:  return (.cyan,   "Building")
            case .sending:   return (.orange, "Sending")
            case .receiving: return (.yellow, "Receiving")
            case .done:      return (.green,  "Done ✓")
            case .error:     return (.red,    "Error")
            }
        }()
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 11, weight: .medium)).foregroundColor(color)
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(color.opacity(0.12)).cornerRadius(20)
        .padding(.trailing, 4)
    }

    var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "wand.and.sparkles")
                .font(.system(size: 52)).foregroundColor(.white.opacity(0.1))
            Text("Paste JSON → Parse → Generate")
                .font(.system(size: 14)).foregroundColor(.white.opacity(0.2))
        }
    }

    var generatingView: some View {
        VStack(spacing: 20) {
            ZStack {
                ForEach(0..<3) { i in
                    Circle()
                        .stroke(Color(red: 0.55, green: 0.25, blue: 0.9)
                            .opacity(0.3 - Double(i) * 0.08), lineWidth: 1.5)
                        .frame(width: CGFloat(60 + i * 30), height: CGFloat(60 + i * 30))
                        .scaleEffect(sdService.isGenerating ? 1.15 : 1.0)
                        .animation(
                            .easeInOut(duration: 1.2 + Double(i) * 0.3)
                            .repeatForever(autoreverses: true).delay(Double(i) * 0.2),
                            value: sdService.isGenerating
                        )
                }
                ProgressView().scaleEffect(1.2).progressViewStyle(.circular)
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
                .font(.system(size: 14, weight: .semibold)).foregroundColor(.white.opacity(0.7))
            Text(msg)
                .font(.system(size: 12)).foregroundColor(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 300)
        }.padding(32)
    }

    // MARK: - Apply Reusable Settings

    private func applyReusableSettings(_ r: ReusableSettings) {
        settings.seed        = r.seed
        settings.steps       = r.steps
        settings.cfgScale    = r.cfgScale
        settings.samplerName = r.samplerName
        settings.width       = r.width
        settings.height      = r.height
        if !r.promptPositive.isEmpty { parsedPrompt = r.promptPositive }
        if !r.promptNegative.isEmpty { settings.negativePrompt = r.promptNegative }
        settings.checkpoint = r.checkpoint
        SeedManager.shared.incrementUsage(seed: r.seed)
        onReuseSettings(r)
    }
}
