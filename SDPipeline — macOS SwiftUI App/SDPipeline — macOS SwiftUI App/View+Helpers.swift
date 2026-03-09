import SwiftUI
import Foundation

// MARK: - View + Helpers

extension View {

    /// Aplica un modificador condicionalmente sin romper el type system.
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition { transform(self) } else { self }
    }
}

// MARK: - String + Helpers

extension String {

    /// Truncar con elipsis si supera `maxLength` caracteres.
    func truncated(_ maxLength: Int) -> String {
        count > maxLength ? String(prefix(maxLength)) + "…" : self
    }
}

// MARK: - Date + Helpers

extension Date {

    /// Formato corto legible: "12 mar · 14:32"
    var shortDisplay: String {
        let f = DateFormatter()
        f.dateFormat = "d MMM · HH:mm"
        return f.string(from: self)
    }

    /// Formato para nombre de archivo: "2025-03-12"
    var filenameDate: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: self)
    }
}
