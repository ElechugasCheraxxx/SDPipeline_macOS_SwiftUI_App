import SwiftUI
import AppKit

// MARK: - JobQueueView
// Vista simple de la cola de trabajos, integrada con JobQueueManager.

struct JobQueueView: View {

    @StateObject private var queue = JobQueueManager.shared

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: "#7c6af7"))
                Text("Cola de Trabajos")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Button(action: { queue.pauseQueue() }) {
                    Image(systemName: queue.isPaused ? "play.circle.fill" : "pause.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(queue.isPaused ? Color(hex: "#3de3c0") : .secondary)
                }
                .buttonStyle(.plain)
                .help(queue.isPaused ? "Reanudar cola" : "Pausar cola")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color.white.opacity(0.03))

            Divider().background(Color.white.opacity(0.06))

            // Stats
            HStack(spacing: 16) {
                statItem("En cola", "\(queue.totalQueued)", color: "#7c6af7")
                statItem("Ejecutando", "\(queue.runningJobs.count)", color: "#f59e0b")
                statItem("Completados", "\(queue.totalCompleted)", color: "#34d399")
                statItem("Fallidos", "\(queue.totalFailed)", color: "#ef4444")
            }
            .padding(10)

            Divider().background(Color.white.opacity(0.06))

            // Lista de trabajos
            if queue.jobs.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.white.opacity(0.1))
                    Text("No hay trabajos en la cola")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(queue.jobs) { job in
                            JobQueueRow(job: job, onCancel: {
                                queue.cancel(jobID: job.id)
                            }, onRetry: {
                                queue.retry(jobID: job.id)
                            })
                            Divider().background(Color.white.opacity(0.04))
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
    }

    @ViewBuilder
    func statItem(_ label: String, _ value: String, color: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundColor(Color(hex: color))
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - JobQueueRow

struct JobQueueRow: View {

    let job:      JobQueueManager.GenerationJob
    var onCancel: () -> Void
    var onRetry:  () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // Icono de estado
            Image(systemName: job.statusIcon)
                .font(.system(size: 12))
                .foregroundColor(Color(hex: job.status.hexColor))

            // Detalles
            VStack(alignment: .leading, spacing: 2) {
                Text(job.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("\(job.priority.label)")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    if job.status == .running, let started = job.startedAt {
                        Text("• \(Int(-started.timeIntervalSinceNow))s")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    if job.status == .done, let finished = job.finishedAt {
                        Text("• \(Int(finished.timeIntervalSince(job.startedAt ?? finished)))s")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            // Acciones
            if job.status == .running {
                Button(action: onCancel) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "#ef4444"))
                }
                .buttonStyle(.plain)
            } else if job.status == .failed {
                Button(action: onRetry) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "#f59e0b"))
                }
                .buttonStyle(.plain)
            } else if job.status == .queued {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Color.white.opacity(0.02))
        .cornerRadius(6)
    }
}
