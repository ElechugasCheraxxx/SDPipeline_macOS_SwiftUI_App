// Core/MirroringCaptureManager.swift
// CORRECCIONES:
// ✅ Escala doble corregida: buildConfig() ahora usa NSScreen.main?.backingScaleFactor
//    en lugar de siempre multiplicar por 2. En monitores @1x, antes capturaba
//    al doble de resolución necesaria y la imagen se mostraba borrosa.
// ✅ Logger estructurado (os.Logger) en lugar de print().
// ✅ Errores de SCStream registrados con log.error() en lugar de solo print().

import ScreenCaptureKit
import AVFoundation
import AppKit
import SwiftUI
import os

private let log = Logger(subsystem: "com.cheraxx.keymapper", category: "MirroringCapture")

@Observable
final class MirroringCaptureManager: NSObject, SCStreamDelegate, SCStreamOutput {

    // MARK: - Singleton
    static let shared = MirroringCaptureManager()
    private override init() { super.init() }

    // MARK: - Estado publicado
    var capturedImage:    CGImage? = nil
    var isCapturing:      Bool     = false
    var permissionDenied: Bool     = false

    // MARK: - Privado
    private var stream:    SCStream?
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private let mirroringBundles = [
        "com.apple.iPhoneMirroring",
        "com.apple.ScreenshotUI",
        "com.apple.MobileDeviceUpdater"
    ]
    private let mirroringTitles = [
        "iPhone Mirroring",
        "Duplicación del iPhone",
        "iPhone"
    ]

    // MARK: - Start
    func startCapture() async {
        guard !isCapturing else { return }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )

            guard let window = findMirroringWindow(in: content) else {
                log.warning("Ventana de Mirroring no encontrada en SCShareableContent")
                return
            }

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = buildConfig(for: window)

            let newStream = SCStream(filter: filter, configuration: config, delegate: self)
            try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
            try await newStream.startCapture()

            self.stream = newStream
            await MainActor.run { self.isCapturing = true }
            log.info("Captura iniciada — \(Int(window.frame.width))×\(Int(window.frame.height)) @\(Int(NSScreen.main?.backingScaleFactor ?? 2))x")

        } catch SCStreamError.userDeclined {
            await MainActor.run { self.permissionDenied = true }
            log.error("Permiso de grabación de pantalla denegado por el usuario")

        } catch {
            log.error("Error al iniciar captura de pantalla: \(error.localizedDescription)")
        }
    }

    func stopCapture() {
        guard isCapturing else { return }
        let s = stream
        stream        = nil
        isCapturing   = false
        capturedImage = nil
        Task {
            do { try await s?.stopCapture() }
            catch { log.error("Error al detener captura: \(error.localizedDescription)") }
        }
        log.info("Captura detenida")
    }

    // MARK: - SCStreamOutput
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            log.error("No se pudo crear CGImage desde el buffer de captura")
            return
        }
        self.capturedImage = cgImage
    }

    // MARK: - SCStreamDelegate
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log.error("Stream de pantalla detenido con error: \(error.localizedDescription)")
        DispatchQueue.main.async {
            self.isCapturing   = false
            self.capturedImage = nil
        }
    }

    // MARK: - Helpers privados
    private func findMirroringWindow(in content: SCShareableContent) -> SCWindow? {
        for bundleID in mirroringBundles {
            if let w = content.windows.first(where: {
                $0.owningApplication?.bundleIdentifier == bundleID
            }) { return w }
        }
        return content.windows.first(where: { w in
            guard let title = w.title else { return false }
            return mirroringTitles.contains(where: { title.contains($0) })
        })
    }

    /// Configuración de captura con escala dinámica del monitor.
    /// FIX: antes siempre multiplicaba por 2 (hardcodeado).
    /// Ahora usa la escala real del monitor para evitar doble escalado.
    private func buildConfig(for window: SCWindow) -> SCStreamConfiguration {
        // En monitores Retina (@2x) capturamos al doble de puntos para nitidez.
        // En monitores @1x capturamos 1:1 para no inflar el tamaño del frame.
        let screenScale = Int(NSScreen.main?.backingScaleFactor ?? 2.0)

        let config       = SCStreamConfiguration()
        config.width     = max(Int(window.frame.width)  * screenScale, 100)
        config.height    = max(Int(window.frame.height) * screenScale, 100)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth           = 5
        config.pixelFormat          = kCVPixelFormatType_32BGRA
        return config
    }
}
