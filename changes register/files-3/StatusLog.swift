import SwiftUI

// ══════════════════════════════════════════════════════
//  StatusLog.swift
//  DesignSystem/Components/Feedback/
//
//  Reemplaza StatusBadge. Muestra historial de mensajes.
// ══════════════════════════════════════════════════════

struct StatusLogEntry: Identifiable {
    let id   = UUID()
    let text : String
    let type : EntryType
    let time : Date = .now

    enum EntryType {
        case info, success, failure, loading

        var color: Color {
            switch self {
            case .info:    return Color(white: 0.6)
            case .success: return Color(red: 0.0, green: 0.9, blue: 0.5)
            case .failure: return Color(red: 1.0, green: 0.3, blue: 0.3)
            case .loading: return Color(red: 1.0, green: 0.0, blue: 0.87)
            }
        }

        var prefix: String {
            switch self {
            case .info:    return "›"
            case .success: return "✓"
            case .failure: return "✗"
            case .loading: return "⟳"
            }
        }
    }

    var timeString: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: time)
    }
}

struct StatusLog: View {
    let entries: [StatusLogEntry]
    @State private var isExpanded = false

    var latest: StatusLogEntry? { entries.last }

    var body: some View {
        VStack(spacing: 0) {

            // ── Línea superior sutil ───────────────────
            Rectangle()
                .fill(Color(red: 1.0, green: 0.0, blue: 0.87).opacity(0.3))
                .frame(height: 1)

            // ── Barra de status (siempre visible) ──────
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() } }) {
                HStack(spacing: 6) {
                    Text("Status:")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)

                    if let latest = latest {
                        Text(latest.type.prefix)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(latest.type.color)

                        Text(latest.text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(latest.type.color)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } else {
                        Text("xxxxxxxxxxx")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Color(red: 1.0, green: 0.0, blue: 0.87))
                    }

                    Spacer()

                    // Contador de entradas + flecha
                    if entries.count > 0 {
                        Text("\(entries.count)")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(.black)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color(red: 1.0, green: 0.0, blue: 0.87))
                            .clipShape(Capsule())
                    }

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Color(white: 0.4))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color(white: 0.05))
            }
            .buttonStyle(.plain)

            // ── Log expandible ─────────────────────────
            if isExpanded {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(entries) { entry in
                                HStack(alignment: .top, spacing: 6) {
                                    Text(entry.timeString)
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundColor(Color(white: 0.3))
                                        .frame(width: 54, alignment: .leading)

                                    Text(entry.type.prefix)
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .foregroundColor(entry.type.color)
                                        .frame(width: 10)

                                    Text(entry.text)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(entry.type.color.opacity(0.9))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 3)
                                .id(entry.id)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .frame(height: min(CGFloat(entries.count) * 22 + 12, 120))
                    .background(Color(white: 0.04))
                    .onChange(of: entries.count) { _ in
                        if let last = entries.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }

                Rectangle()
                    .fill(Color(red: 1.0, green: 0.0, blue: 0.87).opacity(0.2))
                    .frame(height: 1)
            }
        }
    }
}

#Preview {
    StatusLog(entries: [
        StatusLogEntry(text: "Iniciando...",             type: .info),
        StatusLogEntry(text: "Abriendo BlueStacks",      type: .loading),
        StatusLogEntry(text: "Conectando ADB",           type: .loading),
        StatusLogEntry(text: "Free Fire iniciado ✓",     type: .success),
    ])
    .frame(width: 360)
    .background(Color.black)
}
