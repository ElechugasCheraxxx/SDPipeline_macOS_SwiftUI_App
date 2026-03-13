import SwiftUI
import Combine

// MARK: - DashboardViewModel v4
// Extiende DashboardSnapshot con:
//   • KPIs de compliance (publicaciones, score)
//   • Estado de cifrado (activo/inactivo)
//   • Tags únicos del vault
//   • IP-Adapter usage stats
//   • AB Tests activos
//   • Proyectos activos

@MainActor
final class DashboardViewModel: ObservableObject {

    static let shared = DashboardViewModel()
    private init() {}

    @Published var snapshot:      DashboardSnapshot = DashboardSnapshot()
    @Published var isRefreshing:  Bool = false

    // MARK: - Snapshot

    struct DashboardSnapshot {
        // Assets
        var totalAssets:      Int    = 0
        var assetsToday:      Int    = 0
        var assetsLast7Days:  Int    = 0
        var assetsLast30Days: Int    = 0
        var approvedAssets:   Int    = 0
        var rejectedAssets:   Int    = 0
        var publishedAssets:  Int    = 0
        var approvalRate:     Double = 0
        var averageRating:    Double = 0
        var ratingDistribution: [Int: Int] = [:]

        // Prompts
        var topPromptVersions:    [PromptVersioningStore.PromptVersion] = []
        var totalPromptVersions:  Int = 0

        // Models
        var checkpointDistribution: [(name: String, count: Int)] = []

        // Sessions
        var activeSessions:     Int    = 0
        var totalSessions:      Int    = 0
        var activeSessionTitle: String = "—"

        // Security
        var nsfwQuarantineCount: Int = 0
        var promptBlockedCount:  Int = 0

        // Backup
        var lastBackupAt:    Date? = nil
        var backupOK:        Bool  = false

        // GPU
        var gpuDeviceName:   String = "—"
        var gpuVRAMFreeMB:   Double = 0

        // Seeds
        var favoriteSeedCount: Int  = 0
        var topSeedUsed:       Int? = nil

        // NEW v4
        var uniqueTags:        Int    = 0
        var taggedAssets:      Int    = 0
        var encryptionActive:  Bool   = false
        var complianceScore:   Double = 0
        var publishedTotal:    Int    = 0
        var activeProjects:    Int    = 0
        var abTestsActive:     Int    = 0
        var ipAdapterEnabled:  Bool   = false
        var icLightInstalled:  Bool   = false
        var externalEditors:   Int    = 0
    }

    // MARK: - Refresh

    func refresh() {
        isRefreshing = true
        let store  = AssetStore.shared
        let assets = store.fetchAllAssets(limit: 1000)
        let now    = Date()
        let cal    = Calendar.current
        var snap   = DashboardSnapshot()

        // ── Assets ─────────────────────────────────────────────────────
        snap.totalAssets      = assets.count
        snap.assetsToday      = assets.filter { cal.isDateInToday($0.createdAt ?? .distantPast) }.count
        snap.assetsLast7Days  = assets.filter { ($0.createdAt ?? .distantPast) >= now.addingTimeInterval(-7 * 86400) }.count
        snap.assetsLast30Days = assets.filter { ($0.createdAt ?? .distantPast) >= now.addingTimeInterval(-30 * 86400) }.count

        // Quality
        snap.approvedAssets   = assets.filter { $0.statusEnum == .approved  }.count
        snap.rejectedAssets   = assets.filter { $0.statusEnum == .rejected  }.count
        snap.publishedAssets  = assets.filter { $0.statusEnum == .published }.count
        snap.approvalRate     = assets.isEmpty ? 0 : Double(snap.approvedAssets) / Double(assets.count)

        let rated = assets.filter { $0.rating > 0 }
        snap.averageRating    = rated.isEmpty ? 0 :
            Double(rated.map { Int($0.rating) }.reduce(0, +)) / Double(rated.count)
        for r in 0...5 { snap.ratingDistribution[r] = assets.filter { Int($0.rating) == r }.count }

        // Checkpoints
        var cpCounts: [String: Int] = [:]
        for a in assets {
            let cp = (a.checkpoint ?? "desconocido").components(separatedBy: "/").last ?? "desconocido"
            cpCounts[cp, default: 0] += 1
        }
        snap.checkpointDistribution = cpCounts.sorted { $0.value > $1.value }.prefix(6).map { (name: $0.key, count: $0.value) }

        // ── Prompts ─────────────────────────────────────────────────────
        snap.topPromptVersions   = PromptVersioningStore.shared.topPrompts(count: 5)
        snap.totalPromptVersions = PromptVersioningStore.shared.versions.count

        // ── Sessions ────────────────────────────────────────────────────
        let sessions = ContentSessionManager.shared.sessions
        snap.totalSessions      = sessions.count
        snap.activeSessions     = sessions.filter { $0.isActive }.count
        snap.activeSessionTitle = ContentSessionManager.shared.activeSession?.title ?? "—"

        // ── Security ────────────────────────────────────────────────────
        snap.nsfwQuarantineCount = NSFWDetector.shared.log.filter { $0.action == .quarantine }.count
        snap.promptBlockedCount  = ZeroKnowledgeLog.shared.entries(category: .promptBlocked).count

        // ── Backup ──────────────────────────────────────────────────────
        snap.lastBackupAt = BackupManager.shared.config.lastBackupAt
        snap.backupOK     = BackupManager.shared.config.lastBackupOK

        // ── GPU ─────────────────────────────────────────────────────────
        snap.gpuDeviceName   = GPUMonitor.shared.deviceName
        let vramBytes        = GPUMonitor.shared.isAppleSilicon ? GPUMonitor.shared.ramFree : GPUMonitor.shared.vramFree
        snap.gpuVRAMFreeMB   = Double(vramBytes) / 1_048_576.0

        // ── Seeds ───────────────────────────────────────────────────────
        snap.favoriteSeedCount = SeedManager.shared.favorites.count
        snap.topSeedUsed       = SeedManager.shared.topSeeds(count: 1).first?.seed

        // ── NEW v4: Tagging ─────────────────────────────────────────────
        snap.uniqueTags   = TaggingEngine.shared.uniqueTagCount
        snap.taggedAssets = TaggingEngine.shared.totalTaggedAssets

        // ── NEW v4: Crypto ──────────────────────────────────────────────
        snap.encryptionActive = VaultCryptoEngine.shared.isEncryptionEnabled

        // ── NEW v4: Compliance ──────────────────────────────────────────
        snap.complianceScore  = PublishComplianceLogger.shared.complianceScore
        snap.publishedTotal   = PublishComplianceLogger.shared.totalFilesPublished

        // ── NEW v4: Projects ────────────────────────────────────────────
        snap.activeProjects   = ProjectFolderManager.shared.projects.count

        // ── NEW v4: AB Tests ────────────────────────────────────────────
        snap.abTestsActive    = ABTestingEngine.shared.tests.filter { $0.status == .running }.count

        // ── NEW v4: Tools ───────────────────────────────────────────────
        snap.ipAdapterEnabled  = IPAdapterEngine.shared.isEnabled
        snap.icLightInstalled  = ICLightEngine.shared.isInstalled
        snap.externalEditors   = ExternalEditorBridge.shared.installedEditors.count

        self.snapshot    = snap
        self.isRefreshing = false
    }
}

// MARK: - DashboardView v4

struct DashboardView: View {

    @StateObject private var vm  = DashboardViewModel.shared
    @StateObject private var gpu = GPUMonitor.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // ── Header ────────────────────────────────────────────────
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Studio KPIs").font(.system(size: 16, weight: .bold)).foregroundColor(.white)
                        Text(AppEnvironment.shared.fullHealthStatus)
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: { vm.refresh() }) {
                        HStack(spacing: 5) {
                            if vm.isRefreshing { ProgressView().scaleEffect(0.6).progressViewStyle(.circular) }
                            else { Image(systemName: "arrow.clockwise").font(.system(size: 11)) }
                            Text("Actualizar").font(.system(size: 11))
                        }
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.white.opacity(0.06)).cornerRadius(6)
                    }.buttonStyle(.plain)
                }

                // ── Row 1: Assets ─────────────────────────────────────────
                kpiSection("Generación") {
                    kpi("Total",       "\(vm.snapshot.totalAssets)",       sub: "assets")
                    kpi("Hoy",         "\(vm.snapshot.assetsToday)",       sub: "generados", accent: "#3de3c0")
                    kpi("7 días",      "\(vm.snapshot.assetsLast7Days)",   sub: "generados")
                    kpi("Rating",      String(format: "%.1f ★", vm.snapshot.averageRating), sub: "promedio", accent: "#fbbf24")
                }

                // ── Row 2: Curaduría ──────────────────────────────────────
                kpiSection("Curaduría") {
                    kpi("Aprobados",   "\(vm.snapshot.approvedAssets)",    sub: "assets", accent: "#34d399")
                    kpi("Publicados",  "\(vm.snapshot.publishedAssets)",   sub: "assets", accent: "#60a5fa")
                    kpi("Rechazados",  "\(vm.snapshot.rejectedAssets)",    sub: "assets", accent: "#ef4444")
                    kpi("Tasa apr.",   String(format: "%.0f%%", vm.snapshot.approvalRate * 100), sub: "aprobación")
                }

                // ── Row 3: Seguridad + Cifrado (NEW) ──────────────────────
                kpiSection("Seguridad") {
                    kpi("Cifrado",
                        vm.snapshot.encryptionActive ? "AES-256" : "Off",
                        sub: "vault",
                        accent: vm.snapshot.encryptionActive ? "#34d399" : "#ef4444")
                    kpi("NSFW",        "\(vm.snapshot.nsfwQuarantineCount)", sub: "cuarentena", accent: "#f97316")
                    kpi("Prompts",     "\(vm.snapshot.promptBlockedCount)",  sub: "bloqueados",  accent: "#ef4444")
                    kpi("Compliance",  String(format: "%.0f%%", vm.snapshot.complianceScore * 100), sub: "score", accent: "#7c6af7")
                }

                // ── Row 4: Tags (NEW) ─────────────────────────────────────
                kpiSection("Tags y Contenido") {
                    kpi("Tags únicos", "\(vm.snapshot.uniqueTags)",   sub: "en vault", accent: "#a78bfa")
                    kpi("Con tags",    "\(vm.snapshot.taggedAssets)",  sub: "assets")
                    kpi("Sesiones",    "\(vm.snapshot.totalSessions)", sub: "totales")
                    kpi("Proyectos",   "\(vm.snapshot.activeProjects)", sub: "en vault", accent: "#3de3c0")
                }

                // ── Row 5: Herramientas (NEW) ─────────────────────────────
                kpiSection("Herramientas IA") {
                    kpi("IP-Adapter",   vm.snapshot.ipAdapterEnabled ? "Activo" : "Off",
                        sub: "FaceID", accent: vm.snapshot.ipAdapterEnabled ? "#7c6af7" : nil)
                    kpi("IC-Light",     vm.snapshot.icLightInstalled ? "Instalado" : "Fallback",
                        sub: "relight", accent: vm.snapshot.icLightInstalled ? "#fbbf24" : nil)
                    kpi("A/B Tests",    "\(vm.snapshot.abTestsActive)",     sub: "activos")
                    kpi("Editores",     "\(vm.snapshot.externalEditors)",   sub: "detectados")
                }

                // ── Row 6: Publicación (NEW) ──────────────────────────────
                kpiSection("Publicación") {
                    kpi("Publicados",  "\(vm.snapshot.publishedTotal)",  sub: "archivos")
                    kpi("Backup",      vm.snapshot.backupOK ? "✓ OK" : "⚠ Error",
                        sub: vm.snapshot.lastBackupAt?.shortDisplay ?? "nunca",
                        accent: vm.snapshot.backupOK ? "#34d399" : "#ef4444")
                    kpi("Seeds fav",   "\(vm.snapshot.favoriteSeedCount)", sub: "guardados", accent: "#fbbf24")
                    kpi("Prompts",     "\(vm.snapshot.totalPromptVersions)", sub: "versiones")
                }

                // ── GPU Monitor ───────────────────────────────────────────
                gpuSection

                // ── Checkpoint breakdown ──────────────────────────────────
                if !vm.snapshot.checkpointDistribution.isEmpty {
                    checkpointChart
                }

                // ── Rating distribution ───────────────────────────────────
                ratingChart

                // ── Top Prompts ───────────────────────────────────────────
                if !vm.snapshot.topPromptVersions.isEmpty {
                    topPromptsSection
                }
            }
            .padding(16)
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.11))
        .onAppear { vm.refresh() }
    }

    // MARK: - KPI Grid

    @ViewBuilder
    func kpiSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold)).foregroundColor(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                content()
            }
        }
    }

    func kpi(_ title: String, _ value: String, sub: String? = nil, accent: String? = nil) -> some View {
        let accentColor = accent.map { Color(hex: $0) } ?? Color.white.opacity(0.7)
        return VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(accentColor)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(title).font(.system(size: 10, weight: .medium)).foregroundColor(.white)
            if let sub { Text(sub).font(.system(size: 9)).foregroundColor(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.white.opacity(0.04))
        .cornerRadius(8)
    }

    // MARK: - GPU Section

    var gpuSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GPU / HARDWARE".uppercased()).font(.system(size: 9, weight: .semibold)).foregroundColor(.secondary)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(vm.snapshot.gpuDeviceName).font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                    Text(gpu.isAppleSilicon ? "Apple Silicon — MPS activo" : "GPU dedicada")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%.0f MB", vm.snapshot.gpuVRAMFreeMB))
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(vramColor(vm.snapshot.gpuVRAMFreeMB))
                    Text("VRAM libre").font(.system(size: 10)).foregroundColor(.secondary)
                }
            }
            .padding(12).background(Color.white.opacity(0.04)).cornerRadius(8)
        }
    }

    private func vramColor(_ mb: Double) -> Color {
        if mb > 4000 { return Color(hex: "#34d399") }
        if mb > 2000 { return Color(hex: "#fbbf24") }
        return Color(hex: "#ef4444")
    }

    // MARK: - Checkpoint Chart

    var checkpointChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CHECKPOINTS".uppercased()).font(.system(size: 9, weight: .semibold)).foregroundColor(.secondary)
            ForEach(vm.snapshot.checkpointDistribution, id: \.name) { item in
                let total = max(vm.snapshot.totalAssets, 1)
                let pct   = Double(item.count) / Double(total)
                HStack(spacing: 8) {
                    Text(item.name).font(.system(size: 10)).foregroundColor(.white).lineLimit(1).frame(width: 120, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.05))
                            RoundedRectangle(cornerRadius: 3).fill(Color(hex: "#7c6af7").opacity(0.6))
                                .frame(width: geo.size.width * pct)
                        }
                    }.frame(height: 8)
                    Text("\(item.count)").font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary).frame(width: 30)
                }
            }
        }
        .padding(12).background(Color.white.opacity(0.04)).cornerRadius(8)
    }

    // MARK: - Rating Distribution

    var ratingChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RATING".uppercased()).font(.system(size: 9, weight: .semibold)).foregroundColor(.secondary)
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(1...5, id: \.self) { r in
                    let count   = vm.snapshot.ratingDistribution[r] ?? 0
                    let maxCount = (1...5).compactMap { vm.snapshot.ratingDistribution[$0] }.max() ?? 1
                    let height  = maxCount > 0 ? CGFloat(count) / CGFloat(maxCount) * 60 : 0
                    VStack(spacing: 4) {
                        Text("\(count)").font(.system(size: 9)).foregroundColor(.secondary)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(hex: "#fbbf24").opacity(0.4 + Double(r) * 0.12))
                            .frame(width: 28, height: max(height, 4))
                        Text("\(r)★").font(.system(size: 9)).foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(12).background(Color.white.opacity(0.04)).cornerRadius(8)
    }

    // MARK: - Top Prompts

    var topPromptsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TOP PROMPTS".uppercased()).font(.system(size: 9, weight: .semibold)).foregroundColor(.secondary)
            ForEach(vm.snapshot.topPromptVersions) { version in
                VStack(alignment: .leading, spacing: 3) {
                    Text(version.title.isEmpty ? "(sin título)" : version.title)
                        .font(.system(size: 11, weight: .medium)).foregroundColor(.white)
                    Text(version.positive.prefix(100) + (version.positive.count > 100 ? "…" : ""))
                        .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(2)
                }
                .padding(8).background(Color.white.opacity(0.04)).cornerRadius(6)
            }
        }
    }
}
