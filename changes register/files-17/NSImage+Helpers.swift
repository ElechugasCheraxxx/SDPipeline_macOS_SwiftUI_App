import AppKit

// MARK: - NSImage + Helpers
// Extensiones de uso general sobre NSImage.
// Centralizado aquí para evitar redefiniciones en AssetStore, SteganographyEngine, etc.

extension NSImage {

    /// PNG data. Nil si la conversión falla.
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation,
              let rep  = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Redimensionar manteniendo aspect ratio, limitando el lado mayor a `maxDimension`.
    func resized(maxDimension: CGFloat) -> NSImage? {
        let size = self.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale   = min(maxDimension / size.width, maxDimension / size.height)
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let result  = NSImage(size: newSize)
        result.lockFocus()
        self.draw(
            in:        NSRect(origin: .zero, size: newSize),
            from:      NSRect(origin: .zero, size: size),
            operation: .copy,
            fraction:  1.0
        )
        result.unlockFocus()
        return result
    }

    /// CGImage seguro para operaciones Core Graphics.
    var cgImageSafe: CGImage? {
        cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
