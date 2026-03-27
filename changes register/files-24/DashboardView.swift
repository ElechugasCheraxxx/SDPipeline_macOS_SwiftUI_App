import SwiftUI
import Combine

// MARK: - DashboardViewModel v3
// FIXES:
//   - GPUMonitor.vramFreeMB → GPUMonitor.vramFree (Int64, bytes)
//   - GPUMonitor.powerDraw / utilizationPercent → no existen, eliminados
//   - BackupManager.isHealthy → backupMgr.config.lastBackupOK
//   - refresh() usa fetchAllAssets(500) no recentAssets(50)
//   - ContentSessionManager.newSession() → .create()

@MainActor
final class DashboardViewModel: ObservableObject {

    static let shared = DashboardViewModel()
    private init() {}

    @Published var snapshot:      DashboardSnapshot = DashboardSnapshot()
    @Published var isRefreshing:  Bool = false

    // MARK: - Snapshot

    struct DashboardSnapshot {
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

        var topPromptVersions:    [PromptVersioningStore.PromptVersion] = []
        var totalPromptVersions:  Int = 0

        var checkpointDistribution: [(name: String, count: Int)] = []

        var activeSessions:     Int    = 0
        var totalSessions:      Int    = 0
        var activeSessionTitle: String = "—"

        var nsfwQuarantineCount: Int = 0
        var promptBlockedCount:  Int = 0

        var lastBackupAt:    Date? = nil
        var backupOK:        Bool  = false   // FIX: era isHealthy, ahora backupOK

        var gpuDeviceName:   String = "—"
        var gpuVRAMFreeMB:   Double = 0      // FIX: convertido de Int64 bytes

        var favoriteSeedCount: Int  = 0
        var topSeedUsed:     Int?   = nil
    }

    // MARK: - Refresh

    func refresh() {
        isRefreshing = true
        let store  = AssetStore.shared
        let assets = store.fetchAllAssets(limit: 500)   // FIX v2: era recentAssets(50)
        let now    = Date()
        let cal    = Calendar.current
        var snap   = DashboardSnapshot()

        // Asset counts
        snap.totalAssets     = assets.count
        snap.assetsToday     = assets.filter { cal.isDateInToday($0.createdAt ?? .distantPast) }.count
        snap.assetsLast7Days = assets.filter {
            ($0.createdAt ?? .distantPast) >= now.addingTimeInterval(-7 * 86400)
        }.count
        snap.assetsLast30Days = assets.filter {
            ($0.createdAt ?? .distantPast) >= now.addingTimeInterval(-30 * 86400)
        }.count

        // Quality
        snap.approvedAssets  = assets.filter { $0.statusEnum == .approved  }.count
        snap.rejectedAssets  = assets.filter { $0.statusEnum == .rejected  }.count
        snap.publishedAssets = assets.filter { $0.statusEnum == .published }.count
        snap.approvalRate    = assets.isEmpty ? 0 :
            Double(snap.approvedAssets) / Double(assets.count)

        let rated = assets.filter { $0.rating > 0 }
        snap.averageRating = rated.isEmpty ? 0 :
            Double(rated.map { Int($0.rating) }.reduce(0, +)) / Double(rated.count)
        for r in 0...5 {
            snap.ratingDistribution[r] = assets.filter { Int($0.rating) == r }.count
        }

        // Checkpoints
        var cpCounts: [String: Int] = [:]
        for a in assets {
            let cp = (a.checkpoint ?? "desconocido")
                .components(separatedBy: "/").last ?? "desconocido"
            cpCounts[cp, default: 0] += 1
        }
        snap.checkpointDistribution = cpCounts
            .sorted { $0.value > $1.value }
            .prefix(6)
            .map { (name: $0.key, count: $0.value) }

        // Prompts
        snap.topPromptVersions   = PromptVersioningStore.shared.topPrompts(count: 5)
        snap.totalPromptVersions = PromptVersioningStore.shared.versions.count

        // Sessions
        let sessions = ContentSessionManager.shared.sessions
        snap.totalSessions      = sessions.count
        snap.activeSessions     = sessions.filter { $0.isActive }.count
        snap.activeSessionTitle = ContentSessionManager.shared.activeSession?.title ?? "—"

        // Security
        snap.nsfwQuarantineCount = NSFWDetector.shared.log
            .filter { $0.action == .quarantine }.count
        snap.promptBlockedCount  = ZeroKnowledgeLog.shared
            .entries(category: .promptBlocked).count

        // Backup — FIX: usar config.lastBackupOK no isHealthy
        snap.lastBackupAt = BackupManager.shared.config.lastBackupAt
        snap.backupOK     = BackupManager.shared.config.lastBackupOK

        // GPU — FIX: vramFree es Int64 bytes, convertir a MB
        snap.gpuDeviceName = GPUMonitor.shared.deviceName
        let vramBytes      = GPUMonitor.shared.isAppleSilicon
            ? GPUMonitor.shared.ramFree
            : GPUMonitor.shared.vramFree
        snap.gpuVRAMFreeMB = Double(vramBytes) / 1_048_576.0

        // Seeds
        snap.favoriteSeedCount = SeedManager.shared.favorites.count
        snap.topSeedUsed       = SeedManager.shared.topSeeds(count: 1).first?.seed

        self.snapshot    = snap
        self.isRefreshing = false
    }
}

// MARK: - DashboardView

struct DashboardView: View {

    @StateObject private var vm  = DashboardViewModel.shared
    @StateObject private var gpu = GPUMonitor.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                header

                // Row 1 — Volumen
                HStack(spacing: 10) {
                    kpi("Total", "\(vm.snapshot.totalAssets)",
                        icon: "photo.stack", color: Color(hex: "#7c6af7"))
                    kpi("Hoy", "\(vm.snapshot.assetsToday)",
                        icon: "calendar", color: Color(hex: "#3de3c0"))
                    kpi("7d", "\(vm.snapshot.assetsLast7Days)",
                        icon: "chart.line.uptrend.xyaxis", color: .blue)
                    kpi("30d", "\(vm.snapshot.assetsLast30Days)",
                        icon: "chart.bar.fill", color: .orange)
                }
                .padding(.horizontal, 18)

                // Row 2 — Calidad
                HStack(spacing: 10) {
                    kpi("Aprobadas", "\(vm.snapshot.approvedAssets)",
                        sub: String(format: "%.0f%%", vm.snapshot.approvalRate * 100),
                        icon: "checkmark.circle.fill", color: Color(hex: "#34d399"))
                    kpi("Publicadas", "\(vm.snapshot.publishedAssets)",
                        icon: "arrow.up.circle.fill", color: Color(hex: "#60a5fa"))
                    kpi("Rating", String(format: "%.1f ★", vm.snapshot.averageRating),
                        icon: "star.fill", color: .yellow)
                    kpi("Rechazadas", "\(vm.snapshot.rejectedAssets)",
                        icon: "xmark.circle.fill", color: Color(hex: "#ef4444"))
                }
                .padding(.horizontal, 18)

                // Rating distribution
                ratingBarChart
                    .padding(.horizontal, 18)

                // Row 3 — Sesiones + Seeds
                HStack(spacing: 10) {
                    sessionCard; seedsCard
                }
                .padding(.horizontal, 18)

                // Checkpoint distribution
                if !vm.snapshot.checkpointDistribution.isEmpty {
                    checkpointCard.padding(.horizontal, 18)
                }

                // Row 4 — Seguridad + Backup
                HStack(spacing: 10) {
                    securityCard; backupCard
                }
                .padding(.horizontal, 18)

                // GPU card
                gpuCard.padding(.horizontal, 18)

                // Top prompts
                if !vm.snapshot.topPromptVersions.isEmpty {
                    topPromptsCard.padding(.horizontal, 18)
                }

                Spacer(minLength: 16)
            }
            .padding(.top, 14)
        }
        .background(Color(red: 0.08, green: 0.08, blue: 0.10))
        .onAppear { vm.refresh() }
    }

    // MARK: - Header

    var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Studio KPIs")
                    .font(.system(size: 15, weight: .bold)).foregroundColor(.white)
                Text("Actualizado \(Date().shortDisplay)")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
            Spacer()
            Button(action: { vm.refresh() }) {
                HStack(spacing: 4) {
                    if vm.isRefreshing {
                        ProgressView().scaleEffect(0.55).progressViewStyle(.circular)
                    } else {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11))
                    }
                    Text("Refresh").font(.system(size: 11))
                }
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
    }

    // MARK: - KPI Card

    func kpi(_ title: String, _ value: String, sub: String? = nil,
             icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10)).foregroundColor(color)
                Text(title).font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary).tracking(0.5).textCase(.uppercase)
            }
            Text(value).font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            if let s = sub {
                Text(s).font(.system(size: 9)).foregroundColor(.secondary)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04)).cornerRadius(9)
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(color.opacity(0.15), lineWidth: 1))
    }

    // MARK: - Rating Bar Chart

    var ratingBarChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rating Distribution")
                .font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                .tracking(0.8).textCase(.uppercase)
            HStack(spacing: 5) {
                ForEach(1...5, id: \.self) { star in
                    let count = vm.snapshot.ratingDistribution[star] ?? 0
                    let total = max(1, vm.snapshot.totalAssets)
                    VStack(spacing: 3) {
                        GeometryReader { geo in
                            VStack { Spacer()
                                Rectangle()
                                    .fill(starColor(star).opacity(0.7))
                                    .frame(height: geo.size.height * CGFloat(count) / CGFloat(total))
                            }
                        }
                        .frame(height: 36)
                        .background(Color.white.opacity(0.04)).cornerRadius(3)
                        Text("\(star)★").font(.system(size: 8)).foregroundColor(.secondary)
                        Text("\(count)").font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(12).background(Color.white.opacity(0.04)).cornerRadius(9)
    }

    func starColor(_ star: Int) -> Color {
        switch star {
        case 1: return Color(hex: "#ef4444")
        case 2: return Color(hex: "#f97316")
        case 3: return Color(hex: "#fbbf24")
        case 4: return Color(hex: "#84cc16")
        case 5: return Color(hex: "#34d399")
        default: return .yellow
        }
    }

    // MARK: - Session Card

    var sessionCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            cardLabel("Sesión Activa", icon: "camera.aperture", color: Color(hex: "#7c6af7"))
            Text(vm.snapshot.activeSessionTitle)
                .font(.system(size: 12, weight: .semibold)).foregroundColor(.white).lineLimit(1)
            HStack(spacing: 10) {
                Label("\(vm.snapshot.activeSessions) activas", systemImage: "circle.fill")
                    .font(.system(size: 9)).foregroundColor(Color(hex: "#34d399"))
                Label("\(vm.snapshot.totalSessions) total", systemImage: "archivebox")
                    .font(.system(size: 9)).foregroundColor(.secondary)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04)).cornerRadius(9)
    }

    // MARK: - Seeds Card

    var seedsCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            cardLabel("Seeds Favoritos", icon: "star.fill", color: .yellow)
            Text("\(vm.snapshot.favoriteSeedCount)")
                .font(.system(size: 20, weight: .bold, design: .rounded)).foregroundColor(.white)
            if let top = vm.snapshot.topSeedUsed {
                Text("Top: \(top)")
                    .font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04)).cornerRadius(9)
    }

    // MARK: - Checkpoint Card

    var checkpointCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            cardLabel("Checkpoints", icon: "cpu", color: Color(hex: "#7c6af7"))
            ForEach(vm.snapshot.checkpointDistribution, id: \.name) { item in
                let total = max(1, vm.snapshot.totalAssets)
                HStack(spacing: 8) {
                    Text(item.name.truncated(20))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.8))
                        .frame(width: 140, alignment: .leading)
                    GeometryReader { geo in
                        Rectangle()
                            .fill(Color(hex: "#7c6af7").opacity(0.5))
                            .frame(width: geo.size.width * CGFloat(item.count) / CGFloat(total))
                            .cornerRadius(2)
                    }
                    .frame(height: 6).background(Color.white.opacity(0.06)).cornerRadius(2)
                    Text("\(item.count)").font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary).frame(width: 28, alignment: .trailing)
                }
            }
        }
        .padding(12).background(Color.white.opacity(0.04)).cornerRadius(9)
    }

    // MARK: - Security Card

    var securityCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            cardLabel("Seguridad", icon: "lock.shield.fill", color: Color(hex: "#7c6af7"))
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(vm.snapshot.nsfwQuarantineCount)")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(vm.snapshot.nsfwQuarantineCount > 0 ? .orange : Color(hex: "#34d399"))
                    Text("NSFW qrnt.").font(.system(size: 9)).foregroundColor(.secondary)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(vm.snapshot.promptBlockedCount)")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(vm.snapshot.promptBlockedCount > 0 ? .red : Color(hex: "#34d399"))
                    Text("Bloqueados").font(.system(size: 9)).foregroundColor(.secondary)
                }
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04)).cornerRadius(9)
    }

    // MARK: - Backup Card

    var backupCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            // FIX: backupOK en lugar de backupIsHealthy
            cardLabel("Backup", icon: "externaldrive.badge.timemachine",
                      color: vm.snapshot.backupOK ? Color(hex: "#34d399") : .orange)
            HStack(spacing: 5) {
                Circle().fill(vm.snapshot.backupOK ? Color(hex: "#34d399") : .orange)
                    .frame(width: 6, height: 6)
                Text(vm.snapshot.backupOK ? "OK" : "Pendiente")
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
            }
            if let last = vm.snapshot.lastBackupAt {
                Text(last.shortDisplay).font(.system(size: 9)).foregroundColor(.secondary)
            } else {
                Text("Sin backup").font(.system(size: 9)).foregroundColor(.secondary)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04)).cornerRadius(9)
    }

    // MARK: - GPU Card
    // FIX: eliminados powerDraw/utilizationPercent (no existen en GPUMonitor)
    // Mostramos: deviceName, vramFreeMB, preCheckStatus

    var gpuCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "cpu.fill").font(.system(size: 16))
                .foregroundColor(Color(hex: "#3de3c0"))
                .frame(width: 36, height: 36)
                .background(Color(hex: "#3de3c0").opacity(0.1)).cornerRadius(7)

            VStack(alignment: .leading, spacing: 2) {
                Text(vm.snapshot.gpuDeviceName)
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                if vm.snapshot.gpuVRAMFreeMB > 0 {
                    Text(String(format: "%.0f MB libres", vm.snapshot.gpuVRAMFreeMB))
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }
            }
            Spacer()
            // PreCheck badge en tiempo real
            let status = gpu.preCheckStatus
            HStack(spacing: 4) {
                Image(systemName: status.icon).font(.system(size: 10))
                Text(status.message ?? "VRAM OK").font(.system(size: 10))
            }
            .foregroundColor(status.color)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(status.color.opacity(0.1)).cornerRadius(5)
        }
        .padding(12).background(Color.white.opacity(0.04)).cornerRadius(9)
    }

    // MARK: - Top Prompts Card

    var topPromptsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            cardLabel("Top Prompts", icon: "doc.text.magnifyingglass", color: Color(hex: "#7c6af7"))
            ForEach(vm.snapshot.topPromptVersions.prefix(5)) { v in
                HStack(spacing: 8) {
                    Text(v.label.truncated(26))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                    Spacer()
                    Text("×\(v.usageCount)")
                        .font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary)
                    if v.rating > 0 {
                        Text(String(repeating: "★", count: v.rating))
                            .font(.system(size: 8)).foregroundColor(.yellow)
                    }
                }
                .padding(.vertical, 2)
                if v.id != vm.snapshot.topPromptVersions.last?.id {
                    Divider().background(Color.white.opacity(0.05))
                }
            }
        }
        .padding(12).background(Color.white.opacity(0.04)).cornerRadius(9)
    }

    // MARK: - Helper

    func cardLabel(_ title: String, icon: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10)).foregroundColor(color)
            Text(title).font(.system(size: 9, weight: .semibold))
                .foregroundColor(.secondary).tracking(0.8).textCase(.uppercase)
        }
    }
}
