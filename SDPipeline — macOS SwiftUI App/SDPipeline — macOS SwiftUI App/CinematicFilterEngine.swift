import Foundation
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import Combine

// MARK: - CinematicFilterEngine
//
// Motor de filtros cinematográficos post-generación usando Core Image.
// Aplica efectos de grano, bloom, aberración cromática, viñeta y LUTs.
// Los filtros son no-destructivos y se aplican en cascada.
// Se integra con PostProductionEngine y el panel de output.

// MARK: - Filter Models

struct CinematicFilter: Codable, Identifiable, Hashable {
    var id:      UUID   = UUID()
    var name:    String
    var type:    FilterType
    var enabled: Bool   = true
    var params:  [String: Double] = [:]

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: CinematicFilter, rhs: CinematicFilter) -> Bool { lhs.id == rhs.id }

    enum FilterType: String, Codable, CaseIterable {
        case filmGrain        = "Grano de película"
        case bloom            = "Bloom"
        case chromaticAberration = "Aberración cromática"
        case vignette         = "Viñeta"
        case colorGrade       = "Color grade"
        case halation         = "Halación"
        case lensBlur         = "Desenfoque de lente"
        case clarity          = "Claridad"
        case shadows          = "Sombras / Luces"
        case temperature      = "Temperatura de color"

        var icon: String {
            switch self {
            case .filmGrain:           return "waveform"
            case .bloom:               return "sun.max.fill"
            case .chromaticAberration: return "rainbow"
            case .vignette:            return "circle.dashed"
            case .colorGrade:          return "camera.filters"
            case .halation:            return "sparkles"
            case .lensBlur:            return "aqi.medium"
            case .clarity:             return "sparkle.magnifyingglass"
            case .shadows:             return "circle.lefthalf.strikethrough"
            case .temperature:         return "thermometer.medium"
            }
        }

        var defaultParams: [String: Double] {
            switch self {
            case .filmGrain:           return ["intensity": 0.15, "size": 2.0, "roughness": 0.3]
            case .bloom:               return ["radius": 8.0, "intensity": 0.4, "threshold": 0.6]
            case .chromaticAberration: return ["amount": 3.0, "angle": 0.0]
            case .vignette:            return ["radius": 1.2, "intensity": 0.4]
            case .colorGrade:          return ["shadows_r": 0, "shadows_g": 0, "shadows_b": 0.1, "highlights_r": 0.05, "highlights_g": 0, "highlights_b": 0]
            case .halation:            return ["radius": 12.0, "intensity": 0.25, "threshold": 0.75]
            case .lensBlur:            return ["radius": 2.0, "quality": 1.0]
            case .clarity:             return ["amount": 0.3]
            case .shadows:             return ["shadows": 0.0, "highlights": 0.0]
            case .temperature:         return ["temp": 0.0, "tint": 0.0]
            }
        }
    }
}

struct CinematicPreset: Codable, Identifiable {
    var id:      UUID              = UUID()
    var name:    String
    var filters: [CinematicFilter]

    // MARK: - Built-in Presets

    static let cinemaVerde = CinematicPreset(
        name: "Cinema Verde",
        filters: [
            .init(name: "Grano", type: .filmGrain, params: ["intensity": 0.12, "size": 1.5, "roughness": 0.25]),
            .init(name: "Color", type: .colorGrade, params: ["shadows_g": 0.05, "highlights_r": 0.03, "shadows_r": -0.03]),
            .init(name: "Viñeta", type: .vignette, params: ["radius": 1.0, "intensity": 0.35])
        ]
    )

    static let neonNoir = CinematicPreset(
        name: "Neon Noir",
        filters: [
            .init(name: "Bloom", type: .bloom, params: ["radius": 15.0, "intensity": 0.6, "threshold": 0.5]),
            .init(name: "Aberración", type: .chromaticAberration, params: ["amount": 4.0, "angle": 45.0]),
            .init(name: "Viñeta fuerte", type: .vignette, params: ["radius": 0.8, "intensity": 0.7]),
            .init(name: "Color", type: .colorGrade, params: ["shadows_b": 0.15, "shadows_r": 0.1, "highlights_r": -0.05])
        ]
    )

    static let goldenHour = CinematicPreset(
        name: "Golden Hour",
        filters: [
            .init(name: "Temperatura", type: .temperature, params: ["temp": 0.15, "tint": 0.02]),
            .init(name: "Halación", type: .halation, params: ["radius": 20.0, "intensity": 0.35, "threshold": 0.65]),
            .init(name: "Bloom suave", type: .bloom, params: ["radius": 6.0, "intensity": 0.25, "threshold": 0.7]),
            .init(name: "Viñeta suave", type: .vignette, params: ["radius": 1.4, "intensity": 0.3])
        ]
    )

    static let filmNegative = CinematicPreset(
        name: "Film Negative",
        filters: [
            .init(name: "Grano fuerte", type: .filmGrain, params: ["intensity": 0.3, "size": 3.0, "roughness": 0.5]),
            .init(name: "Color vintage", type: .colorGrade, params: ["shadows_b": -0.05, "shadows_r": 0.04, "highlights_g": -0.02]),
            .init(name: "Clarity", type: .clarity, params: ["amount": 0.4]),
            .init(name: "Viñeta", type: .vignette, params: ["radius": 1.1, "intensity": 0.45])
        ]
    )

    static let allPresets: [CinematicPreset] = [.cinemaVerde, .neonNoir, .goldenHour, .filmNegative]
}

// MARK: - CinematicFilterEngine

@MainActor
final class CinematicFilterEngine: ObservableObject {

    static let shared = CinematicFilterEngine()
    private init() {}

    // MARK: - State

    @Published var activeFilters: [CinematicFilter] = []
    @Published var isProcessing: Bool = false
    @Published var lastProcessed: NSImage? = nil
    @Published var savedPresets: [CinematicPreset] = CinematicPreset.allPresets

    private let ciContext = CIContext(options: [
        .useSoftwareRenderer: false,
        .workingColorSpace: CGColorSpaceCreateDeviceRGB()
    ])

    // MARK: - Public API

    /// Añadir filtro a la cadena activa.
    func addFilter(type: CinematicFilter.FilterType) {
        let filter = CinematicFilter(
            name:   type.rawValue,
            type:   type,
            params: type.defaultParams
        )
        activeFilters.append(filter)
    }

    func removeFilter(id: UUID) {
        activeFilters.removeAll { $0.id == id }
    }

    func toggleFilter(id: UUID) {
        guard let idx = activeFilters.firstIndex(where: { $0.id == id }) else { return }
        activeFilters[idx].enabled.toggle()
    }

    func updateParam(filterID: UUID, key: String, value: Double) {
        guard let idx = activeFilters.firstIndex(where: { $0.id == filterID }) else { return }
        activeFilters[idx].params[key] = value
    }

    func clearFilters() { activeFilters.removeAll() }

    func applyPreset(_ preset: CinematicPreset) {
        activeFilters = preset.filters
    }

    /// Aplicar todos los filtros activos a una imagen.
    func process(image: NSImage) async -> NSImage? {
        guard !activeFilters.isEmpty else { return image }
        isProcessing = true

        let result = await Task.detached(priority: .userInitiated) { [filters = activeFilters, ctx = ciContext] in
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return image
            }
            var ciImage = CIImage(cgImage: cgImage)

            for filter in filters where filter.enabled {
                ciImage = CinematicFilterEngine.applyFilter(filter, to: ciImage) ?? ciImage
            }

            guard let outputCG = ctx.createCGImage(ciImage, from: ciImage.extent) else {
                return image
            }
            let result = NSImage(size: image.size)
            result.lockFocus()
            NSGraphicsContext.current?.cgContext.draw(outputCG, in: NSRect(origin: .zero, size: image.size))
            result.unlockFocus()
            return result
        }.value

        lastProcessed = result
        isProcessing  = false
        return result
    }

    // MARK: - Filter Application (nonisolated)

    nonisolated private static func applyFilter(_ filter: CinematicFilter, to image: CIImage) -> CIImage? {
        switch filter.type {
        case .filmGrain:
            return applyFilmGrain(image, params: filter.params)
        case .bloom:
            return applyBloom(image, params: filter.params)
        case .chromaticAberration:
            return applyChromaticAberration(image, params: filter.params)
        case .vignette:
            return applyVignette(image, params: filter.params)
        case .colorGrade:
            return applyColorGrade(image, params: filter.params)
        case .halation:
            return applyHalation(image, params: filter.params)
        case .lensBlur:
            return applyLensBlur(image, params: filter.params)
        case .clarity:
            return applyClarity(image, params: filter.params)
        case .shadows:
            return applyShadowsHighlights(image, params: filter.params)
        case .temperature:
            return applyTemperature(image, params: filter.params)
        }
    }

    // MARK: - Individual Filters

    nonisolated private static func applyFilmGrain(_ image: CIImage, params: [String: Double]) -> CIImage? {
        let intensity  = params["intensity"] ?? 0.15
        
        // CORRECCIÓN: grainSize se declaró pero no se usaba. Ha sido eliminado.
        guard let noiseFilter = CIFilter(name: "CIRandomGenerator"),
              let noiseImage  = noiseFilter.outputImage
        else { return image }

        let scaledNoise = noiseImage
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: intensity, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: intensity, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: intensity, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: -intensity/2, y: -intensity/2, z: -intensity/2, w: 0)
            ])
            .cropped(to: image.extent)

        return image.applyingFilter("CIAdditionCompositing", parameters: [
            kCIInputImageKey: scaledNoise
        ])
    }

    nonisolated private static func applyBloom(_ image: CIImage, params: [String: Double]) -> CIImage? {
        let radius    = params["radius"]    ?? 8.0
        let intensity = params["intensity"] ?? 0.4

        guard let bloom = CIFilter(name: "CIBloom") else { return image }
        bloom.setValue(image, forKey: kCIInputImageKey)
        bloom.setValue(radius,    forKey: kCIInputRadiusKey)
        bloom.setValue(intensity, forKey: kCIInputIntensityKey)
        return bloom.outputImage
    }

    nonisolated private static func applyChromaticAberration(_ image: CIImage, params: [String: Double]) -> CIImage? {
        let amount  = params["amount"] ?? 3.0
        let angle   = params["angle"]  ?? 0.0
        let radians = angle * .pi / 180

        let offsetX = amount * cos(radians)
        let offsetY = amount * sin(radians)

        let rChannel = image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ]).transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))

        let bChannel = image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ]).transformed(by: CGAffineTransform(translationX: -offsetX, y: -offsetY))

        let gChannel = image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ])

        return rChannel
            .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: gChannel])
            .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: bChannel])
            .cropped(to: image.extent)
    }

    nonisolated private static func applyVignette(_ image: CIImage, params: [String: Double]) -> CIImage? {
        let radius    = params["radius"]    ?? 1.2
        let intensity = params["intensity"] ?? 0.4

        guard let vignette = CIFilter(name: "CIVignette") else { return image }
        vignette.setValue(image,     forKey: kCIInputImageKey)
        vignette.setValue(radius,    forKey: kCIInputRadiusKey)
        vignette.setValue(intensity, forKey: kCIInputIntensityKey)
        return vignette.outputImage
    }

    nonisolated private static func applyColorGrade(_ image: CIImage, params: [String: Double]) -> CIImage? {
        let sr = params["shadows_r"] ?? 0, sg = params["shadows_g"] ?? 0, sb = params["shadows_b"] ?? 0
        let hr = params["highlights_r"] ?? 0, hg = params["highlights_g"] ?? 0, hb = params["highlights_b"] ?? 0

        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1.0 + hr, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 1.0 + hg, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 1.0 + hb, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: sr, y: sg, z: sb, w: 0)
        ])
    }

    nonisolated private static func applyHalation(_ image: CIImage, params: [String: Double]) -> CIImage? {
        let radius    = params["radius"]    ?? 12.0
        let intensity = params["intensity"] ?? 0.25

        let redHighlights = image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ])

        guard let blurFilter = CIFilter(name: "CIGaussianBlur") else { return image }
        blurFilter.setValue(redHighlights, forKey: kCIInputImageKey)
        blurFilter.setValue(radius, forKey: kCIInputRadiusKey)

        guard let blurred = blurFilter.outputImage?.cropped(to: image.extent) else { return image }

        let scaledBlur = blurred.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: intensity, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ])

        return image.applyingFilter("CIAdditionCompositing", parameters: [
            kCIInputImageKey: scaledBlur
        ])
    }

    nonisolated private static func applyLensBlur(_ image: CIImage, params: [String: Double]) -> CIImage? {
        let radius = params["radius"] ?? 2.0
        guard let blur = CIFilter(name: "CIDiscBlur") else { return image }
        blur.setValue(image, forKey: kCIInputImageKey)
        blur.setValue(radius, forKey: kCIInputRadiusKey)
        return blur.outputImage?.cropped(to: image.extent)
    }

    nonisolated private static func applyClarity(_ image: CIImage, params: [String: Double]) -> CIImage? {
        let amount = params["amount"] ?? 0.3
        guard let unsharp = CIFilter(name: "CIUnsharpMask") else { return image }
        unsharp.setValue(image,        forKey: kCIInputImageKey)
        unsharp.setValue(2.5,          forKey: kCIInputRadiusKey)
        unsharp.setValue(amount * 0.5, forKey: kCIInputIntensityKey)
        return unsharp.outputImage
    }

    nonisolated private static func applyShadowsHighlights(_ image: CIImage, params: [String: Double]) -> CIImage? {
        let shadows    = params["shadows"]    ?? 0
        let highlights = params["highlights"] ?? 0
        guard let filter = CIFilter(name: "CIHighlightShadowAdjust") else { return image }
        filter.setValue(image,              forKey: kCIInputImageKey)
        filter.setValue(1.0 + highlights,   forKey: "inputHighlightAmount")
        filter.setValue(0.75 + shadows,     forKey: "inputShadowAmount")
        return filter.outputImage
    }

    nonisolated private static func applyTemperature(_ image: CIImage, params: [String: Double]) -> CIImage? {
        let temp = params["temp"] ?? 0
        let tint = params["tint"] ?? 0
        guard let filter = CIFilter(name: "CITemperatureAndTint") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: 6500 + temp * 2000, y: tint * 100), forKey: "inputNeutral")
        filter.setValue(CIVector(x: 6500, y: 0), forKey: "inputTargetNeutral")
        return filter.outputImage
    }

    // MARK: - Preset Management

    func saveCurrentAsPreset(name: String) {
        let preset = CinematicPreset(name: name, filters: activeFilters)
        savedPresets.insert(preset, at: 0)
        persistPresets()
    }

    func deletePreset(id: UUID) {
        savedPresets.removeAll { $0.id == id }
        persistPresets()
    }

    private func persistPresets() {
        guard let url = VaultManager.shared.vaultMetaURL?.appending(path: "cinematic_presets.json"),
              let data = try? JSONEncoder.pretty.encode(savedPresets)
        else { return }
        try? data.write(to: url, options: .atomic)
    }

    func loadPersistedPresets() {
        guard let url = VaultManager.shared.vaultMetaURL?.appending(path: "cinematic_presets.json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder.iso8601.decode([CinematicPreset].self, from: data)
        else { return }
        savedPresets = decoded
    }
}

// MARK: - CinematicFilterView

struct CinematicFilterView: View {

    @StateObject private var engine = CinematicFilterEngine.shared
    var sourceImage: NSImage?
    @State private var previewing = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "camera.filters")
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "#7c6af7"))
                Text("Filtros cinematográficos")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                if engine.isProcessing {
                    ProgressView().scaleEffect(0.7)
                }
                Button(action: applyPreview) {
                    Text("Preview")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color(hex: "#7c6af7"))
                }
                .buttonStyle(.plain)
                .disabled(sourceImage == nil || engine.activeFilters.isEmpty)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.white.opacity(0.03))

            // Presets
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(engine.savedPresets) { preset in
                        presetPill(preset)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
            .background(Color.white.opacity(0.02))

            Divider().background(Color.white.opacity(0.06))

            // Active filter chain
            if engine.activeFilters.isEmpty {
                addFilterPrompt
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(engine.activeFilters) { filter in
                            filterRow(filter)
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 200)
            }

            Divider().background(Color.white.opacity(0.06))

            // Add filter menu
            addFilterBar
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    func presetPill(_ preset: CinematicPreset) -> some View {
        Button(action: { engine.applyPreset(preset) }) {
            Text(preset.name)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.white.opacity(0.8))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.white.opacity(0.06))
                .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }

    func filterRow(_ filter: CinematicFilter) -> some View {
        HStack(spacing: 8) {
            Button(action: { engine.toggleFilter(id: filter.id) }) {
                Image(systemName: filter.enabled ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundColor(filter.enabled ? Color(hex: "#7c6af7") : .secondary)
            }
            .buttonStyle(.plain)

            Image(systemName: filter.type.icon)
                .font(.system(size: 10))
                .foregroundColor(filter.enabled ? .white : .secondary)
                .frame(width: 16)

            Text(filter.name)
                .font(.system(size: 11))
                .foregroundColor(filter.enabled ? .white : .secondary)

            Spacer()

            Button(action: { engine.removeFilter(id: filter.id) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Color.white.opacity(filter.enabled ? 0.04 : 0.02))
        .cornerRadius(5)
    }

    var addFilterPrompt: some View {
        Text("Añade filtros desde el menú inferior")
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity)
            .padding(16)
    }

    var addFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(CinematicFilter.FilterType.allCases, id: \.self) { type in
                    Button(action: { engine.addFilter(type: type) }) {
                        HStack(spacing: 4) {
                            Image(systemName: type.icon).font(.system(size: 9))
                            Text(type.rawValue).font(.system(size: 9))
                        }
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color.white.opacity(0.04))
                        .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
        .background(Color.white.opacity(0.02))
    }

    func applyPreview() {
        guard let img = sourceImage else { return }
        Task {
            _ = await engine.process(image: img)
        }
    }
}
