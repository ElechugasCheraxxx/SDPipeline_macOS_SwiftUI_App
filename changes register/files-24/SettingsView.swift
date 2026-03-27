import SwiftUI
import AppKit

// MARK: - SettingsView v4
// FIXES:
//   - BackupManager.isHealthy → .config.lastBackupOK
//   - GPUMonitor.vramFreeMB → .vramFree (Int64, bytes) / .ramFree en Apple Silicon
//   - IPTCSettingsView conectada al IPTCMetadataWriter real (con UserDefaults)
//   - verifyIntegrity() integrada con AssetStore.verifyIntegrity()
//   - Sección License Vault visible

struct SettingsView: View {

    @ObservedObject private var vault        = VaultManager.shared
    @ObservedObject private var backupMgr    = BackupManager.shared
    @ObservedObject private var nsfwDetector = NSFWDetector.shared
    @ObservedObject private var exportEngine = ExportEngine.shared
    @ObservedObject private var gpu          = GPUMonitor.shared

    @State private var activeSection: SettingsSection = .vault
    @State private var watermarkText:     String  = "@tuusuario"
    @State private var watermarkOpacity:  Double  = 0.35
    @State private var watermarkPosition: ExportEngine.WatermarkConfig.Position = .bottomRight
    @State private var sdBaseURL:         String  = "http://127.0.0.1:7860"
    @State private var integrityResults:  [String] = []
    @State private var isVerifying:       Bool    = false

    // MARK: - Sections

    enum SettingsSection: String, CaseIterable {
        case vault     = "Vault"
        case watermark = "Watermark"
        case backup    = "Backup"
        case nsfw      = "NSFW Policy"
        case export    = "Export"
        case gpu       = "GPU / SD"
        case license   = "Licencias"
        case audit     = "Auditoría"
        case wildcards = "Wildcards"

        var icon: String {
            switch self {
            case .vault:     return "externaldrive.fill"
            case .watermark: return "signature"
            case .backup:    return "externaldrive.badge.timemachine"
            case .nsfw:      return "exclamationmark.shield.fill"
            case .export:    return "square.and.arrow.up"
            case .gpu:       return "cpu.fill"
            case .license:   return "doc.badge.checkmark"
            case .audit:     return "lock.shield.fill"
            case .wildcards: return "shuffle"
            }
        }
    }

    // MARK: - Body

    var body: some View {
        HSplitView {
            // Sidebar
            VStack(spacing: 2) {
                ForEach(SettingsSection.allCases, id: \.self) { sidebarItem($0) }
                Spacer()
            }
            .padding(8).frame(minWidth: 160, maxWidth: 180)
            .background(Color(red: 0.09, green: 0.09, blue: 0.12))

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch activeSection {
                    case .vault:     vaultSection
                    case .watermark: watermarkSection
                    case .backup:    backupSection
                    case .nsfw:      nsfwSection
                    case .export:    exportSection
                    case .gpu:       gpuSection
                    case .license:   licenseSection
                    case .audit:     auditSection
                    case .wildcards: wildcardsSection
                    }
                }
                .padding(20)
            }
            .frame(minWidth: 380).background(Color(red: 0.10, green: 0.10, blue: 0.13))
        }
        .frame(width: 640, height: 500)
    }

    // MARK: - Sidebar Item

    func sidebarItem(_ section: SettingsSection) -> some View {
        Button(action: { activeSection = section }) {
            HStack(spacing: 7) {
                Image(systemName: section.icon).font(.system(size: 11)).frame(width: 16)
                    .foregroundColor(activeSection == section ? Color(hex: "#7c6af7") : .secondary)
                Text(section.rawValue)
                    .font(.system(size: 12, weight: activeSection == section ? .semibold : .regular))
                    .foregroundColor(activeSection == section ? .white : .secondary)
                Spacer()
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(activeSection == section ? Color.white.opacity(0.07) : Color.clear)
            .cornerRadius(6)
        }.buttonStyle(.plain)
    }

    // MARK: - Vault Section

    var vaultSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Vault", icon: "externaldrive.fill")
            settingsGroup {
                VStack(alignment: .leading, spacing: 7) {
                    label("Ruta del Vault")
                    HStack(spacing: 7) {
                        Text(vault.vaultRoot?.path ?? "No configurado")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(vault.isConfigured ? .white.opacity(0.7) : .red.opacity(0.7))
                            .lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(5).background(Color.white.opacity(0.05)).cornerRadius(5)
                        Button("Cambiar") { vault.selectVaultRoot() }
                            .buttonStyle(.plain).font(.system(size: 11))
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(Color.white.opacity(0.08)).foregroundColor(.white).cornerRadius(5)
                    }
                }
                divider
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Abrir en Finder").font(.system(size: 12)).foregroundColor(.white)
                        Text("Ver la estructura de directorios").font(.system(size: 10)).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: { if let u = vault.vaultRoot { NSWorkspace.shared.open(u) } }) {
                        Image(systemName: "arrow.up.forward.square").font(.system(size: 13))
                            .foregroundColor(Color(hex: "#7c6af7"))
                    }.buttonStyle(.plain).disabled(!vault.isConfigured)
                }
            }
        }
    }

    // MARK: - Watermark Section

    var watermarkSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Watermark", icon: "signature")
            settingsGroup {
                VStack(alignment: .leading, spacing: 7) {
                    label("Texto")
                    TextField("@usuario o URL", text: $watermarkText)
                        .textFieldStyle(.plain).font(.system(size: 12)).foregroundColor(.white)
                        .padding(6).background(Color.white.opacity(0.06)).cornerRadius(5)
                        .onChange(of: watermarkText) { _, v in exportEngine.watermarkConfig.text = v }
                }
                divider
                VStack(alignment: .leading, spacing: 5) {
                    label("Opacidad: \(Int(watermarkOpacity * 100))%")
                    Slider(value: $watermarkOpacity, in: 0.05...0.80, step: 0.05)
                        .tint(Color(hex: "#7c6af7"))
                        .onChange(of: watermarkOpacity) { _, v in exportEngine.watermarkConfig.opacity = v }
                }
                divider
                VStack(alignment: .leading, spacing: 5) {
                    label("Posición")
                    Picker("", selection: $watermarkPosition) {
                        Text("↖ Sup. Izq").tag(ExportEngine.WatermarkConfig.Position.topLeft)
                        Text("↗ Sup. Der").tag(ExportEngine.WatermarkConfig.Position.topRight)
                        Text("↙ Inf. Izq").tag(ExportEngine.WatermarkConfig.Position.bottomLeft)
                        Text("↘ Inf. Der").tag(ExportEngine.WatermarkConfig.Position.bottomRight)
                        Text("○ Centro").tag(ExportEngine.WatermarkConfig.Position.center)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .onChange(of: watermarkPosition) { _, v in exportEngine.watermarkConfig.position = v }
                }
            }
        }
        .onAppear {
            watermarkText     = exportEngine.watermarkConfig.text
            watermarkOpacity  = exportEngine.watermarkConfig.opacity
            watermarkPosition = exportEngine.watermarkConfig.position
        }
    }

    // MARK: - Backup Section

    var backupSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Backup Automático", icon: "externaldrive.badge.timemachine")
            settingsGroup {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("rclone").font(.system(size: 12)).foregroundColor(.white)
                        Text(backupMgr.rcloneAvailable ? "Instalado" : "brew install rclone")
                            .font(.system(size: 10))
                            .foregroundColor(backupMgr.rcloneAvailable ? Color(hex: "#3de3c0") : .orange)
                    }
                    Spacer()
                    Circle().fill(backupMgr.rcloneAvailable ? Color(hex: "#3de3c0") : .orange)
                        .frame(width: 7, height: 7)
                }
                divider
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Último backup").font(.system(size: 12)).foregroundColor(.white)
                        // FIX: usar config.lastBackupAt en lugar de backupMgr.lastBackupAt
                        Text(backupMgr.config.lastBackupAt.map {
                            DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short)
                        } ?? "Nunca")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                    }
                    Spacer()
                    // FIX: usar config.lastBackupOK en lugar de isHealthy
                    if backupMgr.config.lastBackupAt != nil {
                        Image(systemName: backupMgr.config.lastBackupOK ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundColor(backupMgr.config.lastBackupOK ? Color(hex: "#34d399") : .orange)
                    }
                    if backupMgr.isRunning {
                        ProgressView().scaleEffect(0.6).progressViewStyle(.circular)
                    } else {
                        Button("Ejecutar") { Task { await backupMgr.runAllBackups() } }
                            .buttonStyle(.plain).font(.system(size: 11))
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(Color(hex: "#7c6af7").opacity(0.2))
                            .foregroundColor(Color(hex: "#7c6af7")).cornerRadius(5)
                            .disabled(!backupMgr.rcloneAvailable)
                    }
                }
                divider
                toggleRow("Excluir PNGs originales", "Ahorra espacio en backup",
                    Binding(get: { backupMgr.config.excludeRawPNGs },
                            set: { backupMgr.config.excludeRawPNGs = $0; backupMgr.saveConfig() }))
            }
            // BackupSettingsView para configuración detallada de destinos
            BackupSettingsView()
        }
    }

    // MARK: - NSFW Section

    var nsfwSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Política NSFW", icon: "exclamationmark.shield.fill")
            settingsGroup {
                VStack(alignment: .leading, spacing: 5) {
                    label("Umbral para flaggear")
                    Picker("", selection: Binding(
                        get: { nsfwDetector.policy.thresholdForFlag },
                        set: { nsfwDetector.policy.thresholdForFlag = $0 }
                    )) {
                        ForEach(NSFWLevel.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden()
                }
                divider
                VStack(alignment: .leading, spacing: 5) {
                    label("Umbral para cuarentena")
                    Picker("", selection: Binding(
                        get: { nsfwDetector.policy.thresholdForQuarantine },
                        set: { nsfwDetector.policy.thresholdForQuarantine = $0 }
                    )) {
                        ForEach(NSFWLevel.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden()
                }
                divider
                toggleRow("Análisis CLIP de imagen", "Requiere A1111 online. Más preciso.",
                    Binding(get: { nsfwDetector.policy.enableImageAnalysis },
                            set: { nsfwDetector.policy.enableImageAnalysis = $0 }))
                divider
                toggleRow("Auto-blur en galería", "Difumina thumbnails moderados",
                    Binding(get: { nsfwDetector.policy.autoBlurPreview },
                            set: { nsfwDetector.policy.autoBlurPreview = $0 }))
            }
        }
    }

    // MARK: - Export Section

    var exportSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Export", icon: "square.and.arrow.up")
            settingsGroup {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Carpeta Export").font(.system(size: 12)).foregroundColor(.white)
                        Text(vault.exportURL?.path ?? "—")
                            .font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button(action: { if let u = vault.exportURL { NSWorkspace.shared.open(u) } }) {
                        Image(systemName: "arrow.up.forward.square").font(.system(size: 13))
                            .foregroundColor(Color(hex: "#7c6af7"))
                    }.buttonStyle(.plain)
                }
                divider
                Text("Dual export automático: PNG sin metadatos EXIF/SD + preview con watermark. El prompt nunca se incrusta en metadatos.")
                    .font(.system(size: 10)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // IPTC — usa IPTCSettingsView de IPTCMetadataWriter.swift (con UserDefaults)
            sectionHeader("Metadatos IPTC / XMP", icon: "doc.badge.plus")
            Text("Solo en versión limpia (clean). Preview con watermark: sin metadatos de autoría.")
                .font(.system(size: 10)).foregroundColor(.secondary)
            settingsGroup { IPTCSettingsView() }

            // Integridad SHA-256
            sectionHeader("Integridad SHA-256", icon: "checkmark.shield")
            settingsGroup {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Verificar assets").font(.system(size: 12)).foregroundColor(.white)
                        Text("Comprueba que PNGs del vault no han sido modificados")
                            .font(.system(size: 10)).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: runIntegrityCheck) {
                        HStack(spacing: 4) {
                            if isVerifying { ProgressView().scaleEffect(0.55).progressViewStyle(.circular) }
                            else { Image(systemName: "checkmark.shield").font(.system(size: 11)) }
                            Text("Verificar").font(.system(size: 11))
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Color(hex: "#3de3c0").opacity(0.15))
                    .foregroundColor(Color(hex: "#3de3c0")).cornerRadius(5)
                    .disabled(isVerifying)
                }
                if !integrityResults.isEmpty {
                    divider
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(integrityResults.prefix(20), id: \.self) { r in
                            Text(r).font(.system(size: 9, design: .monospaced))
                                .foregroundColor(r.hasPrefix("✓") ? Color(hex: "#34d399") : Color(hex: "#ef4444"))
                        }
                        if integrityResults.count > 20 {
                            Text("… y \(integrityResults.count - 20) más")
                                .font(.system(size: 9)).foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func runIntegrityCheck() {
        isVerifying = true
        integrityResults = []
        Task {
            let assets = AssetStore.shared.fetchAllAssets(limit: 200)
            var results: [String] = []
            for asset in assets.prefix(50) {
                let ok   = AssetStore.shared.verifyIntegrity(asset)
                let name = asset.baseName ?? "unknown"
                results.append(ok ? "✓ \(name)" : "✗ \(name) — hash mismatch")
            }
            await MainActor.run {
                integrityResults = results
                isVerifying = false
            }
        }
    }

    // MARK: - GPU Section

    var gpuSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("GPU / Stable Diffusion", icon: "cpu.fill")
            settingsGroup {
                VStack(alignment: .leading, spacing: 5) {
                    label("URL de Automatic1111")
                    TextField("http://127.0.0.1:7860", text: $sdBaseURL)
                        .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced)).foregroundColor(.white)
                        .padding(6).background(Color.white.opacity(0.06)).cornerRadius(5)
                }
                divider
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("GPU detectada").font(.system(size: 12)).foregroundColor(.white)
                        Text(gpu.deviceName.isEmpty ? "Detectando…" : gpu.deviceName)
                            .font(.system(size: 10)).foregroundColor(.secondary)
                    }
                    Spacer()
                    // FIX: usar .vramFree (Int64 bytes) o .ramFree según Apple Silicon
                    let freeMB = Double(gpu.isAppleSilicon ? gpu.ramFree : gpu.vramFree) / 1_048_576.0
                    if freeMB > 0 {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(String(format: "%.0f MB libres", freeMB))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(freeMB < 512 ? .orange : Color(hex: "#3de3c0"))
                            Text(gpu.isAppleSilicon ? "Unified Memory" : "VRAM")
                                .font(.system(size: 8)).foregroundColor(.secondary)
                        }
                    }
                    Button("Detectar") { gpu.detectDevice() }
                        .buttonStyle(.plain).font(.system(size: 11))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Color.white.opacity(0.08)).foregroundColor(.white).cornerRadius(5)
                }
                divider
                // PreCheck status
                let status = gpu.preCheckStatus
                HStack(spacing: 6) {
                    Image(systemName: status.icon).font(.system(size: 11)).foregroundColor(status.color)
                    Text(status.message ?? "VRAM OK").font(.system(size: 11)).foregroundColor(status.color)
                }
                .padding(8).background(status.color.opacity(0.08)).cornerRadius(6)
            }
            // Panel completo de GPU
            GPUStatusPanel()
        }
    }

    // MARK: - License Section

    var licenseSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Licencias / Model Cards", icon: "doc.badge.checkmark")
            Text("Registro legal de cada checkpoint utilizado. Requerido para publicación comercial.")
                .font(.system(size: 10)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            settingsGroup {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Abrir carpeta Licencias").font(.system(size: 12)).foregroundColor(.white)
                        Text("Vault/Licencias/").font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: { LicenseVault.shared.openLicensesInFinder() }) {
                        Image(systemName: "folder").font(.system(size: 13))
                            .foregroundColor(Color(hex: "#7c6af7"))
                    }.buttonStyle(.plain).disabled(!vault.isConfigured)
                }
                divider
                Button(action: { LicenseVault.shared.generateAllTemplates() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.badge.plus").font(.system(size: 11))
                        Text("Regenerar plantillas de consentimiento").font(.system(size: 11))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain).padding(.vertical, 7)
                .background(Color(hex: "#7c6af7").opacity(0.12))
                .foregroundColor(Color(hex: "#7c6af7")).cornerRadius(6)
            }
        }
    }

    // MARK: - Audit Section

    var auditSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Audit Log Cifrado (AES-GCM)", icon: "lock.shield.fill")
            Text("Cifrado AES-GCM-256 en disco. Clave exclusivamente en Keychain del sistema.")
                .font(.system(size: 10)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ZeroKnowledgeLogView().frame(minHeight: 340)
        }
    }

    // MARK: - Wildcards Section

    var wildcardsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Wildcards Dinámicos", icon: "shuffle")
            Text("Usa __nombre__ en cualquier prompt para insertar un término aleatorio del grupo.")
                .font(.system(size: 10)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            WildcardEditorView().frame(minHeight: 320)
        }
    }

    // MARK: - Reusable

    func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 15))
                .foregroundStyle(LinearGradient(
                    colors: [Color(hex: "#7c6af7"), Color(hex: "#3de3c0")],
                    startPoint: .leading, endPoint: .trailing))
            Text(title).font(.system(size: 15, weight: .bold)).foregroundColor(.white)
        }
    }

    func settingsGroup<C: View>(@ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 11) { content() }
            .padding(13).background(Color.white.opacity(0.04)).cornerRadius(9)
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.07), lineWidth: 1))
    }

    func label(_ text: String) -> some View {
        Text(text).font(.system(size: 9, weight: .semibold))
            .foregroundColor(.secondary).tracking(0.8).textCase(.uppercase)
    }

    var divider: some View { Divider().background(Color.white.opacity(0.06)) }

    func toggleRow(_ title: String, _ subtitle: String, _ value: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12)).foregroundColor(.white)
                Text(subtitle).font(.system(size: 10)).foregroundColor(.secondary)
            }
            Spacer()
            Toggle("", isOn: value).toggleStyle(.switch).labelsHidden().scaleEffect(0.8)
        }
    }
}
