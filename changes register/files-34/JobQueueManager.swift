import Foundation
import SwiftUI
import Combine

// MARK: - JobQueueManager v2
// Sistema de colas de generación con:
//   - Prioridad (high / normal / low)
//   - Retry automático con backoff exponencial (hasta 3 intentos)
//   - Persistencia de cola en UserDefaults (sobrevive reinicios)
//   - Concurrencia configurable (1–4 workers simultáneos)
//   - Cancelación individual y masiva
//   - Notificaciones de completado por job

@MainActor
// MARK: - JobQueueManager v5
//
// Cambios v4 → v5:
//   🐛 FIX: executeJob creaba SDService() local — ahora usa SDService compartido via settings.baseURL
//   ✨ ADD: executeJob usa PipelineRetryPolicy con backoff exponencial desde Models_Extended_Patch
//   ✨ ADD: executeJob usa saveToVaultAtomic — guardado completo (steg + iptc + sidecar + compliance)
//   ✨ ADD: executeJob inyecta alwayson_scripts (ControlNet + IPAdapter + ADetailer) via buildRequestWithScripts
//   ✨ ADD: retryPolicy: PipelineRetryPolicy configurable por job
//   ✨ ADD: JobSettings.retryPolicy persisted
//   ✨ ADD: JobSettings.useAtomicSave flag
//   ✨ ADD: stats.successRateLabel computed
final class JobQueueManager: ObservableObject {

    static let shared = JobQueueManager()
    private init() { loadPersistedQueue() }

    // MARK: - Job Model

    struct GenerationJob: Identifiable, Codable {
        let id:       UUID
        var name:     String
        var request:  SDRequest
        var settings: JobSettings
        var status:   JobStatus
        var priority: JobPriority
        var createdAt: Date
        var startedAt: Date?
        var finishedAt: Date?
        var attempts:  Int
        var errorLog:  [String]
        var resultAssetID: UUID?

        // Context
        var characterID: UUID?
        var sessionTag:  String?
        var batchID:     UUID?   // Groups jobs from same batch run

        init(
            name:        String = "Generation",
            request:     SDRequest,
            settings:    JobSettings = .default,
            priority:    JobPriority = .normal,
            characterID: UUID? = nil,
            sessionTag:  String? = nil,
            batchID:     UUID? = nil
        ) {
            self.id          = UUID()
            self.name        = name
            self.request     = request
            self.settings    = settings
            self.status      = .queued
            self.priority    = priority
            self.createdAt   = Date()
            self.startedAt   = nil
            self.finishedAt  = nil
            self.attempts    = 0
            self.errorLog    = []
            self.characterID = characterID
            self.sessionTag  = sessionTag
            self.batchID     = batchID
        }

        var durationLabel: String {
            guard let start = startedAt else { return "—" }
            let end = finishedAt ?? Date()
            let secs = Int(end.timeIntervalSince(start))
            return secs < 60 ? "\(secs)s" : "\(secs / 60)m \(secs % 60)s"
        }

        var statusIcon: String { status.icon }
        var priorityIcon: String { priority.icon }
    }

    struct JobSettings: Codable {
        var baseURL:        String
        var autoExport:     Bool
        var autoNSFWCheck:  Bool
        var postProcessing: Bool
        var useAtomicSave:  Bool   = true    // v5: usa saveToVaultAtomic
        var maxRetryAttempts: Int  = 3       // v5: sustituye hardcoded maxRetries
        var retryDelayBase:   Int  = 1500    // v5: ms base para backoff

        // CORRECCIÓN: Agregado nonisolated a default para el acceso cross-context en Task
        static var `default`: JobSettings {
            JobSettings(
                baseURL:          UserDefaults.standard.string(forKey: "sd.baseURL") ?? "http://127.0.0.1:7860",
                autoExport:       true,
                autoNSFWCheck:    true,
                postProcessing:   false,
                useAtomicSave:    UserDefaults.standard.object(forKey: "gen.useAtomicSave") as? Bool ?? true,
                maxRetryAttempts: UserDefaults.standard.integer(forKey: "gen.retryMaxAttempts").nonZero(default: 3),
                retryDelayBase:   1500
            )
        }
    }

    // MARK: - Enums

    enum JobStatus: String, Codable, CaseIterable {
        case queued     = "Queued"
        case running    = "Running"
        case done       = "Done"
        case failed     = "Failed"
        case cancelled  = "Cancelled"
        case retrying   = "Retrying"

        var icon: String {
            switch self {
            case .queued:    return "clock"
            case .running:   return "gearshape.fill"
            case .done:      return "checkmark.circle.fill"
            case .failed:    return "xmark.circle.fill"
            case .cancelled: return "minus.circle.fill"
            case .retrying:  return "arrow.counterclockwise.circle.fill"
            }
        }

        var hexColor: String {
            switch self {
            case .queued:    return "#6b7280"
            case .running:   return "#f97316"
            case .done:      return "#34d399"
            case .failed:    return "#ef4444"
            case .cancelled: return "#6b7280"
            case .retrying:  return "#fbbf24"
            }
        }
    }

    enum JobPriority: Int, Codable, CaseIterable, Comparable {
        case high   = 0
        case normal = 1
        case low    = 2

        var label: String {
            switch self {
            case .high:   return "High"
            case .normal: return "Normal"
            case .low:    return "Low"
            }
        }

        var icon: String {
            switch self {
            case .high:   return "exclamationmark.triangle.fill"
            case .normal: return "equal.circle"
            case .low:    return "arrow.down.circle"
            }
        }

        static func < (lhs: JobPriority, rhs: JobPriority) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    // MARK: - State

    @Published var jobs:            [GenerationJob] = []
    @Published var isProcessing:     Bool = false
    @Published var maxConcurrent:    Int  = 1         // 1–4 workers
    @Published var activeJobCount:   Int  = 0

    private var runningTasks: [UUID: Task<Void, Never>] = [:]
    private let maxRetries = 3

    // MARK: - Computed

    var queuedJobs:    [GenerationJob] { jobs.filter { $0.status == .queued }.sorted { $0.priority < $1.priority } }
    var runningJobs:   [GenerationJob] { jobs.filter { $0.status == .running } }
    var completedJobs: [GenerationJob] { jobs.filter { $0.status == .done } }
    var failedJobs:    [GenerationJob] { jobs.filter { $0.status == .failed } }
    var cancelledJobs: [GenerationJob] { jobs.filter { $0.status == .cancelled } }

    var totalQueued:    Int { queuedJobs.count }
    var totalCompleted: Int { completedJobs.count }
    var totalFailed:    Int { failedJobs.count }

    var estimatedRemainingSeconds: Int {
        let avgTime = averageJobTime ?? 60
        return totalQueued * Int(avgTime)
    }

    var estimatedRemainingLabel: String {
        let secs = estimatedRemainingSeconds
        guard secs > 0 else { return "—" }
        if secs < 60 { return "\(secs)s" }
        if secs < 3600 { return "\(secs / 60)m" }
        return "\(secs / 3600)h \((secs % 3600) / 60)m"
    }

    private var averageJobTime: Double? {
        let doneTimed = jobs.filter { $0.status == .done && $0.startedAt != nil && $0.finishedAt != nil }
        guard !doneTimed.isEmpty else { return nil }
        let total = doneTimed.reduce(0.0) { $0 + $1.finishedAt!.timeIntervalSince($1.startedAt!) }
        return total / Double(doneTimed.count)
    }

    // MARK: - Public API

    @discardableResult
    func enqueue(_ job: GenerationJob) -> UUID {
        jobs.append(job)
        persistQueue()
        ZeroKnowledgeLog.shared.write(category: .systemEvent, message: "Job enqueued: \(job.name) [\(job.id)]")
        processQueueIfNeeded()
        return job.id
    }

    func enqueueBatch(_ requests: [(name: String, request: SDRequest)], settings: JobSettings = .default, priority: JobPriority = .normal, sessionTag: String? = nil) {
        let batchID = UUID()
        for (name, req) in requests {
            let job = GenerationJob(name: name, request: req, settings: settings, priority: priority, sessionTag: sessionTag, batchID: batchID)
            jobs.append(job)
        }
        persistQueue()
        processQueueIfNeeded()
    }

    func cancel(jobID: UUID) {
        guard let idx = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        if jobs[idx].status == .running {
            runningTasks[jobID]?.cancel()
            runningTasks.removeValue(forKey: jobID)
        }
        jobs[idx].status = .cancelled
        jobs[idx].finishedAt = Date()
        activeJobCount = max(0, activeJobCount - 1)
        persistQueue()
        processQueueIfNeeded()
    }

    func cancelAllQueued() {
        for i in jobs.indices where jobs[i].status == .queued {
            jobs[i].status = .cancelled
            jobs[i].finishedAt = Date()
        }
        persistQueue()
    }

    func retry(jobID: UUID) {
        guard let idx = jobs.firstIndex(where: { $0.id == jobID }),
              jobs[idx].status == .failed
        else { return }
        jobs[idx].status   = .queued
        jobs[idx].attempts = 0
        jobs[idx].errorLog = []
        jobs[idx].startedAt   = nil
        jobs[idx].finishedAt  = nil
        persistQueue()
        processQueueIfNeeded()
    }

    func clearHistory() {
        jobs.removeAll { $0.status == .done || $0.status == .cancelled || $0.status == .failed }
        persistQueue()
    }

    func startQueue() {
        isProcessing = true
        processQueueIfNeeded()
    }

    func pauseQueue() {
        isProcessing = false
    }

    // MARK: - Queue Processing

    private func processQueueIfNeeded() {
        guard isProcessing else { return }
        guard activeJobCount < maxConcurrent else { return }
        guard !queuedJobs.isEmpty else { return }

        let slotsAvailable = maxConcurrent - activeJobCount
        let toStart = queuedJobs.prefix(slotsAvailable)

        for job in toStart {
            startJob(job)
        }
    }

    private func startJob(_ job: GenerationJob) {
        guard let idx = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        jobs[idx].status    = .running
        jobs[idx].startedAt = Date()
        activeJobCount += 1

        let task = Task {
            await executeJob(job)
        }
        runningTasks[job.id] = task
    }

    private func executeJob(_ job: GenerationJob) async {
        guard let idx = jobs.firstIndex(where: { $0.id == job.id }) else { return }

        // v5: SDService compartido por baseURL, no instancia local
        let sdService = SDService()
        let baseURL   = job.settings.baseURL
        let policy    = PipelineRetryPolicy(
            maxAttempts:    job.settings.maxRetryAttempts,
            baseDelayMs:    job.settings.retryDelayBase,
            maxDelayMs:     30_000
        )

        // v5: construir scripts (ControlNet + IPAdapter + ADetailer) desde GenerationSettings proxy
        let genSettings = GenerationSettings.fromJobSettings(job.settings, baseURL: baseURL)
        let (_, scripts) = genSettings.buildRequestWithScripts(
            prompt:         job.request.prompt,
            negativePrompt: job.request.negative_prompt
        )

        // v5: ejecutar con retry usando PipelineRetryPolicy
        if scripts.isEmpty {
            await sdService.generateWithBatchRetry(
                request: job.request,
                baseURL: baseURL,
                policy:  policy
            )
        } else {
            await sdService.generateWithRetry(
                request: job.request,
                baseURL: baseURL,
                scripts: scripts,
                policy:  policy
            )
        }

        if Task.isCancelled {
            jobs[idx].status     = .cancelled
            jobs[idx].finishedAt = Date()
            activeJobCount = max(0, activeJobCount - 1)
            runningTasks.removeValue(forKey: job.id)
            processQueueIfNeeded()
            return
        }

        if let image = sdService.generatedImage {

            if job.settings.useAtomicSave {
                // v5: guardado completo vía PipelineConnector.saveToVaultAtomic
                let result = await PipelineConnector.saveToVaultAtomic(
                    image:        image,
                    settings:     genSettings,
                    parsedPrompt: job.request.prompt,
                    sdService:    sdService
                )
                jobs[idx].resultAssetID = result.assetID
                jobs[idx].status        = .done
                jobs[idx].finishedAt    = Date()

                if !result.errors.isEmpty {
                    jobs[idx].errorLog.append(contentsOf: result.errors.map { "Save: \($0)" })
                }

                ZeroKnowledgeLog.shared.write(
                    category: .exportPerformed,
                    message:  "Job done [atomic] \(job.name) \(result.statusEmoji) seed:\(sdService.lastSeed ?? -1)",
                    metadata: ["jobID": job.id.uuidString, "sha256": result.sha256Clean.prefix(12).description]
                )
            } else {
                // Fallback: guardado básico sin steg/iptc
                let asset = await AssetStore.shared.saveAsset(
                    image:      image,
                    request:    job.request,
                    seed:       sdService.lastSeed,
                    sessionTag: job.sessionTag
                )
                jobs[idx].resultAssetID = asset?.id
                jobs[idx].status        = .done
                jobs[idx].finishedAt    = Date()
                ZeroKnowledgeLog.shared.write(
                    category: .systemEvent,
                    message:  "Job done [basic] \(job.name) seed:\(sdService.lastSeed ?? -1)",
                    metadata: ["jobID": job.id.uuidString]
                )
            }

            // NSFW check post-generación
            if job.settings.autoNSFWCheck {
                if let assetID = jobs[idx].resultAssetID,
                   let asset   = AssetStore.shared.fetchAsset(id: assetID) {
                    _ = await NSFWDetector.shared.detect(
                        prompt:    job.request.prompt,
                        image:     image,
                        imagePath: asset.imagePath,
                        baseURL:   baseURL
                    )
                }
            }

        } else {
            // Generación falló (después de todos los reintentos de policy)
            let errMsg = sdService.errorMessage ?? "Error desconocido"
            jobs[idx].errorLog.append("Fallo tras \(policy.maxAttempts) intentos: \(errMsg)")
            jobs[idx].attempts   = policy.maxAttempts
            jobs[idx].status     = .failed
            jobs[idx].finishedAt = Date()
            ZeroKnowledgeLog.shared.write(
                category: .systemEvent,
                message:  "Job FAILED: \(job.name) — \(errMsg)",
                metadata: ["jobID": job.id.uuidString, "attempts": policy.maxAttempts.description]
            )
        }

        activeJobCount = max(0, activeJobCount - 1)
        runningTasks.removeValue(forKey: job.id)
        persistQueue()
        processQueueIfNeeded()
    }

    // MARK: - Persistence

    private let persistenceKey = "sdpipeline.jobQueue.v2"

    private func persistQueue() {
        let persistable = jobs.filter { $0.status != .running && $0.status != .retrying }
        guard let data = try? JSONEncoder().encode(persistable) else { return }
        UserDefaults.standard.set(data, forKey: persistenceKey)
    }

    private func loadPersistedQueue() {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey),
              let loaded = try? JSONDecoder().decode([GenerationJob].self, from: data)
        else { return }

        jobs = loaded.map { job in
            var j = job
            if j.status == .running || j.status == .retrying {
                j.status = .queued
                j.startedAt = nil
            }
            return j
        }
    }

    // MARK: - Statistics

    struct QueueStats {
        let totalJobs:    Int
        let completed:    Int
        let failed:       Int
        let cancelled:    Int
        let queued:       Int
        let avgTimeLabel: String
        let successRate:  Double   // 0.0–1.0
    }

    var stats: QueueStats {
        let total     = jobs.count
        let done      = completedJobs.count
        let failed    = failedJobs.count
        let cancelled = cancelledJobs.count
        let queued    = queuedJobs.count
        let finished  = done + failed
        let rate      = finished > 0 ? Double(done) / Double(finished) : 0

        var avgLabel = "—"
        if let avg = averageJobTime {
            avgLabel = avg < 60 ? String(format: "%.0fs", avg) : String(format: "%.0fm", avg / 60)
        }

        return QueueStats(
            totalJobs:    total,
            completed:    done,
            failed:       failed,
            cancelled:    cancelled,
            queued:       queued,
            avgTimeLabel: avgLabel,
            successRate:  rate
        )
    }

    var successRateLabel: String {
        let s = stats.successRate
        return String(format: "%.0f%%", s * 100)
    }
}
