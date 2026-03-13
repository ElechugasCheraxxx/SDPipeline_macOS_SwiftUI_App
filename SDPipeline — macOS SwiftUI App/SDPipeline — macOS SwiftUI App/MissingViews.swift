import SwiftUI
import AppKit
import CoreImage

// MARK: - MissingViews v4
// Contiene:
//   • IPAdapterModel alias (puente al enum de IPAdapterEngine)
//   • CharacterProfile.baseImagePath helper (puente a UserDefaults)
//   • ZeroKnowledgeLogView compatibility shim
//   • CIImage init helper para steg verification

// MARK: - IPAdapterModel typealias
// Puente para archivos que referencian IPAdapterModel directamente.

typealias IPAdapterModel = IPAdapterEngine.IPAdapterModel

// MARK: - CIImage steg helper

extension CIImage {
    convenience init?(nsImage: NSImage) {
        guard let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        self.init(cgImage: cgImage)
    }
}

// MARK: - ZeroKnowledgeLog category filter

extension ZeroKnowledgeLog {
    func entries(category: LogCategory) -> [LogEntry] {
        entries(limit: 1000).filter { $0.category == category }
    }
}
