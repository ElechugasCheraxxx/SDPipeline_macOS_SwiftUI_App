// Utils/AppNotifications.swift
// Punto único de definición para todas las Notification.Name de la app.
// Elimina la dispersión de literales de string y evita duplicados.

import Foundation

extension Notification.Name {
    // MARK: - Ventana de Mirroring
    static let mirroringWindowFound = Notification.Name("cheraxx.mirroringWindowFound")
    static let mirroringWindowLost  = Notification.Name("cheraxx.mirroringWindowLost")

    // MARK: - Comandos de menú
    static let createNewProfile     = Notification.Name("cheraxx.createNewProfile")
    static let importProfile        = Notification.Name("cheraxx.importProfile")
    static let exportProfile        = Notification.Name("cheraxx.exportProfile")
    static let toggleKeyMapper      = Notification.Name("cheraxx.toggleKeyMapper")

    // MARK: - Ciclo de vida del overlay
    // Solo se mantienen por compatibilidad con código legacy que aún no usa
    // la observación reactiva con withObservationTracking.
    // A medida que se migre cada módulo, estas constantes se pueden eliminar.
    static let overlayShow          = Notification.Name("cheraxx.overlayShow")
    static let overlayHide          = Notification.Name("cheraxx.overlayHide")
}
