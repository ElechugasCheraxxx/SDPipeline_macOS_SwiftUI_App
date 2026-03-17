import Foundation
import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers

// MARK: - ControlNetEngine
//
// Motor de ControlNet para SDPipelineStudio.
// Integra con A1111 sd-webui-controlnet extension:
//   - Preprocesado de imagen (detect edges, depth, pose, etc.)
//   - Inyección de unidades ControlNet en SDRequest
//   - Presets por caso de uso (character consistency, style transfer, etc.)
//   - IP-Adapter / FaceID para consistencia facial
//
// API endpoints:
//   GET  /controlnet/version
//   GET  /controlnet/model_list
//   GET  /controlnet/module_list
//   POST /controlnet/detect          → preprocesa imagen
//
// SDRequest: se extiende con alwayson_scripts.controlnet.args
//
// ROADMAP: "ControlNet Depth, Canny, SoftEdge, OpenPose" + "IP-Adapter y FaceID" (🟡 MEDIO PLAZO)

// MARK: - ControlNet Types

/// Módulo de preprocesado disponible en A1111 ControlNet
enum ControlNetModule: String, Codable, CaseIterable, Identifiable {
    // Sin preprocesado
    case none               = "none"

    // Detección de bordes
    case canny              = "canny"
    case softedge_hed       = "softedge_hed"
    case softedge_hedsafe   = "softedge_hedsafe"
    case lineart_realistic  = "lineart_realistic"
    case lineart_anime      = "lineart_anime"
    case mlsd               = "mlsd"

    // Profundidad
    case depth_midas        = "depth_midas"
    case depth_leres        = "depth_leres"
    case depth_zoe          = "depth_zoe"
    case normal_bae         = "normal_bae"

    // Pose / Body
    case openpose           = "openpose"
    case openpose_face      = "openpose_face"
    case openpose_faceonly  = "openpose_faceonly"
    case openpose_full      = "openpose_full"
    case openpose_hand      = "openpose_hand"
    case dw_openpose_full   = "dw_openpose_full"

    // Segmentación
    case segmentation       = "segmentation"

    // Scribble / Sketch
    case scribble_hed       = "scribble_hed"
    case scribble_pidinet   = "scribble_pidinet"
    case scribble_xdog      = "scribble_xdog"

    // IP-Adapter / Reference
    case ip_adapter_clip    = "ip-adapter_clip_sd15"
    case ip_adapter_face    = "ip-adapter-faceid"
    case reference_only     = "reference_only"
    case revision           = "revision"
    case color              = "color"
    case shuffle            = "shuffle"
    case tile_resample      = "tile_resample"
    case inpaint_only       = "inpaint_only"
    case inpaint_global_harmonious = "inpaint_global_harmonious"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none:               return "Sin preprocesado"
        case .canny:              return "Canny (Bordes)"
        case .softedge_hed:       return "SoftEdge HED"
        case .softedge_hedsafe:   return "SoftEdge HED (Safe)"
        case .lineart_realistic:  return "Lineart Realista"
        case .lineart_anime:      return "Lineart Anime"
        case .mlsd:               return "MLSD (Líneas rectas)"
        case .depth_midas:        return "Depth MiDaS"
        case .depth_leres:        return "Depth LeReS"
        case .depth_zoe:          return "Depth ZoeDepth"
        case .normal_bae:         return "Normal Map BAE"
        case .openpose:           return "OpenPose (Cuerpo)"
        case .openpose_face:      return "OpenPose (Cuerpo+Cara)"
        case .openpose_faceonly:  return "OpenPose (Solo Cara)"
        case .openpose_full:      return "OpenPose (Full)"
        case .openpose_hand:      return "OpenPose (Manos)"
        case .dw_openpose_full:   return "DW OpenPose Full (recomendado)"
        case .segmentation:       return "Segmentación"
        case .scribble_hed:       return "Scribble HED"
        case .scribble_pidinet:   return "Scribble PidiNet"
        case .scribble_xdog:      return "Scribble XDoG"
        case .ip_adapter_clip:    return "IP-Adapter CLIP"
        case .ip_adapter_face:    return "IP-Adapter FaceID"
        case .reference_only:     return "Reference Only"
        case .revision:           return "Revision (SDXL)"
        case .color:              return "Color"
        case .shuffle:            return "Shuffle"
        case .tile_resample:      return "Tile (Upscale detail)"
        case .inpaint_only:       return "Inpaint Only"
        case .inpaint_global_harmonious: return "Inpaint Global"
        }
    }

    var category: Category {
        switch self {
        case .none:                        return .raw
        case .canny, .softedge_hed, .softedge_hedsafe, .lineart_realistic,
             .lineart_anime, .mlsd:        return .edges
        case .depth_midas, .depth_leres,
             .depth_zoe, .normal_bae:      return .depth
        case .openpose, .openpose_face, .openpose_faceonly,
             .openpose_full, .openpose_hand,
             .dw_openpose_full:            return .pose
        case .segmentation:                return .segmentation
        case .scribble_hed, .scribble_pidinet,
             .scribble_xdog:              return .scribble
        case .ip_adapter_clip, .ip_adapter_face,
             .reference_only, .revision:  return .ipAdapter
        case .color, .shuffle, .tile_resample,
             .inpaint_only,
             .inpaint_global_harmonious:  return .utility
        }
    }

    enum Category: String, CaseIterable {
        case raw         = "Sin preprocesar"
        case edges       = "Bordes"
        case depth       = "Profundidad"
        case pose        = "Pose"
        case segmentation = "Segmentación"
        case scribble    = "Scribble"
        case ipAdapter   = "IP-Adapter"
        case utility     = "Utilidad"

        var icon: String {
            switch self {
            case .raw:          return "circle.slash"
            case .edges:        return "squareshape.dotted.squareshape"
            case .depth:        return "mountain.2.fill"
            case .pose:         return "figure.stand"
            case .segmentation: return "square.3.layers.3d"
            case .scribble:     return "pencil.and.scribble"
            case .ipAdapter:    return "person.crop.circle"
            case .utility:      return "wrench.adjustable"
            }
        }
    }
}

// MARK: - ControlNetUnit

/// Una unidad ControlNet que se inyecta en el SDRequest
struct ControlNetUnit: Codable, Identifiable {
    var id:              UUID          = UUID()
    var enabled:         Bool          = true
    var module:          ControlNetModule = .canny
    var model:           String        = ""
    var weight:          Double        = 1.0
    var guidanceStart:   Double        = 0.0
    var guidanceEnd:     Double        = 1.0
    var controlMode:     ControlMode   = .balanced
    var resizeMode:      ResizeMode    = .scaleToFit
    var imageBase64:     String?       = nil    // imagen de referencia en base64
    var processorRes:    Int           = 512
    var thresholdA:      Double        = 100    // param módulo (ej: Canny low threshold)
    var thresholdB:      Double        = 200    // param módulo (ej: Canny high threshold)
    var lowVRAM:         Bool          = false
    var pixelPerfect:    Bool          = true

    // Nombre de visualización para la UI
    var displayName:     String        = ""

    enum ControlMode: String, Codable, CaseIterable {
        case balanced           = "Balanced"
        case promptImportant    = "My prompt is more important"
        case controlNetImportant = "ControlNet is more important"
    }

    enum ResizeMode: String, Codable, CaseIterable {
        case justResize         = "Just Resize"
        case scaleToFit         = "Scale to Fit (Inner Fit)"
        case envelope           = "Envelope (Outer Fit)"
    }

    // Mapping a1111 API
    var toAPIDict: [String: Any] {
        var dict: [String: Any] = [
            "enabled":          enabled,
            "module":           module.rawValue,
            "model":            model,
            "weight":           weight,
            "guidance_start":   guidanceStart,
            "guidance_end":     guidanceEnd,
            "control_mode":     controlModeInt,
            "resize_mode":      resizeModeInt,
            "processor_res":    processorRes,
            "threshold_a":      thresholdA,
            "threshold_b":      thresholdB,
            "low_vram":         lowVRAM,
            "pixel_perfect":    pixelPerfect
        ]
        if let b64 = imageBase64 {
            dict["image"] = b64
        }
        return dict
    }

    private var controlModeInt: Int {
        switch controlMode {
        case .balanced:             return 0
        case .promptImportant:      return 1
        case .controlNetImportant:  return 2
        }
    }

    private var resizeModeInt: Int {
        switch resizeMode {
        case .justResize:  return 0
        case .scaleToFit:  return 1
        case .envelope:    return 2
        }
    }
}

// MARK: - ControlNetPreset

struct ControlNetPreset: Codable, Identifiable {
    var id:          UUID               = UUID()
    var name:        String
    var description: String             = ""
    var units:       [ControlNetUnit]
    var useCase:     UseCase            = .general
    var createdAt:   Date               = Date()

    enum UseCase: String, Codable, CaseIterable {
        case characterConsistency = "Consistencia de Personaje"
        case poseControl          = "Control de Pose"
        case styleTransfer        = "Transferencia de Estilo"
        case depthComposition     = "Composición por Profundidad"
        case faceID               = "Identidad Facial (IP-Adapter)"
        case tileUpscale          = "Upscale con Detalle (Tile)"
        case inpainting           = "Inpainting"
        case general              = "General"

        var icon: String {
            switch self {
            case .characterConsistency: return "person.crop.circle.fill"
            case .poseControl:          return "figure.stand"
            case .styleTransfer:        return "paintpalette.fill"
            case .depthComposition:     return "mountain.2"
            case .faceID:               return "face.dashed"
            case .tileUpscale:          return "arrow.up.left.and.arrow.down.right"
            case .inpainting:           return "scissors"
            case .general:              return "gearshape"
            }
        }
    }

    // MARK: - Built-in Presets

    static let builtins: [ControlNetPreset] = [

        ControlNetPreset(
            name: "Character Consistency — Pose",
            description: "Mantiene la pose del personaje. Combinar con imagen base del personaje activo.",
            units: [ControlNetUnit(
                enabled: true,
                module: .dw_openpose_full,
                model: "",  // usuario debe seleccionar
                weight: 0.85,
                guidanceStart: 0.0,
                guidanceEnd: 0.85,
                controlMode: .balanced,
                pixelPerfect: true,
                displayName: "Pose — DW OpenPose Full"
            )],
            useCase: .characterConsistency
        ),

        ControlNetPreset(
            name: "IP-Adapter Face Consistency",
            description: "Mantiene la identidad facial usando IP-Adapter FaceID. Alta consistencia entre generaciones.",
            units: [ControlNetUnit(
                enabled: true,
                module: .ip_adapter_face,
                model: "",
                weight: 0.75,
                guidanceStart: 0.0,
                guidanceEnd: 1.0,
                controlMode: .balanced,
                pixelPerfect: false,
                displayName: "IP-Adapter FaceID"
            )],
            useCase: .faceID
        ),

        ControlNetPreset(
            name: "Canny — Control de Estructura",
            description: "Detecta bordes duros para mantener la estructura general de la composición.",
            units: [ControlNetUnit(
                enabled: true,
                module: .canny,
                model: "",
                weight: 0.70,
                guidanceStart: 0.0,
                guidanceEnd: 0.80,
                controlMode: .balanced,
                thresholdA: 100,
                thresholdB: 200,
                pixelPerfect: true,
                displayName: "Canny Edges"
            )],
            useCase: .styleTransfer
        ),

        ControlNetPreset(
            name: "Depth — Composición Espacial",
            description: "Usa mapa de profundidad para guiar la composición 3D. Ideal para escenas complejas.",
            units: [ControlNetUnit(
                enabled: true,
                module: .depth_midas,
                model: "",
                weight: 0.75,
                guidanceStart: 0.0,
                guidanceEnd: 0.85,
                controlMode: .balanced,
                pixelPerfect: true,
                displayName: "Depth MiDaS"
            )],
            useCase: .depthComposition
        ),

        ControlNetPreset(
            name: "Tile — Upscale con Detalle",
            description: "Upscaling con preservación de detalles. Usar con PostProductionEngine.",
            units: [ControlNetUnit(
                enabled: true,
                module: .tile_resample,
                model: "",
                weight: 0.60,
                guidanceStart: 0.0,
                guidanceEnd: 1.0,
                controlMode: .balanced,
                thresholdA: 1.0,
                displayName: "Tile Resample"
            )],
            useCase: .tileUpscale
        ),

        ControlNetPreset(
            name: "SoftEdge — Estilo Suave",
            description: "Bordes suaves. Menos rígido que Canny. Ideal para retratos con consistencia flexible.",
            units: [ControlNetUnit(
                enabled: true,
                module: .softedge_hed,
                model: "",
                weight: 0.65,
                guidanceStart: 0.0,
                guidanceEnd: 0.80,
                controlMode: .promptImportant,
                pixelPerfect: true,
                displayName: "SoftEdge HED"
            )],
            useCase: .characterConsistency
        ),

        ControlNetPreset(
            name: "Character Full — Pose + Face",
            description: "Máxima consistencia: pose corporal + identidad facial simultáneos.",
            units: [
                ControlNetUnit(
                    enabled: true,
                    module: .dw_openpose_full,
                    model: "",
                    weight: 0.80,
                    guidanceStart: 0.0,
                    guidanceEnd: 0.80,
                    controlMode: .balanced,
                    pixelPerfect: true,
                    displayName: "DW OpenPose Full"
                ),
                ControlNetUnit(
                    enabled: true,
                    module: .ip_adapter_face,
                    model: "",
                    weight: 0.65,
                    guidanceStart: 0.0,
                    guidanceEnd: 1.0,
                    controlMode: .balanced,
                    displayName: "IP-Adapter FaceID"
                )
            ],
            useCase: .characterConsistency
        )
    ]
}

// MARK: - ControlNet API Models

struct ControlNetVersionResponse: Decodable {
    let version: Int
}

struct ControlNetModelListResponse: Decodable {
    let model_list: [String]
}

struct ControlNetModuleListResponse: Decodable {
    let module_list: [String]
}

struct ControlNetDetectRequest: Encodable {
    let controlnet_module: String
    let controlnet_input_images: [String]   // base64
    let controlnet_processor_res: Int
    let controlnet_threshold_a: Double
    let controlnet_threshold_b: Double
}

struct ControlNetDetectResponse: Decodable {
    let images: [String]    // base64 preprocessed
    let info: String?
}

// MARK: - ControlNetEngine

@MainActor
final class ControlNetEngine: ObservableObject {

    static let shared = ControlNetEngine()
    private init() {
        loadPresets()
    }

    // MARK: - State

    @Published var isAvailable:     Bool               = false
    @Published var availableModels: [String]           = []
    @Published var availableModules: [String]          = []
    @Published var presets:         [ControlNetPreset] = []
    @Published var activePreset:    ControlNetPreset?  = nil
    @Published var activeUnits:     [ControlNetUnit]   = []
    @Published var isEnabled:       Bool               = false
    @Published var isDetecting:     Bool               = false
    @Published var lastPreprocessed: NSImage?          = nil
    @Published var versionString:   String             = "—"
    @Published var isLoading:       Bool               = false

    private var presetsURL: URL? {
        VaultManager.shared.vaultMetaURL?.appending(path: "controlnet_presets.json")
    }

    // MARK: - Availability Check

    func checkAvailability(baseURL: String) async {
        isLoading = true
        defer { isLoading = false }

        guard let url = URL(string: "\(baseURL)/controlnet/version") else {
            isAvailable = false
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let resp = try JSONDecoder().decode(ControlNetVersionResponse.self, from: data)
            versionString = "v\(resp.version)"
            isAvailable = true
            await fetchModels(baseURL: baseURL)
        } catch {
            isAvailable = false
            versionString = "No disponible"
        }
    }

    // MARK: - Fetch Models

    func fetchModels(baseURL: String) async {
        async let models = fetchModelList(baseURL: baseURL)
        async let modules = fetchModuleList(baseURL: baseURL)
        let (m, mod) = await (models, modules)
        availableModels = m
        availableModules = mod
    }

    private func fetchModelList(baseURL: String) async -> [String] {
        guard let url = URL(string: "\(baseURL)/controlnet/model_list") else { return [] }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let resp = try? JSONDecoder().decode(ControlNetModelListResponse.self, from: data)
        else { return [] }
        return resp.model_list
    }

    private func fetchModuleList(baseURL: String) async -> [String] {
        guard let url = URL(string: "\(baseURL)/controlnet/module_list") else { return [] }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let resp = try? JSONDecoder().decode(ControlNetModuleListResponse.self, from: data)
        else { return [] }
        return resp.module_list
    }

    // MARK: - Preprocess Image

    /// Ejecuta el preprocesador ControlNet en una imagen y retorna la imagen procesada
    func preprocess(
        image:     NSImage,
        module:    ControlNetModule,
        processorRes: Int    = 512,
        thresholdA:   Double = 100,
        thresholdB:   Double = 200,
        baseURL:   String
    ) async -> NSImage? {

        guard isAvailable,
              let url = URL(string: "\(baseURL)/controlnet/detect"),
              let pngData = image.pngData()
        else { return nil }

        isDetecting = true
        defer { isDetecting = false }

        let base64 = pngData.base64EncodedString()

        let requestBody = ControlNetDetectRequest(
            controlnet_module: module.rawValue,
            controlnet_input_images: [base64],
            controlnet_processor_res: processorRes,
            controlnet_threshold_a: thresholdA,
            controlnet_threshold_b: thresholdB
        )

        guard let body = try? JSONEncoder().encode(requestBody) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let resp = try? JSONDecoder().decode(ControlNetDetectResponse.self, from: data),
              let first = resp.images.first,
              let imgData = Data(base64Encoded: first),
              let processedImage = NSImage(data: imgData)
        else { return nil }

        lastPreprocessed = processedImage
        return processedImage
    }

    // MARK: - Inject into SDRequest

    /// Inyecta las unidades ControlNet activas en el payload de SDRequest como alwayson_scripts
    func injectIntoRequestPayload(_ payload: inout [String: Any]) {
        guard isEnabled, !activeUnits.isEmpty else { return }

        let enabledUnits = activeUnits.filter { $0.enabled }
        guard !enabledUnits.isEmpty else { return }

        let args = enabledUnits.map { $0.toAPIDict }

        payload["alwayson_scripts"] = [
            "controlnet": [
                "args": args
            ]
        ]
    }

    /// Genera alwayson_scripts para serialización JSON directa en SDRequest extra fields
    func alwaysOnScripts() -> [String: Any]? {
        guard isEnabled, !activeUnits.isEmpty else { return nil }
        let enabled = activeUnits.filter { $0.enabled }
        guard !enabled.isEmpty else { return nil }
        return ["controlnet": ["args": enabled.map { $0.toAPIDict }]]
    }

    // MARK: - Character Consistency Helper

    /// Configura ControlNet automáticamente para consistencia de personaje.
    /// Usa la imagen base del CharacterEngine y aplica pose + IP-Adapter face.
    func setupCharacterConsistency(
        characterImage: NSImage,
        useIPAdapter: Bool = true,
        usePose: Bool = true
    ) {
        guard let pngData = characterImage.pngData() else { return }
        let base64 = pngData.base64EncodedString()

        var units: [ControlNetUnit] = []

        if usePose {
            var poseUnit = ControlNetUnit(
                enabled: true,
                module: .dw_openpose_full,
                model: bestModel(for: .pose),
                weight: 0.80,
                guidanceStart: 0.0,
                guidanceEnd: 0.80,
                controlMode: .balanced,
                pixelPerfect: true,
                displayName: "DW OpenPose Full"
            )
            poseUnit.imageBase64 = base64
            units.append(poseUnit)
        }

        if useIPAdapter {
            var faceUnit = ControlNetUnit(
                enabled: true,
                module: .ip_adapter_face,
                model: bestModel(for: .ipAdapter),
                weight: 0.70,
                guidanceStart: 0.0,
                guidanceEnd: 1.0,
                controlMode: .balanced,
                pixelPerfect: false,
                displayName: "IP-Adapter FaceID"
            )
            faceUnit.imageBase64 = base64
            units.append(faceUnit)
        }

        activeUnits = units
        isEnabled = !units.isEmpty
    }

    /// Selecciona el mejor modelo disponible para una categoría de módulo
    func bestModel(for category: ControlNetModule.Category) -> String {
        let keyword: String
        switch category {
        case .pose:      keyword = "openpose"
        case .depth:     keyword = "depth"
        case .edges:     keyword = "canny"
        case .ipAdapter: keyword = "ip-adapter"
        default:         keyword = ""
        }
        return availableModels.first { $0.lowercased().contains(keyword) } ?? ""
    }

    // MARK: - Active Preset Management

    func applyPreset(_ preset: ControlNetPreset) {
        activePreset = preset
        activeUnits = preset.units
        isEnabled = true
    }

    func clearActive() {
        activePreset = nil
        activeUnits = []
        isEnabled = false
        lastPreprocessed = nil
    }

    func addUnit(_ unit: ControlNetUnit) {
        activeUnits.append(unit)
        isEnabled = true
    }

    func removeUnit(at index: Int) {
        guard activeUnits.indices.contains(index) else { return }
        activeUnits.remove(at: index)
        if activeUnits.isEmpty { isEnabled = false }
    }

    func updateUnit(_ unit: ControlNetUnit) {
        if let idx = activeUnits.firstIndex(where: { $0.id == unit.id }) {
            activeUnits[idx] = unit
        }
    }

    // MARK: - Preset Persistence

    private func loadPresets() {
        var all: [ControlNetPreset] = ControlNetPreset.builtins

        if let url = presetsURL,
           let data = try? Data(contentsOf: url),
           let custom = try? JSONDecoder.iso8601.decode([ControlNetPreset].self, from: data) {
            all.append(contentsOf: custom)
        }

        presets = all
    }

    func saveCustomPreset(_ preset: ControlNetPreset) {
        var existing = presets.filter { builtin in
            !ControlNetPreset.builtins.contains { $0.id == builtin.id }
        }
        if let idx = existing.firstIndex(where: { $0.id == preset.id }) {
            existing[idx] = preset
        } else {
            existing.append(preset)
        }
        if let url = presetsURL,
           let data = try? JSONEncoder.pretty.encode(existing) {
            try? data.write(to: url)
        }
        loadPresets()
    }

    func saveCurrentAsPreset(name: String, useCase: ControlNetPreset.UseCase = .general) {
        let preset = ControlNetPreset(
            name: name,
            units: activeUnits,
            useCase: useCase
        )
        saveCustomPreset(preset)
    }

    func deletePreset(_ preset: ControlNetPreset) {
        guard !ControlNetPreset.builtins.contains(where: { $0.id == preset.id }) else { return }
        let custom = presets.filter { p in
            !ControlNetPreset.builtins.contains { $0.id == p.id } && p.id != preset.id
        }
        if let url = presetsURL,
           let data = try? JSONEncoder.pretty.encode(custom) {
            try? data.write(to: url)
        }
        loadPresets()
    }
}

// vaultMetaURL está declarado en VaultManager.swift — no redeclarar aquí.

// MARK: - ControlNetPanel (SwiftUI)

struct ControlNetPanel: View {

    @StateObject private var engine = ControlNetEngine.shared
    @State private var showPresets  = false
    @State private var showAddUnit  = false
    @State private var selectedPreset: ControlNetPreset? = nil

    let baseURL: String

    var body: some View {
        VStack(spacing: 0) {

            // Header
            HStack(spacing: 8) {
                Image(systemName: "cpu.fill")
                    .font(.system(size: 12))
                    .foregroundColor(engine.isAvailable ? Color(hex: "#3de3c0") : .secondary)

                Text("ControlNet")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))

                if engine.isAvailable {
                    Text(engine.versionString)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.white.opacity(0.07))
                        .cornerRadius(3)
                } else {
                    Text("No instalado")
                        .font(.system(size: 9))
                        .foregroundColor(Color(hex: "#f59e0b"))
                }

                Spacer()

                Toggle("", isOn: $engine.isEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(!engine.isAvailable)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.white.opacity(0.03))

            if engine.isEnabled && engine.isAvailable {
                Divider().background(Color.white.opacity(0.05))

                VStack(spacing: 8) {
                    // Presets bar
                    HStack(spacing: 6) {
                        Text("Preset:")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)

                        Button(action: { showPresets = true }) {
                            HStack(spacing: 4) {
                                Text(engine.activePreset?.name ?? "Seleccionar preset…")
                                    .font(.system(size: 10))
                                    .foregroundColor(engine.activePreset != nil ? .white : .secondary)
                                    .lineLimit(1)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 8))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.white.opacity(0.06))
                            .cornerRadius(5)
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        Button(action: engine.clearActive) {
                            Image(systemName: "xmark.circle")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Limpiar ControlNet")
                    }

                    // Active units
                    if !engine.activeUnits.isEmpty {
                        VStack(spacing: 4) {
                            ForEach(Array(engine.activeUnits.enumerated()), id: \.element.id) { idx, unit in
                                ControlNetUnitRow(unit: unit, index: idx)
                            }
                        }
                    }

                    // Add unit button
                    Button(action: { showAddUnit = true }) {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.circle")
                                .font(.system(size: 10))
                            Text("Agregar unidad")
                                .font(.system(size: 10))
                        }
                        .foregroundColor(Color(hex: "#7c6af7"))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(Color(hex: "#7c6af7").opacity(0.08))
                        .cornerRadius(5)
                    }
                    .buttonStyle(.plain)
                }
                .padding(10)
            }
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
        )
        .task {
            await engine.checkAvailability(baseURL: baseURL)
        }
        .sheet(isPresented: $showPresets) {
            ControlNetPresetPicker { preset in
                engine.applyPreset(preset)
                showPresets = false
            }
        }
        .sheet(isPresented: $showAddUnit) {
            ControlNetUnitEditor(unit: ControlNetUnit()) { unit in
                engine.addUnit(unit)
                showAddUnit = false
            }
        }
    }
}

// MARK: - ControlNetUnitRow

struct ControlNetUnitRow: View {
    let unit:  ControlNetUnit
    let index: Int

    @StateObject private var engine = ControlNetEngine.shared
    @State private var showEdit = false
    @State private var isOn: Bool

    init(unit: ControlNetUnit, index: Int) {
        self.unit  = unit
        self.index = index
        _isOn = State(initialValue: unit.enabled)
    }

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .onChange(of: isOn) { _, v in
                    var updated = unit
                    updated.enabled = v
                    engine.updateUnit(updated)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(unit.displayName.isEmpty ? unit.module.displayName : unit.displayName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text("W: \(unit.weight, specifier: "%.2f")")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)

                    if !unit.model.isEmpty {
                        Text(unit.model.prefix(20))
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("Sin modelo")
                            .font(.system(size: 9))
                            .foregroundColor(Color(hex: "#f59e0b"))
                    }
                }
            }

            Spacer()

            Button(action: { showEdit = true }) {
                Image(systemName: "pencil")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)

            Button(action: { engine.removeUnit(at: index) }) {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Color.white.opacity(0.04))
        .cornerRadius(6)
        .sheet(isPresented: $showEdit) {
            ControlNetUnitEditor(unit: unit) { updated in
                engine.updateUnit(updated)
                showEdit = false
            }
        }
    }
}

// MARK: - ControlNetPresetPicker

struct ControlNetPresetPicker: View {

    var onSelect: (ControlNetPreset) -> Void

    @StateObject private var engine = ControlNetEngine.shared
    @State private var selectedUseCase: ControlNetPreset.UseCase? = nil
    @Environment(\.dismiss) private var dismiss

    var filtered: [ControlNetPreset] {
        guard let uc = selectedUseCase else { return engine.presets }
        return engine.presets.filter { $0.useCase == uc }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Presets ControlNet")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(16)
            .background(Color.white.opacity(0.03))

            Divider().background(Color.white.opacity(0.07))

            // Use case filter
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    filterChip("Todos", selected: selectedUseCase == nil) {
                        selectedUseCase = nil
                    }
                    ForEach(ControlNetPreset.UseCase.allCases, id: \.self) { uc in
                        filterChip(uc.rawValue, selected: selectedUseCase == uc) {
                            selectedUseCase = selectedUseCase == uc ? nil : uc
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }

            Divider().background(Color.white.opacity(0.07))

            // Preset list
            List(filtered) { preset in
                Button(action: { onSelect(preset) }) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: preset.useCase.icon)
                                .font(.system(size: 11))
                                .foregroundColor(Color(hex: "#7c6af7"))
                            Text(preset.name)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white)
                            Spacer()
                            Text("\(preset.units.count) unidad\(preset.units.count != 1 ? "es" : "")")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                        if !preset.description.isEmpty {
                            Text(preset.description)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
        .frame(width: 460, height: 520)
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
    }

    func filterChip(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
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
}

// MARK: - ControlNetUnitEditor

struct ControlNetUnitEditor: View {

    @State var unit: ControlNetUnit
    var onSave: (ControlNetUnit) -> Void

    @StateObject private var engine = ControlNetEngine.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showImagePicker = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(unit.id == UUID() ? "Nueva Unidad ControlNet" : "Editar Unidad")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Button("Cancelar") { dismiss() }.buttonStyle(.plain).foregroundColor(.secondary)
                Button("Guardar") { onSave(unit); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(hex: "#7c6af7"))
                    .controlSize(.small)
            }
            .padding(16)
            .background(Color.white.opacity(0.03))

            Divider().background(Color.white.opacity(0.07))

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {

                    // Enabled + Name
                    HStack {
                        Toggle("Habilitada", isOn: $unit.enabled)
                            .font(.system(size: 11))
                        Spacer()
                        TextField("Nombre (opcional)", text: $unit.displayName)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                            .frame(width: 200)
                    }

                    // Module
                    settingsSection("Módulo de Preprocesado") {
                        Picker("Módulo", selection: $unit.module) {
                            ForEach(ControlNetModule.Category.allCases, id: \.self) { cat in
                                Section(cat.rawValue) {
                                    ForEach(ControlNetModule.allCases.filter { $0.category == cat }) { mod in
                                        Text(mod.displayName).tag(mod)
                                    }
                                }
                            }
                        }
                        .pickerStyle(.menu)
                        .font(.system(size: 11))
                    }

                    // Model
                    settingsSection("Modelo") {
                        if engine.availableModels.isEmpty {
                            Text("No se encontraron modelos ControlNet. Verificar instalación.")
                                .font(.system(size: 10))
                                .foregroundColor(Color(hex: "#f59e0b"))
                        } else {
                            Picker("Modelo", selection: $unit.model) {
                                Text("Sin modelo").tag("")
                                ForEach(engine.availableModels, id: \.self) { m in
                                    Text(m).tag(m)
                                }
                            }
                            .pickerStyle(.menu)
                            .font(.system(size: 11))
                        }
                    }

                    // Weight & Guidance
                    settingsSection("Peso y Guía") {
                        VStack(spacing: 8) {
                            sliderRow("Peso", value: $unit.weight, range: 0...2, format: "%.2f")
                            sliderRow("Guía Start", value: $unit.guidanceStart, range: 0...1, format: "%.2f")
                            sliderRow("Guía End",   value: $unit.guidanceEnd,   range: 0...1, format: "%.2f")
                        }
                    }

                    // Thresholds (only for edge modules)
                    if unit.module.category == .edges {
                        settingsSection("Umbrales (\(unit.module.displayName))") {
                            VStack(spacing: 8) {
                                sliderRow("Umbral A", value: $unit.thresholdA, range: 1...255, format: "%.0f")
                                sliderRow("Umbral B", value: $unit.thresholdB, range: 1...255, format: "%.0f")
                            }
                        }
                    }

                    // Control Mode
                    settingsSection("Modo de Control") {
                        Picker("", selection: $unit.controlMode) {
                            ForEach(ControlNetUnit.ControlMode.allCases, id: \.self) { m in
                                Text(m.rawValue).tag(m)
                            }
                        }
                        .pickerStyle(.segmented)
                        .font(.system(size: 10))
                    }

                    // Options
                    settingsSection("Opciones") {
                        HStack(spacing: 16) {
                            Toggle("Pixel Perfect", isOn: $unit.pixelPerfect)
                                .font(.system(size: 11))
                            Toggle("Low VRAM", isOn: $unit.lowVRAM)
                                .font(.system(size: 11))
                        }
                    }

                    // Image reference
                    settingsSection("Imagen de Referencia") {
                        if unit.imageBase64 != nil {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(Color(hex: "#34d399"))
                                    .font(.system(size: 12))
                                Text("Imagen cargada")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                Spacer()
                                Button("Quitar") { unit.imageBase64 = nil }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 11))
                                    .foregroundColor(Color(hex: "#ef4444"))
                            }
                        } else {
                            Button(action: loadReferenceImage) {
                                Label("Cargar imagen de referencia", systemImage: "photo.badge.plus")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.white.opacity(0.1))
                            .controlSize(.small)
                        }
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 440, height: 580)
        .background(Color(red: 0.10, green: 0.10, blue: 0.13))
    }

    func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            content()
        }
    }

    func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, format: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: format, value.wrappedValue))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white.opacity(0.7))
                .frame(width: 40)
        }
    }

    func loadReferenceImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url,
           let data = try? Data(contentsOf: url) {
            unit.imageBase64 = data.base64EncodedString()
        }
    }
}

