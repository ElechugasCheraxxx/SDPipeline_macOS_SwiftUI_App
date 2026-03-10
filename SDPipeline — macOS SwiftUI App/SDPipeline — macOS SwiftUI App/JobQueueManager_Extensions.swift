import Foundation
import SwiftUI

// MARK: - JobQueueManager_Extensions.swift
//
// Adds missing API surface that Views reference.
// Does NOT redeclare anything already in JobQueueManager.swift.
//
// Already in JobQueueManager.swift (DO NOT redeclare):
//   clearCompleted(), pause(), resume(), isPaused, completedJobs
//   processNext(), enqueueAllPendingExports(), enqueueScheduledBackup()
//   cancel(jobID:), cancelAll()

// MARK: - cancel(job:) — wrapper over cancel(jobID:)

extension JobQueueManager {
    func cancel(job: QueueJob) {
        cancel(jobID: job.id)
    }
}

// MARK: - enqueue(_ job:) — accepts pre-built QueueJob

extension JobQueueManager {
    @discardableResult
    func enqueue(_ job: QueueJob) -> QueueJob {
        return enqueue(
            type:     job.type,
            label:    job.label,
            priority: job.priority,
            metadata: job.metadata
        )
    }
}

// MARK: - QueueJob convenience initializers

extension QueueJob {
    static func exportJob(for asset: GeneratedAsset, priority: JobPriority = .normal) -> QueueJob {
        QueueJob(
            type:     .export,
            label:    "Export: \(asset.baseName ?? "asset")",
            priority: priority,
            metadata: ["asset_id": asset.id?.uuidString ?? ""]
        )
    }

    static func backupJob(priority: JobPriority = .low) -> QueueJob {
        QueueJob(
            type:     .backup,
            label:    "Backup · \(Date().shortDisplay)",
            priority: priority
        )
    }
}
