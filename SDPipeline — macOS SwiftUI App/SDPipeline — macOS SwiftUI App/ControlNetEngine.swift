import Foundation
import AppKit
import SwiftUI
import Combine

// MARK: - ControlNetEngine
//
// Integración completa con sd-webui-controlnet vía A1111 API.
//
// Modos soportados:
//   Depth       — Mapa de profundidad (MiDaS, DPT)
//   Canny       — Detección de bordes Canny
//   OpenPose    — Estimación de pose corporal
//   SoftEdge    — Bordes suaves (HED/PIDI)
//   NormalMap   — Normal map para iluminación
//   LineArt     — Arte lineal
//   IPAdapter   — IP-Adapter para consistencia de identidad
//   FaceID      — IP-Adapter FaceID para consistencia facial
//   Scribble    — Esbozos a mano libre
//   Seg         — Segmentación semántica
//
// Uso:
//   1. Añadir unidades ControlNet a la request con addUnit(...)
//   2. Inyectar en payload txt2img/img2img vía asPayloadDict()
//   3. El payload va en "alwayson_scripts" → "controlnet" → "args"
//
// ROADMAP: "ControlNet Depth, Canny, SoftEdge, OpenPose" + "IP-Adapter FaceID" (🟡 MEDIO PLAZO)

// MARK: - Models

enum ControlNetMode: String, Codable, CaseIterable, Identifiable {
    case depth      = "depth"
    case canny      = "canny"
    case openPose   = "openpose"
    case softEdge   = "softedge"
    case normalMap  = "normal"
    case lineArt    = "lineart"
    case ipAdapter  = "ip-adapter"
    case faceID     = "ip-adapter_face_id"
    case scribble   = "scribble"
    case seg        = "seg"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .depth:     return "Depth"
        case .canny:     return "Canny"
        case .openPose:  return "OpenPose"
        case .softEdge:  return "SoftEdge"
        case .normalMap: return "Normal Map"
        case .lineArt:   return "LineArt"
        case .ipAdapter: return "IP-Adapter"
        case .faceID:    return "FaceID"
        case .scribble:  return "Scribble"
        case .seg:       return "Segmentation"
        }
    }

    var icon: String {
        switch self {
        case .depth:     return "cube.transparent"
        case .canny:     return "squareshape.split.2x2"
        case .openPose:  return "figure.stand"
        case .softEdge:  return "scribble.variable"
        case .normalMap: return "light.max"
        case .lineArt:   return "pencil.and.outline"
        case .ipAdapter: return "person.crop.rectangle.badge.plus"
        case .faceID:    return "face.smiling.inverse"
        case .scribble:  return "scribble"
        case .seg:       return "square.3.layers.3d"
        }
    }

    var defaultPreprocessor: String {
        switch self {
        case .depth:     return "depth_midas"
        case .canny:     return "canny"
        case .openPose:  return "openpose_full"
        case .softEdge:  return "softedge_hed"
        case .normalMap: return "normal_bae"
        case .lineArt:   return "lineart_realistic"
        case .ipAdapter: return "ip-adapter_clip_sd15"
        case .faceID:    return "ip-adapter_face_id"
        case .scribble:  return "scribble_hed"
        case .seg:       return "seg_ofade20k"
        }
    }

    var defaultModel: String {
        switch self {
        case .depth:     return "control_v11f1p_sd15_depth"
        case .canny:     return "control_v11p_sd15_canny"
        case .openPose:  return "control_v11p_sd15_openpose"
        case .softEdge:  return "control_v11p_sd15_softedge"
        case .normalMap: return "control_v11p_sd15_normalbae"
        case .lineArt:   return "control_v11p_sd15_lineart"
        case .ipAdapter: return "ip-adapter_sd15"
        case .faceID:    return "ip-adapter-faceid_sd15"
        case .scribble:  return "control_v11p_sd15_scribble"
        case .seg:       return "control_v11p_sd15_seg"
        }
    }

    /// ¿Este modo requiere imagen de referencia (IP-Adapter)?
    var isReferenceMode: Bool {
        self == .ipAdapter || self == .faceID
    }
}

enum ControlNetResizeMode: String, Codable, CaseIterable {
    case justResize     = "Just Resize"
    case cropAndResize  = "Crop and Resize"
    case resizeAndFill  = "Resize and Fill"
    case scaleToFit     = "Scale to Fit (Inner Fit)"

    var apiValue: Int {
        switch self {
        case .justResize:    return 0
        case .cropAndResize: return 1
        case .resizeAndFill: return 2
        case .scaleToFit:    return 3
        }
    }
}

struct ControlNetUnit: Identifiable, Codable {
    var id:             UUID   = UUID()
    var mode:           ControlNetMode = .depth
    var enabled:        Bool   = true
    var lowVRAM:        Bool   = false
    var pixelPerfect:   Bool   = true
    var weight:         Double = 1.0        // 0.0 – 2.0
    var guidanceStart:  Double = 0.0        // 0.0 – 1.0
    var guidanceEnd:    Double = 1.0        // 0.0 – 1.0
    var preprocessor:   String = ""         // override defaultPreprocessor
    var model:          String = ""         // override defaultModel
    var resizeMode:     ControlNetResizeMode = .cropAndResize
    var processorRes:   Int    = 512
    var thresholdA:     Double = 100.0      // Canny low threshold
    var thresholdB:     Double = 200.0      // Canny high threshold

    // Imagen de control (base64 PNG o ruta)
    var sourceImageBase64: String? = nil
    var sourceImagePath:   String? = nil

    var effectivePreprocessor: String {
        preprocessor.isEmpty ? mode.defaultPreprocessor : preprocessor
    }

    var effectiveModel: String {
        model.isEmpty ? mode.defaultModel : model
    }
}

// MARK: - ControlNetEngine

@MainActor
final class ControlNetEngine: ObservableObject {

    static let shared = ControlNetEngine()
    private init() { loadConfig() }

    // MARK: - State

    @Published var units:              [ControlNetUnit]  = []
    @Published var availableModels:    [String]          = []
    @Published var availablePreprocessors: [String]      = []
    @Published var isLoading:          Bool              = false
    @Published var isEnabled:          Bool              = false   // toggle global
    @Published var errorMessage:       String?           = nil

    // MARK: - Public API

    /// Añadir unidad ControlNet.
    @discardableResult
    func addUnit(mode: ControlNetMode, sourceImage: NSImage? = nil) -> ControlNetUnit {
        var unit = ControlNetUnit(mode: mode)
        unit.preprocessor = mode.defaultPreprocessor
        unit.model        = mode.defaultModel
        if let img = sourceImage {
            unit.sourceImageBase64 = imageToBase64(img)
        }
        units.append(unit)
        saveConfig()
        return unit
    }

    func removeUnit(id: UUID) {
        units.removeAll { $0.id == id }
        saveConfig()
    }

    func updateUnit(_ unit: ControlNetUnit) {
        if let idx = units.firstIndex(where: { $0.id == unit.id }) {
            units[idx] = unit
            saveConfig()
        }
    }

    func clearUnits() {
        units.removeAll()
        saveConfig()
    }

    func toggleUnit(id: UUID) {
        if let idx = units.firstIndex(where: { $0.id == id }) {
            units[idx].enabled.toggle()
            saveConfig()
        }
    }

    /// Setear imagen de control para una unidad.
    func setSourceImage(_ image: NSImage, for unitID: UUID) {
        guard let idx = units.firstIndex(where: { $0.id == unitID }) else { return }
        units[idx].sourceImageBase64 = imageToBase64(image)
        saveConfig()
    }

    // MARK: - Payload Injection

    /// Genera el dict "alwayson_scripts" → "controlnet" para inyectar en txt2img/img2img payload.
    func alwaysonScriptsPayload() -> [String: Any]? {
        let activeUnits = units.filter { $0.enabled }
        guard !activeUnits.isEmpty, isEnabled else { return nil }

        let args: [[String: Any]] = activeUnits.map { unit in
            var dict: [String: Any] = [
                "enabled":          unit.enabled,
                "low_vram":         unit.lowVRAM,
                "pixel_perfect":    unit.pixelPerfect,
                "module":           unit.effectivePreprocessor,
                "model":            unit.effectiveModel,
                "weight":           unit.weight,
                "guidance_start":   unit.guidanceStart,
                "guidance_end":     unit.guidanceEnd,
                "resize_mode":      unit.resizeMode.apiValue,
                "processor_res":    unit.processorRes,
                "threshold_a":      unit.thresholdA,
                "threshold_b":      unit.thresholdB,
            ]
            if let b64 = unit.sourceImageBase64 {
                dict["image"] = b64
            }
            return dict
        }

        return [
            "controlnet": ["args": args]
        ]
    }

    // MARK: - Fetch from A1111

    func fetchModelsAndPreprocessors(baseURL: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        async let modelsTask        = fetchModels(baseURL: baseURL)
        async let preprocessorTask  = fetchPreprocessors(baseURL: baseURL)

        let (models, preprocessors) = await (modelsTask, preprocessorTask)
        availableModels        = models
        availablePreprocessors = preprocessors
    }

    private func fetchModels(baseURL: String) async -> [String] {
        guard let url = URL(string: "\(baseURL)/controlnet/model_list") else { return [] }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["model_list"] as? [String]
        else { return [] }
        return list
    }

    private func fetchPreprocessors(baseURL: String) async -> [String] {
        guard let url = URL(string: "\(baseURL)/controlnet/module_list") else { return [] }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["module_list"] as? [String]
        else { return [] }
        return list
    }

    // MARK: - Preprocess

    /// Ejecutar solo el preprocesador para obtener la imagen de control.
    func preprocess(image: NSImage, unit: ControlNetUnit, baseURL: String) async -> NSImage? {
        guard let b64 = imageToBase64(image),
              let url = URL(string: "\(baseURL)/controlnet/detect")
        else { return nil }

        let payload: [String: Any] = [
            "controlnet_module": unit.effectivePreprocessor,
            "controlnet_input_images": [b64],
            "controlnet_processor_res": unit.processorRes,
            "controlnet_threshold_a":   unit.thresholdA,
            "controlnet_threshold_b":   unit.thresholdB
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let images = json["images"] as? [String],
              let firstB64 = images.first,
              let imgData = Data(base64Encoded: firstB64)
        else { return nil }

        return NSImage(data: imgData)
    }

    // MARK: - Presets

    /// Preset: Character Consistency con IP-Adapter.
    func applyCharacterConsistencyPreset(referenceImage: NSImage) {
        clearUnits()
        var unit = ControlNetUnit(mode: .ipAdapter)
        unit.weight = 0.75
        unit.guidanceStart = 0.0
        unit.guidanceEnd   = 0.85
        unit.sourceImageBase64 = imageToBase64(referenceImage)
        units = [unit]
        isEnabled = true
        saveConfig()
    }

    /// Preset: FaceID para consistencia facial exacta.
    func applyFaceIDPreset(referenceImage: NSImage) {
        clearUnits()
        var unit = ControlNetUnit(mode: .faceID)
        unit.weight = 0.8
        unit.guidanceStart = 0.0
        unit.guidanceEnd   = 1.0
        unit.sourceImageBase64 = imageToBase64(referenceImage)
        units = [unit]
        isEnabled = true
        saveConfig()
    }

    /// Preset: Depth + OpenPose para control de pose y profundidad.
    func applyPoseDepthPreset(depthImage: NSImage, poseImage: NSImage) {
        clearUnits()
        var depthUnit = ControlNetUnit(mode: .depth)
        depthUnit.weight = 0.8
        depthUnit.sourceImageBase64 = imageToBase64(depthImage)

        var poseUnit = ControlNetUnit(mode: .openPose)
        poseUnit.weight = 1.0
        poseUnit.sourceImageBase64 = imageToBase64(poseImage)

        units = [depthUnit, poseUnit]
        isEnabled = true
        saveConfig()
    }

    // MARK: - Helpers

    func imageToBase64(_ image: NSImage) -> String? {
        guard let tiff = image.tiffRepresentation,
              let bmp  = NSBitmapImageRep(data: tiff),
              let png  = bmp.representation(using: .png, properties: [:])
        else { return nil }
        return png.base64EncodedString()
    }

    // MARK: - Persistence

    private var configURL: URL? {
        VaultManager.shared.vaultMetaURL?.appending(path: "controlnet_config.json")
    }

    private struct Config: Codable {
        var units:     [ControlNetUnit]
        var isEnabled: Bool
    }

    private func saveConfig() {
        guard let url = configURL else { return }
        let config = Config(units: units, isEnabled: isEnabled)
        if let data = try? JSONEncoder.pretty.encode(config) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func loadConfig() {
        guard let url    = configURL,
              let data   = try? Data(contentsOf: url),
              let config = try? JSONDecoder.iso8601.decode(Config.self, from: data)
        else { return }
        units     = config.units
        isEnabled = config.isEnabled
    }
}

// MARK: - ControlNetView

struct ControlNetView: View {

    @StateObject private var engine = ControlNetEngine.shared
    @Binding var baseURL: String
    @State private var showAddSheet  = false
    @State private var editingUnit:  ControlNetUnit? = nil
    @State private var isPreviewing  = false
    @State private var previewImage: NSImage? = nil

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider().background(Color.white.opacity(0.06))

            if engine.units.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(engine.units) { unit in
                            ControlNetUnitRow(
                                unit: unit,
                                onEdit:   { editingUnit = unit },
                                onRemove: { engine.removeUnit(id: unit.id) },
                                onToggle: { engine.toggleUnit(id: unit.id) }
                            )
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 300)
            }

            if engine.units.count < 3 {
                addBar
            }
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.07), lineWidth: 1))
        .sheet(item: $editingUnit) { unit in
            ControlNetUnitEditor(unit: unit)
        }
        .task(id: baseURL) {
            if engine.availableModels.isEmpty {
                await engine.fetchModelsAndPreprocessors(baseURL: baseURL)
            }
        }
    }

    var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "network")
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "#7c6af7"))
            Text("ControlNet")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)

            Spacer()

            if engine.isLoading {
                ProgressView().controlSize(.mini)
            }

            // Global enable/disable
            Toggle("", isOn: $engine.isEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .scaleEffect(0.7)
                .onChange(of: engine.isEnabled) { _, _ in engine.saveConfig() }

            Text(engine.isEnabled ? "ON" : "OFF")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(engine.isEnabled ? Color(hex: "#34d399") : .secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.white.opacity(0.03))
    }

    var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "network")
                .font(.system(size: 28))
                .foregroundColor(.white.opacity(0.07))
            Text("Sin unidades ControlNet")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Text("Añade una unidad para guiar la generación con imagen de control.")
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.6))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 220)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    var addBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(ControlNetMode.allCases) { mode in
                    Button(action: { engine.addUnit(mode: mode) }) {
                        HStack(spacing: 4) {
                            Image(systemName: mode.icon).font(.system(size: 9))
                            Text(mode.displayName).font(.system(size: 9))
                        }
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(Color.white.opacity(0.04))
                        .cornerRadius(5)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
        .background(Color.white.opacity(0.02))
    }
}

// MARK: - ControlNetUnitRow

struct ControlNetUnitRow: View {
    let unit:     ControlNetUnit
    var onEdit:   () -> Void
    var onRemove: () -> Void
    var onToggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // Enable toggle
            Button(action: onToggle) {
                Image(systemName: unit.enabled ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundColor(unit.enabled ? Color(hex: "#7c6af7") : .secondary)
            }
            .buttonStyle(.plain)

            // Mode icon
            Image(systemName: unit.mode.icon)
                .font(.system(size: 11))
                .foregroundColor(unit.enabled ? Color(hex: "#7c6af7") : .secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(unit.mode.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(unit.enabled ? .white : .secondary)
                HStack(spacing: 6) {
                    Text(unit.effectivePreprocessor)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                    Text("w:\(String(format: "%.2f", unit.weight))")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    if unit.sourceImageBase64 != nil {
                        Image(systemName: "photo.fill")
                            .font(.system(size: 8))
                            .foregroundColor(Color(hex: "#34d399"))
                    }
                }
            }

            Spacer()

            Button(action: onEdit) {
                Image(systemName: "pencil").font(.system(size: 10)).foregroundColor(.secondary)
            }
            .buttonStyle(.plain)

            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 9)).foregroundColor(.secondary.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color.white.opacity(unit.enabled ? 0.04 : 0.02))
        .cornerRadius(7)
    }
}

// MARK: - ControlNetUnitEditor

struct ControlNetUnitEditor: View {

    @State var unit: ControlNetUnit
    @Environment(\.dismiss) private var dismiss
    @State private var sourceImagePicked: NSImage? = nil
    @State private var isPreviewing = false
    @State private var preprocessedPreview: NSImage? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: unit.mode.icon)
                    .font(.system(size: 18))
                    .foregroundColor(Color(hex: "#7c6af7"))
                Text("ControlNet · \(unit.mode.displayName)")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Button("Cancelar") { dismiss() }
                    .buttonStyle(.plain).foregroundColor(.secondary)
                Button("Guardar") {
                    ControlNetEngine.shared.updateUnit(unit)
                    dismiss()
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(Color(hex: "#7c6af7"))
                .foregroundColor(.white).cornerRadius(6)
            }
            .padding(18).background(Color.white.opacity(0.03))

            Divider().background(Color.white.opacity(0.07))

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {

                    // Preprocessor
                    settingRow("Preprocesador") {
                        TextField("ej: depth_midas", text: $unit.preprocessor)
                            .textFieldStyle(.roundedBorder).font(.system(size: 12))
                            .onAppear {
                                if unit.preprocessor.isEmpty {
                                    unit.preprocessor = unit.mode.defaultPreprocessor
                                }
                            }
                    }

                    // Model
                    settingRow("Modelo") {
                        TextField("ej: control_v11f1p_sd15_depth", text: $unit.model)
                            .textFieldStyle(.roundedBorder).font(.system(size: 12))
                            .onAppear {
                                if unit.model.isEmpty { unit.model = unit.mode.defaultModel }
                            }
                    }

                    // Weight
                    settingRow("Peso (\(String(format: "%.2f", unit.weight)))") {
                        Slider(value: $unit.weight, in: 0...2, step: 0.05)
                            .accentColor(Color(hex: "#7c6af7"))
                    }

                    // Guidance
                    HStack(spacing: 12) {
                        settingRow("Inicio (\(String(format: "%.2f", unit.guidanceStart)))") {
                            Slider(value: $unit.guidanceStart, in: 0...1, step: 0.05)
                                .accentColor(Color(hex: "#3de3c0"))
                        }
                        settingRow("Fin (\(String(format: "%.2f", unit.guidanceEnd)))") {
                            Slider(value: $unit.guidanceEnd, in: 0...1, step: 0.05)
                                .accentColor(Color(hex: "#3de3c0"))
                        }
                    }

                    // Canny thresholds
                    if unit.mode == .canny {
                        HStack(spacing: 12) {
                            settingRow("Umbral A (\(Int(unit.thresholdA)))") {
                                Slider(value: $unit.thresholdA, in: 0...255, step: 5)
                                    .accentColor(Color(hex: "#f59e0b"))
                            }
                            settingRow("Umbral B (\(Int(unit.thresholdB)))") {
                                Slider(value: $unit.thresholdB, in: 0...255, step: 5)
                                    .accentColor(Color(hex: "#f59e0b"))
                            }
                        }
                    }

                    // Pixel perfect + low vram
                    HStack(spacing: 20) {
                        Toggle("Pixel Perfect", isOn: $unit.pixelPerfect)
                            .toggleStyle(.switch).scaleEffect(0.85).font(.system(size: 12))
                        Toggle("Low VRAM", isOn: $unit.lowVRAM)
                            .toggleStyle(.switch).scaleEffect(0.85).font(.system(size: 12))
                    }

                    Divider().background(Color.white.opacity(0.07))

                    // Source image picker
                    VStack(alignment: .leading, spacing: 8) {
                        Text("IMAGEN DE CONTROL")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.secondary).tracking(1.2)

                        HStack(spacing: 10) {
                            // Preview thumbnail
                            if let img = sourceImagePicked ?? loadSourcePreview() {
                                Image(nsImage: img)
                                    .resizable().scaledToFill()
                                    .frame(width: 60, height: 60)
                                    .cornerRadius(6).clipped()
                            } else {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.white.opacity(0.05))
                                    .frame(width: 60, height: 60)
                                    .overlay(Image(systemName: "photo").foregroundColor(.secondary))
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Button("Cargar desde archivo") { pickSourceImage() }
                                    .buttonStyle(.plain).font(.system(size: 11))
                                    .foregroundColor(Color(hex: "#7c6af7"))

                                if unit.mode.isReferenceMode && CharacterEngine.shared.activeCharacter != nil {
                                    Button("Usar imagen del personaje activo") {
                                        if let char = CharacterEngine.shared.activeCharacter,
                                           let img  = CharacterEngine.shared.loadBaseImage(for: char) {
                                            sourceImagePicked = img
                                            unit.sourceImageBase64 = ControlNetEngine.shared.imageToBase64(img)
                                        }
                                    }
                                    .buttonStyle(.plain).font(.system(size: 11))
                                    .foregroundColor(Color(hex: "#3de3c0"))
                                }

                                if unit.sourceImageBase64 != nil {
                                    Button("Limpiar") {
                                        unit.sourceImageBase64 = nil
                                        sourceImagePicked = nil
                                    }
                                    .buttonStyle(.plain).font(.system(size: 10))
                                    .foregroundColor(.red.opacity(0.7))
                                }
                            }
                        }
                    }

                    // Preprocessed preview
                    if let preview = preprocessedPreview {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("PREVIEW PREPROCESADO")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.secondary).tracking(1.2)
                            Image(nsImage: preview)
                                .resizable().scaledToFit()
                                .frame(maxHeight: 180)
                                .cornerRadius(6)
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 500, height: 580)
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
    }

    private func loadSourcePreview() -> NSImage? {
        guard let b64  = unit.sourceImageBase64,
              let data = Data(base64Encoded: b64)
        else { return nil }
        return NSImage(data: data)
    }

    private func pickSourceImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.canChooseFiles = true
        panel.title = "Seleccionar imagen de control"
        guard panel.runModal() == .OK,
              let url = panel.url,
              let img = NSImage(contentsOf: url) else { return }
        sourceImagePicked = img
        unit.sourceImageBase64 = ControlNetEngine.shared.imageToBase64(img)
    }

    func settingRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - ControlNet extension: saveConfig public shim
extension ControlNetEngine {
    /// Permite que la extensión de vista llame a saveConfig.
    func saveConfig() {
        guard let url = configURL else { return }
        struct C: Codable { var units: [ControlNetUnit]; var isEnabled: Bool }
        let c = C(units: units, isEnabled: isEnabled)
        if let data = try? JSONEncoder.pretty.encode(c) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private var configURL: URL? {
        VaultManager.shared.vaultMetaURL?.appending(path: "controlnet_config.json")
    }
}
