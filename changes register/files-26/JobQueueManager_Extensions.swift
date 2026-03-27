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

// MARK: - Asset-based job creation

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
        return enqueue(job)
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
        return enqueue(job)
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
        return enqueue(job)
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
