import Foundation
import SwiftUI
import Combine

// MARK: - AppEnvironment
//
// Contenedor central de dependencias y orquestador de boot sequence.
// Reemplaza la inicialización dispersa de singletons en SDPipelineApp.
//
// Responsabilidades:
//   1. Punto único de acceso a todos los managers (DI simplificado)
//   2. Boot sequence ordenado por fases con logging
//   3. Estado global de la app (isReady, bootError)
//   4. Notificaciones de cambios cross-cutting (e.g., vaultChanged)
//
// Uso:
//   @EnvironmentObject var env: AppEnvironment
//   env.vault.vaultRoot
//   env.assetStore.recentAssets
//
// ROADMAP: Arquitectura escalable — requerida para testing y modularización.

@MainActor
final class AppEnvironment: ObservableObject {

    // MARK: - Singleton
    static let shared = AppEnvironment()
    private init() {}

    // MARK: - Boot State

    enum BootPhase: String, CaseIterable {
        case idle         = "Iniciando…"
        case vault        = "Cargando Vault…"
        case persistence  = "Cargando base de datos…"
        case legal        = "Verificando licencias…"
        case hardware     = "Detectando hardware…"
        case engines      = "Inicializando motores…"
        case security     = "Iniciando sistemas de seguridad…"
        case backup       = "Programando backups…"
        case jobs         = "Reanudando cola de trabajos…"
        case ready        = "Listo"
        case error        = "Error en arranque"
    }

    @Published var bootPhase:  BootPhase = .idle
    @Published var isReady:    Bool      = false
    @Published var bootError:  String?   = nil
    @Published var bootProgress: Double  = 0

    // MARK: - Manager References (lazy access — not retained here, managers are singletons)

    var vault:            VaultManager            { .shared }
    var projects:         ProjectManager           { .shared }
    var assetStore:       AssetStore               { .shared }
    var assetVersioning:  AssetVersioningStore     { .shared }
    var promptVersioning: PromptVersioningStore    { .shared }
    var promptDatabase:   PromptDatabase           { .shared }
    var licenseVault:     LicenseVault             { .shared }
    var licenseStore:     LicenseLocalStore        { .shared }
    var integrity:        IntegrityManager         { .shared }
    var backup:           BackupManager            { .shared }
    var tagging:          TaggingEngine            { .shared }
    var seedManager:      SeedManager              { .shared }
    var wildcards:        WildcardEngine           { .shared }
    var gpuMonitor:       GPUMonitor               { .shared }
    var mpsOptimizer:     MpsOptimizer             { .shared }
    var loraManager:      LoRAManager              { .shared }
    var modelManager:     ModelManager             { .shared }
    var embeddingsManager: EmbeddingsManager       { .shared }
    var privateRegistry:  PrivateModelRegistry     { .shared }
    var loraEncapsulation: LoRAEncapsulationEngine { .shared }
    var kohyaTraining:    KohyaTrainingManager     { .shared }
    var characterEngine:  CharacterEngine          { .shared }
    var sceneEngine:      SceneEngine              { .shared }
    var contentSessions:  ContentSessionManager    { .shared }
    var jobQueue:         JobQueueManager          { .shared }
    var batchEngine:      BatchEngine              { .shared }
    var xyPlotEngine:     XYPlotEngine             { .shared }
    var controlNet:       ControlNetEngine         { .shared }
    var img2imgEngine:    Img2ImgEngine            { .shared }
    var inpainting:       InpaintingEngine         { .shared }
    var adetailer:        ADetailerEngine          { .shared }
    var hiRes:            HiResFinishEngine        { .shared }
    var postProd:         PostProductionEngine     { .shared }
    var cinematic:        CinematicFilterEngine    { .shared }
    var exportEngine:     ExportEngine             { .shared }
    var publishEngine:    PublishEngine            { .shared }
    var nsfwDetector:     NSFWDetector             { .shared }
    var zkLog:            ZeroKnowledgeLog         { .shared }
    var appHardening:     AppHardeningManager      { .shared }
    var privacy:          PrivacyComplianceManager { .shared }
    var consent:          ConsentTemplateManager   { .shared }
    var steganography:    SteganographyEngine      { .shared }
    var clipSearch:       ClipSearchEngine         { .shared }
    var dashboard:        DashboardViewModel       { .shared }

    // MARK: - Boot Sequence

    func boot() async {
        bootPhase    = .vault
        bootProgress = 0
        bootError    = nil

        do {
            // ── Phase 1: Vault & Persistence ──────────────────────────────
            advance(to: .vault, progress: 0.05)
            vault.checkFirstRun()

            advance(to: .persistence, progress: 0.15)
            projects.createDefaultProjectIfNeeded()

            // ── Phase 2: Legal & Integrity ─────────────────────────────────
            advance(to: .legal, progress: 0.25)
            licenseVault.generateAllTemplates()

            // Integrity check (non-blocking, 10s delay)
            Task.detached(priority: .background) {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                await IntegrityManager.shared.runScheduledCheck()
            }

            // ── Phase 3: Hardware Detection ────────────────────────────────
            advance(to: .hardware, progress: 0.38)
            gpuMonitor.detectDevice()
            if gpuMonitor.isAppleSilicon {
                zkLog.write(category: .systemEvent, message: "Apple Silicon detected — MPS backend activo")
            }

            // ── Phase 4: Engines ───────────────────────────────────────────
            advance(to: .engines, progress: 0.52)
            _ = promptVersioning
            _ = tagging
            _ = wildcards
            _ = seedManager
            _ = contentSessions
            _ = jobQueue
            cinematic.loadPersistedPresets()
            contentSessions.refreshAllStats()

            // ── Phase 5: Security ──────────────────────────────────────────
            advance(to: .security, progress: 0.68)
            // AppHardeningManager auto-initializes on first access
            zkLog.write(category: .systemEvent, message: "App boot iniciado — session \(ZeroKnowledgeLog.currentSessionID)")

            // ── Phase 6: Backup Scheduler ──────────────────────────────────
            advance(to: .backup, progress: 0.82)
            backup.startScheduler()

            // ── Phase 7: Job Queue Resume ──────────────────────────────────
            advance(to: .jobs, progress: 0.92)
            if jobQueue.totalQueued > 0 {
                jobQueue.startQueue()
                zkLog.write(category: .systemEvent,
                            message: "Cola reanudada: \(jobQueue.totalQueued) jobs pendientes")
            }

            // ── Phase 8: Dashboard ─────────────────────────────────────────
            dashboard.refresh()

            advance(to: .ready, progress: 1.0)
            isReady = true

        } catch {
            bootPhase = .error
            bootError = error.localizedDescription
            zkLog.write(category: .systemEvent,
                        message: "ERROR en boot: \(error.localizedDescription)")
        }
    }

    private func advance(to phase: BootPhase, progress: Double) {
        bootPhase    = phase
        bootProgress = progress
    }

    // MARK: - Global App Actions

    /// Purgar EXIF de todos los assets exportados (Kill-Switch global).
    func runEXIFKillSwitch() {
        let assets = assetStore.fetchAllAssets(limit: 1000)
        var count  = 0
        for asset in assets {
            if let path = asset.cleanPath, !path.isEmpty {
                let url = URL(fileURLWithPath: path)
                if (try? exportEngine.stripEXIF(from: url)) != nil { count += 1 }
            }
        }
        zkLog.write(category: .exportPerformed,
                    message: "EXIF Kill-Switch ejecutado — \(count) archivos purgados")
    }

    /// Generar reporte de auditoría completo para exportar.
    func generateAuditReport() async -> AuditReport {
        let zkEntries   = zkLog.entries(limit: 500)
        let intSnap     = IntegrityManager.shared.auditSnapshot
        let backupInfo  = backup.config
        let assets      = assetStore.fetchAllAssets(limit: 2000)

        return AuditReport(
            generatedAt:      Date(),
            sessionID:        ZeroKnowledgeLog.currentSessionID,
            totalAssets:      assets.count,
            approvedAssets:   assets.filter { $0.statusEnum == .approved }.count,
            publishedAssets:  assets.filter { $0.statusEnum == .published }.count,
            securityEvents:   zkEntries.count,
            blockedPrompts:   zkEntries.filter { $0.category == .promptBlocked }.count,
            nsfwDetections:   zkEntries.filter { $0.category == .nsfwDetected }.count,
            lastBackupOK:     backupInfo.lastBackupOK,
            lastBackupDate:   backupInfo.lastBackupDate,
            integrityPassed:  intSnap.corrupted == 0,
            integrityDate:    intSnap.runDate,
            securityLog:      zkEntries
        )
    }

    // MARK: - Vault Health

    var vaultIsHealthy: Bool {
        vault.isConfigured && projects.activeProjects.count > 0
    }
}

// MARK: - AuditReport

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

    var summaryText: String {
        """
        SDPipelineStudio — Reporte de Auditoría
        Generado: \(generatedAt.formatted(date: .complete, time: .standard))
        Sesión ID: \(sessionID)

        ── Assets ──────────────────────────────
        Total:      \(totalAssets)
        Aprobados:  \(approvedAssets)
        Publicados: \(publishedAssets)

        ── Seguridad ────────────────────────────
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
    /// Summary snapshot for AuditReport — uses real @Published properties.
    var auditSnapshot: (runDate: Date?, ok: Int, corrupted: Int, missing: Int) {
        (lastRunAt, okCount, corruptedCount, missingCount)
    }
}
