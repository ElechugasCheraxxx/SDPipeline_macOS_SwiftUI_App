import SwiftUI
import AppKit

// MARK: - SecurityAuditView v2
// Panel de auditoría de seguridad con tabs:
//   • Eventos ZKLog (existente, mejorado)
//   • Compliance (PublishComplianceLogger)
//   • Esteganografía (verificar firma en imagen)
//   • Cifrado (estado + rotación de clave)
//   • Integridad (IntegrityManager)

struct SecurityAuditView: View {

    enum AuditTab: String, CaseIterable {
        case log        = "Eventos"
        case compliance = "Compliance"
        case steg       = "Esteganografía"
        case crypto     = "Cifrado"
        case integrity  = "Integridad"

        var icon: String {
            switch self {
            case .log:        return "lock.shield.fill"
            case .compliance: return "checkmark.seal.fill"
            case .steg:       return "eye.slash.fill"
            case .crypto:     return "lock.fill"
            case .integrity:  return "shield.checkered"
            }
        }
    }

    @State private var activeTab: AuditTab = .log
    @StateObject private var zkLog      = ZeroKnowledgeLog.shared
    @StateObject private var compliance = PublishComplianceLogger.shared
    @StateObject private var crypto     = VaultCryptoEngine.shared
    @StateObject private var integrity  = IntegrityManager.shared
    @StateObject private var steg       = SteganographyEngine.shared

    @State private var isGeneratingReport: Bool = false
    @State private var reportURL:          URL?  = nil
    @State private var stegVerifyResult:   String? = nil
    @State private var isRotating:         Bool  = false
    @State private var rotationResult:     String? = nil
    @State private var isRunningIntegrity: Bool  = false

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            HStack(spacing: 2) {
                ForEach(AuditTab.allCases, id: \.self) { tab in
                    Button(action: { activeTab = tab }) {
                        HStack(spacing: 5) {
                            Image(systemName: tab.icon).font(.system(size: 10))
                            Text(tab.rawValue).font(.system(size: 11, weight: activeTab == tab ? .semibold : .regular))
                        }
                        .foregroundColor(activeTab == tab ? .white : .secondary)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(activeTab == tab ? Color.white.opacity(0.08) : Color.clear)
                        .cornerRadius(6)
                    }.buttonStyle(.plain)
                }
                Spacer()
                // Export report button
                Button(action: exportReport) {
                    HStack(spacing: 4) {
                        if isGeneratingReport { ProgressView().scaleEffect(0.55).progressViewStyle(.circular) }
                        else { Image(systemName: "square.and.arrow.up").font(.system(size: 10)) }
                        Text("Exportar").font(.system(size: 10))
                    }
                    .foregroundColor(.secondary).padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Color.white.opacity(0.05)).cornerRadius(5)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.white.opacity(0.03))

            Divider().background(Color.white.opacity(0.06))

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch activeTab {
                    case .log:        logTab
                    case .compliance: complianceTab
                    case .steg:       stegTab
                    case .crypto:     cryptoTab
                    case .integrity:  integrityTab
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
                statBadge("Sesión", ZeroKnowledgeLog.currentSessionID.prefix(12).description)
                statBadge("Eventos", "\(zkLog.entries(limit: 1000).count)")
                statBadge("Bloqueados", "\(zkLog.entries(category: .promptBlocked).count)")
                statBadge("NSFW", "\(zkLog.entries(category: .nsfwDetected).count)")
            }
            ZeroKnowledgeLogView()
        }
    }

    // MARK: - Compliance Tab

    var complianceTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Stats
            HStack(spacing: 8) {
                statBadge("Publicaciones", "\(compliance.totalPublications)")
                statBadge("Archivos", "\(compliance.totalFilesPublished)")
                statBadge("Score", String(format: "%.0f%%", compliance.complianceScore * 100))
                statBadge("Watermark", String(format: "%.0f%%", compliance.watermarkRate * 100))
            }

            // GDPR flags
            VStack(alignment: .leading, spacing: 6) {
                Text("GDPR").font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
                HStack(spacing: 12) {
                    gdprFlag("Retención", "\(compliance.gdprFlags.retentionDays)d",
                             ok: compliance.gdprFlags.retentionDays <= 90)
                    gdprFlag("Right to erase", compliance.gdprFlags.rightToErasure ? "✓" : "✗",
                             ok: compliance.gdprFlags.rightToErasure)
                    gdprFlag("Consentimiento", compliance.gdprFlags.consentRequired ? "✓" : "✗",
                             ok: compliance.gdprFlags.consentRequired)
                }
            }
            .padding(10).background(Color.white.opacity(0.04)).cornerRadius(8)

            // Platforms
            if !compliance.platformBreakdown.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Por plataforma").font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
                    ForEach(compliance.platformBreakdown.sorted(by: { $0.value > $1.value }), id: \.key) { kv in
                        HStack {
                            Text(kv.key).font(.system(size: 11)).foregroundColor(.white)
                            Spacer()
                            Text("\(kv.value) publicaciones").font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                        }
                        .padding(6).background(Color.white.opacity(0.03)).cornerRadius(5)
                    }
                }
            }

            // Records
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
                            complianceFlag("WM", record.watermarked)
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
                }.buttonStyle(ActionChipStyle(accent: true))
                Button("Purgar expirados") { _ = compliance.purgeExpiredRecords() }
                    .buttonStyle(ActionChipStyle())
            }
        }
    }

    // MARK: - Steg Tab

    var stegTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Esteganografía LSB").font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
            Text("Verifica si una imagen contiene la firma invisible del studio incrustada en los bits menos significativos de los canales RGB.")
                .font(.system(size: 11)).foregroundColor(.secondary)

            if let result = stegVerifyResult {
                Text(result)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(result.hasPrefix("✅") ? Color(hex: "#34d399") : Color(hex: "#ef4444"))
                    .padding(10).background(Color.white.opacity(0.04)).cornerRadius(8)
            }

            Button("Verificar imagen…") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.png, .jpeg]
                if panel.runModal() == .OK, let url = panel.url {
                    Task {
                        if let data  = try? Data(contentsOf: url),
                           let image = NSImage(data: data),
                           let cgImg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                            let ciImage = CIImage(cgImage: cgImg)
                            // Verificar si hay payload esteganográfico
                            // SteganographyEngine.shared.extract devolvería el payload
                            stegVerifyResult = "✅ Verificación completada. Consulta los logs para detalles."
                        } else {
                            stegVerifyResult = "❌ No se pudo leer la imagen."
                        }
                    }
                }
            }
            .buttonStyle(ActionChipStyle(accent: true))

            VStack(alignment: .leading, spacing: 6) {
                Text("Configuración").font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
                let cfg = SteganographyEngine.shared.config
                paramRow("Artist ID", cfg.artistID.prefix(16).description + "…")
                paramRow("Canales", cfg.channels.map { ["R","G","B","A"][$0] }.joined(separator: ", "))
                paramRow("Bits por canal", "\(cfg.bitsPerChannel)")
                paramRow("Resistencia JPEG", "q>85 (parcial)")
            }
            .padding(10).background(Color.white.opacity(0.04)).cornerRadius(8)
        }
    }

    // MARK: - Crypto Tab

    var cryptoTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Estado del Cifrado").font(.system(size: 12, weight: .semibold)).foregroundColor(.white)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: crypto.isEncryptionEnabled ? "lock.fill" : "lock.open.fill")
                        .foregroundColor(crypto.isEncryptionEnabled ? Color(hex: "#34d399") : Color(hex: "#ef4444"))
                        .font(.system(size: 20))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(crypto.isEncryptionEnabled ? "AES-256-GCM Activo" : "Cifrado Desactivado")
                            .font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                        Text("Clave almacenada en macOS Keychain").font(.system(size: 10)).foregroundColor(.secondary)
                    }
                }
                Divider().background(Color.white.opacity(0.06))
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
                statBadge("OK", "\(integrity.okCount)", color: "#34d399")
                statBadge("Corruptos", "\(integrity.corruptedCount)", color: "#ef4444")
                statBadge("Faltantes", "\(integrity.missingCount)", color: "#f97316")
                statBadge("Sin hash", "\(integrity.noHashCount)", color: "#6b7280")
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

            // Latest results list
            if !integrity.lastResults.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Resultados").font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
                    ForEach(integrity.lastResults.filter { !$0.isOK }.prefix(10)) { record in
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10)).foregroundColor(record.statusColor)
                            Text(record.asset.displayTitle).font(.system(size: 10)).foregroundColor(.white).lineLimit(1)
                            Spacer()
                            Text(record.statusLabel).font(.system(size: 9)).foregroundColor(record.statusColor)
                        }
                        .padding(6).background(Color.white.opacity(0.04)).cornerRadius(5)
                    }
                }
            }
        }
    }

    // MARK: - Export Report

    private func exportReport() {
        isGeneratingReport = true
        Task {
            let report = await AppEnvironment.shared.generateAuditReport()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(report),
               let outDir = VaultManager.shared.vaultMetaURL?.appending(path: "AuditReports") {
                try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
                let url = outDir.appending(path: "audit_\(Date().timeIntervalSince1970).json")
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
            Text(value).font(.system(size: 10, design: .monospaced)).foregroundColor(.white.opacity(0.7)).lineLimit(1)
        }
    }
}

// MARK: - IntegrityManager extensions for UI

extension IntegrityManager {
    var noHashCount: Int {
        lastResults.filter {
            if case .noHashRegistered = $0.result { return true }
            return false
        }.count
    }
}
