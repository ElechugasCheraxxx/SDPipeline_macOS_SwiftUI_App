// Core/MouseSimulator.swift
// CORRECCIONES:
// ✅ Logger estructurado (os.Logger) en lugar de print().
// ✅ Race condition en dpadIsDown/dpadDownPoint: os_unfair_lock (ya existía).
// ✅ dpadMove() síncrono sin asyncAfter (ya existía).
// ✅ swipe() con DispatchWorkItem cancelable (ya existía).
// ✅ Errores de CGEvent ahora se registran con log.error() en lugar de ser silenciados.

import AppKit
import CoreGraphics
import os

private let log = Logger(subsystem: "com.cheraxx.keymapper", category: "MouseSimulator")

final class MouseSimulator {

    static let shared = MouseSimulator()
    private init() {}

    // MARK: - D-Pad state (thread-safe)
    private var _dpadLock      = os_unfair_lock()
    private var _dpadIsDown:    Bool    = false
    private var _dpadDownPoint: CGPoint = .zero

    private var dpadIsDown: Bool {
        get { os_unfair_lock_lock(&_dpadLock); defer { os_unfair_lock_unlock(&_dpadLock) }; return _dpadIsDown }
        set { os_unfair_lock_lock(&_dpadLock); defer { os_unfair_lock_unlock(&_dpadLock) }; _dpadIsDown = newValue }
    }

    // MARK: - Cancelación de swipe
    private var _swipeLock = os_unfair_lock()
    private var _swipeWork: DispatchWorkItem?

    // MARK: - Tap
    func tap(at point: CGPoint) {
        post(.leftMouseDown, at: point)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.post(.leftMouseUp, at: point)
        }
    }

    // MARK: - Hold
    func holdDown(at point: CGPoint) { post(.leftMouseDown, at: point) }
    func holdUp(at point: CGPoint)   { post(.leftMouseUp,  at: point) }

    // MARK: - Swipe
    func swipe(from start: CGPoint,
               directionDegrees: Double,
               distancePx: CGFloat,
               durationMs: Int = 200) {
        let steps        = max(10, durationMs / 16)
        let rad          = directionDegrees * .pi / 180.0
        let dx           = CGFloat(cos(rad)) * distancePx / CGFloat(steps)
        let dy           = CGFloat(sin(rad)) * distancePx / CGFloat(steps)
        let stepInterval = Double(durationMs) / Double(steps) / 1000.0

        let points: [CGPoint] = (1...steps).map { i in
            CGPoint(x: start.x + dx * CGFloat(i),
                    y: start.y + dy * CGFloat(i))
        }

        os_unfair_lock_lock(&_swipeLock)
        _swipeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.post(.leftMouseDown, at: start)
            for (i, pt) in points.enumerated() {
                Thread.sleep(forTimeInterval: stepInterval * Double(i + 1))
                guard !Thread.current.isCancelled else { break }
                self.post(.leftMouseDragged, at: pt)
            }
            if let last = points.last {
                self.post(.leftMouseUp, at: last)
            }
        }
        _swipeWork = work
        os_unfair_lock_unlock(&_swipeLock)

        DispatchQueue.global(qos: .userInteractive).async(execute: work)
    }

    // MARK: - D-Pad
    func dpadMove(center: CGPoint, angle: Double, radius: CGFloat) {
        let rad    = angle * .pi / 180.0
        let target = CGPoint(
            x: center.x + CGFloat(cos(rad)) * radius,
            y: center.y + CGFloat(sin(rad)) * radius
        )

        if !dpadIsDown {
            post(.leftMouseDown, at: center)
            dpadIsDown = true
            post(.leftMouseDragged, at: target)
        } else {
            post(.leftMouseDragged, at: target)
        }
    }

    func dpadRelease(at point: CGPoint) {
        guard dpadIsDown else { return }
        post(.leftMouseDragged, at: point)
        post(.leftMouseUp, at: point)
        dpadIsDown = false
    }

    // MARK: - Scroll
    func scroll(deltaX: Int32, deltaY: Int32, at point: CGPoint) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel, wheelCount: 2,
            wheel1: deltaY, wheel2: deltaX, wheel3: 0
        ) else {
            log.error("No se pudo crear evento de scroll")
            return
        }
        event.location = point
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Movimiento de cursor
    func moveMouse(to point: CGPoint) {
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else {
            log.error("No se pudo crear evento de movimiento de cursor")
            return
        }
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Privado
    private func post(_ type: CGEventType, at point: CGPoint) {
        let btn: CGMouseButton = (type == .rightMouseDown || type == .rightMouseUp)
            ? .right : .left
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: btn
        ) else {
            log.error("No se pudo crear CGEvent tipo \(type.rawValue) en \(point.debugDescription)")
            return
        }
        event.post(tap: .cghidEventTap)
    }
}
