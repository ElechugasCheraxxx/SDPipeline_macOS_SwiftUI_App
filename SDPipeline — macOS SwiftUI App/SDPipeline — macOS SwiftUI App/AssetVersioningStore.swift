import Foundation
import AppKit
import SwiftUI
import Combine
import CryptoKit

// MARK: - AssetVersioningStore
//
// Versionado estándar de assets generados.
// Cada imagen aprobada puede tener múltiples versiones:
//   v1 — original raw de SD
//   v2 — post-procesada (upscale, face restore, cinematic filter)
//   v3 — refinada con img2img
//   ...etc.
//
// Arquitectura:
//   Vault/versions/{assetUUID}/
//     manifest.json          ← Índice de versiones
//     v1_original.png        ← Copia inmutable del raw
//     v1.meta.json           ← Sidecar de v1
//     v2_postprocess.png
//     v2.meta.json
//     ...
//
// Reglas:
//   • v1 (original) es INMUTABLE — nunca se sobrescribe
//   • Cada nueva versión tiene su propio sidecar JSON
//   • El manifest registra la cadena de transformaciones (lineage)
//   • Máximo configurable de versiones por asset (default: 10)
//
// ROADMAP: "Versionado estándar de assets" (🔴 INMEDIATO)

@MainActor
final class AssetVersioningStore: ObservableObject {

    static let shared = AssetVersioningStore()
    private init() {}

    // MARK: - Models

    enum VersionTag: String, Codable, CaseIterable {
        case original     = "original"
        case postprocess  = "postprocess"
        case img2img      = "img2img"
        case inpainted    = "inpainted"
        case upscaled     = "upscaled"
        case cinematic    = "cinematic"
        case exported     = "exported"
        case custom       = "custom"

        var label: String {
            switch self {
            case .original:    return "Original"
            case .postprocess: return "Post-procesada"
            case .img2img:     return "Refinada (img2img)"
            case .inpainted:   return "Inpainted"
            case .upscaled:    return "Upscaled"
            case .cinematic:   return "Filtro Cinemático"
            case .exported:    return "Exportada"
            case .custom:      return "Personalizada"
            }
        }

        var icon: String {
            switch self {
            case .original:    return "photo"
            case .postprocess: return "wand.and.stars"
            case .img2img:     return "arrow.triangle.2.circlepath"
            case .inpainted:   return "paintbrush.fill"
            case .upscaled:    return "arrow.up.left.and.arrow.down.right"
            case .cinematic:   return "camera.filters"
            case .exported:    return "square.and.arrow.up"
            case .custom:      return "pencil.circle"
            }
        }
    }

    struct AssetVersion: Codable, Identifiable, Hashable {
        var id:           UUID   = UUID()
        var versionNumber: Int                    // 1, 2, 3...
        var createdAt:    Date   = Date()
        var tag:          VersionTag
        var customLabel:  String?                 // Para tag .custom
        var filename:     String                  // Relativo al directorio de versiones
        var sha256:       String
        var fileSizeBytes: Int

        // Transformación aplicada
        var transformationNote: String?           // "ESRGAN 4x upscale", "ADetailer faces", etc.
        var parentVersionID:    UUID?             // De qué versión deriva

        // Parámetros delta (qué cambió respecto a la versión anterior)
        var deltaParams: [String: String] = [:]   // key: valor

        var displayLabel: String {
            if let custom = customLabel, !custom.isEmpty { return custom }
            return "v\(versionNumber) — \(tag.label)"
        }

        func hash(into hasher: inout Hasher) { hasher.combine(id) }
        static func == (l: AssetVersion, r: AssetVersion) -> Bool { l.id == r.id }
    }

    struct VersionManifest: Codable {
        var schemaVersion: String = "SDPipeline.Versions.v1"
        var assetID:       UUID
        var assetName:     String
        var createdAt:     Date = Date()
        var updatedAt:     Date = Date()
        var versions:      [AssetVersion] = []
        var activeVersionID: UUID?          // Versión "principal" (la que muestra la galería)
        var maxVersions:   Int = 10
    }

    // MARK: - Published State

    @Published private(set) var manifests: [UUID: VersionManifest] = [:]

    // MARK: - Register Initial Version (v1 — Original)

    /// Registrar la imagen original generada como v1 (inmutable).
    /// Llamar desde AssetStore justo después de guardar el asset.
    func registerOriginal(
        assetID: UUID,
        assetName: String,
        imagePath: String,
        sha256: String
    ) throws {
        guard let versionDir = versionDirectory(for: assetID) else { return }
        try FileManager.default.createDirectory(at: versionDir, withIntermediateDirectories: true)

        let srcURL  = URL(fileURLWithPath: imagePath)
        let dstURL  = versionDir.appendingPathComponent("v1_original.png")

        // Copiar (no mover) — el original en Generaciones/ permanece intacto
        if !FileManager.default.fileExists(atPath: dstURL.path) {
            try FileManager.default.copyItem(at: srcURL, to: dstURL)
        }

        let attrs      = try FileManager.default.attributesOfItem(atPath: dstURL.path)
        let fileSize   = (attrs[.size] as? Int) ?? 0

        let version = AssetVersion(
            versionNumber:      1,
            tag:                .original,
            filename:           "v1_original.png",
            sha256:             sha256,
            fileSizeBytes:      fileSize,
            transformationNote: "Generación original SD",
            parentVersionID:    nil
        )

        var manifest = VersionManifest(assetID: assetID, assetName: assetName)
        manifest.versions.append(version)
        manifest.activeVersionID = version.id

        try saveManifest(manifest)
        manifests[assetID] = manifest
    }

    // MARK: - Add New Version

    func addVersion(
        assetID: UUID,
        imageData: Data,
        tag: VersionTag,
        customLabel: String? = nil,
        transformationNote: String? = nil,
        parentVersionID: UUID? = nil,
        deltaParams: [String: String] = [:]
    ) throws -> AssetVersion {
        guard var manifest = manifests[assetID] ?? loadManifest(assetID: assetID),
              let versionDir = versionDirectory(for: assetID)
        else { throw VersioningError.manifestNotFound }

        // Aplicar límite de versiones (eliminar la más antigua si se supera)
        if manifest.versions.count >= manifest.maxVersions {
            pruneOldest(manifest: &manifest, versionDir: versionDir)
        }

        let nextNum   = (manifest.versions.map(\.versionNumber).max() ?? 0) + 1
        let sha256    = SHA256.hash(data: imageData)
            .map { String(format: "%02x", $0) }.joined()
        let filename  = "v\(nextNum)_\(tag.rawValue).png"
        let fileURL   = versionDir.appendingPathComponent(filename)

        try imageData.write(to: fileURL, options: .atomic)

        let version = AssetVersion(
            versionNumber:      nextNum,
            tag:                tag,
            customLabel:        customLabel,
            filename:           filename,
            sha256:             sha256,
            fileSizeBytes:      imageData.count,
            transformationNote: transformationNote,
            parentVersionID:    parentVersionID,
            deltaParams:        deltaParams
        )

        manifest.versions.append(version)
        manifest.updatedAt = Date()

        try saveManifest(manifest)
        manifests[assetID] = manifest

        ZeroKnowledgeLog.shared.write(
            category: .systemEvent,
            message: "Version v\(nextNum) [\(tag.rawValue)] added for asset \(assetID)"
        )

        return version
    }

    // MARK: - Set Active Version

    func setActiveVersion(assetID: UUID, versionID: UUID) throws {
        guard var manifest = manifests[assetID] else { throw VersioningError.manifestNotFound }
        guard manifest.versions.contains(where: { $0.id == versionID }) else {
            throw VersioningError.versionNotFound
        }
        manifest.activeVersionID = versionID
        manifest.updatedAt = Date()
        try saveManifest(manifest)
        manifests[assetID] = manifest
    }

    // MARK: - Get Image for Version

    func imageURL(assetID: UUID, versionID: UUID) -> URL? {
        guard let manifest = manifests[assetID],
              let version = manifest.versions.first(where: { $0.id == versionID }),
              let dir = versionDirectory(for: assetID)
        else { return nil }
        return dir.appendingPathComponent(version.filename)
    }

    func activeImage(assetID: UUID) -> NSImage? {
        guard let manifest = manifests[assetID],
              let activeID = manifest.activeVersionID,
              let url = imageURL(assetID: assetID, versionID: activeID),
              let img = NSImage(contentsOf: url)
        else { return nil }
        return img
    }

    // MARK: - Versions for Asset

    func versions(for assetID: UUID) -> [AssetVersion] {
        manifests[assetID]?.versions ?? []
    }

    // MARK: - Delete Version

    func deleteVersion(assetID: UUID, versionID: UUID) throws {
        guard var manifest = manifests[assetID],
              let idx = manifest.versions.firstIndex(where: { $0.id == versionID })
        else { throw VersioningError.versionNotFound }

        let version = manifest.versions[idx]

        // No se puede eliminar v1 original
        guard version.versionNumber > 1 else { throw VersioningError.cannotDeleteOriginal }

        if let dir = versionDirectory(for: assetID) {
            let fileURL = dir.appendingPathComponent(version.filename)
            try? FileManager.default.removeItem(at: fileURL)
        }

        manifest.versions.remove(at: idx)

        // Si era la activa, volver a v1
        if manifest.activeVersionID == versionID {
            manifest.activeVersionID = manifest.versions.first?.id
        }

        manifest.updatedAt = Date()
        try saveManifest(manifest)
        manifests[assetID] = manifest
    }

    // MARK: - Load All Manifests (on vault open)

    func loadAllManifests() {
        guard let versionsRoot = versionsRootURL else { return }
        let fm = FileManager.default
        guard let assetDirs = try? fm.contentsOfDirectory(
            at: versionsRoot, includingPropertiesForKeys: nil
        ) else { return }

        for dir in assetDirs {
            guard let uuid = UUID(uuidString: dir.lastPathComponent),
                  let manifest = loadManifest(assetID: uuid)
            else { continue }
            manifests[uuid] = manifest
        }
    }

    // MARK: - Storage Helpers

    private var versionsRootURL: URL? {
        VaultManager.shared.vaultRoot?
            .appendingPathComponent("Vault/versions", isDirectory: true)
    }

    private func versionDirectory(for assetID: UUID) -> URL? {
        versionsRootURL?.appendingPathComponent(assetID.uuidString, isDirectory: true)
    }

    private func manifestURL(assetID: UUID) -> URL? {
        versionDirectory(for: assetID)?.appendingPathComponent("manifest.json")
    }

    private func saveManifest(_ manifest: VersionManifest) throws {
        guard let url = manifestURL(assetID: manifest.assetID) else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting  = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        try data.write(to: url, options: .atomic)
    }

    private func loadManifest(assetID: UUID) -> VersionManifest? {
        guard let url = manifestURL(assetID: assetID),
              let data = try? Data(contentsOf: url)
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(VersionManifest.self, from: data)
    }

    private func pruneOldest(manifest: inout VersionManifest, versionDir: URL) {
        // Mantener v1 siempre; eliminar la segunda versión más antigua
        let prunable = manifest.versions
            .filter { $0.versionNumber > 1 }
            .sorted { $0.versionNumber < $1.versionNumber }

        guard let oldest = prunable.first else { return }
        let fileURL = versionDir.appendingPathComponent(oldest.filename)
        try? FileManager.default.removeItem(at: fileURL)
        manifest.versions.removeAll { $0.id == oldest.id }
    }

    // MARK: - Errors

    enum VersioningError: LocalizedError {
        case manifestNotFound
        case versionNotFound
        case cannotDeleteOriginal

        var errorDescription: String? {
            switch self {
            case .manifestNotFound:    return "Manifest de versiones no encontrado para este asset."
            case .versionNotFound:     return "Versión no encontrada."
            case .cannotDeleteOriginal: return "No se puede eliminar la versión original (v1)."
            }
        }
    }
}

// MARK: - Version History View

struct AssetVersionHistoryView: View {

    let assetID: UUID
    @ObservedObject private var store = AssetVersioningStore.shared
    @State private var selectedVersion: AssetVersioningStore.AssetVersion?
    @State private var previewImage: NSImage?

    private var versions: [AssetVersioningStore.AssetVersion] {
        store.versions(for: assetID).sorted { $0.versionNumber > $1.versionNumber }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundColor(Color(hex: "#7c6af7"))
                Text("Historial de Versiones")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(versions.count) versiones")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if versions.isEmpty {
                Text("Sin versiones registradas.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(versions) { version in
                            VersionRow(
                                version: version,
                                isActive: store.manifests[assetID]?.activeVersionID == version.id,
                                isSelected: selectedVersion?.id == version.id,
                                onSelect: {
                                    selectedVersion = version
                                    previewImage = store.imageURL(assetID: assetID, versionID: version.id)
                                        .flatMap { NSImage(contentsOf: $0) }
                                },
                                onActivate: {
                                    try? store.setActiveVersion(assetID: assetID, versionID: version.id)
                                },
                                onDelete: version.versionNumber > 1 ? {
                                    try? store.deleteVersion(assetID: assetID, versionID: version.id)
                                } : nil
                            )
                        }
                    }
                }
                .frame(maxHeight: 280)

                if let img = previewImage {
                    Divider()
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 160)
                        .padding(12)
                        .cornerRadius(8)
                }
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(12)
    }
}

private struct VersionRow: View {
    let version: AssetVersioningStore.AssetVersion
    let isActive: Bool
    let isSelected: Bool
    let onSelect: () -> Void
    let onActivate: () -> Void
    let onDelete: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: version.tag.icon)
                .font(.system(size: 14))
                .foregroundColor(isActive ? Color(hex: "#7c6af7") : .secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(version.displayLabel)
                        .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                    if isActive {
                        Text("ACTIVA")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color(hex: "#7c6af7").opacity(0.2))
                            .foregroundColor(Color(hex: "#7c6af7"))
                            .cornerRadius(4)
                    }
                }
                if let note = version.transformationNote {
                    Text(note)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Text(version.createdAt.formatted(.dateTime.day().month().hour().minute()))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text(ByteCountFormatter.string(fromByteCount: Int64(version.fileSizeBytes), countStyle: .file))
                .font(.system(size: 10))
                .foregroundColor(.secondary)

            if !isActive {
                Button("Activar") { onActivate() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(5)
            }

            if let del = onDelete {
                Button(action: del) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundColor(.red.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
    }
}
