import Foundation
import SwiftUI
import Combine

// MARK: - AppEnvironment v2
//
// Orquestador de boot sequence con soporte completo para:
//   • VaultCryptoEngine (cifrado AES-256-GCM)
//   • ProjectFolderManager (estructura multi-proyecto)
//   • CoreDataPersistence (migración automática)
//   • TaggingEngine (re-índice en background)
//   • Todos los managers del roadmap
//
// CAMBIOS v2:
//   + Boot phase: crypto (cifrado del vault)
//   + Boot phase: projects (carga proyectos del disco)
//   + Boot phase: migration (validación Core Data)
//   + Tagging re-index en background tras boot
//   + runEXIFKillSwitch integra ZeroKnowledgeLog
//   + Health check ampliado con estado de cifrado

@MainActor
final class AppEnvironment: ObservableObject {

    static let shared = AppEnvironment()
    private init() {}

    // MARK: - Boot Phase

    enum BootPhase: String, CaseIterable {
        case idle        = "Iniciando…"
        case vault       = "Cargando Vault…"
        case migration   = "Migrando base de datos…"
        case persistence = "Cargando base de datos…"
        case crypto      = "Inicializando cifrado…"
        case projects    = "Cargando proyectos…"
        case legal       = "Verificando licencias…"
        case hardware    = "Detectando hardware…"
        case engines     = "Inicializando motores…"
        case tagging     = "Indexando tags…"
        case security    = "Iniciando sistemas de seguridad…"
        case backup      = "Programando backups…"
        case jobs        = "Reanudando cola de trabajos…"
        case ready       = "Listo"
        case error       = "Error en arranque"
    }

    @Published var bootPhase:     BootPhase = .idle
    @Published var isReady:       Bool      = false
    @Published var bootError:     String?   = nil
    @Published var bootProgress:  Double    = 0
    @Published var bootLog:       [String]  = []

    // MARK: - Manager References

    var vault:             VaultManager            { .shared }
    var projects:          ProjectManager           { .shared }
    var projectFolders:    ProjectFolderManager     { .shared }
    var assetStore:        AssetStore               { .shared }
    var assetVersioning:   AssetVersioningStore     { .shared }
    var promptVersioning:  PromptVersioningStore    { .shared }
    var promptDatabase:    PromptDatabase           { .shared }
    var licenseVault:      LicenseVault             { .shared }
    var licenseStore:      LicenseLocalStore        { .shared }
    var integrity:         IntegrityManager         { .shared }
    var backup:            BackupManager            { .shared }
    var tagging:           TaggingEngine            { .shared }
    var seedManager:       SeedManager              { .shared }
    var wildcards:         WildcardEngine           { .shared }
    var gpuMonitor:        GPUMonitor               { .shared }
    var mpsOptimizer:      MpsOptimizer             { .shared }
    var loraManager:       LoRAManager              { .shared }
    var modelManager:      ModelManager             { .shared }
    var embeddingsManager: EmbeddingsManager        { .shared }
    var privateRegistry:   PrivateModelRegistry     { .shared }
    var loraEncapsulation: LoRAEncapsulationEngine  { .shared }
    var kohyaTraining:     KohyaTrainingManager     { .shared }
    var characterEngine:   CharacterEngine          { .shared }
    var sceneEngine:       SceneEngine              { .shared }
    var contentSessions:   ContentSessionManager    { .shared }
    var jobQueue:          JobQueueManager          { .shared }
    var batchEngine:       BatchEngine              { .shared }
    var xyPlotEngine:      XYPlotEngine             { .shared }
    var controlNet:        ControlNetEngine         { .shared }
    var img2imgEngine:     Img2ImgEngine            { .shared }
    var inpainting:        InpaintingEngine         { .shared }
    var adetailer:         ADetailerEngine          { .shared }
    var hiRes:             HiResFinishEngine        { .shared }
    var postProd:          PostProductionEngine     { .shared }
    var cinematic:         CinematicFilterEngine    { .shared }
    var exportEngine:      ExportEngine             { .shared }
    var publishEngine:     PublishEngine            { .shared }
    var nsfwDetector:      NSFWDetector             { .shared }
    var zkLog:             ZeroKnowledgeLog         { .shared }
    var appHardening:      AppHardeningManager      { .shared }
    var privacy:           PrivacyComplianceManager { .shared }
    var consent:           ConsentTemplateManager   { .shared }
    var steganography:     SteganographyEngine      { .shared }
    var clipSearch:        ClipSearchEngine         { .shared }
    var cryptoEngine:      VaultCryptoEngine        { .shared }
    var dashboard:         DashboardViewModel       { .shared }

    // MARK: - Boot Sequence

    func boot() async {
        bootPhase    = .vault
        bootProgress = 0
        bootError    = nil
        bootLog      = []

        do {
            // ── Phase 1: Vault ─────────────────────────────────────────────
            advance(to: .vault, progress: 0.05)
            vault.checkFirstRun()
            log("Vault: \(vault.vaultRoot?.path ?? "no configurado")")

            // ── Phase 2: Core Data Migration ───────────────────────────────
            advance(to: .migration, progress: 0.10)
            // AssetStore.shared acceso carga el container
            let assetCount = assetStore.totalAssets
            log("Core Data: \(assetCount) assets cargados")

            // ── Phase 3: Persistence ───────────────────────────────────────
            advance(to: .persistence, progress: 0.15)
            projects.createDefaultProjectIfNeeded()
            log("ProjectManager: \(projects.activeProjects.count) proyectos activos")

            // ── Phase 4: Cifrado ───────────────────────────────────────────
            advance(to: .crypto, progress: 0.22)
            let cryptoKey = cryptoEngine.vaultKey  // fuerza carga/creación de clave
            log("VaultCrypto: AES-256-GCM activo, clave en Keychain")
            _ = cryptoKey

            // ── Phase 5: Projects Folder Structure ─────────────────────────
            advance(to: .projects, progress: 0.30)
            projectFolders.loadProjects()
            if projectFolders.projects.isEmpty && vault.isConfigured {
                // Crear proyecto default si el vault está configurado pero no hay proyectos
                try? projectFolders.createProject(name: "Studio Principal", color: "#7c6af7")
                log("ProjectFolderManager: proyecto default creado")
            } else {
                log("ProjectFolderManager: \(projectFolders.projects.count) proyectos cargados")
            }

            // ── Phase 6: Legal & Licencias ─────────────────────────────────
            advance(to: .legal, progress: 0.38)
            licenseVault.generateAllTemplates()
            log("LicenseVault: plantillas generadas")

            // Integrity check (no bloqueante, diferido 15s)
            Task.detached(priority: .background) {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                await IntegrityManager.shared.runScheduledCheck()
            }

            // ── Phase 7: Hardware ──────────────────────────────────────────
            advance(to: .hardware, progress: 0.46)
            gpuMonitor.detectDevice()
            let silicon = gpuMonitor.isAppleSilicon
            log("GPU: \(silicon ? "Apple Silicon (MPS)" : "Intel/NVIDIA")")
            if silicon {
                zkLog.write(category: .systemEvent, message: "Apple Silicon detected — MPS backend activo")
            }

            // ── Phase 8: Engines ───────────────────────────────────────────
            advance(to: .engines, progress: 0.55)
            _ = promptVersioning
            _ = wildcards
            _ = seedManager
            _ = contentSessions
            _ = jobQueue
            cinematic.loadPersistedPresets()
            contentSessions.refreshAllStats()
            log("Engines: inicializados")

            // ── Phase 9: Tagging Re-index ──────────────────────────────────
            advance(to: .tagging, progress: 0.65)
            let allAssets = assetStore.fetchAllAssets(limit: 5000)
            if allAssets.count > 0 {
                // Re-indexar en background para no bloquear boot
                Task.detached(priority: .utility) {
                    await TaggingEngine.shared.reindexAll(assets: allAssets)
                }
                log("TaggingEngine: re-index programado para \(allAssets.count) assets")
            }

            // ── Phase 10: Security ─────────────────────────────────────────
            advance(to: .security, progress: 0.74)
            _ = appHardening  // inicializa sandboxing y hardening
            zkLog.write(category: .systemEvent,
                        message: "App boot iniciado — session \(ZeroKnowledgeLog.currentSessionID)")
            log("Security: AppHardening + ZKLog activos")

            // ── Phase 11: Backup Scheduler ─────────────────────────────────
            advance(to: .backup, progress: 0.84)
            backup.startScheduler()
            log("Backup: scheduler iniciado")

            // ── Phase 12: Job Queue ────────────────────────────────────────
            advance(to: .jobs, progress: 0.93)
            let pending = jobQueue.totalQueued
            if pending > 0 {
                jobQueue.startQueue()
                zkLog.write(category: .systemEvent,
                            message: "Cola reanudada: \(pending) jobs pendientes")
                log("JobQueue: \(pending) jobs reanudados")
            }

            // ── Phase 13: Dashboard ────────────────────────────────────────
            dashboard.refresh()

            advance(to: .ready, progress: 1.0)
            isReady = true
            log("Boot completado en \(bootLog.count) fases")

        } catch {
            bootPhase = .error
            bootError = error.localizedDescription
            zkLog.write(category: .systemEvent,
                        message: "ERROR en boot: \(error.localizedDescription)")
            log("ERROR: \(error.localizedDescription)")
        }
    }

    private func advance(to phase: BootPhase, progress: Double) {
        bootPhase    = phase
        bootProgress = progress
    }

    private func log(_ message: String) {
        bootLog.append("[\(bootPhase.rawValue)] \(message)")
    }

    // MARK: - Global App Actions

    /// Purgar EXIF de todos los assets exportados (Kill-Switch global).
    func runEXIFKillSwitch() async {
        let assets = assetStore.fetchAllAssets(limit: 2000)
        var count  = 0
        for asset in assets {
            if let path = asset.cleanPath, !path.isEmpty {
                let url = URL(fileURLWithPath: path)
                if (try? exportEngine.stripEXIF(from: url)) != nil { count += 1 }
            }
            if let path = asset.previewPath, !path.isEmpty {
                let url = URL(fileURLWithPath: path)
                if (try? exportEngine.stripEXIF(from: url)) != nil { count += 1 }
            }
        }
        zkLog.write(category: .exportPerformed,
                    message: "EXIF Kill-Switch ejecutado — \(count) archivos purgados")
    }

    /// Re-cifrar vault completo con nueva clave.
    func rotateEncryptionKey() async throws -> Int {
        let count = try await cryptoEngine.rotateVaultKey()
        zkLog.write(category: .systemEvent,
                    message: "Rotación de clave completada — \(count) archivos re-cifrados")
        return count
    }

    /// Reporte de auditoría completo.
    func generateAuditReport() async -> AuditReport {
        let zkEntries  = zkLog.entries(limit: 500)
        let intSnap    = IntegrityManager.shared.auditSnapshot
        let backupInfo = backup.config
        let assets     = assetStore.fetchAllAssets(limit: 5000)

        return AuditReport(
            generatedAt:     Date(),
            sessionID:       ZeroKnowledgeLog.currentSessionID,
            totalAssets:     assets.count,
            approvedAssets:  assets.filter { $0.statusEnum == .approved }.count,
            publishedAssets: assets.filter { $0.statusEnum == .published }.count,
            securityEvents:  zkEntries.count,
            blockedPrompts:  zkEntries.filter { $0.category == .promptBlocked }.count,
            nsfwDetections:  zkEntries.filter { $0.category == .nsfwDetected }.count,
            lastBackupOK:    backupInfo.lastBackupOK,
            lastBackupDate:  backupInfo.lastBackupDate,
            integrityPassed: intSnap.corrupted == 0,
            integrityDate:   intSnap.runDate,
            securityLog:     zkEntries,
            encryptionActive: cryptoEngine.isEncryptionEnabled,
            activeProjects:   projectFolders.projects.count,
            totalTags:        tagging.uniqueTagCount
        )
    }

    // MARK: - Vault Health

    var vaultIsHealthy: Bool {
        vault.isConfigured && projects.activeProjects.count > 0
    }

    var encryptionIsActive: Bool { cryptoEngine.isEncryptionEnabled }

    var fullHealthStatus: String {
        var issues: [String] = []
        if !vault.isConfigured        { issues.append("Vault no configurado") }
        if !encryptionIsActive         { issues.append("Cifrado desactivado") }
        if !backup.config.lastBackupOK { issues.append("Último backup falló") }
        if IntegrityManager.shared.corruptedCount > 0 {
            issues.append("\(IntegrityManager.shared.corruptedCount) assets corruptos")
        }
        return issues.isEmpty ? "✅ Sistema saludable" : "⚠️ " + issues.joined(separator: " · ")
    }
}

// MARK: - AuditReport (extended)

struct AuditReport: Codable {
    let generatedAt:      Date
    let sessionID:        String
    let totalAssets:      Int
    let approvedAssets:   Int
    let publishedAssets:  Int
    let securityEvents:   Int
    let blockedPrompts:   Int
    let nsfwDetections:   Int
    let lastBackupOK:     Bool
    let lastBackupDate:   Date?
    let integrityPassed:  Bool
    let integrityDate:    Date?
    let securityLog:      [ZeroKnowledgeLog.LogEntry]
    let encryptionActive: Bool
    let activeProjects:   Int
    let totalTags:        Int

    var summaryText: String {
        """
        SDPipelineStudio — Reporte de Auditoría
        Generado: \(generatedAt.formatted(date: .complete, time: .standard))
        Sesión ID: \(sessionID)

        ── Assets ──────────────────────────────
        Total:      \(totalAssets)
        Aprobados:  \(approvedAssets)
        Publicados: \(publishedAssets)
        Tags únicos:\(totalTags)

        ── Proyectos ────────────────────────────
        Activos:    \(activeProjects)

        ── Seguridad ────────────────────────────
        Cifrado:       \(encryptionActive ? "✅ AES-256-GCM" : "❌ Desactivado")
        Eventos:       \(securityEvents)
        Prompts bloq.: \(blockedPrompts)
        NSFW detect.:  \(nsfwDetections)

        ── Integridad ───────────────────────────
        Estado:        \(integrityPassed ? "✅ OK" : "⚠️ Advertencias")
        Último check:  \(integrityDate?.formatted() ?? "No ejecutado")

        ── Backup ───────────────────────────────
        Último backup: \(lastBackupDate?.formatted() ?? "Nunca")
        Estado:        \(lastBackupOK ? "✅ OK" : "⚠️ Falló")
        """
    }
}

// MARK: - IntegrityManager audit bridge

extension IntegrityManager {
    var auditSnapshot: (runDate: Date?, ok: Int, corrupted: Int, missing: Int) {
        (lastRunAt, okCount, corruptedCount, missingCount)
    }
}
