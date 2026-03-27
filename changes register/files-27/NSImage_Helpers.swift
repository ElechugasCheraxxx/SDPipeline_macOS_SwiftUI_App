import AppKit
import CoreGraphics

// MARK: - NSImage_Helpers.swift (extended)
//
// El archivo ORIGINAL ya declara:
//   pngData()               → NO redeclarar
//   resized(maxDimension:)  → NO redeclarar (firma: maxDimension: CGFloat)
//   cgImageSafe             → NO redeclarar
//
// Este archivo SOLO agrega lo que falta.

extension NSImage {

    // MARK: - Resize variants (distintas firmas del original)

    /// Redimensionar a tamaño exacto.
    func resized(to newSize: NSSize) -> NSImage {
        let new = NSImage(size: newSize)
        new.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        draw(in: NSRect(origin: .zero, size: newSize),
             from: NSRect(origin: .zero, size: size),
             operation: .copy, fraction: 1.0)
        new.unlockFocus()
        return new
    }

    /// Alias con nombre distinto al original (toMaxDimension en lugar de maxDimension).
    /// Usado en AssetInspectorView y GalleryView para thumbnails.
    func resized(toMaxDimension maxDim: CGFloat) -> NSImage {
        let ratio = min(maxDim / size.width, maxDim / size.height)
        guard ratio < 1 else { return self }
        return resized(to: NSSize(width: size.width * ratio, height: size.height * ratio))
    }

    /// Encajar dentro de un bounding box manteniendo aspect ratio.
    func fitted(into box: NSSize) -> NSImage {
        let ratio = min(box.width / size.width, box.height / size.height)
        return resized(to: NSSize(width: size.width * ratio, height: size.height * ratio))
    }

    // MARK: - Pixel dimensions

    var pixelWidth: Int {
        guard let rep = representations.first else { return Int(size.width) }
        return rep.pixelsWide
    }

    var pixelHeight: Int {
        guard let rep = representations.first else { return Int(size.height) }
        return rep.pixelsHigh
    }

    var pixelSize: NSSize {
        NSSize(width: pixelWidth, height: pixelHeight)
    }

    var aspectRatio: Double {
        size.height > 0 ? Double(size.width / size.height) : 1.0
    }

    // MARK: - Metadata-clean PNG

    /// PNG sin chunks de texto/EXIF (tEXt, iTXt, zTXt, eXIf).
    /// Usado por ExportEngine para versiones clean sin metadatos de generación.
    func cleanPNGData() -> Data? {
        guard let raw = pngData() else { return nil }  // pngData() del archivo original
        return NSImage.stripPNGTextChunks(from: raw)
    }

    static func stripPNGTextChunks(from data: Data) -> Data {
        var result = Data()
        guard data.count > 8 else { return data }
        result.append(data[0..<8])
        var offset = 8
        while offset + 12 <= data.count {
            let lengthData = data[offset..<(offset + 4)]
            let length = Int(lengthData.uint32BigEndian)
            let typeBytes = data[(offset + 4)..<(offset + 8)]
            let type = String(bytes: typeBytes, encoding: .ascii) ?? ""
            let chunkEnd = offset + 12 + length
            guard chunkEnd <= data.count else { break }
            let skipTypes: Set<String> = ["tEXt", "iTXt", "zTXt", "eXIf", "iCCP"]
            if !skipTypes.contains(type) {
                result.append(data[offset..<chunkEnd])
            }
            offset = chunkEnd
        }
        return result
    }

    // MARK: - Compositing (watermarks)

    func composited(with overlay: NSImage, at origin: NSPoint = .zero, alpha: CGFloat = 1.0) -> NSImage {
        let new = NSImage(size: size)
        new.lockFocus()
        draw(at: .zero, from: NSRect(origin: .zero, size: size), operation: .copy, fraction: 1.0)
        overlay.draw(at: origin, from: NSRect(origin: .zero, size: overlay.size),
                     operation: .sourceOver, fraction: alpha)
        new.unlockFocus()
        return new
    }

    // MARK: - Base64

    func base64PNG() -> String? {
        pngData()?.base64EncodedString()
    }

    func base64JPEG(quality: CGFloat = 0.85) -> String? {
        guard let cgImg = cgImageSafe else { return nil }   // cgImageSafe del original
        let rep = NSBitmapImageRep(cgImage: cgImg)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])?
            .base64EncodedString()
    }
}

// MARK: - Data uint32 big-endian helper (private, solo para stripPNGTextChunks)

private extension Data {
    var uint32BigEndian: UInt32 {
        guard count >= 4 else { return 0 }
        return withUnsafeBytes { ptr in
            let b = ptr.baseAddress!.assumingMemoryBound(to: UInt8.self)
            return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
        }
    }
}
