import Foundation
import SwiftUI

// MARK: - Models_Extended_Patch.swift
//
// Extensiones faltantes detectadas en audit de compilación.
// Archivo complementario a Models_Extended.swift — NO modifica el original.
//
// FIXES:
//   1. AssetStatus.hexColor  → requerido por StatusBadge (View_Helpers.swift:111)
//   2. ExportEngine.scrubMetadata(from:) → requerido por ContentView.runEXIFKillSwitch()

// MARK: - 1. AssetStatus.hexColor

extension AssetStatus {
    /// Color hexadecimal compatible con Color(hex:) para StatusBadge.
    var hexColor: String {
        switch self {
        case .draft:     return "#6b7280"   // gris
        case .approved:  return "#34d399"   // verde
        case .published: return "#60a5fa"   // azul
        case .rejected:  return "#ef4444"   // rojo
        }
    }
}

// MARK: - 2. ExportEngine.scrubMetadata(from:)

extension ExportEngine {
    /// Elimina todos los metadatos embebidos de un PNG en memoria.
    /// Wrapper público del método privado interno — usado por ContentView.runEXIFKillSwitch().
    /// Estrategia: NSImage.stripPNGTextChunks (LSB chunks) + re-render pixel-clean vía Core Graphics.
    func scrubMetadata(from data: Data) -> Data {
        // 1. Strip tEXt/zTXt/iTXt PNG chunks (donde A1111 inyecta prompts/seeds)
        let stripped = NSImage.stripPNGTextChunks(from: data)

        // 2. Re-renderizar para limpiar EXIF/XMP residual
        guard let image = NSImage(data: stripped),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return stripped }

        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutableData, "public.png" as CFString, 1, nil
        ) else { return stripped }

        let opts: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 1.0,
            kCGImagePropertyExifDictionary: [:] as NSDictionary,
            kCGImagePropertyIPTCDictionary: [:] as NSDictionary,
            kCGImagePropertyTIFFDictionary: [:] as NSDictionary,
            kCGImageMetadataShouldExcludeGPS: true,
        ]
        CGImageDestinationAddImage(dest, cgImage, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return stripped }

        return mutableData as Data
    }
}

// MARK: - 3. BackupConfig.lastBackupDate convenience alias

extension BackupManager.BackupConfig {
    /// Alias de lastBackupAt para compatibilidad con AuditReport.
    var lastBackupDate: Date? { lastBackupAt }
}

// MARK: - 4. GenerationSettings.default convenience

extension GenerationSettings {
    static var `default`: GenerationSettings { GenerationSettings() }
}
