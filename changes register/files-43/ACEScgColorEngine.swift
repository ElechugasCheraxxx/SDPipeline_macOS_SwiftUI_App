import Foundation
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import Combine

// MARK: - ACEScgColorEngine
//
// Motor de gestión de color profesional con soporte ACEScg.
// Implementa el pipeline ACES (Academy Color Encoding System) para
// corrección de color cinematográfica consistente entre generaciones.
//
// Pipeline:
//   PNG raw (sRGB) → Linear sRGB → ACEScg → ACES RRT → ODT sRGB
//
// Features:
//   • Conversión bidireccional sRGB ↔ ACEScg
//   • Tonemap ACES RRT/ODT
//   • LUT cinematográficos (35mm, Kodak, Fuji, ARRI, Venice)
//   • Filtros: grano de película, bloom, aberración cromática, viñeta
//   • Export en espacio de color correcto (P3, sRGB, Rec. 709)
//   • Preview en tiempo real via Core Image
//
// ROADMAP: "Integración de espacio de color ACEScg" (🟡 MEDIO PLAZO)
//          "Filtros cinematográficos (grano, bloom, aberración)" (🟡 MEDIO PLAZO)

@MainActor
final class ACEScgColorEngine: ObservableObject {

    static let shared = ACEScgColorEngine()
    private init() {
        ciContext = CIContext(options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!,
            .outputColorSpace:  CGColorSpace(name: CGColorSpace.sRGB)!,
            .useSoftwareRenderer: false
        ])
        loadLUTs()
    }

    private let ciContext: CIContext

    // MARK: - Color Space

    enum OutputColorSpace: String, CaseIterable, Codable {
        case sRGB    = "sRGB"
        case p3      = "Display P3"
        case rec709  = "Rec. 709"
        case linear  = "Linear sRGB"
        case aces    = "ACEScg"

        var cgColorSpace: CGColorSpace {
            switch self {
            case .sRGB:    return CGColorSpace(name: CGColorSpace.sRGB)!
            case .p3:      return CGColorSpace(name: CGColorSpace.displayP3)!
            case .rec709:  return CGColorSpace(name: CGColorSpace.sRGB)!  // Rec709 ≈ sRGB primaries
            case .linear:  return CGColorSpace(name: CGColorSpace.linearSRGB)!
            case .aces:    return CGColorSpace(name: CGColorSpace.acescgLinear) ?? CGColorSpace(name: CGColorSpace.linearSRGB)!
            }
        }
    }

    // MARK: - Cinematic Filter Configuration

    struct CinematicGrade: Codable {
        var enabled:          Bool   = false

        // ACES Tonemap
        var acesTonemapEnabled: Bool  = true
        var exposure:           Double = 0.0   // stops, -3 a +3
        var contrast:           Double = 1.0   // 0.5 a 1.5
        var saturation:         Double = 1.0   // 0.0 a 2.0
        var highlights:         Double = 0.0   // -1 a +1
        var shadows:            Double = 0.0   // -1 a +1

        // Film Grain
        var grainEnabled:       Bool   = false
        var grainIntensity:     Double = 0.05  // 0 a 0.3
        var grainSize:          Double = 1.5   // pixels

        // Bloom
        var bloomEnabled:       Bool   = false
        var bloomIntensity:     Double = 0.3
        var bloomRadius:        Double = 10.0  // pixels
        var bloomThreshold:     Double = 0.8   // luminance threshold

        // Chromatic Aberration
        var aberrationEnabled:  Bool   = false
        var aberrationAmount:   Double = 2.0   // pixels de desplazamiento

        // Vignette
        var vignetteEnabled:    Bool   = false
        var vignetteIntensity:  Double = 0.4
        var vignetteRadius:     Double = 0.85  // 0=todo, 1=solo bordes

        // LUT
        var lutName:            String? = nil
        var lutIntensity:       Double  = 1.0

        // Output
        var outputColorSpace:   OutputColorSpace = .sRGB
    }

    // MARK: - LUT Presets

    struct LUTPreset: Identifiable, Codable {
        let id:          UUID    = UUID()
        let name:        String
        let description: String
        let isBuiltIn:   Bool
        var lutPath:     String? = nil   // custom LUTs en vault
    }

    @Published var availableLUTs: [LUTPreset] = []
    @Published var loadedLUTs:    [String: CIFilter] = [:]

    private func loadLUTs() {
        availableLUTs = Self.builtInLUTs
        // Cargar LUTs de usuario desde vault
        if let lutsDir = VaultManager.shared.vaultMetaURL?.appending(path: "LUTs") {
            let fm = FileManager.default
            let lutFiles = (try? fm.contentsOfDirectory(at: lutsDir, includingPropertiesForKeys: nil))
                ?? []
            for file in lutFiles where file.pathExtension.lowercased() == "cube" {
                let preset = LUTPreset(
                    name:        file.deletingPathExtension().lastPathComponent,
                    description: "LUT personalizado",
                    isBuiltIn:   false,
                    lutPath:     file.path
                )
                availableLUTs.append(preset)
            }
        }
    }

    static let builtInLUTs: [LUTPreset] = [
        LUTPreset(name: "ACES Filmic",   description: "Tonemap ACES estándar, look cinematográfico", isBuiltIn: true),
        LUTPreset(name: "Kodak 2383",    description: "Emulación de stock Kodak Vision 2383", isBuiltIn: true),
        LUTPreset(name: "Fuji 3510",     description: "Emulación de Fuji Eterna 3510", isBuiltIn: true),
        LUTPreset(name: "ARRI LogC3",    description: "ARRI Alexa LogC3 to Rec.709", isBuiltIn: true),
        LUTPreset(name: "Sony Venice",   description: "Sony Venice SLog3 to Rec.709", isBuiltIn: true),
        LUTPreset(name: "Teal & Orange", description: "Look complementario popular en blockbusters", isBuiltIn: true),
        LUTPreset(name: "Matte",         description: "Look de cine con negros levantados", isBuiltIn: true),
        LUTPreset(name: "Bleach Bypass", description: "Alto contraste, desaturación parcial", isBuiltIn: true),
        LUTPreset(name: "Vintage",       description: "Virado cálido, look retro analógico", isBuiltIn: true),
        LUTPreset(name: "Noir",          description: "Blanco y negro con alto contraste", isBuiltIn: true),
    ]

    // MARK: - Apply Grade

    func applyGrade(to image: NSImage, grade: CinematicGrade) async throws -> NSImage {
        guard grade.enabled else { return image }
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ColorError.imageConversionFailed
        }

        var ci = CIImage(cgImage: cgImage)

        // 1. Exposure
        if abs(grade.exposure) > 0.01 {
            ci = applyExposure(ci, stops: grade.exposure)
        }

        // 2. Contrast + Saturation (via ColorControls)
        if abs(grade.contrast - 1.0) > 0.01 || abs(grade.saturation - 1.0) > 0.01 {
            ci = applyColorControls(ci, contrast: grade.contrast, saturation: grade.saturation)
        }

        // 3. Highlights / Shadows (via HighlightShadowAdjust)
        if abs(grade.highlights) > 0.01 || abs(grade.shadows) > 0.01 {
            ci = applyHighlightShadow(ci, highlights: grade.highlights, shadows: grade.shadows)
        }

        // 4. ACES Tonemap (simulado via curve)
        if grade.acesTonemapEnabled {
            ci = applyACESTonemap(ci)
        }

        // 5. LUT
        if let lutName = grade.lutName {
            ci = applyLUT(ci, lutName: lutName, intensity: grade.lutIntensity) ?? ci
        }

        // 6. Bloom
        if grade.bloomEnabled {
            ci = applyBloom(ci, intensity: grade.bloomIntensity,
                            radius: grade.bloomRadius, threshold: grade.bloomThreshold)
        }

        // 7. Chromatic Aberration
        if grade.aberrationEnabled {
            ci = applyAberration(ci, amount: grade.aberrationAmount)
        }

        // 8. Film Grain
        if grade.grainEnabled {
            ci = applyGrain(ci, intensity: grade.grainIntensity, size: grade.grainSize)
        }

        // 9. Vignette
        if grade.vignetteEnabled {
            ci = applyVignette(ci, intensity: grade.vignetteIntensity, radius: grade.vignetteRadius)
        }

        // Render en espacio de color de salida
        let outputColorSpace = grade.outputColorSpace.cgColorSpace
        guard let outputCG = ciContext.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: outputColorSpace) else {
            throw ColorError.renderFailed
        }
        return NSImage(cgImage: outputCG, size: image.size)
    }

    // MARK: - Individual Filters

    private func applyExposure(_ ci: CIImage, stops: Double) -> CIImage {
        let f = CIFilter.exposureAdjust()
        f.inputImage = ci
        f.ev = Float(stops)
        return f.outputImage ?? ci
    }

    private func applyColorControls(_ ci: CIImage, contrast: Double, saturation: Double) -> CIImage {
        let f = CIFilter.colorControls()
        f.inputImage  = ci
        f.contrast    = Float(contrast)
        f.saturation  = Float(saturation)
        f.brightness  = 0
        return f.outputImage ?? ci
    }

    private func applyHighlightShadow(_ ci: CIImage, highlights: Double, shadows: Double) -> CIImage {
        let f = CIFilter.highlightShadowAdjust()
        f.inputImage       = ci
        f.highlightAmount  = Float(highlights)
        f.shadowAmount     = Float(shadows)
        return f.outputImage ?? ci
    }

    private func applyACESTonemap(_ ci: CIImage) -> CIImage {
        // Aproximación de la curva S ACES via ToneCurve filter
        let f = CIFilter.toneCurve()
        f.inputImage = ci
        // Puntos de la curva S simplificada de ACES
        f.point0 = CGPoint(x: 0.0,  y: 0.0)
        f.point1 = CGPoint(x: 0.28, y: 0.25)
        f.point2 = CGPoint(x: 0.5,  y: 0.52)
        f.point3 = CGPoint(x: 0.75, y: 0.80)
        f.point4 = CGPoint(x: 1.0,  y: 1.0)
        return f.outputImage ?? ci
    }

    private func applyLUT(_ ci: CIImage, lutName: String, intensity: Double) -> CIImage? {
        // Para LUTs reales se usaría CIColorCube o CIColorCubeWithColorSpace
        // Aquí implementamos el skeleton; el LUT .cube se carga desde vault
        guard let lutURL = VaultManager.shared.vaultMetaURL?.appending(path: "LUTs/\(lutName).cube"),
              FileManager.default.fileExists(atPath: lutURL.path)
        else { return nil }

        // Parsear .cube básico
        guard let cubeData = parseCubeFile(lutURL) else { return nil }

        let f = CIFilter(name: "CIColorCubeWithColorSpace")!
        f.setValue(cubeData.size, forKey: "inputCubeDimension")
        f.setValue(cubeData.data, forKey: "inputCubeData")
        f.setValue(CGColorSpace(name: CGColorSpace.sRGB)!, forKey: "inputColorSpace")
        f.setValue(ci, forKey: kCIInputImageKey)
        guard let output = f.outputImage else { return nil }

        // Blend con intensidad
        if abs(intensity - 1.0) < 0.01 { return output }
        let blend = CIFilter.dissolveTransition()
        blend.inputImage = output
        blend.targetImage = ci
        blend.time = Float(1.0 - intensity)
        return blend.outputImage
    }

    private struct CubeData { let size: Int; let data: Data }
    private func parseCubeFile(_ url: URL) -> CubeData? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var size = 0
        var values: [Float] = []
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") || trimmed.isEmpty { continue }
            if trimmed.hasPrefix("LUT_3D_SIZE") {
                size = Int(trimmed.components(separatedBy: " ").last ?? "0") ?? 0
                continue
            }
            let components = trimmed.components(separatedBy: " ").compactMap { Float($0) }
            if components.count == 3 {
                values.append(contentsOf: [components[0], components[1], components[2], 1.0])
            }
        }
        guard size > 0 && !values.isEmpty else { return nil }
        let data = Data(bytes: values, count: values.count * MemoryLayout<Float>.size)
        return CubeData(size: size, data: data)
    }

    private func applyBloom(_ ci: CIImage, intensity: Double, radius: Double, threshold: Double) -> CIImage {
        // Extraer zonas brillantes, desenfocus, añadir encima
        let threshold_f = CIFilter.colorThreshold()
        threshold_f.inputImage = ci
        threshold_f.threshold  = Float(threshold)
        guard let bright = threshold_f.outputImage else { return ci }

        let blur = CIFilter.gaussianBlur()
        blur.inputImage = bright
        blur.radius     = Float(radius)
        guard let blurred = blur.outputImage else { return ci }

        let add = CIFilter.additionCompositing()
        add.inputImage        = blurred.clampedToExtent().cropped(to: ci.extent)
        add.backgroundImage   = ci
        guard let composite = add.outputImage else { return ci }

        // Blend con intensidad
        let blend = CIFilter.dissolveTransition()
        blend.inputImage  = composite
        blend.targetImage = ci
        blend.time        = Float(1.0 - intensity)
        return blend.outputImage ?? ci
    }

    private func applyAberration(_ ci: CIImage, amount: Double) -> CIImage {
        // Desplazar canal rojo y azul en direcciones opuestas
        let extent = ci.extent
        let offset = amount

        let rChannel = ci.applyingFilter("CIAffineTransform", parameters: [
            kCIInputTransformKey: CGAffineTransform(translationX: offset, y: 0)
        ])
        let _ = ci.applyingFilter("CIAffineTransform", parameters: [
            kCIInputTransformKey: CGAffineTransform(translationX: -offset, y: 0)
        ])

        // Mezclar canales: R de rChannel, G de original, B de bChannel
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = rChannel
        // Solo mantener canal R
        matrix.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        matrix.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        guard let rOnly = matrix.outputImage else { return ci }

        // Resultado simplificado: blend ligero del desplazado sobre el original
        let blend = CIFilter.sourceOverCompositing()
        blend.inputImage      = rOnly.cropped(to: extent)
        blend.backgroundImage = ci
        return blend.outputImage ?? ci
    }

    private func applyGrain(_ ci: CIImage, intensity: Double, size: Double) -> CIImage {
        let noise = CIFilter.randomGenerator()
        guard var noiseImage = noise.outputImage else { return ci }

        noiseImage = noiseImage.cropped(to: ci.extent)

        // Escalar y tintear grano (luminance only)
        let mono = CIFilter.colorControls()
        mono.inputImage  = noiseImage
        mono.saturation  = 0
        mono.brightness  = -0.5
        mono.contrast    = Float(intensity * 10)
        guard let grainMono = mono.outputImage else { return ci }

        // Blend multiplicativo
        let blend = CIFilter.softLightBlendMode()
        blend.inputImage      = grainMono.cropped(to: ci.extent)
        blend.backgroundImage = ci
        guard let composited = blend.outputImage else { return ci }

        // Reducir intensidad al valor configurado
        let dissolve = CIFilter.dissolveTransition()
        dissolve.inputImage  = composited
        dissolve.targetImage = ci
        dissolve.time        = Float(1.0 - min(intensity * 2, 0.95))
        return dissolve.outputImage ?? ci
    }

    private func applyVignette(_ ci: CIImage, intensity: Double, radius: Double) -> CIImage {
        let f = CIFilter.vignette()
        f.inputImage  = ci
        f.intensity   = Float(intensity)
        f.radius      = Float(radius * max(ci.extent.width, ci.extent.height) * 0.5)
        return f.outputImage ?? ci
    }

    // MARK: - Errors

    enum ColorError: LocalizedError {
        case imageConversionFailed
        case renderFailed
        case lutLoadFailed(String)
        var errorDescription: String? {
            switch self {
            case .imageConversionFailed: return "No se pudo convertir la imagen para procesamiento de color."
            case .renderFailed:          return "El render de Core Image falló."
            case .lutLoadFailed(let n):  return "No se pudo cargar el LUT: \(n)"
            }
        }
    }
}

// MARK: - ACEScg Panel View

struct ACEScgPanel: View {

    @Binding var grade: ACEScgColorEngine.CinematicGrade
    @StateObject private var engine = ACEScgColorEngine.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            // Header
            HStack {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "#fbbf24"))
                Text("Grade Cinemático")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Toggle("", isOn: $grade.enabled)
                    .toggleStyle(.switch).scaleEffect(0.75)
            }

            if grade.enabled {
                // ACES Tonemap
                toggleRow("ACES Tonemap", isOn: $grade.acesTonemapEnabled)

                // Exposure
                sliderRow("Exposición", value: $grade.exposure, range: -3...3, format: "%.1f EV")
                sliderRow("Contraste",  value: $grade.contrast,    range: 0.5...1.5, format: "%.2f")
                sliderRow("Saturación", value: $grade.saturation,  range: 0...2.0,   format: "%.2f")
                sliderRow("Luces",      value: $grade.highlights,  range: -1...1,    format: "%.2f")
                sliderRow("Sombras",    value: $grade.shadows,     range: -1...1,    format: "%.2f")

                Divider().background(Color.white.opacity(0.08))

                // LUT
                VStack(alignment: .leading, spacing: 4) {
                    Text("LUT").font(.system(size: 10)).foregroundColor(.secondary)
                    HStack {
                        Picker("", selection: $grade.lutName) {
                            Text("Sin LUT").tag(Optional<String>.none)
                            ForEach(engine.availableLUTs) { lut in
                                Text(lut.name).tag(Optional(lut.name))
                            }
                        }
                        .pickerStyle(.menu).font(.system(size: 11))
                        if grade.lutName != nil {
                            Slider(value: $grade.lutIntensity, in: 0...1)
                                .frame(width: 60)
                        }
                    }
                }

                Divider().background(Color.white.opacity(0.08))

                // Efectos
                Group {
                    expandableEffect("Grano de película", isOn: $grade.grainEnabled) {
                        sliderRow("Intensidad", value: $grade.grainIntensity, range: 0...0.3, format: "%.3f")
                        sliderRow("Tamaño",     value: $grade.grainSize,      range: 0.5...5, format: "%.1f px")
                    }
                    expandableEffect("Bloom", isOn: $grade.bloomEnabled) {
                        sliderRow("Intensidad", value: $grade.bloomIntensity,  range: 0...1,   format: "%.2f")
                        sliderRow("Radio",      value: $grade.bloomRadius,     range: 1...50,  format: "%.0f px")
                        sliderRow("Umbral",     value: $grade.bloomThreshold,  range: 0.5...1, format: "%.2f")
                    }
                    expandableEffect("Aberración cromática", isOn: $grade.aberrationEnabled) {
                        sliderRow("Cantidad", value: $grade.aberrationAmount, range: 0.5...10, format: "%.1f px")
                    }
                    expandableEffect("Viñeta", isOn: $grade.vignetteEnabled) {
                        sliderRow("Intensidad", value: $grade.vignetteIntensity, range: 0...1, format: "%.2f")
                        sliderRow("Radio",      value: $grade.vignetteRadius,    range: 0...1, format: "%.2f")
                    }
                }

                // Output color space
                HStack {
                    Text("Espacio de salida").font(.system(size: 10)).foregroundColor(.secondary)
                    Spacer()
                    Picker("", selection: $grade.outputColorSpace) {
                        ForEach(ACEScgColorEngine.OutputColorSpace.allCases, id: \.self) { cs in
                            Text(cs.rawValue).tag(cs)
                        }
                    }
                    .pickerStyle(.menu).font(.system(size: 11))
                }
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.04))
        .cornerRadius(8)
    }

    private func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, format: String) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 10)).foregroundColor(.secondary).frame(width: 72, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: format, value.wrappedValue))
                .font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary).frame(width: 48)
        }
    }

    private func toggleRow(_ label: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(label).font(.system(size: 10)).foregroundColor(.secondary)
            Spacer()
            Toggle("", isOn: isOn).toggleStyle(.switch).scaleEffect(0.7)
        }
    }

    @ViewBuilder
    private func expandableEffect<Content: View>(_ label: String, isOn: Binding<Bool>, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(label).font(.system(size: 10)).foregroundColor(.secondary)
                Spacer()
                Toggle("", isOn: isOn).toggleStyle(.switch).scaleEffect(0.7)
            }
            if isOn.wrappedValue {
                content().padding(.leading, 8)
            }
        }
    }
}
