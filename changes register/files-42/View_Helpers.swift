import SwiftUI
import AppKit

// MARK: - View_Helpers.swift (extended)
//
// El archivo ORIGINAL ya declara:
//   View.if(_:transform:)   → NO redeclarar
//   String.truncated(_:)    → NO redeclarar
//   Date.shortDisplay       → NO redeclarar
//   Date.filenameDate       → NO redeclarar
//
// Este archivo SOLO agrega componentes SwiftUI reutilizables y
// extensiones de View que NO existen en el original.

// MARK: - SectionCard

struct SectionCard<Content: View>: View {
    let title:   String
    let icon:    String
    let content: Content

    init(_ title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title   = title
        self.icon    = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10)).foregroundColor(.secondary)
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            content
        }
    }
}

// MARK: - StatPill

struct StatPill: View {
    let label: String
    let value: String
    var color: String = "#7c6af7"

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(Color(hex: color))
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color(hex: color).opacity(0.1))
        .cornerRadius(7)
    }
}

// MARK: - BadgeTag

struct BadgeTag: View {
    let text:   String
    var color:  String = "#6b7280"
    var filled: Bool   = false

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(filled ? .white : Color(hex: color))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(filled ? Color(hex: color) : Color(hex: color).opacity(0.15))
            .cornerRadius(4)
    }
}

// MARK: - RatingStars

struct RatingStars: View {
    let rating:      Int32
    var interactive: Bool = false
    var onRate:      ((Int) -> Void)? = nil
    var size:        CGFloat = 12

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: star <= Int(rating) ? "star.fill" : "star")
                    .font(.system(size: size))
                    .foregroundColor(star <= Int(rating) ? Color(hex: "#fbbf24") : .secondary)
                    .onTapGesture { if interactive { onRate?(star) } }
            }
        }
    }
}

// MARK: - StatusBadge

struct StatusBadge: View {
    let status: AssetStatus

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: status.icon).font(.system(size: 9))
            Text(status.rawValue).font(.system(size: 9, weight: .medium))
        }
        .foregroundColor(status.color)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(status.color.opacity(0.15))
        .cornerRadius(4)
    }
}

// MARK: - EmptyStateView

struct EmptyStateView: View {
    let icon:        String
    let title:       String
    let message:     String
    var action:      (() -> Void)? = nil
    var actionLabel: String        = "Get Started"

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundStyle(
                    LinearGradient(colors: [Color(hex: "#7c6af7"), Color(hex: "#3de3c0")],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            Text(title)
                .font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
            Text(message)
                .font(.system(size: 11)).foregroundColor(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 24)
            if let action {
                Button(action: action) {
                    Text(actionLabel)
                        .font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .background(Color(hex: "#7c6af7")).cornerRadius(7)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - LoadingOverlay

struct LoadingOverlay: View {
    let message:  String
    var progress: Double? = nil

    var body: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(Color(hex: "#7c6af7"))
                    .scaleEffect(1.2)
                Text(message)
                    .font(.system(size: 12)).foregroundColor(.white.opacity(0.8))
                if let p = progress {
                    ProgressView(value: p)
                        .progressViewStyle(.linear)
                        .tint(Color(hex: "#7c6af7"))
                        .frame(width: 160)
                    Text("\(Int(p * 100))%")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            .padding(20)
            .background(Color(red: 0.12, green: 0.12, blue: 0.16))
            .cornerRadius(14)
        }
    }
}

// MARK: - GradientHeader

struct GradientHeader: View {
    let title:    String
    let subtitle: String?
    var icon:     String? = nil

    var body: some View {
        HStack(spacing: 12) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundStyle(
                        LinearGradient(colors: [Color(hex: "#7c6af7"), Color(hex: "#3de3c0")],
                                       startPoint: .leading, endPoint: .trailing)
                    )
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .bold)).foregroundColor(.white)
                if let sub = subtitle {
                    Text(sub).font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
            Spacer()
        }
        .padding(20)
        .background(Color.white.opacity(0.03))
    }
}

// MARK: - CopyButton

struct CopyButton: View {
    let text:  String
    var label: String = "Copiar"

    @State private var copied = false

    var body: some View {
        Button(action: {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            withAnimation { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation { copied = false }
            }
        }) {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 10))
                Text(copied ? "Copiado" : label).font(.system(size: 10))
            }
            .foregroundColor(copied ? Color(hex: "#34d399") : .secondary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - View extensions (nuevas — NO redeclaran las del original)

extension View {

    /// Oculta visualmente pero mantiene el espacio en layout.
    func invisible(_ condition: Bool) -> some View {
        opacity(condition ? 0 : 1)
    }

    /// Card background con borde sutil.
    func cardBackground(radius: CGFloat = 8) -> some View {
        self
            .background(Color.white.opacity(0.04))
            .cornerRadius(radius)
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .stroke(Color.white.opacity(0.07), lineWidth: 1)
            )
    }

    /// Borde con color hex.
    func borderHex(_ color: String, width: CGFloat = 1, radius: CGFloat = 8) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: radius)
                .stroke(Color(hex: color), lineWidth: width)
        )
    }
}

// MARK: - IdentifiableUUID
/// Wraps UUID to make it Identifiable, needed for .popover(item:) bindings.
struct IdentifiableUUID: Identifiable {
    let id: UUID
    init(_ id: UUID) { self.id = id }
}
