import Foundation
import UniformTypeIdentifiers
import AppKit
import SwiftUI
import Combine

// MARK: - IPAdapterEngine
//
// Motor de IP-Adapter + FaceID para consistencia facial y de estilo.
// Implementa la integración con:
//   • sd-webui-controlnet (como módulo de ControlNet)
//   • IP-Adapter-FaceID (consistencia facial entre generaciones)
//   • IP-Adapter Plus (consistencia de estilo/referencia)
//   • IP-Adapter Full Face (para img2img con referencia facial)
//
// Workflow completo:
//   1. Cargar imagen de referencia (personaje base)
//   2. Configurar modelo IP-Adapter (FaceID, Plus, Base, etc.)
//   3. Ajustar weight y begin/end step
//   4. Inyectar en SDRequest via AlwaysOnScripts (bajo la key 'controlnet')
//   5. Persistir config por personaje en CharacterEngine
//
// ROADMAP: "IP-Adapter y FaceID para consistencia facial" (🟡 MEDIO PLAZO)

@MainActor
final class IPAdapterEngine: ObservableObject {

    static let shared = IPAdapterEngine()
    private init() { loadModels() }

    // MARK: - Models

    enum IPAdapterModel: String, CaseIterable, Codable {
        case faceID          = "ip-adapter-faceid"
        case faceIDPlus      = "ip-adapter-faceid-plus"
        case faceIDPlusV2    = "ip-adapter-faceid-plusv2"
        case faceIDPortrait  = "ip-adapter-faceid-portrait"
        case plus            = "ip-adapter-plus"
        case plusFace        = "ip-adapter-plus-face"
        case base            = "ip-adapter"
        case light           = "ip-adapter-light"
        case fullFace        = "ip-adapter_full_face"
        case sdxlPlus        = "ip-adapter-plus_sdxl_vit-h"
        case sdxlVitG        = "ip-adapter_sdxl_vit-g"

        var displayName: String {
            switch self {
            case .faceID:         return "FaceID"
            case .faceIDPlus:     return "FaceID Plus"
            case .faceIDPlusV2:   return "FaceID Plus v2"
            case .faceIDPortrait: return "FaceID Portrait"
            case .plus:           return "IP-Adapter Plus"
            case .plusFace:       return "IP-Adapter Plus Face"
            case .base:           return "IP-Adapter Base"
            case .light:          return "IP-Adapter Light"
            case .fullFace:       return "IP-Adapter Full Face"
            case .sdxlPlus:       return "SDXL Plus"
            case .sdxlVitG:       return "SDXL ViT-G"
            }
        }

        var description: String {
            switch self {
            case .faceID, .faceIDPlus, .faceIDPlusV2, .faceIDPortrait:
                return "Consistencia facial entre generaciones"
            case .plus, .plusFace, .fullFace:
                return "Consistencia de referencia con alta fidelidad"
            case .base:
                return "Consistencia de estilo general"
            case .light:
                return "Consistencia ligera, mayor creatividad"
            case .sdxlPlus, .sdxlVitG:
                return "Para modelos SDXL"
            }
        }

        var isFaceModel: Bool {
            [.faceID, .faceIDPlus, .faceIDPlusV2, .faceIDPortrait, .plusFace, .fullFace].contains(self)
        }

        var recommendedWeight: Double {
            switch self {
            case .faceID, .faceIDPortrait: return 0.7
            case .faceIDPlus, .faceIDPlusV2: return 0.8
            case .plus, .plusFace: return 0.6
            case .base: return 0.5
            case .light: return 0.3
            case .fullFace: return 0.85
            case .sdxlPlus, .sdxlVitG: return 0.6
            }
        }
    }

    // MARK: - Configuration

    struct IPAdapterConfig: Codable {
        var enabled:        Bool              = false
        var model:          IPAdapterModel    = .faceIDPlus
        var referenceImage: String?           // path a la imagen de referencia
        var weight:         Double            = 0.7
        var beginStep:      Double            = 0.0  // 0.0 = desde el inicio
        var endStep:        Double            = 1.0  // 1.0 = hasta el final
        var cropFace:       Bool              = true  // auto-crop de cara en referencia
        var clipVisionModel: String           = "ViT-H"

        // Para FaceID específicamente
        var faceIDWeight:   Double            = 0.7
        var lora:           String?           = "ip-adapter-faceid-plus_sdv15.bin"
        var loraWeight:     Double            = 0.7
    }

    // MARK: - State

    @Published var config:            IPAdapterConfig = IPAdapterConfig()
    @Published var availableModels:   [IPAdapterModel] = []
    @Published var referenceImage:    NSImage?    = nil
    @Published var isLoadingImage:    Bool        = false
    @Published var isEnabled:         Bool        = false
    @Published var lastError:         String?     = nil

    // MARK: - Load / Setup

    private func loadModels() {
        // Consultar A1111 para modelos disponibles (endpoint /controlnet/model_list
        // o script list si está instalado)
        availableModels = IPAdapterModel.allCases
    }

    func checkInstalled() async -> Bool {
        guard let base = URL(string: UserDefaults.standard.string(forKey: "sd.baseURL") ?? "http://127.0.0.1:7860") else { return false }
        let url = base.appending(path: "controlnet/model_list")
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["model_list"] as? [String]
        else { return false }
        return models.contains(where: { $0.lowercased().contains("ip-adapter") })
    }

    // MARK: - Reference Image

    func loadReferenceImage(from url: URL) async {
        isLoadingImage = true
        defer { isLoadingImage = false }

        guard let data  = try? Data(contentsOf: url),
              let image = NSImage(data: data)
        else {
            lastError = "No se pudo cargar la imagen de referencia."
            return
        }

        referenceImage          = image
        config.referenceImage   = url.path
        config.enabled          = true
        isEnabled               = true
    }

    func clearReferenceImage() {
        referenceImage        = nil
        config.referenceImage = nil
        config.enabled        = false
        isEnabled             = false
    }

    /// Carga la imagen base del personaje activo como referencia.
    func loadFromCharacter(_ character: CharacterProfile) async {
        guard let imagePath = character.baseImagePath else {
            lastError = "El personaje no tiene imagen base configurada."
            return
        }
        await loadReferenceImage(from: URL(fileURLWithPath: imagePath))
    }

    // MARK: - Inject into SDRequest

    /// Produce el bloque alwayson_scripts para inyectar IP-Adapter en el request vía ControlNet.
    func buildAlwaysOnScripts() -> [String: Any]? {
        guard config.enabled, let refPath = config.referenceImage, referenceImage != nil else { return nil }

        // Convertir imagen de referencia a base64
        guard let imageData = try? Data(contentsOf: URL(fileURLWithPath: refPath)),
              !imageData.isEmpty
        else { return nil }

        let base64 = imageData.base64EncodedString()
        let model  = config.model

        // Determinar el módulo correcto de ControlNet según el tipo de IP-Adapter
        let moduleName = model.isFaceModel ? "ip-adapter-faceid" : "ip-adapter_clip_sd15"

        // Estructura adaptada para la API de ControlNet
        let ipadapterArgs: [String: Any] = [
            "enabled":        true,
            "module":         moduleName,
            "model":          model.rawValue,
            "weight":         config.weight,
            "image":          "data:image/png;base64,\(base64)",
            "guidance_start": config.beginStep,
            "guidance_end":   config.endStep,
            "resize_mode":    "Crop and Resize",
            "processor_res":  512
        ]

        // Para FaceID el LoRA se inyecta en el prompt con sintaxis nativa <lora:name:weight>
        // A1111 moderno no necesita la extensión "Additional networks for generating"
        return ["controlnet": ["args": [ipadapterArgs]]]
    }

    // MARK: - LoRA Prompt Suffix (FaceID)

    /// Sufijo a concatenar al prompt positivo para inyectar el LoRA de FaceID.
    /// Ej: " <lora:ip-adapter-faceid-plus_sdv15:0.70>"
    /// Retorna nil si no aplica (modelo no FaceID o LoRA no configurado).
    func loraPromptSuffix() -> String? {
        guard config.enabled,
              config.model.isFaceModel,
              let loraName = config.lora,
              !loraName.isEmpty
        else { return nil }
        let w = String(format: "%.2f", config.loraWeight)
        return " <lora:\(loraName):\(w)>"
    }

    // MARK: - Per-Character Config Persistence

    func saveConfigForCharacter(_ characterID: UUID) {
        let key  = "ipadapter.config.\(characterID.uuidString)"
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func loadConfigForCharacter(_ characterID: UUID) {
        let key = "ipadapter.config.\(characterID.uuidString)"
        guard let data = UserDefaults.standard.data(forKey: key),
              let cfg  = try? JSONDecoder().decode(IPAdapterConfig.self, from: data)
        else { return }
        config = cfg
        isEnabled = config.enabled
        if let path = config.referenceImage {
            referenceImage = NSImage(contentsOf: URL(fileURLWithPath: path))
        }
    }

    // MARK: - Recommended Presets

    struct Preset: Identifiable {
        let id = UUID()
        let name:   String
        let model:  IPAdapterModel
        let weight: Double
        let begin:  Double
        let end:    Double
        let description: String
    }

    var presets: [Preset] { Self.builtInPresets }

    static let builtInPresets: [Preset] = [
        Preset(name: "Consistencia facial máxima",
               model: .faceIDPlusV2, weight: 0.85, begin: 0.0, end: 1.0,
               description: "Máxima fidelidad al rostro. Limita creatividad."),
        Preset(name: "Consistencia facial + variación",
               model: .faceIDPlus, weight: 0.65, begin: 0.0, end: 0.85,
               description: "Balance entre fidelidad y variedad de poses/ángulos."),
        Preset(name: "Estilo + personaje",
               model: .plus, weight: 0.55, begin: 0.0, end: 1.0,
               description: "Preserva estilo visual general de la referencia."),
        Preset(name: "Referencia suave",
               model: .light, weight: 0.35, begin: 0.2, end: 0.8,
               description: "Influencia ligera. Máxima creatividad."),
        Preset(name: "FaceID Retrato",
               model: .faceIDPortrait, weight: 0.75, begin: 0.0, end: 0.9,
               description: "Optimizado para retratos con fondo variable."),
    ]

    func applyPreset(_ preset: Preset) {
        config.model      = preset.model
        config.weight     = preset.weight
        config.beginStep  = preset.begin
        config.endStep    = preset.end
    }
}

// MARK: - IPAdapterEngine SwiftUI View

struct IPAdapterPanel: View {

    @StateObject private var engine = IPAdapterEngine.shared
    @State private var showPresets = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            // Header + Toggle
            HStack {
                Image(systemName: "person.fill.viewfinder")
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: "#7c6af7"))
                Text("IP-Adapter")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Toggle("", isOn: $engine.isEnabled)
                    .toggleStyle(.switch)
                    .scaleEffect(0.75)
                    .onChange(of: engine.isEnabled) { _, v in engine.config.enabled = v }
            }

            if engine.isEnabled {

                // Referencia
                referenceImageRow

                if engine.referenceImage != nil {
                    // Modelo
                    VStack(alignment: .leading, spacing: 4) {
                        paramLabel("Modelo")
                        Picker("", selection: $engine.config.model) {
                            ForEach(IPAdapterEngine.IPAdapterModel.allCases, id: \.self) { m in
                                Text(m.displayName).tag(m)
                            }
                        }
                        .pickerStyle(.menu)
                        .font(.system(size: 11))
                    }

                    // Weight slider
                    sliderRow("Peso", value: $engine.config.weight, range: 0...1)
                    sliderRow("Inicio", value: $engine.config.beginStep, range: 0...1)
                    sliderRow("Fin", value: $engine.config.endStep, range: 0...1)

                    // Presets
                    Button("Presets recomendados…") { showPresets = true }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "#7c6af7"))
                }

                if let err = engine.lastError {
                    Text(err)
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "#ef4444"))
                }
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.04))
        .cornerRadius(8)
        .sheet(isPresented: $showPresets) { presetsSheet }
    }

    private var referenceImageRow: some View {
        HStack(spacing: 8) {
            if let img = engine.referenceImage {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 44, height: 44)
                    .cornerRadius(6)
                    .clipped()
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 44, height: 44)
                    .overlay(
                        Image(systemName: "person.crop.rectangle")
                            .font(.system(size: 16))
                            .foregroundColor(.secondary)
                    )
            }
            VStack(alignment: .leading, spacing: 4) {
                Button(engine.referenceImage == nil ? "Cargar referencia…" : "Cambiar imagen") {
                    pickReferenceImage()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#7c6af7"))

                if engine.referenceImage != nil {
                    Button("Quitar") { engine.clearReferenceImage() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var presetsSheet: some View {
        VStack(spacing: 0) {
            Text("Presets IP-Adapter")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
                .padding()
            Divider()
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(engine.presets) { preset in
                        Button {
                            engine.applyPreset(preset)
                            showPresets = false
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(preset.name)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(.white)
                                    Spacer()
                                    Text(preset.model.displayName)
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                }
                                Text(preset.description)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            .padding(10)
                            .background(Color.white.opacity(0.05))
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
        }
        .frame(width: 380, height: 360)
        .background(Color(red: 0.10, green: 0.10, blue: 0.13))
    }

    private func pickReferenceImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            Task { await engine.loadReferenceImage(from: url) }
        }
    }

    private func paramLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundColor(.secondary)
    }

    private func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 10)).foregroundColor(.secondary).frame(width: 36, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: "%.2f", value.wrappedValue))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 32)
        }
    }
}

// MARK: - CharacterProfile extension for IP-Adapter

extension CharacterProfile {
    var baseImagePath: String? {
        get { UserDefaults.standard.string(forKey: "char.baseImage.\(id.uuidString)") }
        set { UserDefaults.standard.set(newValue, forKey: "char.baseImage.\(id.uuidString)") }
    }
}
