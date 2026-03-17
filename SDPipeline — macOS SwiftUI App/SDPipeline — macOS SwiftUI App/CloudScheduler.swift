import Foundation
import AppKit
import Combine

// MARK: - CloudScheduler
//
// Distribución de tareas de generación en múltiples GPUs / nodos / nube.
// Soporta:
//   • Multi-GPU local (2+ instancias de A1111 en distintos puertos)
//   • RunPod / Vast.ai / Replicate API
//   • Clusters A1111 en red local (LAN)

@MainActor
final class CloudScheduler: ObservableObject {

    static let shared = CloudScheduler()
    private init() {
        loadConfig()
        if config.enabled { startHealthCheck() }
    }

    // MARK: - Config

    struct SchedulerConfig: Codable {
        var enabled:          Bool              = false
        var strategy:         DistributionStrategy = .roundRobin
        var nodes:            [ComputeNode]     = []
        var cloudProviders:   [CloudProvider]   = []
        var preferCloud:      Bool              = false
        var maxConcurrent:    Int               = 2
        var retryOnFailure:   Bool              = true
        var fallbackToLocal:  Bool              = true

        enum DistributionStrategy: String, CaseIterable, Codable {
            case roundRobin    = "Round-Robin"
            case leastLoaded   = "Menos cargado"
            case fastestFirst  = "Más rápido primero"
            case localFirst    = "Local primero"
            case cloudFirst    = "Nube primero"
        }
    }

    @Published var config = SchedulerConfig()

    // MARK: - Compute Node

    struct ComputeNode: Identifiable, Codable, Equatable {
        var id:             String        = UUID().uuidString
        var name:           String
        var baseURL:        String
        var apiKey:         String        = ""
        var type:           NodeType      = .local
        var priority:       Int           = 5
        var maxVRAM:        Int           = 8
        var status:         NodeStatus    = .unknown
        var currentJobs:    Int           = 0
        var responseTimeMs: Double        = 0
        var successRate:    Double        = 1.0
        var totalJobsDone:  Int           = 0
        var lastSeen:       Date?         = nil

        enum NodeType: String, CaseIterable, Codable {
            case local     = "Local"
            case lan       = "LAN"
            case runpod    = "RunPod"
            case vastai    = "Vast.ai"
            case replicate = "Replicate"
            case custom    = "Personalizado"

            var icon: String {
                switch self {
                case .local:     return "desktopcomputer"
                case .lan:       return "network"
                case .runpod:    return "cloud.fill"
                case .vastai:    return "bolt.cloud.fill"
                case .replicate: return "arrow.triangle.2.circlepath.circle.fill"
                case .custom:    return "server.rack"
                }
            }
        }

        enum NodeStatus: String, Codable, Equatable {
            case unknown   = "Desconocido"
            case online    = "Online"
            case busy      = "Ocupado"
            case offline   = "Offline"
            case error     = "Error"

            var color: String {
                switch self {
                case .online:   return "#34d399"
                case .busy:     return "#fbbf24"
                case .offline:  return "#9090a8"
                case .error:    return "#ef4444"
                case .unknown:  return "#9090a8"
                }
            }

            var icon: String {
                switch self {
                case .online:  return "checkmark.circle.fill"
                case .busy:    return "clock.fill"
                case .offline: return "stop.circle"
                case .error:   return "xmark.circle.fill"
                case .unknown: return "questionmark.circle"
                }
            }
        }

        var isAvailable: Bool { status == .online || status == .busy }
        var loadScore: Double { Double(currentJobs) / max(1, Double(priority)) }
    }

    // MARK: - Cloud Provider

    struct CloudProvider: Identifiable, Codable {
        var id:         String = UUID().uuidString
        var type:       CloudType
        var apiKey:     String = ""
        var endpoint:   String = ""
        var model:      String = ""
        var costPerJob: Double = 0
        var enabled:    Bool   = true

        enum CloudType: String, CaseIterable, Codable {
            case runpod    = "RunPod"
            case vastai    = "Vast.ai"
            case replicate = "Replicate"
            case modal     = "Modal"
            case lambda    = "Lambda GPU Cloud"

            var apiBase: String {
                switch self {
                case .runpod:    return "https://api.runpod.io/v2"
                case .vastai:    return "https://console.vast.ai/api/v0"
                case .replicate: return "https://api.replicate.com/v1"
                case .modal:     return "https://api.modal.com"
                case .lambda:    return "https://cloud.lambdalabs.com/api/v1"
                }
            }
        }
    }

    // MARK: - Distributed Job

    struct DistributedJob: Identifiable {
        let id         = UUID()
        let request:    SDRequest
        let priority:   Int
        var nodeID:     String?     = nil
        var status:     JobStatus   = .queued
        var submittedAt: Date       = Date()
        var startedAt:  Date?       = nil
        var completedAt: Date?      = nil
        var result:     NSImage?    = nil
        var errorMsg:   String?     = nil
        var retries:    Int         = 0

        enum JobStatus: String {
            case queued     = "En cola"
            case routing    = "Enrutando"
            case submitted  = "Enviado"
            case generating = "Generando"
            case done       = "Completado"
            case failed     = "Fallido"
            case cancelled  = "Cancelado"
        }

        var duration: TimeInterval? {
            guard let s = startedAt, let e = completedAt else { return nil }
            return e.timeIntervalSince(s)
        }
    }

    // MARK: - State

    var nodes: [ComputeNode] {
        get { config.nodes }
        set { config.nodes = newValue }
    }
    
    @Published var activeJobs:    [DistributedJob] = []
    @Published var completedJobs: [DistributedJob] = []
    @Published var isHealthChecking = false
    @Published var clusterStats: ClusterStats?

    private var healthCheckTask: Task<Void, Never>?
    private var currentNodeIndex = 0

    // MARK: - Cluster Stats

    struct ClusterStats {
        var totalNodes:    Int
        var onlineNodes:   Int
        var totalVRAM:     Int
        var activeJobs:    Int
        var jobsPerHour:   Double
        var avgLatencyMs:  Double
        var totalCost:     Double
    }

    // MARK: - Submit Job

    func submitJob(request: SDRequest, priority: Int = 5) async throws -> NSImage? {
        guard config.enabled else {
            throw SchedulerError.schedulerDisabled
        }

        let job = DistributedJob(request: request, priority: priority)
        activeJobs.append(job)
        let jobIdx = activeJobs.count - 1

        activeJobs[jobIdx].status = .routing

        guard let node = selectNode(for: request) else {
            if config.fallbackToLocal {
                activeJobs[jobIdx].status = .cancelled
                throw SchedulerError.noAvailableNode
            }
            throw SchedulerError.noAvailableNode
        }

        activeJobs[jobIdx].nodeID = node.id
        activeJobs[jobIdx].status = .submitted

        do {
            let result = try await executeJob(request: request, on: node)

            activeJobs[jobIdx].result      = result
            activeJobs[jobIdx].status      = .done
            activeJobs[jobIdx].completedAt = Date()

            updateNodeStats(nodeID: node.id, success: true)
            moveToCompleted(jobIdx: jobIdx)

            return result

        } catch {
            activeJobs[jobIdx].errorMsg = error.localizedDescription
            activeJobs[jobIdx].status   = .failed
            updateNodeStats(nodeID: node.id, success: false)

            if config.retryOnFailure && activeJobs[jobIdx].retries < 2 {
                activeJobs[jobIdx].retries += 1
                activeJobs[jobIdx].status   = .routing
                return try await submitJob(request: request, priority: priority)
            }

            throw error
        }
    }

    // MARK: - Node Selection

    private func selectNode(for request: SDRequest) -> ComputeNode? {
        let availableNodes = config.nodes.filter { $0.isAvailable }
        guard !availableNodes.isEmpty else { return nil }

        switch config.strategy {
        case .roundRobin:
            let idx  = currentNodeIndex % availableNodes.count
            currentNodeIndex += 1
            return availableNodes[idx]

        case .leastLoaded:
            return availableNodes.min { $0.loadScore < $1.loadScore }

        case .fastestFirst:
            return availableNodes.filter { $0.status == .online }
                .min { $0.responseTimeMs < $1.responseTimeMs }
                ?? availableNodes.first

        case .localFirst:
            return availableNodes.first { $0.type == .local }
                ?? availableNodes.first

        case .cloudFirst:
            return availableNodes.first { $0.type != .local }
                ?? availableNodes.first { $0.type == .local }
        }
    }

    // MARK: - Execute on Node

    private func executeJob(request: SDRequest, on node: ComputeNode) async throws -> NSImage? {
        let encoder = JSONEncoder()
        let bodyData = try encoder.encode(request)

        guard let url = URL(string: "\(node.baseURL)/sdapi/v1/txt2img") else {
            throw SchedulerError.invalidNodeURL(node.baseURL)
        }

        var req = URLRequest(url: url)
        req.httpMethod  = "POST"
        req.httpBody    = bodyData
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 300

        if !node.apiKey.isEmpty {
            req.setValue("Bearer \(node.apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: req)

        guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else {
            throw SchedulerError.nodeError("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }

        guard let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let images   = json["images"] as? [String],
              let firstB64 = images.first,
              let imgData  = Data(base64Encoded: firstB64),
              let image    = NSImage(data: imgData)
        else {
            throw SchedulerError.invalidResponse
        }

        return image
    }

    // MARK: - Health Check

    func startHealthCheck() {
        healthCheckTask?.cancel()
        healthCheckTask = Task {
            while !Task.isCancelled {
                await pingAllNodes()
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
    }

    func pingAllNodes() async {
        isHealthChecking = true
        defer { isHealthChecking = false }

        for i in config.nodes.indices {
            let node = config.nodes[i]
            let (status, latency) = await pingNode(node)
            config.nodes[i].status         = status
            config.nodes[i].responseTimeMs = latency
            config.nodes[i].lastSeen       = status == .online ? Date() : config.nodes[i].lastSeen
        }

        updateClusterStats()
    }

    private func pingNode(_ node: ComputeNode) async -> (ComputeNode.NodeStatus, Double) {
        guard let url = URL(string: "\(node.baseURL)/sdapi/v1/progress") else {
            return (.error, 0)
        }

        let start = Date()

        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 5

            let (data, response) = try await URLSession.shared.data(for: req)
            let latency = Date().timeIntervalSince(start) * 1000

            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                return (.offline, 0)
            }

            if let json     = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let progress = json["progress"] as? Double,
               progress > 0 {
                return (.busy, latency)
            }

            return (.online, latency)

        } catch {
            return (.offline, 0)
        }
    }

    // MARK: - Stats

    private func updateClusterStats() {
        let online = config.nodes.filter { $0.status == .online || $0.status == .busy }
        let totalVRAM = online.reduce(0) { $0 + $1.maxVRAM }
        let avgLatency = online.isEmpty ? 0 : online.map { $0.responseTimeMs }.reduce(0, +) / Double(online.count)

        clusterStats = ClusterStats(
            totalNodes:   config.nodes.count,
            onlineNodes:  online.count,
            totalVRAM:    totalVRAM,
            activeJobs:   activeJobs.count,
            jobsPerHour:  computeJobsPerHour(),
            avgLatencyMs: avgLatency,
            totalCost:    0
        )
    }

    private func computeJobsPerHour() -> Double {
        let cutoff = Date().addingTimeInterval(-3600)
        let recentJobs = completedJobs.filter { ($0.completedAt ?? .distantPast) > cutoff }
        return Double(recentJobs.count)
    }

    private func updateNodeStats(nodeID: String, success: Bool) {
        if let idx = config.nodes.firstIndex(where: { $0.id == nodeID }) {
            config.nodes[idx].totalJobsDone += 1
            let totalDone = Double(config.nodes[idx].totalJobsDone)
            let prevRate  = config.nodes[idx].successRate
            config.nodes[idx].successRate = (prevRate * (totalDone - 1) + (success ? 1 : 0)) / totalDone
        }
    }

    private func moveToCompleted(jobIdx: Int) {
        let job = activeJobs[jobIdx]
        completedJobs.append(job)
        activeJobs.remove(at: jobIdx)
        if completedJobs.count > 1000 { completedJobs.removeFirst(200) }
    }

    // MARK: - Node Management

    func addNode(_ node: ComputeNode) {
        config.nodes.append(node)
        saveConfig()
    }

    func removeNode(id: String) {
        config.nodes.removeAll { $0.id == id }
        saveConfig()
    }

    func updateNode(_ node: ComputeNode) {
        if let idx = config.nodes.firstIndex(where: { $0.id == node.id }) {
            config.nodes[idx] = node
            saveConfig()
        }
    }

    // MARK: - Default Local Nodes

    func scanLocalPorts() async {
        let portsToScan = [7860, 7861, 7862, 7863, 7864]
        for port in portsToScan {
            let url = "http://localhost:\(port)"
            let (status, latency) = await pingNode(ComputeNode(
                name:       "Local :\(port)",
                baseURL:    url,
                type:       .local,
                priority:   10,
                maxVRAM:    8
            ))

            if status == .online || status == .busy {
                let node = ComputeNode(
                    name:           "Local GPU :\(port)",
                    baseURL:        url,
                    type:           .local,
                    priority:       10 - (port - 7860),
                    maxVRAM:        8,
                    status:         status,
                    responseTimeMs: latency
                )

                if !config.nodes.contains(where: { $0.baseURL == url }) {
                    config.nodes.append(node)
                }
            }
        }
        saveConfig()
    }

    // MARK: - Persistence

    private func loadConfig() {
        if let data = UserDefaults.standard.data(forKey: "CloudSchedulerConfig"),
           let cfg  = try? JSONDecoder().decode(SchedulerConfig.self, from: data) {
            config = cfg
        }
    }

    func saveConfig() {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: "CloudSchedulerConfig")
        }
    }

    // MARK: - Errors

    enum SchedulerError: LocalizedError {
        case schedulerDisabled
        case noAvailableNode
        case invalidNodeURL(String)
        case nodeError(String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .schedulerDisabled:        return "El scheduler distribuido no está habilitado."
            case .noAvailableNode:          return "No hay nodos disponibles para procesar el job."
            case .invalidNodeURL(let url):  return "URL de nodo inválida: \(url)"
            case .nodeError(let msg):       return "Error en nodo: \(msg)"
            case .invalidResponse:          return "Respuesta inválida del nodo remoto."
            }
        }
    }
}

