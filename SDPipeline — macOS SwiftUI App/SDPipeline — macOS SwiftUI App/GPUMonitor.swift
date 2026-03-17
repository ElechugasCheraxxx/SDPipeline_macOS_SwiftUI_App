import Foundation
import AppKit
import SwiftUI
import Combine

// MARK: - GPUMonitor
//
// Monitorea VRAM / RAM disponible antes y durante la generación.
// Apple Silicon: memoria unificada — VRAM = RAM del sistema.
// NVIDIA/AMD:    lee /sdapi/v1/memory de A1111 para stats de CUDA.
//
// Responsabilidades:
//   1. Detectar arquitectura (MPS / CUDA)
//   2. Polling cada N segundos del endpoint de memoria de A1111
//   3. Pre-check antes de generar: advertir si hay poco espacio
//   4. Exponer flags MPS recomendados para webui.sh
//   5. View compacta para la barra de estado + panel expandido para Settings

@MainActor
final class GPUMonitor: ObservableObject {

    static let shared = GPUMonitor()
    private init() { detectDevice() }

    // MARK: - Published State

    @Published var deviceName:      String = "Detecting…"
    @Published var isAppleSilicon:  Bool   = false
    @Published var isMPS:           Bool   = false

    // Memoria (bytes) — VRAM para NVIDIA, RAM unificada para Apple Silicon
    @Published var vramTotal: Int64 = 0
    @Published var vramUsed:  Int64 = 0
    @Published var vramFree:  Int64 = 0

    // RAM del sistema
    @Published var ramTotal: Int64 = 0
    @Published var ramFree:  Int64 = 0
    @Published var ramUsed:  Int64 = 0

    // Estado del polling
    @Published var sdMemoryRaw:  SDMemoryResponse? = nil
    @Published var pollError:    String?           = nil
    @Published var isPolling:    Bool              = false
    @Published var lastPollDate: Date?             = nil

    // Pre-check antes de generación
    @Published var preCheckStatus: PreCheckStatus = .unknown

    private var pollTask: Task<Void, Never>?
    private var baseURL: String = "http://127.0.0.1:7860"

    /// Número de fallos consecutivos al hacer fetch de /sdapi/v1/memory.
    /// Al llegar a `maxConsecutiveFailures`, el polling se detiene solo para
    /// evitar inundar el log cuando A1111 no está corriendo.
    private var consecutiveFailures: Int = 0
    private let maxConsecutiveFailures: Int = 5

    // MARK: - Types

    struct SDMemoryResponse: Codable {
        let ram:  RAMBlock?
        let cuda: CUDABlock?

        struct RAMBlock: Codable {
            let free:  Int64?
            let used:  Int64?
            let total: Int64?
        }

        struct CUDABlock: Codable {
            let system:   RAMBlock?
            let active:   RAMBlock?
            let reserved: RAMBlock?
        }
    }

    enum PreCheckStatus {
        case unknown
        case ok
        case warning(String)
        case critical(String)

        var color: Color {
            switch self {
            case .ok:       return Color(hex: "#3de3c0")
            case .warning:  return .yellow
            case .critical: return Color(red: 1, green: 0.45, blue: 0.4)
            case .unknown:  return .gray
            }
        }

        var icon: String {
            switch self {
            case .ok:       return "checkmark.circle.fill"
            case .warning:  return "exclamationmark.triangle.fill"
            case .critical: return "xmark.circle.fill"
            case .unknown:  return "questionmark.circle"
            }
        }

        var message: String? {
            switch self {
            case .ok:               return nil
            case .warning(let m):  return m
            case .critical(let m): return m
            case .unknown:         return nil
            }
        }
    }

    // MARK: - Configuration

    func configure(baseURL: String) {
        self.baseURL = baseURL
        refreshSystemMemory()
    }

    // MARK: - Device Detection

    func detectDevice() {
        // Detectar Apple Silicon en tiempo de compilación
        #if arch(arm64)
        isAppleSilicon = true
        isMPS = true
        #else
        isAppleSilicon = false
        isMPS = false
        #endif

        // Nombre del modelo de Mac (ej. "Mac14,3" → MacBook Pro M2)
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        deviceName = String(cString: model)

        // Memoria física total
        ramTotal  = Int64(ProcessInfo.processInfo.physicalMemory)

        if isAppleSilicon {
            // Memoria unificada: VRAM = RAM
            vramTotal = ramTotal
        }

        refreshSystemMemory()
    }

    // MARK: - System Memory (vm_statistics64)
    // Funciona tanto en Apple Silicon como Intel.

    func refreshSystemMemory() {
        var vmStats = vm_statistics64_data_t()
        var count   = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )

        let result = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else { return }

        let pageSize = Int64(vm_kernel_page_size)
        let free     = Int64(vmStats.free_count    + vmStats.inactive_count) * pageSize
        let active   = Int64(vmStats.active_count  + vmStats.wire_count)     * pageSize
        let used     = ramTotal - free

        ramFree = free
        ramUsed = max(used, active)

        if isAppleSilicon {
            vramFree = ramFree
            vramUsed = ramUsed
        }
    }

    // MARK: - A1111 Memory Polling

    /// Iniciar polling automático cada `interval` segundos.
    func startPolling(interval: TimeInterval = 6.0) {
        guard !isPolling else { return }
        isPolling = true
        consecutiveFailures = 0
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.fetchSDMemory()
                self?.refreshSystemMemory()
                // Auto-stop si A1111 no responde tras varios intentos
                if let self, self.consecutiveFailures >= self.maxConsecutiveFailures {
                    await MainActor.run { self.stopPolling() }
                    return
                }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        isPolling = false
        consecutiveFailures = 0
    }

    private func fetchSDMemory() async {
        guard let url = URL(string: "\(baseURL)/sdapi/v1/memory") else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response  = try JSONDecoder().decode(SDMemoryResponse.self, from: data)

            sdMemoryRaw         = response
            pollError           = nil
            lastPollDate        = Date()
            consecutiveFailures = 0   // reset on success

            // Para NVIDIA/AMD usamos stats de CUDA desde A1111
            if !isAppleSilicon, let cuda = response.cuda?.system {
                vramTotal = cuda.total ?? 0
                vramUsed  = cuda.used  ?? 0
                vramFree  = cuda.free  ?? 0
            }

            updatePreCheckStatus()

        } catch {
            consecutiveFailures += 1
            // Solo actualizar el error en UI si aún no se alcanzó el límite
            // (evitar spam de publicaciones cuando SD no está corriendo)
            if consecutiveFailures <= maxConsecutiveFailures {
                pollError = "Sin respuesta de /sdapi/v1/memory"
            }
        }
    }

    // MARK: - Pre-Generation Check

    /// Ejecutar antes de cada generación. Umbral configurable (default 2 GB).
    func runPreCheck(requestedWidth: Int = 512, requestedHeight: Int = 768) {
        refreshSystemMemory()

        // Estimar VRAM necesaria según resolución (heurística)
        let pixels         = requestedWidth * requestedHeight
        let basePixels     = 512 * 512
        let estimatedVRAM  = Int64(2 * 1024 * 1024 * 1024) * Int64(pixels) / Int64(basePixels)
        let available      = isAppleSilicon ? ramFree : vramFree

        if available <= 0 {
            preCheckStatus = .unknown
        } else if available < 512 * 1024 * 1024 { // < 512 MB — crítico
            preCheckStatus = .critical(
                "Memoria crítica: solo \(formatBytes(available)) libres. Riesgo de crash."
            )
        } else if available < estimatedVRAM {
            preCheckStatus = .warning(
                "\(formatBytes(available)) libres · ~\(formatBytes(estimatedVRAM)) estimados para \(requestedWidth)×\(requestedHeight)"
            )
        } else {
            preCheckStatus = .ok
        }
    }

    private func updatePreCheckStatus() {
        let available = isAppleSilicon ? ramFree : vramFree
        guard available > 0 else { return }

        if available < 1 * 1024 * 1024 * 1024 {
            preCheckStatus = .critical("\(formatBytes(available)) libres — peligroso")
        } else if available < 3 * 1024 * 1024 * 1024 {
            preCheckStatus = .warning("\(formatBytes(available)) libres")
        } else {
            preCheckStatus = .ok
        }
    }

    // MARK: - MPS Recommended Flags

    /// Flags de lanzamiento recomendados para webui.sh en Apple Silicon.
    /// Fuente: A1111 wiki + comunidad macOS.
    var recommendedMPSFlags: [(flag: String, reason: String)] {
        guard isAppleSilicon else { return [] }
        return [
            ("--skip-torch-cuda-test",    "Omitir test de CUDA (no disponible en MPS)"),
            ("--no-half-vae",             "Evitar VAE en FP16 — previene artefactos en MPS"),
            ("--upcast-sampling",         "Upcasting de sampling — mejora calidad en M-series"),
            ("--opt-sdp-attention",       "Optimizar atención con scaled dot-product (más rápido en Metal)"),
            ("--use-cpu=interrogate",     "Interrogate en CPU — más estable"),
        ]
    }

    var mpsLaunchArgString: String {
        recommendedMPSFlags.map { $0.flag }.joined(separator: " \\\n    ")
    }

    // MARK: - Computed Display Properties

    var vramUsagePercent: Double {
        guard vramTotal > 0 else { return 0 }
        return min(Double(vramUsed) / Double(vramTotal), 1.0)
    }

    var ramUsagePercent: Double {
        guard ramTotal > 0 else { return 0 }
        return min(Double(ramUsed) / Double(ramTotal), 1.0)
    }

    func formatBytes(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 B" }
        let gb = Double(bytes) / (1024 * 1024 * 1024)
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / (1024 * 1024)
        return String(format: "%.0f MB", mb)
    }

    var summaryLine: String {
        let label = isAppleSilicon ? "RAM" : "VRAM"
        return "\(label) \(formatBytes(vramUsed))/\(formatBytes(vramTotal))"
    }
}

// MARK: - GPUMonitorBar (compact, para barra de estado)

struct GPUMonitorBar: View {
    @ObservedObject var monitor = GPUMonitor.shared

    var body: some View {
        HStack(spacing: 8) {
            // Badge MPS / CUDA
            Text(monitor.isMPS ? "MPS" : "CUDA")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(monitor.isAppleSilicon ? Color(hex: "#7c6af7") : Color(hex: "#3de3c0"))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(
                    (monitor.isAppleSilicon ? Color(hex: "#7c6af7") : Color(hex: "#3de3c0"))
                        .opacity(0.12)
                )
                .cornerRadius(4)

            // Mini progress bar
            VStack(spacing: 2) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.white.opacity(0.08))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(barColor)
                            .frame(width: geo.size.width * monitor.vramUsagePercent)
                            .animation(.easeInOut(duration: 0.4), value: monitor.vramUsagePercent)
                    }
                }
                .frame(width: 64, height: 4)

                Text(monitor.summaryLine)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            // Pre-check dot
            Image(systemName: monitor.preCheckStatus.icon)
                .font(.system(size: 10))
                .foregroundColor(monitor.preCheckStatus.color)
                .help(monitor.preCheckStatus.message ?? "VRAM OK")
        }
    }

    private var barColor: Color {
        let p = monitor.vramUsagePercent
        if p > 0.85 { return Color(red: 1, green: 0.45, blue: 0.4) }
        if p > 0.65 { return .yellow }
        return Color(hex: "#3de3c0")
    }
}

// MARK: - GPUStatusPanel (expandido, para Settings / Center Panel)

struct GPUStatusPanel: View {
    @ObservedObject var monitor = GPUMonitor.shared
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            // Header
            HStack {
                Label(
                    monitor.isAppleSilicon ? "Apple Silicon · MPS" : "GPU · CUDA",
                    systemImage: monitor.isAppleSilicon ? "memorychip" : "cpu"
                )
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)

                Spacer()

                if monitor.isPolling {
                    HStack(spacing: 4) {
                        Circle().fill(Color(hex: "#3de3c0")).frame(width: 5, height: 5)
                        Text("Live").font(.system(size: 9)).foregroundColor(.secondary)
                    }
                }
            }

            Divider().background(Color.white.opacity(0.07))

            // Barra principal VRAM / RAM
            memoryBar(
                label:   monitor.isAppleSilicon ? "RAM Unificada" : "VRAM",
                used:    monitor.vramUsed,
                total:   monitor.vramTotal,
                percent: monitor.vramUsagePercent
            )

            if !monitor.isAppleSilicon {
                memoryBar(
                    label:   "RAM Sistema",
                    used:    monitor.ramUsed,
                    total:   monitor.ramTotal,
                    percent: monitor.ramUsagePercent
                )
            }

            Divider().background(Color.white.opacity(0.07))

            // Modelo
            infoRow("Modelo",       monitor.deviceName)
            infoRow("Aceleración",  monitor.isMPS ? "Metal (MPS)" : "CUDA")

            // Pre-check status
            if let msg = monitor.preCheckStatus.message {
                HStack(spacing: 6) {
                    Image(systemName: monitor.preCheckStatus.icon)
                        .font(.system(size: 10))
                        .foregroundColor(monitor.preCheckStatus.color)
                    Text(msg)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .padding(8)
                .background(monitor.preCheckStatus.color.opacity(0.07))
                .cornerRadius(6)
            }

            // Flags MPS (solo Apple Silicon)
            if monitor.isAppleSilicon && !monitor.recommendedMPSFlags.isEmpty {
                Divider().background(Color.white.opacity(0.07))

                VStack(alignment: .leading, spacing: 6) {
                    Text("Flags recomendados para webui.sh")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)

                    // Lista de flags con descripción
                    ForEach(monitor.recommendedMPSFlags, id: \.flag) { item in
                        HStack(alignment: .top, spacing: 6) {
                            Text(item.flag)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(Color(hex: "#7c6af7"))
                            Text("·")
                                .foregroundColor(.secondary)
                                .font(.system(size: 10))
                            Text(item.reason)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }

                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(monitor.mpsLaunchArgString, forType: .string)
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            copied = false
                        }
                    }) {
                        Label(
                            copied ? "¡Copiado!" : "Copiar todos los flags",
                            systemImage: copied ? "checkmark" : "doc.on.doc"
                        )
                        .font(.system(size: 11))
                        .foregroundColor(copied ? Color(hex: "#3de3c0") : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Error de polling
            if let err = monitor.pollError {
                HStack(spacing: 5) {
                    Image(systemName: "wifi.slash").font(.system(size: 10))
                    Text(err).font(.system(size: 10))
                }
                .foregroundColor(.secondary.opacity(0.6))
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.035))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.07), lineWidth: 1))
    }

    // MARK: - Sub-views

    func memoryBar(label: String, used: Int64, total: Int64, percent: Double) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.8))
                Spacer()
                Text("\(monitor.formatBytes(used)) / \(monitor.formatBytes(total))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.07))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(barGradient(percent: percent))
                        .frame(width: geo.size.width * min(percent, 1.0))
                        .animation(.easeInOut(duration: 0.5), value: percent)
                }
            }
            .frame(height: 5)
        }
    }

    func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 10)).foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white.opacity(0.7))
                .lineLimit(1)
        }
    }

    func barGradient(percent: Double) -> LinearGradient {
        let colors: [Color] = percent > 0.85
            ? [Color(red: 1, green: 0.45, blue: 0.4), .red]
            : percent > 0.65
                ? [.yellow, Color(red: 1, green: 0.7, blue: 0.2)]
                : [Color(hex: "#7c6af7"), Color(hex: "#3de3c0")]
        return LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }
}
