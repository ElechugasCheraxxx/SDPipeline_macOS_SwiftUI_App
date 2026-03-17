import SwiftUI
import AppKit

// MARK: - BatchRatingView
//
// Curator masivo de imágenes con rating 1–5 estrellas.
// Permite navegar por todos los assets sin rating con teclado:
//
//   1-5   → asignar rating y avanzar
//   →     → siguiente sin calificar
//   ←     → anterior
//   Space → aprobar (rating 4) y avanzar
//   D     → descartar (rating 1) y avanzar
//   S     → saltar sin calificar
//   Del   → rechazar asset (status = rejected)
//
// Activa el estado de aprobado automáticamente cuando rating ≥ 3.
// Activado por: .showBatchRating (SDPipelineApp.swift menú Pipeline)

struct BatchRatingView: View {

    @StateObject private var store      = AssetStore.shared
    @Environment(\.dismiss) private var dismiss

    // ── State ──────────────────────────────────────────────────────────────
    @State private var assets:       [GeneratedAsset] = []
    @State private var currentIndex: Int              = 0
    @State private var hoverRating:  Int              = 0
    @State private var showDone:     Bool             = false
    @State private var ratedCount:   Int              = 0
    @State private var filterStatus: FilterMode       = .unrated

    enum FilterMode: String, CaseIterable {
        case unrated  = "Sin Rating"
        case all      = "Todos"
        case drafts   = "Borradores"
    }

    // MARK: - Computed

    var current: GeneratedAsset? {
        guard !assets.isEmpty, assets.indices.contains(currentIndex) else { return nil }
        return assets[currentIndex]
    }

    var progressFraction: Double {
        guard !assets.isEmpty else { return 0 }
        return Double(currentIndex) / Double(assets.count)
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.white.opacity(0.07))

            if showDone {
                doneView
            } else if assets.isEmpty {
                emptyView
            } else {
                mainContent
            }
        }
        .frame(width: 900, height: 660)
        .background(Color(red: 0.06, green: 0.06, blue: 0.09))
        .onAppear { loadAssets() }
        .onChange(of: filterStatus) { _, _ in loadAssets() }
        .focusable(true)
        .onKeyPress { press in handleKey(press) }
    }

    // MARK: - Header

    var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "star.leadinghalf.filled")
                .font(.system(size: 18))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color(hex: "#fbbf24"), Color(hex: "#f97316")],
                        startPoint: .leading, endPoint: .trailing
                    )
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("Curator de Rating")
                    .font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                if !assets.isEmpty {
                    Text("\(currentIndex + 1) de \(assets.count) · \(ratedCount) calificadas esta sesión")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }
            }

            Spacer()

            // Filter picker
            Picker("", selection: $filterStatus) {
                ForEach(FilterMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)

            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16)).foregroundColor(.secondary)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .background(Color.white.opacity(0.03))
    }

    // MARK: - Main Content

    var mainContent: some View {
        HStack(spacing: 0) {
            // ── Image Panel ────────────────────────────────────────────────
            imagePanel
                .frame(maxWidth: .infinity)

            Divider().background(Color.white.opacity(0.07))

            // ── Control Panel ──────────────────────────────────────────────
            controlPanel
                .frame(width: 280)
        }
    }

    // MARK: - Image Panel

    var imagePanel: some View {
        VStack(spacing: 0) {
            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.white.opacity(0.06)).frame(height: 3)
                    Rectangle()
                        .fill(Color(hex: "#7c6af7"))
                        .frame(width: geo.size.width * progressFraction, height: 3)
                        .animation(.easeInOut(duration: 0.3), value: progressFraction)
                }
            }
            .frame(height: 3)

            // Image
            ZStack {
                Color.black.opacity(0.4)
                if let asset = current, let image = loadImage(asset) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal:   .move(edge: .leading).combined(with: .opacity)
                        ))
                        .id(asset.objectID)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            // Navigation bar
            navigationBar
        }
    }

    var navigationBar: some View {
        HStack(spacing: 16) {
            navButton(icon: "chevron.left", action: previous, hint: "←")
                .disabled(currentIndex == 0)

            Spacer()

            // Quick rating buttons
            HStack(spacing: 6) {
                quickRateButton(rating: 1, icon: "trash", hex: "#ef4444", label: "Descartar")
                quickRateButton(rating: 3, icon: "hand.thumbsup", hex: "#fbbf24", label: "Buena")
                quickRateButton(rating: 5, icon: "star.fill", hex: "#34d399", label: "Maestra")
            }

            Spacer()

            navButton(icon: "chevron.right", action: skip, hint: "→")
                .disabled(currentIndex >= assets.count - 1)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.white.opacity(0.03))
    }

    func navButton(icon: String, action: @escaping () -> Void, hint: String) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 12))
                Text(hint).font(.system(size: 9)).foregroundColor(.secondary)
            }
            .foregroundColor(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.white.opacity(0.06))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    func quickRateButton(rating: Int, icon: String, hex: String, label: String) -> some View {
        Button(action: { rate(rating) }) {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.system(size: 14))
                Text(label).font(.system(size: 9))
            }
            .foregroundColor(Color(hex: hex))
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color(hex: hex).opacity(0.1))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .help("\(label) (tecla \(rating))")
    }

    // MARK: - Control Panel

    var controlPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                // Asset info
                if let asset = current {
                    assetInfoSection(asset)
                }

                Divider().background(Color.white.opacity(0.08))

                // Star rating
                ratingSection

                Divider().background(Color.white.opacity(0.08))

                // Keyboard shortcuts reference
                shortcutsSection

                Divider().background(Color.white.opacity(0.08))

                // Actions
                actionsSection
            }
            .padding(16)
        }
        .background(Color.white.opacity(0.02))
    }

    func assetInfoSection(_ asset: GeneratedAsset) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ASSET")
                .font(.system(size: 9, weight: .semibold)).foregroundColor(.secondary).tracking(1.2)

            Text(asset.displayTitle)
                .font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                .lineLimit(2)

            if let prompt = asset.promptPositive, !prompt.isEmpty {
                Text(prompt.prefix(80) + (prompt.count > 80 ? "…" : ""))
                    .font(.system(size: 10)).foregroundColor(.secondary)
                    .lineLimit(3)
            }

            HStack(spacing: 6) {
                if let date = asset.createdAt {
                    BadgeTag(text: date.formatted(date: .abbreviated, time: .omitted), color: "#6b7280")
                }
                BadgeTag(text: "\(asset.width)×\(asset.height)", color: "#7c6af7")
                StatusBadge(status: asset.statusEnum)
            }
        }
    }

    var ratingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CALIFICACIÓN")
                .font(.system(size: 9, weight: .semibold)).foregroundColor(.secondary).tracking(1.2)

            HStack(spacing: 8) {
                ForEach(1...5, id: \.self) { star in
                    Button(action: { rate(star) }) {
                        VStack(spacing: 3) {
                            Image(systemName: effectiveStar(star) >= star ? "star.fill" : "star")
                                .font(.system(size: 22))
                                .foregroundColor(starColor(star))
                            Text("\(star)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .onHover { inside in hoverRating = inside ? star : 0 }
                    .scaleEffect(hoverRating == star ? 1.15 : 1.0)
                    .animation(.spring(response: 0.2), value: hoverRating)
                }
            }

            if let asset = current, asset.rating > 0 {
                Text(ratingLabel(Int(asset.rating)))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(starHex(Int(asset.rating)))
            }
        }
    }

    var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ATAJOS DE TECLADO")
                .font(.system(size: 9, weight: .semibold)).foregroundColor(.secondary).tracking(1.2)

            let shortcuts: [(key: String, action: String, color: String)] = [
                ("1–5", "Calificar y avanzar", "#7c6af7"),
                ("Space", "Aprobar (★4) y avanzar", "#34d399"),
                ("D", "Descartar (★1)", "#ef4444"),
                ("S / →", "Saltar", "#6b7280"),
                ("←", "Anterior", "#6b7280"),
                ("Del", "Rechazar asset", "#f97316"),
            ]

            ForEach(shortcuts, id: \.key) { item in
                HStack(spacing: 8) {
                    Text(item.key)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(hex: item.color))
                        .frame(width: 50)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color(hex: item.color).opacity(0.1))
                        .cornerRadius(4)
                    Text(item.action)
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }
            }
        }
    }

    var actionsSection: some View {
        VStack(spacing: 8) {
            if let asset = current {
                Button(action: { rejectAsset(asset) }) {
                    Label("Rechazar asset", systemImage: "xmark.circle")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#ef4444"))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(Color(hex: "#ef4444").opacity(0.08))
                        .cornerRadius(7)
                }
                .buttonStyle(.plain)

                Button(action: { approveAsset(asset) }) {
                    Label("Aprobar asset", systemImage: "checkmark.circle")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#34d399"))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(Color(hex: "#34d399").opacity(0.08))
                        .cornerRadius(7)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Empty / Done Views

    var emptyView: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundColor(Color(hex: "#34d399"))
            Text("No hay assets para calificar")
                .font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
            Text(filterStatus == .unrated
                 ? "Todos los assets ya tienen rating asignado."
                 : "No hay assets en esta categoría.")
                .font(.system(size: 11)).foregroundColor(.secondary)
            Button("Cerrar") { dismiss() }
                .buttonStyle(.plain)
                .padding(.horizontal, 20).padding(.vertical, 8)
                .background(Color(hex: "#7c6af7")).foregroundColor(.white)
                .cornerRadius(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var doneView: some View {
        VStack(spacing: 16) {
            Image(systemName: "trophy.fill")
                .font(.system(size: 48))
                .foregroundStyle(LinearGradient(
                    colors: [Color(hex: "#fbbf24"), Color(hex: "#f97316")],
                    startPoint: .top, endPoint: .bottom))
            Text("¡Sesión de curaduría completada!")
                .font(.system(size: 16, weight: .bold)).foregroundColor(.white)
            Text("\(ratedCount) imágenes calificadas en esta sesión.")
                .font(.system(size: 12)).foregroundColor(.secondary)
            HStack(spacing: 12) {
                Button("Otra vuelta") {
                    showDone = false; ratedCount = 0; loadAssets()
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Color.white.opacity(0.08)).foregroundColor(.white)
                .cornerRadius(8)
                Button("Cerrar") { dismiss() }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Color(hex: "#7c6af7")).foregroundColor(.white)
                    .cornerRadius(8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helper Computations

    func effectiveStar(_ star: Int) -> Int { hoverRating > 0 ? hoverRating : Int(current?.rating ?? 0) }

    func starColor(_ star: Int) -> Color {
        let eff = effectiveStar(star)
        guard star <= eff, eff > 0 else { return .white.opacity(0.15) }
        return Color(hex: starHexStr(eff))
    }

    func starHex(_ rating: Int) -> Color { Color(hex: starHexStr(rating)) }

    func starHexStr(_ r: Int) -> String {
        switch r {
        case 1: return "#ef4444"
        case 2: return "#f97316"
        case 3: return "#fbbf24"
        case 4: return "#84cc16"
        default: return "#34d399"
        }
    }

    func ratingLabel(_ r: Int) -> String {
        switch r {
        case 1: return "Descartar"
        case 2: return "Regular"
        case 3: return "Buena"
        case 4: return "Muy buena"
        case 5: return "Maestra"
        default: return ""
        }
    }

    func loadImage(_ asset: GeneratedAsset) -> NSImage? {
        if let thumb = asset.thumbnail { return thumb }
        if let path = asset.imagePath  { return NSImage(contentsOfFile: path) }
        return nil
    }

    // MARK: - Actions

    func loadAssets() {
        let all: [GeneratedAsset]
        switch filterStatus {
        case .unrated: all = AssetStore.shared.fetchAllAssets(limit: 1000).filter { $0.rating == 0 }
        case .all:     all = AssetStore.shared.fetchAllAssets(limit: 500)
        case .drafts:  all = AssetStore.shared.assets(withStatus: .draft, limit: 500)
        }
        assets       = all
        currentIndex = 0
        showDone     = false
    }

    func rate(_ rating: Int) {
        guard let asset = current else { return }
        let newRating = Int(asset.rating) == rating ? 0 : rating
        store.updateRating(asset, rating: newRating)
        if newRating >= 3 { store.updateStatus(asset, status: .approved) }
        ratedCount += 1
        advance()
    }

    func skip() {
        if currentIndex < assets.count - 1 { currentIndex += 1 }
        else { showDone = true }
    }

    func previous() {
        if currentIndex > 0 { currentIndex -= 1 }
    }

    func advance() {
        if currentIndex < assets.count - 1 {
            withAnimation(.easeInOut(duration: 0.2)) { currentIndex += 1 }
        } else {
            showDone = true
        }
    }

    func rejectAsset(_ asset: GeneratedAsset) {
        store.updateStatus(asset, status: .rejected)
        store.updateRating(asset, rating: 1)
        advance()
    }

    func approveAsset(_ asset: GeneratedAsset) {
        store.updateStatus(asset, status: .approved)
        if asset.rating == 0 { store.updateRating(asset, rating: 4) }
        advance()
    }

    func handleKey(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .init("1"): rate(1); return .handled
        case .init("2"): rate(2); return .handled
        case .init("3"): rate(3); return .handled
        case .init("4"): rate(4); return .handled
        case .init("5"): rate(5); return .handled
        case .space:     rate(4); return .handled
        case .init("d"), .init("D"): rate(1); return .handled
        case .init("s"), .init("S"): skip(); return .handled
        case .rightArrow: skip(); return .handled
        case .leftArrow:  previous(); return .handled
        case .delete:
            if let asset = current { rejectAsset(asset) }
            return .handled
        default: return .ignored
        }
    }
}
