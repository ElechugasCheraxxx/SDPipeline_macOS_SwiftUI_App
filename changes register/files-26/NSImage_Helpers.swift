import AppKit
import CoreGraphics
import UniformTypeIdentifiers

// MARK: - NSImage_Helpers.swift
// Image processing utilities used across ExportEngine, SteganographyEngine,
// PostProductionEngine, and NSFWDetector.

extension NSImage {

    // MARK: - Data export

    func pngData() -> Data? {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = size
        return rep.representation(using: .png, properties: [:])
    }

    func jpegData(quality: CGFloat = 0.85) -> Data? {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    func base64PNG() -> String? {
        pngData()?.base64EncodedString()
    }

    func base64JPEG(quality: CGFloat = 0.85) -> String? {
        jpegData(quality: quality)?.base64EncodedString()
    }

    // MARK: - Resize / scale

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

    func resized(toMaxDimension maxDim: CGFloat) -> NSImage {
        let ratio = min(maxDim / size.width, maxDim / size.height)
        guard ratio < 1 else { return self }
        return resized(to: NSSize(width: size.width * ratio, height: size.height * ratio))
    }

    func resized(toWidth w: CGFloat) -> NSImage {
        let ratio = w / size.width
        return resized(to: NSSize(width: w, height: size.height * ratio))
    }

    func resized(toHeight h: CGFloat) -> NSImage {
        let ratio = h / size.height
        return resized(to: NSSize(width: size.width * ratio, height: h))
    }

    /// Fit inside bounding box while preserving aspect ratio.
    func fitted(into box: NSSize) -> NSImage {
        let ratio = min(box.width / size.width, box.height / size.height)
        return resized(to: NSSize(width: size.width * ratio, height: size.height * ratio))
    }

    // MARK: - Pixel dimensions

    var pixelSize: NSSize {
        guard let rep = representations.first else { return size }
        return NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }

    var pixelWidth:  Int { Int(pixelSize.width)  }
    var pixelHeight: Int { Int(pixelSize.height) }
    var aspectRatio: Double { size.height > 0 ? Double(size.width / size.height) : 1.0 }

    // MARK: - Crop

    func cropped(to rect: NSRect) -> NSImage {
        let new = NSImage(size: rect.size)
        new.lockFocus()
        let dest = NSRect(origin: .zero, size: rect.size)
        draw(in: dest, from: rect, operation: .copy, fraction: 1.0)
        new.unlockFocus()
        return new
    }

    // MARK: - Metadata-clean PNG (no EXIF / iTXt / tEXt chunks)

    /// Returns PNG data with all metadata chunks stripped.
    /// Used by ExportEngine for clean exports.
    func cleanPNGData() -> Data? {
        guard let raw = pngData() else { return nil }
        return NSImage.removePNGMetadataChunks(from: raw)
    }

    /// Strip PNG tEXt, iTXt, and zTXt chunks (EXIF equivalent in PNG).
    static func removePNGMetadataChunks(from data: Data) -> Data {
        var result = Data()
        guard data.count > 8 else { return data }

        // PNG signature
        result.append(data[0..<8])
        var offset = 8

        while offset + 12 <= data.count {
            let length = Int(data[offset..<offset+4].uint32BE)
            let type   = String(bytes: data[offset+4..<offset+8], encoding: .ascii) ?? ""
            let chunkEnd = offset + 12 + length

            guard chunkEnd <= data.count else { break }

            // Strip metadata text chunks
            let skipTypes: Set<String> = ["tEXt", "iTXt", "zTXt", "eXIf", "iCCP"]
            if !skipTypes.contains(type) {
                result.append(data[offset..<chunkEnd])
            }
            offset = chunkEnd
        }
        return result
    }

    // MARK: - Compositing

    /// Overlay another image on top (for watermarks).
    func composited(with overlay: NSImage, at origin: NSPoint = .zero, alpha: CGFloat = 1.0) -> NSImage {
        let new = NSImage(size: size)
        new.lockFocus()
        draw(at: .zero, from: NSRect(origin: .zero, size: size), operation: .copy, fraction: 1.0)
        overlay.draw(at: origin, from: NSRect(origin: .zero, size: overlay.size),
                     operation: .sourceOver, fraction: alpha)
        new.unlockFocus()
        return new
    }

    // MARK: - Conversion to/from CGImage

    var cgImageRep: CGImage? {
        cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    convenience init?(cgImage: CGImage) {
        self.init(cgImage: cgImage, size: .zero)
    }
}

// MARK: - Data uint32 big-endian helper

private extension Data {
    var uint32BE: UInt32 {
        guard count >= 4 else { return 0 }
        return withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    }
}

// MARK: - Data CryptoKit SHA-256 (used by AssetStore, IntegrityManager)

import CryptoKit

extension Data {
    var sha256Hex: String {
        SHA256.hash(data: self)
            .compactMap { String(format: "%02x", $0) }
            .joined()
    }
}
