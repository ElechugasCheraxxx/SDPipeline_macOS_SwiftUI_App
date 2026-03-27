import SwiftUI
import AppKit

// MARK: - RightPanelView_Extensions.swift v2
//
// Extiende RightPanelView con:
//   • Tab "Export" — OnlyFansSetExporter + ExportBatchCoordinator UI
//   • outputTab live preview — integra GenerationProgressEngine encima del output
//   • exportTab — panel completo de sets + lote
//   • Wiring de SDService → GenerationProgressEngine (start/stop polling)
//
// Para activar el tab "Export":
//   1. Agregar `.export = "Export"` al enum PanelTab en RightPanelView.swift
//   2. Agregar case `.export: exportTab` en tabContent
//   3. El tab icon: "square.and.arrow.up.on.square"

// MARK: - Live Preview Output Tab Extension

extension RightPanelView {

    // MARK: - Output Tab con Live Preview integrado

    var outputTabWithLivePreview: some View {
        VStack(spacing: 0) {
            // ── Live Preview Banner (durante generación) ────────────────────
            livePreviewOverlayBanner

            // ── Imagen generada / estado ────────────────────────────────────
            ZStack {
                Color(red: 0.07, green: 0.07, blue: 0.09)

                if let img = sdService.generatedImage {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                        .transition(.opacity.animation(.easeInOut(duration: 0.25)))
                } else if sdService.isGenerating {
                    // Mostrar preview parcial si hay, sino animación
                    if let preview = GenerationProgressEngine.shared.previewImage {
                        ZStack {
                            Image(nsImage: preview)
                                .resizable().aspectRatio(contentMode: .fit)
                                .blur(radius: 1.5)
                                .opacity(0.85)
                            // Indicador de "en proceso"
                            VStack(spacing: 6) {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .scaleEffect(0.8)
                                Text(GenerationProgressEngine.shared.statusLabel)
                                    .font(.system(size: 10)).foregroundColor(.white)
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .background(Color.black.opacity(0.5))
                                    .cornerRadius(6)
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

            // ── Post-gen: botones de acción ────────────────────────────────
            if sdService.generatedImage != nil && !sdService.isGenerating {
                postGenActionBar
            }

            // ── Vault result banner ────────────────────────────────────────
            if let result = vaultSaveResult {
                vaultResultDetailView(result)
                    .onTapGesture { withAnimation { vaultSaveResult = nil; vaultMessage = nil } }
            }

            // ── Controles inferiores ────────────────────────────────────────
            bottomControls
        }
    }

    // MARK: - Live Preview Overlay Banner

    @ViewBuilder
    var livePreviewOverlayBanner: some View {
        let engine = GenerationProgressEngine.shared
        if engine.isGenerating {
            VStack(spacing: 0) {
                // Barra de progreso delgada en la parte superior
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Color.white.opacity(0.06)
                        LinearGradient(
                            colors: [Color(hex: "#7c6af7"), Color(hex: "#3de3c0")],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: geo.size.width * engine.progress)
                        .animation(.linear(duration: 0.4), value: engine.progress)
                    }
                }
                .frame(height: 3)

                // Info row
                HStack(spacing: 8) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)

                    Text(engine.statusLabel)
                        .font(.system(size: 10)).foregroundColor(.secondary)

                    Spacer()

                    Text(engine.progressPercent)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(Color(hex: "#7c6af7"))

                    if !engine.etaFormatted.isEmpty {
                        Text(engine.etaFormatted)
                            .font(.system(size: 9)).foregroundColor(.secondary)
                    }

                    Button(action: {
                        Task { await sdService.interruptGeneration(baseURL: settings.wrappedValue.sdBaseURL) }
                        engine.stopPolling()
                    }) {
                        Text("✕")
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "#ef4444"))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Color.black.opacity(0.25))
            }
        }
    }

    // MARK: - Post-Gen Action Bar

    var postGenActionBar: some View {
        HStack(spacing: 8) {
            // Export rápido
            actionBarButton(icon: "square.and.arrow.up", label: "Export", color: "#3de3c0") {
                exportCurrentToVault()
            }

            // Agregar al set actual
            actionBarButton(icon: "plus.rectangle.on.rectangle", label: "Al Lote", color: "#7c6af7") {
                enqueueToExportBatch()
            }

            // Export set OnlyFans
            if let session = ContentSessionManager.shared.activeSession {
                actionBarButton(icon: "rectangle.stack.fill.badge.plus", label: "Set OF", color: "#f59e0b") {
                    exportCurrentSession(session)
                }
            }

            Spacer()

            // Rating rápido
            ratingStars
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.03))
    }

    func actionBarButton(icon: String, label: String, color: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 11)).foregroundColor(Color(hex: color))
                Text(label).font(.system(size: 8)).foregroundColor(.secondary)
            }
            .frame(width: 44, height: 36)
            .background(Color(hex: color).opacity(0.08))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    var ratingStars: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: star <= currentRating ? "star.fill" : "star")
                    .font(.system(size: 11))
                    .foregroundColor(star <= currentRating ? Color(hex: "#f59e0b") : .secondary)
                    .onTapGesture { setRating(star) }
            }
        }
    }

    var currentRating: Int {
        guard let asset = assetStore.recentAssets.last else { return 0 }
        return Int(asset.rating)
    }

    func setRating(_ rating: Int) {
        guard let asset = assetStore.recentAssets.last else { return }
        asset.rating = Int16(rating)
        try? AssetStore.shared.container.viewContext.save()
    }

    // MARK: - Export Actions (wired to new engines)

    func exportCurrentToVault() {
        guard let asset = assetStore.recentAssets.last else { return }
        Task {
            do {
                _ = try await ExportEngine.shared.export(asset: asset, addWatermark: true)
                vaultMessage = "✓ Imagen exportada al vault"
            } catch {
                vaultMessage = "Error: \(error.localizedDescription)"
            }
        }
    }

    func enqueueToExportBatch() {
        let pending = assetStore.recentAssets.prefix(1).map { $0 }
        guard !pending.isEmpty else { return }
        ExportBatchCoordinator.shared.enqueue(assets: Array(pending), setLabel: "Lote rápido")
        if !ExportBatchCoordinator.shared.isRunning {
            ExportBatchCoordinator.shared.start()
        }
    }

    func exportCurrentSession(_ session: ContentSessionManager.ContentSession) {
        let assets = assetStore.recentAssets.filter { $0.statusEnum == .approved }
        guard !assets.isEmpty else { return }
        Task {
            do {
                _ = try await OnlyFansSetExporter.shared.exportSet(
                    assets: assets,
                    setTitle: session.title,
                    session: session
                )
                vaultMessage = "✓ Set '\(session.title)' exportado"
            } catch {
                vaultMessage = "Error en export: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Export Tab (nuevo panel completo)

    var exportTab: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                // ── Batch activo ────────────────────────────────────────────
                if ExportBatchCoordinator.shared.isRunning || ExportBatchCoordinator.shared.queue.count > 0 {
                    VStack(alignment: .leading, spacing: 6) {
                        panelSectionHeader("Cola de Export")
                        ExportBatchProgressView()
                    }
                }

                // ── Set Export ──────────────────────────────────────────────
                VStack(alignment: .leading, spacing: 8) {
                    panelSectionHeader("Export de Set")
                    SetExportPanel()
                }

                // ── Export Settings ─────────────────────────────────────────
                VStack(alignment: .leading, spacing: 8) {
                    panelSectionHeader("Configuración")
                    ExportSettingsView()
                        .frame(maxHeight: 400)
                }

                Spacer(minLength: 20)
            }
            .padding(12)
        }
    }

    func panelSectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(.secondary)
            .tracking(1.0)
    }

    // MARK: - SDService → GenerationProgressEngine Wiring

    /// Llama esto cuando el usuario pulsa "Generar" para sincronizar engines.
    func startProgressTracking(baseURL: String, label: String, expectedSteps: Int) {
        GenerationProgressEngine.shared.startPolling(
            baseURL: baseURL,
            label: label,
            totalExpectedSteps: expectedSteps
        )
    }

    /// Llama esto cuando la generación completa para detener el polling.
    func stopProgressTracking() {
        // Dejar que el engine detecte el 100% automáticamente, o forzar si se canceló
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            await MainActor.run {
                if GenerationProgressEngine.shared.isGenerating {
                    GenerationProgressEngine.shared.stopPolling()
                }
            }
        }
    }
}

// MARK: - SetExportPanel

struct SetExportPanel: View {

    @ObservedObject private var exporter = OnlyFansSetExporter.shared
    @ObservedObject private var sessions = ContentSessionManager.shared
    @ObservedObject private var store    = AssetStore.shared
    @State private var selectedSession: ContentSessionManager.ContentSession?
    @State private var customTitle: String = ""
    @State private var isExporting = false
    @State private var exportMsg: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Selector de sesión
            VStack(alignment: .leading, spacing: 4) {
                Text("SESIÓN").font(.system(size: 9, weight: .semibold)).foregroundColor(.secondary).tracking(1)
                HStack(spacing: 6) {
                    Picker("", selection: $selectedSession) {
                        Text("Seleccionar sesión…").tag(nil as ContentSessionManager.ContentSession?)
                        ForEach(sessions.sessions) { session in
                            Text(session.title).tag(session as ContentSessionManager.ContentSession?)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity)
                    .font(.system(size: 11))
                }
            }

            // Assets a exportar
            if let session = selectedSession {
                let approvedAssets = store.recentAssets.filter { $0.statusEnum == .approved }
                HStack(spacing: 6) {
                    Image(systemName: approvedAssets.isEmpty ? "exclamationmark.triangle" : "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(approvedAssets.isEmpty ? Color(hex: "#f59e0b") : Color(hex: "#3de3c0"))
                    Text(approvedAssets.isEmpty
                         ? "No hay imágenes aprobadas para este set"
                         : "\(approvedAssets.count) imágenes aprobadas listas para export")
                        .font(.system(size: 10))
                        .foregroundColor(approvedAssets.isEmpty ? Color(hex: "#f59e0b") : .secondary)
                }

                if !approvedAssets.isEmpty {
                    // Progreso si está exportando
                    if isExporting {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .scaleEffect(0.55)
                                Text(exporter.progress.phase.rawValue)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("\(Int(exporter.progress.fraction * 100))%")
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundColor(Color(hex: "#7c6af7"))
                            }
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.07)).frame(height: 4)
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color(hex: "#7c6af7"))
                                        .frame(width: geo.size.width * exporter.progress.fraction, height: 4)
                                        .animation(.easeInOut(duration: 0.3), value: exporter.progress.fraction)
                                }
                            }.frame(height: 4)
                        }
                        .padding(8)
                        .background(Color.white.opacity(0.04))
                        .cornerRadius(6)
                    }

                    // Botón de export
                    Button(action: { runSetExport(assets: approvedAssets, session: session) }) {
                        HStack(spacing: 6) {
                            Image(systemName: isExporting ? "clock" : "rectangle.stack.fill.badge.plus")
                                .font(.system(size: 12))
                            Text(isExporting ? "Exportando…" : "Exportar Set para OnlyFans")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(isExporting ? Color.white.opacity(0.1) : Color(hex: "#7c6af7"))
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .disabled(isExporting)
                }
            }

            // Mensaje de resultado
            if let msg = exportMsg {
                Text(msg)
                    .font(.system(size: 10))
                    .foregroundColor(msg.hasPrefix("✓") ? Color(hex: "#3de3c0") : Color(hex: "#ef4444"))
                    .lineLimit(2)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.04))
        .cornerRadius(8)
    }

    func runSetExport(assets: [GeneratedAsset], session: ContentSessionManager.ContentSession) {
        isExporting = true
        exportMsg   = nil
        Task {
            do {
                let result = try await OnlyFansSetExporter.shared.exportSet(
                    assets: assets,
                    setTitle: session.title,
                    session: session
                )
                exportMsg   = "✓ \(result.assetCount) imágenes · ZIP: \(result.zipURL?.lastPathComponent ?? "-")"
            } catch {
                exportMsg   = "❌ \(error.localizedDescription)"
            }
            isExporting = false
        }
    }
}
