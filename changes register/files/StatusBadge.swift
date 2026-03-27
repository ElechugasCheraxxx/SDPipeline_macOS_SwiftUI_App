import SwiftUI

// ══════════════════════════════════════════════════════
//  StatusBadge.swift — DesignSystem · Components · Feedback
// ══════════════════════════════════════════════════════

public struct StatusBadge: View {
    let text: String

    public init(text: String) {
        self.text = text
    }

    public var body: some View {
        HStack(spacing: 5) {
            Text("Status:")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(DSColors.textPrimary)

            Text(text)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundColor(DSColors.textAccent)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(DSColors.backgroundMuted)
    }
}

#Preview {
    StatusBadge(text: "Funcion_1 ejecutada")
        .frame(width: 360)
}
