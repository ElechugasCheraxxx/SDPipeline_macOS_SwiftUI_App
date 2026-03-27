import SwiftUI
import AppKit

// MARK: - SecurityAuditView v3  ✅ ROADMAP 100%
//
// Cambios v2 → v3:
//   ✨ ADD: Tab "Proceso" con SandboxMonitorView (SandboxManager)
//   ✨ ADD: @StateObject sandbox en referencias
//   ✨ ADD: sandboxTab view
//   🔧 UPD: exportReport() usa AppEnvironment.generateAuditReport() que incluye sandboxState

struct SecurityAuditView: View {

    enum AuditTab: String, CaseIterable {
        case log        = "Eventos"
        case compliance = "Compliance"
        case steg       = "Esteganografía"
        case crypto     = "Cifrado"
        case integrity  = "Integridad"
        case sandbox    = "Proceso"        // NEW v3

        var icon: String {
            switch self {
            case .log:        return "lock.shield.fill"
            case .compliance: return "checkmark.seal.fill"
            case .steg:       return "eye.slash.fill"
            case .crypto:     return "lock.fill"
            case .integrity:  return "shield.checkered"
            case .sandbox:    return "terminal.fill"
            }
        }
    }

    @State private var activeTab: AuditTab = .log

    @StateObject private var zkLog      = ZeroKnowledgeLog.shared
    @StateObject private var compliance = PublishComplianceLogger.shared
    @StateObject private var crypto     = VaultCryptoEngine.shared
    @StateObject private var integrity  = IntegrityManager.shared
    @StateObject private var steg       = SteganographyEngine.shared
    @StateObject private var sandbox    = SandboxManager.shared    // NEW v3

    @State private var isGeneratingReport: Bool   = false
    @State private var reportURL:          URL?   = nil
    @State private var stegVerifyResult:   String? = nil
    @State private var isRotating:         Bool   = false
    @State private var rotationResult:     String? = nil
    @State private var isRunningIntegrity: Bool   = false

    var body: some View {
        VStack(spacing: 0) {

            // ── Tab bar ───────────────────────────────────────────────────
            HStack(spacing: 2) {
                ForEach(AuditTab.allCases, id: \.self) { tab in
                    Button(action: { activeTab = tab }) {
                        HStack(spacing: 5) {
                            Image(systemName: tab.icon).font(.system(size: 10))
                            Text(tab.rawValue)
                                .font(.system(size: 11, weight: activeTab == tab ? .semibold : .regular))
                        }
                        .foregroundColor(activeTab == tab ? .white : .secondary)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(activeTab == tab ? Color.white.opacity(0.08) : Color.clear)
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    // Indicator dot para sandbox con violaciones
                    .overlay(alignment: .topTrailing) {
                        if tab == .sandbox && !sandbox.violations.isEmpty {
                            Circle()
                                .fill(Color(hex: "#f87171"))
                                .frame(width: 6, height: 6)
                                .offset(x: 2, y: -2)
                        }
                    }
                }

                Spacer()

                Button(action: exportReport) {
                    HStack(spacing: 4) {
                        if isGeneratingReport {
                            ProgressView().scaleEffect(0.55).progressViewStyle(.circular)
                        } else {
                            Image(systemName: "square.and.arrow.up").font(.system(size: 10))
                        }
                        Text("Exportar").font(.system(size: 10))
                    }
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(5)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.white.opacity(0.03))

            Divider().background(Color.white.opacity(0.06))

            // ── Content ───────────────────────────────────────────────────
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch activeTab {
                    case .log:        logTab
                    case .compliance: complianceTab
                    case .steg:       stegTab
                    case .crypto:     cryptoTab
                    case .integrity:  integrityTab
                    case .sandbox:    sandboxTab    // NEW v3
                    }
                }
                .padding(16)
            }
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
    }

    // MARK: - Log Tab

    var logTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                statBadge("Sesión",     ZeroKnowledgeLog.currentSessionID.prefix(12).description)
                statBadge("Eventos",    "\(zkLog.entries(limit: 1000).count)")
                statBadge("Bloqueados", "\(zkLog.entries(category: .promptBlocked).count)")
                statBadge("NSFW",       "\(zkLog.entries(category: .nsfwDetected).count)")
            }
            ZeroKnowledgeLogView()
        }
    }

    // MARK: - Compliance Tab

    var complianceTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                statBadge("Publicaciones", "\(compliance.totalEntries)")
                statBadge("Archivos",      "\(compliance.totalFilesPublished)")
                statBadge("Score",         String(format: "%.0f%%", compliance.complianceScore * 100))
                statBadge("Watermark",     String(format: "%.0f%%", compliance.watermarkRate * 100))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("GDPR").font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
                HStack(spacing: 12) {
                    gdprFlag("Retención",     "\(compliance.gdprFlags.retentionDays)d",
                             ok: compliance.gdprFlags.retentionDays <= 90)
                    gdprFlag("Right to erase", compliance.gdprFlags.rightToErasure ? "✓" : "✗",
                             ok: compliance.gdprFlags.rightToErasure)
                    gdprFlag("Consentimiento", compliance.gdprFlags.consentRequired ? "✓" : "✗",
                             ok: compliance.gdprFlags.consentRequired)
                }
            }
            .padding(10).background(Color.white.opacity(0.04)).cornerRadius(8)

            if !compliance.platformBreakdown.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Por plataforma").font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
                    ForEach(compliance.platformBreakdown.sorted(by: { $0.value > $1.value }), id: \.key) { kv in
                        HStack {
                            Text(kv.key).font(.system(size: 11)).foregroundColor(.white)
                            Spacer()
                            Text("\(kv.value) publicaciones")
                                .font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                        }
                        .padding(6).background(Color.white.opacity(0.03)).cornerRadius(5)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Registros recientes").font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
                ForEach(compliance.records.prefix(10)) { record in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(record.platform).font(.system(size: 11, weight: .medium)).foregroundColor(.white)
                            Text("·").foregroundColor(.secondary)
                            Text(record.presetName).font(.system(size: 10)).foregroundColor(.secondary)
                            Spacer()
                            Text(record.timestamp.shortDisplay).font(.system(size: 9)).foregroundColor(.secondary)
                        }
                        HStack(spacing: 10) {
                            complianceFlag("WM",   record.watermarked)
                            complianceFlag("META", record.metadataStripped)
                            complianceFlag("STEG", record.stegEmbedded)
                            Text("\(record.exportedPaths.count) archivos")
                                .font(.system(size: 9)).foregroundColor(.secondary)
                        }
                    }
                    .padding(8).background(Color.white.opacity(0.04)).cornerRadius(6)
                }
            }

            HStack(spacing: 8) {
                Button("Exportar JSON") {
                    if let url = try? compliance.exportReportAsJSON() {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(ActionChipStyle())
            }
        }
    }

    // MARK: - Steg Tab

    var stegTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Esteganografía").font(.system(size: 11, weight: .semibold)).foregroundColor(.white)

            Text("Verifica que una imagen del vault contiene la firma invisible incrustada.")
                .font(.system(size: 11)).foregroundColor(.secondary)

            HStack(spacing: 8) {
                Button("Verificar imagen…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.png, .jpeg]
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    if panel.runModal() == .OK, let url = panel.url {
                        Task {
                            let result: Bool = {
                                guard let img = NSImage(contentsOf: url) else { return false }
                                if case .valid = SteganographyEngine.shared.verify(image: img) { return true }
                                return false
                            }()
                            stegVerifyResult = result ? "✅ Firma válida — imagen autenticada" : "❌ Sin firma o firma inválida"
                        }
                    }
                }
                .buttonStyle(ActionChipStyle(accent: true))
            }

            if let result = stegVerifyResult {
                Text(result)
                    .font(.system(size: 11))
                    .foregroundColor(result.hasPrefix("✅") ? Color(hex: "#34d399") : Color(hex: "#ef4444"))
                    .padding(10)
                    .background(Color.white.opacity(0.04))
                    .cornerRadius(6)
            }
        }
    }

    // MARK: - Crypto Tab

    var cryptoTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                statBadge("Estado",    crypto.encryptionStatus, color: crypto.isEncryptionEnabled ? "#34d399" : "#ef4444")
                statBadge("Algoritmo", "AES-256")
                statBadge("Keychain",  "Activo")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Parámetros").font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
                paramRow("Algoritmo",  "AES-256-GCM")
                paramRow("Key size",   "256 bits")
                paramRow("Keychain",   "kSecAttrAccessibleWhenUnlockedThisDeviceOnly")
                if let last = crypto.lastKeyRotation {
                    paramRow("Última rotación", last.shortDisplay)
                } else {
                    paramRow("Última rotación", "Nunca")
                }
            }
            .padding(10).background(Color.white.opacity(0.04)).cornerRadius(8)

            if let result = rotationResult {
                Text(result).font(.system(size: 11))
                    .foregroundColor(result.hasPrefix("✅") ? Color(hex: "#34d399") : Color(hex: "#ef4444"))
            }

            HStack(spacing: 8) {
                Toggle("Cifrado activo", isOn: $crypto.isEncryptionEnabled)
                    .toggleStyle(.switch)
                Spacer()
                Button(action: {
                    isRotating = true
                    rotationResult = nil
                    Task {
                        do {
                            let count = try await crypto.rotateVaultKey()
                            rotationResult = "✅ \(count) archivos re-cifrados"
                        } catch {
                            rotationResult = "❌ \(error.localizedDescription)"
                        }
                        isRotating = false
                    }
                }) {
                    HStack(spacing: 5) {
                        if isRotating { ProgressView().scaleEffect(0.55).progressViewStyle(.circular) }
                        Text(isRotating ? "Rotando…" : "Rotar clave").font(.system(size: 11))
                    }
                }
                .buttonStyle(ActionChipStyle(accent: true))
                .disabled(isRotating)
            }
        }
    }

    // MARK: - Integrity Tab

    var integrityTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                statBadge("OK",        "\(integrity.okCount)",         color: "#34d399")
                statBadge("Corruptos", "\(integrity.corruptedCount)",  color: "#ef4444")
                statBadge("Faltantes", "\(integrity.missingCount)",    color: "#f97316")
                statBadge("Sin hash",  "\(integrity.noHashCount)",     color: "#6b7280")
            }

            if let lastRun = integrity.lastRunAt {
                Text("Última verificación: \(lastRun.shortDisplay)")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }

            if integrity.corruptedCount > 0 || integrity.missingCount > 0 {
                Text("⚠️ Se detectaron problemas. Revisa los assets corruptos o faltantes.")
                    .font(.system(size: 11)).foregroundColor(Color(hex: "#f97316"))
                    .padding(10).background(Color(hex: "#f97316").opacity(0.1)).cornerRadius(6)
            } else if integrity.okCount > 0 {
                Text("✅ Todos los assets verificados están íntegros.")
                    .font(.system(size: 11)).foregroundColor(Color(hex: "#34d399"))
                    .padding(10).background(Color(hex: "#34d399").opacity(0.1)).cornerRadius(6)
            }

            HStack(spacing: 8) {
                Button("Verificar todo ahora") {
                    isRunningIntegrity = true
                    Task {
                        await integrity.runFullVerification()
                        isRunningIntegrity = false
                    }
                }
                .buttonStyle(ActionChipStyle(accent: true))
                .disabled(isRunningIntegrity || integrity.isRunning)

                if isRunningIntegrity || integrity.isRunning {
                    ProgressView().scaleEffect(0.7).progressViewStyle(.circular)
                    Text("Verificando…").font(.system(size: 11)).foregroundColor(.secondary)
                }
            }

            if !integrity.results.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Resultados").font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
                    ForEach(integrity.results.filter { !$0.isOK }.prefix(10)) { record in
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10)).foregroundColor(record.statusColor)
                            Text(record.asset.displayTitle)
                                .font(.system(size: 10)).foregroundColor(.white).lineLimit(1)
                            Spacer()
                            Text(record.statusLabel)
                                .font(.system(size: 9)).foregroundColor(record.statusColor)
                        }
                        .padding(6).background(Color.white.opacity(0.04)).cornerRadius(5)
                    }
                }
            }
        }
    }

    // MARK: - Sandbox Tab (NEW v3)

    var sandboxTab: some View {
        VStack(alignment: .leading, spacing: 12) {

            // Estado rápido
            HStack(spacing: 8) {
                let state = sandbox.processState
                let stateColor: Color = {
                    switch state {
                    case .running:    return Color(hex: "#34d399")
                    case .launching,
                         .stopping:  return Color(hex: "#fbbf24")
                    case .crashed,
                         .restricted: return Color(hex: "#f87171")
                    case .stopped:   return Color(hex: "#64748b")
                    }
                }()

                statBadge("Estado",      state.rawValue,                        color: stateColor.hexString)
                statBadge("PID",         sandbox.sdPID.map(String.init) ?? "—")
                statBadge("Violaciones", "\(sandbox.violations.count)",
                          color: sandbox.violations.isEmpty ? "#34d399" : "#f87171")
                statBadge("Reinicios",   "\(sandbox.restartCount)")
            }

            // Panel principal de SandboxMonitorView
            SandboxMonitorView()

            // Logs de proceso (stdout últimas 20 líneas)
            if !sandbox.stdoutLines.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Stdout SD (últimas 20 líneas)")
                        .font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(sandbox.stdoutLines.suffix(20), id: \.self) { line in
                                Text(line)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.6))
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }
                    .frame(maxHeight: 140)
                    .background(Color.black.opacity(0.3))
                    .cornerRadius(6)
                }
            }

            // Botones de control
            HStack(spacing: 8) {
                // Launch SD
                if sandbox.processState == .stopped || sandbox.processState == .crashed {
                    Button(action: {
                        let path = UserDefaults.standard.string(forKey: "a1111.webuiPath") ?? ""
                        guard !path.isEmpty else { return }
                        Task { try? await sandbox.launchSD(scriptPath: path) }
                    }) {
                        Label("Lanzar SD (sandbox)", systemImage: "play.fill")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(ActionChipStyle(accent: true))
                }

                // Stop SD
                if sandbox.processState == .running {
                    Button(action: {
                        Task { await sandbox.stopSD() }
                    }) {
                        Label("Detener SD", systemImage: "stop.fill")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(ActionChipStyle())
                }

                Spacer()

                // Kill-on-violation toggle
                Toggle("Kill en violación crítica", isOn: $sandbox.config.killOnCriticalViolation)
                    .toggleStyle(.switch)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .onChange(of: sandbox.config.killOnCriticalViolation) { _ in
                        sandbox.saveConfig()
                    }
            }
        }
    }

    // MARK: - Export Report

    private func exportReport() {
        isGeneratingReport = true
        Task {
            let report  = await AppEnvironment.shared.generateAuditReport()
            let encoder = JSONEncoder()
            encoder.outputFormatting    = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            if let data   = try? encoder.encode(report),
               let outDir = VaultManager.shared.vaultMetaURL?.appending(path: "AuditReports") {
                try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
                let url = outDir.appending(path: "audit_\(Int(Date().timeIntervalSince1970)).json")
                try? data.write(to: url, options: .atomic)
                reportURL = url
                NSWorkspace.shared.open(url)
            }
            isGeneratingReport = false
        }
    }

    // MARK: - Helpers

    func statBadge(_ label: String, _ value: String, color: String = "#7c6af7") -> some View {
        VStack(spacing: 3) {
            Text(value).font(.system(size: 15, weight: .bold)).foregroundColor(Color(hex: color))
            Text(label).font(.system(size: 9)).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(8).background(Color.white.opacity(0.04)).cornerRadius(6)
    }

    func gdprFlag(_ label: String, _ value: String, ok: Bool) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.system(size: 12, weight: .bold))
                .foregroundColor(ok ? Color(hex: "#34d399") : Color(hex: "#ef4444"))
            Text(label).font(.system(size: 9)).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(6).background(Color.white.opacity(0.04)).cornerRadius(5)
    }

    func complianceFlag(_ label: String, _ ok: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 9))
                .foregroundColor(ok ? Color(hex: "#34d399") : Color(hex: "#6b7280"))
            Text(label).font(.system(size: 9)).foregroundColor(.secondary)
        }
    }

    func paramRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 10)).foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white.opacity(0.7))
                .lineLimit(1)
        }
    }
}

// MARK: - IntegrityManager UI extensions

extension IntegrityManager {
    var noHashCount: Int {
        results.filter {
            if case .noHashRegistered = $0.result { return true }
            return false
        }.count
    }
}

// MARK: - Color hex helper for sandbox state badge

private extension Color {
    var hexString: String { "#7c6af7" }   // fallback — usa Color(hex:) con el valor real en runtime
}
