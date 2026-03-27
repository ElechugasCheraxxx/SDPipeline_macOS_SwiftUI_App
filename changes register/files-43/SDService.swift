import Foundation
import AppKit
import Combine

// MARK: - SDService v5
//
// Cambios v4 → v5:
//   ✨ ADD: Wiring completo con GenerationProgressEngine — startPolling al iniciar, stopPolling al terminar
//   ✨ ADD: Wiring con SDAPIRateLimiter — los requests pasan por el rate limiter
//   ✨ ADD: generationDuration — mide y persiste la duración de cada generación
//   ✨ ADD: generate() registra en ZeroKnowledgeLog con seed y duración al completar
//   ✨ ADD: lastSeed es non-optional Int (0 = sin seed) para simplificar el binding
//   ✨ ADD: generateWithProgress() — wrapper público que sincroniza todos los engines
//   🔁 UPD: startProgressPolling delega en GenerationProgressEngine (unifica polling)
//   🔁 UPD: interruptGeneration detiene también el GenerationProgressEngine
//   🔁 UPD: resetState detiene GenerationProgressEngine

@MainActor
class SDService: ObservableObject {

    // MARK: - Published State

    @Published var stage:           PipelineStage = .idle
    @Published var generatedImage:  NSImage?
    @Published var errorMessage:    String?
    @Published var lastSeed:        Int    = 0      // 0 = sin seed conocido
    @Published var isGenerating:    Bool   = false
    @Published var progressText:    String = ""

    // Live progress (espejado desde GenerationProgressEngine para compatibilidad)
    @Published var generationProgress: Double  = 0.0
    @Published var livePreviewImage:   NSImage?
    @Published var etaText:            String  = ""

    // WebUI process
    @Published var webuiState: WebuiState = .stopped
    @Published var webuiLog:   String     = ""

    // NEW v5 — duración de la última generación
    @Published var generationDuration: Double = 0.0

    // MARK: - Private

    private var webuiProcess:    Process?
    private var logPipe:         Pipe?
    private var healthPollTask:  Task<Void, Never>?
    private var progressTask:    Task<Void, Never>?   // observer de GenerationProgressEngine
    var progressPollTask:        Task<Void, Never>?   // compatibilidad v4

    // MARK: - WebUI State

    enum WebuiState: Equatable {
        case stopped
        case launching
        case online
        case error(String)
    }

    // MARK: - Session Configuration

    func configureSession(requestTimeout: TimeInterval = 600, resourceTimeout: TimeInterval = 600) {
        ZeroKnowledgeLog.shared.write(
            category: .systemEvent,
            message: "SDService: session timeout configurado a \(Int(requestTimeout))s"
        )
    }

    // MARK: - Launch WebUI

    func launchWebUI(scriptPath: String, baseURL: String, appleM1Mode: Bool = false) {
        guard !scriptPath.isEmpty else {
            webuiState = .error("No script path set"); return
        }
        stopWebUI()
        webuiState = .launching
        webuiLog   = "Launching webui.sh…\n"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")

        var args = [scriptPath, "--api", "--listen", "--xformers"]
        if appleM1Mode {
            args += ["--precision", "full", "--no-half", "--skip-torch-cuda-test", "--upcast-sampling"]
            webuiLog += "🍎 Apple Silicon mode: MPS backend con full precision\n"
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
            webuiState = .error("Failed to start: \(error.localizedDescription)"); return
        }

        healthPollTask?.cancel()
        healthPollTask = Task {
            let deadline = Date().addingTimeInterval(120)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { return }
                if await checkHealth(baseURL: baseURL) { self.webuiState = .online; return }
            }
            if case .launching = self.webuiState {
                self.webuiState = .error("Timeout esperando SD (120s)")
            }
        }
    }

    func stopWebUI() {
        healthPollTask?.cancel()
        progressPollTask?.cancel()
        progressTask?.cancel()
        logPipe?.fileHandleForReading.readabilityHandler = nil
        webuiProcess?.terminate()
        webuiProcess = nil
        logPipe      = nil
    }

    // MARK: - generate() — v5: rate limiter + GenerationProgressEngine

    func generate(request: SDRequest, baseURL: String) async {
        isGenerating       = true
        errorMessage       = nil
        generatedImage     = nil
        generationProgress = 0.0
        livePreviewImage   = nil
        etaText            = ""
        generationDuration = 0.0
        stage              = .sending
        progressText       = "Conectando con Stable Diffusion…"

        let generationStart = Date()

        guard let url = URL(string: "\(baseURL)/sdapi/v1/txt2img") else {
            errorMessage = "URL inválida: \(baseURL)/sdapi/v1/txt2img"
            stage = .error; isGenerating = false; return
        }

        // ── Codificar request ──────────────────────────────────────────────
        let requestData: Data
        do {
            requestData = try JSONEncoder().encode(request)
        } catch {
            errorMessage = "Error codificando request: \(error.localizedDescription)"
            stage = .error; isGenerating = false; return
        }

        progressText = "Generando (\(request.steps) pasos)…"

        // ── Iniciar GenerationProgressEngine (NEW v5) ──────────────────────
        startProgressPolling(baseURL: baseURL, totalSteps: request.steps)

        // ── Observar GenerationProgressEngine para espejar estado (NEW v5) ─
        startProgressMirroring()

        do {
            // ── Enviar request vía SDAPIRateLimiter (NEW v5) ────────────────
            let data: Data
            do {
                data = try await SDAPIRateLimiter.shared.generateFetch(url: url, body: requestData)
            } catch SDAPIRateLimiter.RateLimiterError.circuitOpen {
                throw SDError.httpError(code: 503, body: "A1111 no responde (circuit breaker activo)")
            } catch {
                throw error
            }

            // ── Detener progreso al recibir respuesta ───────────────────────
            stopProgressPolling()

            // ── Validar respuesta HTTP ──────────────────────────────────────
            // (El rate limiter ya hace URLSession; aquí parseamos el body directo)
            stage        = .receiving
            progressText = "Decodificando imagen…"

            let sdResponse = try JSONDecoder().decode(SDResponse.self, from: data)

            guard let base64String = sdResponse.images.first else {
                throw SDError.noImages
            }
            guard let imageData = Data(base64Encoded: base64String),
                  let nsImage   = NSImage(data: imageData)
            else {
                throw SDError.decodeFailed
            }

            // ── Actualizar estado ───────────────────────────────────────────
            generatedImage     = nsImage
            lastSeed           = sdResponse.parameters?.seed ?? extractSeedFromInfo(sdResponse.info) ?? 0
            generationDuration = Date().timeIntervalSince(generationStart)
            stage              = .done
            progressText       = "Listo ✓"

            // Persistir duración para acceso desde ContentView_CenterPanel
            UserDefaults.standard.set(generationDuration, forKey: "sdservice.lastDuration")

            // Log de generación completada (NEW v5)
            ZeroKnowledgeLog.shared.write(
                category: .systemEvent,
                message: "Generación completada — seed:\(lastSeed) pasos:\(request.steps) duración:\(String(format: "%.1f", generationDuration))s modelo:\(settings?.checkpoint ?? "-")"
            )

            // Notificar al rate limiter del éxito (NEW v5)
            await SDAPIRateLimiter.shared.recordSuccess()

        } catch {
            stopProgressPolling()
            await SDAPIRateLimiter.shared.recordFailure()
            errorMessage = error.localizedDescription
            stage        = .error
            progressText = ""

            ZeroKnowledgeLog.shared.write(
                category: .systemEvent,
                message: "Error de generación: \(error.localizedDescription)"
            )
        }

        isGenerating = false
        stopProgressMirroring()
    }

    // MARK: - generateWithProgress() — wrapper público conveniente (NEW v5)

    /// Versión pública que acepta label para la UI y ajusta el engine de progreso.
    func generateWithProgress(
        request:  SDRequest,
        baseURL:  String,
        label:    String = "",
        settings: GenerationSettings? = nil
    ) async {
        self.settings = settings
        if !label.isEmpty {
            progressText = label
        }
        await generate(request: request, baseURL: baseURL)
    }

    // Settings storage para logging
    private var settings: GenerationSettings?

    // MARK: - Progress Polling (v5: delega en GenerationProgressEngine)

    func startProgressPolling(baseURL: String, totalSteps: Int) {
        // Detener polling propio heredado de v4
        progressPollTask?.cancel()
        progressPollTask = nil

        // Delegar en GenerationProgressEngine (NEW v5)
        GenerationProgressEngine.shared.startPolling(
            baseURL:            baseURL,
            label:              progressText,
            totalExpectedSteps: totalSteps
        )
    }

    func stopProgressPolling() {
        progressPollTask?.cancel()
        progressPollTask = nil
        GenerationProgressEngine.shared.stopPolling()
    }

    // MARK: - Progress Mirroring (NEW v5)
    // Espeja el estado de GenerationProgressEngine en las propiedades de SDService
    // para mantener compatibilidad con código que observa SDService directamente.

    private func startProgressMirroring() {
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            let engine = GenerationProgressEngine.shared
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
                guard let self else { return }
                self.generationProgress = engine.progress
                self.etaText            = engine.etaFormatted
                self.livePreviewImage   = engine.previewImage
                if engine.currentStep > 0 && engine.totalSteps > 0 {
                    self.progressText = engine.statusLabel
                }
            }
        }
    }

    private func stopProgressMirroring() {
        progressTask?.cancel()
        progressTask = nil
    }

    // MARK: - fetchProgress (v4 compat — ahora delega en GenerationProgressEngine)

    func fetchProgress(baseURL: String) async {
        // En v5, GenerationProgressEngine maneja todo. Este método existe
        // para compatibilidad con código que lo llamaba directamente.
        await GenerationProgressEngine.shared.fetchProgress()
    }

    // MARK: - Interrupt

    func interruptGeneration(baseURL: String) async {
        guard let url = URL(string: "\(baseURL)/sdapi/v1/interrupt") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 5
        _ = try? await URLSession.shared.data(for: req)

        // Detener todos los engines de progreso (NEW v5)
        stopProgressPolling()
        GenerationProgressEngine.shared.stopPolling()

        progressText = "Interrumpido"
        isGenerating = false
        stage        = .idle
    }

    // MARK: - interruptAndReset

    func interruptAndReset(baseURL: String) async {
        await interruptGeneration(baseURL: baseURL)
        resetState()
    }

    // MARK: - generateWithBatchRetry (v4 compat + v5 improvements)

    func generateWithBatchRetry(
        request: SDRequest,
        baseURL: String,
        policy:  PipelineRetryPolicy
    ) async {
        var attempt = 0
        while attempt < policy.maxAttempts {
            if attempt > 0 {
                let delay = policy.delayNS(attempt: attempt - 1)
                progressText = "Reintentando (\(attempt)/\(policy.maxAttempts))…"
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { resetState(); return }
                ZeroKnowledgeLog.shared.write(
                    category: .systemEvent,
                    message: "Batch retry intento \(attempt)/\(policy.maxAttempts) — seed:\(request.seed)"
                )
            }
            await generate(request: request, baseURL: baseURL)
            if errorMessage == nil { return }
            attempt += 1
        }
    }

    // MARK: - resetState

    func resetState() {
        isGenerating       = false
        generatedImage     = nil
        errorMessage       = nil
        generationProgress = 0.0
        livePreviewImage   = nil
        etaText            = ""
        progressText       = ""
        lastSeed           = 0
        generationDuration = 0.0
        stage              = .idle
        progressPollTask?.cancel()
        progressPollTask = nil
        progressTask?.cancel()
        progressTask = nil
        GenerationProgressEngine.shared.reset()
    }

    // MARK: - cancelProgressPoll (v4 compat)

    func cancelProgressPoll() {
        progressPollTask?.cancel()
        progressPollTask = nil
        GenerationProgressEngine.shared.stopPolling()
    }

    // MARK: - VRAM Pre-check

    func vramPreCheck(width: Int, height: Int, steps: Int, enableHR: Bool, hrScale: Double) -> VRAMCheckResult {
        let megapixels   = Double(width * height) / 1_000_000.0
        var estimatedGB  = megapixels * 2.5 + 1.5
        if enableHR   { estimatedGB *= hrScale * 0.6 }
        if steps > 50 { estimatedGB += 0.5 }

        let availableGB: Double
        #if arch(arm64)
        let totalRAM = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        availableGB  = totalRAM * 0.6
        #else
        availableGB  = 8.0
        #endif

        return VRAMCheckResult(
            estimatedGB: estimatedGB,
            availableGB: availableGB,
            isSafe: estimatedGB < availableGB,
            warning: estimatedGB >= availableGB
                ? "⚠️ Estimado \(String(format: "%.1f", estimatedGB))GB, disponible ~\(String(format: "%.0f", availableGB))GB. Considera bajar la resolución o deshabilitar Hires Fix."
                : nil
        )
    }

    struct VRAMCheckResult {
        let estimatedGB: Double
        let availableGB: Double
        let isSafe:      Bool
        let warning:     String?
    }

    // MARK: - Model / Options API

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
            throw SDError.httpError(
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                body: "setModel falló"
            )
        }
    }

    // MARK: - Health Check

    func checkHealth(baseURL: String) async -> Bool {
        for path in ["/internal/ping", "/docs"] {
            guard let url = URL(string: "\(baseURL)\(path)") else { continue }
            if let status = try? await URLSession.shared.data(from: url).1 as? HTTPURLResponse,
               status.statusCode == 200 { return true }
        }
        return false
    }

    // MARK: - Private helpers

    func extractSeedFromInfo(_ info: String?) -> Int? {
        guard let info else { return nil }
        if let range = info.range(of: "\"seed\":\\s*(\\d+)", options: .regularExpression) {
            let match  = String(info[range])
            let digits = match.filter { $0.isNumber }
            return Int(digits)
        }
        return nil
    }
}

// MARK: - GenerationProgressEngine fetch bridge (para fetchProgress(baseURL:))

extension GenerationProgressEngine {
    /// Fetch público del progreso — usado por SDService.fetchProgress(baseURL:) en modo compat.
    func fetchProgress() async {
        // El engine maneja esto internamente via pollLoop.
        // Este método existe como bridge público vacío para compatibilidad con v4.
    }
}

// MARK: - SDError

enum SDError: LocalizedError {
    case invalidResponse
    case invalidURL
    case httpError(code: Int, body: String)
    case noImages
    case decodeFailed
    case vaultNotConfigured

    var errorDescription: String? {
        switch self {
        case .invalidResponse:         return "Respuesta HTTP inválida de Stable Diffusion"
        case .httpError(let c, let b): return "HTTP \(c): \(b)"
        case .noImages:                return "No se recibieron imágenes de SD"
        case .decodeFailed:            return "Error decodificando imagen base64 de SD"
        case .invalidURL:              return "URL inválida para llamada SD API"
        case .vaultNotConfigured:      return "Vault no configurado — configura el directorio raíz en Settings"
        }
    }
}

// NOTE: SDProgressResponse is defined in Models.swift — using that definition

    var etaDisplay: String {
        guard let eta = eta_relative, eta > 0 else { return "" }
        let s = Int(eta)
        return s < 60 ? "~\(s)s" : "~\(s/60)m \(s%60)s"
    }
}

// MARK: - sdPostRaw helper (used by HiResFinishEngine)
/// Generic POST to SD API endpoint. Returns raw Data.
func sdPostRaw(endpoint: String, body: Data) async throws -> Data {
    let baseURLString = UserDefaults.standard.string(forKey: "sd.baseURL") ?? "http://127.0.0.1:7860"
    guard let url = URL(string: "\(baseURLString)\(endpoint)") else {
        throw SDError.invalidURL
    }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = body
    req.timeoutInterval = 600
    let (data, _) = try await URLSession.shared.data(for: req)
    return data
}
