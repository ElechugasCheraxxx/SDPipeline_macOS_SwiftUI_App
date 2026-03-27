import SwiftUI
import Combine

// MARK: - DashboardViewModel
//
// v2 FIXES:
//   - refresh() usa fetchAllAssets(limit:500) en lugar de recentAssets (solo 50)
//   - Checkpoint distribution real desde Core Data
//   - Session stats integradas desde ContentSessionManager
//   - GPU device name desde GPUMonitor
//   - Backup status desde BackupManager

@MainActor
final class DashboardViewModel: ObservableObject {

    static let shared = DashboardViewModel()
    private init() {}

    @Published var snapshot:     DashboardSnapshot = DashboardSnapshot()
    @Published var isRefreshing: Bool = false

    // MARK: - Snapshot

    struct DashboardSnapshot {
        // Generaciones
        var totalAssets:       Int    = 0
        var assetsToday:       Int    = 0
        var assetsLast7Days:   Int    = 0
        var assetsLast30Days:  Int    = 0

        // Calidad
        var approvedAssets:    Int    = 0
        var rejectedAssets:    Int    = 0
        var publishedAssets:   Int    = 0
        var approvalRate:      Double = 0
        var averageRating:     Double = 0
        var ratingDistribution: [Int: Int] = [:]

        // Prompts
        var topPromptVersions:   [PromptVersioningStore.PromptVersion] = []
        var totalPromptVersions: Int = 0

        // Checkpoints
        var checkpointDistribution: [(name: String, count: Int)] = []

        // Sesiones
        var activeSessions:      Int = 0
        var totalSessions:       Int = 0
        var activeSessionTitle:  String = "—"

        // Seguridad
        var nsfwQuarantineCount: Int = 0
        var promptBlockedCount:  Int = 0

        // Backup
        var lastBackupAt:        Date? = nil
        var backupIsHealthy:     Bool  = false

        // GPU
        var gpuDeviceName:       String = "—"
        var gpuVRAMFree:         Double = 0

        // Seeds
        var favoriteSeedCount:   Int = 0
        var topSeedUsed:         Int? = nil
    }

    // MARK: - Refresh

    func refresh() {
        isRefreshing = true
        let store  = AssetStore.shared
        // FIX v2: usar fetchAllAssets (500) en lugar de recentAssets (50)
        let assets = store.fetchAllAssets(limit: 500)
        let now    = Date()
        let cal    = Calendar.current

        var snap = DashboardSnapshot()

        // ── Asset counts ────────────────────────────────────────────────
        snap.totalAssets = assets.count
        snap.assetsToday = assets.filter {
            cal.isDateInToday($0.createdAt ?? .distantPast)
        }.count
        snap.assetsLast7Days = assets.filter {
            ($0.createdAt ?? .distantPast) >= now.addingTimeInterval(-7 * 86400)
        }.count
        snap.assetsLast30Days = assets.filter {
            ($0.createdAt ?? .distantPast) >= now.addingTimeInterval(-30 * 86400)
        }.count

        // ── Quality ──────────────────────────────────────────────────────
        let approved  = assets.filter { $0.statusEnum == .approved }
        let rejected  = assets.filter { $0.statusEnum == .rejected }
        let published = assets.filter { $0.statusEnum == .published }
        snap.approvedAssets  = approved.count
        snap.rejectedAssets  = rejected.count
        snap.publishedAssets = published.count
        snap.approvalRate    = assets.isEmpty ? 0 : Double(approved.count) / Double(assets.count)

        let rated = assets.filter { $0.rating > 0 }
        snap.averageRating = rated.isEmpty ? 0 :
            Double(rated.map { Int($0.rating) }.reduce(0, +)) / Double(rated.count)

        for r in 0...5 {
            snap.ratingDistribution[r] = assets.filter { Int($0.rating) == r }.count
        }

        // ── Checkpoints ──────────────────────────────────────────────────
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

        // ── Prompts ──────────────────────────────────────────────────────
        snap.topPromptVersions   = PromptVersioningStore.shared.topPrompts(count: 5)
        snap.totalPromptVersions = PromptVersioningStore.shared.versions.count

        // ── Sessions ─────────────────────────────────────────────────────
        let sessions = ContentSessionManager.shared.sessions
        snap.totalSessions   = sessions.count
        snap.activeSessions  = sessions.filter { $0.isActive }.count
        snap.activeSessionTitle = ContentSessionManager.shared.activeSession?.title ?? "—"

        // ── Security ─────────────────────────────────────────────────────
        snap.nsfwQuarantineCount = NSFWDetector.shared.log
            .filter { $0.action == .quarantine }.count
        snap.promptBlockedCount  = ZeroKnowledgeLog.shared
            .entries(category: .promptBlocked).count

        // ── Backup ───────────────────────────────────────────────────────
        snap.lastBackupAt    = BackupManager.shared.lastBackupAt
        snap.backupIsHealthy = BackupManager.shared.isHealthy

        // ── GPU ──────────────────────────────────────────────────────────
        snap.gpuDeviceName = GPUMonitor.shared.deviceName
        snap.gpuVRAMFree   = GPUMonitor.shared.vramFreeMB

        // ── Seeds ────────────────────────────────────────────────────────
        snap.favoriteSeedCount = SeedManager.shared.favorites.count
        snap.topSeedUsed       = SeedManager.shared.topSeeds(count: 1).first?.seed

        self.snapshot    = snap
        self.isRefreshing = false
    }
}

// MARK: - DashboardView

struct DashboardView: View {

    @StateObject private var vm = DashboardViewModel.shared
    @StateObject private var gpu = GPUMonitor.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Studio KPIs")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                        Text("Actualizado \(Date().shortDisplay)")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: { vm.refresh() }) {
                        HStack(spacing: 4) {
                            if vm.isRefreshing {
                                ProgressView().scaleEffect(0.6).progressViewStyle(.circular)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 11))
                            }
                            Text("Refresh")
                                .font(.system(size: 11))
                        }
                        .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                // ── Fila 1: Generaciones ────────────────────────────────
                HStack(spacing: 12) {
                    kpiCard("Total", value: "\(vm.snapshot.totalAssets)",
                            icon: "photo.stack", color: Color(hex: "#7c6af7"))
                    kpiCard("Hoy", value: "\(vm.snapshot.assetsToday)",
                            icon: "calendar", color: Color(hex: "#3de3c0"))
                    kpiCard("7 días", value: "\(vm.snapshot.assetsLast7Days)",
                            icon: "chart.line.uptrend.xyaxis", color: .blue)
                    kpiCard("30 días", value: "\(vm.snapshot.assetsLast30Days)",
                            icon: "chart.bar.fill", color: .orange)
                }
                .padding(.horizontal, 20)

                // ── Fila 2: Calidad ─────────────────────────────────────
                HStack(spacing: 12) {
                    kpiCard("Aprobadas",
                            value: "\(vm.snapshot.approvedAssets)",
                            subtitle: approvalRateStr,
                            icon: "checkmark.circle.fill",
                            color: Color(hex: "#34d399"))
                    kpiCard("Publicadas",
                            value: "\(vm.snapshot.publishedAssets)",
                            icon: "arrow.up.circle.fill",
                            color: Color(hex: "#60a5fa"))
                    kpiCard("Rating Prom.",
                            value: String(format: "%.1f ★", vm.snapshot.averageRating),
                            icon: "star.fill",
                            color: .yellow)
                    kpiCard("Rechazadas",
                            value: "\(vm.snapshot.rejectedAssets)",
                            icon: "xmark.circle.fill",
                            color: Color(hex: "#ef4444"))
                }
                .padding(.horizontal, 20)

                // ── Rating Distribution ─────────────────────────────────
                ratingBar
                    .padding(.horizontal, 20)

                // ── Fila 3: Sesión + Seeds ──────────────────────────────
                HStack(spacing: 12) {
                    sessionCard
                    seedsCard
                }
                .padding(.horizontal, 20)

                // ── Checkpoint distribution ─────────────────────────────
                if !vm.snapshot.checkpointDistribution.isEmpty {
                    checkpointCard
                        .padding(.horizontal, 20)
                }

                // ── Seguridad + Backup ──────────────────────────────────
                HStack(spacing: 12) {
                    securityCard
                    backupCard
                }
                .padding(.horizontal, 20)

                // ── GPU ─────────────────────────────────────────────────
                gpuCard
                    .padding(.horizontal, 20)

                // ── Top prompts ─────────────────────────────────────────
                if !vm.snapshot.topPromptVersions.isEmpty {
                    topPromptsCard
                        .padding(.horizontal, 20)
                }

                Spacer(minLength: 20)
            }
        }
        .background(Color(red: 0.08, green: 0.08, blue: 0.10))
        .onAppear { vm.refresh() }
    }

    // MARK: - KPI Card

    func kpiCard(
        _ title: String,
        value: String,
        subtitle: String? = nil,
        icon: String,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundColor(color)
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                    .tracking(0.5)
                    .textCase(.uppercase)
            }
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            if let sub = subtitle {
                Text(sub)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(color.opacity(0.15), lineWidth: 1))
    }

    var approvalRateStr: String {
        String(format: "%.0f%% del total", vm.snapshot.approvalRate * 100)
    }

    // MARK: - Rating Bar

    var ratingBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Distribución de Rating")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .tracking(0.5)
                .textCase(.uppercase)

            HStack(spacing: 6) {
                ForEach(1...5, id: \.self) { star in
                    let count = vm.snapshot.ratingDistribution[star] ?? 0
                    let total = max(1, vm.snapshot.totalAssets)
                    VStack(spacing: 4) {
                        GeometryReader { geo in
                            VStack {
                                Spacer()
                                Rectangle()
                                    .fill(Color.yellow.opacity(0.6 + 0.08 * Double(star)))
                                    .frame(height: geo.size.height * CGFloat(count) / CGFloat(total))
                            }
                        }
                        .frame(height: 40)
                        .background(Color.white.opacity(0.04))
                        .cornerRadius(4)

                        Text("\(star)★")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                        Text("\(count)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.04))
        .cornerRadius(10)
    }

    // MARK: - Session Card

    var sessionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "camera.aperture")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#7c6af7"))
                Text("Sesión Activa")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                    .tracking(0.5)
                    .textCase(.uppercase)
            }
            Text(vm.snapshot.activeSessionTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
            HStack(spacing: 12) {
                Label("\(vm.snapshot.activeSessions) activas",
                      systemImage: "circle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "#34d399"))
                Label("\(vm.snapshot.totalSessions) total",
                      systemImage: "archivebox")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04))
        .cornerRadius(10)
    }

    // MARK: - Seeds Card

    var seedsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "star.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.yellow)
                Text("Seeds")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                    .tracking(0.5)
                    .textCase(.uppercase)
            }
            Text("\(vm.snapshot.favoriteSeedCount) favoritos")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
            if let top = vm.snapshot.topSeedUsed {
                Text("Top: \(top)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04))
        .cornerRadius(10)
    }

    // MARK: - Checkpoint Distribution

    var checkpointCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Checkpoints Usados")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .tracking(0.5)
                .textCase(.uppercase)

            ForEach(vm.snapshot.checkpointDistribution, id: \.name) { item in
                let total = max(1, vm.snapshot.totalAssets)
                HStack(spacing: 8) {
                    Text(item.name.truncated(22))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.85))
                        .frame(width: 150, alignment: .leading)
                    GeometryReader { geo in
                        Rectangle()
                            .fill(Color(hex: "#7c6af7").opacity(0.5))
                            .frame(width: geo.size.width * CGFloat(item.count) / CGFloat(total))
                            .cornerRadius(3)
                    }
                    .frame(height: 8)
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(3)
                    Text("\(item.count)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 30, alignment: .trailing)
                }
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.04))
        .cornerRadius(10)
    }

    // MARK: - Security Card

    var securityCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#7c6af7"))
                Text("Seguridad")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                    .tracking(0.5)
                    .textCase(.uppercase)
            }
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(vm.snapshot.nsfwQuarantineCount)")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(vm.snapshot.nsfwQuarantineCount > 0 ? .orange : Color(hex: "#34d399"))
                    Text("NSFW cuarentena")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(vm.snapshot.promptBlockedCount)")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(vm.snapshot.promptBlockedCount > 0 ? .red : Color(hex: "#34d399"))
                    Text("Prompts bloqueados")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04))
        .cornerRadius(10)
    }

    // MARK: - Backup Card

    var backupCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "externaldrive.badge.timemachine")
                    .font(.system(size: 11))
                    .foregroundColor(vm.snapshot.backupIsHealthy ? Color(hex: "#34d399") : .orange)
                Text("Backup")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                    .tracking(0.5)
                    .textCase(.uppercase)
            }
            HStack(spacing: 6) {
                Circle()
                    .fill(vm.snapshot.backupIsHealthy ? Color(hex: "#34d399") : .orange)
                    .frame(width: 7, height: 7)
                Text(vm.snapshot.backupIsHealthy ? "Saludable" : "Pendiente")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
            }
            if let last = vm.snapshot.lastBackupAt {
                Text("Último: \(last.shortDisplay)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            } else {
                Text("Sin backup registrado")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04))
        .cornerRadius(10)
    }

    // MARK: - GPU Card

    var gpuCard: some View {
        HStack(spacing: 16) {
            Image(systemName: "cpu.fill")
                .font(.system(size: 18))
                .foregroundColor(Color(hex: "#3de3c0"))
                .frame(width: 40, height: 40)
                .background(Color(hex: "#3de3c0").opacity(0.1))
                .cornerRadius(8)

            VStack(alignment: .leading, spacing: 2) {
                Text(vm.snapshot.gpuDeviceName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                if vm.snapshot.gpuVRAMFree > 0 {
                    Text(String(format: "VRAM libre: %.0f MB", vm.snapshot.gpuVRAMFree))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            Spacer()

            // Telemetría en tiempo real
            VStack(alignment: .trailing, spacing: 2) {
                Text(gpu.utilizationPercent > 0
                     ? String(format: "GPU %.0f%%", gpu.utilizationPercent)
                     : "GPU —")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(gpu.utilizationPercent > 80 ? .orange : .secondary)
                Text(gpu.powerDraw > 0
                     ? String(format: "%.0f W", gpu.powerDraw)
                     : "— W")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.04))
        .cornerRadius(10)
    }

    // MARK: - Top Prompts Card

    var topPromptsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#7c6af7"))
                Text("Top Prompts Usados")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .tracking(0.5)
                    .textCase(.uppercase)
            }
            ForEach(vm.snapshot.topPromptVersions.prefix(5)) { version in
                HStack(spacing: 8) {
                    Text(version.label.truncated(28))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                    Spacer()
                    Text("×\(version.usageCount)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                    if version.rating > 0 {
                        HStack(spacing: 1) {
                            ForEach(0..<version.rating, id: \.self) { _ in
                                Image(systemName: "star.fill")
                                    .font(.system(size: 7))
                                    .foregroundColor(.yellow)
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
                if version.id != vm.snapshot.topPromptVersions.last?.id {
                    Divider().background(Color.white.opacity(0.05))
                }
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.04))
        .cornerRadius(10)
    }
}
