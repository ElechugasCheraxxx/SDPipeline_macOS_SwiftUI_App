import SwiftUI
import AppKit

// MARK: - JobQueueView
// Vista de la cola de trabajos referenciada en RightPanelView tab "Cola".

struct JobQueueView: View {

    @StateObject private var queue = JobQueueManager.shared

    var body: some View {
        VStack(spacing: 0) {
            queueHeader
            Divider().background(Color.white.opacity(0.06))

            if queue.queue.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(queue.queue) { job in
                            JobRowView(job: job)
                            Divider().background(Color.white.opacity(0.03))
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Divider().background(Color.white.opacity(0.06))
            queueFooter
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
    }

    var queueHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "list.bullet.rectangle.portrait")
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "#7c6af7"))
            Text("Cola de Jobs")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)

            let running = queue.queue.filter { $0.status == .running }.count
            let pending  = queue.queue.filter { $0.status == .queued }.count
            if running + pending > 0 {
                Text("\(running) activos · \(pending) en espera")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Pause/Resume
            Button(action: { queue.isPaused ? queue.resume() : queue.pause() }) {
                Image(systemName: queue.isPaused ? "play.circle.fill" : "pause.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(queue.isPaused ? Color(hex: "#34d399") : .secondary)
            }.buttonStyle(.plain)

            // Cancel all
            if !queue.queue.isEmpty {
                Button(action: { queue.cancelAll() }) {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 13))
                        .foregroundColor(Color(hex: "#ef4444").opacity(0.7))
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.white.opacity(0.03))
    }

    var queueFooter: some View {
        HStack(spacing: 12) {
            let done     = queue.queue.filter { $0.status == .completed }.count
            let failed   = queue.queue.filter { $0.status == .failed }.count
            let total    = queue.queue.count

            statChip("\(done)/\(total)", "Completados", color: "#34d399")
            statChip("\(failed)", "Fallidos", color: "#ef4444")

            Spacer()

            if done > 0 {
                Button("Limpiar completados") {
                    queue.clearCompleted()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Color.white.opacity(0.02))
    }

    var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 28))
                .foregroundColor(.white.opacity(0.1))
            Text("Cola vacía")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Text("Los jobs aparecen aquí cuando usas Batch o X/Y Plot")
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.6))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    func statChip(_ value: String, _ label: String, color: String) -> some View {
        HStack(spacing: 3) {
            Text(value)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(Color(hex: color))
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - JobRowView

struct JobRowView: View {
    let job: QueueJob
    @StateObject private var queue = JobQueueManager.shared

    var statusColor: Color {
        switch job.status {
        case .queued:    return Color(hex: "#6b7280")
        case .running:   return Color(hex: "#7c6af7")
        case .completed: return Color(hex: "#34d399")
        case .failed:    return Color(hex: "#ef4444")
        case .cancelled: return Color(hex: "#f59e0b")
        }
    }

    var statusIcon: String {
        switch job.status {
        case .queued:    return "clock"
        case .running:   return "arrow.triangle.2.circlepath"
        case .completed: return "checkmark.circle.fill"
        case .failed:    return "exclamationmark.circle.fill"
        case .cancelled: return "xmark.circle"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            // Status indicator
            Image(systemName: statusIcon)
                .font(.system(size: 11))
                .foregroundColor(statusColor)
                .frame(width: 18)
                .symbolEffect(.rotate, isActive: job.status == .running)

            // Job info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(job.type.rawValue)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                    priorityBadge
                }
                Text(job.title.truncated(55))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                if job.status == .running, let progress = job.progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(Color(hex: "#7c6af7"))
                        .frame(maxWidth: 180)
                }

                if job.status == .failed, let err = job.errorMessage {
                    Text(err.truncated(50))
                        .font(.system(size: 9))
                        .foregroundColor(Color(hex: "#ef4444"))
                }
            }

            Spacer()

            // Retry count
            if job.retryCount > 0 {
                Text("×\(job.retryCount)")
                    .font(.system(size: 9))
                    .foregroundColor(Color(hex: "#f59e0b"))
            }

            // Cancel button
            if job.status == .queued || job.status == .running {
                Button(action: { queue.cancel(job: job) }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary.opacity(0.6))
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    var priorityBadge: some View {
        Text(job.priority.label)
            .font(.system(size: 8, weight: .medium))
            .foregroundColor(Color(hex: job.priority.color))
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(Color(hex: job.priority.color).opacity(0.12))
            .cornerRadius(3)
    }
}

// MARK: - StudioPublishView
// Wrapper de PublishView para usar en el tab "Publicar" del RightPanelView.
// Recibe el array de imágenes generadas en la sesión actual.

struct StudioPublishView: View {
    let images: [NSImage]

    @StateObject private var engine  = PublishEngine.shared
    @StateObject private var session = ContentSessionManager.shared

    var body: some View {
        VStack(spacing: 0) {
            // Session context banner
            if let active = session.activeSession {
                HStack(spacing: 8) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "#7c6af7"))
                    Text("Sesión activa: \(active.title)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                    Spacer()
                    Text("\(active.assetCount) assets")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Color(hex: "#7c6af7").opacity(0.08))

                Divider().background(Color.white.opacity(0.05))
            }

            // Image count banner
            HStack(spacing: 6) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text(images.isEmpty
                     ? "No hay imágenes en esta sesión"
                     : "\(images.count) imagen\(images.count == 1 ? "" : "es") listas para publicar")
                    .font(.system(size: 11))
                    .foregroundColor(images.isEmpty ? .secondary : .white.opacity(0.75))
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.white.opacity(0.02))

            Divider().background(Color.white.opacity(0.05))

            if images.isEmpty {
                emptyPublishState
            } else {
                PublishView()
            }
        }
    }

    var emptyPublishState: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.up.to.line.circle")
                .font(.system(size: 36))
                .foregroundColor(.white.opacity(0.08))
            Text("Genera imágenes primero")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.3))
            Text("Las imágenes generadas en el tab Output aparecerán aquí para publicar.")
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.6))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 220)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }
}

// MARK: - NewSessionSheet
// Sheet para crear una nueva sesión de contenido.
// Referenciado en ContentView y SDPipelineApp.

struct NewSessionSheet: View {

    var onCreate: (String, ContentSessionManager.SessionCategory) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title:       String = ""
    @State private var description: String = ""
    @State private var category:    ContentSessionManager.SessionCategory = .editorial
    @State private var platform:    ContentSessionManager.TargetPlatform  = .onlyfans
    @State private var targetCount: Int    = 20

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "film.stack.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color(hex: "#7c6af7"), Color(hex: "#3de3c0")],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text("Nueva Sesión de Contenido")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                    Text("Agrupa tus generaciones por temática o shoot")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(20)
            .background(Color.white.opacity(0.03))

            Divider().background(Color.white.opacity(0.08))

            ScrollView {
                VStack(spacing: 16) {

                    // Título
                    field("Nombre de la sesión", required: true) {
                        TextField("Ej: Beach Editorial Marzo 2025", text: $title)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                    }

                    // Categoría
                    field("Categoría") {
                        Picker("", selection: $category) {
                            ForEach(ContentSessionManager.SessionCategory.allCases, id: \.self) {
                                Label($0.rawValue, systemImage: $0.icon).tag($0)
                            }
                        }
                        .pickerStyle(.menu)
                        .font(.system(size: 12))
                    }

                    // Plataforma
                    field("Plataforma objetivo") {
                        Picker("", selection: $platform) {
                            ForEach(ContentSessionManager.TargetPlatform.allCases, id: \.self) {
                                Text($0.rawValue).tag($0)
                            }
                        }
                        .pickerStyle(.segmented)
                        .font(.system(size: 11))
                    }

                    // Target count
                    field("Objetivo de assets") {
                        HStack {
                            Slider(value: Binding(
                                get: { Double(targetCount) },
                                set: { targetCount = Int($0) }
                            ), in: 5...100, step: 5)
                            Text("\(targetCount)")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundColor(Color(hex: "#7c6af7"))
                                .frame(width: 36)
                        }
                    }

                    // Descripción
                    field("Notas / referencias (opcional)") {
                        TextEditor(text: $description)
                            .font(.system(size: 11))
                            .scrollContentBackground(.hidden)
                            .background(Color.white.opacity(0.05))
                            .cornerRadius(6)
                            .frame(height: 70)
                    }
                }
                .padding(20)
            }

            Divider().background(Color.white.opacity(0.08))

            // Actions
            HStack {
                Button("Cancelar") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Crear Sesión") {
                    guard !title.isEmpty else { return }
                    onCreate(title, category)
                    dismiss()
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(title.isEmpty
                    ? Color.gray.opacity(0.3)
                    : LinearGradient(
                        colors: [Color(hex: "#7c6af7"), Color(hex: "#5b4ecf")],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                .foregroundColor(.white)
                .cornerRadius(8)
                .disabled(title.isEmpty)
            }
            .padding(20)
        }
        .frame(width: 440)
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
    }

    func field<Content: View>(_ label: String, required: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 3) {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                if required {
                    Text("*")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#ef4444"))
                }
            }
            content()
        }
    }
}

// MARK: - ContentSessionManager extensions for missing enums/funcs

extension ContentSessionManager {

    // SessionCategory extension for icon (used in NewSessionSheet)
    // These are assumed to exist in ContentSessionManager — adding safety extensions

    var sessionSummary: String {
        guard let s = activeSession else { return "Sin sesión activa" }
        return "\(s.title) · \(s.assetCount) assets"
    }
}

extension ContentSessionManager.SessionCategory {
    var icon: String {
        switch self {
        case .editorial:   return "photo.artframe"
        case .character:   return "person.crop.square"
        case .campaign:    return "megaphone"
        case .experimental: return "wand.and.sparkles"
        case .bts:         return "video"
        case .lifestyle:   return "figure.walk"
        }
    }
}
