import SwiftUI
import UniformTypeIdentifiers
import AppKit
import Combine

// MARK: - SettingsView v10
//
// Cambios v9 → v10:
//   ✨ ADD: case cleanup — sección "Limpieza de Artefactos" (ArtifactCleanupEngine)
//          ROADMAP: "Limpieza automática de artefactos" ahora conectada a UI
//   🔁 UPD: SettingsSection.group incluye cleanup en grupo "Producción"
//
// Cambios v8 → v9:
//   + Sección "Pipeline" — retry policy, atomic save, autocomplete, workers
//   + Sección "ControlNet" — gestión de unidades + presets de red
//   + Sección "Presets" — panel ReusableSettingsManager
//   + Grupos de sidebar actualizados para nuevas secciones
// Añade secciones:
//   • Cifrado (VaultCryptoEngine — rotación de clave, estado AES-256)
//   • Compliance (PublishComplianceLogger — GDPR flags, reporte)
//   • IP-Adapter (configuración por defecto, presets)
//   • Color (ACEScgColorEngine — LUTs, grado por defecto)
//   • Editor externo (ExternalEditorBridge)

struct SettingsView: View {

    @ObservedObject private var vault         = VaultManager.shared
    @ObservedObject private var backupMgr     = BackupManager.shared
    @ObservedObject private var nsfwDetector  = NSFWDetector.shared
    @ObservedObject private var exportEngine  = ExportEngine.shared
    @ObservedObject private var gpu           = GPUMonitor.shared
    @ObservedObject private var projects      = ProjectManager.shared
    @ObservedObject private var cryptoEngine  = VaultCryptoEngine.shared
    @ObservedObject private var compliance    = PublishComplianceLogger.shared
    @ObservedObject private var ipAdapter     = IPAdapterEngine.shared
    @ObservedObject private var colorEngine   = ACEScgColorEngine.shared
    @ObservedObject private var editorBridge  = ExternalEditorBridge.shared

    @State private var activeSection: SettingsSection = .vault
    @State private var watermarkText:     String  = UserDefaults.standard.string(forKey: "watermark.text") ?? "@tuusuario"
    @State private var watermarkOpacity:  Double  = UserDefaults.standard.double(forKey: "watermark.opacity").nonZero(default: 0.35)
    @State private var watermarkPosition: ExportEngine.WatermarkConfig.Position = .bottomRight
    @State private var sdBaseURL:         String  = UserDefaults.standard.string(forKey: "sd.baseURL") ?? "http://127.0.0.1:7860"
    @State private var webuiScriptPath:   String  = UserDefaults.standard.string(forKey: "a1111.webuiPath") ?? ""
    @State private var autoLaunchSD:      Bool    = UserDefaults.standard.bool(forKey: "sandbox.autoLaunchSD")
    @State private var integrityResults:  [String] = []
    @State private var isVerifying:       Bool    = false
    @State private var isRotatingKey:     Bool    = false
    @State private var keyRotationResult: String? = nil
    @State private var isExportingCompliance: Bool = false

    // MARK: - Sections

    enum SettingsSection: String, CaseIterable {
        case vault      = "Vault"
        case projects   = "Proyectos"
        case crypto     = "Cifrado"
        case watermark  = "Watermark"
        case backup     = "Backup"
        case nsfw       = "NSFW Policy"
        case export     = "Export"
        case compliance = "Compliance"
        case ipAdapter  = "IP-Adapter"
        case color      = "Color"
        case editor     = "Editor externo"
        case gpu        = "GPU / SD"
        case license    = "Licencias"
        case integrity  = "Integridad"
        case audit      = "Auditoría"
        case wildcards  = "Wildcards"
        case pipeline   = "Pipeline"
        case controlnet = "ControlNet"
        case presets    = "Presets"
        case cleanup    = "Limpieza"   // NEW v10 — ArtifactCleanupEngine

        var icon: String {
            switch self {
            case .vault:      return "externaldrive.fill"
            case .projects:   return "folder.badge.gearshape"
            case .crypto:     return "lock.fill"
            case .watermark:  return "signature"
            case .backup:     return "externaldrive.badge.timemachine"
            case .nsfw:       return "exclamationmark.shield.fill"
            case .export:     return "square.and.arrow.up"
            case .compliance: return "checkmark.seal.fill"
            case .ipAdapter:  return "person.fill.viewfinder"
            case .color:      return "wand.and.stars"
            case .editor:     return "arrow.up.forward.app.fill"
            case .gpu:        return "cpu.fill"
            case .license:    return "doc.badge.checkmark"
            case .integrity:  return "shield.checkered"
            case .audit:      return "lock.shield.fill"
            case .wildcards:  return "shuffle"
            case .pipeline:   return "arrow.triangle.2.circlepath.circle.fill"
            case .controlnet: return "network"
            case .presets:    return "bookmark.fill"
            case .cleanup:    return "sparkle.magnifyingglass"
            }
        }

        var group: String {
            switch self {
            case .vault, .projects, .crypto, .backup, .integrity:   return "Infraestructura"
            case .watermark, .export, .compliance, .ipAdapter, .color, .editor: return "Producción"
            case .nsfw, .license, .audit:                            return "Seguridad"
            case .gpu, .wildcards, .pipeline:                        return "Sistema"
            case .controlnet:                                        return "Producción"
            case .presets:                                           return "Producción"
            case .cleanup:                                           return "Producción"
            }
        }
    }

    // MARK: - Body

    var body: some View {
        HSplitView {
            // Sidebar
            VStack(alignment: .leading, spacing: 0) {
                ForEach(["Infraestructura", "Producción", "Seguridad", "Sistema"], id: \.self) { group in
                    Text(group.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 4)
                    ForEach(SettingsSection.allCases.filter { $0.group == group }, id: \.self) {
                        sidebarItem($0)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 8).frame(minWidth: 168, maxWidth: 190)
            .background(Color(red: 0.09, green: 0.09, blue: 0.12))

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch activeSection {
                    case .vault:      vaultSection
                    case .projects:   projectsSection
                    case .crypto:     cryptoSection
                    case .watermark:  watermarkSection
                    case .backup:     backupSection
                    case .nsfw:       nsfwSection
                    case .export:     exportSection
                    case .compliance: complianceSection
                    case .ipAdapter:  ipAdapterSection
                    case .color:      colorSection
                    case .editor:     editorSection
                    case .gpu:        gpuSection
                    case .license:    licenseSection
                    case .integrity:  integritySection
                    case .audit:      auditSection
                    case .wildcards:  wildcardsSection
                    case .pipeline:   pipelineSection
                    case .controlnet: controlNetSection
                    case .presets:    presetsSection
                    case .cleanup:    cleanupSection
                    }
                }
                .padding(24)
            }
            .frame(minWidth: 460)
            .background(Color(red: 0.10, green: 0.10, blue: 0.13))
        }
        .frame(minWidth: 680, minHeight: 520)
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
    }

    // MARK: - Sidebar Item

    func sidebarItem(_ section: SettingsSection) -> some View {
        let isActive = activeSection == section
        return Button(action: { activeSection = section }) {
            HStack(spacing: 7) {
                Image(systemName: section.icon)
                    .font(.system(size: 11))
                    .frame(width: 16)
                    .foregroundColor(isActive ? Color(hex: "#7c6af7") : .secondary)
                Text(section.rawValue)
                    .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                    .foregroundColor(isActive ? .white : .secondary)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(isActive ? Color.white.opacity(0.07) : Color.clear)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
    }

    // MARK: - Section: Vault

    var vaultSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Vault del Studio")

            if vault.isConfigured, let root = vault.vaultRoot {
                infoCard {
                    paramRow("Ruta", root.path)
                    paramRow("Estado", "✅ Configurado")
                    if let url = vault.generacionesURL {
                        paramRow("Generaciones", url.lastPathComponent)
                    }
                }
                HStack(spacing: 8) {
                    Button("Abrir en Finder") { NSWorkspace.shared.open(root) }
                        .buttonStyle(ActionChipStyle())
                    Button("Re-configurar…") { vault.showFirstRunSheet = true }
                        .buttonStyle(ActionChipStyle())
                }
            } else {
                Text("Vault no configurado. Reinicia la app para ejecutar el asistente de configuración.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                Button("Configurar Vault…") { vault.showFirstRunSheet = true }
                    .buttonStyle(ActionChipStyle(accent: true))
            }
        }
    }

    // MARK: - Section: Projects

    var projectsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Proyectos del Studio")
            let pf = ProjectFolderManager.shared
            if pf.projects.isEmpty {
                Text("No hay proyectos creados aún. El sistema crea uno por defecto al configurar el vault.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            } else {
                ForEach(pf.projects) { project in
                    HStack(spacing: 10) {
                        Circle().fill(Color(hex: project.color)).frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(project.name)
                                .font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
                            Text(project.rootURL.path)
                                .font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if project.isActive {
                            Text("Activo").font(.system(size: 9, weight: .semibold))
                                .foregroundColor(Color(hex: "#34d399"))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color(hex: "#34d399").opacity(0.15)).cornerRadius(4)
                        } else {
                            Button("Activar") { pf.setActive(project) }
                                .buttonStyle(ActionChipStyle())
                        }
                    }
                    .padding(10).background(Color.white.opacity(0.04)).cornerRadius(8)
                }
            }
            Button("Nuevo proyecto…") {
                _ = try? pf.createProject(name: "Nuevo Proyecto \(pf.projects.count + 1)")
            }
            .buttonStyle(ActionChipStyle(accent: true))
        }
    }

    // MARK: - Section: Cifrado (NEW)

    var cryptoSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Cifrado AES-256-GCM")

            infoCard {
                HStack {
                    Image(systemName: cryptoEngine.isEncryptionEnabled ? "lock.fill" : "lock.open.fill")
                        .foregroundColor(cryptoEngine.isEncryptionEnabled ? Color(hex: "#34d399") : Color(hex: "#ef4444"))
                    Text(cryptoEngine.isEncryptionEnabled ? "Cifrado activo" : "Cifrado desactivado")
                        .font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
                    Spacer()
                    Toggle("", isOn: $cryptoEngine.isEncryptionEnabled)
                        .toggleStyle(.switch).scaleEffect(0.8)
                }
                Divider().background(Color.white.opacity(0.06))
                paramRow("Algoritmo", "AES-256-GCM")
                paramRow("Almacén de clave", "macOS Keychain")
                paramRow("Scope", "kSecAttrAccessibleWhenUnlockedThisDeviceOnly")
                if let lastRotation = cryptoEngine.lastKeyRotation {
                    paramRow("Última rotación", lastRotation.shortDisplay)
                } else {
                    paramRow("Última rotación", "Nunca")
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Rotación de Clave").font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                Text("Genera una nueva clave AES-256 y re-cifra todos los archivos del vault. El proceso corre en background y puede tardar varios minutos.")
                    .font(.system(size: 11)).foregroundColor(.secondary)

                if let result = keyRotationResult {
                    Text(result).font(.system(size: 11))
                        .foregroundColor(result.hasPrefix("✅") ? Color(hex: "#34d399") : Color(hex: "#ef4444"))
                }

                Button(action: {
                    isRotatingKey = true
                    keyRotationResult = nil
                    Task {
                        do {
                            let count = try await cryptoEngine.rotateVaultKey()
                            keyRotationResult = "✅ Rotación completa — \(count) archivos re-cifrados"
                        } catch {
                            keyRotationResult = "❌ Error: \(error.localizedDescription)"
                        }
                        isRotatingKey = false
                    }
                }) {
                    HStack(spacing: 6) {
                        if isRotatingKey { ProgressView().scaleEffect(0.6).progressViewStyle(.circular) }
                        Text(isRotatingKey ? "Rotando clave…" : "Rotar clave del vault")
                    }
                }
                .buttonStyle(ActionChipStyle(accent: true))
                .disabled(isRotatingKey)
            }
        }
    }

    // MARK: - Section: Watermark

    var watermarkSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Watermark de Previews")
            infoCard {
                HStack(spacing: 8) {
                    Text("Texto").font(.system(size: 10)).foregroundColor(.secondary).frame(width: 72, alignment: .leading)
                    TextField("@usuario", text: $watermarkText)
                        .textFieldStyle(.plain).font(.system(size: 11)).foregroundColor(.white)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(Color.white.opacity(0.06)).cornerRadius(6)
                    Button("Guardar") {
                        exportEngine.watermarkConfig.text = watermarkText
                        UserDefaults.standard.set(watermarkText, forKey: "watermark.text")
                    }.buttonStyle(ActionChipStyle())
                }
                sliderRow("Opacidad", value: $watermarkOpacity, range: 0.1...0.9)
                HStack(spacing: 6) {
                    Text("Posición").font(.system(size: 10)).foregroundColor(.secondary).frame(width: 72)
                    Picker("", selection: $watermarkPosition) {
                        Text("↙ Inferior izquierda").tag(ExportEngine.WatermarkConfig.Position.bottomLeft)
                        Text("↘ Inferior derecha").tag(ExportEngine.WatermarkConfig.Position.bottomRight)
                        Text("↗ Superior derecha").tag(ExportEngine.WatermarkConfig.Position.topRight)
                        Text("↖ Superior izquierda").tag(ExportEngine.WatermarkConfig.Position.topLeft)
                        Text("⊙ Centro").tag(ExportEngine.WatermarkConfig.Position.center)
                    }.pickerStyle(.menu).font(.system(size: 11))
                }
            }
        }
    }

    // MARK: - Section: Backup

    var backupSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Backup Automático (rclone)")
            infoCard {
                HStack(spacing: 8) {
                    Image(systemName: backupMgr.config.lastBackupOK ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                        .foregroundColor(backupMgr.config.lastBackupOK ? Color(hex: "#34d399") : Color(hex: "#f59e0b"))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(backupMgr.config.lastBackupOK ? "Último backup exitoso" : "Sin backup reciente")
                            .font(.system(size: 11, weight: .medium)).foregroundColor(.white)
                        if let lastAt = backupMgr.config.lastBackupAt {
                            Text(lastAt.shortDisplay).font(.system(size: 10)).foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    Button("Backup ahora") { Task { await backupMgr.runAllBackups() } }
                        .buttonStyle(ActionChipStyle(accent: true))
                        .disabled(backupMgr.isRunning)
                }
            }
            if backupMgr.config.destinations.isEmpty {
                Text("No hay destinos configurados. Añade al menos un destino rclone.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            } else {
                ForEach(backupMgr.config.destinations) { dest in
                    HStack(spacing: 8) {
                        Image(systemName: dest.type.icon).font(.system(size: 12)).foregroundColor(Color(hex: "#7c6af7"))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(dest.name).font(.system(size: 11, weight: .medium)).foregroundColor(.white)
                            Text(dest.rcloneRemote).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                        }
                        Spacer()
                        Circle().fill(dest.isEnabled ? Color(hex: "#34d399") : .gray).frame(width: 7, height: 7)
                    }
                    .padding(8).background(Color.white.opacity(0.04)).cornerRadius(6)
                }
            }
            Button("Abrir configuración rclone…") { backupMgr.openRcloneConfig() }
                .buttonStyle(ActionChipStyle())
        }
    }

    // MARK: - Section: NSFW

    var nsfwSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Política NSFW")
            infoCard {
                paramRow("Análisis de Imagen (CLIP)", nsfwDetector.policy.enableImageAnalysis ? "Sí" : "No")
                paramRow("Umbral de Cuarentena", nsfwDetector.policy.thresholdForQuarantine.label)
                paramRow("Umbral de Flag", nsfwDetector.policy.thresholdForFlag.label)
            }
            HStack(spacing: 8) {
                Toggle("Análisis de Imagen", isOn: $nsfwDetector.policy.enableImageAnalysis).toggleStyle(.switch)
                Toggle("Log de todo", isOn: $nsfwDetector.policy.logAll).toggleStyle(.switch)
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading) {
                    Text("Umbral de Cuarentena").font(.system(size: 10)).foregroundColor(.secondary)
                    Picker("", selection: $nsfwDetector.policy.thresholdForQuarantine) {
                        ForEach(NSFWLevel.allCases, id: \.self) { l in Text(l.label).tag(l) }
                    }.pickerStyle(.menu)
                }
                VStack(alignment: .leading) {
                    Text("Umbral de Flag").font(.system(size: 10)).foregroundColor(.secondary)
                    Picker("", selection: $nsfwDetector.policy.thresholdForFlag) {
                        ForEach(NSFWLevel.allCases, id: \.self) { l in Text(l.label).tag(l) }
                    }.pickerStyle(.menu)
                }
            }
        }
    }

    // MARK: - Section: Export

    var exportSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Export y Dos Versiones")
            Text("Cada imagen aprobada produce: (1) versión limpia sin metadatos y (2) versión preview con watermark. La versión raw del vault nunca sale.")
                .font(.system(size: 11)).foregroundColor(.secondary)
            infoCard {
                paramRow("Kill-Switch EXIF", "Disponible desde App → Vault menu")
                paramRow("Chunks PNG eliminados", "tEXt, iTXt, zTXt, eXIf, iCCP")
                paramRow("Proceso", "Re-render pixel a pixel vía Core Graphics")
            }
            Button("Ejecutar EXIF Kill-Switch global") {
                Task { await AppEnvironment.shared.runEXIFKillSwitch() }
            }
            .buttonStyle(ActionChipStyle(accent: true))
        }
    }

    // MARK: - Section: Compliance (NEW)

    var complianceSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Compliance y GDPR")

            infoCard {
                paramRow("Publicaciones registradas", "\(compliance.totalEntries)")
                paramRow("Archivos publicados", "\(compliance.totalFilesPublished)")
                paramRow("Score de compliance", String(format: "%.0f%%", compliance.currentComplianceScore * 100))
                paramRow("Watermark rate", String(format: "%.0f%%", compliance.watermarkRate * 100))
                Divider().background(Color.white.opacity(0.06))
                HStack {
                    Text("Plataformas").font(.system(size: 10)).foregroundColor(.secondary)
                    Spacer()
                    Text(compliance.platformBreakdown.map { "\($0.key): \($0.value)" }.joined(separator: " · "))
                        .font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary).lineLimit(1)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("GDPR").font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                sliderRow("Retención (días)", value: Binding(
                    get: { Double(compliance.gdprFlags.retentionDays) },
                    set: { compliance.gdprFlags.retentionDays = Int($0) }
                ), range: 7...365)
                Toggle("Portabilidad de datos", isOn: Binding(
                    get: { compliance.gdprFlags.allowsDataPortability },
                    set: { compliance.gdprFlags.allowsDataPortability = $0 }
                )).toggleStyle(.switch)
                Toggle("Derecho al olvido", isOn: Binding(
                    get: { compliance.gdprFlags.rightToErasure },
                    set: { compliance.gdprFlags.rightToErasure = $0 }
                )).toggleStyle(.switch)
                Toggle("Consentimiento requerido", isOn: Binding(
                    get: { compliance.gdprFlags.consentRequired },
                    set: { compliance.gdprFlags.consentRequired = $0 }
                )).toggleStyle(.switch)
            }

            HStack(spacing: 8) {
                Button("Exportar reporte JSON") {
                    isExportingCompliance = true
                    if let url = try? compliance.exportReportAsJSON() {
                        NSWorkspace.shared.open(url)
                    }
                    isExportingCompliance = false
                }
                .buttonStyle(ActionChipStyle(accent: true))
                Button("Purgar registros expirados") { _ = compliance.purgeExpiredRecords() }
                    .buttonStyle(ActionChipStyle())
            }
        }
    }

    // MARK: - Section: IP-Adapter (NEW)

    var ipAdapterSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("IP-Adapter / FaceID")
            Text("Configuración por defecto de IP-Adapter para consistencia facial entre generaciones.")
                .font(.system(size: 11)).foregroundColor(.secondary)

            infoCard {
                paramRow("Estado A1111", ipAdapter.availableModels.isEmpty ? "Sin detectar" : "\(ipAdapter.availableModels.count) modelos")
                paramRow("Modelo activo", ipAdapter.config.model.displayName)
                paramRow("Peso", String(format: "%.2f", ipAdapter.config.weight))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Modelo por defecto").font(.system(size: 11)).foregroundColor(.secondary)
                Picker("", selection: $ipAdapter.config.model) {
                    ForEach(IPAdapterModel.allCases, id: \.self) { m in
                        Text(m.displayName).tag(m)
                    }
                }.pickerStyle(.menu).font(.system(size: 11))
                sliderRow("Peso por defecto", value: $ipAdapter.config.weight, range: 0.1...1.0)
                Toggle("Auto-recorte de cara", isOn: $ipAdapter.config.cropFace).toggleStyle(.switch)
            }

            Button("Verificar instalación A1111") {
                Task { await ipAdapter.checkInstalled() }
            }
            .buttonStyle(ActionChipStyle())
        }
    }

    // MARK: - Section: Color (NEW)

    var colorSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Gestión de Color ACEScg")
            Text("Pipeline de color cinematográfico. Los ajustes se aplican en post-procesamiento, no afectan la generación SD.")
                .font(.system(size: 11)).foregroundColor(.secondary)

            infoCard {
                paramRow("LUTs disponibles", "\(colorEngine.availableLUTs.count)")
                paramRow("LUTs built-in", "\(ACEScgColorEngine.builtInLUTs.count)")
                paramRow("LUTs de usuario", "\(colorEngine.availableLUTs.filter { !$0.isBuiltIn }.count)")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("LUTs disponibles").font(.system(size: 11)).foregroundColor(.secondary)
                ForEach(colorEngine.availableLUTs.prefix(8)) { lut in
                    HStack {
                        Image(systemName: lut.isBuiltIn ? "checkmark.circle.fill" : "folder.fill")
                            .font(.system(size: 10))
                            .foregroundColor(lut.isBuiltIn ? Color(hex: "#34d399") : Color(hex: "#7c6af7"))
                        Text(lut.name).font(.system(size: 11)).foregroundColor(.white)
                        Spacer()
                        Text(lut.description).font(.system(size: 9)).foregroundColor(.secondary).lineLimit(1)
                    }
                    .padding(6).background(Color.white.opacity(0.03)).cornerRadius(5)
                }
            }

            Button("Abrir carpeta LUTs…") {
                if let url = VaultManager.shared.vaultMetaURL?.appending(path: "LUTs") {
                    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(ActionChipStyle())
        }
    }

    // MARK: - Section: Editor Externo (NEW)

    var editorSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Editor Externo")
            Text("Abre assets en aplicaciones externas y re-importa las versiones editadas al vault automáticamente.")
                .font(.system(size: 11)).foregroundColor(.secondary)

            infoCard {
                paramRow("Editor preferido", editorBridge.preferredEditor.rawValue)
                paramRow("Editores detectados", editorBridge.installedEditors.map { $0.rawValue }.joined(separator: ", "))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Editor preferido").font(.system(size: 11)).foregroundColor(.secondary)
                Picker("", selection: $editorBridge.preferredEditor) {
                    ForEach(editorBridge.installedEditors, id: \.self) { editor in
                        Label(editor.rawValue, systemImage: editor.icon).tag(editor)
                    }
                }
                .pickerStyle(.menu).font(.system(size: 11))
                .onChange(of: editorBridge.preferredEditor) { _, v in editorBridge.setPreferredEditor(v) }
            }

            Button("Detectar editores instalados") { editorBridge.detectInstalledEditors() }
                .buttonStyle(ActionChipStyle())
        }
    }

    // MARK: - Section: GPU

    var gpuSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("GPU / Stable Diffusion")
            infoCard {
                paramRow("Dispositivo", gpu.deviceName)
                paramRow("Apple Silicon", gpu.isAppleSilicon ? "Sí (MPS activo)" : "No")
                let vramMB = Double(gpu.isAppleSilicon ? gpu.ramFree : gpu.vramFree) / 1_048_576.0
                paramRow("VRAM libre", String(format: "%.0f MB", vramMB))
                paramRow("SD Base URL", sdBaseURL)
                paramRow("webui.sh", webuiScriptPath.isEmpty ? "⚠️ No configurada" : webuiScriptPath)
                paramRow("Auto-launch al iniciar", autoLaunchSD ? "✅ Activado" : "⬜ Desactivado")
            }

            // ── SD Base URL ──────────────────────────────────────────────────
            HStack(spacing: 8) {
                TextField("http://127.0.0.1:7860", text: $sdBaseURL)
                    .textFieldStyle(.plain).font(.system(size: 11, design: .monospaced)).foregroundColor(.white)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Color.white.opacity(0.06)).cornerRadius(6)
                Button("Guardar URL") { UserDefaults.standard.set(sdBaseURL, forKey: "sd.baseURL") }
                    .buttonStyle(ActionChipStyle())
            }

            // ── Ruta webui.sh ────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 6) {
                Text("Ruta a webui.sh")
                    .font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
                HStack(spacing: 8) {
                    TextField("/Users/…/stable-diffusion-webui/webui.sh", text: $webuiScriptPath)
                        .textFieldStyle(.plain).font(.system(size: 11, design: .monospaced)).foregroundColor(.white)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(Color.white.opacity(0.06)).cornerRadius(6)
                    Button("Explorar") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.shellScript, .unixExecutable]
                        panel.allowsOtherFileTypes = true
                        panel.message = "Selecciona webui.sh"
                        if panel.runModal() == .OK, let url = panel.url {
                            webuiScriptPath = url.path
                        }
                    }
                    .buttonStyle(ActionChipStyle())
                    Button("Guardar ruta") {
                        UserDefaults.standard.set(webuiScriptPath, forKey: "a1111.webuiPath")
                    }
                    .buttonStyle(ActionChipStyle(accent: true))
                    .disabled(webuiScriptPath.isEmpty)
                }
            }

            // ── Auto-launch toggle ───────────────────────────────────────────
            HStack {
                Toggle("Lanzar A1111 automáticamente al iniciar la app", isOn: $autoLaunchSD)
                    .font(.system(size: 11)).foregroundColor(.white)
                    .onChange(of: autoLaunchSD) { val in
                        UserDefaults.standard.set(val, forKey: "sandbox.autoLaunchSD")
                    }
                Spacer()
            }
            if autoLaunchSD && webuiScriptPath.isEmpty {
                Text("⚠️ Auto-launch activado pero falta la ruta a webui.sh")
                    .font(.system(size: 10)).foregroundColor(Color(hex: "#f97316"))
            }
        }
    }

    // MARK: - Section: License

    var licenseSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Model Cards y Licencias")
            Text("Cada checkpoint usado debe tener su model_card registrado en Vault/Licencias/ para publicación con compliance.")
                .font(.system(size: 11)).foregroundColor(.secondary)
            HStack(spacing: 8) {
                Button("Abrir carpeta Licencias") {
                    if let url = VaultManager.shared.licenciasURL { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(ActionChipStyle())
                Button("Generar plantillas") { LicenseVault.shared.generateAllTemplates() }
                    .buttonStyle(ActionChipStyle(accent: true))
            }
        }
    }

    // MARK: - Section: Integrity

    var integritySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Integridad del Vault")
            let im = IntegrityManager.shared
            infoCard {
                paramRow("Assets verificados", "\(im.okCount + im.corruptedCount + im.missingCount)")
                paramRow("Íntegros", "\(im.okCount)")
                paramRow("Corruptos", "\(im.corruptedCount)")
                paramRow("No encontrados", "\(im.missingCount)")
                if let lastRun = im.lastRunAt { paramRow("Último check", lastRun.shortDisplay) }
            }
            HStack(spacing: 8) {
                Button("Verificar ahora") { Task { await im.runFullVerification() } }
                    .buttonStyle(ActionChipStyle(accent: true))
                    .disabled(isVerifying)
                Button("Verificación programada") { Task { await im.runScheduledCheck() } }
                    .buttonStyle(ActionChipStyle())
            }
        }
    }

    // MARK: - Section: Audit

    var auditSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Audit Log Cifrado")
            ZeroKnowledgeLogView().frame(height: 420)
        }
    }

    // MARK: - Section: Wildcards

    var wildcardsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Wildcards")
            Text("Sintaxis __nombre__ en el prompt. Se resuelven aleatoriamente en cada generación.")
                .font(.system(size: 11)).foregroundColor(.secondary)
            let categories = WildcardEngine.shared.categories
            if categories.isEmpty {
                Text("No hay wildcards. Créalos en Vault/wildcards/").font(.system(size: 11)).foregroundColor(.secondary)
            } else {
                ForEach(categories, id: \.self) { cat in
                    HStack {
                        Text("__\(cat)__").font(.system(size: 11, design: .monospaced)).foregroundColor(Color(hex: "#7c6af7"))
                        Spacer()
                        Text("\(WildcardEngine.shared.entries(for: cat).count) entradas")
                            .font(.system(size: 10)).foregroundColor(.secondary)
                    }
                    .padding(8).background(Color.white.opacity(0.04)).cornerRadius(5)
                }
            }
            Button("Abrir carpeta Wildcards") {
                if let url = VaultManager.shared.vaultMetaURL?.appending(path: "wildcards") {
                    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(ActionChipStyle())
        }
    }


    // MARK: - Section: Pipeline (v9 NEW)

    var pipelineSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionTitle("Pipeline & Escalabilidad")

            // Retry Policy
            infoCard {
                HStack {
                    Image(systemName: "arrow.counterclockwise.circle").foregroundColor(Color(hex: "#7c6af7"))
                    Text("Retry Policy").font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                }
                Picker("Intentos máximos", selection: Binding(
                    get: { UserDefaults.standard.integer(forKey: "gen.retryMaxAttempts").nonZero(default: 3) },
                    set: { UserDefaults.standard.set($0, forKey: "gen.retryMaxAttempts") }
                )) {
                    Text("1 (sin retry)").tag(1)
                    Text("2 intentos").tag(2)
                    Text("3 intentos").tag(3)
                    Text("5 intentos").tag(5)
                }
                .pickerStyle(.segmented).font(.system(size: 10))

                Toggle("Retry en timeout", isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: "gen.retryOnTimeout") },
                    set: { UserDefaults.standard.set($0, forKey: "gen.retryOnTimeout") }
                ))
                .toggleStyle(.switch).tint(Color(hex: "#7c6af7")).font(.system(size: 11))
                Toggle("Retry en HTTP 5xx", isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: "gen.retryOn5xx") },
                    set: { UserDefaults.standard.set($0, forKey: "gen.retryOn5xx") }
                ))
                .toggleStyle(.switch).tint(Color(hex: "#7c6af7")).font(.system(size: 11))

                paramRow("Delay base", "\(UserDefaults.standard.integer(forKey: "gen.retryBaseDelayMs").nonZero(default: 1500)) ms")
            }

            // Atomic Save
            infoCard {
                HStack {
                    Image(systemName: "internaldrive.fill").foregroundColor(Color(hex: "#3de3c0"))
                    Text("Guardado Atómico").font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                }
                Toggle("Usar saveToVaultAtomic (recomendado)", isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: "gen.useAtomicSave") },
                    set: { UserDefaults.standard.set($0, forKey: "gen.useAtomicSave") }
                ))
                .toggleStyle(.switch).tint(Color(hex: "#3de3c0")).font(.system(size: 11))
                Text("Incluye esteganografía, IPTC, sidecar JSON y compliance log en cada imagen.")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }

            // Autocomplete
            infoCard {
                HStack {
                    Image(systemName: "text.magnifyingglass").foregroundColor(Color(hex: "#fbbf24"))
                    Text("Autocompletado de Prompts").font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                    Spacer()
                    if PromptAutoCompleteEngine.shared.isIndexing {
                        ProgressView().scaleEffect(0.6)
                    } else {
                        Text("\(PromptAutoCompleteEngine.shared.indexSize) tokens")
                            .font(.system(size: 10)).foregroundColor(.secondary)
                    }
                }
                Toggle("Activado", isOn: Binding(
                    get:  { PromptAutoCompleteEngine.shared.config.enabled },
                    set:  { PromptAutoCompleteEngine.shared.config.enabled = $0 }
                ))
                .toggleStyle(.switch).tint(Color(hex: "#fbbf24")).font(.system(size: 11))

                HStack(spacing: 12) {
                    Toggle("LoRAs", isOn: Binding(
                        get: { PromptAutoCompleteEngine.shared.config.includeLoRAs },
                        set: { PromptAutoCompleteEngine.shared.config.includeLoRAs = $0 }
                    )).toggleStyle(.switch).scaleEffect(0.8).tint(Color(hex: "#7c6af7"))
                    Text("LoRAs")

                    Toggle("Embeddings", isOn: Binding(
                        get: { PromptAutoCompleteEngine.shared.config.includeEmbeddings },
                        set: { PromptAutoCompleteEngine.shared.config.includeEmbeddings = $0 }
                    )).toggleStyle(.switch).scaleEffect(0.8).tint(Color(hex: "#7c6af7"))
                    Text("Embeddings")

                    Toggle("Danbooru", isOn: Binding(
                        get: { PromptAutoCompleteEngine.shared.config.includeDanbooru },
                        set: { PromptAutoCompleteEngine.shared.config.includeDanbooru = $0 }
                    )).toggleStyle(.switch).scaleEffect(0.8).tint(Color(hex: "#7c6af7"))
                    Text("Danbooru")
                }
                .font(.system(size: 10)).foregroundColor(.secondary)

                Button("Re-indexar ahora") {
                    Task {
                        _ = LoRAManager.shared.availableLoRAs.map { $0.name }
                        _ = EmbeddingsManager.shared.loaded.map { $0.name }
                        await PromptAutoCompleteEngine.shared.buildIndex()
                    }
                }
                .buttonStyle(ActionChipStyle())
            }

            // Workers
            infoCard {
                HStack {
                    Image(systemName: "cpu.fill").foregroundColor(Color(hex: "#f472b6"))
                    Text("Workers de Cola").font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                    Spacer()
                    Text("\(JobQueueManager.shared.maxConcurrent) activos")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }
                Stepper("Workers simultáneos: \(JobQueueManager.shared.maxConcurrent)",
                        value: Binding(
                            get: { JobQueueManager.shared.maxConcurrent },
                            set: { JobQueueManager.shared.maxConcurrent = $0 }
                        ), in: 1...4)
                .font(.system(size: 11)).foregroundColor(.white)
                Text("Más workers = más RAM/GPU. Recomendado ≤2 en Apple Silicon 16GB.")
                    .font(.system(size: 10)).foregroundColor(.secondary)

                paramRow("Jobs completados", "\(JobQueueManager.shared.totalCompleted)")
                paramRow("Tasa de éxito",    "\("N/A")")
                paramRow("ETA restante",     JobQueueManager.shared.estimatedRemainingLabel)
            }
        }
    }

    // MARK: - Section: ControlNet (v9 NEW)

    var controlNetSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionTitle("ControlNet")
            controlNetStatusCard
            controlNetUnitsCard
            Button("Recargar modelos desde A1111") {
                Task { await ControlNetEngine.shared.fetchModels(baseURL: UserDefaults.standard.string(forKey: "sd.baseURL") ?? "http://127.0.0.1:7860") }
            }
            .buttonStyle(ActionChipStyle())
        }
    }

    @ViewBuilder private var controlNetStatusCard: some View {
        let engine = ControlNetEngine.shared
        infoCard {
            HStack {
                Image(systemName: "network").foregroundColor(Color(hex: "#60a5fa"))
                Text("Estado ControlNet").font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { engine.isEnabled },
                    set: { engine.isEnabled = $0 }
                ))
                .toggleStyle(.switch).tint(Color(hex: "#60a5fa")).labelsHidden()
            }
            paramRow("Unidades activas",   "\(engine.activeUnits.filter { $0.enabled }.count) / \(engine.activeUnits.count)")
            paramRow("Modelos instalados", "\(engine.availableModels.count)")
            if engine.availableModels.isEmpty && engine.activeUnits.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11)).foregroundColor(Color(hex: "#f59e0b"))
                    Text("sd-webui-controlnet no detectado. Instálalo en A1111 Extensions.")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }
                .padding(8).background(Color(hex: "#f59e0b").opacity(0.08)).cornerRadius(6)
            }
            Button("Instalar sd-webui-controlnet") {
                NSWorkspace.shared.open(URL(string: "https://github.com/Mikubill/sd-webui-controlnet")!)
            }
            .buttonStyle(ActionChipStyle())
        }
    }

    @ViewBuilder private var controlNetUnitsCard: some View {
        let engine = ControlNetEngine.shared
        infoCard {
            Text("UNIDADES").font(.system(size: 9, weight: .semibold)).foregroundColor(.secondary).tracking(1)
            if engine.activeUnits.isEmpty {
                Text("Sin unidades configuradas. Añádalas desde el panel FaceID.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            } else {
                ForEach(engine.activeUnits.indices, id: \.self) { i in
                    controlNetUnitRow(engine.activeUnits[i], index: i)
                }
            }
        }
    }

    @ViewBuilder private func controlNetUnitRow(_ unit: ControlNetUnit, index i: Int) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(unit.enabled ? Color(hex: "#60a5fa") : Color.white.opacity(0.15))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text("Unidad \(i+1) · \(unit.module.rawValue)")
                    .font(.system(size: 11, weight: .medium)).foregroundColor(.white)
                Text("Modelo: \(unit.model.isEmpty ? "—" : unit.model) · W:\(String(format: "%.2f", unit.weight))")
                    .font(.system(size: 9)).foregroundColor(.secondary)
            }
            Spacer()
            Text(unit.controlMode.rawValue)
                .font(.system(size: 9)).foregroundColor(.secondary)
        }
        .padding(8).background(Color.white.opacity(0.04)).cornerRadius(6)
    }

    // MARK: - Section: Presets (v9 NEW)

    var presetsSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionTitle("Presets de Pipeline")

            let manager = ReusableSettingsManager.shared

            // Stats
            infoCard {
                HStack(spacing: 16) {
                    VStack(spacing: 2) {
                        Text("\(manager.presets.count)")
                            .font(.system(size: 20, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(hex: "#7c6af7"))
                        Text("Total").font(.system(size: 9)).foregroundColor(.secondary)
                    }
                    VStack(spacing: 2) {
                        Text("\(manager.favoriteCount)")
                            .font(.system(size: 20, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(hex: "#f59e0b"))
                        Text("Favoritos").font(.system(size: 9)).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Exportar JSON") {
                        guard let data = try? manager.exportJSON() else { return }
                        let panel = NSSavePanel()
                        panel.nameFieldStringValue = "presets_\(Int(Date().timeIntervalSince1970)).json"
                        panel.allowedContentTypes  = [.json]
                        if panel.runModal() == .OK, let url = panel.url {
                            try? data.write(to: url)
                        }
                    }
                    .buttonStyle(ActionChipStyle())

                    Button("Importar JSON") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.json]
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.urls.first,
                           let data = try? Data(contentsOf: url) {
                            try? manager.importJSON(data)
                        }
                    }
                    .buttonStyle(ActionChipStyle())
                }
            }

            // Lista compacta
            ReusableSettingsPanel { _ in }
                .frame(height: 360)
        }
    }

    // MARK: - Reusable Helpers

    func sectionTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 15, weight: .bold)).foregroundColor(.white)
    }

    func paramRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 10)).foregroundColor(.secondary)
            Spacer()
            Text(value).font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white.opacity(0.7)).lineLimit(1)
        }
    }

    func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 10)).foregroundColor(.secondary).frame(width: 120, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: range.upperBound > 10 ? "%.0f" : "%.2f", value.wrappedValue))
                .font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary).frame(width: 40)
        }
    }

    @ViewBuilder
    func infoCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .padding(12).background(Color.white.opacity(0.04)).cornerRadius(8)
    }

    // MARK: - Section: Cleanup (NEW v10)
    // ROADMAP: "Limpieza automática de artefactos" + "Inpainting de cortesía"

    var cleanupSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionTitle("Limpieza de Artefactos")

            let engine = ArtifactCleanupEngine.shared

            infoCard {
                Text("Motor de detección y reparación automática de defectos post-generación.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                Text("Usa Vision framework + inpainting dirigido vía A1111.")
                    .font(.system(size: 10)).foregroundColor(.secondary.opacity(0.7))
            }

            // Auto-run toggles
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("Activación automática").font(.system(size: 12, weight: .semibold))

                Toggle("Ejecutar después de cada generación", isOn: Binding(
                    get: { engine.config.autoRunAfterGeneration },
                    set: { engine.config.autoRunAfterGeneration = $0; saveCleanupConfig() }
                ))
                .toggleStyle(.switch)
                .font(.system(size: 12))

                Toggle("Ejecutar después de ADetailer", isOn: Binding(
                    get: { engine.config.autoRunAfterADetailer },
                    set: { engine.config.autoRunAfterADetailer = $0; saveCleanupConfig() }
                ))
                .toggleStyle(.switch)
                .font(.system(size: 12))

                Toggle("Omitir si ADetailer ya procesó la imagen", isOn: Binding(
                    get: { engine.config.skipIfADetailerRan },
                    set: { engine.config.skipIfADetailerRan = $0; saveCleanupConfig() }
                ))
                .toggleStyle(.switch)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            }

            Divider().background(Color.white.opacity(0.07))

            // Repair targets
            VStack(alignment: .leading, spacing: 12) {
                Text("OBJETIVOS DE REPARACIÓN")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)

                Toggle("Reparar manos malformadas", isOn: Binding(
                    get: { engine.config.repairHands },
                    set: { engine.config.repairHands = $0; saveCleanupConfig() }
                ))
                .toggleStyle(.switch).font(.system(size: 12))

                Toggle("Reparar rostros (complemento ADetailer)", isOn: Binding(
                    get: { engine.config.repairFaces },
                    set: { engine.config.repairFaces = $0; saveCleanupConfig() }
                ))
                .toggleStyle(.switch).font(.system(size: 12))

                Toggle("Reparar tangencias de ropa / inpainting cortesía", isOn: Binding(
                    get: { engine.config.repairTangencies },
                    set: { engine.config.repairTangencies = $0; saveCleanupConfig() }
                ))
                .toggleStyle(.switch).font(.system(size: 12))

                Toggle("Limpiar ruido de fondo", isOn: Binding(
                    get: { engine.config.repairBackground },
                    set: { engine.config.repairBackground = $0; saveCleanupConfig() }
                ))
                .toggleStyle(.switch).font(.system(size: 12))
            }

            Divider().background(Color.white.opacity(0.07))

            // Fine-tune params
            VStack(alignment: .leading, spacing: 10) {
                Text("PARÁMETROS DE INPAINTING")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)

                sliderRow("Denoising", value: Binding(
                    get: { engine.config.inpaintingDenoising },
                    set: { engine.config.inpaintingDenoising = $0; saveCleanupConfig() }
                ), range: 0.1...0.9)

                HStack {
                    Text("Pasos").font(.system(size: 10)).foregroundColor(.secondary)
                    Spacer()
                    Stepper("\(engine.config.inpaintingSteps)", value: Binding(
                        get: { engine.config.inpaintingSteps },
                        set: { engine.config.inpaintingSteps = $0; saveCleanupConfig() }
                    ), in: 10...50)
                    .font(.system(size: 11))
                }

                HStack {
                    Text("Pasadas máximas").font(.system(size: 10)).foregroundColor(.secondary)
                    Spacer()
                    Stepper("\(engine.config.maxRepairPasses)", value: Binding(
                        get: { engine.config.maxRepairPasses },
                        set: { engine.config.maxRepairPasses = $0; saveCleanupConfig() }
                    ), in: 1...5)
                    .font(.system(size: 11))
                }
            }
        }
    }

    private func saveCleanupConfig() {
        let data = try? JSONEncoder().encode(ArtifactCleanupEngine.shared.config)
        UserDefaults.standard.set(data, forKey: "cleanup.config")
    }

// MARK: - ActionChipStyle

struct ActionChipStyle: ButtonStyle {
    var accent: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11))
            .foregroundColor(accent ? .white : Color(hex: "#7c6af7"))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(accent
                ? Color(hex: "#7c6af7").opacity(configuration.isPressed ? 0.9 : 1.0)
                : Color(hex: "#7c6af7").opacity(configuration.isPressed ? 0.15 : 0.1))
            .cornerRadius(6)
    }
}
}

// MARK: - Compat extensions

extension Double {
    func nonZero(default defaultValue: Double) -> Double { self == 0 ? defaultValue : self }
}

extension BackupManager {
    func openRcloneConfig() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", "Terminal", "--args", "rclone config"]
        try? task.run()
    }
}

extension WildcardEngine {
    var categories: [String] { allKeys }
    func entries(for category: String) -> [String] { terms(for: category) }
}

extension Int {
    func nonZero(default value: Int) -> Int { self == 0 ? value : self }
}



