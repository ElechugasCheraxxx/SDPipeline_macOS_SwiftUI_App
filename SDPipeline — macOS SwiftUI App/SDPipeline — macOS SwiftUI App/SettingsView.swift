import SwiftUI
import AppKit

// MARK: - SettingsView v5
// AÑADIDO:
//   - Sección "Proyectos" con ProjectPickerView inline
//   - Sección "Integridad" con IntegrityDashboardView
//   - Fix backup section → BackupManager bindings correctos
//   - Fix GPU section → GPUMonitor.vramFree (Int64 bytes) → MB display

struct SettingsView: View {

    @ObservedObject private var vault        = VaultManager.shared
    @ObservedObject private var backupMgr    = BackupManager.shared
    @ObservedObject private var nsfwDetector = NSFWDetector.shared
    @ObservedObject private var exportEngine = ExportEngine.shared
    @ObservedObject private var gpu          = GPUMonitor.shared
    @ObservedObject private var projects     = ProjectManager.shared

    @State private var activeSection: SettingsSection = .vault
    @State private var watermarkText:     String  = UserDefaults.standard.string(forKey: "watermark.text") ?? "@tuusuario"
    @State private var watermarkOpacity:  Double  = UserDefaults.standard.double(forKey: "watermark.opacity").nonZero(default: 0.35)
    @State private var watermarkPosition: ExportEngine.WatermarkConfig.Position = .bottomRight
    @State private var sdBaseURL:         String  = "http://127.0.0.1:7860"
    @State private var integrityResults:  [String] = []
    @State private var isVerifying:       Bool    = false

    // MARK: - Sections

    enum SettingsSection: String, CaseIterable {
        case vault      = "Vault"
        case projects   = "Proyectos"       // NEW
        case watermark  = "Watermark"
        case backup     = "Backup"
        case nsfw       = "NSFW Policy"
        case export     = "Export"
        case gpu        = "GPU / SD"
        case license    = "Licencias"
        case integrity  = "Integridad"      // NEW
        case audit      = "Auditoría"
        case wildcards  = "Wildcards"

        var icon: String {
            switch self {
            case .vault:      return "externaldrive.fill"
            case .projects:   return "folder.badge.gearshape"
            case .watermark:  return "signature"
            case .backup:     return "externaldrive.badge.timemachine"
            case .nsfw:       return "exclamationmark.shield.fill"
            case .export:     return "square.and.arrow.up"
            case .gpu:        return "cpu.fill"
            case .license:    return "doc.badge.checkmark"
            case .integrity:  return "shield.checkered"
            case .audit:      return "lock.shield.fill"
            case .wildcards:  return "shuffle"
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
                    case .vault:      vaultSection
                    case .projects:   projectsSection
                    case .watermark:  watermarkSection
                    case .backup:     backupSection
                    case .nsfw:       nsfwSection
                    case .export:     exportSection
                    case .gpu:        gpuSection
                    case .license:    licenseSection
                    case .integrity:  integritySection
                    case .audit:      auditSection
                    case .wildcards:  wildcardsSection
                    }
                }
                .padding(24)
            }
            .frame(minWidth: 420)
            .background(Color(red: 0.10, green: 0.10, blue: 0.13))
        }
        .frame(minWidth: 620, minHeight: 480)
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
    }

    // MARK: - Sidebar Item

    func sidebarItem(_ section: SettingsSection) -> some View {
        let isActive = activeSection == section
        return Button(action: { activeSection = section }) {
            HStack(spacing: 8) {
                Image(systemName: section.icon)
                    .font(.system(size: 12))
                    .frame(width: 16)
                    .foregroundColor(isActive ? Color(hex: "#7c6af7") : .secondary)
                Text(section.rawValue)
                    .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                    .foregroundColor(isActive ? .white : .secondary)
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(isActive ? Color.white.opacity(0.08) : Color.clear)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Section: Vault

    var vaultSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Configuración del Vault")

            if let root = vault.vaultRoot {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Directorio raíz actual")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                    HStack {
                        Text(root.path)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.white.opacity(0.8))
                            .lineLimit(2)
                        Spacer()
                        Button("Abrir") {
                            NSWorkspace.shared.open(root)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "#7c6af7"))
                    }
                    .padding(10)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(8)
                }
            } else {
                Text("⚠️ Vault no configurado")
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "#f59e0b"))
            }

            Button("Cambiar ubicación del Vault…") {
                vault.selectVaultRoot()
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.white.opacity(0.07))
            .foregroundColor(.white)
            .cornerRadius(6)
            .font(.system(size: 12))
        }
    }

    // MARK: - Section: Projects (NEW)

    var projectsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Gestión de Proyectos")

            Text("Organiza tus generaciones en proyectos independientes, cada uno con su propio vault, settings y sesiones.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            ProjectPickerView()
                .frame(height: 360)
        }
    }

    // MARK: - Section: Watermark

    var watermarkSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Watermark Visible")

            VStack(alignment: .leading, spacing: 8) {
                Text("Texto del watermark")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                TextField("@tuusuario", text: $watermarkText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onChange(of: watermarkText) { _, v in
                        exportEngine.watermarkConfig.text = v
                        UserDefaults.standard.set(v, forKey: "watermark.text")
                    }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Opacidad: \(String(format: "%.0f%%", watermarkOpacity * 100))")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                Slider(value: $watermarkOpacity, in: 0.1...0.8, step: 0.05)
                    .onChange(of: watermarkOpacity) { _, v in
                        exportEngine.watermarkConfig.opacity = v
                        UserDefaults.standard.set(v, forKey: "watermark.opacity")
                    }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Posición")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                Picker("", selection: $watermarkPosition) {
                    Text("Superior izq.").tag(ExportEngine.WatermarkConfig.Position.topLeft)
                    Text("Superior der.").tag(ExportEngine.WatermarkConfig.Position.topRight)
                    Text("Centro").tag(ExportEngine.WatermarkConfig.Position.center)
                    Text("Inferior izq.").tag(ExportEngine.WatermarkConfig.Position.bottomLeft)
                    Text("Inferior der.").tag(ExportEngine.WatermarkConfig.Position.bottomRight)
                }
                .pickerStyle(.segmented)
                .font(.system(size: 11))
                .onChange(of: watermarkPosition) { _, v in
                    exportEngine.watermarkConfig.position = v
                }
            }

            Divider().background(Color.white.opacity(0.07))
            sectionTitle("Metadatos IPTC/XMP")
            IPTCSettingsView()
        }
    }

    // MARK: - Section: Backup

    var backupSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Backup Automático (rclone)")

            // Status
            HStack(spacing: 8) {
                Image(systemName: backupMgr.config.lastBackupOK ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .foregroundColor(backupMgr.config.lastBackupOK ? Color(hex: "#34d399") : Color(hex: "#f59e0b"))
                VStack(alignment: .leading, spacing: 2) {
                    Text(backupMgr.config.lastBackupOK ? "Último backup exitoso" : "Sin backup reciente")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white)
                    if let lastAt = backupMgr.config.lastBackupAt {
                        Text(lastAt.shortDisplay)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                Button("Backup ahora") {
                    Task { await backupMgr.runAllBackups() }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color(hex: "#7c6af7").opacity(0.2))
                .foregroundColor(Color(hex: "#7c6af7"))
                .cornerRadius(6)
                .font(.system(size: 11))
                .disabled(backupMgr.isRunning)
            }
            .padding(12)
            .background(Color.white.opacity(0.04))
            .cornerRadius(8)

            // Destinations
            if backupMgr.config.destinations.isEmpty {
                Text("No hay destinos configurados. Añade al menos un destino rclone para activar los backups automáticos.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else {
                ForEach(backupMgr.config.destinations) { dest in
                    HStack(spacing: 8) {
                        Image(systemName: dest.type.icon)
                            .font(.system(size: 12))
                            .foregroundColor(Color(hex: "#7c6af7"))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(dest.name).font(.system(size: 11, weight: .medium)).foregroundColor(.white)
                            Text(dest.rcloneRemote).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                        }
                        Spacer()
                        Circle()
                            .fill(dest.isEnabled ? Color(hex: "#34d399") : .gray)
                            .frame(width: 7, height: 7)
                    }
                    .padding(8)
                    .background(Color.white.opacity(0.04))
                    .cornerRadius(6)
                }
            }

            Button("Abrir configuración de rclone…") {
                backupMgr.openRcloneConfig()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundColor(Color(hex: "#7c6af7"))
        }
    }

    // MARK: - Section: NSFW

    var nsfwSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Política NSFW")

            Toggle("Análisis de imagen con CLIP (requiere A1111 online)", isOn: $nsfwDetector.policy.enableImageAnalysis)
                .toggleStyle(.switch).font(.system(size: 12)).foregroundColor(.white)

            Toggle("Auto-blur de previews con contenido marcado", isOn: $nsfwDetector.policy.autoBlurPreview)
                .toggleStyle(.switch).font(.system(size: 12)).foregroundColor(.white)

            Toggle("Log de todas las detecciones", isOn: $nsfwDetector.policy.logAll)
                .toggleStyle(.switch).font(.system(size: 12)).foregroundColor(.white)

            Divider().background(Color.white.opacity(0.07))

            NSFWLogView()
                .frame(height: 280)
        }
    }

    // MARK: - Section: Export

    var exportSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Configuración de Export")
            Text("Las imágenes se exportan en dos versiones: una limpia (sin metadatos SD) y una preview con watermark.")
                .font(.system(size: 11)).foregroundColor(.secondary)

            // Export directories info
            if let exportURL = VaultManager.shared.exportURL {
                paramRow("Export limpio", exportURL.path)
            }
            if let previewURL = VaultManager.shared.previewsURL {
                paramRow("Previews", previewURL.path)
            }

            Button("Abrir carpeta Export en Finder") {
                if let url = VaultManager.shared.exportURL {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundColor(Color(hex: "#7c6af7"))
        }
    }

    // MARK: - Section: GPU

    var gpuSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("GPU / Stable Diffusion")

            // GPU info
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Dispositivo").font(.system(size: 10)).foregroundColor(.secondary)
                    Text(gpu.deviceName.isEmpty ? "Detectando…" : gpu.deviceName)
                        .font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                }
                Spacer()
                VStack(alignment: .leading, spacing: 4) {
                    Text("VRAM libre").font(.system(size: 10)).foregroundColor(.secondary)
                    // vramFree is Int64 bytes — convert to MB
                    let vramMB = Double(gpu.vramFree) / 1_048_576
                    Text(vramMB > 0 ? String(format: "%.0f MB", vramMB) : "N/A")
                        .font(.system(size: 12, weight: .semibold)).foregroundColor(vramColor(vramMB))
                }
            }
            .padding(12).background(Color.white.opacity(0.05)).cornerRadius(8)

            // SD URL
            VStack(alignment: .leading, spacing: 6) {
                Text("URL de Stable Diffusion").font(.system(size: 11)).foregroundColor(.secondary)
                TextField("http://127.0.0.1:7860", text: $sdBaseURL)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12))
            }

            Text("💡 Para Apple Silicon usa --medvram-sdxl y --opt-sdp-attention para mejor rendimiento.")
                .font(.system(size: 10)).foregroundColor(.secondary)
        }
    }

    func vramColor(_ mb: Double) -> Color {
        if mb <= 0 { return .gray }
        if mb < 1000 { return Color(hex: "#ef4444") }
        if mb < 2000 { return Color(hex: "#f59e0b") }
        return Color(hex: "#34d399")
    }

    // MARK: - Section: License

    var licenseSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Vault Legal — Licencias")

            let cards = LicenseVault.shared.loadAllModelCards()
            if cards.isEmpty {
                Text("No hay model cards registrados. Los checkpoints se auto-registran en el primer uso.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            } else {
                ForEach(cards, id: \.id) { card in
                    licenseRow(card)
                }
            }

            Divider().background(Color.white.opacity(0.07))

            Button("Abrir Vault/Licencias en Finder") {
                LicenseVault.shared.openLicensesInFinder()
            }
            .buttonStyle(.plain).font(.system(size: 11)).foregroundColor(Color(hex: "#7c6af7"))
        }
    }

    func licenseRow(_ card: LicenseVault.ModelCard) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(licenseColor(card))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.checkpointName).font(.system(size: 11, weight: .medium)).foregroundColor(.white).lineLimit(1)
                Text(card.licenseType.rawValue).font(.system(size: 9)).foregroundColor(.secondary)
            }
            Spacer()
            Text(card.commercialUse.rawValue)
                .font(.system(size: 9))
                .foregroundColor(licenseColor(card))
                .lineLimit(1)
        }
        .padding(8).background(Color.white.opacity(0.04)).cornerRadius(6)
    }

    func licenseColor(_ card: LicenseVault.ModelCard) -> Color {
        switch card.commercialUse {
        case .allowed:           return Color(hex: "#34d399")
        case .allowed_with_attr: return Color(hex: "#fbbf24")
        case .restricted:        return Color(hex: "#f97316")
        case .prohibited:        return Color(hex: "#ef4444")
        case .unknown:           return Color(hex: "#6b7280")
        }
    }

    // MARK: - Section: Integrity (NEW)

    var integritySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Integridad SHA-256")
            Text("Verifica que los archivos en disco coincidan con los hashes registrados en el momento de la generación.")
                .font(.system(size: 11)).foregroundColor(.secondary)

            IntegrityDashboardView()
                .frame(height: 420)
        }
    }

    // MARK: - Section: Audit

    var auditSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Audit Log Cifrado")
            ZeroKnowledgeLogView()
                .frame(height: 420)
        }
    }

    // MARK: - Section: Wildcards

    var wildcardsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Wildcards")
            Text("Los wildcards usan la sintaxis __nombre__ en el prompt. Se resuelven aleatoriamente al generar.")
                .font(.system(size: 11)).foregroundColor(.secondary)
            // WildcardEngine list view — simplified
            let categories = WildcardEngine.shared.categories
            if categories.isEmpty {
                Text("No hay wildcards definidos. Créalos en Vault/wildcards/")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            } else {
                ForEach(categories, id: \.self) { cat in
                    HStack {
                        Text(cat).font(.system(size: 11)).foregroundColor(.white)
                        Spacer()
                        let count = WildcardEngine.shared.entries(for: cat).count
                        Text("\(count) entradas").font(.system(size: 10)).foregroundColor(.secondary)
                    }
                    .padding(8).background(Color.white.opacity(0.04)).cornerRadius(5)
                }
            }
        }
    }

    // MARK: - Helpers

    func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15, weight: .bold))
            .foregroundColor(.white)
    }

    func paramRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 10)).foregroundColor(.secondary)
            Spacer()
            Text(value).font(.system(size: 10, design: .monospaced)).foregroundColor(.white.opacity(0.7)).lineLimit(1)
        }
    }
}

// MARK: - Double extension

extension Double {
    func nonZero(default defaultValue: Double) -> Double {
        self == 0 ? defaultValue : self
    }
}

// MARK: - BackupManager.openRcloneConfig stub

extension BackupManager {
    func openRcloneConfig() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", "Terminal", "--args", "rclone config"]
        try? task.run()
    }
}

// MARK: - WildcardEngine extensions for settings view

extension WildcardEngine {
    var categories: [String] { Array(wildcardMap.keys.sorted()) }
    func entries(for category: String) -> [String] { wildcardMap[category] ?? [] }
}
