import Foundation
import SwiftUI
import Combine

// MARK: - JobQueueManager Extensions
// Métodos referenciados en Views y SDPipelineApp que deben existir:
//   - pause() / resume() / isPaused
//   - cancel(job:)
//   - clearCompleted()
//   - enqueue(_ job:)
//   - cancel(job:) por QueueJob

// These extensions add the missing API surface that JobQueueView
// and SDPipelineApp reference. The core JobQueueManager class is
// assumed to be in JobQueueManager.swift with the base properties.

extension JobQueueManager {

    // MARK: - Missing methods (add if not present in base class)

    /// Encolar un QueueJob ya construido.
    func enqueue(_ job: QueueJob) {
        // Append to queue ordered by priority (highest first)
        var mutableQueue = queue
        let insertIdx = mutableQueue.firstIndex(where: { $0.priority < job.priority }) ?? mutableQueue.endIndex
        mutableQueue.insert(job, at: insertIdx)
        queue = mutableQueue
        persistQueue()
        processNextIfPossible()
    }

    /// Cancelar un job específico por referencia.
    func cancel(job: QueueJob) {
        guard let idx = queue.firstIndex(where: { $0.id == job.id }) else { return }
        queue[idx].status = .cancelled
        persistQueue()
    }

    /// Limpiar todos los jobs completados de la cola visible.
    func clearCompleted() {
        queue.removeAll { $0.status == .completed || $0.status == .cancelled }
        persistQueue()
    }

    /// Proceso interno — continuar con siguiente job si hay capacidad.
    internal func processNextIfPossible() {
        guard !isPaused else { return }
        let runningCount = queue.filter { $0.status == .running }.count
        guard runningCount < maxConcurrentWorkers else { return }
        guard let nextIdx = queue.firstIndex(where: { $0.status == .queued }) else { return }
        queue[nextIdx].status = .running
        queue[nextIdx].startedAt = Date()
        executeJob(queue[nextIdx])
    }

    /// Ejecutar un job — delega según el tipo.
    private func executeJob(_ job: QueueJob) {
        Task { @MainActor in
            guard let idx = queue.firstIndex(where: { $0.id == job.id }) else { return }

            do {
                switch job.type {
                case .export:
                    if let assetIDStr = job.metadata["assetID"],
                       let assetID = UUID(uuidString: assetIDStr) {
                        let ctx = AssetStore.shared.container.viewContext
                        let request = GeneratedAsset.fetchRequest()
                        request.predicate = NSPredicate(format: "id == %@", assetID as CVarArg)
                        if let asset = try? ctx.fetch(request).first {
                            _ = try await ExportEngine.shared.export(asset: asset, addWatermark: true)
                        }
                    }

                case .backup:
                    await BackupManager.shared.runAllBackups()

                case .singleGeneration, .batchGeneration, .postProduction, .xyPlot:
                    // These are handled by their respective engines
                    // Queue just tracks status — actual execution is triggered elsewhere
                    try await Task.sleep(for: .seconds(0.1))
                }

                queue[idx].status      = .completed
                queue[idx].completedAt = Date()
                queue[idx].progress    = 1.0

            } catch {
                if queue[idx].retryCount < queue[idx].maxRetries {
                    queue[idx].retryCount   += 1
                    queue[idx].status        = .queued
                    queue[idx].errorMessage  = error.localizedDescription
                } else {
                    queue[idx].status        = .failed
                    queue[idx].errorMessage  = error.localizedDescription
                    queue[idx].completedAt   = Date()
                }
            }

            persistQueue()
            // Process next job
            processNextIfPossible()
        }
    }

    // MARK: - Persistence helper

    internal func persistQueue() {
        guard let url = queuePersistenceURL else { return }
        let persistable = queue.filter { $0.status != .completed && $0.status != .cancelled }
        if let data = try? JSONEncoder.pretty.encode(persistable) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private var queuePersistenceURL: URL? {
        VaultManager.shared.vaultMetaURL?.appending(path: "job_queue.json")
    }
}

// MARK: - QueueJob convenience initializers

extension QueueJob {
    static func exportJob(for asset: GeneratedAsset, priority: JobPriority = .normal) -> QueueJob {
        QueueJob(
            type:     .export,
            title:    "Export: \(asset.baseName ?? "asset")",
            priority: priority,
            metadata: ["assetID": asset.id?.uuidString ?? ""]
        )
    }

    static func backupJob(priority: JobPriority = .low) -> QueueJob {
        QueueJob(
            type:     .backup,
            title:    "Backup automático · \(Date().shortDisplay)",
            priority: priority
        )
    }
}
