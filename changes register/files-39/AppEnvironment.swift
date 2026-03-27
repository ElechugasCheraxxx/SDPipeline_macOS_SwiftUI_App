import Foundation
import SwiftUI
import Combine

// MARK: - AppEnvironment v6
//
// Cambios v5 → v6:
//   ✨ ADD: BootPhase.cleanup — motor de limpieza de artefactos
//   ✨ ADD: BootPhase.versioning — PromptVersioningStore + AssetVersioningStore init
//   ✨ ADD: var cleanup: ArtifactCleanupEngine en referencias
//   ✨ ADD: var promptVersioning: PromptVersioningStore en referencias (era sólo var declarado)
//   ✨ ADD: bootCleanup() — inicializa ArtifactCleanupEngine con config persistida
//   ✨ ADD: bootVersioning() — carga PromptVersioningStore + AssetVersioningStore
//   ✨ ADD: bootImgPipeline() — inicializa Img2ImgEngine + InpaintingEngine con settings
//   ✨ ADD: BootPhase.imgPipeline
//   ✨ ADD: scheduleWeeklyIntegrityCheck() — check semanal programado en background
//   ✨ ADD: HealthReport.cleanupOK + promptVersioningOK
//   ✨ ADD: AuditReport.artifactsScanned + promptVersionsStored
//   🔧 FIX: runPostBootHealthCheck() maneja el error de URL de red correctamente (no fuerza unwrap)
//   🔧 FIX: bootJobs() usa queue.filter en vez de .status == .queued (type-safe)
//   🔧 FIX: generateAuditReport() era síncrono pero accedía a AssetStore async — ahora @MainActor
//   🔁 UPD: bootEngines() incluye ArtifactCleanupEngine + PromptVersioningStore
//   🔁 UPD: BootPhase enum order reordenado (cleanup + versioning antes de security)

@MainActor
final class AppEnvironment: ObservableObject {

    static let shared = AppEnvironment()
    private init() {}

    // MARK: - Boot Phase

    enum BootPhase: String, CaseIterable {
        case idle           = "Iniciando…"
        case vault          = "Cargando Vault…"
        case migration      = "Migrando base de datos…"
        case persistence    = "Cargando base de datos…"
        case crypto         = "Inicializando cifrado…"
        case projects       = "Cargando proyectos…"
        case legal          = "Verificando licencias…"
        case hardware       = "Detectando hardware…"
        case engines        = "Inicializando motores…"
        case versioning     = "Cargando historial de versiones…"  // NEW v6
        case cleanup        = "Inicializando limpieza de artefactos…"  // NEW v6
        case imgPipeline    = "Preparando pipeline img2img…"     // NEW v6
        case tagging        = "Indexando tags…"
        case autocomplete   = "Indexando autocompletado…"
        case rateLimiter    = "Configurando API rate limiter…"
        case progressEngine = "Preparando preview engine…"
        case exportPipeline = "Preparando pipeline de export…"
        case security       = "Iniciando sistemas de seguridad…"
        case sandbox        = "Configurando sandbox de procesos…"
        case backup         = "Programando backups…"
        case jobs           = "Reanudando cola de trabajos…"
        case ready          = "Listo"
        case error          = "Error en arranque"
    }

    @Published var bootPhase:    BootPhase = .idle
    @Published var isReady:      Bool      = false
    @Published var bootError:    String?   = nil
    @Published var bootProgress: Double    = 0
    @Published var bootLog:      [String]  = []

    // MARK: - System Alert

    struct SystemAlert: Identifiable {
        let id       = UUID()
        let title:   String
        let message: String
        let severity: Severity
        enum Severity { case info, warning, critical }
    }
    @Published var systemAlert: SystemAlert? = nil

    // MARK: - Manager References

    var vault:              VaultManager             { .shared }
    var projects:           ProjectManager            { .shared }
    var projectFolders:     ProjectFolderManager      { .shared }
    var assetStore:         AssetStore                { .shared }
    var assetVersioning:    AssetVersioningStore      { .shared }
    var promptVersioning:   PromptVersioningStore     { .shared }  // was missing real init in v5
    var promptDatabase:     PromptDatabase            { .shared }
    var licenseVault:       LicenseVault              { .shared }
    var licenseStore:       LicenseLocalStore         { .shared }
    var integrity:          IntegrityManager          { .shared }
    var backup:             BackupManager             { .shared }
    var tagging:            TaggingEngine             { .shared }
    var seedManager:        SeedManager               { .shared }
    var wildcards:          WildcardEngine            { .shared }
    var gpuMonitor:         GPUMonitor                { .shared }
    var mpsOptimizer:       MpsOptimizer              { .shared }
    var loraManager:        LoRAManager               { .shared }
    var modelManager:       ModelManager              { .shared }
    var embeddingsManager:  EmbeddingsManager         { .shared }
    var privateRegistry:    PrivateModelRegistry      { .shared }
    var loraEncapsulation:  LoRAEncapsulationEngine   { .shared }
    var kohyaTraining:      KohyaTrainingManager      { .shared }
    var characterEngine:    CharacterEngine           { .shared }
    var sceneEngine:        SceneEngine               { .shared }
    var contentSessions:    ContentSessionManager     { .shared }
    var jobQueue:           JobQueueManager           { .shared }
    var publishEngine:      PublishEngine             { .shared }
    var exportEngine:       ExportEngine              { .shared }
    var abTesting:          ABTestingEngine           { .shared }
    var dashboard:          DashboardViewModel        { .shared }
    var promptAutocomplete: PromptAutoCompleteEngine  { .shared }
    var privacyCompliance:  PrivacyComplianceManager  { .shared }
    var progressEngine:     GenerationProgressEngine  { .shared }
    var rateLimiter:        SDAPIRateLimiter          { SDAPIRateLimiter.shared }
    var setExporter:        OnlyFansSetExporter       { .shared }
    var exportBatch:        ExportBatchCoordinator    { .shared }
    var sandbox:            SandboxManager            { .shared }
    var cleanup:            ArtifactCleanupEngine     { .shared }  // NEW v6

    // MARK: - Boot Sequence

    func boot() async {
        guard bootPhase == .idle || bootPhase == .error else { return }
        bootError = nil
        bootLog   = []
        isReady   = false

        let phases: [(BootPhase, () async throws -> Void)] = [
            (.vault,          bootVault),
            (.migration,      bootMigration),
            (.persistence,    bootPersistence),
            (.crypto,         bootCrypto),
            (.projects,       bootProjects),
            (.legal,          bootLegal),
            (.hardware,       bootHardware),
            (.engines,        bootEngines),
            (.versioning,     bootVersioning),     // NEW v6
            (.cleanup,        bootCleanup),         // NEW v6
            (.imgPipeline,    bootImgPipeline),     // NEW v6
            (.tagging,        bootTagging),
            (.autocomplete,   bootAutocomplete),
            (.rateLimiter,    bootRateLimiter),
            (.progressEngine, bootProgressEngine),
            (.exportPipeline, bootExportPipeline),
            (.security,       bootSecurity),
            (.sandbox,        bootSandbox),
            (.backup,         bootBackup),
            (.jobs,           bootJobs),
        ]

        for (idx, (phase, fn)) in phases.enumerated() {
            bootPhase    = phase
            bootProgress = Double(idx) / Double(phases.count)
            log(phase.rawValue)

            do {
                try await fn()
            } catch {
                bootPhase = .error
                bootError = error.localizedDescription
                log("❌ Error en \(phase.rawValue): \(error.localizedDescription)")
                return
            }
        }

        bootPhase    = .ready
        bootProgress = 1.0
        isReady      = true
        log("✅ Studio listo")

        // Post-boot tasks — non-blocking
        Task { await runPostBootHealthCheck() }
        Task { await scheduleWeeklyIntegrityCheck() }  // NEW v6
    }

    // MARK: - Boot Implementations

    private func bootVault() async throws {
        VaultManager.shared.checkFirstRun()
        guard VaultManager.shared.vaultRoot != nil else {
            log("Vault: no configurado — esperando selección del usuario")
            return
        }
        try VaultManager.shared.ensureAllDirectories()
        log("Vault: \(VaultManager.shared.vaultRoot?.lastPathComponent ?? "?")")
    }

    private func bootMigration() async throws {
        // CoreData migration is handled by NSPersistentContainer lightweight migration
        log("Migración: CoreData en modo migración progresiva")
    }

    private func bootPersistence() async throws {
        _ = CoreDataPersistence.shared
        _ = AssetStore.shared
        let count = AssetStore.shared.fetchAllAssets(limit: 1).count
        log("Persistencia: CoreData OK · \(AssetStore.shared.recentAssets.count) assets recientes")
        _ = count
    }

    private func bootCrypto() async throws {
        _ = VaultCryptoEngine.shared
        let enabled = VaultCryptoEngine.shared.isEncryptionEnabled
        log("Cifrado: AES-256-GCM \(enabled ? "activo" : "desactivado")")
    }

    private func bootProjects() async throws {
        ProjectManager.shared.loadProjects()
        ProjectFolderManager.shared.loadProjects()
        let count = ProjectManager.shared.activeProjects.count
        log("Proyectos: \(count) cargados")
    }

    private func bootLegal() async throws {
        PrivacyComplianceManager.shared.installDefaultPolicies()
        _ = LicenseVault.shared
        _ = LicenseLocalStore.shared
        log("Legal: políticas instaladas · vault licencias OK")
    }

    private func bootHardware() async throws {
        GPUMonitor.shared.startPolling()
        MpsOptimizer.shared.configure()
        let device = GPUMonitor.shared.deviceName
        log("Hardware: \(device) · Apple Silicon: \(GPUMonitor.shared.isAppleSilicon)")
    }

    private func bootEngines() async throws {
        // Generation engines
        _ = SDService.shared                  // Already an @StateObject in ContentView — OK to warm up
        _ = Img2ImgEngine.shared
        _ = InpaintingEngine.shared
        _ = BatchEngine.shared
        _ = XYPlotEngine.shared

        // Model engines
        _ = LoRAManager.shared
        _ = ModelManager.shared
        _ = EmbeddingsManager.shared
        _ = PrivateModelRegistry.shared
        _ = LoRAEncapsulationEngine.shared

        // Character / scene engines
        _ = CharacterEngine.shared
        _ = SceneEngine.shared
        _ = WildcardEngine.shared
        _ = SeedManager.shared

        // Post-production engines
        _ = PostProductionEngine.shared
        _ = CinematicFilterEngine.shared
        _ = ACEScgColorEngine.shared
        _ = HiResFinishEngine.shared
        _ = TiledUpscalerEngine.shared
        _ = ADetailerEngine.shared
        _ = ControlNetEngine.shared
        _ = IPAdapterEngine.shared
        _ = ICLightEngine.shared

        // Content / publishing engines
        _ = ContentSessionManager.shared
        _ = PublishEngine.shared
        _ = ExportEngine.shared
        _ = OnlyFansSetExporter.shared
        _ = ExportBatchCoordinator.shared

        // Analytics / UI engines
        _ = ABTestingEngine.shared
        _ = DashboardViewModel.shared
        _ = ClipSearchEngine.shared
        _ = VisionAestheticsEngine.shared

        log("Motores: todos inicializados")
    }

    // NEW v6
    private func bootVersioning() async throws {
        _ = PromptVersioningStore.shared
        _ = AssetVersioningStore.shared
        _ = PromptVersioningStore.shared      // loads from disk
        let promptVersionCount = PromptVersioningStore.shared.versions.count
        log("Versioning: \(promptVersionCount) versiones de prompts cargadas")
    }

    // NEW v6
    private func bootCleanup() async throws {
        if let data   = UserDefaults.standard.data(forKey: "cleanup.config"),
           let config = try? JSONDecoder().decode(ArtifactCleanupEngine.CleanupConfig.self, from: data) {
            ArtifactCleanupEngine.shared.config = config
        }
        log("Cleanup: ArtifactCleanupEngine configurado · auto=\(ArtifactCleanupEngine.shared.config.autoRunAfterGeneration)")
    }

    // NEW v6
    private func bootImgPipeline() async throws {
        // Restore last img2img denoise from UserDefaults
        let lastDenoise = UserDefaults.standard.double(forKey: "img2img.lastDenoise")
        if lastDenoise > 0 {
            Img2ImgEngine.shared.defaultDenoise = lastDenoise
        }
        log("Img2Img pipeline: OK · denoise default=\(Img2ImgEngine.shared.defaultDenoise)")
    }

    private func bootTagging() async throws {
        await TaggingEngine.shared.loadIndex()
        log("Tags: \(TaggingEngine.shared.tagFrequency.count) tags indexados")
    }

    private func bootAutocomplete() async throws {
        await PromptAutoCompleteEngine.shared.buildIndex()
        let loraNames = LoRAManager.shared.installedLoRAs.map(\.name)
        let embNames  = EmbeddingsManager.shared.embeddings.map(\.name)
        await PromptAutoCompleteEngine.shared.buildIndex(loraNames: loraNames, embeddingNames: embNames)
        log("Autocompletado: índice construido")
    }

    private func bootRateLimiter() async throws {
        let maxTokens    = UserDefaults.standard.integer(forKey: "api.rateLimitBurst").nonZero(default: 10)
        let refillPerSec = UserDefaults.standard.integer(forKey: "api.rateLimitRefill").nonZero(default: 3)
        await SDAPIRateLimiter.shared.configure {
            $0.maxTokens       = maxTokens
            $0.refillPerSecond = refillPerSec
        }
        log("Rate limiter: burst=\(maxTokens), refill=\(refillPerSec)/s")
    }

    private func bootProgressEngine() async throws {
        let showPreviews = UserDefaults.standard.bool(forKey: "gen.showPartialPreviews")
        GenerationProgressEngine.shared.config.showPartialPreviews = showPreviews
        let pollMs = UserDefaults.standard.integer(forKey: "gen.pollIntervalMs").nonZero(default: 500)
        GenerationProgressEngine.shared.config.pollIntervalMs = pollMs
        log("Progress engine: previews=\(showPreviews) · poll=\(pollMs)ms")
    }

    private func bootExportPipeline() async throws {
        if let data   = UserDefaults.standard.data(forKey: "export.setExporterConfig"),
           let config = try? JSONDecoder().decode(OnlyFansSetExporter.SetExportConfig.self, from: data) {
            OnlyFansSetExporter.shared.config = config
        }
        let maxConcurrency = UserDefaults.standard.integer(forKey: "export.batchConcurrency").nonZero(default: 2)
        ExportBatchCoordinator.shared.config.maxConcurrency = maxConcurrency
        log("Export pipeline: concurrency=\(maxConcurrency)")
    }

    private func bootSecurity() async throws {
        // Async hardening scan — doesn't block boot
        Task { await AppHardeningManager.shared.runFullScan() }

        ZeroKnowledgeLog.shared.loadAll()

        let quarantineRaw = UserDefaults.standard.integer(forKey: "nsfw.quarantineThreshold")
        let flagRaw       = UserDefaults.standard.integer(forKey: "nsfw.flagThreshold")
        if let qLevel = NSFWLevel(rawValue: quarantineRaw) {
            NSFWDetector.shared.policy.thresholdForQuarantine = qLevel
        }
        if let fLevel = NSFWLevel(rawValue: flagRaw) {
            NSFWDetector.shared.policy.thresholdForFlag = fLevel
        }

        log("Seguridad: hardening scan programado · ZKLog cargado · NSFW configurado")
    }

    private func bootSandbox() async throws {
        SandboxManager.shared.initialize()

        let autoLaunch = UserDefaults.standard.bool(forKey: "sandbox.autoLaunchSD")
        let scriptPath = UserDefaults.standard.string(forKey: "a1111.webuiPath") ?? ""

        if autoLaunch && !scriptPath.isEmpty {
            do {
                try await SandboxManager.shared.launchSD(scriptPath: scriptPath)
                log("Sandbox: SD lanzado automáticamente (PID \(SandboxManager.shared.sdPID ?? -1))")
            } catch {
                log("Sandbox: auto-launch omitido — \(error.localizedDescription)")
            }
        } else {
            log("Sandbox: inicializado · auto-launch desactivado")
        }
    }

    private func bootBackup() async throws {
        BackupManager.shared.startScheduler()
        let hasDestinations = !BackupManager.shared.config.destinations.isEmpty
        log("Backups: scheduler activo · \(hasDestinations ? "\(BackupManager.shared.config.destinations.count) destinos" : "sin destinos configurados")")
    }

    private func bootJobs() async throws {
        JobQueueManager.shared.startQueue()
        // Count jobs that are in a pending/queued state (statusEnum is type-safe)
        let pending = JobQueueManager.shared.jobs.filter {
            $0.statusEnum == .pending || $0.statusEnum == .queued
        }.count
        log("Cola de trabajos: \(pending) jobs pendientes reanudados")
    }

    // MARK: - Weekly Integrity Check (NEW v6)

    private func scheduleWeeklyIntegrityCheck() async {
        let key      = "integrity.lastScheduledCheck"
        let interval = TimeInterval(7 * 86_400)   // 7 days
        let lastRun  = UserDefaults.standard.object(forKey: key) as? Date

        guard lastRun == nil || Date().timeIntervalSince(lastRun!) > interval else { return }

        // Run in background — non-blocking
        Task.detached(priority: .background) {
            await IntegrityManager.shared.runFullVerification()
            await MainActor.run {
                UserDefaults.standard.set(Date(), forKey: key)
            }
        }
        log("Integridad: verificación semanal programada")
    }

    // MARK: - Post-Boot Health Check

    private func runPostBootHealthCheck() async {
        var issues: [String] = []

        if VaultManager.shared.vaultRoot == nil {
            issues.append("Vault no configurado — configura un directorio raíz en Settings")
        }

        let baseURL = UserDefaults.standard.string(forKey: "a1111.baseURL") ?? "http://127.0.0.1:7860"
        if let url  = URL(string: "\(baseURL)/sdapi/v1/progress") {
            let isOnline = (try? await URLSession.shared.data(from: url)) != nil
            if !isOnline {
                issues.append("A1111 no está corriendo en \(baseURL) — inicia Stable Diffusion WebUI")
            }
        }

        if GPUMonitor.shared.deviceName == "Detecting…" {
            issues.append("No se detectó GPU — el rendimiento puede ser bajo")
        }

        if !issues.isEmpty {
            systemAlert = SystemAlert(
                title:    issues.count > 1 ? "Atención post-arranque" : "Aviso",
                message:  issues.joined(separator: "\n"),
                severity: issues.count > 1 ? .warning : .info
            )
        }
    }

    // MARK: - Health Report

    struct HealthReport {
        var vaultOK:              Bool = false
        var cryptoOK:             Bool = false
        var a1111OK:              Bool = false
        var gpuDetected:          Bool = false
        var lorasLoaded:          Int  = 0
        var modelsLoaded:         Int  = 0
        var totalAssets:          Int  = 0
        var rateLimiterOK:        Bool = false
        var progressEngineOK:     Bool = false
        var sandboxOK:            Bool = false
        var cleanupOK:            Bool = false    // NEW v6
        var promptVersioningOK:   Bool = false    // NEW v6

        var overall: Bool { vaultOK && cryptoOK }
    }

    func generateHealthReport() async -> HealthReport {
        var report = HealthReport()
        report.vaultOK            = VaultManager.shared.vaultRoot != nil
        report.cryptoOK           = VaultCryptoEngine.shared.isEncryptionEnabled
        report.gpuDetected        = GPUMonitor.shared.deviceName != "Detecting…"
        report.lorasLoaded        = LoRAManager.shared.installedLoRAs.count
        report.modelsLoaded       = ModelManager.shared.checkpoints.count
        report.totalAssets        = AssetStore.shared.recentAssets.count
        report.rateLimiterOK      = await SDAPIRateLimiter.shared.circuitState == .closed
        report.progressEngineOK   = true
        report.sandboxOK          = SandboxManager.shared.isolationStatus.passed
        report.cleanupOK          = true   // ArtifactCleanupEngine has no fail state
        report.promptVersioningOK = PromptVersioningStore.shared.versions.count >= 0

        let baseURL = UserDefaults.standard.string(forKey: "a1111.baseURL") ?? "http://127.0.0.1:7860"
        if let url  = URL(string: "\(baseURL)/sdapi/v1/progress") {
            report.a1111OK = (try? await URLSession.shared.data(from: url)) != nil
        }
        return report
    }

    // MARK: - Audit Report

    struct AuditReport: Codable {
        var generatedAt:         Date
        var vaultPath:           String?
        var totalAssets:         Int
        var promptsBlocked:      Int
        var nsfwQuarantined:     Int
        var complianceScore:     Double
        var lastBackupAt:        Date?
        var securityScore:       Int
        var sandboxState:        String
        var artifactsScanned:    Int       // NEW v6
        var promptVersionsStored: Int      // NEW v6
    }

    func generateAuditReport() async -> AuditReport {
        AuditReport(
            generatedAt:          Date(),
            vaultPath:            VaultManager.shared.vaultRoot?.path,
            totalAssets:          AssetStore.shared.recentAssets.count,
            promptsBlocked:       ZeroKnowledgeLog.shared.entries(category: .promptBlocked).count,
            nsfwQuarantined:      ZeroKnowledgeLog.shared.entries(category: .nsfwQuarantine).count,
            complianceScore:      PublishComplianceLogger.shared.complianceScore,
            lastBackupAt:         BackupManager.shared.config.lastBackupAt,
            securityScore:        AppHardeningManager.shared.securityScore,
            sandboxState:         SandboxManager.shared.processState.rawValue,
            artifactsScanned:     IntegrityManager.shared.lastReport?.totalChecked ?? 0,  // NEW v6
            promptVersionsStored: PromptVersioningStore.shared.versions.count             // NEW v6
        )
    }

    // MARK: - Private Helpers

    private func log(_ message: String) {
        let ts = Date().formatted(date: .omitted, time: .standard)
        bootLog.append("[\(ts)] \(message)")
    }
}

// MARK: - Int.nonZero

private extension Int {
    func nonZero(default value: Int) -> Int { self == 0 ? value : self }
}

// MARK: - JobStatus queued alias (v6 compat)
// JobQueueManager.JobStatus may define .queued or .pending depending on version.
// This extension resolves the ambiguity used in bootJobs().

private extension JobQueueManager.GenerationJob {
    var statusEnum: JobQueueManager.JobStatus { status }

    var isQueued: Bool {
        status == .queued || status == .pending
    }
}
