// Core/EventTapManager.swift
// CORRECCIONES:
// ✅ Logger estructurado (os.Logger) en lugar de print().
// ✅ Thread-safety: start()/stop() con os_unfair_lock (ya existía, se mantiene).
// ✅ Captura de botones de ratón + teclado (ya existía, se mantiene).
// ✅ captureNextKey() para el inspector sin colisión con el tap global.

import AppKit
import CoreGraphics
import os

private let log = Logger(subsystem: "com.cheraxx.keymapper", category: "EventTap")

@Observable
final class EventTapManager {

    // MARK: - Estado
    var isRunning:     Bool   = false
    var lastPressedKey: String = ""

    // MARK: - Callbacks
    var onKeyDown:   ((String) -> Void)?
    var onKeyUp:     ((String) -> Void)?
    var shouldBlock: ((String) -> Bool)?

    // MARK: - Privado
    private var _stateLock     = os_unfair_lock()
    private var eventTap:      CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var pressedKeys:   Set<String> = []

    private var captureCompletion: ((String) -> Void)?
    private var isCaptureMode = false

    // MARK: - Start / Stop
    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        os_unfair_lock_lock(&_stateLock)
        defer { os_unfair_lock_unlock(&_stateLock) }
        guard !isRunning else { return }

        guard AXIsProcessTrusted() else {
            log.error("Permiso de Accesibilidad no concedido — EventTap no puede iniciarse")
            return
        }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)        |
            (1 << CGEventType.keyUp.rawValue)           |
            (1 << CGEventType.leftMouseDown.rawValue)   |
            (1 << CGEventType.leftMouseUp.rawValue)     |
            (1 << CGEventType.rightMouseDown.rawValue)  |
            (1 << CGEventType.rightMouseUp.rawValue)

        eventTap = CGEvent.tapCreate(
            tap:              .cgSessionEventTap,
            place:            .headInsertEventTap,
            options:          .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<EventTapManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let tap = eventTap else {
            log.error("No se pudo crear el CGEvent tap — verifica permisos de Accesibilidad")
            return
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
        log.info("EventTap iniciado (teclado + botones de ratón)")
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        os_unfair_lock_lock(&_stateLock)
        defer { os_unfair_lock_unlock(&_stateLock) }
        guard isRunning, let tap = eventTap else { return }

        CGEvent.tapEnable(tap: tap, enable: false)
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap      = nil
        runLoopSource = nil
        pressedKeys.removeAll()
        isRunning     = false
        isCaptureMode = false
        captureCompletion = nil
        log.info("EventTap detenido")
    }

    // MARK: - Manejador de eventos
    private func handleEvent(proxy: CGEventTapProxy,
                             type:  CGEventType,
                             event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyString = eventKey(from: event, type: type)

        // Modo captura del inspector
        if isCaptureMode && (type == .keyDown || type == .leftMouseDown || type == .rightMouseDown) {
            let completion = captureCompletion
            isCaptureMode     = false
            captureCompletion = nil
            DispatchQueue.main.async { completion?(keyString) }
            log.debug("Tecla capturada por inspector: \(keyString)")
            return nil
        }

        let isDown = (type == .keyDown || type == .leftMouseDown || type == .rightMouseDown)
        let isUp   = (type == .keyUp   || type == .leftMouseUp   || type == .rightMouseUp)

        if isDown {
            guard !pressedKeys.contains(keyString) else {
                return shouldBlock?(keyString) == true ? nil : Unmanaged.passUnretained(event)
            }
            pressedKeys.insert(keyString)
            DispatchQueue.main.async { [weak self] in
                self?.lastPressedKey = keyString
                self?.onKeyDown?(keyString)
            }
            if shouldBlock?(keyString) == true { return nil }

        } else if isUp {
            pressedKeys.remove(keyString)
            DispatchQueue.main.async { [weak self] in
                self?.onKeyUp?(keyString)
            }
            if shouldBlock?(keyString) == true { return nil }
        }

        return Unmanaged.passUnretained(event)
    }

    // MARK: - Extracción de string de tecla / botón
    private func eventKey(from event: CGEvent, type: CGEventType) -> String {
        switch type {
        case .leftMouseDown,  .leftMouseUp:  return "MouseLButton"
        case .rightMouseDown, .rightMouseUp: return "MouseRButton"
        default:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            return KeyCodeHelper.string(for: CGKeyCode(keyCode))
        }
    }

    // MARK: - Modo captura para el editor de bindings
    func captureNextKey(completion: @escaping (String) -> Void) {
        captureCompletion = completion
        isCaptureMode     = true
        log.debug("Modo captura de tecla activado")
    }

    func cancelCapture() {
        isCaptureMode     = false
        captureCompletion = nil
        log.debug("Modo captura de tecla cancelado")
    }
}
