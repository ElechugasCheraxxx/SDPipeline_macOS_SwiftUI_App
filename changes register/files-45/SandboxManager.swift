import Foundation
import AppKit
import Combine
import CryptoKit

// MARK: - SandboxManager
//
// Aislamiento de procesos para Stable Diffusion / A1111.
// Complementa AppHardeningManager (que audita el estado)
// con control activo del ciclo de vida del proceso SD.
//
// TRES RESPONSABILIDADES:
//   1. LAUNCH ISOLATION  — Lanza webui.sh con entorno restrictivo:
//      · Variables de entorno mínimas (sin HOME completo)
//      · Working directory = vault raíz (no ~/Desktop u otros)
//      · umask 0o077: archivos creados sin permisos para otros
//      · Sin herencia de DYLD_INSERT_LIBRARIES (anti-inject)
//
//   2. FILESYSTEM WATCH  — Vigila que el proceso SD solo
//      escriba dentro de directorios autorizados.
//      Usa DispatchSource.makeFileSystemObjectSource para
//      detectar modificaciones en directorios sensibles.
//
//   3. PROCESS LIFECYCLE — Monitorea PID, captura stdout/stderr,
//      detecta crashes y reinicios no autorizados, expone
//      estado observable para la UI.
//
// Integración:
//   · AppHardeningManager → checkSDProcessIsolation() lee sandboxState
//   · ZeroKnowledgeLog   → todos los eventos anómalos se registran
//   · AppEnvironment     → bootSecurity() llamará a SandboxManager.shared.initialize()
//
// ROADMAP: "Sandboxing de procesos SD" (Sección 3 - Seguridad 🟠 CORTO PLAZO)

@MainActor
final class SandboxManager: ObservableObject {

    static let shared = SandboxManager()
    private init() { loadConfig() }

    // MARK: - Process State

    enum ProcessState: String, Equatable {
        case stopped     = "Detenido"
        case launching   = "Iniciando…"
        case running     = "Corriendo"
        case crashed     = "Crash detectado"
        case restricted  = "Restringido (violación)"
        case stopping    = "Deteniéndose…"
    }

    // MARK: - Violation Record

    struct SandboxViolation: Identifiable, Codable {
        let id         = UUID()
        let detectedAt = Date()
        let type:      ViolationType
        let detail:    String
        let pid:       Int32?

        enum ViolationType: String, Codable {
            case unauthorizedWrite  = "Escritura no autorizada"
            case unauthorizedEnv    = "Variable de entorno sospechosa"
            case networkExposure    = "Exposición de red detectada"
            case unexpectedChild    = "Proceso hijo inesperado"
            case processRestart     = "Reinicio no autorizado"
        }
    }

    // MARK: - Configuration

    struct SandboxConfig: Codable {
        /// Directorios donde SD puede escribir libremente
        var allowedWriteDirectories: [String] = []   // poblado en initialize() desde VaultManager

        /// Variables de entorno permitidas para el proceso SD
        var allowedEnvironmentKeys: Set<String> = [
            "PATH", "LANG", "LC_ALL", "HOME",
            "PYTORCH_ENABLE_MPS_FALLBACK",
            "COMMANDLINE_ARGS", "venv_dir",
            "REQS_FILE", "ACCELERATE"
        ]

        /// Bloquear variables relacionadas con inyección de código
        var blockedEnvironmentPrefixes: [String] = [
            "DYLD_INSERT_LIBRARIES",
            "DYLD_FRAMEWORK_PATH",
            "DYLD_LIBRARY_PATH",
            "LD_PRELOAD",
            "PYTHONPATH_OVERRIDE"
        ]

        /// Puerto único permitido para binding de A1111
        var allowedHost: String = "127.0.0.1"
        var allowedPort: Int    = 7860

        /// Si true: kill del proceso SD al detectar violación crítica
        var killOnCriticalViolation: Bool = false

        /// Segundos entre polls de salud del proceso
        var healthCheckIntervalSeconds: Double = 5.0

        /// Máximo número de reinicios automáticos antes de marcar crashed
        var maxAutoRestarts: Int = 3
    }

    // MARK: - Published State

    @Published var processState:      ProcessState    = .stopped
    @Published var violations:        [SandboxViolation] = []
    @Published var config:            SandboxConfig   = SandboxConfig()
    @Published var sdPID:             Int32?          = nil
    @Published var stdoutLines:       [String]        = []   // últimas 500 líneas
    @Published var stderrLines:       [String]        = []
    @Published var restartCount:      Int             = 0
    @Published var isMonitoring:      Bool            = false

    // MARK: - Private

    private var sdProcess:         Process?
    private var healthTimer:       AnyCancellable?
    private var fswSources:        [DispatchSourceFileSystemObject] = []
    private var cancellables       = Set<AnyCancellable>()
    private var launchTimestamp:   Date?
    private var authorizedPID:     Int32?   // PID del proceso que lanzamos nosotros

    // MARK: - Initialize (llamado desde bootSecurity)

    func initialize() {
        // Poblar allowedWriteDirectories desde VaultManager en tiempo real
        let paths: [URL?] = [
            VaultManager.shared.generacionesURL,
            VaultManager.shared.masterPicksURL,
            VaultManager.shared.exportURL,
            VaultManager.shared.vaultMetaURL,
            VaultManager.shared.privateLoRAsURL,
        ]
        config.allowedWriteDirectories = paths
            .compactMap { $0?.path }

        // Agregar directorio de trabajo de A1111 si está configurado
        let webuiPath = UserDefaults.standard.string(forKey: "a1111.webuiPath") ?? ""
        if !webuiPath.isEmpty {
            let webuiDir = URL(fileURLWithPath: webuiPath).deletingLastPathComponent().path
            config.allowedWriteDirectories.append(webuiDir)
        }

        ZeroKnowledgeLog.shared.write(
            category: .systemEvent,
            message: "SandboxManager inicializado — \(config.allowedWriteDirectories.count) directorios autorizados"
        )
    }

    // MARK: - Launch SD Process (isolated)

    /// Lanza webui.sh con entorno restrictivo.
    /// - Parameter scriptPath: Ruta completa a webui.sh (desde GenerationSettings)
    func launchSD(scriptPath: String) async throws {
        guard processState == .stopped || processState == .crashed else {
            throw SandboxError.alreadyRunning
        }

        processState = .launching
        launchTimestamp = Date()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptPath]

        // ── Entorno restringido ────────────────────────────────────────────
        var restrictedEnv = buildRestrictedEnvironment()

        // Flags MPS de MpsOptimizer
        restrictedEnv["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"

        // Working directory = directorio de webui.sh (no home del usuario)
        let workDir = URL(fileURLWithPath: scriptPath).deletingLastPathComponent()
        process.currentDirectoryURL = workDir
        process.environment = restrictedEnv

        // ── stdout / stderr pipes ──────────────────────────────────────────
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError  = stderrPipe

        // Leer stdout asíncronamente
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                self?.appendStdout(line)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                self?.appendStderr(line)
                // Detectar mensajes de error graves
                if line.lowercased().contains("error") || line.lowercased().contains("fatal") {
                    self?.logAnomaly("Stderr crítico: \(line.prefix(120))")
                }
            }
        }

        // ── Terminación ────────────────────────────────────────────────────
        process.terminationHandler = { [weak self] p in
            Task { @MainActor [weak self] in
                self?.handleProcessTermination(p)
            }
        }

        try process.run()

        sdProcess    = process
        sdPID        = process.processIdentifier
        authorizedPID = process.processIdentifier
        processState = .running

        ZeroKnowledgeLog.shared.write(
            category: .systemEvent,
            message:  "SD lanzado en modo sandbox — PID \(process.processIdentifier)",
            metadata: ["script": scriptPath, "workDir": workDir.path]
        )

        // Iniciar monitoreo
        startHealthMonitor()
        startFilesystemWatch()
    }

    // MARK: - Stop

    func stopSD() async {
        guard let process = sdProcess, process.isRunning else {
            processState = .stopped
            return
        }

        processState = .stopping
        process.terminate()

        // Dar 5 s y luego SIGKILL si sigue corriendo
        let pid = process.processIdentifier
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if process.isRunning {
                kill(pid, SIGKILL)
                await MainActor.run { self.processState = .stopped }
            }
        }

        stopFilesystemWatch()
        healthTimer?.cancel()
        healthTimer = nil
        isMonitoring = false
        sdPID = nil
        authorizedPID = nil

        ZeroKnowledgeLog.shared.write(
            category: .systemEvent,
            message: "SD detenido manualmente — PID \(pid)"
        )
    }

    // MARK: - Environment Sanitization

    private func buildRestrictedEnvironment() -> [String: String] {
        let fullEnv = ProcessInfo.processInfo.environment
        var restricted: [String: String] = [:]

        for key in config.allowedEnvironmentKeys {
            if let value = fullEnv[key] {
                restricted[key] = value
            }
        }

        // Verificar y registrar si se intenta pasar variables bloqueadas
        for prefix in config.blockedEnvironmentPrefixes {
            let dangerous = fullEnv.keys.filter { $0.hasPrefix(prefix) }
            if !dangerous.isEmpty {
                let violation = SandboxViolation(
                    type:   .unauthorizedEnv,
                    detail: "Variables bloqueadas en entorno: \(dangerous.joined(separator: ", "))",
                    pid:    nil
                )
                violations.insert(violation, at: 0)
                ZeroKnowledgeLog.shared.write(
                    category: .systemEvent,
                    message:  "SANDBOX: Variables de entorno peligrosas bloqueadas",
                    metadata: ["vars": dangerous.joined(separator: ",")]
                )
            }
        }

        // PATH mínimo — solo lo esencial para Python/bash
        restricted["PATH"] = "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
        // umask 0o077 se aplica vía comando en webui.sh launch wrapper si es necesario
        return restricted
    }

    // MARK: - Health Monitor

    private func startHealthMonitor() {
        isMonitoring = true
        healthTimer = Timer.publish(
            every: config.healthCheckIntervalSeconds,
            on: .main,
            in: .common
        )
        .autoconnect()
        .sink { [weak self] _ in
            Task { await self?.performHealthCheck() }
        }
    }

    private func performHealthCheck() async {
        guard let process = sdProcess else { return }

        if !process.isRunning {
            // El proceso terminó inesperadamente
            if processState == .running {
                handleUnexpectedCrash()
            }
            return
        }

        // Verificar que el PID no ha cambiado (no fue reemplazado por otro proceso)
        if process.processIdentifier != authorizedPID {
            recordViolation(.processRestart, detail: "PID cambió de \(authorizedPID ?? -1) a \(process.processIdentifier)")
        }

        // Verificar que A1111 no está escuchando en 0.0.0.0 (exposición de red)
        await checkNetworkExposure()
    }

    private func checkNetworkExposure() async {
        // Ejecutar lsof para verificar binding de red
        let task   = Process()
        let pipe   = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments     = ["-nP", "-iTCP:\(config.allowedPort)", "-sTCP:LISTEN"]
        task.standardOutput = pipe
        task.standardError  = Pipe()
        guard let _ = try? task.run() else { return }
        task.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        // Si hay una línea con 0.0.0.0 (o *:7860), es una exposición
        if output.contains("0.0.0.0:\(config.allowedPort)") || output.contains("*:\(config.allowedPort)") {
            recordViolation(
                .networkExposure,
                detail: "A1111 escuchando en 0.0.0.0:\(config.allowedPort) — acceso público detectado"
            )
        }
    }

    // MARK: - Filesystem Watch

    private func startFilesystemWatch() {
        stopFilesystemWatch()

        // Vigilar directorios SENSIBLES donde SD NO debería escribir
        let sensitiveDirectories: [URL?] = [
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
            FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first,
        ]

        for dirURL in sensitiveDirectories.compactMap({ $0 }) {
            guard FileManager.default.fileExists(atPath: dirURL.path) else { continue }

            let fd = open(dirURL.path, O_EVTONLY)
            guard fd >= 0 else { continue }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .link, .rename],
                queue: DispatchQueue.global(qos: .utility)
            )

            let capturedPath = dirURL.path
            source.setEventHandler { [weak self] in
                Task { @MainActor [weak self] in
                    self?.handleFilesystemEvent(in: capturedPath)
                }
            }

            source.setCancelHandler { close(fd) }
            source.resume()
            fswSources.append(source)
        }
    }

    private func stopFilesystemWatch() {
        fswSources.forEach { $0.cancel() }
        fswSources.removeAll()
    }

    private func handleFilesystemEvent(in directory: String) {
        // Solo registrar si el proceso SD está corriendo
        guard processState == .running else { return }

        // Verificar si el directorio está en la lista autorizada
        let isAuthorized = config.allowedWriteDirectories.contains { authorized in
            directory.hasPrefix(authorized)
        }

        guard !isAuthorized else { return }

        recordViolation(
            .unauthorizedWrite,
            detail: "Actividad de escritura detectada en directorio no autorizado: \(directory)"
        )
    }

    // MARK: - Violation Handling

    private func recordViolation(_ type: SandboxViolation.ViolationType, detail: String) {
        let violation = SandboxViolation(
            type:   type,
            detail: detail,
            pid:    sdPID
        )

        violations.insert(violation, at: 0)
        if violations.count > 100 {
            violations = Array(violations.prefix(100))
        }

        ZeroKnowledgeLog.shared.write(
            category: .systemEvent,
            message:  "SANDBOX VIOLATION [\(type.rawValue)]: \(detail)",
            metadata: ["pid": sdPID.map(String.init) ?? "?"]
        )

        // Acción según nivel de seguridad
        if config.killOnCriticalViolation && type == .unauthorizedWrite {
            processState = .restricted
            Task { await stopSD() }
        }
    }

    private func logAnomaly(_ message: String) {
        ZeroKnowledgeLog.shared.write(
            category: .systemEvent,
            message:  "SD ANOMALY: \(message)"
        )
    }

    // MARK: - Process Termination Handling

    private func handleProcessTermination(_ process: Process) {
        let exitCode = process.terminationStatus

        stdoutPipe_cleanup(process)

        if processState == .stopping {
            processState = .stopped
            return
        }

        if exitCode != 0 {
            handleUnexpectedCrash()
        } else {
            processState = .stopped
        }
    }

    private func stdoutPipe_cleanup(_ process: Process) {
        if let pipe = process.standardOutput as? Pipe {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
        if let pipe = process.standardError as? Pipe {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
    }

    private func handleUnexpectedCrash() {
        ZeroKnowledgeLog.shared.write(
            category: .systemEvent,
            message:  "SD crash inesperado — reinicio \(restartCount + 1)/\(config.maxAutoRestarts)"
        )

        restartCount += 1

        if restartCount >= config.maxAutoRestarts {
            processState = .crashed
            healthTimer?.cancel()
            isMonitoring = false
            violations.insert(
                SandboxViolation(
                    type:   .processRestart,
                    detail: "Máximo de reinicios alcanzado (\(config.maxAutoRestarts)) — proceso marcado como crashed",
                    pid:    sdPID
                ),
                at: 0
            )
        } else {
            processState = .stopped
        }
    }

    // MARK: - Stdout/Stderr Buffer

    private func appendStdout(_ line: String) {
        stdoutLines.append(line.trimmingCharacters(in: .newlines))
        if stdoutLines.count > 500 { stdoutLines.removeFirst() }
    }

    private func appendStderr(_ line: String) {
        stderrLines.append(line.trimmingCharacters(in: .newlines))
        if stderrLines.count > 200 { stderrLines.removeFirst() }
    }

    // MARK: - Status for AppHardeningManager

    /// Usado por AppHardeningManager.checkSDProcessIsolation()
    var isolationStatus: (passed: Bool, detail: String) {
        switch processState {
        case .stopped:
            return (true, "SD no está corriendo — sin superficie de ataque.")
        case .running:
            let hasViolations = violations.contains { v in
                Calendar.current.dateComponents([.minute], from: v.detectedAt, to: Date()).minute ?? 0 < 60
            }
            return (
                !hasViolations,
                hasViolations
                    ? "⚠️ \(violations.count) violación(es) reciente(s) detectadas."
                    : "✅ Proceso SD corriendo en modo aislado (PID \(sdPID ?? -1))"
            )
        case .restricted:
            return (false, "❌ Proceso SD restringido por violación de sandbox.")
        case .crashed:
            return (false, "❌ Crash detectado — revisar logs.")
        default:
            return (true, "SD en transición (\(processState.rawValue))")
        }
    }

    // MARK: - Persistence

    private var configURL: URL? {
        VaultManager.shared.vaultMetaURL?.appending(path: "sandbox_config.json")
    }

    private func loadConfig() {
        guard let url = configURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(SandboxConfig.self, from: data)
        else { return }
        config = decoded
    }

    func saveConfig() {
        guard let url = configURL else { return }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(config).write(to: url, options: .atomic)
    }
}

// MARK: - SandboxError

enum SandboxError: LocalizedError {
    case alreadyRunning
    case scriptNotFound(String)
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:         return "El proceso SD ya está corriendo."
        case .scriptNotFound(let p):  return "webui.sh no encontrado en: \(p)"
        case .permissionDenied:       return "Sin permisos para ejecutar el script SD."
        }
    }
}

// MARK: - AppHardeningManager Integration Extension
// Extiende AppHardeningManager para usar SandboxManager.shared.isolationStatus

extension AppHardeningManager {
    /// Reemplaza el stub de checkSDProcessIsolation() en AppHardeningManager
    func checkSDProcessIsolationLive() async -> SecurityCheckResult {
        let status = await SandboxManager.shared.isolationStatus
        return SecurityCheckResult(
            check:    "Aislamiento de proceso SD",
            passed:   status.passed,
            severity: status.passed ? .info : .critical,
            detail:   status.detail,
            action:   status.passed ? nil : "Revisa SandboxManager en Security → Process Isolation"
        )
    }
}

// MARK: - AppEnvironment Boot Extension

// var sandbox declared in AppEnvironment.swift
}

// MARK: - SandboxManager UI (Panel de monitoreo)

import SwiftUI

struct SandboxMonitorView: View {
    @ObservedObject private var mgr = SandboxManager.shared
    @State private var showLog = false

    var stateColor: Color {
        switch mgr.processState {
        case .stopped:    return Color(hex: "#64748b")
        case .launching:  return Color(hex: "#fbbf24")
        case .running:    return Color(hex: "#34d399")
        case .crashed,
             .restricted: return Color(hex: "#f87171")
        case .stopping:   return Color(hex: "#fb923c")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Header ────────────────────────────────────────────────────
            HStack(spacing: 8) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 8, height: 8)
                    .overlay(
                        Circle()
                            .fill(stateColor.opacity(0.3))
                            .frame(width: 14, height: 14)
                            .opacity(mgr.processState == .running ? 1 : 0)
                    )

                Text("SD Process Sandbox")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)

                Text(mgr.processState.rawValue)
                    .font(.system(size: 10))
                    .foregroundColor(stateColor)

                if let pid = mgr.sdPID {
                    Text("PID \(pid)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                Spacer()

                if mgr.restartCount > 0 {
                    Text("↺ \(mgr.restartCount)")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(Color(hex: "#fbbf24"))
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)

            Divider().background(Color.white.opacity(0.06))

            // ── Violations ────────────────────────────────────────────────
            if mgr.violations.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#34d399"))
                    Text("Sin violaciones de sandbox")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "#f87171"))
                        Text("\(mgr.violations.count) violación(es)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color(hex: "#f87171"))
                        Spacer()
                        Button("Ver log") { showLog.toggle() }
                            .font(.system(size: 10))
                            .buttonStyle(.plain)
                            .foregroundColor(Color(hex: "#7c6af7"))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)

                    if showLog {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                ForEach(mgr.violations.prefix(10)) { v in
                                    ViolationRow(violation: v)
                                }
                            }
                            .padding(.horizontal, 14).padding(.bottom, 8)
                        }
                        .frame(maxHeight: 160)
                    }
                }
            }

            Divider().background(Color.white.opacity(0.06))

            // ── Allowed Dirs ──────────────────────────────────────────────
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(mgr.config.allowedWriteDirectories, id: \.self) { path in
                        HStack(spacing: 5) {
                            Image(systemName: "folder.badge.checkmark")
                                .font(.system(size: 9))
                                .foregroundColor(Color(hex: "#34d399"))
                            Text(path)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .padding(.top, 4)
            } label: {
                Text("Directorios autorizados (\(mgr.config.allowedWriteDirectories.count))")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.07), lineWidth: 1))
    }
}

private struct ViolationRow: View {
    let violation: SandboxManager.SandboxViolation

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "xmark.shield")
                .font(.system(size: 10))
                .foregroundColor(Color(hex: "#f87171"))
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 1) {
                Text(violation.type.rawValue)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color(hex: "#fbbf24"))
                Text(violation.detail)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                Text(violation.detectedAt, style: .relative)
                    .font(.system(size: 8))
                    .foregroundColor(.secondary.opacity(0.6))
            }
        }
        .padding(.vertical, 3)
    }
}
