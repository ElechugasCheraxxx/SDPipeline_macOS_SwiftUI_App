import Foundation
import Combine

// MARK: - SDAPIRateLimiter
//
// Limitador de tasa y coalescer de requests para el API de Automatic1111.
// Problema: cuando hay múltiples engines (ControlNet, IPAdapter, ADetailer, Batch)
// emitiendo requests simultáneamente, se saturan los sockets de A1111.
//
// Solución:
//   • Token Bucket Algorithm — N tokens por segundo, configurable
//   • Request Queue con prioridades (generación > post-process > poll)
//   • Deduplicación de polls de progreso concurrentes (solo 1 activo)
//   • Circuit Breaker — para automáticamente si A1111 no responde
//   • Métricas de throughput para el dashboard
//
// ROADMAP: Escalabilidad API — nuevo componente de infraestructura

actor SDAPIRateLimiter {

    static let shared = SDAPIRateLimiter()
    private init() { Task { await startRefillTask() } }

    // MARK: - Configuration

    struct Config {
        var maxTokens:        Int    = 10    // Burst máximo
        var refillPerSecond:  Int    = 3     // Tokens/segundo sostenido
        var maxQueueDepth:    Int    = 50    // Requests en cola antes de rechazar
        var circuitBreakerThreshold: Int = 5 // Fallos consecutivos antes de abrir
        var circuitBreakerResetMs:   Int = 10_000 // ms antes de re-intentar
        var pollDedupeWindowMs:      Int = 400    // Ventana de deduplicación de polls
    }

    private(set) var config = Config()

    // MARK: - Token Bucket State

    private var tokens:      Int   = 10
    private var lastRefill:  Date  = Date()

    // MARK: - Circuit Breaker

    enum CircuitState { case closed, open, halfOpen }
    private(set) var circuitState: CircuitState = .closed
    private var consecutiveFailures: Int = 0
    private var circuitOpenedAt: Date?

    // MARK: - Queue

    enum RequestPriority: Int, Comparable {
        case critical = 0   // Interrupciones de emergencia
        case high     = 1   // Generación interactiva
        case normal   = 2   // Batch, post-process
        case low      = 3   // Polls de progreso, pre-fetch

        static func < (lhs: RequestPriority, rhs: RequestPriority) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    struct QueuedRequest {
        let id:         UUID          = UUID()
        let priority:   RequestPriority
        let tag:        String        // Para deduplicación (ej: "progress-poll")
        let execute:    @Sendable () async throws -> Data
        let continuation: CheckedContinuation<Data, Error>
    }

    private var queue: [QueuedRequest] = []

    // MARK: - Deduplication

    private var activeTags: Set<String> = []

    // MARK: - Metrics (observable desde el dashboard)

    struct Metrics: Sendable {
        var totalRequests:    Int = 0
        var throttled:        Int = 0
        var circuitBreaks:    Int = 0
        var queueDepth:       Int = 0
        var avgLatencyMs:     Double = 0
        var requestsPerMin:   Double = 0
    }
    private(set) var metrics = Metrics()
    private var recentLatencies: [Double] = []
    private var requestTimestamps: [Date]  = []

    // MARK: - Public API

    /// Encola un request respetando el rate limit y la prioridad.
    /// Throws si el circuit breaker está abierto o la cola está llena.
    func request(
        priority: RequestPriority = .normal,
        tag: String = "",
        execute: @Sendable @escaping () async throws -> Data
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            Task {
                self.enqueue(
                    priority: priority,
                    tag: tag,
                    execute: execute,
                    continuation: continuation
                )
            }
        }
    }

    /// Versión de conveniencia para URLRequests estándar.
    func fetch(
        url: URL,
        method: String = "GET",
        body: Data? = nil,
        headers: [String: String] = [:],
        priority: RequestPriority = .normal,
        tag: String = ""
    ) async throws -> Data {
        try await request(priority: priority, tag: tag) {
            let timeout: TimeInterval = (method == "POST") ? 600 : 30
            var req = URLRequest(url: url, timeoutInterval: timeout)
            req.httpMethod = method
            req.httpBody   = body
            headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
            if body != nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            let (data, _) = try await URLSession.shared.data(for: req)
            return data
        }
    }

    /// Actualiza la configuración del limiter.
    func configure(_ block: (inout Config) -> Void) {
        block(&config)
        tokens = min(tokens, config.maxTokens)
    }

    // MARK: - Circuit Breaker Control

    func recordSuccess() {
        consecutiveFailures = 0
        if circuitState == .halfOpen {
            circuitState = .closed
        }
    }

    func recordFailure() {
        consecutiveFailures += 1
        if consecutiveFailures >= config.circuitBreakerThreshold {
            if circuitState != .open {
                circuitState    = .open
                circuitOpenedAt = Date()
                metrics.circuitBreaks += 1
            }
        }
    }

    // MARK: - Private: Enqueueing

    private func enqueue(
        priority: RequestPriority,
        tag: String,
        execute: @Sendable @escaping () async throws -> Data,
        continuation: CheckedContinuation<Data, Error>
    ) {
        // Circuit breaker check
        if circuitState == .open {
            if let openedAt = circuitOpenedAt,
               Date().timeIntervalSince(openedAt) * 1000 > Double(config.circuitBreakerResetMs) {
                circuitState = .halfOpen
            } else {
                continuation.resume(throwing: RateLimiterError.circuitOpen)
                return
            }
        }

        // Deduplication check
        if !tag.isEmpty && activeTags.contains(tag) {
            continuation.resume(throwing: RateLimiterError.deduplicated(tag))
            return
        }

        // Queue depth check
        if queue.count >= config.maxQueueDepth {
            metrics.throttled += 1
            continuation.resume(throwing: RateLimiterError.queueFull)
            return
        }

        let queued = QueuedRequest(
            priority: priority,
            tag: tag,
            execute: execute,
            continuation: continuation
        )

        // Priority insertion sort
        let insertIdx = queue.firstIndex(where: { $0.priority > priority }) ?? queue.count
        queue.insert(queued, at: insertIdx)
        metrics.queueDepth = queue.count

        if !tag.isEmpty { activeTags.insert(tag) }

        metrics.totalRequests += 1
        trackRequestTimestamp()

        drainQueue()
    }

    // MARK: - Private: Queue Drain

    private func drainQueue() {
        refillTokens()

        while tokens > 0 && !queue.isEmpty {
            let item = queue.removeFirst()
            tokens -= 1
            metrics.queueDepth = queue.count

            if !item.tag.isEmpty { activeTags.remove(item.tag) }

            Task {
                let start = Date()
                do {
                    let data = try await item.execute()
                    let latencyMs = Date().timeIntervalSince(start) * 1000
                    self.recordLatency(latencyMs)
                    self.recordSuccess()
                    item.continuation.resume(returning: data)
                } catch {
                    self.recordFailure()
                    item.continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Private: Token Refill

    private func refillTokens() {
        let now      = Date()
        let elapsed  = now.timeIntervalSince(lastRefill)
        let newTokens = Int(elapsed * Double(config.refillPerSecond))
        if newTokens > 0 {
            tokens    = min(tokens + newTokens, config.maxTokens)
            lastRefill = now
        }
    }

    private func startRefillTask() {
        Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
                await self?.periodicDrain()
            }
        }
    }

    private func periodicDrain() {
        guard !queue.isEmpty else { return }
        drainQueue()
    }

    // MARK: - Private: Metrics

    private func recordLatency(_ ms: Double) {
        recentLatencies.append(ms)
        if recentLatencies.count > 50 { recentLatencies.removeFirst() }
        metrics.avgLatencyMs = recentLatencies.reduce(0, +) / Double(recentLatencies.count)
    }

    private func trackRequestTimestamp() {
        let now = Date()
        requestTimestamps.append(now)
        // Limpiar más de 1 minuto
        requestTimestamps = requestTimestamps.filter { now.timeIntervalSince($0) <= 60 }
        metrics.requestsPerMin = Double(requestTimestamps.count)
    }

    // MARK: - Errors

    enum RateLimiterError: LocalizedError {
        case circuitOpen
        case queueFull
        case deduplicated(String)

        var errorDescription: String? {
            switch self {
            case .circuitOpen:         return "A1111 no está respondiendo (circuit breaker activo)"
            case .queueFull:           return "Cola de requests saturada — A1111 sobrecargado"
            case .deduplicated(let t): return "Request duplicado omitido: \(t)"
            }
        }
    }
}

// MARK: - SDService Extension: Rate-limited fetch

/// Extension helper para que SDService use el rate limiter transparentemente.
extension SDAPIRateLimiter {

    /// Fetch rate-limited para el API de generación (alta prioridad).
    func generateFetch(url: URL, body: Data) async throws -> Data {
        try await fetch(
            url: url,
            method: "POST",
            body: body,
            headers: ["Content-Type": "application/json"],
            priority: .high,
            tag: ""
        )
    }

    /// Fetch rate-limited para polls de progreso (baja prioridad, deduplicado).
    func progressFetch(url: URL) async throws -> Data {
        try await fetch(
            url: url,
            method: "GET",
            priority: .low,
            tag: "progress-poll"
        )
    }

    /// Fetch rate-limited para operaciones de post-procesado (prioridad normal).
    func postProcFetch(url: URL, body: Data) async throws -> Data {
        try await fetch(
            url: url,
            method: "POST",
            body: body,
            headers: ["Content-Type": "application/json"],
            priority: .normal
        )
    }
}
