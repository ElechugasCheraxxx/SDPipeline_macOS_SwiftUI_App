import SwiftUI
import Foundation
import AppKit
import Combine

// MARK: - SetupAssistantView
//
// Asistente de configuración para instalar y verificar extensiones A1111.
// Cubre la sección 🟠 SECCIÓN 9 — Hardware/Software:
//   - sd-webui-controlnet
//   - ADetailer
//   - ESRGAN models (R-ESRGAN 4x+, R-ESRGAN 4x+ Anime6B)
//   - Ultimate SD Upscale
//   - IC-Light (relight cinematográfico)
//   - sd-webui-supermerger (opcional)
//
// También verifica el estado de A1111 y guía la configuración inicial.

// MARK: - Extension Item Models

struct A1111Extension: Identifiable {
    let id:          UUID   = UUID()
    let name:        String
    let description: String
    let category:    Category
    let repoURL:     String
    let installURL:  String     // URL directa para Extensions tab de A1111
    let verifyPath:  String     // endpoint A1111 para verificar instalación
    let docURL:      String
    let priority:    Priority
    let notes:       [String]

    var installGitCommand: String {
        "cd extensions && git clone \(repoURL)"
    }

    enum Category: String, CaseIterable {
        case essential   = "Esenciales"
        case upscaling   = "Upscaling"
        case refinement  = "Refinamiento"
        case workflow    = "Flujo de Trabajo"
        case optional    = "Opcionales"

        var icon: String {
            switch self {
            case .essential:  return "star.fill"
            case .upscaling:  return "arrow.up.left.and.arrow.down.right"
            case .refinement: return "wand.and.stars"
            case .workflow:   return "gearshape.2.fill"
            case .optional:   return "plus.circle"
            }
        }

        var color: String {
            switch self {
            case .essential:  return "#ef4444"
            case .upscaling:  return "#3de3c0"
            case .refinement: return "#f472b6"
            case .workflow:   return "#7c6af7"
            case .optional:   return "#8b8b8b"
            }
        }
    }

    enum Priority: Int, Comparable {
        case critical = 0
        case high     = 1
        case medium   = 2
        case low      = 3

        static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    // Catalog
    static let catalog: [A1111Extension] = [
        A1111Extension(
            name: "ControlNet",
            description: "Control de composición, pose, profundidad e identidad facial. Esencial para consistencia de personajes.",
            category: .essential,
            repoURL: "https://github.com/Mikubill/sd-webui-controlnet",
            installURL: "https://github.com/Mikubill/sd-webui-controlnet",
            verifyPath: "/controlnet/version",
            docURL: "https://github.com/Mikubill/sd-webui-controlnet/wiki",
            priority: .critical,
            notes: [
                "Instalar desde Extensions → Install from URL",
                "Después de instalar, reiniciar la WebUI",
                "Descargar modelos ControlNet por separado (ver enlace abajo)",
                "Modelos van en models/ControlNet/ en el directorio de A1111"
            ]
        ),
        A1111Extension(
            name: "ADetailer",
            description: "Refinamiento automático de caras y manos post-generación. Elimina artefactos faciales sin esfuerzo manual.",
            category: .essential,
            repoURL: "https://github.com/Bing-su/adetailer",
            installURL: "https://github.com/Bing-su/adetailer",
            verifyPath: "/sdapi/v1/scripts",
            docURL: "https://github.com/Bing-su/adetailer#readme",
            priority: .critical,
            notes: [
                "Instalar desde Extensions → Install from URL",
                "Los modelos YOLOv8 se descargan automáticamente en primer uso",
                "MediaPipe face_full es el modo más preciso",
                "Soporta hasta 5 unidades simultáneas (cara + manos + cuerpo)"
            ]
        ),
        A1111Extension(
            name: "Ultimate SD Upscale",
            description: "Upscaling por tiles con alta calidad. Permite escalar imágenes grandes sin out-of-memory.",
            category: .upscaling,
            repoURL: "https://github.com/Coyote-A/ultimate-upscale-for-automatic1111",
            installURL: "https://github.com/Coyote-A/ultimate-upscale-for-automatic1111",
            verifyPath: "/sdapi/v1/scripts",
            docURL: "https://github.com/Coyote-A/ultimate-upscale-for-automatic1111#readme",
            priority: .high,
            notes: [
                "Usar con ControlNet Tile para mejor detalle",
                "Tile Size recomendado: 512 para SD 1.5, 1024 para SDXL",
                "Seam Fix: Half tile offsets produce mejores resultados"
            ]
        ),
        A1111Extension(
            name: "IC-Light",
            description: "Relight cinemático con IA. Relumina imágenes existentes con nuevas fuentes de luz de manera convincente.",
            category: .workflow,
            repoURL: "https://github.com/lllyasviel/IC-Light",
            installURL: "https://github.com/huchenlei/sd-webui-ic-light",
            verifyPath: "/sdapi/v1/scripts",
            docURL: "https://github.com/lllyasviel/IC-Light",
            priority: .medium,
            notes: [
                "Instalar versión WebUI: sd-webui-ic-light por huchenlei",
                "Requiere modelos IC-Light descargados por separado",
                "Ideal para añadir iluminación dramática a retratos existentes",
                "Compatible con Apple Silicon (MPS)"
            ]
        ),
        A1111Extension(
            name: "SD WebUI Supermerger",
            description: "Merge de checkpoints in-browser. Permite crear modelos híbridos sin línea de comandos.",
            category: .optional,
            repoURL: "https://github.com/hako-mikan/sd-webui-supermerger",
            installURL: "https://github.com/hako-mikan/sd-webui-supermerger",
            verifyPath: "/sdapi/v1/scripts",
            docURL: "https://github.com/hako-mikan/sd-webui-supermerger#readme",
            priority: .low,
            notes: [
                "Soporta checkpoint merging sin línea de comandos",
                "Útil para combinar checkpoints base con LoRAs embebidos"
            ]
        ),
        A1111Extension(
            name: "Civitai Browser Plus",
            description: "Navega, descarga y gestiona modelos de CivitAI directamente desde A1111.",
            category: .optional,
            repoURL: "https://github.com/BlafKing/sd-civitai-browser-plus",
            installURL: "https://github.com/BlafKing/sd-civitai-browser-plus",
            verifyPath: "/sdapi/v1/scripts",
            docURL: "https://github.com/BlafKing/sd-civitai-browser-plus#readme",
            priority: .low,
            notes: [
                "Requiere API key de CivitAI para descarga directa",
                "Permite previsualizar imágenes de modelos antes de descargar"
            ]
        )
    ]
}

// MARK: - ESRGAN Model Catalog

struct ESRGANModel: Identifiable {
    let id:          UUID = UUID()
    let name:        String
    let description: String
    let downloadURL: String
    let targetPath:  String
    let sizeMB:      Int
    let bestFor:     String

    static let recommended: [ESRGANModel] = [
        ESRGANModel(
            name: "R-ESRGAN 4x+",
            description: "Modelo general de alta calidad. Mejor para fotografía realista y retratos.",
            downloadURL: "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesrgan-ncnn-vulkan-20220424-macos.zip",
            targetPath: "models/ESRGAN/R-ESRGAN 4x+.pth",
            sizeMB: 67,
            bestFor: "Fotografía realista, retratos"
        ),
        ESRGANModel(
            name: "R-ESRGAN 4x+ Anime6B",
            description: "Versión optimizada para ilustraciones. Menos ringing que el modelo general.",
            downloadURL: "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.2.4/RealESRGAN_x4plus_anime_6B.pth",
            targetPath: "models/ESRGAN/RealESRGAN_x4plus_anime_6B.pth",
            sizeMB: 18,
            bestFor: "Anime, ilustraciones, arte digital"
        ),
        ESRGANModel(
            name: "ESRGAN 4x (original)",
            description: "Modelo original. Más detalles pero más artefactos. Útil para imágenes de baja resolución.",
            downloadURL: "https://github.com/xinntao/ESRGAN/releases/download/v0.1.1/RRDB_ESRGAN_x4.pth",
            targetPath: "models/ESRGAN/ESRGAN_4x.pth",
            sizeMB: 64,
            bestFor: "Imágenes con poca resolución origen"
        )
    ]
}

// MARK: - Setup State

@MainActor
final class SetupAssistantState: ObservableObject {
    static let shared = SetupAssistantState()
    private init() {}

    @Published var extensionStatus: [String: ExtStatus] = [:]
    @Published var isCheckingAll: Bool = false

    enum ExtStatus {
        case unknown
        case installed
        case notInstalled
        case checking
    }

    func statusIcon(_ name: String) -> (String, Color) {
        switch extensionStatus[name] {
        case .installed:    return ("checkmark.circle.fill", Color(hex: "#34d399"))
        case .notInstalled: return ("xmark.circle.fill", Color(hex: "#ef4444"))
        case .checking:     return ("arrow.clockwise", .secondary)
        default:            return ("questionmark.circle", .secondary)
        }
    }

    func checkAll(baseURL: String) async {
        isCheckingAll = true
        defer { isCheckingAll = false }

        for ext in A1111Extension.catalog where ext.priority == .critical || ext.priority == .high {
            extensionStatus[ext.name] = .checking
            let installed = await checkExtension(ext, baseURL: baseURL)
            extensionStatus[ext.name] = installed ? .installed : .notInstalled
        }
    }

    private func checkExtension(_ ext: A1111Extension, baseURL: String) async -> Bool {
        guard let url = URL(string: "\(baseURL)\(ext.verifyPath)") else { return false }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return false }

        if ext.verifyPath == "/controlnet/version" {
            return (try? JSONDecoder().decode(ControlNetVersionResponse.self, from: data)) != nil
        }

        if ext.verifyPath == "/sdapi/v1/scripts",
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let txt2img = json["txt2img"] as? [String] {
            let nameKeyword = ext.name.lowercased().replacingOccurrences(of: " ", with: "")
            return txt2img.contains { $0.lowercased().replacingOccurrences(of: " ", with: "").contains(nameKeyword) }
        }

        return false
    }
}

// MARK: - SetupAssistantView

struct SetupAssistantView: View {

    @StateObject private var state = SetupAssistantState.shared
    @State private var activeSection: Section = .overview
    @State private var baseURL: String = "http://127.0.0.1:7860"
    @State private var selectedExt: A1111Extension? = nil
    @State private var selectedCategory: A1111Extension.Category? = nil

    enum Section: String, CaseIterable {
        case overview   = "Resumen"
        case extensions = "Extensiones"
        case models     = "Modelos ESRGAN"
        case controlnet = "Modelos ControlNet"
        case checklist  = "Checklist Final"

        var icon: String {
            switch self {
            case .overview:   return "house.fill"
            case .extensions: return "puzzlepiece.fill"
            case .models:     return "arrow.up.left.and.arrow.down.right"
            case .controlnet: return "cpu.fill"
            case .checklist:  return "checkmark.seal.fill"
            }
        }
    }

    var filteredExtensions: [A1111Extension] {
        if let cat = selectedCategory {
            return A1111Extension.catalog.filter { $0.category == cat }
        }
        return A1111Extension.catalog
    }

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 160, maxWidth: 180)
            mainContent
                .frame(minWidth: 480)
        }
        .frame(minWidth: 680, minHeight: 540)
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
    }

    // MARK: - Sidebar

    var sidebar: some View {
        VStack(spacing: 2) {
            // A1111 URL
            VStack(alignment: .leading, spacing: 4) {
                Text("URL DE A1111")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                TextField("http://127.0.0.1:7860", text: $baseURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10))
                Button(action: {
                    Task { await state.checkAll(baseURL: baseURL) }
                }) {
                    HStack {
                        if state.isCheckingAll { ProgressView().controlSize(.mini) }
                        Text(state.isCheckingAll ? "Verificando…" : "Verificar todo")
                            .font(.system(size: 10))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(hex: "#7c6af7"))
                .controlSize(.small)
                .disabled(state.isCheckingAll)
            }
            .padding(.horizontal, 10).padding(.vertical, 10)

            Divider().background(Color.white.opacity(0.07))

            ForEach(Section.allCases, id: \.self) { section in
                Button(action: { activeSection = section }) {
                    HStack(spacing: 8) {
                        Image(systemName: section.icon)
                            .font(.system(size: 11))
                            .frame(width: 14)
                            .foregroundColor(activeSection == section ? Color(hex: "#7c6af7") : .secondary)
                        Text(section.rawValue)
                            .font(.system(size: 11, weight: activeSection == section ? .semibold : .regular))
                            .foregroundColor(activeSection == section ? .white : .secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(activeSection == section ? Color.white.opacity(0.07) : Color.clear)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            // Status summary
            if !state.extensionStatus.isEmpty {
                Divider().background(Color.white.opacity(0.07))
                VStack(alignment: .leading, spacing: 4) {
                    let installed = state.extensionStatus.values.filter { $0 == .installed }.count
                    let total     = state.extensionStatus.count
                    Text("\(installed)/\(total) instalados")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(installed == total ? Color(hex: "#34d399") : Color(hex: "#f59e0b"))
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
            }
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
    }

    // MARK: - Main Content

    @ViewBuilder
    var mainContent: some View {
        switch activeSection {
        case .overview:   overviewSection
        case .extensions: extensionsSection
        case .models:     esrganSection
        case .controlnet: controlnetModelsSection
        case .checklist:  checklistSection
        }
    }

    // MARK: - Overview

    var overviewSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                sectionTitle("Bienvenido al Asistente de Configuración", icon: "house.fill")

                Text("SDPipelineStudio requiere Automatic1111 WebUI con ciertas extensiones para funcionar al máximo. Este asistente te guía para instalar todo lo necesario.")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.8))
                    .lineSpacing(4)

                // Prerequisites
                VStack(alignment: .leading, spacing: 8) {
                    Text("REQUISITOS PREVIOS")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)

                    prereqItem("Automatic1111 WebUI instalado y corriendo", icon: "checkmark.circle")
                    prereqItem("Python 3.10+ y git instalados", icon: "checkmark.circle")
                    prereqItem("Al menos un checkpoint SD descargado", icon: "checkmark.circle")
                    prereqItem("macOS 13+ (Apple Silicon recomendado)", icon: "checkmark.circle")
                }
                .padding(12)
                .background(Color.white.opacity(0.04))
                .cornerRadius(8)

                // Quick install order
                VStack(alignment: .leading, spacing: 8) {
                    Text("ORDEN DE INSTALACIÓN RECOMENDADO")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)

                    installOrderRow(1, "ControlNet",          "Consistencia de personajes y composición")
                    installOrderRow(2, "ADetailer",           "Refinamiento automático de caras/manos")
                    installOrderRow(3, "Ultimate SD Upscale", "Upscaling de alta calidad por tiles")
                    installOrderRow(4, "ESRGAN Models",       "Descarga los modelos de upscaling")
                    installOrderRow(5, "ControlNet Models",   "Descarga modelos Canny, Depth, OpenPose, IP-Adapter")
                    installOrderRow(6, "IC-Light",            "Relight cinematográfico (opcional)")
                }
                .padding(12)
                .background(Color.white.opacity(0.04))
                .cornerRadius(8)

                // A1111 install path note
                infoBox(
                    icon: "info.circle.fill",
                    color: "#3de3c0",
                    title: "¿Dónde instalar extensiones?",
                    body: "En A1111 WebUI, ve a Extensions → Install from URL, pega la URL del repositorio y haz click en Install. Reinicia la WebUI después de cada extensión."
                )
            }
            .padding(20)
        }
        .background(Color(red: 0.08, green: 0.08, blue: 0.10))
    }

    // MARK: - Extensions Section

    var extensionsSection: some View {
        VStack(spacing: 0) {
            // Category filter
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    extFilterChip("Todas", selected: selectedCategory == nil) { selectedCategory = nil }
                    ForEach(A1111Extension.Category.allCases, id: \.self) { cat in
                        extFilterChip(cat.rawValue, selected: selectedCategory == cat) {
                            selectedCategory = selectedCategory == cat ? nil : cat
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
            }

            Divider().background(Color.white.opacity(0.07))

            List(filteredExtensions) { ext in
                ExtensionRow(
                    ext:    ext,
                    status: state.extensionStatus[ext.name] ?? .unknown,
                    onSelect: { selectedExt = ext }
                )
            }
            .listStyle(.plain)
        }
        .background(Color(red: 0.08, green: 0.08, blue: 0.10))
        .sheet(item: $selectedExt) { ext in
            ExtensionDetailSheet(ext: ext, baseURL: baseURL)
        }
    }

    // MARK: - ESRGAN Section

    var esrganSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                sectionTitle("Modelos ESRGAN de Upscaling", icon: "arrow.up.left.and.arrow.down.right")

                Text("Descarga estos modelos y colócalos en la carpeta models/ESRGAN/ de tu instalación de A1111.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                ForEach(ESRGANModel.recommended) { model in
                    ESRGANModelCard(model: model)
                }

                infoBox(
                    icon: "folder.fill",
                    color: "#f59e0b",
                    title: "Ruta de instalación",
                    body: "stable-diffusion-webui/models/ESRGAN/\n\nDespués de copiar los archivos .pth, ve a Settings → Upscaling en A1111 para verificar que aparecen en el dropdown."
                )
            }
            .padding(20)
        }
        .background(Color(red: 0.08, green: 0.08, blue: 0.10))
    }

    // MARK: - ControlNet Models Section

    var controlnetModelsSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                sectionTitle("Modelos ControlNet", icon: "cpu.fill")

                Text("Descarga los modelos ControlNet y colócalos en models/ControlNet/ en tu instalación de A1111.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                Text("MODELOS ESENCIALES")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)

                ForEach(controlnetModels, id: \.name) { model in
                    cnModelCard(model)
                }

                infoBox(
                    icon: "link",
                    color: "#7c6af7",
                    title: "Fuente recomendada",
                    body: "HuggingFace: lllyasviel/ControlNet-v1-1\nIP-Adapter: h94/IP-Adapter\n\nDescarga solo los modelos .safetensors (no los .yaml ni .bin) para ahorrar espacio."
                )
            }
            .padding(20)
        }
        .background(Color(red: 0.08, green: 0.08, blue: 0.10))
    }

    var controlnetModels: [(name: String, file: String, size: String, use: String)] {
        [
            ("Canny",       "control_v11p_sd15_canny.safetensors",        "1.4 GB", "Detección de bordes, estructura"),
            ("Depth",       "control_v11f1p_sd15_depth.safetensors",       "1.4 GB", "Composición 3D, profundidad"),
            ("OpenPose",    "control_v11p_sd15_openpose.safetensors",      "1.4 GB", "Control de pose corporal"),
            ("SoftEdge",    "control_v11p_sd15_softedge.safetensors",      "1.4 GB", "Bordes suaves, estilo"),
            ("Lineart",     "control_v11p_sd15_lineart.safetensors",       "1.4 GB", "Arte lineal, manga"),
            ("Tile",        "control_v11f1e_sd15_tile.safetensors",        "1.4 GB", "Upscale con detalle"),
            ("IP-Adapter",  "ip-adapter_sd15.safetensors",                 "0.3 GB", "Consistencia de estilo"),
            ("IP-Adapter FaceID", "ip-adapter-faceid_sd15.bin",            "0.5 GB", "Consistencia facial"),
        ]
    }

    // MARK: - Checklist Section

    var checklistSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                sectionTitle("Checklist de Configuración Final", icon: "checkmark.seal.fill")

                Text("Verifica que cada punto esté completo antes de usar SDPipelineStudio al máximo.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                checkGroup("A1111 WebUI", items: [
                    "A1111 instalado y corriendo en http://127.0.0.1:7860",
                    "API habilitada (--api flag en argumentos de inicio)",
                    "Al menos un checkpoint SD 1.5 descargado",
                    "CLIP Interrogator habilitado (opcional)"
                ])

                checkGroup("Extensiones Críticas", items: [
                    "sd-webui-controlnet instalado y activado",
                    "adetailer instalado y activado",
                    "ultimate-upscale instalado",
                    "Todas las extensiones actualizadas"
                ])

                checkGroup("Modelos ControlNet (mínimo)", items: [
                    "control_v11p_sd15_canny.safetensors",
                    "control_v11f1p_sd15_depth.safetensors",
                    "control_v11p_sd15_openpose.safetensors",
                    "ip-adapter_sd15.safetensors"
                ])

                checkGroup("Modelos ESRGAN", items: [
                    "R-ESRGAN 4x+ descargado",
                    "R-ESRGAN 4x+ Anime6B descargado (opcional)"
                ])

                checkGroup("SDPipelineStudio", items: [
                    "Vault configurado en disco local",
                    "Proyecto activo creado",
                    "Watermark configurado en Settings",
                    "IPTC/XMP creator info configurado"
                ])

                infoBox(
                    icon: "checkmark.seal.fill",
                    color: "#34d399",
                    title: "¿Todo listo?",
                    body: "Una vez completados estos pasos, SDPipelineStudio tendrá acceso completo a todas las funciones: ControlNet para consistencia de personajes, ADetailer para refinamiento facial, y upscaling de alta calidad."
                )
            }
            .padding(20)
        }
        .background(Color(red: 0.08, green: 0.08, blue: 0.10))
    }

    // MARK: - Helper Views

    func sectionTitle(_ title: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(Color(hex: "#7c6af7"))
            Text(title)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
        }
    }

    func prereqItem(_ text: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#34d399"))
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.8))
        }
    }

    func installOrderRow(_ n: Int, _ name: String, _ desc: String) -> some View {
        HStack(spacing: 10) {
            Text("\(n)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .frame(width: 20, height: 20)
                .background(Color(hex: "#7c6af7").opacity(0.3))
                .cornerRadius(10)

            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                Text(desc)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()

            // CORRECCIÓN: Evitamos la advertencia "Value 'status' was defined but never used"
            if state.extensionStatus[name] != nil {
                let (icon, color) = state.statusIcon(name)
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(color)
            }
        }
    }

    func infoBox(icon: String, color: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(Color(hex: color))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                Text(body)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineSpacing(3)
            }
        }
        .padding(12)
        .background(Color(hex: color).opacity(0.08))
        .cornerRadius(8)
    }

    func extFilterChip(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: selected ? .semibold : .regular))
                .foregroundColor(selected ? .white : .secondary)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(selected ? Color(hex: "#7c6af7").opacity(0.3) : Color.white.opacity(0.06))
                .cornerRadius(5)
        }
        .buttonStyle(.plain)
    }

    func cnModelCard(_ model: (name: String, file: String, size: String, use: String)) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                Text(model.file)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
                Text(model.use)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.7))
            }
            Spacer()
            Text(model.size)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color.white.opacity(0.04))
        .cornerRadius(6)
    }

    func checkGroup(_ title: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(items, id: \.self) { item in
                    HStack(spacing: 8) {
                        Image(systemName: "square")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Text(item)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.8))
                    }
                }
            }
            .padding(10)
            .background(Color.white.opacity(0.03))
            .cornerRadius(6)
        }
    }
}

// MARK: - ExtensionRow

struct ExtensionRow: View {
    let ext:    A1111Extension
    let status: SetupAssistantState.ExtStatus
    var onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                // Category dot
                Circle()
                    .fill(Color(hex: ext.category.color))
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(ext.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)

                        Text(ext.category.rawValue)
                            .font(.system(size: 9))
                            .foregroundColor(Color(hex: ext.category.color))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color(hex: ext.category.color).opacity(0.15))
                            .cornerRadius(3)

                        if ext.priority == .critical {
                            Text("CRÍTICO")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(Color(hex: "#ef4444"))
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Color(hex: "#ef4444").opacity(0.15))
                                .cornerRadius(3)
                        }
                    }

                    Text(ext.description)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                // Status icon
                statusBadge
            }
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    var statusBadge: some View {
        switch status {
        case .installed:
            Label("Instalado", systemImage: "checkmark.circle.fill")
                .font(.system(size: 10))
                .foregroundColor(Color(hex: "#34d399"))
        case .notInstalled:
            Label("Falta", systemImage: "xmark.circle.fill")
                .font(.system(size: 10))
                .foregroundColor(Color(hex: "#ef4444"))
        case .checking:
            ProgressView().controlSize(.mini)
        case .unknown:
            Image(systemName: "chevron.right")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - ExtensionDetailSheet

struct ExtensionDetailSheet: View {
    let ext:     A1111Extension
    let baseURL: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text(ext.name)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                    Text(ext.category.rawValue)
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: ext.category.color))
                }
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }.buttonStyle(.plain)
            }
            .padding(16)
            .background(Color.white.opacity(0.03))

            Divider().background(Color.white.opacity(0.07))

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(ext.description)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.8))
                        .lineSpacing(4)

                    // Install URL
                    VStack(alignment: .leading, spacing: 6) {
                        Text("INSTALAR DESDE URL")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)

                        HStack(spacing: 8) {
                            Text(ext.installURL)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(Color(hex: "#3de3c0"))
                                .lineLimit(1)
                            Spacer()
                            Button(action: {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(ext.installURL, forType: .string)
                            }) {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Copiar URL")
                        }
                        .padding(8)
                        .background(Color.white.opacity(0.05))
                        .cornerRadius(6)
                    }

                    // Notes
                    VStack(alignment: .leading, spacing: 6) {
                        Text("INSTRUCCIONES")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)

                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(ext.notes.enumerated()), id: \.offset) { i, note in
                                HStack(alignment: .top, spacing: 8) {
                                    Text("\(i+1)")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .frame(width: 14)
                                    Text(note)
                                        .font(.system(size: 11))
                                        .foregroundColor(.white.opacity(0.8))
                                }
                            }
                        }
                    }

                    // Open docs
                    Button(action: {
                        if let url = URL(string: ext.docURL) {
                            NSWorkspace.shared.open(url)
                        }
                    }) {
                        Label("Abrir documentación", systemImage: "link.circle")
                            .font(.system(size: 11))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.06))
                            .foregroundColor(.white.opacity(0.8))
                            .cornerRadius(7)
                    }
                    .buttonStyle(.plain)
                }
                .padding(16)
            }
        }
        .frame(width: 440, height: 460)
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
    }
}

// MARK: - ESRGANModelCard

struct ESRGANModelCard: View {
    let model: ESRGANModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Text("\(model.sizeMB) MB")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            Text(model.description)
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            Text("Mejor para: \(model.bestFor)")
                .font(.system(size: 10))
                .foregroundColor(Color(hex: "#3de3c0"))

            Text(model.targetPath)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.7))

            HStack(spacing: 8) {
                Button(action: {
                    if let url = URL(string: model.downloadURL) {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    Label("Descargar", systemImage: "arrow.down.circle")
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "#3de3c0"))
                }
                .buttonStyle(.plain)

                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.downloadURL, forType: .string)
                }) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Copiar URL de descarga")
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.04))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
        )
    }
}
