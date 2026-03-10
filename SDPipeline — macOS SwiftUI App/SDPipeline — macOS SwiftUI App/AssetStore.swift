import Foundation
import CoreData
import AppKit
import Combine
import CryptoKit
import SwiftUI

// MARK: - AssetStore
// Core Data stack para persistencia de todas las generaciones.
// FIX v2: NSPersistentContainer ahora usa .sdPipelineStudioModel (programático).
//         saveAsset es ahora async para permitir llamadas con await desde PipelineConnector.

@MainActor
final class AssetStore: ObservableObject {

    static let shared = AssetStore()

    // MARK: - Core Data Stack

    let container: NSPersistentContainer

    @Published var recentAssets: [GeneratedAsset] = []

    private init() {
        // FIX: pasar modelo programático para evitar búsqueda de .xcdatamodeld inexistente
        container = NSPersistentContainer(
            name: "SDPipelineStudio",
            managedObjectModel: .sdPipelineStudioModel
        )

        let storeURL = AssetStore.resolveStoreURL()
        let description = NSPersistentStoreDescription(url: storeURL)
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        container.persistentStoreDescriptions = [description]

        container.loadPersistentStores { _, error in
            if let error {
                print("⚠️ AssetStore: error cargando persistent store: \(error)")
            }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        fetchRecentAssets()
    }

    // MARK: - Public API

    /// Guardar una nueva generación completa en Core Data + sidecar JSON.
    /// FIX: ahora es `async` para permitir `await` desde PipelineConnector y otros callers.
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

        guard let vaultDir = VaultManager.shared.todayGeneracionesURL else {
            print("⚠️ AssetStore: Vault no configurado")
            return nil
        }

        try? FileManager.default.createDirectory(at: vaultDir, withIntermediateDirectories: true)

        let timestamp = Int(Date().timeIntervalSince1970)
        let baseName  = "gen_\(timestamp)"
        let assetID   = UUID()

        guard let pngData = image.pngData() else { return nil }
        let sha256 = pngData.sha256Hex

        // ── Esteganografía (SteganographyEngine es @MainActor — llamar en MainActor) ──────
        let finalPNGData: Data = SteganographyEngine.shared.embed(
            image:      image,
            assetID:    assetID,
            sessionTag: sessionTag,
            sha256:     sha256
        ) ?? pngData

        let origURL = vaultDir.appending(path: "\(baseName)_v001.orig.png")
        try? finalPNGData.write(to: origURL)

        // ── Sidecar JSON ───────────────────────────────────────────────────────
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
        let sidecarURL = VaultManager.shared.sidecarURL(for: origURL)
        if let sidecarData = try? JSONEncoder.pretty.encode(sidecar) {
            try? sidecarData.write(to: sidecarURL)
        }

        // ── LicenseVault: registro automático de checkpoint en primer uso ──────
        if !checkpoint.isEmpty && !LicenseVault.shared.isRegistered(checkpoint: checkpoint) {
            let card = LicenseVault.ModelCard(
                checkpointName:    checkpoint,
                modelVersion:      "desconocida",
                baseModel:         "desconocido",
                source:            .other,
                sourceURL:         nil,
                licenseType:       .unknown,
                licenseURL:        nil,
                commercialUse:     .unknown,
                creditRequired:    true,
                modificationsOK:   false,
                sharingOK:         false,
                nsfw:              false,
                notes:             "Auto-registrado en primer uso — revisar y actualizar manualmente."
            )
            LicenseVault.shared.registerModel(card)
        }

        // ── Thumbnail ──────────────────────────────────────────────────────────
        let thumbnailData = image.resized(maxDimension: 400)?.pngData()

        // ── Core Data ──────────────────────────────────────────────────────────
        let ctx = container.viewContext
        let asset = GeneratedAsset(context: ctx)
        asset.id             = assetID
        asset.baseName       = baseName
        asset.version        = 1
        asset.createdAt      = Date()
        asset.imagePath      = origURL.path
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
        asset.rating         = 0
        asset.status         = AssetStatus.draft.rawValue
        asset.thumbnailData  = thumbnailData

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

    /// Actualizar rating de un asset (0 = sin calificar, 1-5 estrellas).
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

    /// Buscar assets por prompt, tag de sesión o nombre.
    func search(query: String, sessionTag: String? = nil, minRating: Int = 0) -> [GeneratedAsset] {
        let request = GeneratedAsset.fetchRequest()
        var predicates: [NSPredicate] = []

        if !query.isEmpty {
            predicates.append(NSPredicate(
                format: "promptPositive CONTAINS[cd] %@ OR sessionTag CONTAINS[cd] %@ OR baseName CONTAINS[cd] %@",
                query, query, query
            ))
        }
        if let tag = sessionTag {
            predicates.append(NSPredicate(format: "sessionTag == %@", tag))
        }
        if minRating > 0 {
            predicates.append(NSPredicate(format: "rating >= %d", minRating))
        }

        if !predicates.isEmpty {
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        }
        request.sortDescriptors = [NSSortDescriptor(keyPath: \GeneratedAsset.createdAt, ascending: false)]
        request.fetchLimit = 200
        return (try? container.viewContext.fetch(request)) ?? []
    }

    /// Todos los assets con un status dado.
    func assets(withStatus status: AssetStatus, limit: Int = 100) -> [GeneratedAsset] {
        let request = GeneratedAsset.fetchRequest()
        request.predicate = NSPredicate(format: "status == %@", status.rawValue)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \GeneratedAsset.createdAt, ascending: false)]
        request.fetchLimit = limit
        return (try? container.viewContext.fetch(request)) ?? []
    }

    /// Fetch reciente (50 últimos).
    func fetchRecentAssets() {
        let request = GeneratedAsset.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \GeneratedAsset.createdAt, ascending: false)]
        request.fetchLimit = 50
        recentAssets = (try? container.viewContext.fetch(request)) ?? []
    }

    /// Fetch extendido para galería (hasta 500).
    func fetchAllAssets(limit: Int = 500) -> [GeneratedAsset] {
        let request = GeneratedAsset.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \GeneratedAsset.createdAt, ascending: false)]
        request.fetchLimit = limit
        return (try? container.viewContext.fetch(request)) ?? []
    }

    /// Verificar integridad SHA-256 de un asset.
    func verifyIntegrity(_ asset: GeneratedAsset) -> Bool {
        guard let path = asset.imagePath,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let storedHash = asset.sha256
        else { return false }
        return data.sha256Hex == storedHash
    }

    /// Eliminar asset de Core Data y disco.
    func delete(_ asset: GeneratedAsset) {
        [asset.imagePath, asset.sidecarPath, asset.cleanPath, asset.previewPath]
            .compactMap { $0 }
            .map    { URL(fileURLWithPath: $0) }
            .forEach { try? FileManager.default.removeItem(at: $0) }
        container.viewContext.delete(asset)
        try? container.viewContext.save()
        fetchRecentAssets()
    }

    // MARK: - Statistics

    var totalCount: Int {
        (try? container.viewContext.count(for: GeneratedAsset.fetchRequest())) ?? 0
    }

    var approvedCount: Int {
        let r = GeneratedAsset.fetchRequest()
        r.predicate = NSPredicate(format: "status == %@", AssetStatus.approved.rawValue)
        return (try? container.viewContext.count(for: r)) ?? 0
    }

    // MARK: - Store URL

    private static func resolveStoreURL() -> URL {
        if let vaultMeta = VaultManager.shared.vaultMetaURL {
            return vaultMeta.appending(path: "SDPipelineStudio.sqlite")
        }
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

    var icon: String {
        switch self {
        case .draft:     return "pencil.circle"
        case .approved:  return "checkmark.circle.fill"
        case .published: return "arrow.up.circle.fill"
        case .rejected:  return "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .draft:     return .gray
        case .approved:  return Color(hex: "#34d399")
        case .published: return Color(hex: "#60a5fa")
        case .rejected:  return Color(hex: "#ef4444")
        }
    }
}

// MARK: - GeneratedAsset (NSManagedObject)

@objc(GeneratedAsset)
public class GeneratedAsset: NSManagedObject {

    // Identidad
    @NSManaged public var id:             UUID?
    @NSManaged public var baseName:       String?
    @NSManaged public var version:        Int32
    @NSManaged public var createdAt:      Date?

    // Rutas de archivo
    @NSManaged public var imagePath:      String?
    @NSManaged public var cleanPath:      String?
    @NSManaged public var previewPath:    String?
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
    @NSManaged public var rating:         Int32
    @NSManaged public var status:         String?
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

// MARK: - NSManagedObjectModel programático

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

// Extensions movidas a archivos dedicados:
// sha256Hex  → Data+Crypto.swift
// pngData()  → NSImage+Helpers.swift
// resized()  → NSImage+Helpers.swift
// pretty     → Codable+Helpers.swift
