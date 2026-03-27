// Core/OverlayManager.swift
// CORRECCIONES:
// ✅ Ciclo de vida del overlay usando withObservationTracking + AsyncStream
//    en lugar de NotificationCenter. Elimina el acoplamiento por notificaciones.
// ✅ OverlayManager ya no necesita ser un singleton — se instancia en CheraxxApp
//    y se pasa como dependencia. El singleton se mantiene por compatibilidad
//    pero con un aviso de que el enfoque preferido es DI.
// ✅ Logger estructurado.
// ✅ teardown limpio al deinit.

import AppKit
import SwiftUI
import os

private let log = Logger(subsystem: "com.cheraxx.keymapper", category: "OverlayManager")

@MainActor
final class OverlayManager {

    // MARK: - Singleton (compatible con código existente)
    static let shared = OverlayManager()

    // MARK: - Estado
    private var windowController: OverlayWindowController?
    private var observationTask:  Task<Void, Never>?

    private weak var keyMapper:     KeyMapper?
    private weak var windowTracker: WindowTracker?

    // MARK: - Setup
    /// Llama una sola vez desde CheraxxApp. Inicia la observación reactiva
    /// de WindowTracker sin necesidad de NotificationCenter.
    func setup(keyMapper: KeyMapper, windowTracker: WindowTracker) {
        self.keyMapper     = keyMapper
        self.windowTracker = windowTracker

        // Cancelar observación anterior (si setup() se llama más de una vez)
        observationTask?.cancel()

        // Observar isMirroringActive y mirroringWindowFrame directamente
        observationTask = Task { [weak self] in
            guard let self else { return }
            for await _ in self.mirroringChanges(in: windowTracker) {
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    self.handleMirroringState()
                }
            }
        }

        log.info("OverlayManager configurado con observación reactiva de WindowTracker")
    }

    // MARK: - AsyncStream de cambios de Mirroring
    /// Produce un valor cada vez que isMirroringActive o mirroringWindowFrame cambia.
    private func mirroringChanges(in tracker: WindowTracker) -> AsyncStream<Void> {
        AsyncStream { continuation in
            // Dispara inmediatamente para el estado inicial
            continuation.yield(())

            // Observa cambios con withObservationTracking en bucle
            func scheduleNextObservation() {
                withObservationTracking {
                    // Acceder a las propiedades que queremos observar
                    _ = tracker.isMirroringActive
                    _ = tracker.mirroringWindowFrame
                } onChange: {
                    continuation.yield(())
                    // Re-programar para el siguiente cambio
                    Task { @MainActor in scheduleNextObservation() }
                }
            }

            scheduleNextObservation()

            continuation.onTermination = { _ in
                log.debug("AsyncStream de Mirroring terminado")
            }
        }
    }

    // MARK: - Gestión del ciclo de vida del overlay
    private func handleMirroringState() {
        guard let keyMapper, let windowTracker else { return }

        if windowTracker.isMirroringActive, let frame = windowTracker.mirroringWindowFrame {
            if let profile = keyMapper.activeProfile {
                if windowController == nil {
                    windowController = OverlayWindowController(
                        profile: profile,
                        windowTracker: windowTracker,
                        keyMapper: keyMapper
                    )
                    log.info("Overlay creado sobre \(frame.debugDescription)")
                }
                windowController?.show(over: frame)
            } else {
                // Mirroring activo pero sin perfil seleccionado
                windowController?.hide()
                log.debug("Mirroring activo pero sin perfil — overlay oculto")
            }
        } else {
            windowController?.hide()
            windowController = nil
            log.info("Overlay ocultado (Mirroring inactivo)")
        }
    }

    // MARK: - API pública
    /// Actualiza el perfil mostrado en el overlay sin destruirlo.
    func updateProfile(_ profile: MappingProfile) {
        windowController?.updateProfile(profile)
        log.debug("Perfil del overlay actualizado: \(profile.name)")
    }

    /// Oculta y destruye el overlay manualmente (ej. al desactivar KeyMapper).
    func detach() {
        windowController?.hide()
        windowController = nil
        log.debug("Overlay desconectado manualmente")
    }

    // MARK: - Cleanup
    deinit {
        observationTask?.cancel()
    }
}
