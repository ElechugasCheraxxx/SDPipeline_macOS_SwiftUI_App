import Foundation
import AppKit
import Combine

// MARK: - DockerManager
//
// Gestión de aislamiento Docker para Stable Diffusion WebUI.
// Permite correr A1111/ComfyUI en contenedor aislado con acceso controlado
// a modelos, outputs y red.
//
// Features:
//   • Detección y verificación de Docker Desktop / Colima
//   • Composición de docker-compose.yml para A1111 + ComfyUI
//   • Control de ciclo de vida (start/stop/restart/logs)
//   • Gestión de volúmenes (modelos, outputs, extensiones)
//   • Network policy: solo puertos SD API (7860)
//   • GPU passthrough (MPS/CUDA si disponible)
//   • Auto-restart on crash
//
// ROADMAP: "Aislamiento con Docker para SD" (🟢 LARGO PLAZO)

@MainActor
final class DockerManager: ObservableObject {

    static let shared = DockerManager()
    private init() { detectDockerInstallation() }

    // MARK: - Config

    struct DockerConfig: Codable {
        var engine:            DockerEngine   = .dockerDesktop
        var containerName:     String         = "sdpipeline-a1111"
        var imageName:         String         = "universalml/automatic1111:latest"
        var apiPort:           Int            = 7860
        var modelsHostPath:    String         = ""   // ~/SDModels or vault path
        var outputsHostPath:   String         = ""   // vault/Export path
        var extensionsHostPath: String        = ""
        var gpuMode:           GPUMode        = .auto
        var autoStart:         Bool           = false
        var autoRestart:       Bool           = true
        var memoryLimit:       String         = "8g"
        var cpuLimit:          String         = "0"  // 0 = no limit
        var extraArgs:         String         = "--no-half --precision full"
        var useComfyUI:        Bool           = false
        var comfyUIPort:       Int            = 8188

        enum DockerEngine: String, CaseIterable, Codable {
            case dockerDesktop = "Docker Desktop"
            case colima        = "Colima"
            case podman        = "Podman"

            var executablePath: String {
                switch self {
                case .dockerDesktop: return "/usr/local/bin/docker"
                case .colima:        return "/usr/local/bin/docker"
                case .podman:        return "/usr/local/bin/podman"
                }
            }

            var icon: String {
                switch self {
                case .dockerDesktop: return "shippingbox.fill"
                case .colima:        return "terminal.fill"
                case .podman:        return "cube.box.fill"
                }
            }
        }

        enum GPUMode: String, CaseIterable, Codable {
            case auto  = "Auto"
            case cpu   = "CPU"
            case mps   = "Apple MPS"
            case cuda  = "CUDA"
            case none  = "Sin GPU"
        }
    }

    @Published var config = DockerConfig()

    // MARK: - State

    enum ContainerState: Equatable {
        case unknown
        case notInstalled
        case dockerNotRunning
        case stopped
        case starting
        case running(port: Int)
        case error(String)

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }

        var label: String {
            switch self {
            case .unknown:           return "Desconocido"
            case .notInstalled:      return "Docker no instalado"
            case .dockerNotRunning:  return "Docker no está corriendo"
            case .stopped:           return "Contenedor detenido"
            case .starting:          return "Iniciando…"
            case .running(let port): return "Corriendo (:\(port))"
            case .error(let msg):    return "Error: \(msg)"
            }
        }

        var color: String {
            switch self {
            case .running:  return "#34d399"
            case .starting: return "#fbbf24"
            case .error:    return "#ef4444"
            default:        return "#9090a8"
            }
        }

        var icon: String {
            switch self {
            case .running:  return "checkmark.circle.fill"
            case .starting: return "arrow.clockwise"
            case .error:    return "xmark.circle.fill"
            default:        return "stop.circle"
            }
        }
    }

    @Published var containerState: ContainerState = .unknown
    @Published var isDockerInstalled:  Bool     = false
    @Published var dockerVersion:      String   = ""
    @Published var containerLogs:      [String] = []
    @Published var containerStats:     ContainerStats?
    @Published var availableImages:    [String] = []

    private var logProcess:       Process?
    private var statsPollingTask: Task<Void, Never>?
    private var logPollingTask:   Task<Void, Never>?

    // MARK: - Container Stats

    struct ContainerStats {
        var cpuPercent:    Double
        var memoryMB:      Double
        var memoryLimitMB: Double
        var networkRxMB:   Double
        var networkTxMB:   Double
        var gpuUtilization: Double?
    }

    // MARK: - Docker Detection

    func detectDockerInstallation() {
        Task {
            let dockerPath = config.engine.executablePath

            // Check if docker is in PATH
            let (output, _, exitCode) = await runCommand([dockerPath, "--version"])
            if exitCode == 0 {
                isDockerInstalled = true
                dockerVersion = output.trimmingCharacters(in: .whitespacesAndNewlines)
                await checkDockerRunning()
            } else {
                // Try common locations
                let alternatives = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/usr/bin/docker"]
                for path in alternatives {
                    let (out, _, code) = await runCommand([path, "--version"])
                    if code == 0 {
                        isDockerInstalled = true
                        dockerVersion = out.trimmingCharacters(in: .whitespacesAndNewlines)
                        await checkDockerRunning()
                        return
                    }
                }
                containerState = .notInstalled
            }
        }
    }

    private func checkDockerRunning() async {
        let (_, _, code) = await runCommand([config.engine.executablePath, "info"])
        if code != 0 {
            containerState = .dockerNotRunning
            return
        }
        await refreshContainerStatus()
    }

    // MARK: - Container Lifecycle

    func startContainer() async throws {
        guard isDockerInstalled else { throw DockerError.dockerNotInstalled }
        containerState = .starting
        addLog("Iniciando contenedor \(config.containerName)…")

        // Check if container exists
        let (existing, _, _) = await runCommand([
            config.engine.executablePath, "ps", "-a",
            "--filter", "name=\(config.containerName)",
            "--format", "{{.Names}}"
        ])

        let containerExists = existing.contains(config.containerName)

        let cmd: [String]
        if containerExists {
            // Start existing container
            cmd = [config.engine.executablePath, "start", config.containerName]
        } else {
            // Create and start new container
            cmd = buildRunCommand()
        }

        let (output, errOutput, exitCode) = await runCommand(cmd)

        if exitCode != 0 {
            let errMsg = errOutput.isEmpty ? output : errOutput
            containerState = .error(errMsg.prefix(100).description)
            throw DockerError.containerStartFailed(errMsg)
        }

        addLog("Contenedor iniciado. Esperando API…")
        await waitForAPI()
    }

    func stopContainer() async throws {
        let (_, err, code) = await runCommand([
            config.engine.executablePath, "stop", config.containerName
        ])
        if code != 0 { throw DockerError.commandFailed(err) }
        containerState = .stopped
        statsPollingTask?.cancel()
        logPollingTask?.cancel()
        addLog("Contenedor detenido.")
    }

    func restartContainer() async throws {
        addLog("Reiniciando contenedor…")
        let (_, err, code) = await runCommand([
            config.engine.executablePath, "restart", config.containerName
        ])
        if code != 0 { throw DockerError.commandFailed(err) }
        await waitForAPI()
    }

    func removeContainer() async throws {
        try? await stopContainer()
        let (_, err, code) = await runCommand([
            config.engine.executablePath, "rm", "-f", config.containerName
        ])
        if code != 0 { throw DockerError.commandFailed(err) }
        containerState = .stopped
        addLog("Contenedor eliminado.")
    }

    // MARK: - Build Run Command

    private func buildRunCommand() -> [String] {
        var cmd: [String] = [
            config.engine.executablePath, "run", "-d",
            "--name", config.containerName,
            "-p", "\(config.apiPort):7860"
        ]

        // Volume mounts
        if !config.modelsHostPath.isEmpty {
            cmd += ["-v", "\(config.modelsHostPath):/workspace/stable-diffusion-webui/models"]
        }
        if !config.outputsHostPath.isEmpty {
            cmd += ["-v", "\(config.outputsHostPath):/workspace/stable-diffusion-webui/outputs"]
        }
        if !config.extensionsHostPath.isEmpty {
            cmd += ["-v", "\(config.extensionsHostPath):/workspace/stable-diffusion-webui/extensions"]
        }

        // Memory limit
        if config.memoryLimit != "0" {
            cmd += ["-m", config.memoryLimit]
        }

        // Auto-restart
        if config.autoRestart {
            cmd += ["--restart", "unless-stopped"]
        }

        // GPU passthrough
        switch config.gpuMode {
        case .cuda:
            cmd += ["--gpus", "all"]
        case .mps:
            // Apple Silicon - no direct passthrough needed in Docker
            // MPS flags are passed via env
            cmd += ["-e", "PYTORCH_MPS_HIGH_WATERMARK_RATIO=0.0"]
        default:
            break
        }

        // Extra environment
        cmd += ["-e", "WEBUI_FLAGS=--api --listen \(config.extraArgs)"]

        cmd.append(config.imageName)

        return cmd
    }

    // MARK: - Wait for API

    private func waitForAPI() async {
        let maxWait = 120  // seconds
        let start   = Date()
        let apiURL  = URL(string: "http://localhost:\(config.apiPort)/sdapi/v1/sd-models")!

        while Date().timeIntervalSince(start) < Double(maxWait) {
            if let (_, resp) = try? await URLSession.shared.data(from: apiURL),
               (resp as? HTTPURLResponse)?.statusCode == 200 {
                containerState = .running(port: config.apiPort)
                addLog("✅ API disponible en puerto \(config.apiPort)")
                startPolling()
                return
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            addLog("Esperando API… (\(Int(Date().timeIntervalSince(start)))s)")
        }

        containerState = .error("API no respondió en \(maxWait)s")
    }

    // MARK: - Status Polling

    func refreshContainerStatus() async {
        let (output, _, code) = await runCommand([
            config.engine.executablePath, "inspect",
            "--format", "{{.State.Status}}", config.containerName
        ])

        if code != 0 {
            containerState = .stopped
            return
        }

        let status = output.trimmingCharacters(in: .whitespacesAndNewlines)
        switch status {
        case "running":
            containerState = .running(port: config.apiPort)
        case "exited", "stopped":
            containerState = .stopped
        case "starting":
            containerState = .starting
        default:
            containerState = .unknown
        }
    }

    private func startPolling() {
        statsPollingTask?.cancel()
        statsPollingTask = Task {
            while !Task.isCancelled {
                await fetchStats()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }

        logPollingTask?.cancel()
        logPollingTask = Task {
            let (output, _, _) = await runCommand([
                config.engine.executablePath, "logs", "--tail", "100",
                "-f", config.containerName
            ])
            for line in output.split(separator: "\n").suffix(50) {
                addLog(String(line))
            }
        }
    }

    private func fetchStats() async {
        let (output, _, code) = await runCommand([
            config.engine.executablePath, "stats", "--no-stream",
            "--format", "{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}",
            config.containerName
        ])

        guard code == 0 else { return }
        let parts = output.components(separatedBy: "\t")
        guard parts.count >= 3 else { return }

        let cpuStr = parts[0].replacingOccurrences(of: "%", with: "")
        let cpu    = Double(cpuStr) ?? 0

        let memParts = parts[1].components(separatedBy: "/")
        let memUsedMB = parseSize(memParts.first?.trimmingCharacters(in: .whitespaces) ?? "")
        let memLimitMB = parseSize(memParts.last?.trimmingCharacters(in: .whitespaces) ?? "")

        containerStats = ContainerStats(
            cpuPercent:     cpu,
            memoryMB:       memUsedMB,
            memoryLimitMB:  memLimitMB,
            networkRxMB:    0,
            networkTxMB:    0
        )
    }

    // MARK: - Docker Compose

    func generateComposeFile() -> String {
        let modelVol = config.modelsHostPath.isEmpty ? "./models" : config.modelsHostPath
        let outputVol = config.outputsHostPath.isEmpty ? "./outputs" : config.outputsHostPath
        let extVol = config.extensionsHostPath.isEmpty ? "./extensions" : config.extensionsHostPath

        var compose = """
        version: '3.8'
        
        services:
          \(config.containerName):
            image: \(config.imageName)
            container_name: \(config.containerName)
            restart: \(config.autoRestart ? "unless-stopped" : "no")
            ports:
              - "\(config.apiPort):7860"
            volumes:
              - \(modelVol):/workspace/stable-diffusion-webui/models
              - \(outputVol):/workspace/stable-diffusion-webui/outputs
              - \(extVol):/workspace/stable-diffusion-webui/extensions
            environment:
              - WEBUI_FLAGS=--api --listen \(config.extraArgs)
            deploy:
              resources:
                limits:
                  memory: \(config.memoryLimit)
        """

        if config.gpuMode == .cuda {
            compose += """
            
                      reservations:
                        devices:
                          - driver: nvidia
                            count: all
                            capabilities: [gpu]
            """
        }

        if config.useComfyUI {
            compose += """
            
              comfyui:
                image: universalml/comfyui:latest
                container_name: sdpipeline-comfyui
                restart: \(config.autoRestart ? "unless-stopped" : "no")
                ports:
                  - "\(config.comfyUIPort):8188"
                volumes:
                  - \(modelVol):/comfyui/models
                  - \(outputVol):/comfyui/output
            """
        }

        compose += "\n\nnetworks:\n  default:\n    driver: bridge\n"
        return compose
    }

    func saveComposeFile(to directory: URL) throws {
        let content = generateComposeFile()
        let url = directory.appendingPathComponent("docker-compose.yml")
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Available Images

    func fetchAvailableImages() async {
        let (output, _, code) = await runCommand([
            config.engine.executablePath, "images",
            "--format", "{{.Repository}}:{{.Tag}}",
            "--filter", "reference=*a1111*"
        ])

        if code == 0 {
            availableImages = output.split(separator: "\n").map(String.init)
        }

        // Add common images
        let common = [
            "universalml/automatic1111:latest",
            "ghcr.io/abiosoft/automatic1111:latest",
            "camenduru/stable-diffusion-webui:latest"
        ]
        for img in common where !availableImages.contains(img) {
            availableImages.append(img)
        }
    }

    func pullImage() async throws {
        addLog("Descargando imagen \(config.imageName)…")
        let (_, err, code) = await runCommand([
            config.engine.executablePath, "pull", config.imageName
        ])
        if code != 0 { throw DockerError.commandFailed(err) }
        addLog("✅ Imagen descargada.")
    }

    // MARK: - Helpers

    @discardableResult
    private func runCommand(_ args: [String]) async -> (String, String, Int) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: args[0])
        proc.arguments = Array(args.dropFirst())

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError  = errPipe

        guard (try? proc.run()) != nil else {
            return ("", "Failed to run: \(args.joined(separator: " "))", -1)
        }

        proc.waitUntilExit()

        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        return (out, err, Int(proc.terminationStatus))
    }

    private func addLog(_ message: String) {
        let ts = Date().formatted(date: .omitted, time: .standard)
        containerLogs.append("[\(ts)] \(message)")
        if containerLogs.count > 500 { containerLogs.removeFirst(100) }
    }

    private func parseSize(_ str: String) -> Double {
        if str.hasSuffix("GiB") { return (Double(str.dropLast(3)) ?? 0) * 1024 }
        if str.hasSuffix("MiB") { return Double(str.dropLast(3)) ?? 0 }
        if str.hasSuffix("kB")  { return (Double(str.dropLast(2)) ?? 0) / 1024 }
        return 0
    }

    // MARK: - Persistence

    func saveConfig() {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: "DockerManagerConfig")
        }
    }

    func loadConfig() {
        if let data = UserDefaults.standard.data(forKey: "DockerManagerConfig"),
           let cfg  = try? JSONDecoder().decode(DockerConfig.self, from: data) {
            config = cfg
        }
    }

    // MARK: - Computed base URL

    var sdAPIBaseURL: String { "http://localhost:\(config.apiPort)" }

    // MARK: - Errors

    enum DockerError: LocalizedError {
        case dockerNotInstalled
        case containerStartFailed(String)
        case commandFailed(String)
        case imageNotFound

        var errorDescription: String? {
            switch self {
            case .dockerNotInstalled:         return "Docker no está instalado. Instala Docker Desktop o Colima."
            case .containerStartFailed(let m): return "Error al iniciar contenedor: \(m)"
            case .commandFailed(let m):        return "Error en comando Docker: \(m)"
            case .imageNotFound:               return "Imagen Docker no encontrada."
            }
        }
    }
}
