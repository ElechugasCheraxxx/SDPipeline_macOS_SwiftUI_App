import SwiftUI
import Combine

// MARK: - DashboardView
//
// Dashboard de métricas y KPIs del estudio.
// Agrega datos de AssetStore, PublishEngine, BackupManager, GPUMonitor,
// NSFWDetector y PromptVersioningStore para dar una vista operacional.
//
// KPIs:
//   • Total generaciones (hoy / 7d / 30d / total)
//   • Tasa de aprobación (aprobadas / total)
//   • Rating promedio de assets
//   • Prompts más usados (top 5)
//   • Distribución por checkpoint
//   • Historial de exports y publicaciones
//   • Alertas de seguridad (NSFW quarantine count)
//   • Estado de backup
//
// ROADMAP: "Dashboard de métricas/KPIs" (🟡 Medio Plazo)

@MainActor
final class DashboardViewModel: ObservableObject {

    static let shared = DashboardViewModel()
    private init() {}

    @Published var snapshot: DashboardSnapshot = DashboardSnapshot()
    @Published var isRefreshing: Bool = false

    struct DashboardSnapshot {
        // Generaciones
        var totalAssets:       Int    = 0
        var assetsToday:       Int    = 0
        var assetsLast7Days:   Int    = 0
        var assetsLast30Days:  Int    = 0

        // Calidad
        var approvedAssets:    Int    = 0
        var approvalRate:      Double = 0   // 0–1
        var averageRating:     Double = 0
        var ratingDistribution: [Int: Int] = [:] // rating → count

        // Tiempos
        var averageGenTime:    Double = 0   // segundos
        var totalGenTimeHours: Double = 0

        // Prompts
        var topPromptVersions: [PromptVersioningStore.PromptVersion] = []
        var totalPromptVersions: Int = 0

        // Checkpoints
        var checkpointDistribution: [(name: String, count: Int)] = []

        // Exports
        var totalExports:      Int    = 0
        var exportsLast7Days:  Int    = 0

        // Seguridad
        var nsfwQuarantineCount: Int  = 0
        var promptBlockedCount:  Int  = 0

        // Backup
        var lastBackupAt:      Date?  = nil
        var backupIsHealthy:   Bool   = false

        // GPU
        var gpuDeviceName:     String = "—"
    }

    func refresh() {
        isRefreshing = true
        let store   = AssetStore.shared
        let assets  = store.recentAssets
        let now     = Date()
        let cal     = Calendar.current

        var snap = DashboardSnapshot()

        // ── Asset counts ────────────────────────────────────────────────
        snap.totalAssets     = assets.count
        snap.assetsToday     = assets.filter {
            cal.isDateInToday($0.createdAt ?? .distantPast)
        }.count
        snap.assetsLast7Days = assets.filter {
            ($0.createdAt ?? .distantPast) >= now.addingTimeInterval(-7*86400)
        }.count
        snap.assetsLast30Days = assets.filter {
            ($0.createdAt ?? .distantPast) >= now.addingTimeInterval(-30*86400)
        }.count

        // ── Quality ──────────────────────────────────────────────────────
        let approved = assets.filter { $0.statusEnum == .approved }
        snap.approvedAssets = approved.count
        snap.approvalRate   = assets.isEmpty ? 0 : Double(approved.count) / Double(assets.count)

        let rated = assets.filter { $0.rating > 0 }
        snap.averageRating  = rated.isEmpty ? 0 : Double(rated.map { Int($0.rating) }.reduce(0,+)) / Double(rated.count)

        for r in 0...5 {
            snap.ratingDistribution[r] = assets.filter { Int($0.rating) == r }.count
        }

        // ── Gen times (from ModelBenchmarks) ────────────────────────────
        let allBenchmarks = ModelManager.shared.availableModels.flatMap { $0.benchmarks }
        if !allBenchmarks.isEmpty {
            let total = allBenchmarks.map { $0.genTime }.reduce(0, +)
            snap.averageGenTime    = total / Double(allBenchmarks.count)
            snap.totalGenTimeHours = total / 3600
        }

        // ── Prompts ──────────────────────────────────────────────────────
        let pStore = PromptVersioningStore.shared
        snap.topPromptVersions  = pStore.topPrompts(limit: 5)
        snap.totalPromptVersions = pStore.versions.count

        // ── Checkpoint distribution ──────────────────────────────────────
        var cpDict: [String: Int] = [:]
        for asset in assets {
            let cp = asset.checkpoint?.isEmpty == false
                ? ((asset.checkpoint! as NSString).deletingPathExtension
                    .components(separatedBy: .init(charactersIn: "/_")).last ?? "Unknown")
                : "Unknown"
            cpDict[cp, default: 0] += 1
        }
        snap.checkpointDistribution = cpDict
            .sorted { $0.value > $1.value }
            .prefix(6)
            .map { (name: $0.key, count: $0.value) }

        // ── Exports ──────────────────────────────────────────────────────
        let publishLog = PublishEngine.shared.publishLog
        snap.totalExports     = publishLog.count
        snap.exportsLast7Days = publishLog.filter {
            $0.timestamp >= now.addingTimeInterval(-7*86400)
        }.count

        // ── Security (from ZK log cache) ────────────────────────────────
        let zkLog = ZeroKnowledgeLog.shared
        snap.nsfwQuarantineCount = zkLog.decryptedEntries.filter { $0.category == .nsfwQuarantine }.count
        snap.promptBlockedCount  = zkLog.decryptedEntries.filter { $0.category == .promptBlocked }.count

        // ── Backup ───────────────────────────────────────────────────────
        let backup = BackupManager.shared
        snap.lastBackupAt    = backup.lastBackupAt
        snap.backupIsHealthy = backup.rcloneAvailable && !backup.isRunning
            && (backup.lastBackupAt.map { now.timeIntervalSince($0) < 86400 * 2 } ?? false)

        // ── GPU ──────────────────────────────────────────────────────────
        snap.gpuDeviceName = GPUMonitor.shared.deviceName

        snapshot    = snap
        isRefreshing = false
    }
}

// MARK: - DashboardView

struct DashboardView: View {

    @StateObject private var vm = DashboardViewModel.shared
    @State private var autoRefresh = true
    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                // ── Header ───────────────────────────────────────────────
                HStack(spacing: 8) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: 14))
                        .foregroundColor(Color(hex: "#7c6af7"))
                    Text("Studio Dashboard")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                    Spacer()
                    if vm.isRefreshing {
                        ProgressView()
                            .scaleEffect(0.6)
                            .progressViewStyle(.circular)
                    }
                    Button(action: { vm.refresh() }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 4)

                // ── Row 1: Generaciones KPIs ─────────────────────────────
                kpiRow {
                    kpiCard("Total", value: "\(vm.snapshot.totalAssets)", icon: "photo.stack", color: "#7c6af7")
                    kpiCard("Hoy",   value: "\(vm.snapshot.assetsToday)",      icon: "sun.max.fill",   color: "#fbbf24")
                    kpiCard("7 días", value: "\(vm.snapshot.assetsLast7Days)", icon: "calendar",       color: "#34d399")
                    kpiCard("30 días", value: "\(vm.snapshot.assetsLast30Days)", icon: "calendar.badge.clock", color: "#60a5fa")
                }

                // ── Row 2: Quality KPIs ──────────────────────────────────
                kpiRow {
                    kpiCard("Aprobadas",
                            value: String(format: "%.0f%%", vm.snapshot.approvalRate * 100),
                            icon: "checkmark.seal.fill", color: "#34d399")
                    kpiCard("Rating Ø",
                            value: String(format: "%.1f★", vm.snapshot.averageRating),
                            icon: "star.fill", color: "#fbbf24")
                    kpiCard("Prompts",
                            value: "\(vm.snapshot.totalPromptVersions)",
                            icon: "doc.text.fill", color: "#a78bfa")
                    kpiCard("Exports",
                            value: "\(vm.snapshot.totalExports)",
                            icon: "arrow.up.doc.fill", color: "#f97316")
                }

                // ── Rating Distribution ──────────────────────────────────
                dashCard(title: "Distribución de Rating", icon: "star.leadinghalf.filled") {
                    HStack(alignment: .bottom, spacing: 8) {
                        ForEach(1...5, id: \.self) { star in
                            let count = vm.snapshot.ratingDistribution[star] ?? 0
                            let maxCount = vm.snapshot.ratingDistribution.values.max() ?? 1
                            let height = maxCount > 0 ? CGFloat(count) / CGFloat(maxCount) * 60 : 0
                            VStack(spacing: 4) {
                                Text("\(count)")
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.yellow.opacity(0.5 + Double(star) * 0.1))
                                    .frame(width: 24, height: max(4, height))
                                Text("\(star)★")
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        // Unrated
                        let unratedCount = vm.snapshot.ratingDistribution[0] ?? 0
                        VStack(spacing: 4) {
                            Text("\(unratedCount)")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.white.opacity(0.1))
                                .frame(width: 24, height: max(4, 10))
                            Text("—")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(height: 80)
                }

                // ── Checkpoints + Top Prompts ────────────────────────────
                HStack(alignment: .top, spacing: 12) {
                    dashCard(title: "Checkpoints", icon: "cpu.fill") {
                        VStack(spacing: 5) {
                            ForEach(vm.snapshot.checkpointDistribution, id: \.name) { item in
                                HStack(spacing: 6) {
                                    Text(item.name)
                                        .font(.system(size: 10))
                                        .foregroundColor(.white.opacity(0.8))
                                        .lineLimit(1)
                                    Spacer()
                                    Text("\(item.count)")
                                        .font(.system(size: 9))
                                        .foregroundColor(.secondary)
                                }
                                let total = vm.snapshot.totalAssets
                                let pct = total > 0 ? CGFloat(item.count) / CGFloat(total) : 0
                                GeometryReader { geo in
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color(hex: "#7c6af7").opacity(0.3))
                                        .frame(width: max(4, geo.size.width * pct), height: 3)
                                }
                                .frame(height: 3)
                            }
                            if vm.snapshot.checkpointDistribution.isEmpty {
                                Text("Sin datos").font(.system(size: 10)).foregroundColor(.secondary)
                            }
                        }
                    }

                    dashCard(title: "Top Prompts", icon: "doc.text.magnifyingglass") {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(vm.snapshot.topPromptVersions) { pv in
                                HStack(spacing: 4) {
                                    Text(pv.label)
                                        .font(.system(size: 10))
                                        .foregroundColor(.white.opacity(0.75))
                                        .lineLimit(1)
                                    Spacer()
                                    Text("\(pv.usageCount)×")
                                        .font(.system(size: 9))
                                        .foregroundColor(.secondary)
                                }
                            }
                            if vm.snapshot.topPromptVersions.isEmpty {
                                Text("Sin datos").font(.system(size: 10)).foregroundColor(.secondary)
                            }
                        }
                    }
                }

                // ── Security + Backup status ─────────────────────────────
                dashCard(title: "Seguridad & Backup", icon: "lock.shield.fill") {
                    HStack(spacing: 20) {
                        securityStat(label: "NSFW Quarantine",
                                     value: "\(vm.snapshot.nsfwQuarantineCount)",
                                     color: vm.snapshot.nsfwQuarantineCount > 0 ? "#f97316" : "#34d399")
                        securityStat(label: "Prompts Bloqueados",
                                     value: "\(vm.snapshot.promptBlockedCount)",
                                     color: vm.snapshot.promptBlockedCount > 0 ? "#ef4444" : "#34d399")
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(vm.snapshot.backupIsHealthy ? Color(hex: "#34d399") : Color(hex: "#ef4444"))
                                    .frame(width: 6, height: 6)
                                Text(vm.snapshot.backupIsHealthy ? "Backup OK" : "Backup pendiente")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            if let last = vm.snapshot.lastBackupAt {
                                Text("Último: \(last, style: .relative)")
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }

                // ── GPU ──────────────────────────────────────────────────
                dashCard(title: "Hardware", icon: "cpu.fill") {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("GPU / Accelerator")
                                .font(.system(size: 9)).foregroundColor(.secondary)
                            Text(vm.snapshot.gpuDeviceName)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white)
                        }
                        if vm.snapshot.averageGenTime > 0 {
                            Divider().frame(height: 28).background(Color.white.opacity(0.1))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Gen time Ø")
                                    .font(.system(size: 9)).foregroundColor(.secondary)
                                Text(String(format: "%.1fs", vm.snapshot.averageGenTime))
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.white)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Total compute")
                                    .font(.system(size: 9)).foregroundColor(.secondary)
                                Text(String(format: "%.1fh", vm.snapshot.totalGenTimeHours))
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.white)
                            }
                        }
                        Spacer()
                    }
                }

                Spacer(minLength: 20)
            }
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.11))
        .onAppear { vm.refresh() }
        .onReceive(timer) { _ in if autoRefresh { vm.refresh() } }
    }

    // MARK: - Sub-components

    func kpiRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) { content() }
            .padding(.horizontal, 14)
    }

    func kpiCard(_ title: String, value: String, icon: String, color: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: color))
                Text(title)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
            }
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(hex: color).opacity(0.2), lineWidth: 1))
    }

    func dashCard<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "#7c6af7"))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
            }
            content()
        }
        .padding(12)
        .background(Color.white.opacity(0.03))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.06), lineWidth: 1))
        .padding(.horizontal, 14)
    }

    func securityStat(label: String, value: String, color: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 9)).foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(Color(hex: color))
        }
    }
}
