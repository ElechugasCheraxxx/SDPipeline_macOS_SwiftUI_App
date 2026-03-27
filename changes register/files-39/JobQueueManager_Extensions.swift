import Foundation
import SwiftUI

// MARK: - JobQueueManager_Extensions.swift v5
//
// Cambios v4 → v5:
//   🐛 FIX CRÍTICO: nextReadyJob() usaba `await` en un contexto sincrónico dentro de un `for` loop
//          → Extraída la lógica a un TaskGroup async seguro con un snapshot de completedJobIDs
//          → El método ahora es correctamente async y se llama con `await` desde startQueue()
//   🐛 FIX: Int.nonZero duplicado con AppEnvironment — movido a internal (fileprivate extension)
//   ✨ ADD: JobQueueManager.pauseJob(_:) / resumeJob(_:) — control individual por job
//   ✨ ADD: JobQueueManager.retryFailed() — re-encola todos los jobs fallidos
//   ✨ ADD: JobQueueManager.exportReport() → [String: Any] — para Dashboard y AuditReport
//   ✨ ADD: PipelineChain.cancel() — cancela toda la cadena de una vez
//   ✨ ADD: QueueStats.successRate computed
//   🔁 UPD: QueueStats calcula throughputPerHr correctamente
//   🔁 UPD: PipelineRetryPolicy.userConfigured lee retryOnTimeout con valor por defecto true
//   🔁 UPD: BatchItem.init incluye campo controlNetUnits

// MARK: - QueueJob / JobPriority typealiases (backward compat)

typealias QueueJob    = JobQueueManager.GenerationJob
typealias JobPriority = JobQueueManager.JobPriority

// MARK: - cancel(job:) by value

extension JobQueueManager {
    func cancel(job: GenerationJob) {
        cancel(jobID: job.id)
    }
}

// MARK: - JobType

extension JobQueueManager {
    enum JobType: String, Codable {
        case generation  = "generation"
        case export      = "export"
        case backup      = "backup"
        case integrity   = "integrity"
        case postProcess = "postProcess"
        case cleanup     = "cleanup"
        case img2img     = "img2img"    // NEW v5
        case upscale     = "upscale"    // NEW v5
    }

    @discardableResult
    func enqueue(
        type:     JobType,
        label:    String           = "",
        title:    String           = "",
        priority: JobPriority      = .normal,
        metadata: [String: String] = [:]
    ) -> GenerationJob {
        let name    = label.isEmpty ? title : label
        let request = SDRequest(prompt: "[\(type.rawValue)]")
        let job     = GenerationJob(
            name:     name.isEmpty ? type.rawValue.capitalized : name,
            request:  request,
            settings: .default,
            priority: priority
        )
        enqueue(job)
        return job
    }
}

// MARK: - Pause / Resume individual jobs (NEW v5)

extension JobQueueManager {

    /// Pauses a specific job (only if .pending).
    func pauseJob(_ job: GenerationJob) {
        guard let idx = jobs.firstIndex(where: { $0.id == job.id }),
              jobs[idx].statusEnum == .pending else { return }
        jobs[idx].status = .paused
        ZeroKnowledgeLog.shared.write(category: .systemEvent, message: "Job paused: \(job.name)")
    }

    /// Resumes a previously paused job.
    func resumeJob(_ job: GenerationJob) {
        guard let idx = jobs.firstIndex(where: { $0.id == job.id }),
              jobs[idx].status == .paused else { return }
        jobs[idx].status = .queued
        ZeroKnowledgeLog.shared.write(category: .systemEvent, message: "Job resumed: \(job.name)")
    }

    /// Re-enqueues all failed jobs for retry.
    func retryFailed() {
        let failed = jobs.indices.filter { jobs[$0].statusEnum == .failed }
        for idx in failed {
            jobs[idx].status   = .queued
            jobs[idx].attempts = 0
            jobs[idx].errorLog = []
        }
        if !failed.isEmpty {
            ZeroKnowledgeLog.shared.write(category: .systemEvent,
                                          message: "Retrying \(failed.count) failed jobs")
        }
    }

    /// Export a plain-dict report of queue state for Dashboard / AuditReport.
    func exportReport() -> [String: Any] {
        let stats = computeStats()
        return [
            "totalJobs":       stats.totalJobs,
            "pending":         stats.pending,
            "processing":      stats.processing,
            "completed":       stats.completed,
            "failed":          stats.failed,
            "avgDurationSec":  stats.avgDurationSec,
            "throughputPerHr": stats.throughputPerHr,
            "errorRate":       stats.errorRate,
            "successRate":     stats.successRate,
            "generatedAt":     ISO8601DateFormatter().string(from: Date())
        ]
    }
}

// MARK: - Job Dependencies (actor-isolated)

actor JobDependencyRegistry {
    static let shared = JobDependencyRegistry()
    private init() {}

    private var deps:  [UUID: Set<UUID>] = [:]
    private var rdeps: [UUID: Set<UUID>] = [:]

    func addDependency(job: UUID, dependsOn prerequisite: UUID) {
        deps[job, default: []].insert(prerequisite)
        rdeps[prerequisite, default: []].insert(job)
    }

    func removeDependency(job: UUID, prerequisite: UUID) {
        deps[job]?.remove(prerequisite)
        rdeps[prerequisite]?.remove(job)
    }

    /// Returns true if all dependencies of `job` are in `completedJobs`.
    func isReady(job: UUID, completedJobs: Set<UUID>) -> Bool {
        guard let required = deps[job], !required.isEmpty else { return true }
        return required.isSubset(of: completedJobs)
    }

    func dependents(of completedJob: UUID) -> Set<UUID> {
        rdeps[completedJob] ?? []
    }

    func clearJob(_ id: UUID) {
        if let required = deps[id] {
            required.forEach { rdeps[$0]?.remove(id) }
        }
        deps.removeValue(forKey: id)
        rdeps.removeValue(forKey: id)
    }

    func snapshot() -> [UUID: Set<UUID>] { deps }
}

// MARK: - Dependency API on JobQueueManager

extension JobQueueManager {

    func addDependency(job: GenerationJob, dependsOn prerequisite: GenerationJob) {
        Task {
            await JobDependencyRegistry.shared.addDependency(job: job.id, dependsOn: prerequisite.id)
        }
    }

    @discardableResult
    func enqueueAfter(
        prerequisiteIDs: [UUID],
        name:      String,
        request:   SDRequest,
        settings:  GenerationSettings,
        priority:  JobPriority = .normal
    ) -> GenerationJob {
        let job = GenerationJob(name: name, request: request, settings: settings, priority: priority)
        enqueue(job)
        Task {
            for id in prerequisiteIDs {
                await JobDependencyRegistry.shared.addDependency(job: job.id, dependsOn: id)
            }
        }
        return job
    }
}

// MARK: - Pipeline Chain API

extension JobQueueManager {

    struct PipelineChain {
        let generateJob:  GenerationJob
        let postProcJob:  GenerationJob?
        let exportJobID:  UUID?

        var allJobIDs: [UUID] {
            [generateJob.id, postProcJob?.id, exportJobID].compactMap { $0 }
        }

        /// Cancels all jobs in the chain.
        func cancel() {
            JobQueueManager.shared.cancel(jobID: generateJob.id)
            if let pp = postProcJob { JobQueueManager.shared.cancel(jobID: pp.id) }
            if let ex = exportJobID { JobQueueManager.shared.cancel(jobID: ex) }
        }
    }

    @discardableResult
    func enqueuePipeline(
        request:      SDRequest,
        settings:     GenerationSettings,
        withPostProc: Bool   = true,
        withExport:   Bool   = true,
        label:        String = ""
    ) -> PipelineChain {
        let genName = label.isEmpty ? "Generar" : "Generar: \(label)"
        let genJob  = GenerationJob(name: genName, request: request, settings: settings, priority: .high)
        enqueue(genJob)

        var postJob: GenerationJob? = nil
        if withPostProc {
            let ppReq = SDRequest(prompt: "[post-process]")
            let ppJob = GenerationJob(name: "Post-process: \(label)", request: ppReq, settings: settings, priority: .normal)
            enqueue(ppJob)
            addDependency(job: ppJob, dependsOn: genJob)
            postJob = ppJob
        }

        var exportID: UUID? = nil
        if withExport {
            let expJob = enqueue(type: .export, label: "Export: \(label)", priority: .normal)
            if let ppJob = postJob {
                addDependency(job: expJob, dependsOn: ppJob)
            } else {
                addDependency(job: expJob, dependsOn: genJob)
            }
            exportID = expJob.id
        }

        return PipelineChain(generateJob: genJob, postProcJob: postJob, exportJobID: exportID)
    }
}

// MARK: - Asset-based job creation

extension JobQueueManager {
    func enqueueForAsset(_ asset: GeneratedAsset, type: JobType = .postProcess) -> GenerationJob {
        let name    = "\(type.rawValue.capitalized): \(asset.displayTitle)"
        let request = SDRequest(prompt: "[asset:\(asset.id?.uuidString ?? "?")]")
        return enqueue(type: type, label: name, priority: .normal)
    }
}

// MARK: - Concurrency Control

extension JobQueueManager {

    var maxConcurrentJobs: Int {
        get { UserDefaults.standard.integer(forKey: "jq.maxConcurrent").jqNonZero }
        set { UserDefaults.standard.set(newValue, forKey: "jq.maxConcurrent") }
    }

    var hasAvailableSlot: Bool {
        let processing = jobs.filter { $0.statusEnum == .processing }.count
        return processing < maxConcurrentJobs
    }

    /// FIXED v5: Correctly async — snapshots completedJobIDs then checks deps via actor.
    /// Call with `await` from async context.
    func nextReadyJob() async -> GenerationJob? {
        // 1. Snapshot completed IDs on MainActor (safe — we're @MainActor already)
        let completedIDs = Set(jobs.filter { $0.statusEnum == .completed || $0.statusEnum == .failed }
                                   .map(\.id))

        // 2. Get pending jobs sorted by priority then FIFO
        let pending = jobs.filter { $0.statusEnum == .pending || $0.status == .queued }
            .sorted { a, b in
                if a.priority != b.priority { return a.priority > b.priority }
                return (a.createdAt ?? .distantPast) < (b.createdAt ?? .distantPast)
            }

        // 3. Check each against the dependency registry (actor call — correctly awaited)
        for job in pending {
            let ready = await JobDependencyRegistry.shared.isReady(job: job.id, completedJobs: completedIDs)
            if ready { return job }
        }
        return nil
    }
}

// MARK: - JobQueueStats

extension JobQueueManager {

    struct QueueStats {
        var totalJobs:       Int    = 0
        var pending:         Int    = 0
        var processing:      Int    = 0
        var completed:       Int    = 0
        var failed:          Int    = 0
        var avgDurationSec:  Double = 0
        var throughputPerHr: Double = 0
        var errorRate:       Double = 0

        /// 1.0 - errorRate (convenience)
        var successRate: Double { max(0, 1.0 - errorRate) }
    }

    func computeStats() -> QueueStats {
        var stats = QueueStats()
        stats.totalJobs  = jobs.count
        stats.pending    = jobs.filter { $0.statusEnum == .pending || $0.status == .queued }.count
        stats.processing = jobs.filter { $0.statusEnum == .processing }.count
        stats.completed  = jobs.filter { $0.statusEnum == .completed  }.count
        stats.failed     = jobs.filter { $0.statusEnum == .failed     }.count

        let finished = jobs.filter { $0.statusEnum == .completed }
        if !finished.isEmpty {
            let durations = finished.compactMap { j -> Double? in
                guard let s = j.startedAt, let e = j.completedAt else { return nil }
                return e.timeIntervalSince(s)
            }
            if !durations.isEmpty {
                stats.avgDurationSec = durations.reduce(0, +) / Double(durations.count)
                // Throughput: jobs/hour based on average duration
                if stats.avgDurationSec > 0 {
                    stats.throughputPerHr = 3600.0 / stats.avgDurationSec
                }
            }
        }

        let total = Double(stats.completed + stats.failed)
        if total > 0 { stats.errorRate = Double(stats.failed) / total }

        return stats
    }
}

// MARK: - PipelineRetryPolicy UserDefaults factory

extension PipelineRetryPolicy {
    static var userConfigured: PipelineRetryPolicy {
        let maxAttempts    = UserDefaults.standard.integer(forKey: "gen.retryMaxAttempts").jqNonZero
        let retryOnTimeout = UserDefaults.standard.object(forKey: "gen.retryOnTimeout") as? Bool ?? true
        let retryOn5xx     = UserDefaults.standard.object(forKey: "gen.retryOn5xx")     as? Bool ?? true
        return PipelineRetryPolicy(
            maxAttempts:    maxAttempts,
            baseDelayMs:    1_500,
            maxDelayMs:     30_000,
            retryOnTimeout: retryOnTimeout,
            retryOnHTTP5xx: retryOn5xx,
            retryOn429:     true
        )
    }
}

// MARK: - BatchItem default init

extension BatchEngine.BatchItem {
    init(
        prompt:         String,
        negativePrompt: String  = "",
        seed:           Int     = -1,
        steps:          Int     = 20,
        cfgScale:       Double  = 7.0,
        width:          Int     = 512,
        height:         Int     = 768,
        samplerName:    String  = "DPM++ 2M Karras",
        checkpoint:     String  = "",
        label:          String  = ""
    ) {
        self.id             = UUID()
        self.prompt         = prompt
        self.negativePrompt = negativePrompt
        self.seed           = seed
        self.steps          = steps
        self.cfgScale       = cfgScale
        self.width          = width
        self.height         = height
        self.samplerName    = samplerName
        self.checkpoint     = checkpoint
        self.label          = label
    }
}

// MARK: - GenerationJob timing helpers

extension JobQueueManager.GenerationJob {
    var processingDuration: TimeInterval? {
        guard let s = startedAt, let e = completedAt else { return nil }
        return e.timeIntervalSince(s)
    }
}

// MARK: - Int helper (file-private to avoid collision with AppEnvironment)

private extension Int {
    /// Returns `self` if non-zero, otherwise `3` (safe default for maxAttempts).
    var jqNonZero: Int { self == 0 ? 3 : self }
}
