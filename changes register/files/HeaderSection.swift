import SwiftUI
import AppKit

// ══════════════════════════════════════════════════════
//  HeaderSection.swift — Features · Home · Components
// ══════════════════════════════════════════════════════

struct HeaderSection: View {
    @State private var hoverIcon: String? = nil

    var body: some View {
        HStack(spacing: 0) {

            // ── Logo + Título ──────────────────────────
            HStack(spacing: 6) {
                if let img = NSImage(named: "Blackcompany-logo") {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                        .colorMultiply(.white)
                } else {
                    Image(systemName: "b.square.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(DSColors.textPrimary)
                }

                HStack(spacing: 0) {
                    Text("BLACK COMPANY")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundColor(DSColors.textPrimary)
                        .tracking(1.5)
                    Text(" | ")
                        .foregroundColor(DSColors.brandPrimary)
                        .font(.system(size: 11, weight: .heavy))
                    Text("V3")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundColor(DSColors.brandPrimary)
                        .tracking(1)
                }
            }

            Spacer()

            // ── Iconos sociales ────────────────────────
            HStack(spacing: 14) {
                HeaderIconButton(systemName: "music.note",     id: "tt",   hoverIcon: $hoverIcon, url: "https://tiktok.com")
                HeaderIconButton(systemName: "camera",         id: "ig",   hoverIcon: $hoverIcon, url: "https://instagram.com")
                HeaderIconButton(systemName: "gamecontroller", id: "dc",   hoverIcon: $hoverIcon, url: "https://discord.com")

                Rectangle()
                    .fill(Color.white.opacity(0.2))
                    .frame(width: 1, height: 14)

                HeaderIconButton(
                    systemName: "rectangle.portrait.and.arrow.right",
                    id: "exit",
                    hoverIcon: $hoverIcon,
                    url: nil,
                    isExit: true
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(DSColors.backgroundSurface)
    }
}

// ── Sub-componente: icono del header ──────────────────
private struct HeaderIconButton: View {
    let systemName: String
    let id: String
    @Binding var hoverIcon: String?
    let url: String?
    var isExit: Bool = false

    var isHovering: Bool { hoverIcon == id }

    var body: some View {
        Button(action: {
            if isExit {
                NSApplication.shared.terminate(nil)
            } else if let u = url, let link = URL(string: u) {
                NSWorkspace.shared.open(link)
            }
        }) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isHovering ? DSColors.brandPrimary : DSColors.textPrimary)
                .animation(.easeOut(duration: 0.15), value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { h in hoverIcon = h ? id : nil }
    }
}

#Preview {
    HeaderSection()
        .frame(width: 360)
        .background(Color.black)
}
