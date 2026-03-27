import Foundation
import SwiftUI

// MARK: - JobQueueManager_Extensions.swift v3
//
// Puente de compatibilidad entre JobQueueManager (GenerationJob) y
// el resto del codebase que usaba el API anterior (QueueJob/enqueue by type).
// NO redeclara nada ya en JobQueueManager.swift.

// MARK: - QueueJob compatibility shim
// Algunos archivos (SDPipelineApp, GalleryView) referencian QueueJob.
// Se provee como typealias apuntando a GenerationJob para zero-breaking.

typealias QueueJob  = JobQueueManager.GenerationJob
typealias JobPriority = JobQueueManager.JobPriority

// MARK: - cancel(job:) by value

extension JobQueueManager {
    func cancel(job: GenerationJob) {
        cancel(jobID: job.id)
    }
}

// MARK: - enqueue by type (backward-compat with old API)

extension JobQueueManager {

    enum JobType: String, Codable {
        case generation = "generation"
        case export     = "export"
        case backup     = "backup"
        case integrity  = "integrity"
    }

    /// Legacy convenience enqueue used by SDPipelineApp and some Views.
    @discardableResult
    func enqueue(
        type:     JobType,
        label:    String          = "",
        title:    String          = "",
        priority: JobPriority     = .normal,
        metadata: [String: String] = [:]
    ) -> GenerationJob {
        let name = label.isEmpty ? title : label
        // For non-generation types, use a placeholder request
        let placeholderRequest = SDRequest(prompt: "[\(type.rawValue)]")
        let job = GenerationJob(
            name:     name.isEmpty ? type.rawValue.capitalized : name,
            request:  placeholderRequest,
            settings: .default,
            priority: priority
        )
        enqueue(job)
        return job
    }
}

// MARK: - Asset-based job creation (CORREGIDO)

extension JobQueueManager {

    /// Create and enqueue an export job for a specific asset.
    @discardableResult
    func enqueueExport(for asset: GeneratedAsset, priority: JobPriority = .normal) -> GenerationJob {
        let job = GenerationJob(
            name:       "Export · \(asset.displayTitle)",
            request:    SDRequest(prompt: "[export]"),
            settings:   .default,
            priority:   priority,
            sessionTag: asset.sessionTag
        )
        enqueue(job)
        return job
    }

    /// Enqueue a scheduled backup job.
    @discardableResult
    func enqueueScheduledBackup(priority: JobPriority = .low) -> GenerationJob {
        let job = GenerationJob(
            name:     "Backup · \(Date().shortDisplay)",
            request:  SDRequest(prompt: "[backup]"),
            settings: .default,
            priority: priority
        )
        enqueue(job)
        return job
    }

    /// Enqueue an integrity scan job.
    @discardableResult
    func enqueueIntegrityScan() -> GenerationJob {
        let job = GenerationJob(
            name:     "Integrity Scan",
            request:  SDRequest(prompt: "[integrity]"),
            settings: .default,
            priority: .low
        )
        enqueue(job)
        return job
    }
}

// MARK: - clearCompleted / pause / resume (backward-compat names)

extension JobQueueManager {

    func clearCompleted() { clearHistory() }

    var isPaused: Bool { !isProcessing }

    func pause()  { pauseQueue()  }
    func resume() { startQueue()  }

    func cancelAll() {
        for job in jobs where job.status == .queued || job.status == .running {
            cancel(jobID: job.id)
        }
    }

    func processNext() {
        // No-op externally; internal processing handled by processQueueIfNeeded()
        startQueue()
    }
}

// MARK: - QueueJob convenience static factories

extension JobQueueManager.GenerationJob {

    static func exportJob(for asset: GeneratedAsset, priority: JobPriority = .normal) -> JobQueueManager.GenerationJob {
        JobQueueManager.GenerationJob(
            name:       "Export: \(asset.displayTitle)",
            request:    SDRequest(prompt: "[export-only]"),
            settings:   .default,
            priority:   priority,
            sessionTag: asset.sessionTag
        )
    }

    static func backupJob(priority: JobPriority = .low) -> JobQueueManager.GenerationJob {
        JobQueueManager.GenerationJob(
            name:    "Backup · \(Date().shortDisplay)",
            request: SDRequest(prompt: "[backup]"),
            settings: .default,
            priority: priority
        )
    }
}

// MARK: - QueueJob.label compatibility
// Old code used job.label — map to job.name

extension JobQueueManager.GenerationJob {
    var label: String { name }
}

// MARK: - GenerationSettings ← JobSettings bridge (v5)

extension GenerationSettings {
    /// Construye un GenerationSettings proxy desde un JobSettings.
    /// Permite que executeJob use buildRequestWithScripts (ControlNet/IPAdapter/ADetailer).
    static func fromJobSettings(_ js: JobQueueManager.JobSettings, baseURL: String) -> GenerationSettings {
        var s = GenerationSettings()
        s.sdBaseURL = baseURL
        // Los engines activos se leen desde sus singletons (IPAdapterEngine.shared, etc.)
        // No necesitamos copiar configuración — buildRequestWithScripts los lee directamente.
        return s
    }
}

// MARK: - AssetStore.fetchAsset(id:) bridge (v5)

extension AssetStore {
    func fetchAsset(id: UUID) -> GeneratedAsset? {
        fetchAllAssets(limit: 2000).first { $0.id == id }
    }
}

// MARK: - JobQueueManager stats helpers (v5)

extension JobQueueManager {

    /// Porcentaje de éxito formateado.
    var formattedSuccessRate: String {
        let s = stats.successRate
        return String(format: "%.0f%%", s * 100)
    }

    /// Jobs del batch actual (mismo batchID).
    func jobs(inBatch batchID: UUID) -> [GenerationJob] {
        jobs.filter { $0.batchID == batchID }
    }

    /// Progreso de un batch (0.0–1.0).
    func batchProgress(_ batchID: UUID) -> Double {
        let batch = jobs(inBatch: batchID)
        guard !batch.isEmpty else { return 0 }
        let done = batch.filter { $0.status == .done || $0.status == .failed || $0.status == .cancelled }.count
        return Double(done) / Double(batch.count)
    }

    /// ETA del batch en segundos.
    func batchETA(_ batchID: UUID) -> Int {
        let batch   = jobs(inBatch: batchID)
        let pending = batch.filter { $0.status == .queued || $0.status == .running }.count
        let avg     = averageJobDuration ?? 60
        return pending * Int(avg)
    }

    private var averageJobDuration: Double? {
        let done = completedJobs.filter { $0.startedAt != nil && $0.finishedAt != nil }
        guard !done.isEmpty else { return nil }
        let total = done.reduce(0.0) { $0 + $1.finishedAt!.timeIntervalSince($1.startedAt!) }
        return total / Double(done.count)
    }

    /// Encola un batch completo desde BatchEngine.BatchJob items con PipelineRetryPolicy.
    @discardableResult
    func enqueueBatchItems(
        _ items:    [BatchEngine.BatchItem],
        baseURL:    String,
        priority:   JobPriority     = .normal,
        policy:     PipelineRetryPolicy = .default,
        sessionTag: String?         = nil
    ) -> UUID {
        let batchID = UUID()
        let settings = GenerationJob.JobSettings(
            baseURL:          baseURL,
            autoExport:       true,
            autoNSFWCheck:    NSFWDetector.shared.config.autoCheck,
            postProcessing:   false,
            useAtomicSave:    true,
            maxRetryAttempts: policy.maxAttempts,
            retryDelayBase:   policy.baseDelayMs
        )
        for item in items {
            let req = SDRequest(
                prompt:         item.prompt,
                negativePrompt: item.negativePrompt,
                seed:           item.seed,
                steps:          item.steps,
                cfgScale:       item.cfgScale,
                width:          item.width,
                height:         item.height,
                samplerName:    item.samplerName
            )
            let job = GenerationJob(
                name:       item.label.isEmpty ? "Batch item" : item.label,
                request:    req,
                settings:   settings,
                priority:   priority,
                sessionTag: sessionTag,
                batchID:    batchID
            )
            jobs.append(job)
        }
        persistQueue()
        processQueueIfNeeded()
        ZeroKnowledgeLog.shared.write(
            category: .systemEvent,
            message:  "Batch enqueued: \\(items.count) items · batchID:\\(batchID.uuidString.prefix(8))"
        )
        return batchID
    }
}
