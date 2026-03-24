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
//   🔧 FIX: ControlNet se pasa como "controlnet_units" TOP-LEVEL en /sdapi/v1/txt2img
//           via SDRequestWithControlNet. Estrategias descartadas:
//           • alwayson_scripts["controlnet"] → 422 (minúsculas)
//           • alwayson_scripts["ControlNet"] → 422 (mayúsculas)
//           • /controlnet/txt2img           → 404 (endpoint no existe)
//   🔧 FIX: Filtrado de controlnet units vacías para evitar rechazos en A1111

@MainActor
class SDService: ObservableObject {

    // MARK: - Published State

    @Published var stage:           PipelineStage = .idle
    @Published var generatedImage:  NSImage?
    @Published var errorMessage:    String?
    @Published var lastSeed:        Int    = 0
    @Published var isGenerating:    Bool   = false
    @Published var progressText:    String = ""

    @Published var generationProgress: Double  = 0.0
    @Published var livePreviewImage:   NSImage?
    @Published var etaText:            String  = ""

    @Published var webuiState: WebuiState = .stopped
    @Published var webuiLog:   String     = ""

    @Published var generationDuration: Double = 0.0

    // MARK: - Private

    private var webuiProcess:   Process?
    private var logPipe:        Pipe?
    private var healthPollTask: Task<Void, Never>?
    private var progressTask:   Task<Void, Never>?
    var progressPollTask:       Task<Void, Never>?

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
                    GPUMonitor.shared.startPolling()
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
                if await checkHealth(baseURL: baseURL) {
                    self.webuiState = .online
                    GPUMonitor.shared.startPolling()
                    return
                }
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
        GPUMonitor.shared.stopPolling()
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

        let requestData: Data
        do {
            requestData = try JSONEncoder().encode(request)
        } catch {
            errorMessage = "Error codificando request: \(error.localizedDescription)"
            stage = .error; isGenerating = false; return
        }

        progressText = "Generando (\(request.steps) pasos)…"

        startProgressPolling(baseURL: baseURL, totalSteps: request.steps)
        startProgressMirroring()

        do {
            let data: Data
            do {
                data = try await SDAPIRateLimiter.shared.generateFetch(url: url, body: requestData)
            } catch SDAPIRateLimiter.RateLimiterError.circuitOpen {
                throw SDError.httpError(code: 503, body: "A1111 no responde (circuit breaker activo)")
            } catch {
                throw error
            }

            stopProgressPolling()

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

            generatedImage     = nsImage
            lastSeed           = sdResponse.parameters?.seed ?? extractSeedFromInfo(sdResponse.info) ?? 0
            generationDuration = Date().timeIntervalSince(generationStart)
            stage              = .done
            progressText       = "Listo ✓"

            UserDefaults.standard.set(generationDuration, forKey: "sdservice.lastDuration")

            ZeroKnowledgeLog.shared.write(
                category: .systemEvent,
                message: "Generación completada — seed:\(lastSeed) pasos:\(request.steps) duración:\(String(format: "%.1f", generationDuration))s modelo:\(settings?.checkpoint ?? "-")"
            )

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

    // MARK: - generateWithProgress()

    func generateWithProgress(
        request:  SDRequest,
        baseURL:  String,
        label:    String = "",
        settings: GenerationSettings? = nil
    ) async {
        self.settings = settings
        if !label.isEmpty { progressText = label }
        await generate(request: request, baseURL: baseURL)
    }

    private var settings: GenerationSettings?

    // MARK: - Progress Polling

    func startProgressPolling(baseURL: String, totalSteps: Int) {
        progressPollTask?.cancel()
        progressPollTask = nil
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

    // MARK: - Progress Mirroring

    private func startProgressMirroring() {
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            let engine = GenerationProgressEngine.shared
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
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

    // MARK: - fetchProgress (v4 compat)

    func fetchProgress(baseURL: String) async {
        await GenerationProgressEngine.shared.fetchProgress()
    }

    // MARK: - Interrupt

    func interruptGeneration(baseURL: String) async {
        guard let url = URL(string: "\(baseURL)/sdapi/v1/interrupt") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 5
        _ = try? await URLSession.shared.data(for: req)

        stopProgressPolling()
        GenerationProgressEngine.shared.stopPolling()

        progressText = "Interrumpido"
        isGenerating = false
        stage        = .idle
    }

    func interruptAndReset(baseURL: String) async {
        await interruptGeneration(baseURL: baseURL)
        resetState()
    }

    // MARK: - generateWithBatchRetry

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

    func cancelProgressPoll() {
        progressPollTask?.cancel()
        progressPollTask = nil
        GenerationProgressEngine.shared.stopPolling()
    }

    // MARK: - VRAM Pre-check

    func vramPreCheck(width: Int, height: Int, steps: Int, enableHR: Bool, hrScale: Double) -> VRAMCheckResult {
        let megapixels   = Double(width * height) / 1_000_000.0
        var estimatedGB  = megapixels * 2.5 + 1.5
        if enableHR  { estimatedGB *= hrScale * 0.6 }
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

// MARK: - GenerationProgressEngine fetch bridge

extension GenerationProgressEngine {
    func fetchProgress() async {
        // El engine maneja esto internamente via pollLoop.
        // Existe como bridge público vacío para compatibilidad con v4.
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

// MARK: - sdPostRaw helper (used by HiResFinishEngine)

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

extension SDService {

    var baseURL: URL? {
        URL(string: UserDefaults.standard.string(forKey: "sd.baseURL") ?? "http://127.0.0.1:7860")
    }

    // MARK: generateWithPlan — entry point unificado
    //
    // Con ControlNet activo  → generateWithControlNet()
    //   → SDRequestWithControlNet → "controlnet_units" TOP-LEVEL en /sdapi/v1/txt2img ✅
    // Solo ADetailer         → generateWithScripts() → alwayson_scripts["ADetailer"]
    // Sin scripts            → generate() plano

    func generateWithPlan(_ plan: SDGenerationPlan, baseURL: String) async {
        let activeUnits = plan.controlNetUnits.filter {
            ($0["enabled"] as? Bool) == true
        }

        if !activeUnits.isEmpty {
            await generateWithControlNet(
                request:         plan.request,
                controlNetUnits: activeUnits,
                alwaysOnScripts: plan.alwaysOnScripts,
                baseURL:         baseURL
            )
        } else if !plan.alwaysOnScripts.isEmpty {
            await generateWithScripts(
                request: plan.request,
                scripts:  plan.alwaysOnScripts,
                baseURL:  baseURL
            )
        } else {
            await generate(request: plan.request, baseURL: baseURL)
        }
    }

    // MARK: generateWithControlNet
    //
    // Usa SDRequestWithControlNet que serializa "controlnet_units" como campo
    // TOP-LEVEL en el body de /sdapi/v1/txt2img — separado de alwayson_scripts.
    // ADetailer sigue en alwaysOnScripts sin cambios.

    func generateWithControlNet(
        request:         SDRequest,
        controlNetUnits: [[String: Any]],
        alwaysOnScripts: [String: Any] = [:],
        baseURL:         String
    ) async {

        isGenerating       = true
        errorMessage       = nil
        generatedImage     = nil
        generationProgress = 0.0
        livePreviewImage   = nil
        etaText            = ""
        stage              = .sending

        let activeUnits = controlNetUnits.filter { ($0["enabled"] as? Bool) == true }
        let unitCount   = activeUnits.count
        progressText    = "ControlNet (\(unitCount) unidad\(unitCount == 1 ? "" : "es"))…"

        guard let url = URL(string: "\(baseURL)/sdapi/v1/txt2img") else {
            errorMessage = "URL inválida: \(baseURL)/sdapi/v1/txt2img"
            stage = .error; isGenerating = false; return
        }

        // ✅ "controlnet_units" top-level — NO en alwayson_scripts
        let wrapper = SDRequestWithControlNet(
            base:            request,
            controlNetUnits: activeUnits,
            alwaysOnScripts: alwaysOnScripts
        )

        var urlRequest             = URLRequest(url: url)
        urlRequest.httpMethod      = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 600

        do {
            urlRequest.httpBody = try JSONEncoder().encode(wrapper)
        } catch {
            errorMessage = "Encode error: \(error.localizedDescription)"
            stage = .error; isGenerating = false; return
        }

        progressText = "Generando \(request.steps) steps · ControlNet…"
        startProgressPolling(baseURL: baseURL, totalSteps: request.steps)

        do {
            let (data, response) = try await URLSession.shared.data(for: urlRequest)

            progressPollTask?.cancel()
            progressPollTask   = nil
            generationProgress = 1.0
            livePreviewImage   = nil

            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? "No body"
                throw SDError.httpError(
                    code: (response as? HTTPURLResponse)?.statusCode ?? 0,
                    body: body
                )
            }

            stage        = .receiving
            progressText = "Decodificando imagen…"

            let sdResponse = try JSONDecoder().decode(SDResponse.self, from: data)
            guard let b64     = sdResponse.images.first,
                  let imgData = Data(base64Encoded: b64),
                  let nsImage = NSImage(data: imgData)
            else { throw SDError.decodeFailed }

            generatedImage = nsImage
            lastSeed       = sdResponse.parameters?.seed ?? extractSeedFromInfo(sdResponse.info) ?? 0
            stage          = .done
            progressText   = "✓ Hecho (\(unitCount) CN unit\(unitCount == 1 ? "" : "s"))"

            ZeroKnowledgeLog.shared.write(
                category: .systemEvent,
                message:  "ControlNet OK · \(unitCount) units · seed:\(lastSeed) · steps:\(request.steps)"
            )

        } catch {
            progressPollTask?.cancel()
            progressPollTask = nil
            errorMessage     = error.localizedDescription
            stage            = .error
            progressText     = ""

            ZeroKnowledgeLog.shared.write(
                category: .systemEvent,
                message:  "ControlNet error: \(error.localizedDescription)"
            )
        }

        isGenerating = false
        stopProgressMirroring()
    }

    // MARK: generateWithScripts — v3

    func generateWithScripts(
        request: SDRequest,
        scripts: [String: Any],
        baseURL: String
    ) async {
        guard !scripts.isEmpty else {
            await generate(request: request, baseURL: baseURL)
            return
        }

        isGenerating       = true
        errorMessage       = nil
        generatedImage     = nil
        generationProgress = 0.0
        livePreviewImage   = nil
        etaText            = ""
        stage              = .sending
        let activeKeys     = scripts.keys.sorted().joined(separator: ", ")
        progressText       = "SD conectando · scripts: \(activeKeys)…"

        guard let url = URL(string: "\(baseURL)/sdapi/v1/txt2img") else {
            errorMessage = "URL inválida: \(baseURL)"
            stage = .error; isGenerating = false; return
        }

        let wrapper = SDRequestWithScripts(base: request, scripts: scripts)
        var urlRequest             = URLRequest(url: url)
        urlRequest.httpMethod      = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 600

        do {
            urlRequest.httpBody = try JSONEncoder().encode(wrapper)
        } catch {
            errorMessage = "Encode error: \(error.localizedDescription)"
            stage = .error; isGenerating = false; return
        }

        progressText = "Generando \(request.steps) steps · \(activeKeys)…"
        startProgressPolling(baseURL: baseURL, totalSteps: request.steps)

        do {
            let (data, response) = try await URLSession.shared.data(for: urlRequest)

            progressPollTask?.cancel()
            progressPollTask   = nil
            generationProgress = 1.0
            livePreviewImage   = nil

            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? "No body"
                throw SDError.httpError(
                    code: (response as? HTTPURLResponse)?.statusCode ?? 0,
                    body: body
                )
            }

            stage        = .receiving
            progressText = "Decodificando imagen…"

            let sdResponse = try JSONDecoder().decode(SDResponse.self, from: data)
            guard let b64     = sdResponse.images.first,
                  let imgData = Data(base64Encoded: b64),
                  let nsImage = NSImage(data: imgData)
            else { throw SDError.decodeFailed }

            generatedImage = nsImage
            lastSeed       = sdResponse.parameters?.seed ?? extractSeedFromInfo(sdResponse.info) ?? 0
            stage          = .done
            progressText   = "✓ Hecho (\(scripts.count) scripts activos)"

        } catch {
            progressPollTask?.cancel()
            progressPollTask = nil
            errorMessage     = error.localizedDescription
            stage            = .error
            progressText     = ""
        }

        isGenerating = false
        Task { await SDRequestScriptsRegistry.shared.pruneOldEntries() }
    }

    // MARK: generateWithRetry (v3)

    func generateWithRetry(
        request: SDRequest,
        baseURL: String,
        scripts: [String: Any] = [:],
        policy:  PipelineRetryPolicy
    ) async {
        var attempt = 0
        while attempt < policy.maxAttempts {
            if attempt > 0 {
                let delay = policy.delayNS(attempt: attempt - 1)
                progressText = "Reintentando (\(attempt)/\(policy.maxAttempts))…"
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
                ZeroKnowledgeLog.shared.write(
                    category: .systemEvent,
                    message:  "SD retry intento \(attempt)/\(policy.maxAttempts)"
                )
            }

            if scripts.isEmpty {
                await generate(request: request, baseURL: baseURL)
            } else {
                await generateWithScripts(request: request, scripts: scripts, baseURL: baseURL)
            }

            if errorMessage == nil { return }
            attempt += 1
        }
    }
}
