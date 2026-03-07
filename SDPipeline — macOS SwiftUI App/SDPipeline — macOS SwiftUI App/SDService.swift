import Foundation
import AppKit
import Combine

@MainActor
class SDService: ObservableObject {
    @Published var stage: PipelineStage = .idle
    @Published var generatedImage: NSImage?
    @Published var errorMessage: String?
    @Published var lastSeed: Int?
    @Published var isGenerating: Bool = false
    @Published var progressText: String = ""

    // MARK: - WebUI Process
    @Published var webuiState: WebuiState = .stopped
    @Published var webuiLog: String = ""

    private var webuiProcess: Process?
    private var logPipe: Pipe?
    private var healthPollTask: Task<Void, Never>?

    enum WebuiState: Equatable {
        case stopped
        case launching
        case online
        case error(String)
    }

    // MARK: - Launch / Re-launch

    func launchWebUI(scriptPath: String, baseURL: String) {
        guard !scriptPath.isEmpty else {
            webuiState = .error("No script path set")
            return
        }

        // Kill any existing process first
        stopWebUI()

        webuiState = .launching
        webuiLog = "Launching webui.sh…\n"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptPath, "--api"]
        process.currentDirectoryURL = URL(fileURLWithPath: scriptPath)
            .deletingLastPathComponent()

        // Capture stdout + stderr so we can show logs
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError  = pipe
        logPipe = pipe

        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if case .online = self.webuiState { return } // already moved on
                self.webuiState = .error("Process exited unexpectedly")
                self.healthPollTask?.cancel()
            }
        }

        // Stream log output
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                self?.webuiLog += text
            }
        }

        do {
            try process.run()
            webuiProcess = process
        } catch {
            webuiState = .error("Failed to start: \(error.localizedDescription)")
            return
        }

        // Poll health until online or timeout (~120 s)
        healthPollTask?.cancel()
        healthPollTask = Task {
            let deadline = Date().addingTimeInterval(120)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 s
                if Task.isCancelled { return }
                let ok = await self.checkHealth(baseURL: baseURL)
                if ok {
                    self.webuiState = .online
                    return
                }
            }
            // Timeout
            if case .launching = self.webuiState {
                self.webuiState = .error("Timed out waiting for SD to come online")
            }
        }
    }

    func stopWebUI() {
        healthPollTask?.cancel()
        logPipe?.fileHandleForReading.readabilityHandler = nil
        webuiProcess?.terminate()
        webuiProcess = nil
        logPipe = nil
    }

    // MARK: - Generate

    func generate(request: SDRequest, baseURL: String) async {
        isGenerating = true
        errorMessage = nil
        generatedImage = nil
        stage = .sending
        progressText = "Connecting to Stable Diffusion…"

        guard let url = URL(string: "\(baseURL)/sdapi/v1/txt2img") else {
            errorMessage = "Invalid URL: \(baseURL)/sdapi/v1/txt2img"
            stage = .error
            isGenerating = false
            return
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 300

        do {
            urlRequest.httpBody = try JSONEncoder().encode(request)
        } catch {
            errorMessage = "Failed to encode request: \(error.localizedDescription)"
            stage = .error
            isGenerating = false
            return
        }

        progressText = "Generating (\(request.steps) steps)…"

        do {
            let (data, response) = try await URLSession.shared.data(for: urlRequest)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw NSError(domain: "SDPipeline", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"])
            }

            guard httpResponse.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? "Unknown error"
                throw NSError(domain: "SDPipeline", code: httpResponse.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode): \(body)"])
            }

            stage = .receiving
            progressText = "Decoding image…"

            let sdResponse = try JSONDecoder().decode(SDResponse.self, from: data)

            guard let base64String = sdResponse.images.first else {
                throw NSError(domain: "SDPipeline", code: -2,
                              userInfo: [NSLocalizedDescriptionKey: "No images in response"])
            }

            guard let imageData = Data(base64Encoded: base64String),
                  let nsImage = NSImage(data: imageData) else {
                throw NSError(domain: "SDPipeline", code: -3,
                              userInfo: [NSLocalizedDescriptionKey: "Failed to decode base64 image"])
            }

            generatedImage = nsImage
            lastSeed = sdResponse.parameters?.seed
            stage = .done
            progressText = "Done! ✓"

        } catch {
            errorMessage = error.localizedDescription
            stage = .error
            progressText = ""
        }

        isGenerating = false
    }

    // MARK: - Health

    func checkHealth(baseURL: String) async -> Bool {
        // Try /internal/ping first, fall back to /docs (which also returns 200 when ready)
        for path in ["/internal/ping", "/docs"] {
            guard let url = URL(string: "\(baseURL)\(path)") else { continue }
            if let status = try? await URLSession.shared.data(from: url).1 as? HTTPURLResponse,
               status.statusCode == 200 {
                return true
            }
        }
        return false
    }
}
