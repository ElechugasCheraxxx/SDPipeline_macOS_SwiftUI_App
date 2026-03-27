import SwiftUI
import AppKit

// MARK: - SettingsView
// Panel de configuración centralizado del estudio.
// Accesible desde el menú Vault o mediante Cmd+, (standard macOS shortcut).
// Agrupa: Vault, Watermark, Backup, NSFW Policy, Export, GPU.

struct SettingsView: View {

    @ObservedObject private var vault        = VaultManager.shared
    @ObservedObject private var backupMgr    = BackupManager.shared
    @ObservedObject private var nsfwDetector = NSFWDetector.shared
    @ObservedObject private var exportEngine = ExportEngine.shared

    @State private var activeSection: SettingsSection = .vault

    enum SettingsSection: String, CaseIterable {
        case vault      = "Vault"
        case watermark  = "Watermark"
        case backup     = "Backup"
        case nsfw       = "NSFW Policy"
        case export     = "Export"
        case gpu        = "GPU / SD"

        var icon: String {
            switch self {
            case .vault:     return "externaldrive.fill"
            case .watermark: return "signature"
            case .backup:    return "externaldrive.badge.timemachine"
            case .nsfw:      return "exclamationmark.shield.fill"
            case .export:    return "square.and.arrow.up"
            case .gpu:       return "cpu.fill"
            }
        }
    }

    var body: some View {
        HSplitView {
            // Sidebar
            VStack(spacing: 2) {
                ForEach(SettingsSection.allCases, id: \.self) { section in
                    sidebarItem(section)
                }
                Spacer()
            }
            .padding(8)
            .frame(minWidth: 160, maxWidth: 180)
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
                    }
                }
                .padding(20)
            }
            .frame(minWidth: 360)
            .background(Color(red: 0.10, green: 0.10, blue: 0.13))
        }
        .frame(width: 560, height: 420)
    }

    // MARK: - Sidebar Item

    func sidebarItem(_ section: SettingsSection) -> some View {
        Button(action: { activeSection = section }) {
            HStack(spacing: 8) {
                Image(systemName: section.icon)
                    .font(.system(size: 12))
                    .frame(width: 18)
                    .foregroundColor(activeSection == section ? Color(hex: "#7c6af7") : .secondary)
                Text(section.rawValue)
                    .font(.system(size: 12, weight: activeSection == section ? .semibold : .regular))
                    .foregroundColor(activeSection == section ? .white : .secondary)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(activeSection == section ? Color.white.opacity(0.07) : Color.clear)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Vault Section

    var vaultSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Vault", icon: "externaldrive.fill")

            settingsGroup {
                VStack(alignment: .leading, spacing: 8) {
                    label("Ruta del Vault")
                    HStack(spacing: 8) {
                        Text(vault.vaultRoot?.path ?? "No configurado")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(vault.isConfigured ? .white.opacity(0.7) : .red.opacity(0.7))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                            .background(Color.white.opacity(0.05))
                            .cornerRadius(5)

                        Button("Cambiar") { vault.selectVaultRoot() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color.white.opacity(0.08))
                            .foregroundColor(.white)
                            .cornerRadius(5)
                    }
                }

                divider

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Abrir en Finder")
                            .font(.system(size: 12))
                            .foregroundColor(.white)
                        Text("Ver la estructura de directorios del vault")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: {
                        if let url = vault.vaultRoot { NSWorkspace.shared.open(url) }
                    }) {
                        Image(systemName: "arrow.up.forward.square")
                            .font(.system(size: 13))
                            .foregroundColor(Color(hex: "#7c6af7"))
                    }
                    .buttonStyle(.plain)
                    .disabled(!vault.isConfigured)
                }
            }
        }
    }

    // MARK: - Watermark Section

    @State private var watermarkText:     String  = "@tuusuario"
    @State private var watermarkOpacity:  Double  = 0.35
    @State private var watermarkPosition: ExportEngine.WatermarkConfig.Position = .bottomRight
    @State private var watermarkFontSize: Double  = 18

    var watermarkSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Watermark", icon: "signature")

            settingsGroup {
                VStack(alignment: .leading, spacing: 8) {
                    label("Texto del watermark")
                    TextField("@usuario o URL", text: $watermarkText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundColor(.white)
                        .padding(7)
                        .background(Color.white.opacity(0.06))
                        .cornerRadius(6)
                        .onChange(of: watermarkText) { _, val in
                            ExportEngine.shared.watermarkConfig.text = val
                        }
                }

                divider

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        label("Opacidad: \(Int(watermarkOpacity * 100))%")
                        Spacer()
                    }
                    Slider(value: $watermarkOpacity, in: 0.05...0.80, step: 0.05)
                        .tint(Color(hex: "#7c6af7"))
                        .onChange(of: watermarkOpacity) { _, val in
                            ExportEngine.shared.watermarkConfig.opacity = val
                        }
                }

                divider

                VStack(alignment: .leading, spacing: 6) {
                    label("Posición")
                    Picker("", selection: $watermarkPosition) {
                        Text("Sup. Izq").tag(ExportEngine.WatermarkConfig.Position.topLeft)
                        Text("Sup. Der").tag(ExportEngine.WatermarkConfig.Position.topRight)
                        Text("Inf. Izq").tag(ExportEngine.WatermarkConfig.Position.bottomLeft)
                        Text("Inf. Der").tag(ExportEngine.WatermarkConfig.Position.bottomRight)
                        Text("Centro").tag(ExportEngine.WatermarkConfig.Position.center)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .onChange(of: watermarkPosition) { _, val in
                        ExportEngine.shared.watermarkConfig.position = val
                    }
                }
            }
        }
        .onAppear {
            watermarkText     = ExportEngine.shared.watermarkConfig.text
            watermarkOpacity  = ExportEngine.shared.watermarkConfig.opacity
            watermarkPosition = ExportEngine.shared.watermarkConfig.position
        }
    }

    // MARK: - Backup Section

    var backupSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Backup Automático", icon: "externaldrive.badge.timemachine")

            settingsGroup {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("rclone disponible")
                            .font(.system(size: 12))
                            .foregroundColor(.white)
                        Text(backupMgr.rcloneAvailable ? "Instalado y listo" : "No encontrado — brew install rclone")
                            .font(.system(size: 10))
                            .foregroundColor(backupMgr.rcloneAvailable ? Color(hex: "#3de3c0") : .orange)
                    }
                    Spacer()
                    Circle()
                        .fill(backupMgr.rcloneAvailable ? Color(hex: "#3de3c0") : .orange)
                        .frame(width: 8, height: 8)
                }

                divider

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Último backup")
                            .font(.system(size: 12)).foregroundColor(.white)
                        Text(backupMgr.config.lastBackupAt.map {
                            DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short)
                        } ?? "Nunca")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                    }
                    Spacer()
                    if backupMgr.isRunning {
                        ProgressView().scaleEffect(0.7).progressViewStyle(.circular)
                    } else {
                        Button("Ejecutar ahora") {
                            Task { await backupMgr.runAllBackups() }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color(hex: "#7c6af7").opacity(0.2))
                        .foregroundColor(Color(hex: "#7c6af7"))
                        .cornerRadius(5)
                        .disabled(!backupMgr.rcloneAvailable)
                    }
                }

                divider

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Excluir PNGs originales")
                            .font(.system(size: 12)).foregroundColor(.white)
                        Text("Ahorra espacio — los exports limpios son suficientes")
                            .font(.system(size: 10)).foregroundColor(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { backupMgr.config.excludeRawPNGs },
                        set: { backupMgr.config.excludeRawPNGs = $0; backupMgr.saveConfig() }
                    ))
                    .toggleStyle(.switch).labelsHidden().scaleEffect(0.8)
                }
            }
        }
    }

    // MARK: - NSFW Section

    var nsfwSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Política NSFW", icon: "exclamationmark.shield.fill")

            settingsGroup {
                VStack(alignment: .leading, spacing: 6) {
                    label("Umbral para flaggear")
                    Picker("", selection: Binding(
                        get: { nsfwDetector.policy.thresholdForFlag },
                        set: { nsfwDetector.policy.thresholdForFlag = $0 }
                    )) {
                        ForEach(NSFWLevel.allCases, id: \.self) { level in
                            Text(level.label).tag(level)
                        }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }

                divider

                VStack(alignment: .leading, spacing: 6) {
                    label("Umbral para cuarentena")
                    Picker("", selection: Binding(
                        get: { nsfwDetector.policy.thresholdForQuarantine },
                        set: { nsfwDetector.policy.thresholdForQuarantine = $0 }
                    )) {
                        ForEach(NSFWLevel.allCases, id: \.self) { level in
                            Text(level.label).tag(level)
                        }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }

                divider

                toggleRow(
                    title:    "Análisis de imagen con CLIP",
                    subtitle: "Requiere A1111 online. Más preciso.",
                    value:    Binding(
                        get: { nsfwDetector.policy.enableImageAnalysis },
                        set: { nsfwDetector.policy.enableImageAnalysis = $0 }
                    )
                )

                divider

                toggleRow(
                    title:    "Auto-blur en preview",
                    subtitle: "Difumina imágenes moderadas en la galería",
                    value:    Binding(
                        get: { nsfwDetector.policy.autoBlurPreview },
                        set: { nsfwDetector.policy.autoBlurPreview = $0 }
                    )
                )
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
                        Text("Carpeta Export")
                            .font(.system(size: 12)).foregroundColor(.white)
                        Text(vault.exportURL?.path ?? "No configurado")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button(action: {
                        if let url = vault.exportURL { NSWorkspace.shared.open(url) }
                    }) {
                        Image(systemName: "arrow.up.forward.square")
                            .font(.system(size: 13))
                            .foregroundColor(Color(hex: "#7c6af7"))
                    }
                    .buttonStyle(.plain)
                }

                divider

                Text("Los exports limpios se guardan automáticamente al hacer Vault.\nFormato: PNG sin metadatos + versión preview con watermark.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - GPU Section

    @State private var sdBaseURL: String = "http://127.0.0.1:7860"

    var gpuSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("GPU / Stable Diffusion", icon: "cpu.fill")

            settingsGroup {
                VStack(alignment: .leading, spacing: 6) {
                    label("URL de Automatic1111")
                    TextField("http://127.0.0.1:7860", text: $sdBaseURL)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(7)
                        .background(Color.white.opacity(0.06))
                        .cornerRadius(6)
                }

                divider

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("GPU detectada")
                            .font(.system(size: 12)).foregroundColor(.white)
                        Text(GPUMonitor.shared.deviceName.isEmpty ? "Detectando…" : GPUMonitor.shared.deviceName)
                            .font(.system(size: 10)).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Detectar") { GPUMonitor.shared.detectDevice() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.white.opacity(0.08))
                        .foregroundColor(.white)
                        .cornerRadius(5)
                }
            }
        }
    }

    // MARK: - Reusable sub-components

    func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color(hex: "#7c6af7"), Color(hex: "#3de3c0")],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
            Text(title)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
        }
    }

    func settingsGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(14)
        .background(Color.white.opacity(0.04))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.07), lineWidth: 1))
    }

    func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.secondary)
            .tracking(0.8)
            .textCase(.uppercase)
    }

    var divider: some View {
        Divider().background(Color.white.opacity(0.06))
    }

    func toggleRow(title: String, subtitle: String, value: Binding<Bool>) -> some View {
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
