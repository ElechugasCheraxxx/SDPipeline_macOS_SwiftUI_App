// Core/WindowTracker.swift
// CORRECCIONES aplicadas:
// ✅ Detección de ventana sin polling ciego: usa notificaciones NSWorkspace
//    (didActivateApplication, didDeactivateApplication, didLaunchApplication,
//    didTerminateApplication) y revisa la lista de ventanas solo cuando hay
//    un cambio real en el estado de las apps. El timer de respaldo baja a 2 s
//    y solo actúa si la ventana ya está activa (para detectar redimensionado).
// ✅ axFrame() — sin force-cast inseguro (ya estaba corregido, se mantiene).
// ✅ activeAppBundleID vía NSWorkspace.didActivateApplicationNotification.
// ✅ Logger estructurado (os.Logger) en lugar de print().
// ✅ Ningún god-object: WindowTracker solo rastrea la ventana de Mirroring
//    y la app activa; no hace nada más.

import AppKit
import Foundation
import os

private let log = Logger(subsystem: "com.cheraxx.keymapper", category: "WindowTracker")

@Observable
final class WindowTracker {

    // MARK: - Estado público
    var mirroringWindowFrame: CGRect? = nil
    var isMirroringActive:    Bool    = false
    var statusMessage:        String  = "Buscando ventana de Duplicación del iPhone…"
    var activeAppBundleID:    String? = nil

    // MARK: - Privado
    private var observers: [NSObjectProtocol] = []
    private var resizeTimer: Timer?
    private var lastKnownFrame: CGRect? = nil
    private var isTracking = false

    private let mirroringBundleFragments = [
        "iPhoneMirroring",
        "iPhone-Mirroring",
        "MobileDeviceUpdater"
    ]
    private let fallbackTitles = [
        "iPhone Mirroring",
        "Duplicación del iPhone",
        "iPhone"
    ]

    // MARK: - Inicio / Parada
    func startTracking() {
        guard !isTracking else { return }
        isTracking = true

        let nc = NSWorkspace.shared.notificationCenter

        // Detectar activación / desactivación de apps
        let onActivate = nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.activeAppBundleID = app?.bundleIdentifier
            self?.checkMirroringWindow()
        }

        let onDeactivate = nc.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.checkMirroringWindow()
        }

        // Detectar lanzamiento / terminación de apps
        let onLaunch = nc.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.checkMirroringWindow()
        }

        let onTerminate = nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.checkMirroringWindow()
        }

        observers = [onActivate, onDeactivate, onLaunch, onTerminate]

        // Timer de respaldo a 2 s solo para detectar redimensionado de ventana
        // mientras Mirroring ya está activo
        resizeTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self, self.isMirroringActive else { return }
            self.checkMirroringWindow()
        }

        // Comprobación inicial
        activeAppBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        checkMirroringWindow()

        log.info("WindowTracker iniciado — modo event-driven + timer de respaldo 2 s")
    }

    func stopTracking() {
        resizeTimer?.invalidate()
        resizeTimer = nil
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        isTracking = false
        log.info("WindowTracker detenido")
    }

    // MARK: - Comprobación principal
    private func checkMirroringWindow() {
        guard let frame = findMirroringWindowFrame() else {
            if isMirroringActive {
                isMirroringActive    = false
                mirroringWindowFrame = nil
                lastKnownFrame       = nil
                statusMessage        = "Ventana de Duplicación no encontrada. Abre iPhone Mirroring."
                NotificationCenter.default.post(name: .mirroringWindowLost, object: nil)
                log.debug("Ventana de Mirroring perdida")
            }
            return
        }

        if !isMirroringActive || frame != lastKnownFrame {
            isMirroringActive    = true
            mirroringWindowFrame = frame
            lastKnownFrame       = frame
            statusMessage        = "Ventana activa • \(Int(frame.width))×\(Int(frame.height))"
            NotificationCenter.default.post(name: .mirroringWindowFound, object: frame)
            log.debug("Ventana de Mirroring: \(frame.debugDescription)")
        }
    }

    // MARK: - Búsqueda de ventana
    private func findMirroringWindowFrame() -> CGRect? {
        // 1) Buscar por bundle ID conocido (más rápido y fiable)
        let runningApps = NSWorkspace.shared.runningApplications
        for fragment in mirroringBundleFragments {
            if let app = runningApps.first(where: {
                $0.bundleIdentifier?.contains(fragment) == true
            }), let frame = bestWindowFrame(pid: app.processIdentifier) {
                return frame
            }
        }
        // 2) Fallback: buscar por título de ventana
        return frameFromWindowTitle()
    }

    /// Devuelve el frame de la ventana más grande de un proceso (evita ventanas auxiliares).
    private func bestWindowFrame(pid: pid_t) -> CGRect? {
        let axApp = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            axApp, kAXWindowsAttribute as CFString, &windowsRef
        ) == .success,
              let windows = windowsRef as? [AXUIElement],
              !windows.isEmpty
        else { return nil }

        // Preferir la ventana de mayor área (la principal de Mirroring)
        return windows
            .compactMap { axFrame(for: $0) }
            .max(by: { $0.width * $0.height < $1.width * $1.height })
    }

    private func frameFromWindowTitle() -> CGRect? {
        let runningApps = NSWorkspace.shared.runningApplications
        for app in runningApps where app.activationPolicy == .regular {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var windowsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                axApp, kAXWindowsAttribute as CFString, &windowsRef
            ) == .success,
                  let windows = windowsRef as? [AXUIElement] else { continue }
            for window in windows {
                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
                let title = titleRef as? String ?? ""
                if fallbackTitles.contains(where: { title.contains($0) }),
                   let frame = axFrame(for: window) {
                    return frame
                }
            }
        }
        return nil
    }

    // MARK: - AXFrame seguro
    private func axFrame(for window: AXUIElement) -> CGRect? {
        var posRef:  CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success
        else { return nil }

        guard let posRef, let sizeRef,
              CFGetTypeID(posRef)  == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID()
        else { return nil }

        let posValue  = posRef  as! AXValue   // seguro: tipo verificado con CFGetTypeID
        let sizeValue = sizeRef as! AXValue

        var position = CGPoint.zero
        var size     = CGSize.zero
        AXValueGetValue(posValue,  .cgPoint, &position)
        AXValueGetValue(sizeValue, .cgSize,  &size)

        guard size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: position, size: size)
    }

    // MARK: - Helpers de coordenadas
    func absolutePoint(relativeX: Double, relativeY: Double) -> CGPoint? {
        guard let frame = mirroringWindowFrame else { return nil }
        return CGPoint(
            x: frame.minX + (relativeX / 100.0) * frame.width,
            y: frame.minY + (relativeY / 100.0) * frame.height
        )
    }

    func relativePosition(from absolute: CGPoint) -> CGPoint? {
        guard let frame = mirroringWindowFrame, frame.contains(absolute) else { return nil }
        return CGPoint(
            x: ((absolute.x - frame.minX) / frame.width)  * 100.0,
            y: ((absolute.y - frame.minY) / frame.height) * 100.0
        )
    }

    deinit { stopTracking() }
}
