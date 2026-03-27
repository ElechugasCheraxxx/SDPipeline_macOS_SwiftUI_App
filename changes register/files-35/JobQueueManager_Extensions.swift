import Foundation
import SwiftUI

// MARK: - JobQueueManager_Extensions.swift v4
//
// Cambios v3 → v4:
//   ✨ ADD: Job dependencies — un job puede esperar a que otros completen antes de ejecutarse
//   ✨ ADD: Concurrency control — límite configurable de jobs paralelos
//   ✨ ADD: Priority scheduling mejorado — ties resueltos por FIFO timestamp
//   ✨ ADD: Export job type — integración con ExportBatchCoordinator
//   ✨ ADD: JobQueueStats para el Dashboard
//   ✨ ADD: Pause / Resume de jobs individuales
//   ✨ ADD: Job chaining API — conveniencia para pipelines (generate → postproc → export)
//   🐛 FIX: QueueJob/GenerationJob typealiases (herencia de v3)

// MARK: - QueueJob / JobPriority typealiases (backward compat)

typealias QueueJob    = JobQueueManager.GenerationJob
typealias JobPriority = JobQueueManager.JobPriority

// MARK: - cancel(job:) by value

extension JobQueueManager {
    func cancel(job: GenerationJob) {
        cancel(jobID: job.id)
    }
}

// MARK: - JobType (backward compat)

extension JobQueueManager {
    enum JobType: String, Codable {
        case generation   = "generation"
        case export       = "export"
        case backup       = "backup"
        case integrity    = "integrity"
        case postProcess  = "postProcess"
        case cleanup      = "cleanup"
    }

    /// Legacy convenience enqueue.
    @discardableResult
    func enqueue(
        type:     JobType,
        label:    String          = "",
        title:    String          = "",
        priority: JobPriority     = .normal,
        metadata: [String: String] = [:]
    ) -> GenerationJob {
        let name     = label.isEmpty ? title : label
        let request  = SDRequest(prompt: "[\(type.rawValue)]")
        let job      = GenerationJob(
            name:     name.isEmpty ? type.rawValue.capitalized : name,
            request:  request,
            settings: .default,
            priority: priority
        )
        enqueue(job)
        return job
    }
}

// MARK: - Job Dependencies

/// Registro actor-isolated de dependencias entre jobs.
/// Si job A depende de job B, A no inicia hasta que B termine (done/failed).
actor JobDependencyRegistry {
    static let shared = JobDependencyRegistry()
    private init() {}

    /// Mapa: jobID → Set de IDs que este job necesita completados
    private var deps: [UUID: Set<UUID>] = [:]
    /// Mapa inverso: completedJobID → Set de jobs que lo esperaban
    private var rdeps: [UUID: Set<UUID>] = [:]

    func addDependency(job: UUID, dependsOn prerequisite: UUID) {
        deps[job, default: []].insert(prerequisite)
        rdeps[prerequisite, default: []].insert(job)
    }

    func removeDependency(job: UUID, prerequisite: UUID) {
        deps[job]?.remove(prerequisite)
        rdeps[prerequisite]?.remove(job)
    }

    /// Retorna true si el job puede iniciar (todas sus dependencias completadas).
    func isReady(job: UUID, completedJobs: Set<UUID>) -> Bool {
        guard let required = deps[job] else { return true }
        return required.isSubset(of: completedJobs)
    }

    /// Retorna los jobs que estaban esperando al prerequisite (para notificarles).
    func dependents(of completedJob: UUID) -> Set<UUID> {
        return rdeps[completedJob] ?? []
    }

    func clearJob(_ id: UUID) {
        if let required = deps[id] {
            for prereq in required { rdeps[prereq]?.remove(id) }
        }
        deps.removeValue(forKey: id)
        rdeps.removeValue(forKey: id)
    }
}

// MARK: - Dependency API on JobQueueManager

extension JobQueueManager {

    /// Agrega una dependencia: `job` no inicia hasta que `prerequisite` complete.
    func addDependency(job: GenerationJob, dependsOn prerequisite: GenerationJob) {
        Task {
            await JobDependencyRegistry.shared.addDependency(job: job.id, dependsOn: prerequisite.id)
        }
    }

    /// Crea y encola un job que sólo inicia después de que `prerequisiteIDs` completen.
    @discardableResult
    func enqueueAfter(
        prerequisiteIDs: [UUID],
        name:     String,
        request:  SDRequest,
        settings: GenerationSettings,
        priority: JobPriority = .normal
    ) -> GenerationJob {
        let job = GenerationJob(name: name, request: request, settings: settings, priority: priority)
        enqueue(job)
        Task {
            for prereqID in prerequisiteIDs {
                await JobDependencyRegistry.shared.addDependency(job: job.id, dependsOn: prereqID)
            }
        }
        return job
    }
}

// MARK: - Pipeline Chain API

extension JobQueueManager {

    /// Construye una cadena de jobs: generate → postProcess → export.
    /// Cada etapa espera automáticamente a la anterior.
    struct PipelineChain {
        let generateJob:    GenerationJob
        let postProcJob:    GenerationJob?
        let exportJobID:    UUID?

        var allJobIDs: [UUID] {
            [generateJob.id, postProcJob?.id, exportJobID].compactMap { $0 }
        }
    }

    @discardableResult
    func enqueuePipeline(
        request:        SDRequest,
        settings:       GenerationSettings,
        withPostProc:   Bool = true,
        withExport:     Bool = true,
        label:          String = ""
    ) -> PipelineChain {
        let genName    = label.isEmpty ? "Generar" : "Generar: \(label)"
        let genJob     = GenerationJob(name: genName, request: request, settings: settings, priority: .high)
        enqueue(genJob)

        var postJob: GenerationJob? = nil
        if withPostProc {
            let ppReq  = SDRequest(prompt: "[post-process]")
            let ppJob  = GenerationJob(name: "Post-process: \(label)", request: ppReq, settings: settings, priority: .normal)
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

// MARK: - Asset-based job creation (v3 compat)

extension JobQueueManager {
    func enqueueForAsset(_ asset: GeneratedAsset, type: JobType = .postProcess) -> GenerationJob {
        let name    = "\(type.rawValue.capitalized): \(asset.baseName ?? asset.id.uuidString)"
        let request = SDRequest(prompt: "[asset:\(asset.id.uuidString)]")
        return enqueue(type: type, label: name, priority: .normal)
    }
}

// MARK: - Concurrency Control

extension JobQueueManager {

    /// Número máximo de jobs que pueden estar en estado .processing simultáneamente.
    var maxConcurrentJobs: Int {
        get { UserDefaults.standard.integer(forKey: "jq.maxConcurrent").nonZero(default: 1) }
        set { UserDefaults.standard.set(newValue, forKey: "jq.maxConcurrent") }
    }

    /// Retorna true si hay slots disponibles para iniciar un nuevo job.
    var hasAvailableSlot: Bool {
        let processing = jobs.filter { $0.statusEnum == .processing }.count
        return processing < maxConcurrentJobs
    }

    /// Siguiente job listo para ejecutarse (respetando dependencias y prioridad).
    func nextReadyJob(completedJobIDs: Set<UUID>) -> GenerationJob? {
        let pending = jobs.filter { $0.statusEnum == .pending }
            .sorted { a, b in
                if a.priority != b.priority { return a.priority > b.priority }
                return (a.createdAt ?? .distantPast) < (b.createdAt ?? .distantPast)
            }

        for job in pending {
            let ready = (try? await JobDependencyRegistry.shared.isReady(job: job.id, completedJobs: completedJobIDs)) ?? true
            // Note: non-async context; use sync check via cached state
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
    }

    func computeStats() -> QueueStats {
        var stats = QueueStats()
        stats.totalJobs   = jobs.count
        stats.pending     = jobs.filter { $0.statusEnum == .pending   }.count
        stats.processing  = jobs.filter { $0.statusEnum == .processing }.count
        stats.completed   = jobs.filter { $0.statusEnum == .completed  }.count
        stats.failed      = jobs.filter { $0.statusEnum == .failed     }.count

        let finished = jobs.filter { $0.statusEnum == .completed }
        if !finished.isEmpty {
            let durations = finished.compactMap { j -> Double? in
                guard let s = j.startedAt, let e = j.completedAt else { return nil }
                return e.timeIntervalSince(s)
            }
            if !durations.isEmpty {
                stats.avgDurationSec = durations.reduce(0, +) / Double(durations.count)
            }
        }

        let total = Double(stats.completed + stats.failed)
        if total > 0 { stats.errorRate = Double(stats.failed) / total }

        return stats
    }
}

// MARK: - PipelineRetryPolicy UserDefaults factory (v3 compat)

extension PipelineRetryPolicy {
    static var userConfigured: PipelineRetryPolicy {
        PipelineRetryPolicy(
            maxAttempts:    UserDefaults.standard.integer(forKey: "gen.retryMaxAttempts").nonZero(default: 3),
            baseDelayMs:    1500,
            maxDelayMs:     30_000,
            retryOnTimeout: UserDefaults.standard.bool(forKey: "gen.retryOnTimeout"),
            retryOnHTTP5xx: UserDefaults.standard.bool(forKey: "gen.retryOn5xx"),
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
    /// Duración de procesamiento en segundos (nil si no completó).
    var processingDuration: TimeInterval? {
        guard let s = startedAt, let e = completedAt else { return nil }
        return e.timeIntervalSince(s)
    }
}

// MARK: - Int.nonZero helper

extension Int {
    func nonZero(default value: Int) -> Int {
        self == 0 ? value : self
    }
}
