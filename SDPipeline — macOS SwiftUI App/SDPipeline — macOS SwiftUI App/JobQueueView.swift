import SwiftUI
import AppKit

// MARK: - JobQueueView v2

struct JobQueueView: View {

    @StateObject private var queue = JobQueueManager.shared

    @State private var selectedTab:    QueueTab   = .all
    @State private var searchText:     String     = ""
    @State private var expandedJobID:  UUID?      = nil
    @State private var showClearAlert: Bool       = false

    enum QueueTab: String, CaseIterable {
        case all        = "Todos"
        case running    = "Ejecutando"
        case queued     = "En Cola"
        case done       = "Completados"
        case failed     = "Fallidos"

        var icon: String {
            switch self {
            case .all:     return "list.bullet"
            case .running: return "play.circle.fill"
            case .queued:  return "clock.fill"
            case .done:    return "checkmark.circle.fill"
            case .failed:  return "exclamationmark.circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .all:     return Color.white.opacity(0.7)
            case .running: return Color(hex: "#f59e0b")
            case .queued:  return Color(hex: "#7c6af7")
            case .done:    return Color(hex: "#34d399")
            case .failed:  return Color(hex: "#ef4444")
            }
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider().background(Color.white.opacity(0.06))
            statsRow
            Divider().background(Color.white.opacity(0.06))
            etaBar
            Divider().background(Color.white.opacity(0.06))
            tabBar
            Divider().background(Color.white.opacity(0.06))
            searchBar
            Divider().background(Color.white.opacity(0.04))
            jobList
            Divider().background(Color.white.opacity(0.06))
            bottomBar
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
        .alert("Limpiar historial", isPresented: $showClearAlert) {
            Button("Limpiar", role: .destructive) { queue.clearHistory() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Se eliminarán todos los jobs completados, cancelados y fallidos.")
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "list.bullet.rectangle.portrait.fill")
                .font(.system(size: 13))
                .foregroundStyle(LinearGradient(
                    colors: [Color(hex: "#7c6af7"), Color(hex: "#3de3c0")],
                    startPoint: .topLeading, endPoint: .bottomTrailing))

            Text("Cola de Trabajos")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)

            Spacer()

            // Workers control
            HStack(spacing: 4) {
                Text("Workers:")
                    .font(.system(size: 9)).foregroundColor(.secondary)
                Stepper("", value: $queue.maxConcurrent, in: 1...4)
                    .labelsHidden().scaleEffect(0.65).frame(width: 52)
                Text("\(queue.maxConcurrent)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(hex: "#7c6af7"))
                    .frame(width: 14)
            }

            Divider().frame(height: 14).background(Color.white.opacity(0.1))

            // Play / Pause
            Button(action: {
                queue.isProcessing ? queue.pauseQueue() : queue.startQueue()
            }) {
                HStack(spacing: 4) {
                    Image(systemName: queue.isProcessing ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(queue.isProcessing ? Color(hex: "#f59e0b") : Color(hex: "#34d399"))
                    Text(queue.isProcessing ? "Pausar" : "Reanudar")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)
            .help(queue.isProcessing ? "Pausar procesamiento" : "Reanudar procesamiento")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.white.opacity(0.03))
    }

    // MARK: - Stats Row

    private var statsRow: some View {
        HStack(spacing: 0) {
            statCell("\(queue.totalQueued)",    "En cola",     "#7c6af7")
            Divider().frame(height: 30).background(Color.white.opacity(0.08))
            statCell("\(queue.runningJobs.count)", "Corriendo",  "#f59e0b")
            Divider().frame(height: 30).background(Color.white.opacity(0.08))
            statCell("\(queue.totalCompleted)", "Completados", "#34d399")
            Divider().frame(height: 30).background(Color.white.opacity(0.08))
            statCell("\(queue.totalFailed)",    "Fallidos",    "#ef4444")
        }
        .padding(.vertical, 6)
    }

    private func statCell(_ value: String, _ label: String, _ hex: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundColor(Color(hex: hex))
            Text(label)
                .font(.system(size: 9)).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - ETA Bar

    private var etaBar: some View {
        HStack(spacing: 10) {
            // Global progress
            let total    = queue.jobs.count
            let done     = queue.completedJobs.count
            let progress = total > 0 ? Double(done) / Double(total) : 0.0

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.06))
                        .frame(height: 4)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LinearGradient(
                            colors: [Color(hex: "#7c6af7"), Color(hex: "#3de3c0")],
                            startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * progress, height: 4)
                        .animation(.easeInOut(duration: 0.4), value: progress)
                }
            }
            .frame(height: 4)

            Text("\(Int(progress * 100))%")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 28)

            Divider().frame(height: 10).background(Color.white.opacity(0.1))

            HStack(spacing: 4) {
                Image(systemName: "clock").font(.system(size: 9)).foregroundColor(.secondary)
                Text("ETA: \(queue.estimatedRemainingLabel)")
                    .font(.system(size: 9)).foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(QueueTab.allCases, id: \.self) { tab in
                    tabButton(tab)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
    }

    private func tabButton(_ tab: QueueTab) -> some View {
        let isSelected = selectedTab == tab
        let count = tabCount(tab)
        return Button(action: { withAnimation(.spring(response: 0.2)) { selectedTab = tab } }) {
            HStack(spacing: 4) {
                Image(systemName: tab.icon).font(.system(size: 10))
                Text(tab.rawValue).font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(isSelected ? .white : .secondary)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(tab.color.opacity(isSelected ? 0.5 : 0.2))
                        .cornerRadius(4)
                }
            }
            .foregroundColor(isSelected ? tab.color : .secondary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(isSelected ? tab.color.opacity(0.12) : Color.clear)
            .cornerRadius(7)
        }
        .buttonStyle(.plain)
    }

    private func tabCount(_ tab: QueueTab) -> Int {
        switch tab {
        case .all:     return queue.jobs.count
        case .running: return queue.runningJobs.count
        case .queued:  return queue.totalQueued
        case .done:    return queue.totalCompleted
        case .failed:  return queue.totalFailed
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundColor(.secondary)
            TextField("Buscar por nombre…", text: $searchText)
                .textFieldStyle(.plain).font(.system(size: 11)).foregroundColor(.white)
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Color.white.opacity(0.03))
    }

    // MARK: - Job List

    private var jobList: some View {
        let filtered = filteredJobs
        return Group {
            if filtered.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        // Batch groups
                        let grouped = groupByBatch(filtered)
                        ForEach(grouped, id: \.id) { group in
                            if let batchID = group.batchID, group.jobs.count > 1 {
                                batchGroupView(batchID: batchID, jobs: group.jobs)
                            } else {
                                ForEach(group.jobs) { job in
                                    jobRow(job)
                                    if job.id != group.jobs.last?.id {
                                        Divider().background(Color.white.opacity(0.04))
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray.fill")
                .font(.system(size: 32)).foregroundColor(.white.opacity(0.08))
            // ¡AQUÍ ESTABA EL BUG DE LAS COMILLAS! Solucionado:
            Text(searchText.isEmpty ? "No hay trabajos en esta vista" : "Sin resultados para \"\(searchText)\"")
                .font(.system(size: 12)).foregroundColor(.secondary)
            if selectedTab == .failed {
                Button("Ver todos los jobs") { selectedTab = .all; searchText = "" }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#7c6af7"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filteredJobs: [JobQueueManager.GenerationJob] {
        var jobs: [JobQueueManager.GenerationJob]
        switch selectedTab {
        case .all:     jobs = queue.jobs
        case .running: jobs = queue.runningJobs
        case .queued:  jobs = queue.queuedJobs
        case .done:    jobs = queue.completedJobs
        case .failed:  jobs = queue.failedJobs
        }
        if !searchText.isEmpty {
            jobs = jobs.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
        return jobs.sorted { a, b in
            // Running first, then queued by priority, then done/failed by date
            if a.status == .running && b.status != .running { return true }
            if b.status == .running && a.status != .running { return false }
            return a.createdAt > b.createdAt
        }
    }

    // MARK: - Batch Group

    struct JobGroup: Identifiable {
        var id: String { batchID?.uuidString ?? jobs.first?.id.uuidString ?? UUID().uuidString }
        let batchID: UUID?
        var jobs: [JobQueueManager.GenerationJob]
    }

    private func groupByBatch(_ jobs: [JobQueueManager.GenerationJob]) -> [JobGroup] {
        var groups: [String: JobGroup] = [:]
        var order:  [String] = []
        for job in jobs {
            let key = job.batchID?.uuidString ?? job.id.uuidString
            if groups[key] == nil {
                groups[key] = JobGroup(batchID: job.batchID, jobs: [])
                order.append(key)
            }
            groups[key]!.jobs.append(job)
        }
        return order.compactMap { groups[$0] }
    }

    @ViewBuilder
    private func batchGroupView(batchID: UUID, jobs: [JobQueueManager.GenerationJob]) -> some View {
        let doneCount    = jobs.filter { $0.status == .done }.count
        let failedCount  = jobs.filter { $0.status == .failed }.count
        let runningCount = jobs.filter { $0.status == .running }.count

        DisclosureGroup {
            ForEach(jobs) { job in
                jobRow(job).padding(.leading, 16)
                Divider().background(Color.white.opacity(0.04)).padding(.leading, 16)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.stack.fill")
                    .font(.system(size: 11)).foregroundColor(Color(hex: "#7c6af7"))
                Text("Batch · \(jobs.count) jobs")
                    .font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
                Spacer()
                HStack(spacing: 6) {
                    if runningCount > 0 { badge("\(runningCount)", "#f59e0b") }
                    if doneCount    > 0 { badge("\(doneCount)",    "#34d399") }
                    if failedCount  > 0 { badge("\(failedCount)",  "#ef4444") }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .padding(.horizontal, 4)
        .background(Color.white.opacity(0.03))
        .cornerRadius(7)
        .padding(.horizontal, 4)
    }

    private func badge(_ text: String, _ hex: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Color(hex: hex).opacity(0.5))
            .cornerRadius(4)
    }

    // MARK: - Job Row

    @ViewBuilder
    private func jobRow(_ job: JobQueueManager.GenerationJob) -> some View {
        let isExpanded = expandedJobID == job.id
        VStack(spacing: 0) {
            // Main row
            HStack(spacing: 10) {
                // Priority indicator
                Rectangle()
                    .fill(priorityColor(job.priority))
                    .frame(width: 3)
                    .cornerRadius(2)

                // Status icon
                statusIcon(job)

                // Info
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.name)
                        .font(.system(size: 11, weight: .medium)).foregroundColor(.white).lineLimit(1)
                    HStack(spacing: 6) {
                        priorityBadge(job.priority)
                        Text(job.durationLabel)
                            .font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary)
                        if let session = job.sessionTag {
                            Text("·").foregroundColor(.secondary).font(.system(size: 9))
                            Text(session).font(.system(size: 9)).foregroundColor(Color(hex: "#7c6af7")).lineLimit(1)
                        }
                    }
                }

                Spacer()

                // Action buttons
                HStack(spacing: 8) {
                    switch job.status {
                    case .running:
                        Button(action: { queue.cancel(jobID: job.id) }) {
                            Image(systemName: "stop.fill").font(.system(size: 11))
                                .foregroundColor(Color(hex: "#ef4444"))
                        }
                        .buttonStyle(.plain).help("Cancelar job")

                    case .failed:
                        Button(action: { queue.retry(jobID: job.id) }) {
                            Image(systemName: "arrow.counterclockwise").font(.system(size: 11))
                                .foregroundColor(Color(hex: "#f59e0b"))
                        }
                        .buttonStyle(.plain).help("Reintentar")

                    case .queued:
                        Button(action: { queue.cancel(jobID: job.id) }) {
                            Image(systemName: "xmark").font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain).help("Quitar de la cola")

                    default: EmptyView()
                    }

                    // Expand toggle
                    Button(action: {
                        withAnimation(.spring(response: 0.2)) {
                            expandedJobID = isExpanded ? nil : job.id
                        }
                    }) {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9)).foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(
                job.status == .running
                    ? Color(hex: "#f59e0b").opacity(0.06)
                    : Color.white.opacity(0.02)
            )

            // Expandable detail
            if isExpanded {
                jobDetail(job)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .cornerRadius(6)
    }

    // MARK: - Job Detail (expandable)

    @ViewBuilder
    private func jobDetail(_ job: JobQueueManager.GenerationJob) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().background(Color.white.opacity(0.06))

            // Prompt preview
            if !job.request.prompt.isEmpty {
                detailRow(icon: "text.bubble", label: "Prompt") {
                    Text(job.request.prompt.prefix(200) + (job.request.prompt.count > 200 ? "…" : ""))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }

            // Generation params
            detailRow(icon: "slider.horizontal.3", label: "Params") {
                HStack(spacing: 10) {
                    paramChip("Steps", "\(job.request.steps)")
                    paramChip("CFG",   String(format: "%.1f", job.request.cfg_scale))
                    paramChip("Size",  "\(job.request.width)×\(job.request.height)")
                    if job.request.seed != -1 {
                        paramChip("Seed", "\(job.request.seed)")
                    }
                    paramChip("Sampler", job.request.sampler_name)
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            // Error log
            if !job.errorLog.isEmpty {
                detailRow(icon: "exclamationmark.triangle", label: "Errores") {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(job.errorLog.suffix(3), id: \.self) { err in
                            Text("· \(err)")
                                .font(.system(size: 9)).foregroundColor(Color(hex: "#ef4444"))
                        }
                    }
                }
            }

            // Timing
            if let started = job.startedAt {
                detailRow(icon: "clock", label: "Timing") {
                    HStack(spacing: 10) {
                        paramChip("Inicio", started.formatted(date: .omitted, time: .shortened))
                        if let finished = job.finishedAt {
                            paramChip("Fin", finished.formatted(date: .omitted, time: .shortened))
                            let dur = Int(finished.timeIntervalSince(started))
                            paramChip("Duración", "\(dur)s")
                        }
                        paramChip("Intentos", "\(job.attempts)")
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color.white.opacity(0.025))
    }

    private func detailRow<Content: View>(icon: String, label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).font(.system(size: 9)).foregroundColor(.secondary).frame(width: 12)
            VStack(alignment: .leading, spacing: 4) {
                Text(label.uppercased())
                    .font(.system(size: 8, weight: .semibold)).foregroundColor(.secondary).tracking(0.8)
                content()
            }
        }
    }

    private func paramChip(_ label: String, _ value: String) -> some View {
        VStack(spacing: 1) {
            Text(label).font(.system(size: 7)).foregroundColor(.secondary)
            Text(value).font(.system(size: 9, weight: .medium)).foregroundColor(.white)
        }
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(Color.white.opacity(0.05))
        .cornerRadius(5)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 8) {
            // Retry all failed
            if queue.totalFailed > 0 {
                Button(action: {
                    queue.failedJobs.forEach { queue.retry(jobID: $0.id) }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.counterclockwise").font(.system(size: 10))
                        Text("Reintentar todos (\(queue.totalFailed))")
                            .font(.system(size: 10))
                    }
                    .foregroundColor(Color(hex: "#f59e0b"))
                }
                .buttonStyle(.plain)
            }

            // Cancel all queued
            if queue.totalQueued > 0 {
                Button(action: { queue.cancelAllQueued() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle").font(.system(size: 10))
                        Text("Cancelar cola (\(queue.totalQueued))")
                            .font(.system(size: 10))
                    }
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            Text("\(queue.jobs.count) jobs totales")
                .font(.system(size: 9)).foregroundColor(Color.secondary.opacity(0.6))

            Divider().frame(height: 14).background(Color.white.opacity(0.1))

            Button(action: { showClearAlert = true }) {
                HStack(spacing: 4) {
                    Image(systemName: "trash").font(.system(size: 10))
                    Text("Limpiar historial").font(.system(size: 10))
                }
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.white.opacity(0.02))
    }

    // MARK: - Helpers

    private func statusIcon(_ job: JobQueueManager.GenerationJob) -> some View {
        Group {
            switch job.status {
            case .running:
                ProgressView().scaleEffect(0.55).frame(width: 16, height: 16)
            default:
                Image(systemName: job.statusIcon)
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: job.status.hexColor))
                    .frame(width: 16)
            }
        }
    }

    private func priorityColor(_ priority: JobQueueManager.JobPriority) -> Color {
        switch priority {
        case .low:      return Color.white.opacity(0.2)
        case .normal:   return Color(hex: "#7c6af7").opacity(0.6)
        case .high:     return Color(hex: "#f59e0b").opacity(0.8)
        }
    }

    private func priorityBadge(_ priority: JobQueueManager.JobPriority) -> some View {
        HStack(spacing: 3) {
            Image(systemName: priority.icon).font(.system(size: 7))
            Text(priority.label).font(.system(size: 8))
        }
        .foregroundColor(priorityColor(priority))
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(priorityColor(priority).opacity(0.15))
        .cornerRadius(4)
    }
}

// durationLabel is defined in JobQueueManager.swift
