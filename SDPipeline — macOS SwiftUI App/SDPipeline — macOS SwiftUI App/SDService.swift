import Foundation
import AppKit
import Combine

// MARK: - SDService v2
//
// CAMBIOS v2:
//   - Integración con GenerationProgressMonitor (live preview + ETA + step counter)
//   - Integración con ControlNetEngine (alwayson_scripts injection)
//   - Integración con EmbeddingManager (inject active embeddings)
//   - Interrupt endpoint (/sdapi/v1/interrupt) para cancelación mid-generation
//   - Skip endpoint (/sdapi/v1/skip) para saltar al siguiente paso
//   - Soporte para override_settings (VAE, clip_skip, etc.)

@MainActor
class SDService: ObservableObject {

    @Published var stage:          PipelineStage = .idle
    @Published var generatedImage: NSImage?
    @Published var errorMessage:   String?
    @Published var lastSeed:       Int?
    @Published var isGenerating:   Bool          = false
    @Published var progressText:   String        = ""

    // MARK: - WebUI Process

    @Published var webuiState: WebuiState = .stopped
    @Published var webuiLog:   String     = ""

    private var webuiProcess:  Process?
    private var logPipe:       Pipe?
    private var healthPollTask: Task<Void, Never>?

    enum WebuiState: Equatable {
        case stopped
        case launching
        case online
        case error(String)
    }

    // MARK: - Launch / Stop

    func launchWebUI(scriptPath: String, baseURL: String) {
        guard !scriptPath.isEmpty else {
            webuiState = .error("No script path set"); return
        }
        stopWebUI()
        webuiState = .launching
        webuiLog   = "Launching webui.sh…\n"

        let process = Process()
        process.executableURL    = URL(fileURLWithPath: "/bin/bash")
        process.arguments        = [scriptPath, "--api"]
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
            Task { @MainActor [weak self] in self?.webuiLog += text }
        }

        do {
            try process.run()
            webuiProcess = process
        } catch {
            webuiState = .error("Failed to start: \(error.localizedDescription)")
            return
        }

        healthPollTask?.cancel()
        healthPollTask = Task {
            let deadline = Date().addingTimeInterval(120)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { return }
                if await self.checkHealth(baseURL: baseURL) {
                    self.webuiState = .online
                    return
                }
            }
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
        logPipe      = nil
    }

    // MARK: - Generate (txt2img)

    func generate(request: SDRequest, baseURL: String) async {
        isGenerating  = true
        errorMessage  = nil
        generatedImage = nil
        stage         = .sending
        progressText  = "Conectando con Stable Diffusion…"

        guard let url = URL(string: "\(baseURL)/sdapi/v1/txt2img") else {
            errorMessage = "URL inválida: \(baseURL)/sdapi/v1/txt2img"
            stage = .error; isGenerating = false; return
        }

        // Build payload dict (allows injection of alwayson_scripts)
        var payload: [String: Any]
        do {
            let requestData = try JSONEncoder().encode(request)
            guard var dict = try JSONSerialization.jsonObject(with: requestData) as? [String: Any]
            else { throw NSError(domain: "SDService", code: -1) }

            // ── Inject ControlNet if enabled ────────────────────────────────────
            if let cnScripts = ControlNetEngine.shared.alwaysonScriptsPayload() {
                dict["alwayson_scripts"] = cnScripts
            }

            payload = dict
        } catch {
            errorMessage = "Error serializando request: \(error.localizedDescription)"
            stage = .error; isGenerating = false; return
        }

        // ── Start live progress monitor ──────────────────────────────────────────
        GenerationProgressMonitor.shared.start(baseURL: baseURL, interval: 1.0)

        progressText = "Generando (\(request.steps) steps)…"
        stage = .sending

        do {
            guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
                throw NSError(domain: "SDService", code: -2, userInfo: [NSLocalizedDescriptionKey: "Error serializando payload"])
            }

            var urlRequest = URLRequest(url: url)
            urlRequest.httpMethod  = "POST"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.timeoutInterval = 300
            urlRequest.httpBody    = body

            let (data, response) = try await URLSession.shared.data(for: urlRequest)

            // ── Stop progress monitor ────────────────────────────────────────────
            GenerationProgressMonitor.shared.stop()

            guard let http = response as? HTTPURLResponse else {
                throw NSError(domain: "SDService", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"])
            }

            guard http.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? "Unknown error"
                throw NSError(domain: "SDService", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(body)"])
            }

            stage = .receiving
            progressText = "Decodificando imagen…"

            let sdResponse = try JSONDecoder().decode(SDResponse.self, from: data)

            guard let base64String = sdResponse.images.first else {
                throw NSError(domain: "SDService", code: -2,
                              userInfo: [NSLocalizedDescriptionKey: "No images in response"])
            }

            guard let imageData = Data(base64Encoded: base64String),
                  let nsImage   = NSImage(data: imageData) else {
                throw NSError(domain: "SDService", code: -3,
                              userInfo: [NSLocalizedDescriptionKey: "Failed to decode base64 image"])
            }

            generatedImage = nsImage
            lastSeed       = sdResponse.parameters?.seed
            stage          = .done
            progressText   = "Listo ✓"

        } catch {
            GenerationProgressMonitor.shared.stop()
            errorMessage = error.localizedDescription
            stage        = .error
            progressText = ""
        }

        isGenerating = false
    }

    // MARK: - Interrupt / Skip

    /// Interrumpir la generación en curso.
    func interrupt(baseURL: String) async {
        guard let url = URL(string: "\(baseURL)/sdapi/v1/interrupt") else { return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        _ = try? await URLSession.shared.data(for: req)
        GenerationProgressMonitor.shared.stop()
    }

    /// Saltar el step actual (acelerar convergencia).
    func skip(baseURL: String) async {
        guard let url = URL(string: "\(baseURL)/sdapi/v1/skip") else { return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        _ = try? await URLSession.shared.data(for: req)
    }

    // MARK: - Health

    func checkHealth(baseURL: String) async -> Bool {
        for path in ["/internal/ping", "/docs"] {
            guard let url = URL(string: "\(baseURL)\(path)") else { continue }
            if let status = try? await URLSession.shared.data(from: url).1 as? HTTPURLResponse,
               status.statusCode == 200 {
                return true
            }
        }
        return false
    }

    // MARK: - Fetch Options (checkpoint, VAE, samplers)

    func fetchCurrentOptions(baseURL: String) async -> [String: Any]? {
        guard let url = URL(string: "\(baseURL)/sdapi/v1/options"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    func fetchSamplers(baseURL: String) async -> [String] {
        guard let url = URL(string: "\(baseURL)/sdapi/v1/samplers"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return list.compactMap { $0["name"] as? String }
    }

    func fetchSchedulers(baseURL: String) async -> [String] {
        guard let url = URL(string: "\(baseURL)/sdapi/v1/schedulers"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return list.compactMap { $0["name"] as? String }
    }

    /// Cambiar opciones en A1111 (checkpoint, VAE, clip_skip, etc.).
    @discardableResult
    func setOptions(_ options: [String: Any], baseURL: String) async -> Bool {
        guard let url  = URL(string: "\(baseURL)/sdapi/v1/options"),
              let body = try? JSONSerialization.data(withJSONObject: options)
        else { return false }
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody  = body
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse
        else { return false }
        return http.statusCode == 200
    }
}
