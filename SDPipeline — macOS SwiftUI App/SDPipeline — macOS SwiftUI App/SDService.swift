import Foundation
import AppKit
import Combine

// MARK: - SDService v3
// Cambios v2→v3:
//   - Live progress polling (/sdapi/v1/progress) con ETA y preview frame
//   - Interrupt endpoint (/sdapi/v1/interrupt)
//   - Apple Silicon launch flags: --precision full --no-half --use-cpu all / MPS
//   - VRAM pre-check antes de generar
//   - Async health check con retry logic

@MainActor
class SDService: ObservableObject {
    @Published var stage:          PipelineStage = .idle
    @Published var generatedImage: NSImage?
    @Published var errorMessage:   String?
    @Published var lastSeed:       Int?
    @Published var isGenerating:   Bool = false
    @Published var progressText:   String = ""

    // Live progress
    @Published var generationProgress: Double = 0.0   // 0.0 – 1.0
    @Published var livePreviewImage:   NSImage?       // frame durante generación
    @Published var etaText:            String = ""

    // WebUI process
    @Published var webuiState: WebuiState = .stopped
    @Published var webuiLog:   String = ""

    private var webuiProcess:    Process?
    private var logPipe:         Pipe?
    private var healthPollTask:  Task<Void, Never>?
    private var progressPollTask: Task<Void, Never>?

    enum WebuiState: Equatable {
        case stopped
        case launching
        case online
        case error(String)
    }

    // MARK: - Launch WebUI

    func launchWebUI(scriptPath: String, baseURL: String, appleM1Mode: Bool = false) {
        guard !scriptPath.isEmpty else {
            webuiState = .error("No script path set")
            return
        }
        stopWebUI()
        webuiState = .launching
        webuiLog = "Launching webui.sh…\n"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")

        // Apple Silicon MPS flags for better compatibility
        var args = [scriptPath, "--api", "--listen", "--xformers"]
        if appleM1Mode {
            args += ["--precision", "full", "--no-half", "--skip-torch-cuda-test", "--upcast-sampling"]
            webuiLog += "🍎 Apple Silicon mode: MPS backend with full precision\n"
        }
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: scriptPath).deletingLastPathComponent()

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError  = pipe
        logPipe = pipe

        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if case .online = self.webuiState { return }
                self.webuiState = .error("Process exited unexpectedly")
                self.healthPollTask?.cancel()
            }
        }

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                self?.webuiLog += text
                // Detect "Model loaded" to set online faster
                if text.contains("Model loaded") || text.contains("Running on local URL") {
                    self?.webuiState = .online
                    self?.healthPollTask?.cancel()
                }
            }
        }

        do {
            try process.run()
            webuiProcess = process
        } catch {
            webuiState = .error("Failed to start: \(error.localizedDescription)")
            return
        }

        // Poll health until online (120s timeout)
        healthPollTask?.cancel()
        healthPollTask = Task {
            let deadline = Date().addingTimeInterval(120)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { return }
                if await checkHealth(baseURL: baseURL) {
                    self.webuiState = .online
                    return
                }
            }
            if case .launching = self.webuiState {
                self.webuiState = .error("Timed out waiting for SD to come online (120s)")
            }
        }
    }

    func stopWebUI() {
        healthPollTask?.cancel()
        progressPollTask?.cancel()
        logPipe?.fileHandleForReading.readabilityHandler = nil
        webuiProcess?.terminate()
        webuiProcess = nil
        logPipe = nil
    }

    // MARK: - Generate

    func generate(request: SDRequest, baseURL: String) async {
        isGenerating        = true
        errorMessage        = nil
        generatedImage      = nil
        generationProgress  = 0.0
        livePreviewImage    = nil
        etaText             = ""
        stage               = .sending
        progressText        = "Connecting to Stable Diffusion…"

        guard let url = URL(string: "\(baseURL)/sdapi/v1/txt2img") else {
            errorMessage = "Invalid URL: \(baseURL)/sdapi/v1/txt2img"
            stage = .error; isGenerating = false; return
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 600

        do {
            urlRequest.httpBody = try JSONEncoder().encode(request)
        } catch {
            errorMessage = "Failed to encode request: \(error.localizedDescription)"
            stage = .error; isGenerating = false; return
        }

        progressText = "Generating (\(request.steps) steps)…"

        // Start progress polling
        startProgressPolling(baseURL: baseURL, totalSteps: request.steps)

        do {
            let (data, response) = try await URLSession.shared.data(for: urlRequest)

            progressPollTask?.cancel()
            generationProgress = 1.0
            livePreviewImage   = nil

            guard let httpResponse = response as? HTTPURLResponse else {
                throw SDError.invalidResponse
            }
            guard httpResponse.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? "Unknown error"
                throw SDError.httpError(code: httpResponse.statusCode, body: body)
            }

            stage        = .receiving
            progressText = "Decoding image…"

            let sdResponse = try JSONDecoder().decode(SDResponse.self, from: data)

            guard let base64String = sdResponse.images.first else {
                throw SDError.noImages
            }
            guard let imageData = Data(base64Encoded: base64String),
                  let nsImage = NSImage(data: imageData) else {
                throw SDError.decodeFailed
            }

            generatedImage = nsImage
            lastSeed       = sdResponse.parameters?.seed ?? extractSeedFromInfo(sdResponse.info)
            stage          = .done
            progressText   = "Done! ✓"

        } catch {
            progressPollTask?.cancel()
            errorMessage = error.localizedDescription
            stage        = .error
            progressText = ""
        }

        isGenerating = false
    }

    // MARK: - Live Progress Polling

    private func startProgressPolling(baseURL: String, totalSteps: Int) {
        progressPollTask?.cancel()
        progressPollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 800_000_000) // 0.8s
                if Task.isCancelled { return }
                await self.fetchProgress(baseURL: baseURL)
            }
        }
    }

    private func fetchProgress(baseURL: String) async {
        guard let url = URL(string: "\(baseURL)/sdapi/v1/progress") else { return }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let prog = try? JSONDecoder().decode(SDProgressResponse.self, from: data) else { return }

        generationProgress = prog.progress
        etaText            = prog.etaDisplay

        if let step = prog.state?.sampling_step, let total = prog.state?.sampling_steps, total > 0 {
            progressText = "Step \(step)/\(total) · \(prog.percentDisplay)"
        }

        // Live preview frame
        if let previewB64 = prog.current_image,
           !previewB64.isEmpty,
           let previewData = Data(base64Encoded: previewB64),
           let previewImg  = NSImage(data: previewData) {
            livePreviewImage = previewImg
        }
    }

    // MARK: - Interrupt

    func interruptGeneration(baseURL: String) async {
        guard let url = URL(string: "\(baseURL)/sdapi/v1/interrupt") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 5
        _ = try? await URLSession.shared.data(for: req)
        progressPollTask?.cancel()
        progressText = "Interrupted"
        isGenerating = false
        stage = .idle
    }

    // MARK: - VRAM Pre-check

    /// Returns estimated VRAM requirement and warns if GPU memory may be insufficient.
    func vramPreCheck(width: Int, height: Int, steps: Int, enableHR: Bool, hrScale: Double) -> VRAMCheckResult {
        let megapixels = Double(width * height) / 1_000_000.0
        var estimatedGB = megapixels * 2.5 + 1.5 // baseline estimate
        if enableHR { estimatedGB *= hrScale * 0.6 }
        if steps > 50 { estimatedGB += 0.5 }

        let availableGB: Double
        #if arch(arm64)
        // Apple Silicon: check system RAM (shared with GPU)
        let totalRAM = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        availableGB = totalRAM * 0.6 // conservative: 60% for GPU
        #else
        availableGB = 8.0 // default assumption for unknown GPU
        #endif

        return VRAMCheckResult(
            estimatedGB: estimatedGB,
            availableGB: availableGB,
            isSafe: estimatedGB < availableGB,
            warning: estimatedGB >= availableGB
                ? "⚠️ Estimated \(String(format: "%.1f", estimatedGB))GB needed, ~\(String(format: "%.0f", availableGB))GB available. Consider lowering resolution or disabling Hires Fix."
                : nil
        )
    }

    struct VRAMCheckResult {
        let estimatedGB: Double
        let availableGB: Double
        let isSafe: Bool
        let warning: String?
    }

    // MARK: - Model / Options

    func fetchCurrentModel(baseURL: String) async -> String? {
        guard let url = URL(string: "\(baseURL)/sdapi/v1/options"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["sd_model_checkpoint"] as? String
    }

    func setModel(_ modelTitle: String, baseURL: String) async throws {
        guard let url = URL(string: "\(baseURL)/sdapi/v1/options") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["sd_model_checkpoint": modelTitle])
        req.timeoutInterval = 60
        let (_, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw SDError.httpError(code: (response as? HTTPURLResponse)?.statusCode ?? -1, body: "setModel failed")
        }
    }

    // MARK: - Health

    func checkHealth(baseURL: String) async -> Bool {
        for path in ["/internal/ping", "/docs"] {
            guard let url = URL(string: "\(baseURL)\(path)") else { continue }
            if let status = try? await URLSession.shared.data(from: url).1 as? HTTPURLResponse,
               status.statusCode == 200 { return true }
        }
        return false
    }

    // MARK: - Private helpers

    private func extractSeedFromInfo(_ info: String?) -> Int? {
        guard let info else { return nil }
        if let range = info.range(of: "\"seed\":\\s*(\\d+)", options: .regularExpression) {
            let match = String(info[range])
            let digits = match.filter { $0.isNumber }
            return Int(digits)
        }
        return nil
    }
}

// MARK: - SDError

enum SDError: LocalizedError {
    case invalidResponse
    case httpError(code: Int, body: String)
    case noImages
    case decodeFailed
    case vaultNotConfigured

    var errorDescription: String? {
        switch self {
        case .invalidResponse:          return "Invalid HTTP response from Stable Diffusion"
        case .httpError(let c, let b):  return "HTTP \(c): \(b)"
        case .noImages:                 return "No images returned in SD response"
        case .decodeFailed:             return "Failed to decode base64 image from SD"
        case .vaultNotConfigured:       return "Vault not configured — set vault root in Settings"
        }
    }
}
