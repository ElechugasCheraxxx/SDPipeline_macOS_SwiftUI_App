import Foundation
import CoreData
import CryptoKit
import Combine

// MARK: - CoreDataPersistence
//
// Capa de persistencia centralizada para SDPipelineStudio.
// Gestiona el NSPersistentContainer con el modelo de datos completo
// incluyendo todas las entidades requeridas por el roadmap.
//
// Entidades:
//   • GeneratedAsset    — imágenes generadas con metadatos completos
//   • PromptRecord      — historial de prompts con versionado
//   • CharacterProfile  — perfiles JSON de personajes
//   • ContentSession    — sesiones de contenido (sets fotográficos)
//   • ProjectRecord     — proyectos del studio
//   • SeedRecord        — seeds favoritos por personaje
//   • AuditEvent        — eventos de auditoría cifrados
//
// ROADMAP: Persistencia con Core Data (🔴 INMEDIATO)

@MainActor
final class CoreDataPersistence: ObservableObject {

    static let shared = CoreDataPersistence()
    private init() { setup() }

    // MARK: - Container

    let container: NSPersistentContainer

    private func setup() {
        // Usar modelo programático para evitar dependencia de .xcdatamodeld
        // AssetStore.swift ya inicializa el container — aquí extendemos el modelo
    }

    init(inMemory: Bool = false) {
        container = NSPersistentContainer(
            name: "SDPipelineStudio",
            managedObjectModel: Self.buildFullModel()
        )
        if inMemory {
            container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
        }
        container.loadPersistentStores { _, error in
            if let error { fatalError("CoreData failed: \(error)") }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    // MARK: - Full Model Builder

    static func buildFullModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()

        func attr(_ name: String, _ type: NSAttributeType, optional: Bool = true) -> NSAttributeDescription {
            let a = NSAttributeDescription()
            a.name = name; a.attributeType = type; a.isOptional = optional
            return a
        }

        // ── GeneratedAsset ───────────────────────────────────────────────
        let assetEntity = NSEntityDescription()
        assetEntity.name = "GeneratedAsset"
        assetEntity.managedObjectClassName = "GeneratedAsset"
        assetEntity.properties = [
            attr("id",               .UUIDAttributeType,       optional: false),
            attr("baseName",         .stringAttributeType),
            attr("version",          .integer32AttributeType,  optional: false),
            attr("createdAt",        .dateAttributeType),
            attr("imagePath",        .stringAttributeType),
            attr("cleanPath",        .stringAttributeType),
            attr("previewPath",      .stringAttributeType),
            attr("sidecarPath",      .stringAttributeType),
            attr("promptPositive",   .stringAttributeType),
            attr("promptNegative",   .stringAttributeType),
            attr("seed",             .integer64AttributeType,  optional: false),
            attr("steps",            .integer32AttributeType,  optional: false),
            attr("cfgScale",         .doubleAttributeType,     optional: false),
            attr("samplerName",      .stringAttributeType),
            attr("width",            .integer32AttributeType,  optional: false),
            attr("height",           .integer32AttributeType,  optional: false),
            attr("modelName",        .stringAttributeType),
            attr("checkpoint",       .stringAttributeType),
            attr("vaeUsed",          .stringAttributeType),
            attr("loraWeightsJSON",  .stringAttributeType),
            attr("sha256",           .stringAttributeType),
            attr("rating",           .integer32AttributeType,  optional: false),
            attr("status",           .stringAttributeType),
            attr("sessionTag",       .stringAttributeType),
            attr("notes",            .stringAttributeType),
            attr("tags",             .stringAttributeType),
            attr("characterID",      .UUIDAttributeType),
            attr("projectID",        .UUIDAttributeType),
            attr("thumbnailData",    .binaryDataAttributeType),
            attr("hiresEnabled",     .booleanAttributeType),
            attr("hiresUpscaler",    .stringAttributeType),
            attr("hiresScale",       .doubleAttributeType),
            attr("denoisingStrength",.doubleAttributeType),
            attr("controlNetJSON",   .stringAttributeType),
            attr("stegEmbedded",     .booleanAttributeType),
            attr("nsfwFlagged",      .booleanAttributeType),
            attr("publishedAt",      .dateAttributeType),
            attr("exportedAt",       .dateAttributeType),
        ]

        // ── PromptRecord ─────────────────────────────────────────────────
        let promptEntity = NSEntityDescription()
        promptEntity.name = "PromptRecord"
        promptEntity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        promptEntity.properties = [
            attr("id",           .UUIDAttributeType,      optional: false),
            attr("title",        .stringAttributeType),
            attr("positive",     .stringAttributeType),
            attr("negative",     .stringAttributeType),
            attr("version",      .integer32AttributeType, optional: false),
            attr("parentID",     .UUIDAttributeType),
            attr("createdAt",    .dateAttributeType),
            attr("successRate",  .doubleAttributeType),
            attr("useCount",     .integer32AttributeType, optional: false),
            attr("tags",         .stringAttributeType),
            attr("characterID",  .UUIDAttributeType),
            attr("projectID",    .UUIDAttributeType),
        ]

        // ── CharacterProfile ─────────────────────────────────────────────
        let charEntity = NSEntityDescription()
        charEntity.name = "CharacterProfile"
        charEntity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        charEntity.properties = [
            attr("id",             .UUIDAttributeType,      optional: false),
            attr("name",           .stringAttributeType),
            attr("jsonBlob",       .stringAttributeType),
            attr("baseImagePath",  .stringAttributeType),
            attr("thumbnailData",  .binaryDataAttributeType),
            attr("createdAt",      .dateAttributeType),
            attr("updatedAt",      .dateAttributeType),
            attr("projectID",      .UUIDAttributeType),
            attr("favoriteSeed",   .integer64AttributeType),
        ]

        // ── ContentSession ───────────────────────────────────────────────
        let sessionEntity = NSEntityDescription()
        sessionEntity.name = "ContentSession"
        sessionEntity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        sessionEntity.properties = [
            attr("id",          .UUIDAttributeType,      optional: false),
            attr("title",       .stringAttributeType),
            attr("category",    .stringAttributeType),
            attr("platform",    .stringAttributeType),
            attr("createdAt",   .dateAttributeType),
            attr("updatedAt",   .dateAttributeType),
            attr("assetCount",  .integer32AttributeType, optional: false),
            attr("projectID",   .UUIDAttributeType),
            attr("notes",       .stringAttributeType),
            attr("exportedAt",  .dateAttributeType),
        ]

        // ── ProjectRecord ────────────────────────────────────────────────
        let projectEntity = NSEntityDescription()
        projectEntity.name = "ProjectRecord"
        projectEntity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        projectEntity.properties = [
            attr("id",          .UUIDAttributeType,      optional: false),
            attr("name",        .stringAttributeType),
            attr("color",       .stringAttributeType),
            attr("createdAt",   .dateAttributeType),
            attr("updatedAt",   .dateAttributeType),
            attr("isActive",    .booleanAttributeType),
            attr("vaultSubdir", .stringAttributeType),
            attr("notes",       .stringAttributeType),
        ]

        // ── SeedRecord ───────────────────────────────────────────────────
        let seedEntity = NSEntityDescription()
        seedEntity.name = "SeedRecord"
        seedEntity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        seedEntity.properties = [
            attr("id",          .UUIDAttributeType,      optional: false),
            attr("seed",        .integer64AttributeType, optional: false),
            attr("label",       .stringAttributeType),
            attr("characterID", .UUIDAttributeType),
            attr("projectID",   .UUIDAttributeType),
            attr("rating",      .integer32AttributeType, optional: false),
            attr("useCount",    .integer32AttributeType, optional: false),
            attr("createdAt",   .dateAttributeType),
            attr("notes",       .stringAttributeType),
        ]

        // ── AuditEvent ───────────────────────────────────────────────────
        let auditEntity = NSEntityDescription()
        auditEntity.name = "AuditEvent"
        auditEntity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        auditEntity.properties = [
            attr("id",          .UUIDAttributeType,      optional: false),
            attr("timestamp",   .dateAttributeType),
            attr("category",    .stringAttributeType),
            attr("message",     .stringAttributeType),
            attr("sessionID",   .stringAttributeType),
            attr("encrypted",   .booleanAttributeType),
            attr("payload",     .binaryDataAttributeType),
        ]

        model.entities = [
            assetEntity, promptEntity, charEntity,
            sessionEntity, projectEntity, seedEntity, auditEntity
        ]
        return model
    }

    // MARK: - Save

    func save() {
        let ctx = container.viewContext
        guard ctx.hasChanges else { return }
        do { try ctx.save() }
        catch { print("CoreData save error: \(error)") }
    }

    func saveBackground(_ block: @escaping (NSManagedObjectContext) -> Void) {
        container.performBackgroundTask { ctx in
            block(ctx)
            if ctx.hasChanges { try? ctx.save() }
        }
    }

    // MARK: - Migration Helper

    /// Verifica que el store actual sea compatible con el modelo.
    /// Si no, intenta migración ligera automática.
    func validateAndMigrateIfNeeded() {
        guard let storeURL = container.persistentStoreDescriptions.first?.url else { return }
        let coordinator = container.persistentStoreCoordinator
        let options: [String: Any] = [
            NSMigratePersistentStoresAutomaticallyOption: true,
            NSInferMappingModelAutomaticallyOption: true
        ]
        if let store = coordinator.persistentStore(for: storeURL) {
            _ = store // store already loaded
        } else {
            try? coordinator.addPersistentStore(
                ofType: NSSQLiteStoreType,
                configurationName: nil,
                at: storeURL,
                options: options
            )
        }
    }
}

// MARK: - Convenience fetch helpers

extension NSManagedObjectContext {

    func fetchAll<T: NSManagedObject>(_ type: T.Type,
                                      predicate: NSPredicate? = nil,
                                      sortKey: String? = nil,
                                      ascending: Bool = false,
                                      limit: Int = 0) -> [T] {
        let request = NSFetchRequest<T>(entityName: String(describing: type))
        request.predicate = predicate
        if let key = sortKey {
            request.sortDescriptors = [NSSortDescriptor(key: key, ascending: ascending)]
        }
        if limit > 0 { request.fetchLimit = limit }
        return (try? fetch(request)) ?? []
    }

    func count<T: NSManagedObject>(_ type: T.Type, predicate: NSPredicate? = nil) -> Int {
        let request = NSFetchRequest<T>(entityName: String(describing: type))
        request.predicate = predicate
        return (try? count(for: request)) ?? 0
    }
}
