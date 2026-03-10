import SwiftUI
import AppKit

// MARK: - RightPanelView v3
// Tabs: Output | Galería | Batch | Cola | Publicar | KPIs
// NEW: tab "Cola" con JobQueueView + cinematic presets bar

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
    @StateObject private var cinematic = CinematicFilterEngine.shared
    @StateObject private var queue     = JobQueueManager.shared

    enum PanelTab: String, CaseIterable {
        case output = "Output"; case gallery = "Galería"; case batch = "Batch"
        case queue  = "Cola";   case publish = "Publicar"; case dashboard = "KPIs"

        var icon: String {
            switch self {
            case .output:    return "photo.artframe"
            case .gallery:   return "photo.stack"
            case .batch:     return "square.grid.3x3.fill"
            case .queue:     return "list.bullet.rectangle"
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
    }

    var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(PanelTab.allCases, id: \.self) { tab in
                Button(action: { activeTab = tab }) {
                    HStack(spacing: 4) {
                        Image(systemName: tab.icon).font(.system(size: 11))
                        Text(tab.rawValue).font(.system(size: 11, weight: activeTab == tab ? .semibold : .regular))
                        // Badge para Cola
                        if tab == .queue {
                            let n = queue.queue.filter { $0.status == .queued || $0.status == .running }.count
                            if n > 0 {
                                Text("\(n)").font(.system(size: 8, weight: .bold)).foregroundColor(.white)
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(Color(hex: "#ef4444")).cornerRadius(8)
                            }
                        }
                    }
                    .foregroundColor(activeTab == tab ? .white : .secondary)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(activeTab == tab ? Color.white.opacity(0.08) : Color.clear)
                    .cornerRadius(6)
                }.buttonStyle(.plain)
            }
            Spacer()
            if activeTab == .output { stageBadge }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.white.opacity(0.03))
    }

    @ViewBuilder
    var tabContent: some View {
        switch activeTab {
        case .output:    outputTab
        case .gallery:   GalleryView(onReuseSettings: { r in onReuseSettings(r); activeTab = .output })
        case .batch:     BatchJobView(basePrompt: $parsedPrompt, baseNegative: $settings.negativePrompt,
                                      baseURL: $settings.sdBaseURL, width: $settings.width, height: $settings.height)
        case .queue:     JobQueueView()
        case .publish:   StudioPublishView(images: [sdService.generatedImage].compactMap { $0 })
        case .dashboard: DashboardView()
        }
    }

    // MARK: - Output Tab

    var outputTab: some View {
        VStack(spacing: 0) {
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

            if let msg = vaultMessage {
                Text(msg).font(.system(size: 11, weight: .medium))
                    .foregroundColor(msg.hasPrefix("✓") ? Color(hex: "#34d399") : .orange)
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                    .background(Color.black.opacity(0.35))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.easeInOut, value: vaultMessage)
            }

            if sdService.generatedImage != nil { cinematicBar }
            Divider().background(Color.white.opacity(0.06))
            if let img = sdService.generatedImage { bottomBar(img) }
        }
    }

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
            Image(systemName: "wand.and.sparkles").font(.system(size: 44)).foregroundColor(.white.opacity(0.07))
            Text("JSON → Parse → Generate").font(.system(size: 13)).foregroundColor(.white.opacity(0.16))
        }
    }

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
                if cinematic.isProcessing {
                    ProgressView().scaleEffect(0.55).progressViewStyle(.circular)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
        }
        .background(Color.white.opacity(0.02))
    }

    func bottomBar(_ image: NSImage) -> some View {
        HStack(spacing: 7) {
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
            Button(action: { onSaveImage(image) }) {
                Image(systemName: "square.and.arrow.down").font(.system(size: 11)).foregroundColor(.secondary)
            }.buttonStyle(.plain).help("Exportar PNG")
            Button(action: {
                Task { await Img2ImgEngine.shared.refine(image: image, prompt: parsedPrompt, negative: settings.negativePrompt, denoise: 0.40, settings: Img2ImgSettings(), baseURL: settings.sdBaseURL, checkpoint: settings.checkpoint) }
            }) {
                HStack(spacing: 3) {
                    Image(systemName: "wand.and.stars").font(.system(size: 10))
                    Text("Refinar").font(.system(size: 11))
                }
                .foregroundColor(.secondary).padding(.horizontal, 7).padding(.vertical, 4)
                .background(Color.white.opacity(0.06)).cornerRadius(5)
            }.buttonStyle(.plain)
            Button(action: { vaultImage(image) }) {
                HStack(spacing: 4) {
                    if isVaulting { ProgressView().scaleEffect(0.5).progressViewStyle(.circular) }
                    else { Image(systemName: "externaldrive.badge.plus").font(.system(size: 10)) }
                    Text("Vault").font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(.white).padding(.horizontal, 11).padding(.vertical, 6)
                .background(LinearGradient(colors: [Color(hex: "#7c6af7"), Color(hex: "#5b4ecf")],
                                           startPoint: .leading, endPoint: .trailing))
                .cornerRadius(7)
            }.buttonStyle(.plain).disabled(isVaulting)
        }
        .padding(.horizontal, 11).padding(.vertical, 8).background(Color.white.opacity(0.03))
    }

    @ViewBuilder
    var stageBadge: some View {
        let (c, t): (Color, String) = {
            switch sdService.stage {
            case .idle: return (.gray, "Idle"); case .parsing: return (.blue, "Parsing")
            case .building: return (.cyan, "Building"); case .sending: return (.orange, "Sending")
            case .receiving: return (.yellow, "Receiving"); case .done: return (.green, "Done ✓")
            case .error: return (.red, "Error")
            }
        }()
        HStack(spacing: 4) {
            Circle().fill(c).frame(width: 5, height: 5)
            Text(t).font(.system(size: 10, weight: .medium)).foregroundColor(c)
        }
        .padding(.horizontal, 7).padding(.vertical, 3).background(c.opacity(0.12)).cornerRadius(12)
    }

    private func vaultImage(_ image: NSImage) {
        isVaulting = true
        Task {
            let msg = await PipelineConnector.saveToVaultFull(
                image: image, settings: settings, parsedPrompt: parsedPrompt, sdService: sdService)
            await MainActor.run {
                withAnimation { vaultMessage = msg }
                isVaulting = false
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    await MainActor.run { withAnimation { vaultMessage = nil } }
                }
            }
        }
    }
}
