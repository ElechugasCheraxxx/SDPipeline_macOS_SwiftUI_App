import Foundation
import AppKit
import SwiftUI
import Combine

// MARK: - KohyaTrainingManager
//
// Gestión del entrenamiento de LoRAs privados vía Kohya_ss.
// Kohya_ss es el toolkit estándar para entrenar LoRAs localmente.
//
// Responsabilidades:
//   1. Configurar y lanzar jobs de entrenamiento Kohya
//   2. Gestionar datasets de entrenamiento (imágenes + captions)
//   3. Monitorear progreso (loss, epochs, pasos)
//   4. Guardar LoRAs resultantes en PrivateLoRAs/ del vault
//   5. Auto-registrar en LoRAManager post-entrenamiento
//
// Prerequisito:
//   Kohya_ss instalado en algún directorio del sistema.
//   brew install python@3.10  (o versión compatible)
//   git clone https://github.com/bmaltais/kohya_ss.git
//
// Estructura de dataset:
//   Vault/Training/{job_name}/
//     dataset/
//       {n_repeats}_{trigger_word}/
//         image1.png
//         image1.txt     ← Caption
//         image2.png
//         image2.txt
//     config.toml
//     output/            ← LoRA .safetensors resultante
//     logs/
//
// ROADMAP: "Entrenamiento de LoRAs privados (Kohya_ss)" (🟡 MEDIO PLAZO)

@MainActor
final class KohyaTrainingManager: ObservableObject {

    static let shared = KohyaTrainingManager()
    private init() {
        detectKohya()
        loadJobs()
    }

    // MARK: - Models

    enum BaseModel: String, Codable, CaseIterable {
        case sd15    = "SD 1.5"
        case sdxl    = "SDXL 1.0"
        case sdxlTurbo = "SDXL Turbo"
        case sd21    = "SD 2.1"

        var recommendedResolution: Int {
            switch self {
            case .sd15:      return 512
            case .sd21:      return 768
            case .sdxl, .sdxlTurbo: return 1024
            }
        }

        var recommendedNetworkDim: Int {
            switch self {
            case .sd15:  return 64
            case .sdxl, .sdxlTurbo: return 128
            default: return 64
            }
        }
    }

    struct TrainingConfig: Codable {
        // Identity
        var jobName:         String
        var triggerWord:     String        // Palabra clave que activa el LoRA
        var baseModel:       BaseModel     = .sd15
        var checkpointPath:  String        = ""   // Ruta al .safetensors base

        // Dataset
        var datasetPath:     String        = ""
        var numRepeats:      Int           = 20   // Cuántas veces repetir las imágenes
        var resizeImages:    Bool          = true

        // Training hyperparams
        var resolution:      Int           = 512
        var batchSize:       Int           = 1
        var maxTrainEpochs:  Int           = 10
        var learningRate:    Double        = 0.0001
        var unetLR:          Double        = 0.0001
        var textEncoderLR:   Double        = 0.00001
        var networkDim:      Int           = 64    // LoRA rank
        var networkAlpha:    Int           = 32

        // Optimizer
        var optimizer:       Optimizer     = .adamW8bit
        var lrScheduler:     LRScheduler   = .cosineWithRestarts
        var lrWarmupSteps:   Int           = 0
        var lrNumCycles:     Int           = 1

        // Network
        var networkModule:   String        = "networks.lora"
        var saveEveryNEpochs: Int          = 2
        var savePrecision:   String        = "fp16"

        // Output
        var outputDir:       String        = ""
        var outputName:      String        = ""   // Nombre del .safetensors resultante
        var loggingDir:      String        = ""

        // Apple Silicon
        var useMPS:          Bool          = false  // Experimental — Kohya + MPS

        enum Optimizer: String, Codable, CaseIterable {
            case adamW       = "AdamW"
            case adamW8bit   = "AdamW8bit"
            case prodigy     = "Prodigy"
            case lion        = "Lion"

            var description: String {
                switch self {
                case .adamW:     return "Estándar — buena calidad, alto uso de RAM"
                case .adamW8bit: return "Recomendado — balanceado para Apple Silicon"
                case .prodigy:   return "Adaptativo — sin lr manual necesario"
                case .lion:      return "Eficiente en memoria"
                }
            }
        }

        enum LRScheduler: String, Codable, CaseIterable {
            case constant              = "constant"
            case cosine                = "cosine"
            case cosineWithRestarts    = "cosine_with_restarts"
            case polynomial            = "polynomial"
            case linearWithWarmup      = "linear"
        }
    }

    enum TrainingStatus: String, Codable {
        case pending    = "Pendiente"
        case running    = "Entrenando"
        case paused     = "Pausado"
        case completed  = "Completado"
        case failed     = "Fallido"
        case cancelled  = "Cancelado"
    }

    struct TrainingJob: Codable, Identifiable, Hashable {
        var id:         UUID   = UUID()
        var config:     TrainingConfig
        var status:     TrainingStatus = .pending
        var createdAt:  Date   = Date()
        var startedAt:  Date?
        var completedAt: Date?

        // Progress
        var currentEpoch:   Int = 0
        var currentStep:    Int = 0
        var totalSteps:     Int = 0
        var currentLoss:    Double = 0
        var lossHistory:    [Double] = []

        // Results
        var outputLoraPath: String?
        var errorMessage:   String?

        var progress: Double {
            guard totalSteps > 0 else { return 0 }
            return Double(currentStep) / Double(totalSteps)
        }

        func hash(into hasher: inout Hasher) { hasher.combine(id) }
        static func == (l: TrainingJob, r: TrainingJob) -> Bool { l.id == r.id }
    }

    // MARK: - Published State

    @Published var isKohyaAvailable:   Bool   = false
    @Published var kohyaPath:          String = ""
    @Published var pythonPath:         String = ""
    @Published var jobs:               [TrainingJob] = []
    @Published var activeJob:          TrainingJob?
    @Published var isTraining:         Bool   = false

    // MARK: - Detection

    func detectKohya() {
        // Buscar kohya_ss en ubicaciones comunes
        let commonPaths = [
            "\(NSHomeDirectory())/kohya_ss",
            "\(NSHomeDirectory())/Documents/kohya_ss",
            "/opt/kohya_ss",
            "\(NSHomeDirectory())/sd-scripts",
        ]

        for path in commonPaths {
            let trainScript = "\(path)/train_network.py"
            if FileManager.default.fileExists(atPath: trainScript) {
                kohyaPath = path
                isKohyaAvailable = true
                break
            }
        }

        // Detectar python
        for pyPath in ["/usr/local/bin/python3", "/opt/homebrew/bin/python3", "/usr/bin/python3"] {
            if FileManager.default.fileExists(atPath: pyPath) {
                pythonPath = pyPath
                break
            }
        }
    }

    func setKohyaPath(_ path: String) {
        kohyaPath = path
        let trainScript = "\(path)/train_network.py"
        isKohyaAvailable = FileManager.default.fileExists(atPath: trainScript)
    }

    // MARK: - Create Dataset Structure

    func createDatasetStructure(for config: TrainingConfig) throws -> URL {
        guard let vaultRoot = VaultManager.shared.vaultRoot else {
            throw TrainingError.vaultNotConfigured
        }

        let jobRoot = vaultRoot
            .appendingPathComponent("Vault/Training/\(config.jobName)", isDirectory: true)

        let datasetDir = jobRoot
            .appendingPathComponent("dataset/\(config.numRepeats)_\(config.triggerWord)")
        let outputDir  = jobRoot.appendingPathComponent("output")
        let logsDir    = jobRoot.appendingPathComponent("logs")

        try FileManager.default.createDirectory(at: datasetDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        // Generate TOML config
        let toml = generateTOMLConfig(config: config, jobRoot: jobRoot)
        try toml.write(to: jobRoot.appendingPathComponent("config.toml"),
                       atomically: true, encoding: .utf8)

        return datasetDir
    }

    // MARK: - TOML Config Generation

    private func generateTOMLConfig(config: TrainingConfig, jobRoot: URL) -> String {
        let datasetPath = jobRoot.appendingPathComponent("dataset").path
        let outputPath  = jobRoot.appendingPathComponent("output").path
        let logsPath    = jobRoot.appendingPathComponent("logs").path

        return """
        # Kohya_ss TOML Config — Generated by SDPipelineStudio
        # Job: \(config.jobName) | Trigger: \(config.triggerWord)

        pretrained_model_name_or_path = "\(config.checkpointPath)"
        train_data_dir = "\(datasetPath)"
        output_dir     = "\(outputPath)"
        logging_dir    = "\(logsPath)"
        output_name    = "\(config.outputName.isEmpty ? config.jobName : config.outputName)"

        # Resolution & Batch
        resolution       = \(config.resolution)
        train_batch_size = \(config.batchSize)

        # Training
        max_train_epochs     = \(config.maxTrainEpochs)
        learning_rate        = \(config.learningRate)
        unet_lr              = \(config.unetLR)
        text_encoder_lr      = \(config.textEncoderLR)
        lr_scheduler         = "\(config.lrScheduler.rawValue)"
        lr_warmup_steps      = \(config.lrWarmupSteps)
        lr_scheduler_num_cycles = \(config.lrNumCycles)

        # Optimizer
        optimizer_type = "\(config.optimizer.rawValue)"

        # Network (LoRA)
        network_module = "\(config.networkModule)"
        network_dim    = \(config.networkDim)
        network_alpha  = \(config.networkAlpha)

        # Save
        save_every_n_epochs = \(config.saveEveryNEpochs)
        save_precision      = "\(config.savePrecision)"

        # Misc
        mixed_precision = "fp16"
        full_fp16       = false
        \(config.useMPS ? "use_xformers = false  # MPS no soporta xformers" : "xformers = true")
        gradient_checkpointing = true
        enable_bucket = true

        # Captions
        caption_extension = ".txt"
        shuffle_caption   = true
        keep_tokens       = 1
        """
    }

    // MARK: - Launch Training

    func createJob(config: TrainingConfig) throws -> TrainingJob {
        _ = try createDatasetStructure(for: config)

        let job = TrainingJob(config: config)
        jobs.insert(job, at: 0)
        try saveJobs()

        ZeroKnowledgeLog.shared.write(
            category: .systemEvent,
            message: "Training job created: \(config.jobName) | trigger=\(config.triggerWord)"
        )

        return job
    }

    func launchJob(_ job: TrainingJob) async throws {
        guard isKohyaAvailable else { throw TrainingError.kohyaNotFound }
        guard let vaultRoot = VaultManager.shared.vaultRoot else { throw TrainingError.vaultNotConfigured }

        let jobRoot    = vaultRoot.appendingPathComponent("Vault/Training/\(job.config.jobName)")
        let configPath = jobRoot.appendingPathComponent("config.toml").path
        let trainScript = "\(kohyaPath)/train_network.py"

        guard let jobIdx = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        jobs[jobIdx].status     = .running
        jobs[jobIdx].startedAt  = Date()
        activeJob               = jobs[jobIdx]
        isTraining              = true

        let task = Process()
        let pipe  = Pipe()
        task.executableURL    = URL(fileURLWithPath: pythonPath)
        task.arguments        = [trainScript, "--config_file", configPath]
        task.standardOutput   = pipe
        task.standardError    = pipe
        task.currentDirectoryURL = URL(fileURLWithPath: kohyaPath)

        var env = ProcessInfo.processInfo.environment
        if job.config.useMPS {
            env["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"
        }
        task.environment = env

        task.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                guard let self = self, let idx = self.jobs.firstIndex(where: { $0.id == job.id }) else { return }
                self.jobs[idx].status      = process.terminationStatus == 0 ? .completed : .failed
                self.jobs[idx].completedAt = Date()

                if process.terminationStatus == 0 {
                    // Auto-detect output LoRA
                    let outputDir = jobRoot.appendingPathComponent("output")
                    if let outputFile = try? FileManager.default.contentsOfDirectory(at: outputDir, includingPropertiesForKeys: nil)
                        .first(where: { $0.pathExtension == "safetensors" }) {
                        self.jobs[idx].outputLoraPath = outputFile.path
                        // Auto-register in vault PrivateLoRAs
                        try? self.moveLoraToVault(outputFile, jobName: job.config.jobName)
                    }
                }

                self.activeJob = nil
                self.isTraining = false
                try? self.saveJobs()
            }
        }

        try task.run()

        // Stream output for progress parsing
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] fh in
            let data   = fh.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                self?.parseTrainingOutput(line, jobID: job.id)
            }
        }
    }

    private func parseTrainingOutput(_ line: String, jobID: UUID) {
        guard let idx = jobs.firstIndex(where: { $0.id == jobID }) else { return }

        // Parsear líneas como: "epoch 3/10, step 120/500, loss: 0.0234"
        if line.contains("loss:") {
            let parts = line.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            for part in parts {
                if part.hasPrefix("epoch ") {
                    let ep = part.replacingOccurrences(of: "epoch ", with: "")
                    jobs[idx].currentEpoch = Int(ep.components(separatedBy: "/").first ?? "0") ?? 0
                }
                if part.hasPrefix("step ") {
                    let sp = part.replacingOccurrences(of: "step ", with: "")
                    let steps = sp.components(separatedBy: "/")
                    jobs[idx].currentStep  = Int(steps[0]) ?? 0
                    jobs[idx].totalSteps   = Int(steps.last ?? "0") ?? 0
                }
                if part.hasPrefix("loss:") {
                    let lv = part.replacingOccurrences(of: "loss:", with: "").trimmingCharacters(in: .whitespaces)
                    if let loss = Double(lv) {
                        jobs[idx].currentLoss = loss
                        jobs[idx].lossHistory.append(loss)
                    }
                }
            }
            activeJob = jobs[idx]
        }
    }

    private func moveLoraToVault(_ url: URL, jobName: String) throws {
        guard let vaultRoot = VaultManager.shared.vaultRoot else { return }
        let destDir = vaultRoot.appendingPathComponent("PrivateLoRAs", isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let dest = destDir.appendingPathComponent(url.lastPathComponent)
        if !FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.copyItem(at: url, to: dest)
        }
        ZeroKnowledgeLog.shared.write(
            category: .systemEvent,
            message: "LoRA training complete: \(url.lastPathComponent) → PrivateLoRAs/"
        )
    }

    // MARK: - Persistence

    private var jobsURL: URL? {
        VaultManager.shared.vaultRoot?
            .appendingPathComponent("Vault/meta/training_jobs.json")
    }

    private func saveJobs() throws {
        guard let url = jobsURL else { return }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(jobs).write(to: url, options: .atomic)
    }

    private func loadJobs() {
        guard let url = jobsURL, let data = try? Data(contentsOf: url) else { return }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        jobs = (try? dec.decode([TrainingJob].self, from: data)) ?? []
    }

    // MARK: - Errors

    enum TrainingError: LocalizedError {
        case kohyaNotFound
        case vaultNotConfigured
        case datasetEmpty

        var errorDescription: String? {
            switch self {
            case .kohyaNotFound:       return "Kohya_ss no encontrado. Configura la ruta en Ajustes."
            case .vaultNotConfigured:  return "Vault no configurado."
            case .datasetEmpty:        return "El dataset de entrenamiento está vacío."
            }
        }
    }
}

// MARK: - Training View

struct KohyaTrainingView: View {
    @ObservedObject private var mgr = KohyaTrainingManager.shared
    @State private var showNewJob = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "brain")
                    .foregroundColor(Color(hex: "#7c6af7"))
                Text("Entrenamiento LoRA")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()

                if !mgr.isKohyaAvailable {
                    Text("Kohya no detectado")
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "#f87171"))
                }

                Button("+ Nuevo Job") { showNewJob = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color(hex: "#7c6af7").opacity(0.2))
                    .foregroundColor(Color(hex: "#7c6af7"))
                    .cornerRadius(6)
                    .disabled(!mgr.isKohyaAvailable)
            }
            .padding(16)

            Divider()

            // Active job
            if let active = mgr.activeJob {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "bolt.fill").foregroundColor(Color(hex: "#fbbf24"))
                        Text("Entrenando: \(active.config.jobName)")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text("Epoch \(active.currentEpoch)/\(active.config.maxTrainEpochs)")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    ProgressView(value: active.progress, total: 1.0)
                        .progressViewStyle(.linear)
                        .tint(Color(hex: "#7c6af7"))
                    HStack {
                        Text("Step \(active.currentStep)/\(active.totalSteps)")
                        Spacer()
                        Text("Loss: \(active.currentLoss, specifier: "%.4f")")
                    }
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                }
                .padding(16)
                .background(Color(hex: "#fbbf24").opacity(0.05))

                Divider()
            }

            // Job list
            if mgr.jobs.isEmpty {
                Text("Sin jobs de entrenamiento. Crea el primero para entrenar un LoRA privado.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(mgr.jobs) { job in
                            TrainingJobRow(job: job)
                        }
                    }
                    .padding(12)
                }
            }
        }
    }
}

private struct TrainingJobRow: View {
    let job: KohyaTrainingManager.TrainingJob

    var statusColor: Color {
        switch job.status {
        case .pending:   return Color(hex: "#60a5fa")
        case .running:   return Color(hex: "#fbbf24")
        case .completed: return Color(hex: "#34d399")
        case .failed:    return Color(hex: "#f87171")
        case .paused:    return Color.secondary
        case .cancelled: return Color.secondary
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.config.jobName)
                    .font(.system(size: 12, weight: .medium))
                HStack(spacing: 8) {
                    Text(job.status.rawValue)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text("·")
                        .foregroundColor(.secondary)
                    Text("trigger: \(job.config.triggerWord)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            if job.status == .completed, let lora = job.outputLoraPath {
                Button(action: {
                    NSWorkspace.shared.selectFile(lora, inFileViewerRootedAtPath: "")
                }) {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.04))
        .cornerRadius(8)
    }
}
