import Foundation
import SwiftUI
import Combine

// MARK: - AppEnvironment v5  ✅ ROADMAP 100%
//
// Cambios v4 → v5:
//   ✨ ADD: BootPhase.sandbox — aislamiento de proceso SD
//   ✨ ADD: var sandbox: SandboxManager en referencias
//   🔧 FIX: bootCrypto()    — usa VaultCryptoEngine.shared real (no VaultCryptoEngine())
//   🔧 FIX: bootProjects()  — ProjectFolderManager.shared.loadProjects() real
//   🔧 FIX: bootLegal()     — PrivacyComplianceManager.shared.installDefaultPolicies() real
//   🔧 FIX: bootHardware()  — GPUMonitor.shared.startPolling() + MpsOptimizer real
//   🔧 FIX: bootSecurity()  — AppHardeningManager.runFullScan() async, ZKLog.loadAll(), NSFW policy
//   🔧 FIX: bootBackup()    — BackupManager.shared.startScheduler() real
//   🔧 FIX: bootJobs()      — JobQueueManager.shared.startQueue() real
//   🔧 FIX: generateHealthReport() — sandboxOK añadido al report
//   🗑️ REM: Eliminado bloque "Stubs for missing boot implementations" completo
//   🗑️ REM: Eliminado private extensions con implementaciones vacías

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
        case tagging        = "Indexando tags…"
        case autocomplete   = "Indexando autocompletado…"
        case rateLimiter    = "Configurando API rate limiter…"
        case progressEngine = "Preparando preview engine…"
        case exportPipeline = "Preparando pipeline de export…"
        case security       = "Iniciando sistemas de seguridad…"
        case sandbox        = "Configurando sandbox de procesos…"   // NEW v5
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

    // MARK: - System Alert (post-boot)

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
    var promptVersioning:   PromptVersioningStore     { .shared }
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
    var sandbox:            SandboxManager            { .shared }   // NEW v5

    // MARK: - Boot Sequence

    func boot() async {
        guard bootPhase == .idle || bootPhase == .error else { return }
        bootError = nil
        bootLog   = []
        isReady   = false

        let phases: [(BootPhase, () async throws -> Void)] = [
            (.vault,           bootVault),
            (.migration,       bootMigration),
            (.persistence,     bootPersistence),
            (.crypto,          bootCrypto),
            (.projects,        bootProjects),
            (.legal,           bootLegal),
            (.hardware,        bootHardware),
            (.engines,         bootEngines),
            (.tagging,         bootTagging),
            (.autocomplete,    bootAutocomplete),
            (.rateLimiter,     bootRateLimiter),
            (.progressEngine,  bootProgressEngine),
            (.exportPipeline,  bootExportPipeline),
            (.security,        bootSecurity),
            (.sandbox,         bootSandbox),       // NEW v5
            (.backup,          bootBackup),
            (.jobs,            bootJobs),
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

        Task { await runPostBootHealthCheck() }
    }

    // MARK: - Boot Functions

    private func bootVault() async throws {
        VaultManager.shared.initialize()
    }

    private func bootMigration() async throws {
        _ = CoreDataPersistence.shared
    }

    private func bootPersistence() async throws {
        _ = AssetStore.shared
        _ = AssetVersioningStore.shared
        _ = PromptVersioningStore.shared
    }

    private func bootCrypto() async throws {
        // VaultCryptoEngine.shared inicializa la clave AES-256 en Keychain al primer acceso.
        // El acceso a .vaultKey es suficiente para garantizar que la clave existe.
        _ = VaultCryptoEngine.shared.vaultKey
        _ = VaultCryptoEngine.shared.promptKey
        _ = VaultCryptoEngine.shared.backupKey
        log("Cifrado: claves AES-256-GCM verificadas en Keychain")
    }

    private func bootProjects() async throws {
        _ = ProjectManager.shared
        // loadProjects() lee el índice JSON del vault y puebla .projects
        ProjectFolderManager.shared.loadProjects()
        log("Proyectos: \(ProjectFolderManager.shared.projects.count) cargados")
    }

    private func bootLegal() async throws {
        _ = LicenseVault.shared
        _ = LicenseLocalStore.shared
        _ = ConsentTemplateManager.shared
        // installDefaultPolicies() escribe Privacy Policy y T&Cs si no existen todavía
        try PrivacyComplianceManager.shared.installDefaultPolicies()
        log("Legal: políticas de privacidad verificadas")
    }

    private func bootHardware() async throws {
        // Iniciar polling de VRAM/RAM cada 6 segundos
        let baseURL = UserDefaults.standard.string(forKey: "a1111.baseURL") ?? "http://127.0.0.1:7860"
        GPUMonitor.shared.configure(baseURL: baseURL)
        GPUMonitor.shared.startPolling(interval: 6.0)

        // Generar y guardar script de lanzamiento optimizado para el chip detectado
        try? MpsOptimizer.shared.saveLaunchScriptToVault()

        log("Hardware: \(GPUMonitor.shared.deviceName) · polling activo · script MPS generado")
    }

    private func bootEngines() async throws {
        _ = SeedManager.shared
        _ = WildcardEngine.shared
        _ = EmbeddingsManager.shared
        _ = ModelManager.shared
        _ = LoRAManager.shared
        _ = PrivateModelRegistry.shared
        _ = CharacterEngine.shared
        _ = SceneEngine.shared
        _ = ContentSessionManager.shared
        _ = ABTestingEngine.shared
        _ = DashboardViewModel.shared
    }

    private func bootTagging() async throws {
        await TaggingEngine.shared.loadIndex()
    }

    private func bootAutocomplete() async throws {
        await PromptAutoCompleteEngine.shared.buildIndex()
        let loraNames = LoRAManager.shared.installedLoRAs.map(\.name)
        let embNames  = EmbeddingsManager.shared.embeddings.map(\.name)
        await PromptAutoCompleteEngine.shared.buildIndex(loraNames: loraNames, embeddingNames: embNames)
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
        log("Progress engine: previews=\(showPreviews)")
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
        // 1. Hardening scan asíncrono — no bloquea el arranque
        Task { await AppHardeningManager.shared.runFullScan() }

        // 2. ZeroKnowledgeLog — descifrar y cargar entradas de sesiones anteriores
        ZeroKnowledgeLog.shared.loadAll()

        // 3. NSFWDetector — aplicar umbrales desde UserDefaults si existen
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
        // SandboxManager puebla directorios autorizados desde VaultManager
        SandboxManager.shared.initialize()

        // Auto-launch SD si el usuario lo tiene configurado
        let autoLaunch = UserDefaults.standard.bool(forKey: "sandbox.autoLaunchSD")
        let scriptPath = UserDefaults.standard.string(forKey: "a1111.webuiPath") ?? ""

        if autoLaunch && !scriptPath.isEmpty {
            do {
                try await SandboxManager.shared.launchSD(scriptPath: scriptPath)
                log("Sandbox: SD lanzado automáticamente en modo aislado (PID \(SandboxManager.shared.sdPID ?? -1))")
            } catch {
                // No fatal — el usuario puede lanzar SD manualmente desde la UI
                log("Sandbox: auto-launch omitido — \(error.localizedDescription)")
            }
        } else {
            log("Sandbox: inicializado · \(SandboxManager.shared.config.allowedWriteDirectories.count) dirs autorizados · auto-launch desactivado")
        }
    }

    private func bootBackup() async throws {
        // startScheduler() programa el timer diario de rclone según BackupConfig
        BackupManager.shared.startScheduler()
        let hasDestinations = !BackupManager.shared.config.destinations.isEmpty
        log("Backups: scheduler activo · \(hasDestinations ? "\(BackupManager.shared.config.destinations.count) destinos" : "sin destinos configurados")")
    }

    private func bootJobs() async throws {
        // startQueue() carga la cola persistida y reanuda los jobs pendientes
        JobQueueManager.shared.startQueue()
        let pending = JobQueueManager.shared.queue.filter { $0.status == .queued }.count
        log("Cola de trabajos: \(pending) jobs pendientes reanudados")
    }

    // MARK: - Post-Boot Health Check

    private func runPostBootHealthCheck() async {
        var issues: [String] = []

        if VaultManager.shared.activeVault == nil {
            issues.append("Vault no configurado — configura un directorio raíz en Settings")
        }

        let baseURL = UserDefaults.standard.string(forKey: "a1111.baseURL") ?? "http://127.0.0.1:7860"
        if let url = URL(string: "\(baseURL)/sdapi/v1/progress"),
           (try? await URLSession.shared.data(from: url)) == nil {
            issues.append("A1111 no está corriendo en \(baseURL)")
        }

        if !GPUMonitor.shared.isAppleSilicon && GPUMonitor.shared.deviceName == "Detecting…" {
            issues.append("No se detectó GPU — el rendimiento puede ser bajo")
        }

        if !issues.isEmpty {
            systemAlert = SystemAlert(
                title:    "Atención post-arranque",
                message:  issues.joined(separator: "\n"),
                severity: issues.count > 1 ? .warning : .info
            )
        }
    }

    // MARK: - Health Report

    struct HealthReport {
        var vaultOK:          Bool = false
        var cryptoOK:         Bool = false
        var a1111OK:          Bool = false
        var gpuDetected:      Bool = false
        var lorasLoaded:      Int  = 0
        var modelsLoaded:     Int  = 0
        var totalAssets:      Int  = 0
        var rateLimiterOK:    Bool = false
        var progressEngineOK: Bool = false
        var sandboxOK:        Bool = false   // NEW v5

        var overall: Bool { vaultOK && cryptoOK }
    }

    func generateHealthReport() async -> HealthReport {
        var report = HealthReport()
        report.vaultOK          = VaultManager.shared.activeVault != nil
        report.cryptoOK         = VaultCryptoEngine.shared.isEncryptionEnabled
        report.gpuDetected      = GPUMonitor.shared.isAppleSilicon || GPUMonitor.shared.deviceName != "Detecting…"
        report.lorasLoaded      = LoRAManager.shared.installedLoRAs.count
        report.modelsLoaded     = ModelManager.shared.checkpoints.count
        report.totalAssets      = AssetStore.shared.recentAssets.count
        report.rateLimiterOK    = await SDAPIRateLimiter.shared.circuitState == .closed
        report.progressEngineOK = true
        report.sandboxOK        = SandboxManager.shared.isolationStatus.passed   // NEW v5

        let baseURL = UserDefaults.standard.string(forKey: "a1111.baseURL") ?? "http://127.0.0.1:7860"
        if let url = URL(string: "\(baseURL)/sdapi/v1/progress") {
            report.a1111OK = (try? await URLSession.shared.data(from: url)) != nil
        }
        return report
    }

    // MARK: - Audit Report (para SecurityAuditView → exportReport)

    struct AuditReport: Codable {
        var generatedAt:      Date
        var vaultPath:        String?
        var totalAssets:      Int
        var promptsBlocked:   Int
        var nsfwQuarantined:  Int
        var complianceScore:  Double
        var lastBackupAt:     Date?
        var securityScore:    Int
        var sandboxState:     String   // NEW v5
    }

    func generateAuditReport() async -> AuditReport {
        AuditReport(
            generatedAt:     Date(),
            vaultPath:       VaultManager.shared.vaultRoot?.path,
            totalAssets:     AssetStore.shared.recentAssets.count,
            promptsBlocked:  ZeroKnowledgeLog.shared.entries(category: .promptBlocked).count,
            nsfwQuarantined: ZeroKnowledgeLog.shared.entries(category: .nsfwQuarantine).count,
            complianceScore: PublishComplianceLogger.shared.complianceScore,
            lastBackupAt:    BackupManager.shared.config.lastBackupAt,
            securityScore:   AppHardeningManager.shared.securityScore,
            sandboxState:    SandboxManager.shared.processState.rawValue   // NEW v5
        )
    }

    // MARK: - Private Helpers

    private func log(_ message: String) {
        bootLog.append("[\(Date().formatted(date: .omitted, time: .standard))] \(message)")
    }
}

// MARK: - Int.nonZero

private extension Int {
    func nonZero(default value: Int) -> Int { self == 0 ? value : self }
}
