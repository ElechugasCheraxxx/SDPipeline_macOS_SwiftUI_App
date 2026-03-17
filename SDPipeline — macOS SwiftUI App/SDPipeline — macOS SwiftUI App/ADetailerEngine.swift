import Foundation
import AppKit
import SwiftUI
import Combine

// MARK: - ADetailerEngine
//
// Integración con la extensión ADetailer para A1111.
// ADetailer detecta automáticamente caras, manos, cuerpos y las refina
// con un segundo pase de img2img sobre las regiones detectadas.
//
// Modelos ADetailer disponibles:
//   - face_yolov8n.pt             → Detección de caras (rápido)
//   - face_yolov8s.pt             → Detección de caras (preciso)
//   - hand_yolov8n.pt             → Detección de manos
//   - person_yolov8n-seg.pt       → Segmentación de personas
//   - mediapipe_face_full          → MediaPipe cara (alta calidad)
//   - mediapipe_face_short         → MediaPipe cara (fast)
//   - mediapipe_face_mesh          → MediaPipe mesh facial
//
// Inyección: via alwayson_scripts.ADetailer.args en el SDRequest payload
//
// Compatibilidad: se combina con ControlNet (ambos usan alwayson_scripts)
//
// ROADMAP: "ADetailer Pro para manos/rostros" + "Refinamiento facial automático" (🟡 MEDIO PLAZO)

// MARK: - ADetailer Models

struct ADetailerUnit: Codable, Identifiable {
    var id:              UUID   = UUID()
    var enabled:         Bool   = true
    var model:           ADetailerModel = .faceFull

    // Detección
    var confidenceThreshold: Double = 0.3      // 0.0–1.0
    var dilateErode:         Int    = 32        // expansión de máscara
    var maskBlur:            Int    = 4
    var maskPadding:         Int    = 0         // padding adicional

    // Inpaint
    var denoiseStrength:     Double = 0.40      // bajo = suave, alto = cambio más drástico
    var cfgScale:            Double = 7.0
    var steps:               Int    = 20
    var samplerName:         String = ""        // vacío = usar el mismo del job principal
    var prompt:              String = ""        // vacío = usar el mismo del job principal
    var negativePrompt:      String = ""
    var width:               Int    = 512       // 0 = auto (match detection)
    var height:              Int    = 512

    // Opciones avanzadas
    var inpaintFullRes:      Bool   = true
    var inpaintFullResPadding: Int  = 0
    var useInpaintWidthHeight: Bool = false     // forzar width/height arriba

    var displayName: String { model.displayName }

    // MARK: - API Serialization

    var toAPIDict: [String: Any] {
        let dict: [String: Any] = [
            "ad_model":                       model.rawValue,
            "ad_prompt":                      prompt,
            "ad_negative_prompt":             negativePrompt,
            "ad_confidence":                  confidenceThreshold,
            "ad_mask_k_largest":              0,
            "ad_mask_min_ratio":              0.0,
            "ad_mask_max_ratio":              1.0,
            "ad_dilate_erode":               dilateErode,
            "ad_x_offset":                    0,
            "ad_y_offset":                    0,
            "ad_mask_merge_invert":           "None",
            "ad_mask_blur":                   maskBlur,
            "ad_denoising_strength":          denoiseStrength,
            "ad_inpaint_only_masked":         inpaintFullRes,
            "ad_inpaint_only_masked_padding": inpaintFullResPadding,
            "ad_use_inpaint_width_height":    useInpaintWidthHeight,
            "ad_inpaint_width":               width,
            "ad_inpaint_height":              height,
            "ad_use_steps":                   steps > 0,
            "ad_steps":                       steps,
            "ad_use_cfg_scale":               true,
            "ad_cfg_scale":                   cfgScale,
            "ad_use_sampler":                 !samplerName.isEmpty,
            "ad_sampler":                     samplerName.isEmpty ? "DPM++ 2M Karras" : samplerName,
            "ad_use_noise_multiplier":        false,
            "ad_noise_multiplier":            1.0,
            "ad_use_clip_skip":               false,
            "ad_clip_skip":                   1,
            "ad_restore_face":                false,
            "ad_controlnet_model":            "None",
            "ad_controlnet_module":           "None",
            "ad_controlnet_weight":           1.0,
            "ad_controlnet_guidance_start":   0.0,
            "ad_controlnet_guidance_end":     1.0
        ]
        return dict
    }
}

// MARK: - ADetailer Model List

enum ADetailerModel: String, Codable, CaseIterable, Identifiable {
    // Face
    case faceYolov8n   = "face_yolov8n.pt"
    case faceYolov8s   = "face_yolov8s.pt"
    case faceFull      = "mediapipe_face_full"
    case faceShort     = "mediapipe_face_short"
    case faceMesh      = "mediapipe_face_mesh"

    // Body
    case handYolov8n   = "hand_yolov8n.pt"
    case personSeg     = "person_yolov8n-seg.pt"
    case bodyYolov8n   = "body_yolov8n.pt"

    // Combined
    case faceHand      = "face_yolov8n_seg.pt"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .faceYolov8n:  return "Face YOLOv8n (Rápido)"
        case .faceYolov8s:  return "Face YOLOv8s (Preciso)"
        case .faceFull:     return "MediaPipe Face Full (Recomendado)"
        case .faceShort:    return "MediaPipe Face Short"
        case .faceMesh:     return "MediaPipe Face Mesh"
        case .handYolov8n:  return "Hand YOLOv8n"
        case .personSeg:    return "Person Segmentation"
        case .bodyYolov8n:  return "Body YOLOv8n"
        case .faceHand:     return "Face + Hands YOLOv8"
        }
    }

    var category: Category {
        switch self {
        case .faceYolov8n, .faceYolov8s, .faceFull, .faceShort, .faceMesh: return .face
        case .handYolov8n, .faceHand:                                        return .hands
        case .personSeg, .bodyYolov8n:                                       return .body
        }
    }

    enum Category: String, CaseIterable {
        case face  = "Cara"
        case hands = "Manos"
        case body  = "Cuerpo"

        var icon: String {
            switch self {
            case .face:  return "face.smiling"
            case .hands: return "hand.raised.fill"
            case .body:  return "figure.stand"
            }
        }
    }
}

// MARK: - ADetailer Preset

struct ADetailerPreset: Codable, Identifiable {
    var id:          UUID           = UUID()
    var name:        String
    var description: String         = ""
    var units:       [ADetailerUnit]

    static let builtins: [ADetailerPreset] = [
        ADetailerPreset(
            name: "Face Enhance (Standard)",
            description: "Refinamiento de cara. Denoise suave para mantener identidad.",
            units: [ADetailerUnit(
                enabled: true,
                model: .faceFull,
                confidenceThreshold: 0.3,
                dilateErode: 32,
                maskBlur: 4,
                denoiseStrength: 0.40,
                cfgScale: 7.0,
                steps: 20
            )]
        ),
        ADetailerPreset(
            name: "Face + Hands",
            description: "Refinamiento simultáneo de cara y manos.",
            units: [
                ADetailerUnit(
                    enabled: true,
                    model: .faceFull,
                    confidenceThreshold: 0.3,
                    denoiseStrength: 0.40,
                    steps: 20
                ),
                ADetailerUnit(
                    enabled: true,
                    model: .handYolov8n,
                    confidenceThreshold: 0.3,
                    dilateErode: 16,
                    denoiseStrength: 0.50,
                    steps: 25
                )
            ]
        ),
        ADetailerPreset(
            name: "Portrait Full Refinement",
            description: "Cara + alta fidelidad. Denoise más alto para corrección de artefactos.",
            units: [ADetailerUnit(
                enabled: true,
                model: .faceYolov8s,
                confidenceThreshold: 0.25,
                dilateErode: 48,
                maskBlur: 8,
                denoiseStrength: 0.55,
                cfgScale: 8.0,
                steps: 28,
                inpaintFullResPadding: 32
            )]
        ),
        ADetailerPreset(
            name: "Minimal — Just Fix Eyes",
            description: "Denoise muy bajo. Sólo corrige detalles mínimos de la cara.",
            units: [ADetailerUnit(
                enabled: true,
                model: .faceFull,
                confidenceThreshold: 0.4,
                dilateErode: 16,
                maskBlur: 2,
                denoiseStrength: 0.25,
                steps: 15
            )]
        )
    ]
}

// MARK: - ADetailerEngine

@MainActor
final class ADetailerEngine: ObservableObject {

    static let shared = ADetailerEngine()
    private init() { loadPresets() }

    // MARK: - State

    @Published var isAvailable:  Bool               = false
    @Published var isEnabled:    Bool               = false
    @Published var activeUnits:  [ADetailerUnit]    = []
    @Published var activePreset: ADetailerPreset?   = nil
    @Published var presets:      [ADetailerPreset]  = []
    @Published var versionInfo:  String             = "—"

    private var presetsURL: URL? {
        VaultManager.shared.vaultMetaURL?.appending(path: "adetailer_presets.json")
    }

    // MARK: - Availability

    func checkAvailability(baseURL: String) async {
        // ADetailer no expone un endpoint /version directo,
        // pero podemos verificar si aparece en /sdapi/v1/scripts
        guard let url = URL(string: "\(baseURL)/sdapi/v1/scripts") else {
            isAvailable = false
            return
        }

        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            isAvailable = false
            return
        }

        let txt2imgScripts = (json["txt2img"] as? [String]) ?? []
        let img2imgScripts = (json["img2img"] as? [String]) ?? []
        let allScripts     = txt2imgScripts + img2imgScripts

        isAvailable = allScripts.contains { $0.lowercased().contains("adetailer") }
        versionInfo = isAvailable ? "Instalado" : "No instalado"
    }

    // MARK: - Inject into Request Payload

    /// Inyecta unidades ADetailer en el payload. Combina con ControlNet si ya existe.
    func injectIntoPayload(_ payload: inout [String: Any]) {
        guard isEnabled, !activeUnits.isEmpty else { return }

        let enabledUnits = activeUnits.filter { $0.enabled }
        guard !enabledUnits.isEmpty else { return }

        // Primer arg siempre es {enabled: true}, luego un dict por unidad
        var args: [Any] = [true]
        args.append(contentsOf: enabledUnits.map { $0.toAPIDict })

        var scripts = payload["alwayson_scripts"] as? [String: Any] ?? [:]
        scripts["ADetailer"] = ["args": args]
        payload["alwayson_scripts"] = scripts
    }

    func alwaysOnArgs() -> [String: Any]? {
        guard isEnabled, !activeUnits.isEmpty else { return nil }
        let enabled = activeUnits.filter { $0.enabled }
        guard !enabled.isEmpty else { return nil }
        var args: [Any] = [true]
        args.append(contentsOf: enabled.map { $0.toAPIDict })
        return ["ADetailer": ["args": args]]
    }

    // MARK: - Preset Management

    func applyPreset(_ preset: ADetailerPreset) {
        activePreset = preset
        activeUnits  = preset.units
        isEnabled    = true
    }

    func clearActive() {
        activePreset = nil
        activeUnits  = []
        isEnabled    = false
    }

    func addUnit(_ unit: ADetailerUnit) {
        guard activeUnits.count < 5 else { return }  // ADetailer soporta hasta 5 unidades
        activeUnits.append(unit)
        isEnabled = true
    }

    func removeUnit(id: UUID) {
        activeUnits.removeAll { $0.id == id }
        if activeUnits.isEmpty { isEnabled = false }
    }

    func updateUnit(_ unit: ADetailerUnit) {
        if let idx = activeUnits.firstIndex(where: { $0.id == unit.id }) {
            activeUnits[idx] = unit
        }
    }

    // MARK: - Quick Setup

    func quickSetupFace() {
        if let preset = presets.first(where: { $0.name.contains("Standard") }) {
            applyPreset(preset)
        } else {
            activeUnits = [ADetailerUnit(enabled: true, model: .faceFull)]
            isEnabled = true
        }
    }

    func quickSetupFaceAndHands() {
        if let preset = presets.first(where: { $0.name.contains("Hands") }) {
            applyPreset(preset)
        } else {
            activeUnits = [
                ADetailerUnit(enabled: true, model: .faceFull),
                ADetailerUnit(enabled: true, model: .handYolov8n)
            ]
            isEnabled = true
        }
    }

    // MARK: - Persistence

    private func loadPresets() {
        var all: [ADetailerPreset] = ADetailerPreset.builtins

        if let url  = presetsURL,
           let data = try? Data(contentsOf: url),
           let custom = try? JSONDecoder.iso8601.decode([ADetailerPreset].self, from: data) {
            all.append(contentsOf: custom)
        }

        presets = all
    }

    func saveCustomPreset(name: String, description: String = "") {
        let preset = ADetailerPreset(name: name, description: description, units: activeUnits)
        var custom = presets.filter { p in !ADetailerPreset.builtins.contains { $0.id == p.id } }
        custom.append(preset)
        if let url  = presetsURL,
           let data = try? JSONEncoder.pretty.encode(custom) {
            try? data.write(to: url)
        }
        loadPresets()
    }
}

// MARK: - ADetailerPanel (SwiftUI)

struct ADetailerPanel: View {

    @StateObject private var engine   = ADetailerEngine.shared
    @StateObject private var cnEngine = ControlNetEngine.shared
    @State private var showPresets    = false
    @State private var editingUnit:   ADetailerUnit? = nil
    let baseURL: String

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "face.smiling.inverse")
                    .font(.system(size: 12))
                    .foregroundColor(engine.isAvailable ? Color(hex: "#f472b6") : .secondary)

                Text("ADetailer")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))

                if engine.isAvailable {
                    Text("Instalado")
                        .font(.system(size: 9))
                        .foregroundColor(Color(hex: "#34d399"))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color(hex: "#34d399").opacity(0.12))
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
                    // Quick buttons
                    HStack(spacing: 6) {
                        quickButton("Cara", icon: "face.smiling") { engine.quickSetupFace() }
                        quickButton("Cara + Manos", icon: "hand.raised") { engine.quickSetupFaceAndHands() }
                        Spacer()
                        Button(action: { showPresets = true }) {
                            Image(systemName: "list.bullet")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Presets")
                    }

                    // Active units
                    if !engine.activeUnits.isEmpty {
                        VStack(spacing: 3) {
                            ForEach(engine.activeUnits) { unit in
                                ADetailerUnitRow(
                                    unit: unit,
                                    onEdit: { editingUnit = unit },
                                    onRemove: { engine.removeUnit(id: unit.id) }
                                )
                            }
                        }
                    }

                    // Compatibility badge (ControlNet)
                    if cnEngine.isEnabled && !cnEngine.activeUnits.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "link")
                                .font(.system(size: 9))
                                .foregroundColor(Color(hex: "#3de3c0"))
                            Text("Compatible con ControlNet activo")
                                .font(.system(size: 9))
                                .foregroundColor(Color(hex: "#3de3c0"))
                        }
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color(hex: "#3de3c0").opacity(0.08))
                        .cornerRadius(4)
                    }
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
        .task { await engine.checkAvailability(baseURL: baseURL) }
        .sheet(isPresented: $showPresets) {
            ADetailerPresetPickerSheet { preset in
                engine.applyPreset(preset)
                showPresets = false
            }
        }
        .sheet(item: $editingUnit) { unit in
            ADetailerUnitEditor(unit: unit) { updated in
                engine.updateUnit(updated)
                editingUnit = nil
            }
        }
    }

    func quickButton(_ label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9))
                Text(label).font(.system(size: 10))
            }
            .foregroundColor(.white.opacity(0.8))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.white.opacity(0.06))
            .cornerRadius(5)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - ADetailerUnitRow

struct ADetailerUnitRow: View {
    let unit:     ADetailerUnit
    var onEdit:   () -> Void
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: unit.model.category.icon)
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#f472b6"))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(unit.model.displayName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("Denoise: \(unit.denoiseStrength, specifier: "%.2f")")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text("Confianza: \(unit.confidenceThreshold, specifier: "%.2f")")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }.buttonStyle(.plain)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color.white.opacity(0.04))
        .cornerRadius(5)
    }
}

// MARK: - ADetailerPresetPickerSheet

struct ADetailerPresetPickerSheet: View {
    var onSelect: (ADetailerPreset) -> Void
    @StateObject private var engine = ADetailerEngine.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Presets ADetailer")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }.buttonStyle(.plain)
            }
            .padding(16)
            .background(Color.white.opacity(0.03))

            Divider().background(Color.white.opacity(0.07))

            List(engine.presets) { preset in
                Button(action: { onSelect(preset) }) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(preset.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                        Text(preset.description)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Text("\(preset.units.count) unidad\(preset.units.count != 1 ? "es" : "")")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary.opacity(0.6))
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
        .frame(width: 380, height: 380)
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
    }
}

// MARK: - ADetailerUnitEditor

struct ADetailerUnitEditor: View {
    @State var unit: ADetailerUnit
    var onSave: (ADetailerUnit) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Editar ADetailer Unit")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Button("Cancelar") { dismiss() }.buttonStyle(.plain).foregroundColor(.secondary)
                Button("Guardar") { onSave(unit); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(hex: "#f472b6"))
                    .controlSize(.small)
            }
            .padding(16)
            .background(Color.white.opacity(0.03))

            Divider().background(Color.white.opacity(0.07))

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // Model
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Modelo").font(.system(size: 10)).foregroundColor(.secondary)
                        Picker("", selection: $unit.model) {
                            ForEach(ADetailerModel.Category.allCases, id: \.self) { cat in
                                Section(cat.rawValue) {
                                    ForEach(ADetailerModel.allCases.filter { $0.category == cat }) { m in
                                        Text(m.displayName).tag(m)
                                    }
                                }
                            }
                        }
                        .pickerStyle(.menu)
                        .font(.system(size: 11))
                    }

                    // Sliders
                    VStack(spacing: 8) {
                        adSlider("Denoise", value: $unit.denoiseStrength, range: 0.1...1.0, format: "%.2f")
                        adSlider("Confianza", value: $unit.confidenceThreshold, range: 0.1...1.0, format: "%.2f")
                        adSlider("CFG Scale", value: $unit.cfgScale, range: 1...20, format: "%.1f")
                        adSlider("Dilate/Erode", value: Binding(
                            get: { Double(unit.dilateErode) },
                            set: { unit.dilateErode = Int($0) }
                        ), range: 0...64, format: "%.0f")
                        adSlider("Mask Blur", value: Binding(
                            get: { Double(unit.maskBlur) },
                            set: { unit.maskBlur = Int($0) }
                        ), range: 0...20, format: "%.0f")
                    }

                    HStack(spacing: 16) {
                        Toggle("Full Res Inpaint", isOn: $unit.inpaintFullRes)
                            .font(.system(size: 11))
                    }

                    // Prompt override
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Prompt override (vacío = usar prompt principal)")
                            .font(.system(size: 10)).foregroundColor(.secondary)
                        TextField("Prompt adicional para esta región…", text: $unit.prompt)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 400, height: 460)
        .background(Color(red: 0.10, green: 0.10, blue: 0.13))
    }

    func adSlider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, format: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10)).foregroundColor(.secondary)
                .frame(width: 90, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: format, value.wrappedValue))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 36)
        }
    }
}

// MARK: - Unit Factory

extension ADetailerEngine {
    /// Creates an ADetailerUnit with the given model. Used by HiResFinishEngine.
    func createUnit(model: ADetailerModel = .faceFull,
                    denoiseStrength: Double = 0.40) -> ADetailerUnit {
        ADetailerUnit(model: model, denoiseStrength: denoiseStrength)
    }
}
