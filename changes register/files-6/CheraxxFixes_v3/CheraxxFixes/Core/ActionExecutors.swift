// Core/ActionExecutors.swift
// CORRECCIÓN — KeyMapper god-class descompuesto.
// Cada familia de acciones vive en su propio Executor struct.
// KeyMapper actúa solo como coordinador/dispatcher (ver KeyMapper.swift).
// Todas las instancias reciben WindowTracker y MouseSimulator por inyección,
// sin acceder a singletons directamente.

import AppKit
import CoreGraphics
import os

private let log = Logger(subsystem: "com.cheraxx.keymapper", category: "Executors")

// MARK: - Protocolo base
protocol ActionExecutor {
    var windowTracker: WindowTracker   { get }
    var mouse:         MouseSimulator  { get }
}

extension ActionExecutor {
    /// Convierte coordenadas relativas (0–100) a punto absoluto en pantalla.
    func absolute(x: Double, y: Double) -> CGPoint? {
        windowTracker.absolutePoint(relativeX: x, relativeY: y)
    }
}

// MARK: - TapExecutor
struct TapExecutor: ActionExecutor {
    let windowTracker: WindowTracker
    let mouse:         MouseSimulator

    func execute(x: Double, y: Double, holdMs: Int = 80) {
        guard let pt = absolute(x: x, y: y) else {
            log.warning("TapExecutor: ventana de Mirroring no disponible")
            return
        }
        mouse.holdDown(at: pt)
        DispatchQueue.global().asyncAfter(deadline: .now() + Double(holdMs) / 1000.0) {
            self.mouse.holdUp(at: pt)
        }
    }
}

// MARK: - RepeatedTapExecutor
final class RepeatedTapExecutor: ActionExecutor {
    let windowTracker: WindowTracker
    let mouse:         MouseSimulator

    private var timer: DispatchSourceTimer?
    private var _lock = os_unfair_lock()

    init(windowTracker: WindowTracker, mouse: MouseSimulator) {
        self.windowTracker = windowTracker
        self.mouse         = mouse
    }

    func start(x: Double, y: Double, intervalMs: Int, holdMs: Int) {
        stop()
        let interval = max(50, intervalMs)
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        t.schedule(deadline: .now(), repeating: .milliseconds(interval))
        t.setEventHandler { [weak self] in
            guard let self, let pt = self.absolute(x: x, y: y) else { return }
            self.mouse.holdDown(at: pt)
            DispatchQueue.global().asyncAfter(deadline: .now() + Double(holdMs) / 1000.0) {
                self.mouse.holdUp(at: pt)
            }
        }
        os_unfair_lock_lock(&_lock); timer = t; os_unfair_lock_unlock(&_lock)
        t.resume()
        log.debug("RepeatedTap iniciado — intervalo \(interval) ms")
    }

    func stop() {
        os_unfair_lock_lock(&_lock); let t = timer; timer = nil; os_unfair_lock_unlock(&_lock)
        t?.cancel()
    }

    deinit { stop() }
}

// MARK: - DpadExecutor
final class DpadExecutor: ActionExecutor {
    let windowTracker: WindowTracker
    let mouse:         MouseSimulator

    // Estado de teclas WASD activas
    private var activeDirections: Set<Direction> = []
    private var _lock = os_unfair_lock()

    enum Direction: Hashable {
        case up, down, left, right
        case altUp, altDown, altLeft, altRight
    }

    init(windowTracker: WindowTracker, mouse: MouseSimulator) {
        self.windowTracker = windowTracker
        self.mouse         = mouse
    }

    func keyDown(direction: Direction, centerX: Double, centerY: Double,
                 radiusPct: Double, isFloating: Bool, speedFactor: Double) {
        os_unfair_lock_lock(&_lock)
        activeDirections.insert(direction)
        let dirs = activeDirections
        os_unfair_lock_unlock(&_lock)

        updateDpad(activeDirections: dirs, centerX: centerX, centerY: centerY,
                   radiusPct: radiusPct, speedFactor: speedFactor)
    }

    func keyUp(direction: Direction, centerX: Double, centerY: Double,
               radiusPct: Double, speedFactor: Double) {
        os_unfair_lock_lock(&_lock)
        activeDirections.remove(direction)
        let dirs = activeDirections
        os_unfair_lock_unlock(&_lock)

        if dirs.isEmpty {
            if let center = absolute(x: centerX, y: centerY) {
                mouse.dpadRelease(at: center)
            }
        } else {
            updateDpad(activeDirections: dirs, centerX: centerX, centerY: centerY,
                       radiusPct: radiusPct, speedFactor: speedFactor)
        }
    }

    private func updateDpad(activeDirections: Set<Direction>, centerX: Double, centerY: Double,
                             radiusPct: Double, speedFactor: Double) {
        guard let center = absolute(x: centerX, y: centerY),
              let frame  = windowTracker.mirroringWindowFrame else { return }

        let radius  = (radiusPct / 100.0) * min(frame.width, frame.height) * speedFactor
        let angle   = angleFromDirections(activeDirections)
        mouse.dpadMove(center: center, angle: angle, radius: radius)
    }

    private func angleFromDirections(_ dirs: Set<Direction>) -> Double {
        var dx: Double = 0, dy: Double = 0
        if dirs.contains(.up)    || dirs.contains(.altUp)    { dy -= 1 }
        if dirs.contains(.down)  || dirs.contains(.altDown)  { dy += 1 }
        if dirs.contains(.left)  || dirs.contains(.altLeft)  { dx -= 1 }
        if dirs.contains(.right) || dirs.contains(.altRight) { dx += 1 }
        return atan2(dy, dx) * 180.0 / .pi
    }

    func releaseAll(centerX: Double, centerY: Double) {
        os_unfair_lock_lock(&_lock)
        activeDirections.removeAll()
        os_unfair_lock_unlock(&_lock)
        if let center = absolute(x: centerX, y: centerY) {
            mouse.dpadRelease(at: center)
        }
    }
}

// MARK: - AimAndShootExecutor
final class AimAndShootExecutor: ActionExecutor {
    let windowTracker: WindowTracker
    let mouse:         MouseSimulator

    private var isToggled    = false
    private var lastMousePos = CGPoint.zero
    private var trackTimer:  DispatchSourceTimer?

    // Límites del área de aim (en coordenadas relativas 0–100)
    struct Bounds {
        var left, right, top, bottom: Double
    }

    init(windowTracker: WindowTracker, mouse: MouseSimulator) {
        self.windowTracker = windowTracker
        self.mouse         = mouse
    }

    func toggle(x: Double, y: Double, bounds: Bounds, sensitivity: Double) {
        isToggled.toggle()
        if isToggled {
            startTracking(centerX: x, centerY: y, bounds: bounds, sensitivity: sensitivity)
            log.debug("AimAndShoot: modo aiming activado")
        } else {
            stopTracking()
            log.debug("AimAndShoot: modo aiming desactivado")
        }
    }

    func shoot(x: Double, y: Double) {
        guard let pt = absolute(x: x, y: y) else { return }
        mouse.holdDown(at: pt)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.08) {
            self.mouse.holdUp(at: pt)
        }
    }

    private func startTracking(centerX: Double, centerY: Double, bounds: Bounds, sensitivity: Double) {
        trackTimer?.cancel()
        lastMousePos = NSEvent.mouseLocation

        let t = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        t.schedule(deadline: .now(), repeating: .milliseconds(16)) // ~60 fps
        t.setEventHandler { [weak self] in
            self?.track(centerX: centerX, centerY: centerY, bounds: bounds, sensitivity: sensitivity)
        }
        trackTimer = t
        t.resume()
    }

    private func track(centerX: Double, centerY: Double, bounds: Bounds, sensitivity: Double) {
        guard let frame = windowTracker.mirroringWindowFrame else { return }
        let current = NSEvent.mouseLocation

        let dx = (current.x - lastMousePos.x) * sensitivity
        let dy = (lastMousePos.y - current.y) * sensitivity // invertir Y (pantalla → coordenada)
        lastMousePos = current

        guard abs(dx) > 0.5 || abs(dy) > 0.5 else { return }

        let rawX = centerX + (dx / frame.width)  * 100.0
        let rawY = centerY + (dy / frame.height) * 100.0

        let clampedX = max(bounds.left, min(bounds.right,  rawX))
        let clampedY = max(bounds.top,  min(bounds.bottom, rawY))

        if let pt = absolute(x: clampedX, y: clampedY) {
            mouse.moveMouse(to: pt)
        }
    }

    func stopTracking() {
        trackTimer?.cancel()
        trackTimer = nil
        isToggled  = false
    }

    deinit { stopTracking() }
}

// MARK: - SwipeExecutor
struct SwipeExecutor: ActionExecutor {
    let windowTracker: WindowTracker
    let mouse:         MouseSimulator

    func execute(x: Double, y: Double, degrees: Double, distancePct: Double, durationMs: Int) {
        guard let pt = absolute(x: x, y: y),
              let frame = windowTracker.mirroringWindowFrame else { return }
        let distancePx = (distancePct / 100.0) * min(frame.width, frame.height)
        mouse.swipe(from: pt, directionDegrees: degrees,
                    distancePx: distancePx, durationMs: durationMs)
        log.debug("Swipe desde (\(x),\(y)) dir \(degrees)° dist \(Int(distancePx))px")
    }
}

// MARK: - ScriptExecutor
final class ScriptExecutor: ActionExecutor {
    let windowTracker: WindowTracker
    let mouse:         MouseSimulator

    private var runningTask: Task<Void, Never>?

    init(windowTracker: WindowTracker, mouse: MouseSimulator) {
        self.windowTracker = windowTracker
        self.mouse         = mouse
    }

    func execute(steps: [MacroStep]) {
        runningTask?.cancel()
        runningTask = Task { [weak self] in
            guard let self else { return }

            for step in steps {
                guard !Task.isCancelled else { break }
                let delayMs = max(0, step.delayMs)

                // Delay ANTES del paso (permite .wait como pausa pura)
                if delayMs > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                    guard !Task.isCancelled else { break }
                }

                switch step.type {
                case .tap:
                    // FIX: validar x/y no nulos antes de ejecutar
                    guard let x = step.x, let y = step.y else {
                        log.warning("ScriptExecutor: paso .tap sin coordenadas — se omite")
                        continue
                    }
                    guard let pt = self.absolute(x: x, y: y) else {
                        log.warning("ScriptExecutor: ventana de Mirroring no disponible")
                        continue
                    }
                    self.mouse.tap(at: pt)
                    log.debug("Script .tap en (\(x), \(y))")

                case .swipe:
                    // FIX: validar x/y no nulos
                    guard let x = step.x, let y = step.y else {
                        log.warning("ScriptExecutor: paso .swipe sin coordenadas — se omite")
                        continue
                    }
                    guard let pt = self.absolute(x: x, y: y),
                          let frame = self.windowTracker.mirroringWindowFrame else {
                        log.warning("ScriptExecutor: ventana de Mirroring no disponible para swipe")
                        continue
                    }
                    // Swipe hacia arriba por defecto (270°), distancia 20% del alto
                    let dist = frame.height * 0.20
                    self.mouse.swipe(from: pt, directionDegrees: 270.0,
                                     distancePx: dist, durationMs: 200)
                    log.debug("Script .swipe desde (\(x), \(y))")

                case .wait:
                    // El delay ya se aplicó antes del switch — no hay acción adicional
                    log.debug("Script .wait \(delayMs)ms")
                }
            }
            log.debug("Script completado — \(steps.count) paso(s)")
        }
    }

    func cancel() {
        runningTask?.cancel()
        runningTask = nil
    }

    deinit { cancel() }
}

// MARK: - SkillsPadExecutor
final class SkillsPadExecutor: ActionExecutor {
    let windowTracker: WindowTracker
    let mouse:         MouseSimulator

    private var trackTimer: DispatchSourceTimer?
    private var center:     CGPoint = .zero
    private var skills:     [SkillSlot] = []

    init(windowTracker: WindowTracker, mouse: MouseSimulator) {
        self.windowTracker = windowTracker
        self.mouse         = mouse
    }

    func activate(centerX: Double, centerY: Double, skills: [SkillSlot]) {
        self.skills = skills
        guard let pt = absolute(x: centerX, y: centerY) else { return }
        self.center = pt
        mouse.holdDown(at: pt)

        // Rastrear posición del cursor para saber qué skill apunta
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        t.schedule(deadline: .now(), repeating: .milliseconds(32))
        t.setEventHandler { [weak self] in self?.updateSkillSelection() }
        trackTimer = t
        t.resume()
    }

    private func updateSkillSelection() {
        let cursorPos = NSEvent.mouseLocation
        let dx = cursorPos.x - center.x
        let dy = center.y - cursorPos.y    // invertir Y
        let dist = sqrt(dx * dx + dy * dy)
        guard dist > 20 else { return }   // zona muerta central

        let angle = (atan2(dy, dx) * 180.0 / .pi + 360.0).truncatingRemainder(dividingBy: 360)
        if let skill = skills.min(by: {
            angleDiff(a: $0.angleDegrees, b: angle) < angleDiff(a: $1.angleDegrees, b: angle)
        }), let pt = absolute(x: skill.targetX, y: skill.targetY) {
            mouse.holdDown(at: pt)
        }
    }

    func release() {
        trackTimer?.cancel()
        trackTimer = nil
        mouse.holdUp(at: center)
        log.debug("SkillsPad liberado")
    }

    private func angleDiff(a: Double, b: Double) -> Double {
        var diff = abs(a - b)
        if diff > 180 { diff = 360 - diff }
        return diff
    }

    deinit { release() }
}
