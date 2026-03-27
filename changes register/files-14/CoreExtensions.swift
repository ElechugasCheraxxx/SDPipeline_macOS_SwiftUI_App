import SwiftUI
import AppKit
import Foundation

// MARK: - CoreExtensions.swift
//
// Archivo único que resuelve todas las dependencias de compilación compartidas:
//   1. Color(hex:) — usada en toda la UI
//   2. ReusableSettings — struct de transferencia entre GalleryView y pipeline
//   3. NSImage.pngData() — eliminada de AssetStore, centralizada aquí
//   4. NSImage.resized(maxDimension:) — centralizada aquí
//   5. JSONEncoder.pretty — centralizada aquí (eliminar de AssetStore)
//   6. Data.sha256Hex — centralizada aquí (eliminar de AssetStore)
//   7. NSColor helpers
//
// INSTRUCCIÓN: Eliminar de AssetStore.swift las definiciones de:
//   - pngData(), resized(), sha256Hex, JSONEncoder.pretty, JSONDecoder.iso8601
// Y dejar solo el import de CryptoKit allí si es necesario.

// MARK: - Color(hex:)
// Soporte de colores hexadecimales (#RRGGBB y #RRGGBBAA) para SwiftUI.

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255,
                            (int >> 8) * 17,
                            (int >> 4 & 0xF) * 17,
                            (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255,
                            int >> 16,
                            int >> 8 & 0xFF,
                            int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24,
                            int >> 16 & 0xFF,
                            int >> 8 & 0xFF,
                            int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red:     Double(r) / 255,
            green:   Double(g) / 255,
            blue:    Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - ReusableSettings
// Struct de transferencia cuando el usuario hace "Reusar" desde GalleryView.
// Lleva solo los campos que el pipeline puede aplicar directamente.

struct ReusableSettings {
    var seed:           Int
    var steps:          Int
    var cfgScale:       Double
    var samplerName:    String
    var width:          Int
    var height:         Int
    var promptPositive: String
    var promptNegative: String
    var checkpoint:     String
    var sessionTag:     String?

    /// Construir desde un GeneratedAsset de Core Data.
    init(from asset: GeneratedAsset) {
        self.seed           = Int(asset.seed)
        self.steps          = Int(asset.steps)
        self.cfgScale       = asset.cfgScale
        self.samplerName    = asset.samplerName ?? "DPM++ 2M Karras"
        self.width          = Int(asset.width)
        self.height         = Int(asset.height)
        self.promptPositive = asset.promptPositive ?? ""
        self.promptNegative = asset.promptNegative ?? ""
        self.checkpoint     = asset.checkpoint ?? ""
        self.sessionTag     = asset.sessionTag
    }
}

// MARK: - NSImage helpers (centralizados)

extension NSImage {

    /// PNG data del NSImage. Nil si la conversión falla.
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation,
              let rep  = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Redimensionar manteniendo aspect ratio, limitando el lado mayor.
    func resized(maxDimension: CGFloat) -> NSImage? {
        let size = self.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale   = min(maxDimension / size.width, maxDimension / size.height)
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let result  = NSImage(size: newSize)
        result.lockFocus()
        self.draw(
            in:   NSRect(origin: .zero, size: newSize),
            from: NSRect(origin: .zero, size: size),
            operation: .copy,
            fraction:  1.0
        )
        result.unlockFocus()
        return result
    }

    /// CGImage representation para operaciones Core Graphics.
    var cgImageSafe: CGImage? {
        cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

// MARK: - Data + SHA-256 (centralizado)

import CryptoKit

extension Data {
    var sha256Hex: String {
        let digest = SHA256.hash(data: self)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - JSONEncoder / JSONDecoder helpers (centralizados)

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting    = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

// MARK: - NSColor helpers

extension NSColor {
    convenience init(hex: String) {
        let swiftColor = Color(hex: hex)
        // Convertir Color → NSColor via UIColor bridge
        if #available(macOS 12.0, *) {
            self.init(swiftColor)
        } else {
            self.init(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        }
    }
}

// MARK: - View helpers

extension View {
    /// Aplica un modificador solo si la condición es true.
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition { transform(self) } else { self }
    }
}

// MARK: - String helpers

extension String {
    /// Truncar con elipsis a N caracteres.
    func truncated(_ maxLength: Int) -> String {
        count > maxLength ? String(prefix(maxLength)) + "…" : self
    }
}

// MARK: - Date helpers

extension Date {
    /// Formato legible corto: "12 mar · 14:32"
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
