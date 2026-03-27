import Foundation
import CoreData
import AppKit
import Combine

// MARK: - AssetStore
// Core Data stack para persistencia de todas las generaciones.
// Cada GeneratedAsset representa una imagen con su linaje completo.

@MainActor
final class AssetStore: ObservableObject {

    static let shared = AssetStore()

    // MARK: - Core Data Stack

    let container: NSPersistentContainer

    @Published var recentAssets: [GeneratedAsset] = []

    private init() {
        container = NSPersistentContainer(name: "SDPipelineStudio")

        // Configurar store en el vault si está disponible, o en Application Support como fallback
        let storeURL = AssetStore.resolveStoreURL()
        let description = NSPersistentStoreDescription(url: storeURL)
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        container.persistentStoreDescriptions = [description]

        container.loadPersistentStores { _, error in
            if let error {
                // En producción personal no hay usuarios que perder datos —
                // loguear y continuar con store en memoria como fallback
                print("⚠️ AssetStore: error cargando persistent store: \(error)")
            }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        fetchRecentAssets()
    }

    // MARK: - Public API

    /// Guardar una nueva generación completa en Core Data + sidecar JSON.
    @discardableResult
    func saveAsset(
        image:       NSImage,
        request:     SDRequest,
        seed:        Int?,
        modelName:   String   = "",
        checkpoint:  String   = "",
        vaeUsed:     String   = "",
        loraWeights: [String: Double] = [:],
        sessionTag:  String?  = nil
    ) async -> GeneratedAsset? {

        guard let vaultDir = await VaultManager.shared.todayGeneracionesURL else {
            print("⚠️ AssetStore: Vault no configurado")
            return nil
        }

        // Crear directorio de fecha si no existe
        try? FileManager.default.createDirectory(at: vaultDir, withIntermediateDirectories: true)

        // Generar nombre base único
        let timestamp = Int(Date().timeIntervalSince1970)
        let baseName  = "gen_\(timestamp)"

        // Guardar PNG original (imagen raw de SD, nunca modificada)
        guard let pngData = image.pngData() else { return nil }
        let origURL = vaultDir.appending(path: "\(baseName)_v001.orig.png")
        try? pngData.write(to: origURL)

        // Calcular hash SHA-256 para integridad
        let sha256 = pngData.sha256Hex

        // Construir sidecar JSON
        let sidecar = SidecarJSON(
            baseName:    baseName,
            version:     1,
            imageURL:    origURL,
            request:     request,
            seed:        seed ?? request.seed,
            modelName:   modelName,
            checkpoint:  checkpoint,
            vaeUsed:     vaeUsed,
            loraWeights: loraWeights,
            sha256:      sha256,
            sessionTag:  sessionTag
        )

        // Guardar sidecar junto a la imagen
        let sidecarURL = VaultManager.shared.sidecarURL(for: origURL)
        if let sidecarData = try? JSONEncoder.pretty.encode(sidecar) {
            try? sidecarData.write(to: sidecarURL)
        }

        // ── Esteganografía: incrustar payload invisible antes de guardar ──────
        var finalPNGData = pngData
        let assetID = UUID()
        do {
            let stegEngine = SteganographyEngine()
            let stegPayload = SteganographyPayload(
                artistID:  "SDPipelineStudio",
                assetID:   assetID.uuidString,
                sha256:    sha256,
                timestamp: Date()
            )
            if let embedded = try? stegEngine.embed(payload: stegPayload, into: pngData) {
                finalPNGData = embedded
                // Re-escribir el PNG original con el payload invisible
                try? finalPNGData.write(to: origURL)
            }
        }

        // ── Export Engine: generar versiones clean + preview ──────────────────
        var cleanPath:   String? = nil
        var previewPath: String? = nil
        if let exportDir = VaultManager.shared.exportURL {
            try? FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
            let previewDir = exportDir.appending(path: "Previews")
            try? FileManager.default.createDirectory(at: previewDir, withIntermediateDirectories: true)

            let exportConfig = ExportConfig(
                cleanOutputURL:   exportDir.appending(path: "\(baseName)_clean.png"),
                previewOutputURL: previewDir.appending(path: "\(baseName)_preview.png"),
                watermark: WatermarkConfig(
                    text:     "© SDPipeline Studio",
                    position: .bottomRight,
                    opacity:  0.55
                ),
                scrubMetadata: true
            )
            if let exportResult = try? ExportEngine.export(imageData: finalPNGData, config: exportConfig) {
                cleanPath   = exportResult.cleanURL.path
                previewPath = exportResult.previewURL.path
            }
        }

        // ── LicenseVault: registrar checkpoint en primer uso ──────────────────
        if !checkpoint.isEmpty {
            Task.detached(priority: .utility) {
                let vault = LicenseVault.shared
                if !vault.isRegistered(checkpoint: checkpoint) {
                    vault.registerModel(ModelCard(
                        checkpoint:   checkpoint,
                        displayName:  checkpoint,
                        licenseType:  .creativeML_OpenRAIL_M,
                        licenseURL:   nil,
                        addedAt:      Date()
                    ))
                }
            }
        }

        // ── PromptHistory: registrar prompt exitoso ───────────────────────────
        Task { @MainActor in
            PromptHistory.shared.record(
                positive: request.prompt,
                negative: request.negative_prompt,
                seed:     seed ?? request.seed,
                assetID:  assetID.uuidString
            )
        }

        // Crear thumbnail para galería (max 400px, sin procesar)
        let thumbnailData = image.resized(maxDimension: 400)?.pngData()

        // Guardar en Core Data
        let ctx = container.viewContext
        let asset = GeneratedAsset(context: ctx)
        asset.id             = assetID
        asset.baseName       = baseName
        asset.version        = 1
        asset.createdAt      = Date()
        asset.imagePath      = origURL.path
        asset.cleanPath      = cleanPath
        asset.previewPath    = previewPath
        asset.sidecarPath    = sidecarURL.path
        asset.promptPositive = request.prompt
        asset.promptNegative = request.negative_prompt
        asset.seed           = Int64(seed ?? request.seed)
        asset.steps          = Int32(request.steps)
        asset.cfgScale       = request.cfg_scale
        asset.samplerName    = request.sampler_name
        asset.width          = Int32(request.width)
        asset.height         = Int32(request.height)
        asset.modelName      = modelName
        asset.checkpoint     = checkpoint
        asset.vaeUsed        = vaeUsed
        asset.sha256         = sha256
        asset.sessionTag     = sessionTag
        asset.rating         = 0   // Sin calificar
        asset.status         = AssetStatus.draft.rawValue
        asset.thumbnailData  = thumbnailData

        // Serializar loraWeights como JSON string
        if let loraJSON = try? JSONEncoder().encode(loraWeights),
           let loraStr  = String(data: loraJSON, encoding: .utf8) {
            asset.loraWeightsJSON = loraStr
        }

        do {
            try ctx.save()
            fetchRecentAssets()
            return asset
        } catch {
            print("⚠️ AssetStore: error guardando asset: \(error)")
            ctx.rollback()
            return nil
        }
    }

    /// Actualizar rating de un asset (1-5 estrellas, 0 = sin calificar).
    func updateRating(_ asset: GeneratedAsset, rating: Int) {
        asset.rating = Int32(max(0, min(5, rating)))
        try? container.viewContext.save()
        fetchRecentAssets()
    }

    /// Cambiar el status de un asset.
    func updateStatus(_ asset: GeneratedAsset, status: AssetStatus) {
        asset.status = status.rawValue
        try? container.viewContext.save()
        fetchRecentAssets()
    }

    /// Buscar assets por términos en prompt, tag de sesión o nombre.
    func search(query: String) -> [GeneratedAsset] {
        let request = GeneratedAsset.fetchRequest()
        if !query.isEmpty {
            request.predicate = NSPredicate(
                format: "promptPositive CONTAINS[cd] %@ OR sessionTag CONTAINS[cd] %@ OR baseName CONTAINS[cd] %@",
                query, query, query
            )
        }
        request.sortDescriptors = [NSSortDescriptor(keyPath: \GeneratedAsset.createdAt, ascending: false)]
        request.fetchLimit = 200
        return (try? container.viewContext.fetch(request)) ?? []
    }

    /// Fetch de assets recientes (últimas 50 generaciones).
    func fetchRecentAssets() {
        let request = GeneratedAsset.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \GeneratedAsset.createdAt, ascending: false)]
        request.fetchLimit = 50
        recentAssets = (try? container.viewContext.fetch(request)) ?? []
    }

    // MARK: - Store URL

    private static func resolveStoreURL() -> URL {
        // Preferir guardar el store dentro del Vault si está configurado
        if let vaultMeta = VaultManager.shared.vaultMetaURL {
            return vaultMeta.appending(path: "SDPipelineStudio.sqlite")
        }
        // Fallback: Application Support
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appending(path: "SDPipeline")
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appending(path: "SDPipelineStudio.sqlite")
    }
}

// MARK: - Asset Status

enum AssetStatus: String, CaseIterable {
    case draft     = "draft"
    case approved  = "approved"
    case published = "published"
    case rejected  = "rejected"

    var label: String {
        switch self {
        case .draft:     return "Borrador"
        case .approved:  return "Aprobada"
        case .published: return "Publicada"
        case .rejected:  return "Rechazada"
        }
    }

    var color: String {
        switch self {
        case .draft:     return "gray"
        case .approved:  return "green"
        case .published: return "blue"
        case .rejected:  return "red"
        }
    }
}

// MARK: - GeneratedAsset (NSManagedObject)
// NOTA: Este archivo define la subclase manualmente para no depender de
// archivos de modelo .xcdatamodeld generados por Xcode que varían por versión.
// Alternativamente, crear SDPipelineStudio.xcdatamodeld con estas entidades.

@objc(GeneratedAsset)
public class GeneratedAsset: NSManagedObject {

    // Identidad
    @NSManaged public var id:             UUID?
    @NSManaged public var baseName:       String?
    @NSManaged public var version:        Int32
    @NSManaged public var createdAt:      Date?

    // Rutas de archivo
    @NSManaged public var imagePath:      String?
    @NSManaged public var cleanPath:      String?   // Export limpio (sin metadatos)
    @NSManaged public var previewPath:    String?   // Preview con watermark
    @NSManaged public var sidecarPath:    String?

    // Prompt
    @NSManaged public var promptPositive: String?
    @NSManaged public var promptNegative: String?

    // Parámetros SD
    @NSManaged public var seed:           Int64
    @NSManaged public var steps:          Int32
    @NSManaged public var cfgScale:       Double
    @NSManaged public var samplerName:    String?
    @NSManaged public var width:          Int32
    @NSManaged public var height:         Int32

    // Modelo
    @NSManaged public var modelName:      String?
    @NSManaged public var checkpoint:     String?
    @NSManaged public var vaeUsed:        String?
    @NSManaged public var loraWeightsJSON: String?

    // Seguridad
    @NSManaged public var sha256:         String?

    // Curaduría
    @NSManaged public var rating:         Int32      // 0 = sin calificar, 1-5 estrellas
    @NSManaged public var status:         String?    // AssetStatus.rawValue
    @NSManaged public var sessionTag:     String?
    @NSManaged public var notes:          String?

    // Galería
    @NSManaged public var thumbnailData:  Data?

    // Computed helpers
    var imageURL: URL? {
        guard let p = imagePath else { return nil }
        return URL(fileURLWithPath: p)
    }

    var statusEnum: AssetStatus {
        AssetStatus(rawValue: status ?? "") ?? .draft
    }

    var loraWeights: [String: Double] {
        guard let json = loraWeightsJSON?.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: Double].self, from: json)
        else { return [:] }
        return dict
    }

    var thumbnail: NSImage? {
        guard let data = thumbnailData else { return nil }
        return NSImage(data: data)
    }

    @nonobjc public class func fetchRequest() -> NSFetchRequest<GeneratedAsset> {
        NSFetchRequest<GeneratedAsset>(entityName: "GeneratedAsset")
    }
}

// MARK: - NSManagedObjectModel (programático)
// Evita depender de .xcdatamodeld — el modelo se define en código.

extension NSManagedObjectModel {

    static var sdPipelineStudioModel: NSManagedObjectModel = {
        let model = NSManagedObjectModel()
        let entity = NSEntityDescription()
        entity.name = "GeneratedAsset"
        entity.managedObjectClassName = "GeneratedAsset"

        func attr(_ name: String, _ type: NSAttributeType, optional: Bool = true) -> NSAttributeDescription {
            let a = NSAttributeDescription()
            a.name = name
            a.attributeType = type
            a.isOptional = optional
            return a
        }

        entity.properties = [
            attr("id",              .UUIDAttributeType),
            attr("baseName",        .stringAttributeType),
            attr("version",         .integer32AttributeType, optional: false),
            attr("createdAt",       .dateAttributeType),
            attr("imagePath",       .stringAttributeType),
            attr("cleanPath",       .stringAttributeType),
            attr("previewPath",     .stringAttributeType),
            attr("sidecarPath",     .stringAttributeType),
            attr("promptPositive",  .stringAttributeType),
            attr("promptNegative",  .stringAttributeType),
            attr("seed",            .integer64AttributeType, optional: false),
            attr("steps",           .integer32AttributeType, optional: false),
            attr("cfgScale",        .doubleAttributeType,    optional: false),
            attr("samplerName",     .stringAttributeType),
            attr("width",           .integer32AttributeType, optional: false),
            attr("height",          .integer32AttributeType, optional: false),
            attr("modelName",       .stringAttributeType),
            attr("checkpoint",      .stringAttributeType),
            attr("vaeUsed",         .stringAttributeType),
            attr("loraWeightsJSON", .stringAttributeType),
            attr("sha256",          .stringAttributeType),
            attr("rating",          .integer32AttributeType, optional: false),
            attr("status",          .stringAttributeType),
            attr("sessionTag",      .stringAttributeType),
            attr("notes",           .stringAttributeType),
            attr("thumbnailData",   .binaryDataAttributeType),
        ]

        model.entities = [entity]
        return model
    }()
}

// MARK: - NSPersistentContainer override para usar modelo programático

extension AssetStore {
    static func buildContainer(storeURL: URL) -> NSPersistentContainer {
        let container = NSPersistentContainer(
            name: "SDPipelineStudio",
            managedObjectModel: .sdPipelineStudioModel
        )
        let desc = NSPersistentStoreDescription(url: storeURL)
        desc.shouldMigrateStoreAutomatically = true
        desc.shouldInferMappingModelAutomatically = true
        container.persistentStoreDescriptions = [desc]
        return container
    }
}

// MARK: - Data + SHA-256

import CryptoKit

extension Data {
    var sha256Hex: String {
        let digest = SHA256.hash(data: self)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - NSImage helpers

extension NSImage {
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    func resized(maxDimension: CGFloat) -> NSImage? {
        let size = self.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(maxDimension / size.width, maxDimension / size.height)
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let new = NSImage(size: newSize)
        new.lockFocus()
        self.draw(in: NSRect(origin: .zero, size: newSize),
                  from: NSRect(origin: .zero, size: size),
                  operation: .copy, fraction: 1.0)
        new.unlockFocus()
        return new
    }
}

// MARK: - JSONEncoder pretty

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}
