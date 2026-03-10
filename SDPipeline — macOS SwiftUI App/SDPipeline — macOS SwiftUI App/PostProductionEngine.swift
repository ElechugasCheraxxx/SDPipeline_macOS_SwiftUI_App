import Foundation
import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers

// MARK: - PostProductionEngine
//
// Pipeline de post-procesado vía A1111 /sdapi/v1/extra-single-image
//
// Operaciones:
//   .upscale      — ESRGAN/R-ESRGAN/SwinIR upscaling
//   .faceRestore  — GFPGAN / CodeFormer
//   .combined     — Upscale + Face restore en un solo request
//
// Complementa ExportEngine (que hace EXIF scrub + watermark + dual export).
// PostProductionEngine se ejecuta ANTES del export final.

// MARK: - Models

enum PostProdOperation: String, Codable, CaseIterable {
    case upscale     = "Upscale"
    case faceRestore = "Restaurar Rostros"
    case combined    = "Upscale + Rostros"

    var icon: String {
        switch self {
        case .upscale:     return "arrow.up.left.and.arrow.down.right"
        case .faceRestore: return "face.smiling"
        case .combined:    return "sparkles"
        }
    }
}

struct PostProdSettings {
    // Upscale
    var upscaler1:          String  = "R-ESRGAN 4x+"
    var upscaler2:          String  = "None"
    var upscaler2Visibility: Double = 0.0
    var upscaleBy:          Double  = 2.0      // multiplicador
    var upscaleToWidth:     Int     = 0        // 0 = usar upscaleBy
    var upscaleToHeight:    Int     = 0
    var resizeToWidth:      Int     = 0
    var resizeToHeight:     Int     = 0

    // Face restore
    var codeFormerWeight:   Double  = 0.5
    var faceRestoreModel:   String  = "CodeFormer"  // o "GFPGAN"

    // Tiling (para imágenes muy grandes)
    var tileWidth:          Int     = 512
    var tileHeight:         Int     = 0        // 0 = auto

    static let upscalerOptions = [
        "R-ESRGAN 4x+", "R-ESRGAN 4x+ Anime6B", "ESRGAN_4x",
        "SwinIR 4x", "Lanczos", "Nearest", "None"
    ]

    static let faceRestoreOptions = ["CodeFormer", "GFPGAN"]
}

struct PostProdResult: Identifiable {
    var id:          UUID    = UUID()
    var image:       NSImage
    var savedPath:   String? = nil
    var operation:   PostProdOperation
    var duration:    Double
    var originalSize: CGSize
    var resultSize:  CGSize
}

// MARK: - PostProductionEngine

@MainActor
final class PostProductionEngine: ObservableObject {

    static let shared = PostProductionEngine()
    private init() {}

    // MARK: - State

    @Published var isProcessing:  Bool               = false
    @Published var progress:      Double             = 0
    @Published var progressText:  String             = ""
    @Published var result:        PostProdResult?    = nil
    @Published var errorMessage:  String?            = nil
    @Published var availableUpscalers: [String]      = PostProdSettings.upscalerOptions

    // MARK: - Fetch Available Upscalers

    func fetchUpscalers(baseURL: String) async {
        guard let url = URL(string: "\(baseURL)/sdapi/v1/upscalers") else { return }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return }
        let names = json.compactMap { $0["name"] as? String }
        if !names.isEmpty { availableUpscalers = names }
    }

    // MARK: - Process

    func process(
        image:     NSImage,
        settings:  PostProdSettings,
        operation: PostProdOperation,
        baseURL:   String
    ) async {
        guard !isProcessing else { return }
        isProcessing  = true
        errorMessage  = nil
        result        = nil
        progress      = 0.1
        progressText  = "Preparando post-procesado…"

        let startTime = Date()

        do {
            let b64 = try imageToBase64(image)
            let payload = buildPayload(b64: b64, settings: settings, operation: operation)

            progress     = 0.3
            progressText = "\(operation.rawValue)…"

            let url    = URL(string: "\(baseURL)/sdapi/v1/extra-single-image")!
            var req    = URLRequest(url: url, timeoutInterval: 300)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody  = try JSONSerialization.data(withJSONObject: payload)

            let (data, resp) = try await URLSession.shared.data(for: req)
            progress = 0.85

            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                throw PostProdError.badResponse((resp as? HTTPURLResponse)?.statusCode ?? -1)
            }

            guard let json     = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let imgStr   = json["image"] as? String,
                  let imgData  = Data(base64Encoded: imgStr),
                  let nsImage  = NSImage(data: imgData)
            else { throw PostProdError.noImage }

            let savedPath = saveResult(nsImage, operation: operation)

            result = PostProdResult(
                image:        nsImage,
                savedPath:    savedPath,
                operation:    operation,
                duration:     Date().timeIntervalSince(startTime),
                originalSize: image.size,
                resultSize:   nsImage.size
            )

            progress     = 1.0
            progressText = "\(operation.rawValue) completado ✓"

        } catch {
            errorMessage = error.localizedDescription
            progressText = "Error: \(error.localizedDescription)"
        }

        isProcessing = false
    }

    // MARK: - Convenience

    func upscale(_ image: NSImage, by factor: Double = 2.0, upscaler: String = "R-ESRGAN 4x+", baseURL: String) async {
        var s = PostProdSettings()
        s.upscaler1 = upscaler
        s.upscaleBy = factor
        await process(image: image, settings: s, operation: .upscale, baseURL: baseURL)
    }

    func restoreFaces(_ image: NSImage, weight: Double = 0.5, baseURL: String) async {
        var s = PostProdSettings()
        s.codeFormerWeight = weight
        await process(image: image, settings: s, operation: .faceRestore, baseURL: baseURL)
    }

    func upscaleAndRestore(_ image: NSImage, factor: Double = 2.0, upscaler: String = "R-ESRGAN 4x+", faceWeight: Double = 0.5, baseURL: String) async {
        var s = PostProdSettings()
        s.upscaler1        = upscaler
        s.upscaleBy        = factor
        s.codeFormerWeight = faceWeight
        await process(image: image, settings: s, operation: .combined, baseURL: baseURL)
    }

    // MARK: - Payload

    private func buildPayload(b64: String, settings: PostProdSettings, operation: PostProdOperation) -> [String: Any] {
        var payload: [String: Any] = [
            "image": b64,
            "upscaling_resize": settings.upscaleBy,
            "upscaler_1": settings.upscaler1,
            "upscaler_2": settings.upscaler2,
            "extras_upscaler_2_visibility": settings.upscaler2Visibility,
        ]

        if settings.tileWidth > 0  { payload["upscale_first"] = true }

        switch operation {
        case .upscale:
            payload["gfpgan_visibility"]    = 0.0
            payload["codeformer_visibility"] = 0.0
            payload["codeformer_weight"]     = 0.0

        case .faceRestore:
            payload["upscaling_resize"] = 1.0
            payload["upscaler_1"]       = "None"
            if settings.faceRestoreModel == "GFPGAN" {
                payload["gfpgan_visibility"]    = 1.0
                payload["codeformer_visibility"] = 0.0
            } else {
                payload["gfpgan_visibility"]    = 0.0
                payload["codeformer_visibility"] = 1.0
                payload["codeformer_weight"]     = settings.codeFormerWeight
            }

        case .combined:
            if settings.faceRestoreModel == "GFPGAN" {
                payload["gfpgan_visibility"]    = 1.0
                payload["codeformer_visibility"] = 0.0
            } else {
                payload["gfpgan_visibility"]    = 0.0
                payload["codeformer_visibility"] = 1.0
                payload["codeformer_weight"]     = settings.codeFormerWeight
            }
        }

        if settings.upscaleToWidth > 0 {
            payload["upscaling_resize_w"] = settings.upscaleToWidth
            payload["upscaling_resize_h"] = settings.upscaleToHeight
            payload["upscaling_crop"]     = true
        }

        return payload
    }

    // MARK: - Helpers

    private func imageToBase64(_ image: NSImage) throws -> String {
        guard let tiff = image.tiffRepresentation,
              let bmp  = NSBitmapImageRep(data: tiff),
              let png  = bmp.representation(using: .png, properties: [:])
        else { throw PostProdError.conversionFailed }
        return png.base64EncodedString()
    }

    private func saveResult(_ image: NSImage, operation: PostProdOperation) -> String? {
        guard let dir = VaultManager.shared.masterPicksURL else { return nil }
        let subdir = dir.appending(path: "postprod")
        try? FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        let filename = "pp_\(operation.rawValue.lowercased().replacingOccurrences(of: " ", with: "_"))_\(Int(Date().timeIntervalSince1970)).png"
        let fileURL  = subdir.appending(path: filename)
        guard let tiff = image.tiffRepresentation,
              let bmp  = NSBitmapImageRep(data: tiff),
              let png  = bmp.representation(using: .png, properties: [:]) else { return nil }
        try? png.write(to: fileURL, options: .atomic)
        return fileURL.path
    }
}

// MARK: - Errors

enum PostProdError: LocalizedError {
    case badResponse(Int), noImage, conversionFailed
    var errorDescription: String? {
        switch self {
        case .badResponse(let c): return "A1111 respondió \(c). Verifica que ESRGAN/CodeFormer estén instalados."
        case .noImage:            return "No se recibió imagen procesada"
        case .conversionFailed:   return "Error convirtiendo imagen"
        }
    }
}

// MARK: - PostProductionView

struct PostProductionView: View {

    @ObservedObject var engine = PostProductionEngine.shared
    @Binding var baseURL: String
    var sourceImage: NSImage?

    @State private var settings   = PostProdSettings()
    @State private var operation  = PostProdOperation.combined
    @State private var localImage: NSImage? = nil

    var currentSource: NSImage? { localImage ?? sourceImage }

    var body: some View {
        VStack(spacing: 0) {

            // Header
            HStack(spacing: 10) {
                Image(systemName: "sparkles").font(.system(size: 14))
                    .foregroundColor(Color(hex: "#34d399"))
                Text("Post-Producción")
                    .font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(Color.white.opacity(0.03))

            Divider().background(Color.white.opacity(0.07))

            ScrollView {
                VStack(spacing: 14) {

                    // Operación
                    VStack(alignment: .leading, spacing: 6) {
                        sLabel("Operación")
                        HStack(spacing: 6) {
                            ForEach(PostProdOperation.allCases, id: \.self) { op in
                                Button(action: { operation = op }) {
                                    VStack(spacing: 3) {
                                        Image(systemName: op.icon).font(.system(size: 13))
                                        Text(op.rawValue).font(.system(size: 9)).lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                                    .background(operation == op
                                        ? Color(hex: "#34d399").opacity(0.2) : Color.white.opacity(0.04))
                                    .foregroundColor(operation == op ? Color(hex: "#34d399") : .secondary)
                                    .cornerRadius(7)
                                }.buttonStyle(.plain)
                            }
                        }
                    }

                    // Imagen fuente
                    HStack(spacing: 12) {
                        if let img = currentSource {
                            Image(nsImage: img).resizable().scaledToFill()
                                .frame(width: 60, height: 60).clipShape(RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Imagen fuente")
                                    .font(.system(size: 11, weight: .medium)).foregroundColor(.white)
                                Text("\(Int(img.size.width))×\(Int(img.size.height))")
                                    .font(.system(size: 10)).foregroundColor(.secondary)
                                if let r = engine.result {
                                    Text("→ \(Int(r.resultSize.width))×\(Int(r.resultSize.height))")
                                        .font(.system(size: 10)).foregroundColor(Color(hex: "#34d399"))
                                }
                            }
                        } else {
                            RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04))
                                .frame(width: 60, height: 60)
                                .overlay(Image(systemName: "photo").foregroundColor(.secondary))
                        }
                        Spacer()
                        Button("Seleccionar") { pickImage() }
                            .buttonStyle(.plain).font(.system(size: 11))
                            .foregroundColor(Color(hex: "#34d399"))
                    }
                    .padding(10).background(Color.white.opacity(0.03)).cornerRadius(8)

                    // Config upscale
                    if operation == .upscale || operation == .combined {
                        VStack(alignment: .leading, spacing: 8) {
                            sLabel("Upscaler")
                            Picker("", selection: $settings.upscaler1) {
                                ForEach(engine.availableUpscalers, id: \.self) { u in
                                    Text(u).tag(u)
                                }
                            }.pickerStyle(.menu).labelsHidden()
                             .background(Color.white.opacity(0.06)).cornerRadius(6)

                            HStack {
                                sLabel("Factor ×\(String(format: "%.1f", settings.upscaleBy))")
                                Spacer()
                            }
                            Slider(value: $settings.upscaleBy, in: 1.0...4.0, step: 0.5)
                                .accentColor(Color(hex: "#34d399"))
                            HStack {
                                Text("×1").font(.system(size: 9)).foregroundColor(.secondary)
                                Spacer()
                                Text("×4").font(.system(size: 9)).foregroundColor(.secondary)
                            }
                        }
                        .padding(10).background(Color.white.opacity(0.03)).cornerRadius(8)
                    }

                    // Config face restore
                    if operation == .faceRestore || operation == .combined {
                        VStack(alignment: .leading, spacing: 8) {
                            sLabel("Restauración facial")
                            HStack(spacing: 8) {
                                ForEach(PostProdSettings.faceRestoreOptions, id: \.self) { m in
                                    Button(action: { settings.faceRestoreModel = m }) {
                                        Text(m).font(.system(size: 11))
                                            .padding(.horizontal, 10).padding(.vertical, 5)
                                            .background(settings.faceRestoreModel == m
                                                ? Color(hex: "#34d399").opacity(0.2) : Color.white.opacity(0.05))
                                            .foregroundColor(settings.faceRestoreModel == m
                                                ? Color(hex: "#34d399") : .secondary)
                                            .cornerRadius(6)
                                    }.buttonStyle(.plain)
                                }
                            }
                            if settings.faceRestoreModel == "CodeFormer" {
                                HStack {
                                    sLabel("Weight: \(String(format: "%.2f", settings.codeFormerWeight))")
                                    Spacer()
                                }
                                Slider(value: $settings.codeFormerWeight, in: 0...1, step: 0.05)
                                    .accentColor(Color(hex: "#34d399"))
                                HStack {
                                    Text("Fidelidad").font(.system(size: 9)).foregroundColor(.secondary)
                                    Spacer()
                                    Text("Calidad").font(.system(size: 9)).foregroundColor(.secondary)
                                }
                            }
                        }
                        .padding(10).background(Color.white.opacity(0.03)).cornerRadius(8)
                    }

                    // Progress / Result
                    if engine.isProcessing {
                        VStack(spacing: 6) {
                            ProgressView(value: engine.progress).accentColor(Color(hex: "#34d399"))
                            Text(engine.progressText).font(.system(size: 11)).foregroundColor(.secondary)
                        }
                        .padding(10).background(Color.white.opacity(0.03)).cornerRadius(8)
                    }

                    if let res = engine.result {
                        VStack(spacing: 8) {
                            Image(nsImage: res.image).resizable().scaledToFit()
                                .frame(maxHeight: 200).cornerRadius(8)
                            HStack {
                                Text("✓ \(Int(res.resultSize.width))×\(Int(res.resultSize.height))")
                                    .font(.system(size: 11)).foregroundColor(Color(hex: "#34d399"))
                                Spacer()
                                Text(String(format: "%.1fs", res.duration))
                                    .font(.system(size: 10)).foregroundColor(.secondary)
                            }
                            // Usar como fuente para siguiente op
                            Button(action: { localImage = res.image }) {
                                Label("Usar como fuente", systemImage: "arrow.uturn.backward")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain).foregroundColor(Color(hex: "#34d399"))
                        }
                        .padding(10).background(Color.white.opacity(0.03)).cornerRadius(8)
                    }

                    if let err = engine.errorMessage {
                        Text("⚠ \(err)").font(.system(size: 11))
                            .foregroundColor(Color(red: 1, green: 0.45, blue: 0.45))
                            .padding(8).background(Color.red.opacity(0.08)).cornerRadius(6)
                    }

                    // CTA
                    Button(action: { Task { await run() } }) {
                        HStack(spacing: 8) {
                            if engine.isProcessing {
                                ProgressView().controlSize(.small).tint(.white)
                                Text("Procesando…")
                            } else {
                                Image(systemName: operation.icon)
                                Text(operation.rawValue)
                            }
                        }
                        .font(.system(size: 13, weight: .bold))
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(currentSource != nil
                            ? LinearGradient(colors: [Color(hex: "#34d399"), Color(hex: "#10b981")],
                                           startPoint: .leading, endPoint: .trailing)
                            : LinearGradient(colors: [.gray.opacity(0.3), .gray.opacity(0.3)],
                                           startPoint: .leading, endPoint: .trailing))
                        .foregroundColor(.white).cornerRadius(10)
                    }
                    .buttonStyle(.plain).disabled(currentSource == nil || engine.isProcessing)
                }
                .padding(14)
            }
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(Color(hex: "#34d399").opacity(0.2), lineWidth: 1))
        .task { await engine.fetchUpscalers(baseURL: baseURL) }
    }

    private func run() async {
        guard let img = currentSource else { return }
        await engine.process(image: img, settings: settings, operation: operation, baseURL: baseURL)
    }

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.canChooseFiles = true
        panel.title = "Seleccionar imagen para post-producción"
        guard panel.runModal() == .OK, let url = panel.url,
              let img = NSImage(contentsOf: url) else { return }
        localImage = img
    }

    func sLabel(_ t: String) -> some View {
        Text(t).font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
    }
}
