import Foundation
import AppKit
import SwiftUI
import Combine

// MARK: - ExportBatchCoordinator

@MainActor
final class ExportBatchCoordinator: ObservableObject {

    static let shared = ExportBatchCoordinator()
    private init() {}

    // MARK: - Models

    struct ExportJob: Identifiable {
        let id       = UUID()
        var asset:   GeneratedAsset
        var setLabel: String         = ""
        var priority: Int            = 0

        var status: Status = .pending
        var result: ExportEngine.ExportResult?
        var error:  String?
        var attempts: Int = 0

        enum Status: String {
            case pending    = "Pendiente"
            case processing = "Procesando"
            case done       = "Completado"
            case failed     = "Fallido"
            case skipped    = "Omitido"
        }
    }

    struct BatchConfig {
        var maxConcurrency:  Int    = 2
        var maxRetries:      Int    = 2
        var retryDelayMs:    Int    = 500
        var stopOnError:     Bool   = false
        var addWatermark:    Bool   = true
        var notifyOnComplete: Bool  = true
    }

    struct BatchSummary {
        let total:     Int
        let succeeded: Int
        let failed:    Int
        let skipped:   Int
        let duration:  TimeInterval
        let results:   [ExportJob]

        var successRate: Double { total > 0 ? Double(succeeded) / Double(total) : 0 }
    }

    // MARK: - Published State

    @Published var queue:        [ExportJob]     = []
    @Published var isRunning:    Bool             = false
    @Published var isPaused:     Bool             = false
    @Published var totalProgress: Double          = 0
    @Published var currentJobs:  [UUID]           = []
    @Published var lastSummary:  BatchSummary?
    @Published var config = BatchConfig()

    private var processingTask: Task<Void, Never>?
    private var batchStartTime: Date?

    // MARK: - Public API

    @discardableResult
    func enqueue(assets: [GeneratedAsset], setLabel: String = "", priority: Int = 0) -> [UUID] {
        let jobs = assets.map { asset -> ExportJob in
            ExportJob(asset: asset, setLabel: setLabel, priority: priority)
        }
        queue.append(contentsOf: jobs)
        sortQueue()
        return jobs.map(\.id)
    }

    func start() {
        guard !isRunning else { return }
        isRunning    = true
        isPaused     = false
        batchStartTime = Date()

        processingTask = Task { [weak self] in
            await self?.processLoop()
        }
    }

    func pause() {
        isPaused = true
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        if isRunning { return }
        start()
    }

    func cancel() {
        processingTask?.cancel()
        processingTask = nil
        isRunning = false
        isPaused  = false

        for idx in queue.indices where queue[idx].status == .pending {
            queue[idx].status = .skipped
        }
        currentJobs = []
    }

    func clearCompleted() {
        queue.removeAll { $0.status == .done || $0.status == .failed || $0.status == .skipped }
        updateProgress()
    }

    func retryFailed() {
        for idx in queue.indices where queue[idx].status == .failed {
            queue[idx].status   = .pending
            queue[idx].error    = nil
            queue[idx].attempts = 0
        }
        if !isRunning { start() }
    }

    // MARK: - Process Loop

    private func processLoop() async {
        while !Task.isCancelled {
            while isPaused && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }

            let pending = queue.filter { $0.status == .pending }
            if pending.isEmpty { break }

            let slotsAvailable = config.maxConcurrency - currentJobs.count
            guard slotsAvailable > 0 else {
                try? await Task.sleep(nanoseconds: 100_000_000)
                continue
            }

            let batch = Array(pending.prefix(slotsAvailable))

            await withTaskGroup(of: Void.self) { group in
                for job in batch {
                    group.addTask { [weak self] in
                        await self?.processJob(id: job.id)
                    }
                }
            }

            if config.stopOnError && queue.contains(where: { $0.status == .failed }) {
                break
            }
        }

        await finalizeBatch()
    }

    private func processJob(id: UUID) async {
        guard let idx = queue.firstIndex(where: { $0.id == id }) else { return }

        queue[idx].status = .processing
        currentJobs.append(id)

        var lastError: String = ""

        for attempt in 1...(config.maxRetries + 1) {
            do {
                queue[idx].attempts = attempt
                let result = try await ExportEngine.shared.export(
                    asset: queue[idx].asset,
                    addWatermark: config.addWatermark
                )
                queue[idx].result = result
                queue[idx].status = .done
                lastError = ""
                break
            } catch {
                lastError = error.localizedDescription
                if attempt <= config.maxRetries {
                    try? await Task.sleep(nanoseconds: UInt64(config.retryDelayMs) * 1_000_000)
                }
            }
        }

        if !lastError.isEmpty {
            queue[idx].status = .failed
            queue[idx].error  = lastError
        }

        currentJobs.removeAll(where: { $0 == id })
        updateProgress()
    }

    private func finalizeBatch() async {
        isRunning   = false
        currentJobs = []
        updateProgress()

        let duration = Date().timeIntervalSince(batchStartTime ?? Date())
        let summary  = BatchSummary(
            total:     queue.count,
            succeeded: queue.filter { $0.status == .done }.count,
            failed:    queue.filter { $0.status == .failed }.count,
            skipped:   queue.filter { $0.status == .skipped }.count,
            duration:  duration,
            results:   queue
        )
        lastSummary = summary

        PublishComplianceLogger.shared.logBatchExport(
            succeeded: summary.succeeded,
            failed: summary.failed,
            duration: duration
        )
    }

    private func sortQueue() {
        queue.sort { $0.priority > $1.priority }
    }

    private func updateProgress() {
        let done = queue.filter { $0.status == .done || $0.status == .failed || $0.status == .skipped }.count
        totalProgress = queue.isEmpty ? 0 : Double(done) / Double(queue.count)
    }

    var completedCount: Int { queue.filter { $0.status == .done }.count }
    var failedCount:    Int { queue.filter { $0.status == .failed }.count }
    var pendingCount:   Int { queue.filter { $0.status == .pending }.count }
}

// MARK: - BatchCoordinator SwiftUI Progress View

struct ExportBatchProgressView: View {

    @ObservedObject var coordinator = ExportBatchCoordinator.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.doc.on.clipboard")
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: "#7c6af7"))
                Text("Export en lote")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                if coordinator.isRunning {
                    Text("\(coordinator.completedCount)/\(coordinator.queue.count)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
            }

            // Barra global
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.07)).frame(height: 4)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LinearGradient(
                            colors: [Color(hex: "#7c6af7"), Color(hex: "#3de3c0")],
                            startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * coordinator.totalProgress, height: 4)
                        .animation(.easeInOut(duration: 0.25), value: coordinator.totalProgress)
                }
            }.frame(height: 4)

            // Jobs activos
            if !coordinator.currentJobs.isEmpty {
                ForEach(coordinator.currentJobs.prefix(2), id: \.self) { id in
                    if let job = coordinator.queue.first(where: { $0.id == id }) {
                        HStack(spacing: 6) {
                            ProgressView().progressViewStyle(.circular).scaleEffect(0.45).frame(width: 12, height: 12)
                            Text(job.asset.baseName ?? "imagen")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }

            // Controles
            HStack(spacing: 8) {
                if coordinator.isRunning {
                    Button(coordinator.isPaused ? "Reanudar" : "Pausar") {
                        coordinator.isPaused ? coordinator.resume() : coordinator.pause()
                    }
                    Button("Cancelar") { coordinator.cancel() }
                }
                if coordinator.failedCount > 0 {
                    Button("Reintentar (\(coordinator.failedCount))") { coordinator.retryFailed() }
                }
                if !coordinator.isRunning && coordinator.completedCount > 0 {
                    Button("Limpiar") { coordinator.clearCompleted() }
                }
            }
            .font(.system(size: 10))
            .foregroundColor(Color(hex: "#7c6af7"))
        }
        .padding(12)
        .background(Color.white.opacity(0.04))
        .cornerRadius(10)
    }
}
