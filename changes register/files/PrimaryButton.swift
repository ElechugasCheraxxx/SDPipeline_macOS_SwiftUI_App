import SwiftUI

// ══════════════════════════════════════════════════════
//  PrimaryButton.swift — DesignSystem · Components · Buttons
// ══════════════════════════════════════════════════════

public struct PrimaryButton: View {
    let label: String
    let action: () -> Void

    @State private var isHovering = false
    @State private var isPressed  = false

    public init(label: String, action: @escaping () -> Void) {
        self.label  = label
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(DSColors.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(isPressed
                              ? DSColors.statePressed
                              : isHovering
                                ? DSColors.stateHover
                                : DSColors.brandPrimary)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color.white.opacity(isHovering ? 0.35 : 0.0), lineWidth: 1)
                )
                .shadow(
                    color: DSColors.stateGlow.opacity(isHovering ? 1.0 : 0.4),
                    radius: isHovering ? 12 : 4,
                    x: 0, y: 0
                )
                .scaleEffect(isPressed ? 0.95 : 1.0)
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .animation(.easeOut(duration: 0.08), value: isPressed)
        .onHover { h in isHovering = h }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded   { _ in isPressed = false }
        )
    }
}

#Preview {
    PrimaryButton(label: "Funcion_1") {}
        .frame(width: 160)
        .padding()
        .background(Color.black)
}
