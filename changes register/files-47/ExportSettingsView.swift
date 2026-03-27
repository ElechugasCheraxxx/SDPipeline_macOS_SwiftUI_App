import SwiftUI
import AppKit

// MARK: - ExportSettingsView
//
// Panel completo de configuración de export, insertable en SettingsView
// o como sheet independiente.
//
// Secciones:
//   1. Formato de salida (JPEG/PNG/WebP + calidad)
//   2. Watermark (texto, posición, opacidad, fuente)
//   3. OnlyFans Set Export (handle, naming, compliance)
//   4. Batch export (concurrencia, retries)
//   5. Destinos (directorios de clean/preview/sets)

struct ExportSettingsView: View {

    @ObservedObject private var exportEngine   = ExportEngine.shared
    @ObservedObject private var setExporter    = OnlyFansSetExporter.shared
    @ObservedObject private var batchCoord     = ExportBatchCoordinator.shared

    @State private var selectedTab: ExportTab  = .format
    @State private var showDirPicker: Bool     = false
    @State private var pickerTarget: DirTarget = .clean

    enum ExportTab: String, CaseIterable {
        case format    = "Formato"
        case watermark = "Watermark"
        case sets      = "Sets OF"
        case batch     = "Lote"

        var icon: String {
            switch self {
            case .format:    return "doc.badge.gearshape"
            case .watermark: return "pencil.and.outline"
            case .sets:      return "rectangle.stack.fill.badge.plus"
            case .batch:     return "square.stack.3d.up"
            }
        }
    }

    enum DirTarget { case clean, preview, sets }

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            HStack(spacing: 4) {
                ForEach(ExportTab.allCases, id: \.self) { tab in
                    tabButton(tab)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider().background(Color.white.opacity(0.07))

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch selectedTab {
                    case .format:    formatSection
                    case .watermark: watermarkSection
                    case .sets:      setsSection
                    case .batch:     batchSection
                    }
                }
                .padding(18)
            }
        }
        .frame(minWidth: 460, minHeight: 420)
    }

    // MARK: - Tab Button

    func tabButton(_ tab: ExportTab) -> some View {
        let isSelected = selectedTab == tab
        return Button(action: { selectedTab = tab }) {
            HStack(spacing: 5) {
                Image(systemName: tab.icon).font(.system(size: 11))
                Text(tab.rawValue).font(.system(size: 11, weight: isSelected ? .semibold : .regular))
            }
            .foregroundColor(isSelected ? .white : .secondary)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(isSelected ? Color(hex: "#7c6af7").opacity(0.25) : Color.clear)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Format Section

    var formatSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsGroup("Formato de imagen") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        ForEach(OnlyFansSetExporter.SetExportConfig.OutputFormat.allCases, id: \.self) { fmt in
                            formatChip(fmt)
                        }
                    }

                    if setExporter.config.outputFormat != .png {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Calidad JPEG/WebP")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("\(Int(setExporter.config.jpegQuality * 100))%")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.white)
                                    .monospacedDigit()
                            }
                            Slider(value: $setExporter.config.jpegQuality, in: 0.6...1.0, step: 0.01)
                                .accentColor(Color(hex: "#7c6af7"))
                        }
                    }
                }
            }

            settingsGroup("Thumbnails") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: $setExporter.config.generateThumbnails) {
                        settingsLabel("Generar thumbnails", sub: "400×600 px para catálogo")
                    }
                    .toggleStyle(.switch)

                    if setExporter.config.generateThumbnails {
                        HStack {
                            Text("Dimensión máxima").font(.system(size: 11)).foregroundColor(.secondary)
                            Spacer()
                            Picker("", selection: $setExporter.config.thumbnailMaxDim) {
                                Text("400px").tag(400)
                                Text("600px").tag(600)
                                Text("800px").tag(800)
                                Text("1024px").tag(1024)
                            }
                            .pickerStyle(.menu)
                            .font(.system(size: 11))
                            .frame(width: 90)
                        }
                    }
                }
            }

            settingsGroup("EXIF / Metadatos") {
                VStack(alignment: .leading, spacing: 8) {
                    infoRow(icon: "checkmark.shield.fill", color: Color(hex: "#3de3c0"),
                            text: "EXIF Scrubbing activo",
                            sub: "Todos los metadatos SD eliminados en exports limpios")
                    infoRow(icon: "checkmark.shield.fill", color: Color(hex: "#3de3c0"),
                            text: "Chunks tEXt/iTXt eliminados",
                            sub: "Los prompts/seeds de A1111 no aparecen en el PNG final")
                    infoRow(icon: "info.circle", color: Color(hex: "#7c6af7"),
                            text: "IPTC/XMP se agregan a versión limpia",
                            sub: "Autoría y copyright para DAM")
                }
            }
        }
    }

    func formatChip(_ fmt: OnlyFansSetExporter.SetExportConfig.OutputFormat) -> some View {
        let isSelected = setExporter.config.outputFormat == fmt
        return Button(action: { setExporter.config.outputFormat = fmt }) {
            Text(fmt.rawValue)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? .white : .secondary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(isSelected ? Color(hex: "#7c6af7") : Color.white.opacity(0.06))
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Watermark Section

    var watermarkSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsGroup("Watermark de preview") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(isOn: $setExporter.config.includeWatermark) {
                        settingsLabel("Watermark en previews", sub: "Solo en versión de redes/teasers")
                    }
                    .toggleStyle(.switch)

                    if setExporter.config.includeWatermark {
                        fieldRow(label: "Texto", placeholder: "@tuhandle") {
                            TextField("@tuhandle", text: $setExporter.config.watermarkText)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Opacidad").font(.system(size: 11)).foregroundColor(.secondary)
                                Spacer()
                                Text("\(Int(exportEngine.watermarkConfig.opacity * 100))%")
                                    .font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
                                    .monospacedDigit()
                            }
                            Slider(value: $exportEngine.watermarkConfig.opacity, in: 0.1...0.9, step: 0.05)
                                .accentColor(Color(hex: "#7c6af7"))
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("POSICIÓN").font(.system(size: 9, weight: .semibold)).foregroundColor(.secondary).tracking(1)
                            HStack(spacing: 6) {
                                ForEach(ExportEngine.WatermarkConfig.Position.allCases, id: \.self) { pos in
                                    positionButton(pos)
                                }
                            }
                        }
                    }
                }
            }

            settingsGroup("Preview de watermark") {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.04))
                        .frame(height: 120)
                    Text("Imagen de muestra")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                    VStack {
                        Spacer()
                        HStack {
                            if exportEngine.watermarkConfig.position == .bottomLeft ||
                               exportEngine.watermarkConfig.position == .topLeft { Spacer(minLength: 0) }
                            Text(setExporter.config.watermarkText)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white.opacity(exportEngine.watermarkConfig.opacity))
                                .shadow(color: .black.opacity(0.5), radius: 1)
                                .padding(10)
                            if exportEngine.watermarkConfig.position == .bottomRight ||
                               exportEngine.watermarkConfig.position == .topRight { Spacer(minLength: 0) }
                        }
                        if exportEngine.watermarkConfig.position == .bottomLeft ||
                           exportEngine.watermarkConfig.position == .bottomRight { Spacer(minLength: 0) }
                    }
                    .frame(height: 120)
                }
            }
        }
    }

    func positionButton(_ pos: ExportEngine.WatermarkConfig.Position) -> some View {
        let isSelected = exportEngine.watermarkConfig.position == pos
        return Button(action: { exportEngine.watermarkConfig.position = pos }) {
            Text(pos.label)
                .font(.system(size: 9))
                .foregroundColor(isSelected ? .white : .secondary)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(isSelected ? Color(hex: "#7c6af7") : Color.white.opacity(0.06))
                .cornerRadius(5)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Sets Section

    var setsSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsGroup("Identidad del creador") {
                VStack(alignment: .leading, spacing: 10) {
                    fieldRow(label: "Handle", placeholder: "@tuusuario") {
                        TextField("@tuusuario", text: $setExporter.config.creatorHandle)
                    }
                }
            }

            settingsGroup("Nomenclatura de archivos") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(OnlyFansSetExporter.SetExportConfig.NamingConvention.allCases, id: \.self) { conv in
                        namingOption(conv)
                    }
                    Text("Ejemplo: \(namingExample)")
                        .font(.system(size: 9)).foregroundColor(.secondary)
                        .padding(.top, 4)
                }
            }

            settingsGroup("Compliance") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $setExporter.config.requireCompliance) {
                        settingsLabel("Gate de compliance obligatorio",
                                      sub: "Bloquea export si hay violaciones críticas")
                    }
                    .toggleStyle(.switch)

                    Toggle(isOn: $setExporter.config.includeManifest) {
                        settingsLabel("Incluir manifest.json",
                                      sub: "Metadatos completos del set")
                    }
                    .toggleStyle(.switch)

                    Toggle(isOn: $setExporter.config.zipOutput) {
                        settingsLabel("Comprimir en ZIP",
                                      sub: "Un archivo .zip por set listo para subir")
                    }
                    .toggleStyle(.switch)
                }
            }
        }
    }

    var namingExample: String {
        let handle = setExporter.config.creatorHandle.trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        switch setExporter.config.namingConvention {
        case .standard:   return "\(handle)_20250615_set_verano_001.jpg"
        case .sequential: return "set_001.jpg"
        case .uuid:       return "f47ac10b-58cc-4372-a567-001.jpg"
        }
    }

    func namingOption(_ conv: OnlyFansSetExporter.SetExportConfig.NamingConvention) -> some View {
        let isSelected = setExporter.config.namingConvention == conv
        return Button(action: { setExporter.config.namingConvention = conv }) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isSelected ? Color(hex: "#7c6af7") : Color.white.opacity(0.2))
                    .frame(width: 10, height: 10)
                Text(conv.rawValue)
                    .font(.system(size: 11))
                    .foregroundColor(isSelected ? .white : .secondary)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Batch Section

    var batchSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsGroup("Concurrencia") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Exports paralelos").font(.system(size: 11)).foregroundColor(.secondary)
                        Spacer()
                        Picker("", selection: $batchCoord.config.maxConcurrency) {
                            Text("1 (secuencial)").tag(1)
                            Text("2 (recomendado)").tag(2)
                            Text("4").tag(4)
                        }
                        .pickerStyle(.menu)
                        .frame(width: 130)
                    }
                    Text("Con 2 paralelos y 20 imágenes: ~50% más rápido que secuencial")
                        .font(.system(size: 9)).foregroundColor(.secondary)
                }
            }

            settingsGroup("Reintentos") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Intentos máximos").font(.system(size: 11)).foregroundColor(.secondary)
                        Spacer()
                        Stepper("\(batchCoord.config.maxRetries)", value: $batchCoord.config.maxRetries, in: 0...5)
                            .frame(width: 120)
                    }
                    Toggle(isOn: $batchCoord.config.stopOnError) {
                        settingsLabel("Parar en primer error",
                                      sub: "Por defecto continúa y reporta al final")
                    }
                    .toggleStyle(.switch)
                }
            }

            settingsGroup("Notificaciones") {
                Toggle(isOn: $batchCoord.config.notifyOnComplete) {
                    settingsLabel("Notificación al completar",
                                  sub: "Alerta macOS cuando el lote termina")
                }
                .toggleStyle(.switch)
            }
        }
    }

    // MARK: - Reusable Components

    func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.secondary)
                .tracking(1.0)
            content()
                .padding(12)
                .background(Color.white.opacity(0.04))
                .cornerRadius(8)
        }
    }

    func settingsLabel(_ title: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11)).foregroundColor(.white)
            Text(sub).font(.system(size: 9)).foregroundColor(.secondary)
        }
    }

    func fieldRow<Content: View>(label: String, placeholder: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundColor(.secondary).tracking(1)
            content()
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(.white)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(Color.white.opacity(0.06))
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.1), lineWidth: 1))
        }
    }

    func infoRow(icon: String, color: Color, text: String, sub: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).font(.system(size: 11)).foregroundColor(color).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(text).font(.system(size: 11)).foregroundColor(.white)
                Text(sub).font(.system(size: 9)).foregroundColor(.secondary)
            }
        }
    }
}

// WatermarkConfig.Position CaseIterable + label defined in ExportEngine

// MARK: - WatermarkConfig.Position display label

extension ExportEngine.WatermarkConfig.Position {
    var label: String {
        switch self {
        case .topLeft:     return "↖ Sup-Izq"
        case .topRight:    return "↗ Sup-Der"
        case .bottomLeft:  return "↙ Inf-Izq"
        case .bottomRight: return "↘ Inf-Der"
        case .center:      return "⊙ Centro"
        }
    }
}
