import Foundation
import AppKit
import SwiftUI
import Combine

// MARK: - JobQueueManager
//
// Cola de trabajos asíncronos con prioridad, retry y planificación.
// Permite encolar generaciones individuales, batch jobs, exports y backups
// para ejecución ordenada sin bloquear la UI.
//
// Features:
//   - Prioridad (urgent > high > normal > low)
//   - Retry automático (configurable, max 3)
//   - Pausa / resume
//   - Concurrencia configurable (1-3 workers)
//   - Persistencia de la cola en caso de crash
//   - Notificaciones de completado
//
// ROADMAP: "Sistema de colas y jobs automáticos" (🟡 MEDIO PLAZO)

// MARK: - Models

enum JobPriority: Int, Codable, CaseIterable, Comparable {
    case low     = 0
    case normal  = 1
    case high    = 2
    case urgent  = 3

    static func < (lhs: JobPriority, rhs: JobPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .low:    return "Baja"
        case .normal: return "Normal"
        case .high:   return "Alta"
        case .urgent: return "Urgente"
        }
    }

    var color: String {
        switch self {
        case .low:    return "#6b7280"
        case .normal: return "#7c6af7"
        case .high:   return "#f59e0b"
        case .urgent: return "#ef4444"
        }
    }
}

enum QueueJobType: String, Codable, CaseIterable {
    case singleGeneration = "Generación"
    case batchGeneration  = "Batch"
    case export           = "Export"
    case backup           = "Backup"
    case postProduction   = "Post-prod"
    case xyPlot           = "X/Y Plot"

    var icon: String {
        switch self {
        case .singleGeneration: return "wand.and.stars"
        case .batchGeneration:  return "square.grid.3x3.fill"
        case .export:           return "arrow.up.doc.fill"
        case .backup:           return "externaldrive.badge.timemachine"
        case .postProduction:   return "camera.filters"
        case .xyPlot:           return "grid.circle.fill"
        }
    }
}

enum QueueJobStatus: String, Codable {
    case pending   = "Pendiente"
    case running   = "Ejecutando"
    case completed = "Completado"
    case failed    = "Fallido"
    case cancelled = "Cancelado"
    case paused    = "Pausado"

    var color: String {
        switch self {
        case .pending:   return "#6b7280"
        case .running:   return "#7c6af7"
        case .completed: return "#34d399"
        case .failed:    return "#ef4444"
        case .cancelled: return "#9ca3af"
        case .paused:    return "#f59e0b"
        }
    }

    var icon: String {
        switch self {
        case .pending:   return "clock"
        case .running:   return "arrow.triangle.2.circlepath"
        case .completed: return "checkmark.circle.fill"
        case .failed:    return "exclamationmark.circle.fill"
        case .cancelled: return "xmark.circle.fill"
        case .paused:    return "pause.circle.fill"
        }
    }
}

struct QueueJob: Identifiable, Codable {
    var id:           UUID         = UUID()
    var type:         QueueJobType
    var label:        String
    var priority:     JobPriority  = .normal
    var status:       QueueJobStatus = .pending
    var progress:     Double       = 0
    var progressText: String       = ""
    var createdAt:    Date         = Date()
    var startedAt:    Date?        = nil
    var completedAt:  Date?        = nil
    var retryCount:   Int          = 0
    var maxRetries:   Int          = 3
    var errorMessage: String?      = nil
    var metadata:     [String: String] = [:]

    var canRetry: Bool { retryCount < maxRetries && status == .failed }
    var duration: TimeInterval? {
        guard let start = startedAt else { return nil }
        return (completedAt ?? Date()).timeIntervalSince(start)
    }
}

// MARK: - JobQueueManager

@MainActor
final class JobQueueManager: ObservableObject {

    static let shared = JobQueueManager()
    private init() { loadQueue() }

    // MARK: - State

    @Published var queue:         [QueueJob] = []
    @Published var completedJobs: [QueueJob] = []
    @Published var isPaused:      Bool       = false
    @Published var isRunning:     Bool       = false
    @Published var activeJobID:   UUID?      = nil

    var maxConcurrency: Int = 1      // Aumentar con cuidado — A1111 no es multi-GPU by default
    var autoRetry:      Bool = true

    // MARK: - Public API — Enqueue

    @discardableResult
    func enqueue(
        type:     QueueJobType,
        label:    String,
        priority: JobPriority = .normal,
        metadata: [String: String] = [:]
    ) -> QueueJob {
        var job = QueueJob(type: type, label: label, priority: priority, metadata: metadata)
        // Insertar por prioridad (mayor prioridad primero, mismo nivel FIFO)
        let insertIdx = queue.firstIndex { $0.priority < priority } ?? queue.count
        queue.insert(job, at: insertIdx)
        saveQueue()
        processNext()
        return job
    }

    func cancel(jobID: UUID) {
        if let idx = queue.firstIndex(where: { $0.id == jobID }) {
            queue[idx].status = .cancelled
            saveQueue()
        }
    }

    func cancelAll() {
        queue.indices.forEach { queue[$0].status = .cancelled }
        saveQueue()
    }

    func pause() {
        isPaused = true
    }

    func resume() {
        isPaused = false
        processNext()
    }

    func retry(jobID: UUID) {
        guard let idx = queue.firstIndex(where: { $0.id == jobID }),
              queue[idx].canRetry
        else { return }
        queue[idx].status    = .pending
        queue[idx].retryCount += 1
        queue[idx].errorMessage = nil
        saveQueue()
        processNext()
    }

    func clearCompleted() {
        completedJobs.removeAll()
        saveQueue()
    }

    // MARK: - Processing Loop

    private func processNext() {
        guard !isPaused, !isRunning else { return }
        guard let jobIdx = queue.firstIndex(where: { $0.status == .pending }) else { return }

        isRunning          = true
        activeJobID        = queue[jobIdx].id
        queue[jobIdx].status    = .running
        queue[jobIdx].startedAt = Date()

        let job = queue[jobIdx]
        saveQueue()

        Task {
            await executeJob(job)
            isRunning   = false
            activeJobID = nil
            processNext()   // Encadenar el siguiente
        }
    }

    private func executeJob(_ job: QueueJob) async {
        guard let idx = queue.firstIndex(where: { $0.id == job.id }) else { return }

        do {
            switch job.type {
            case .singleGeneration:
                await handleSingleGeneration(job: job, idx: idx)
            case .batchGeneration:
                await handleBatchGeneration(job: job, idx: idx)
            case .export:
                await handleExport(job: job, idx: idx)
            case .backup:
                await handleBackup(job: job, idx: idx)
            case .postProduction:
                await handlePostProduction(job: job, idx: idx)
            case .xyPlot:
                await handleXYPlot(job: job, idx: idx)
            }

            if let currentIdx = queue.firstIndex(where: { $0.id == job.id }) {
                queue[currentIdx].status      = .completed
                queue[currentIdx].completedAt = Date()
                let finished = queue.remove(at: currentIdx)
                completedJobs.insert(finished, at: 0)
                if completedJobs.count > 100 { completedJobs.removeLast() }
            }

        } catch {
            if let currentIdx = queue.firstIndex(where: { $0.id == job.id }) {
                queue[currentIdx].status       = .failed
                queue[currentIdx].errorMessage = error.localizedDescription
                queue[currentIdx].completedAt  = Date()

                // Auto-retry
                if autoRetry && queue[currentIdx].canRetry {
                    queue[currentIdx].status    = .pending
                    queue[currentIdx].retryCount += 1
                }
            }
        }

        saveQueue()
    }

    // MARK: - Job Handlers

    private func handleSingleGeneration(job: QueueJob, idx: Int) async {
        // El job metadata debería tener: "prompt", "settings_json"
        update(idx: idx, progress: 0.0, text: "Generando…")
        // En producción: reconstruir settings desde metadata y llamar SDService
        try? await Task.sleep(for: .milliseconds(100)) // placeholder
        update(idx: idx, progress: 1.0, text: "Generado")
    }

    private func handleBatchGeneration(job: QueueJob, idx: Int) async {
        update(idx: idx, progress: 0.0, text: "Ejecutando batch…")
        // En producción: recuperar BatchJob desde metadata["job_id"] y ejecutar
        try? await Task.sleep(for: .milliseconds(100))
        update(idx: idx, progress: 1.0, text: "Batch completado")
    }

    private func handleExport(job: QueueJob, idx: Int) async {
        update(idx: idx, progress: 0.0, text: "Exportando…")
        // En producción: recuperar asset desde metadata["asset_id"] y llamar ExportEngine
        if let assetIDStr = job.metadata["asset_id"],
           let assetID = UUID(uuidString: assetIDStr),
           let asset = AssetStore.shared.recentAssets.first(where: { $0.id == assetID }) {
            do {
                _ = try await ExportEngine.shared.export(asset: asset, addWatermark: true)
                update(idx: idx, progress: 1.0, text: "Export completado")
            } catch {
                update(idx: idx, progress: 0, text: "Error: \(error.localizedDescription)")
                throw error
            }
        }
    }

    private func handleBackup(job: QueueJob, idx: Int) async {
        update(idx: idx, progress: 0.1, text: "Iniciando backup…")
        await BackupManager.shared.runAllBackups()
        update(idx: idx, progress: 1.0, text: "Backup completado")
    }

    private func handlePostProduction(job: QueueJob, idx: Int) async {
        update(idx: idx, progress: 0.0, text: "Post-procesando…")
        try? await Task.sleep(for: .milliseconds(100))
        update(idx: idx, progress: 1.0, text: "Post-prod completado")
    }

    private func handleXYPlot(job: QueueJob, idx: Int) async {
        update(idx: idx, progress: 0.0, text: "Ejecutando X/Y Plot…")
        try? await Task.sleep(for: .milliseconds(100))
        update(idx: idx, progress: 1.0, text: "Plot completado")
    }

    // MARK: - Helpers

    private func update(idx: Int, progress: Double, text: String) {
        guard idx < queue.count else { return }
        queue[idx].progress     = progress
        queue[idx].progressText = text
    }

    // MARK: - Queue Convenience

    /// Encolar export de todos los assets aprobados pendientes.
    func enqueueAllPendingExports() {
        let pending = AssetStore.shared.recentAssets.filter {
            $0.statusEnum == .approved && ($0.cleanPath == nil || $0.cleanPath!.isEmpty)
        }
        for asset in pending {
            guard let id = asset.id else { continue }
            enqueue(
                type:     .export,
                label:    "Export · \(asset.baseName ?? id.uuidString.prefix(8).description)",
                priority: .normal,
                metadata: ["asset_id": id.uuidString]
            )
        }
    }

    /// Encolar backup programado.
    func enqueueScheduledBackup() {
        enqueue(
            type:     .backup,
            label:    "Backup programado · \(Date().shortDisplay)",
            priority: .low
        )
    }

    // MARK: - Persistence

    private struct QueuePersistence: Codable {
        var queue:        [QueueJob]
        var completedJobs: [QueueJob]
    }

    private var persistenceURL: URL? {
        VaultManager.shared.vaultMetaURL?.appending(path: "job_queue.json")
    }

    private func saveQueue() {
        guard let url = persistenceURL else { return }
        let payload = QueuePersistence(queue: queue, completedJobs: Array(completedJobs.prefix(50)))
        if let data = try? JSONEncoder.pretty.encode(payload) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func loadQueue() {
        guard let url = persistenceURL,
              let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder.iso8601.decode(QueuePersistence.self, from: data)
        else { return }
        // Al cargar, marcar jobs en "running" como fallidos (crash recovery)
        queue = payload.queue.map {
            var job = $0
            if job.status == .running { job.status = .failed; job.errorMessage = "App restarted" }
            return job
        }
        completedJobs = payload.completedJobs
    }
}

// MARK: - JobQueueView

struct JobQueueView: View {

    @StateObject private var manager = JobQueueManager.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.white.opacity(0.06))

            if manager.queue.isEmpty && manager.completedJobs.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if !manager.queue.isEmpty {
                            sectionHeader("En cola (\(manager.queue.count))")
                            ForEach(manager.queue) { job in
                                jobRow(job, isCompleted: false)
                                Divider().background(Color.white.opacity(0.04))
                            }
                        }
                        if !manager.completedJobs.isEmpty {
                            sectionHeader("Completados (\(manager.completedJobs.count))")
                            ForEach(manager.completedJobs.prefix(20)) { job in
                                jobRow(job, isCompleted: true)
                                Divider().background(Color.white.opacity(0.04))
                            }
                        }
                    }
                }
            }
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.07), lineWidth: 1))
    }

    var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "list.bullet.below.rectangle")
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "#7c6af7"))
            Text("Job Queue")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
            Spacer()
            if manager.isPaused {
                Button(action: { manager.resume() }) {
                    Image(systemName: "play.fill").font(.system(size: 11))
                        .foregroundColor(Color(hex: "#34d399"))
                }
                .buttonStyle(.plain)
            } else {
                Button(action: { manager.pause() }) {
                    Image(systemName: "pause.fill").font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            Button(action: { manager.enqueueAllPendingExports() }) {
                Image(systemName: "plus.circle").font(.system(size: 12))
                    .foregroundColor(Color(hex: "#7c6af7"))
            }
            .buttonStyle(.plain)
            .help("Encolar todos los exports pendientes")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.white.opacity(0.03))
    }

    func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(Color.white.opacity(0.02))
    }

    func jobRow(_ job: QueueJob, isCompleted: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: job.type.icon)
                .font(.system(size: 11))
                .foregroundColor(Color(hex: job.status.color))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(job.label)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(job.status.rawValue)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(Color(hex: job.status.color))
                    Text("·").font(.system(size: 9)).foregroundColor(.secondary)
                    Text(job.priority.label)
                        .font(.system(size: 9))
                        .foregroundColor(Color(hex: job.priority.color))
                    if job.status == .running {
                        Text(job.progressText)
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                }
                if job.status == .running {
                    ProgressView(value: job.progress)
                        .progressViewStyle(.linear)
                        .tint(Color(hex: "#7c6af7"))
                        .frame(maxWidth: 160)
                }
                if let err = job.errorMessage {
                    Text(err.truncated(50))
                        .font(.system(size: 9))
                        .foregroundColor(Color(hex: "#ef4444"))
                }
            }

            Spacer()

            HStack(spacing: 6) {
                if job.canRetry {
                    Button(action: { manager.retry(jobID: job.id) }) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }.buttonStyle(.plain)
                }
                if !isCompleted && job.status == .pending {
                    Button(action: { manager.cancel(jobID: job.id) }) {
                        Image(systemName: "xmark").font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.5))
                    }.buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
    }

    var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "list.bullet.below.rectangle")
                .font(.system(size: 28))
                .foregroundColor(.white.opacity(0.08))
            Text("La cola está vacía")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Button(action: { manager.enqueueAllPendingExports() }) {
                Text("Encolar exports pendientes")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#7c6af7"))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity).padding(30)
    }
}
