import Foundation
import SwiftUI
import Combine

// MARK: - JobQueueManager v5
//
// Cambios para escalabilidad masiva:
//   - Delegación de requests al SDAPIRateLimiter para no saturar A1111
//   - Backoff Exponencial
//   - Transacciones Atómicas: si un asset se rompe guardando, no ensucia la base de datos

@MainActor
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
            settings:    JobSettings? = nil,
            priority:    JobPriority = .normal,
            characterID: UUID? = nil,
            sessionTag:  String? = nil,
            batchID:     UUID? = nil
        ) {
            self.id          = UUID()
            self.name        = name
            self.request     = request
            self.settings    = settings ?? JobSettings(baseURL: "http://127.0.0.1:7860", autoExport: true, autoNSFWCheck: true, postProcessing: false)
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
        var useAtomicSave:  Bool   = true
        var maxRetryAttempts: Int  = 3
        var retryDelayBase:   Int  = 1500

        static var `default`: JobSettings {
            JobSettings(
                baseURL:          UserDefaults.standard.string(forKey: "sd.baseURL") ?? "http://127.0.0.1:7860",
                autoExport:       true,
                autoNSFWCheck:    true,
                postProcessing:   false,
                useAtomicSave:    UserDefaults.standard.object(forKey: "gen.useAtomicSave") as? Bool ?? true,
                maxRetryAttempts: max(1, UserDefaults.standard.integer(forKey: "gen.retryMaxAttempts") > 0 ? UserDefaults.standard.integer(forKey: "gen.retryMaxAttempts") : 3),
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
    @Published var maxConcurrent:    Int  = 1
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
    
    // Compatibility wrapper for string-based enqueuing logic
    @discardableResult
    func enqueueBatchItems(_ items: [BatchItem], baseURL: String, priority: JobPriority = .normal, sessionTag: String? = nil) -> UUID {
        let batchID = UUID()
        let settings = JobSettings.default
        for item in items {
            let job = GenerationJob(name: item.label, request: item.asSDRequest, settings: settings, priority: priority, sessionTag: sessionTag, batchID: batchID)
            jobs.append(job)
        }
        persistQueue()
        processQueueIfNeeded()
        return batchID
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

        let sdService = SDService()
        let baseURL   = job.settings.baseURL
        let policy    = PipelineRetryPolicy(
            maxAttempts:    job.settings.maxRetryAttempts,
            baseDelayMs:    job.settings.retryDelayBase,
            maxDelayMs:     30_000
        )

        var genSettings = GenerationSettings()
        genSettings.sdBaseURL          = job.settings.baseURL
        genSettings.autoRunNSFWCheck   = job.settings.autoNSFWCheck
        genSettings.autoRunPostProd    = job.settings.postProcessing
        let (_, scripts) = genSettings.buildRequestWithScripts(
            prompt:         job.request.prompt,
            negativePrompt: job.request.negative_prompt
        )

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
                    message:  "Job done [atomic] \(job.name) \(result.statusEmoji) seed:\(sdService.lastSeed)",
                    metadata: ["jobID": job.id.uuidString, "sha256": result.sha256Clean.prefix(12).description]
                )
            } else {
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
                    message:  "Job done [basic] \(job.name) seed:\(sdService.lastSeed)",
                    metadata: ["jobID": job.id.uuidString]
                )
            }

            if job.settings.autoNSFWCheck {
                if let assetID = jobs[idx].resultAssetID,
                   let asset   = AssetStore.shared.fetchAllAssets(limit: 1).first(where: { $0.id == assetID }) {
                    _ = await NSFWDetector.shared.detect(
                        prompt:    job.request.prompt,
                        image:     image,
                        imagePath: asset.imagePath,
                        baseURL:   baseURL
                    )
                }
            }

        } else {
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
}
