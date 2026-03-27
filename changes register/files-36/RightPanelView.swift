import SwiftUI
import AppKit

// MARK: - RightPanelView v6
//
// Cambios v5 → v6:
//   ✨ ADD: Tab "Export" — OnlyFansSetExporter + ExportBatchCoordinator UI completa
//   ✨ ADD: outputTab integra GenerationProgressEngine — barra de progreso real + live preview parcial
//   ✨ ADD: postGenActionBar — Export rápido, Al Lote, Set OF, rating de 5 estrellas
//   ✨ ADD: livePreviewOverlayBanner — barra animada encima del output durante generación
//   ✨ ADD: @StateObject progressEngine para observar actualizaciones en tiempo real
//   🔁 UPD: generatingAnim muestra preview parcial de GenerationProgressEngine si disponible
//   🔁 UPD: bottomBar mantiene compatibilidad total con v5

struct RightPanelView: View {

    @ObservedObject var sdService:    SDService
    @Binding       var settings:      GenerationSettings
    @Binding       var parsedPrompt:  String

    var onGenerate:      () -> Void
    var onSaveImage:     (NSImage) -> Void
    var onReuseSettings: (ReusableSettings) -> Void

    // MARK: - State

    @State private var activeTab:       PanelTab = .output
    @State private var vaultMessage:    String?  = nil
    @State private var isVaulting:      Bool     = false
    @State private var isRelighting:    Bool     = false
    @State private var showACEScg:      Bool     = false
    @State private var vaultSaveResult: PipelineConnector.PipelineSaveResult? = nil
    @State private var showSavePreset:  Bool     = false
    @State private var showExportSettings: Bool  = false  // NEW v6

    // MARK: - Observed Objects

    @StateObject private var cinematic      = CinematicFilterEngine.shared
    @StateObject private var queue          = JobQueueManager.shared
    @StateObject private var ipAdapter      = IPAdapterEngine.shared
    @StateObject private var icLight        = ICLightEngine.shared
    @StateObject private var editorBridge   = ExternalEditorBridge.shared
    @StateObject private var presetsManager = ReusableSettingsManager.shared
    @StateObject private var progressEngine = GenerationProgressEngine.shared   // NEW v6
    @StateObject private var assetStore     = AssetStore.shared                 // NEW v6
    @StateObject private var batchCoord     = ExportBatchCoordinator.shared     // NEW v6
    @StateObject private var setExporter    = OnlyFansSetExporter.shared        // NEW v6

    // MARK: - Tab Definition

    enum PanelTab: String, CaseIterable {
        case output    = "Output"
        case gallery   = "Galería"
        case batch     = "Batch"
        case queue     = "Cola"
        case ipadapter = "FaceID"
        case presets   = "Presets"
        case export    = "Export"    // NEW v6
        case publish   = "Publicar"
        case dashboard = "KPIs"

        var icon: String {
            switch self {
            case .output:    return "photo.artframe"
            case .gallery:   return "photo.stack"
            case .batch:     return "square.grid.3x3.fill"
            case .queue:     return "list.bullet.rectangle"
            case .ipadapter: return "person.fill.viewfinder"
            case .presets:   return "bookmark.fill"
            case .export:    return "square.and.arrow.up.on.square"   // NEW v6
            case .publish:   return "arrow.up.to.line"
            case .dashboard: return "chart.bar.xaxis"
            }
        }
    }

    // MARK: - Body

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
            if sdService.generatedImage != nil {
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
        .sheet(isPresented: $showExportSettings) {
            VStack(spacing: 0) {
                HStack {
                    Text("Configuración de Export")
                        .font(.system(size: 13, weight: .bold)).foregroundColor(.white)
                    Spacer()
                    Button(action: { showExportSettings = false }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15)).foregroundColor(.secondary)
                    }.buttonStyle(.plain)
                }.padding(14)
                Divider()
                ExportSettingsView()
                Divider()
                HStack {
                    Spacer()
                    Button("Cerrar") { showExportSettings = false }
                        .buttonStyle(.plain).foregroundColor(Color(hex: "#7c6af7"))
                        .padding(12)
                }
            }
            .frame(width: 480, height: 540)
            .background(Color(red: 0.09, green: 0.09, blue: 0.12))
        }
    }

    // MARK: - Tab Bar

    var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(PanelTab.allCases, id: \.self) { tab in
                    tabButton(tab)
                }
                Spacer()
                if activeTab == .output { stageBadge }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
        .background(Color.white.opacity(0.03))
    }

    @ViewBuilder
    func tabButton(_ tab: PanelTab) -> some View {
        Button(action: { activeTab = tab }) {
            HStack(spacing: 4) {
                Image(systemName: tab.icon).font(.system(size: 10))
                Text(tab.rawValue).font(.system(size: 10, weight: activeTab == tab ? .semibold : .regular))

                // Badges
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
                // Export batch badge (NEW v6)
                if tab == .export, batchCoord.pendingCount > 0 {
                    Text("\(batchCoord.pendingCount)")
                        .font(.system(size: 7, weight: .bold)).foregroundColor(.white)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color(hex: "#3de3c0")).cornerRadius(4)
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
                .font(.system(size: 8, weight: .bold)).foregroundColor(.white)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(Color(hex: "#ef4444")).cornerRadius(4)
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
        case .export:
            exportTab                    // NEW v6
        case .publish:
            StudioPublishView(images: [sdService.generatedImage].compactMap { $0 })
        case .dashboard:
            DashboardView()
        }
    }

    // MARK: - Output Tab (v6 — con GenerationProgressEngine integrado)

    var outputTab: some View {
        VStack(spacing: 0) {

            // ── Live progress bar (GenerationProgressEngine) ───────────────
            liveProgressBanner

            // ── Imagen generada / estado ────────────────────────────────────
            ZStack {
                Color(red: 0.07, green: 0.07, blue: 0.09)

                if let img = sdService.generatedImage {
                    Image(nsImage: img)
                        .resizable().aspectRatio(contentMode: .fit)
                        .transition(.opacity.animation(.easeInOut(duration: 0.25)))

                } else if sdService.isGenerating {
                    // Mostrar preview parcial si está disponible
                    if let preview = progressEngine.previewImage {
                        ZStack {
                            Image(nsImage: preview)
                                .resizable().aspectRatio(contentMode: .fit)
                                .blur(radius: 1.5)
                                .opacity(0.8)

                            // Overlay informativo
                            VStack(spacing: 6) {
                                HStack(spacing: 6) {
                                    ProgressView()
                                        .progressViewStyle(.circular)
                                        .scaleEffect(0.65)
                                    Text(progressEngine.statusLabel)
                                        .font(.system(size: 10))
                                        .foregroundColor(.white)
                                }
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(Color.black.opacity(0.55))
                                .cornerRadius(8)
                            }
                        }
                    } else {
                        generatingAnim
                    }

                } else if let err = sdService.errorMessage {
                    errorView(err)
                } else {
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            // ── Post-gen action bar (NEW v6) ────────────────────────────────
            if sdService.generatedImage != nil && !sdService.isGenerating {
                postGenActionBar
            }

            // ── Vault result banner ─────────────────────────────────────────
            if let result = vaultSaveResult {
                vaultResultDetailView(result)
                    .onTapGesture { withAnimation { vaultSaveResult = nil; vaultMessage = nil } }
            } else if let msg = vaultMessage {
                Text(msg).font(.system(size: 11, weight: .medium))
                    .foregroundColor(msg.hasPrefix("✓") ? Color(hex: "#34d399") : .orange)
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                    .background(Color.black.opacity(0.35))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.easeInOut, value: vaultMessage)
            }

            // ── IC-Light progress ───────────────────────────────────────────
            if icLight.isProcessing {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.6).progressViewStyle(.circular)
                    Text(icLight.progressText).font(.system(size: 11)).foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color.white.opacity(0.03))
            }

            // ── Cinematic filter bar ────────────────────────────────────────
            if sdService.generatedImage != nil { cinematicBar }

            Divider().background(Color.white.opacity(0.06))
            if let img = sdService.generatedImage { bottomBar(img) }
        }
    }

    // MARK: - Live Progress Banner (NEW v6)

    @ViewBuilder
    var liveProgressBanner: some View {
        if progressEngine.isGenerating {
            VStack(spacing: 0) {
                // Barra de progreso (3px, gradient)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Color.white.opacity(0.06)
                        LinearGradient(
                            colors: [Color(hex: "#7c6af7"), Color(hex: "#3de3c0")],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: geo.size.width * progressEngine.progress)
                        .animation(.linear(duration: 0.4), value: progressEngine.progress)
                    }
                }
                .frame(height: 3)

                // Info row
                HStack(spacing: 8) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.48)
                        .frame(width: 12, height: 12)

                    Text(progressEngine.statusLabel)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    Spacer()

                    if !progressEngine.etaFormatted.isEmpty {
                        Text(progressEngine.etaFormatted)
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }

                    Text(progressEngine.progressPercent)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(Color(hex: "#7c6af7"))

                    Button(action: {
                        Task { await sdService.interruptGeneration(baseURL: settings.sdBaseURL) }
                        progressEngine.stopPolling()
                    }) {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 11))
                            .foregroundColor(Color(hex: "#ef4444"))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.black.opacity(0.2))
            }
        }
    }

    // MARK: - Post-Gen Action Bar (NEW v6)

    var postGenActionBar: some View {
        HStack(spacing: 6) {
            // Export limpio
            quickActionBtn(icon: "doc.fill", label: "Limpio", color: "#3de3c0") {
                exportLastAsset(withWatermark: false)
            }

            // Export preview con watermark
            quickActionBtn(icon: "pencil.and.outline", label: "Preview", color: "#7c6af7") {
                exportLastAsset(withWatermark: true)
            }

            // Añadir al lote
            quickActionBtn(icon: "plus.rectangle.on.rectangle", label: "Lote", color: "#f59e0b") {
                addLastAssetToBatch()
            }

            // Set OnlyFans (solo si hay sesión activa)
            if ContentSessionManager.shared.activeSession != nil {
                quickActionBtn(icon: "rectangle.stack.fill.badge.plus", label: "Set OF", color: "#ec4899") {
                    exportCurrentSession()
                }
            }

            Spacer()

            // Rating rápido
            quickRatingBar
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.03))
    }

    func quickActionBtn(icon: String, label: String, color: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: color))
                Text(label)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .frame(width: 46, height: 36)
            .background(Color(hex: color).opacity(0.09))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    var quickRatingBar: some View {
        let currentRating = assetStore.recentAssets.last.map { Int($0.rating) } ?? 0
        HStack(spacing: 3) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: star <= currentRating ? "star.fill" : "star")
                    .font(.system(size: 11))
                    .foregroundColor(star <= currentRating ? Color(hex: "#f59e0b") : .secondary.opacity(0.5))
                    .onTapGesture { setRating(star) }
            }
        }
    }

    func setRating(_ rating: Int) {
        guard let asset = assetStore.recentAssets.last else { return }
        asset.rating = Int16(rating)
        try? AssetStore.shared.container.viewContext.save()
    }

    // MARK: - Export Quick Actions

    private func exportLastAsset(withWatermark: Bool) {
        guard let asset = assetStore.recentAssets.last else {
            vaultMessage = "⚠️ Sin imagen reciente para exportar"
            return
        }
        Task {
            do {
                _ = try await ExportEngine.shared.export(asset: asset, addWatermark: withWatermark)
                vaultMessage = "✓ Imagen \(withWatermark ? "preview" : "limpia") exportada"
                clearVaultMessageAfterDelay()
            } catch {
                vaultMessage = "Error export: \(error.localizedDescription)"
            }
        }
    }

    private func addLastAssetToBatch() {
        let approved = assetStore.recentAssets.filter {
            $0.statusEnum == .approved || $0.statusEnum == .draft
        }
        guard !approved.isEmpty else {
            vaultMessage = "⚠️ Sin imágenes aprobadas para el lote"
            return
        }
        ExportBatchCoordinator.shared.enqueue(
            assets: Array(approved.prefix(1)),
            setLabel: "Lote rápido"
        )
        if !ExportBatchCoordinator.shared.isRunning {
            ExportBatchCoordinator.shared.start()
        }
        vaultMessage = "✓ \(min(approved.count, 1)) imagen(es) añadidas al lote"
        clearVaultMessageAfterDelay()
    }

    private func exportCurrentSession() {
        guard let session = ContentSessionManager.shared.activeSession else { return }
        let approved = assetStore.recentAssets.filter { $0.statusEnum == .approved }
        guard !approved.isEmpty else {
            vaultMessage = "⚠️ Sin imágenes aprobadas en la sesión"
            return
        }
        Task {
            do {
                let result = try await OnlyFansSetExporter.shared.exportSet(
                    assets: approved,
                    setTitle: session.title,
                    session: session
                )
                vaultMessage = "✓ Set '\(result.setTitle)' exportado · \(result.assetCount) imágenes"
                clearVaultMessageAfterDelay()
            } catch {
                vaultMessage = "Error set: \(error.localizedDescription)"
            }
        }
    }

    private func clearVaultMessageAfterDelay() {
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await MainActor.run { withAnimation { vaultMessage = nil } }
        }
    }

    // MARK: - Export Tab (NEW v6)

    var exportTab: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {

                // Batch activo
                if batchCoord.isRunning || !batchCoord.queue.isEmpty {
                    exportSectionHeader("Cola de Export")
                    ExportBatchProgressView()
                        .padding(.horizontal, 12)
                }

                // Set Export (OnlyFans)
                exportSectionHeader("Export de Set")
                SetExportPanel()
                    .padding(.horizontal, 12)

                // Lote de assets
                exportSectionHeader("Export en Lote")
                batchQueueSection
                    .padding(.horizontal, 12)

                // Botón a configuración
                Button(action: { showExportSettings = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "gearshape.fill").font(.system(size: 11))
                        Text("Configuración de Export & Watermark")
                            .font(.system(size: 11))
                    }
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                    .background(Color.white.opacity(0.04)).cornerRadius(8)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)

                Spacer(minLength: 20)
            }
            .padding(.vertical, 12)
        }
    }

    func exportSectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(.secondary)
            .tracking(1.0)
            .padding(.horizontal, 12)
    }

    var batchQueueSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            let approved = assetStore.recentAssets.filter { $0.statusEnum == .approved || $0.statusEnum == .draft }

            HStack(spacing: 8) {
                Image(systemName: approved.isEmpty ? "tray" : "tray.full.fill")
                    .font(.system(size: 11))
                    .foregroundColor(approved.isEmpty ? .secondary : Color(hex: "#3de3c0"))
                Text(approved.isEmpty
                     ? "Sin imágenes aprobadas en la sesión actual"
                     : "\(approved.count) imagen(es) aprobadas disponibles")
                    .font(.system(size: 10))
                    .foregroundColor(approved.isEmpty ? .secondary : .white)
                Spacer()
            }

            if !approved.isEmpty {
                HStack(spacing: 8) {
                    Button(action: {
                        ExportBatchCoordinator.shared.enqueue(
                            assets: approved,
                            setLabel: "Lote sesión"
                        )
                        if !ExportBatchCoordinator.shared.isRunning {
                            ExportBatchCoordinator.shared.start()
                        }
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill").font(.system(size: 10))
                            Text("Encolar y exportar todas")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .background(Color(hex: "#7c6af7")).cornerRadius(7)
                    }
                    .buttonStyle(.plain)

                    // Config de concurrencia rápida
                    Picker("", selection: $batchCoord.config.maxConcurrency) {
                        Text("×1").tag(1)
                        Text("×2").tag(2)
                        Text("×4").tag(4)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 90)
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.04))
        .cornerRadius(8)
    }

    // MARK: - Presets Tab (v5 compat)

    var presetsTab: some View {
        ReusableSettingsPanel { preset in
            onReuseSettings(preset)
            withAnimation { activeTab = .output }
        }
    }

    // MARK: - IP-Adapter Tab

    var ipAdapterTab: some View {
        ScrollView {
            VStack(spacing: 12) {
                IPAdapterPanel()
                    .padding(.horizontal, 10).padding(.top, 10)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "light.max").font(.system(size: 12)).foregroundColor(Color(hex: "#fbbf24"))
                        Text("IC-Light Relight").font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                        Spacer()
                        Toggle("", isOn: $icLight.config.enabled)
                            .toggleStyle(.switch).scaleEffect(0.75)
                    }

                    if icLight.config.enabled {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(ICLightEngine.LightingDirection.allCases, id: \.self) { dir in
                                    Button { icLight.config.direction = dir } label: {
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
                                    }.buttonStyle(.plain)
                                }
                            }
                        }

                        TextField("Prompt de luz adicional…", text: $icLight.config.lightPrompt)
                            .textFieldStyle(.plain).font(.system(size: 11)).foregroundColor(.white)
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

                        Text("Presets de luz").font(.system(size: 10)).foregroundColor(.secondary)
                        ForEach(ICLightEngine.builtInPresets.prefix(4)) { preset in
                            Button { icLight.applyPreset(preset) } label: {
                                HStack {
                                    Text(preset.name).font(.system(size: 11)).foregroundColor(.white)
                                    Spacer()
                                    Text(preset.description).font(.system(size: 9)).foregroundColor(.secondary).lineLimit(1)
                                }
                                .padding(8).background(Color.white.opacity(0.04)).cornerRadius(6)
                            }.buttonStyle(.plain)
                        }

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

            // Duración de generación (NEW v6)
            let dur = sdService.generationDuration
            if dur > 0 {
                Text(String(format: "%.1fs", dur))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button(action: { activeTab = .gallery }) {
                Image(systemName: "arrow.up.forward.app").font(.system(size: 10)).foregroundColor(.secondary)
            }.buttonStyle(.plain).help("Ver en galería")

            Button(action: { onSaveImage(image) }) {
                Image(systemName: "square.and.arrow.down").font(.system(size: 11)).foregroundColor(.secondary)
            }.buttonStyle(.plain).help("Exportar PNG")

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

            Button(action: { showSavePreset = true }) {
                Image(systemName: "bookmark.badge.plus").font(.system(size: 11))
                    .foregroundColor(Color(hex: "#f59e0b"))
            }.buttonStyle(.plain).help("Guardar como preset")

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

    // MARK: - Vault Result Detail Banner (v5 compat)

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
            Text(progressEngine.isGenerating ? progressEngine.statusLabel : sdService.progressText)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.45))
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
            let result = await PipelineConnector.saveToVaultAtomic(
                image: image, settings: settings, parsedPrompt: parsedPrompt, sdService: sdService)
            await MainActor.run {
                withAnimation {
                    vaultSaveResult = result
                    vaultMessage    = nil
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

// MARK: - ACEScg Sheet (v5 compat)

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
            }.padding()
            Divider()
            ScrollView { ACEScgPanel(grade: $grade).padding() }
            Divider()
            HStack {
                Button("Cancelar") { dismiss() }
                    .buttonStyle(.plain).foregroundColor(.secondary)
                Spacer()
                Button("Aplicar") { onApply(grade); dismiss() }
                    .buttonStyle(.borderedProminent)
            }.padding()
        }
        .frame(width: 420, height: 580)
        .background(Color(red: 0.10, green: 0.10, blue: 0.13))
    }
}
