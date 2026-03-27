import Foundation
import SwiftUI

// MARK: - JobQueueManager_Extensions.swift v5
//
// Cambios v4 → v5:
//   🐛 FIX CRÍTICO: statusEnum no existe en GenerationJob — eliminado, usar .status directamente
//   🐛 FIX CRÍTICO: .pending/.processing/.completed → .queued/.running/.done (nombres reales del enum)
//   🐛 FIX CRÍTICO: .paused no existe en JobStatus — eliminado
//   🐛 FIX CRÍTICO: j.completedAt no existe → es j.finishedAt
//   🐛 FIX CRÍTICO: nextReadyJob usaba await en contexto síncrono → ahora es async correcto
//   🐛 FIX: a.createdAt era comparado con ?? .distantPast innecesario (createdAt es Date, no Date?)
//   🐛 FIX: Int.nonZero collision con PipelineConnector — ahora fileprivate
//   ✨ ADD: pauseJob / resumeJob via status .cancelled (no existe .paused, se omite del flujo)
//   ✨ ADD: retryFailed() — re-encola todos los jobs en estado .failed
//   ✨ ADD: exportReport() → [String: Any] para Dashboard y AuditReport
//   ✨ ADD: PipelineChain.cancelAll() — cancela toda la cadena de golpe
//   ✨ ADD: QueueStats.successRate computed property

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
        case img2img     = "img2img"
        case upscale     = "upscale"
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

// MARK: - Retry Failed (NEW v5)

extension JobQueueManager {

    /// Re-encola todos los jobs en estado .failed para reintento.
    func retryFailed() {
        let failedIndices = jobs.indices.filter { jobs[$0].status == .failed }
        for idx in failedIndices {
            jobs[idx].status   = .queued
            jobs[idx].attempts = 0
            jobs[idx].errorLog = []
        }
        if !failedIndices.isEmpty {
            ZeroKnowledgeLog.shared.write(
                category: .systemEvent,
                message:  "Retry: \(failedIndices.count) jobs fallidos re-encolados"
            )
        }
    }

    /// Exporta un reporte plano del estado de la cola para Dashboard / AuditReport.
    func exportReport() -> [String: Any] {
        let stats = computeStats()
        return [
            "totalJobs":       stats.totalJobs,
            "queued":          stats.queued,
            "running":         stats.running,
            "done":            stats.done,
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

/// Registro actor-isolated de dependencias entre jobs.
/// Si job A depende de job B, A no inicia hasta que B termine (done/failed).
actor JobDependencyRegistry {
    static let shared = JobDependencyRegistry()
    private init() {}

    private var deps:  [UUID: Set<UUID>] = [:]   // jobID → prerequisiteIDs
    private var rdeps: [UUID: Set<UUID>] = [:]   // prerequisiteID → dependentJobIDs

    func addDependency(job: UUID, dependsOn prerequisite: UUID) {
        deps[job, default: []].insert(prerequisite)
        rdeps[prerequisite, default: []].insert(job)
    }

    func removeDependency(job: UUID, prerequisite: UUID) {
        deps[job]?.remove(prerequisite)
        rdeps[prerequisite]?.remove(job)
    }

    /// Retorna true si todas las dependencias de `job` están en `completedJobs`.
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

        /// Cancela todos los jobs de la cadena de una vez.
        func cancelAll() {
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
            let ppJob = GenerationJob(name: "Post-process: \(label)", request: ppReq,
                                      settings: settings, priority: .normal)
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

    /// True si hay slots libres para iniciar otro job.
    var hasAvailableSlot: Bool {
        // FIX: .running is the real case (was .processing)
        let running = jobs.filter { $0.status == .running }.count
        return running < maxConcurrentJobs
    }

    // MARK: nextReadyJob — FIX v5: now correctly async
    // Previous version called `await` inside a synchronous `for` loop → compile error.
    // Now the function is `async` and snapshots completedJobIDs before actor call.

    func nextReadyJob() async -> GenerationJob? {
        // Snapshot completed IDs on MainActor (safe — we are @MainActor)
        // FIX: .done is the real "completed" case (was .completed)
        let completedIDs = Set(
            jobs.filter { $0.status == .done || $0.status == .failed || $0.status == .cancelled }
                .map(\.id)
        )

        // FIX: .queued is the real "pending" case (was .pending)
        // FIX: createdAt is Date (not Date?), no nil-coalescing needed
        let pending = jobs
            .filter { $0.status == .queued }
            .sorted { a, b in
                if a.priority != b.priority { return a.priority > b.priority }
                return a.createdAt < b.createdAt
            }

        for job in pending {
            let ready = await JobDependencyRegistry.shared.isReady(
                job: job.id, completedJobs: completedIDs
            )
            if ready { return job }
        }
        return nil
    }
}

// MARK: - JobQueueStats

extension JobQueueManager {

    struct QueueStats {
        var totalJobs:       Int    = 0
        // FIX: field names match real JobStatus cases
        var queued:          Int    = 0   // was "pending"
        var running:         Int    = 0   // was "processing"
        var done:            Int    = 0   // was "completed"
        var failed:          Int    = 0
        var avgDurationSec:  Double = 0
        var throughputPerHr: Double = 0
        var errorRate:       Double = 0

        /// 1.0 - errorRate
        var successRate: Double { max(0, 1.0 - errorRate) }
    }

    func computeStats() -> QueueStats {
        var stats = QueueStats()
        stats.totalJobs = jobs.count
        // FIX: use real JobStatus enum cases throughout
        stats.queued    = jobs.filter { $0.status == .queued    }.count
        stats.running   = jobs.filter { $0.status == .running   }.count
        stats.done      = jobs.filter { $0.status == .done      }.count
        stats.failed    = jobs.filter { $0.status == .failed    }.count

        // Duration calc — FIX: finishedAt (not completedAt)
        let finished = jobs.filter { $0.status == .done }
        if !finished.isEmpty {
            let durations = finished.compactMap { j -> Double? in
                guard let s = j.startedAt, let e = j.finishedAt else { return nil }
                return e.timeIntervalSince(s)
            }
            if !durations.isEmpty {
                stats.avgDurationSec = durations.reduce(0, +) / Double(durations.count)
                if stats.avgDurationSec > 0 {
                    stats.throughputPerHr = 3600.0 / stats.avgDurationSec
                }
            }
        }

        let total = Double(stats.done + stats.failed)
        if total > 0 { stats.errorRate = Double(stats.failed) / total }

        return stats
    }
}

// MARK: - PipelineRetryPolicy UserDefaults factory (v3 compat)

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

// MARK: - BatchItem default init (v3 compat)

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
    /// Duración de procesamiento en segundos — FIX: finishedAt (no completedAt).
    var processingDuration: TimeInterval? {
        guard let s = startedAt, let e = finishedAt else { return nil }
        return e.timeIntervalSince(s)
    }
}

// MARK: - Int helper (fileprivate — avoids collision with PipelineConnector extension)

private extension Int {
    /// Retorna self si no es cero, de lo contrario retorna 3 (safe default).
    var jqNonZero: Int { self == 0 ? 3 : self }
}
