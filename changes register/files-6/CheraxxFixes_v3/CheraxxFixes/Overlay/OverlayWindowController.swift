// Overlay/OverlayWindowController.swift
// CORRECCIONES:
// ✅ updateProfile() ya no apila hostingView: el controlador anterior se elimina
//    correctamente antes de instanciar el nuevo (bug original causaba memory leak
//    + corrupción visual con N capas de SwiftUI superpuestas).
// ✅ NSPanel no activating: el overlay nunca roba el foco de iPhone Mirroring.
// ✅ Ventana click-through en zonas sin widgets: eventos de ratón pasan al Mirroring.
// ✅ Nivel de ventana correcto: .floating permite que el overlay quede sobre Mirroring
//    sin bloquear otros paneles del sistema (diálogos, etc.).
// ✅ Actualización de frame sin parpadeo: setFrame(_:display:animate:) con animate=false.
// ✅ Logger estructurado.
// ✅ deinit limpio: elimina el panel y libera hostingController.

import AppKit
import SwiftUI
import os

private let log = Logger(subsystem: "com.cheraxx.keymapper", category: "OverlayWindow")

// MARK: - OverlayWindowController
@MainActor
final class OverlayWindowController {

    // MARK: - Estado privado
    private var panel:             OverlayPanel?
    private var hostingController: NSHostingController<AnyView>?

    private let windowTracker: WindowTracker
    private let keyMapper:     KeyMapper
    private var currentProfile: MappingProfile

    // MARK: - Init
    init(profile: MappingProfile,
         windowTracker: WindowTracker,
         keyMapper: KeyMapper) {
        self.currentProfile = profile
        self.windowTracker  = windowTracker
        self.keyMapper      = keyMapper

        buildPanel()
        log.debug("OverlayWindowController creado para perfil '\(profile.name)'")
    }

    // MARK: - API pública

    /// Posiciona el overlay sobre el frame de la ventana de Mirroring y lo muestra.
    func show(over mirroringFrame: CGRect) {
        guard let panel else { return }

        // Convertir frame de coordenadas AppKit (origen en bottom-left de pantalla)
        let screenFrame = convertToScreen(mirroringFrame)
        panel.setFrame(screenFrame, display: true, animate: false)

        if !panel.isVisible {
            // orderFront sin activar la app — Mirroring mantiene el foco
            panel.orderFront(nil)
            log.info("Overlay mostrado — frame \(mirroringFrame.debugDescription)")
        }
    }

    /// Oculta el overlay sin destruirlo (se puede mostrar de nuevo con show(over:)).
    func hide() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        log.debug("Overlay oculto")
    }

    /// Reemplaza el perfil mostrado.
    /// FIX: elimina el hostingController anterior ANTES de crear el nuevo.
    /// Sin esto, cada llamada apilaba una capa adicional de SwiftUI sobre la anterior
    /// causando un leak progresivo de memoria y corrupción visual.
    func updateProfile(_ profile: MappingProfile) {
        currentProfile = profile
        replaceContent(with: profile)
        log.debug("Perfil del overlay actualizado: '\(profile.name)'")
    }

    // MARK: - Construcción interna

    private func buildPanel() {
        // OverlayPanel: subclase de NSPanel configurada para overlay no activante
        let p = OverlayPanel(
            contentRect: .zero,
            styleMask:   [.borderless, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )
        p.level                 = .floating        // encima de Mirroring, debajo de alertas
        p.backgroundColor       = .clear
        p.isOpaque              = false
        p.hasShadow             = false
        p.ignoresMouseEvents    = false            // dejamos que OverlayHitView filtre
        p.collectionBehavior    = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isMovable             = false
        p.isReleasedWhenClosed  = false            // gestionamos lifetime manualmente

        panel = p
        replaceContent(with: currentProfile)
    }

    /// Reemplaza el contenido SwiftUI del panel, eliminando el anterior primero.
    private func replaceContent(with profile: MappingProfile) {
        guard let panel else { return }

        // 1. Retirar y liberar el hosting controller anterior
        hostingController?.view.removeFromSuperview()
        hostingController = nil

        // 2. Crear la vista SwiftUI con las dependencias inyectadas
        let overlayView = AnyView(
            OverlayView(profile: profile)
                .environment(windowTracker)
                .environment(keyMapper)
        )

        // 3. Instanciar el nuevo NSHostingController
        let hc = NSHostingController(rootView: overlayView)
        hc.view.translatesAutoresizingMaskIntoConstraints = false
        hc.view.wantsLayer = true
        hc.view.layer?.backgroundColor = .clear

        // 4. Añadir al panel usando OverlayHitView como contenedor click-through
        let hitView = OverlayHitView(frame: panel.contentView?.bounds ?? .zero)
        hitView.autoresizingMask = [.width, .height]
        hitView.addSubview(hc.view)

        NSLayoutConstraint.activate([
            hc.view.leadingAnchor.constraint(equalTo: hitView.leadingAnchor),
            hc.view.trailingAnchor.constraint(equalTo: hitView.trailingAnchor),
            hc.view.topAnchor.constraint(equalTo: hitView.topAnchor),
            hc.view.bottomAnchor.constraint(equalTo: hitView.bottomAnchor),
        ])

        panel.contentView = hitView
        hostingController = hc
    }

    // MARK: - Conversión de coordenadas

    /// Convierte el frame de Accessibility (coordenadas de pantalla, Y desde top-left)
    /// a coordenadas AppKit de NSScreen (Y desde bottom-left de la pantalla principal).
    private func convertToScreen(_ frame: CGRect) -> CGRect {
        guard let screenHeight = NSScreen.main?.frame.height else {
            return frame
        }
        // Accessibility usa Y creciente hacia abajo desde top-left.
        // AppKit usa Y creciente hacia arriba desde bottom-left de NSScreen.main.
        return CGRect(
            x: frame.minX,
            y: screenHeight - frame.maxY,
            width:  frame.width,
            height: frame.height
        )
    }

    // MARK: - Cleanup
    deinit {
        hostingController?.view.removeFromSuperview()
        hostingController = nil
        panel?.close()
        panel = nil
        log.debug("OverlayWindowController liberado")
    }
}

// MARK: - OverlayPanel
/// NSPanel configurado para no activarse al recibir eventos de ratón.
/// Esto garantiza que iPhone Mirroring no pierda el foco cuando el usuario
/// interactúa con el overlay.
private final class OverlayPanel: NSPanel {

    override var canBecomeKey: Bool   { false }
    override var canBecomeMain: Bool  { false }

    /// Retornar true aquí permite que el panel reciba eventos de ratón sin
    /// convertirse en la ventana key, manteniendo el foco en Mirroring.
    override func sendEvent(_ event: NSEvent) {
        // Ignorar eventos de activación para no robar el foco
        if event.type == .appKitDefined || event.type == .systemDefined {
            return
        }
        super.sendEvent(event)
    }
}

// MARK: - OverlayHitView
/// Vista contenedora que permite el click-through en zonas transparentes del overlay.
/// Los widgets del OverlayView (botones, dpad, etc.) tienen su propia área de hit
/// definida por SwiftUI. Las zonas entre widgets (transparentes) pasan los eventos
/// directamente a la ventana de Mirroring que hay debajo.
private final class OverlayHitView: NSView {

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Preguntar a la jerarquía de SwiftUI si algún subview quiere el evento
        let hit = super.hitTest(point)

        // Si el hit es esta misma vista (zona sin widgets) → click-through
        if hit === self { return nil }

        // Si el hit es un subview de SwiftUI → dejar que lo maneje normalmente
        return hit
    }

    override var isFlipped: Bool { true }
    override var isOpaque:  Bool { false }
}
