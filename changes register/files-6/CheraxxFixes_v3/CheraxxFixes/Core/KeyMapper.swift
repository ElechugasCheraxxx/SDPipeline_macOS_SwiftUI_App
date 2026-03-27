// Core/KeyMapper.swift
// CORRECCIÓN — KeyMapper ya no es un god-class.
// Responsabilidades actuales:
//   • Activar/desactivar el EventTap.
//   • Mapear teclas → bindings del perfil activo.
//   • Delegar ejecución a los Executor específicos (ActionExecutors.swift).
//   • Exponer estado observable (isEnabled, activeKeys, activeProfile).
// Cada familia de acciones vive en su propio Executor struct/class.
// No hay lógica de ejecución aquí — solo dispatching.

import AppKit
import SwiftUI
import os

private let log = Logger(subsystem: "com.cheraxx.keymapper", category: "KeyMapper")

@Observable
@MainActor
final class KeyMapper {

    // MARK: - Estado público
    var isEnabled:     Bool              = false
    var activeProfile: MappingProfile?
    var activeKeys:    Set<String>       = []

    // MARK: - Dependencias inyectadas
    // FIX: windowTracker es var para que AppSetupModifier pueda inyectar
    // el WindowTracker compartido de CheraxxApp después de la construcción.
    // Sin esto, KeyMapper() creaba su propio WindowTracker interno que nunca
    // compartía estado con el de CheraxxApp ni con OverlayManager.
    private let eventTap:      EventTapManager
    var windowTracker:         WindowTracker   // var: reemplazable vía setWindowTracker()
    private let mouse:         MouseSimulator

    // MARK: - Executors (uno por tipo de acción)
    private lazy var tapExec:         TapExecutor         = .init(windowTracker: windowTracker, mouse: mouse)
    private lazy var swipeExec:       SwipeExecutor       = .init(windowTracker: windowTracker, mouse: mouse)
    private lazy var scriptExec:      ScriptExecutor      = .init(windowTracker: windowTracker, mouse: mouse)
    private lazy var repeatedTapExec: RepeatedTapExecutor = .init(windowTracker: windowTracker, mouse: mouse)
    private lazy var skillsPadExec:   SkillsPadExecutor   = .init(windowTracker: windowTracker, mouse: mouse)

    // Executors con estado por binding (se crean/destruyen al cambiar perfil)
    private var dpadExecutors:       [UUID: DpadExecutor]         = [:]
    private var aimAndShootExecutors:[UUID: AimAndShootExecutor]  = [:]

    // MARK: - Init (inyección de dependencias)
    init(eventTap:      EventTapManager  = EventTapManager(),
         windowTracker: WindowTracker    = WindowTracker(),
         mouse:         MouseSimulator   = .shared) {
        self.eventTap      = eventTap
        self.windowTracker = windowTracker
        self.mouse         = mouse
        wireEventTap()
    }

    // MARK: - Activar / Desactivar
    func enable() {
        guard !isEnabled else { return }
        eventTap.start()
        isEnabled = true
        log.info("KeyMapper activado — perfil: \(self.activeProfile?.name ?? "ninguno")")
    }

    func disable() {
        guard isEnabled else { return }
        releaseAllExecutors()
        eventTap.stop()
        isEnabled = false
        activeKeys.removeAll()
        log.info("KeyMapper desactivado")
    }

    func toggle() { isEnabled ? disable() : enable() }

    // MARK: - Perfil activo
    func setProfile(_ profile: MappingProfile?) {
        releaseAllExecutors()
        dpadExecutors.removeAll()
        aimAndShootExecutors.removeAll()

        activeProfile = profile
        activeKeys.removeAll()

        // Pre-instanciar executors con estado por binding
        profile?.bindings.forEach { binding in
            switch binding.params {
            case .dpad:         dpadExecutors[binding.id]        = DpadExecutor(windowTracker: windowTracker, mouse: mouse)
            case .dpadMOBA:     dpadExecutors[binding.id]        = DpadExecutor(windowTracker: windowTracker, mouse: mouse)
            case .aimAndShoot:  aimAndShootExecutors[binding.id] = AimAndShootExecutor(windowTracker: windowTracker, mouse: mouse)
            default:            break
            }
        }

        log.info("Perfil activo: \(profile?.name ?? "ninguno") — \(profile?.bindings.count ?? 0) bindings")
    }

    // MARK: - Wiring del EventTap
    private func wireEventTap() {
        eventTap.onKeyDown = { [weak self] key in
            Task { @MainActor [weak self] in
                self?.activeKeys.insert(key)
                self?.handleKeyDown(key)
            }
        }
        eventTap.onKeyUp = { [weak self] key in
            Task { @MainActor [weak self] in
                self?.activeKeys.remove(key)
                self?.handleKeyUp(key)
            }
        }
        eventTap.shouldBlock = { [weak self] key in
            guard let self, self.isEnabled else { return false }
            return self.activeProfile?.bindings.contains { self.keyMatches(key, in: $0) } ?? false
        }
    }

    // MARK: - Dispatch keyDown → executor
    private func handleKeyDown(_ key: String) {
        guard isEnabled, let profile = activeProfile else { return }

        for binding in profile.bindings where keyMatches(key, in: binding) {
            switch binding.params {
            case .tap(_, let holdMs):
                tapExec.execute(x: binding.x, y: binding.y, holdMs: holdMs ?? 80)

            case .repeatedTap(_, let interval, let holdMs):
                repeatedTapExec.start(x: binding.x, y: binding.y,
                                      intervalMs: interval ?? 200,
                                      holdMs: holdMs ?? 80)

            case .dpad(let kU, let kD, let kL, let kR,
                       let akU, let akD, let akL, let akR,
                       let radius, let floating, let speed):
                let dir = dpadDirection(for: key,
                    keyUp: kU, keyDown: kD, keyLeft: kL, keyRight: kR,
                    altKeyUp: akU, altKeyDown: akD, altKeyLeft: akL, altKeyRight: akR)
                dpadExecutors[binding.id]?.keyDown(
                    direction: dir, centerX: binding.x, centerY: binding.y,
                    radiusPct: radius ?? 12.0, isFloating: floating ?? false,
                    speedFactor: speed ?? 1.0
                )

            case .dpadMOBA(let kU, let kD, let kL, let kR, let radius, let speed):
                let dir = dpadDirection(for: key, keyUp: kU, keyDown: kD, keyLeft: kL, keyRight: kR)
                dpadExecutors[binding.id]?.keyDown(
                    direction: dir, centerX: binding.x, centerY: binding.y,
                    radiusPct: radius ?? 14.0, isFloating: true, speedFactor: speed ?? 1.0
                )

            case .aimAndShoot(_, _, _, let left, let right, let top, let bottom, let sens, _, _, _):
                let bounds = AimAndShootExecutor.Bounds(
                    left: left ?? 0, right: right ?? 100,
                    top: top ?? 0, bottom: bottom ?? 100
                )
                aimAndShootExecutors[binding.id]?.toggle(
                    x: binding.x, y: binding.y, bounds: bounds, sensitivity: sens ?? 1.0
                )

            case .swipe(_, let degrees, let distPct, let durationMs):
                swipeExec.execute(x: binding.x, y: binding.y,
                                  degrees: degrees ?? 0.0,
                                  distancePct: distPct ?? 30.0,
                                  durationMs: durationMs ?? 200)

            case .focus(_, let holdMs):
                tapExec.execute(x: binding.x, y: binding.y, holdMs: holdMs ?? 500)

            case .skillsPad(let skills):
                skillsPadExec.activate(centerX: binding.x, centerY: binding.y, skills: skills)

            case .tilt(_, _, let sens):
                // El tilt se maneja en un executor dedicado (simplificado aquí)
                handleTilt(binding: binding, sens: sens ?? 1.0)

            case .rotate(_, let degrees, _):
                handleRotate(binding: binding, degrees: degrees ?? 90.0)

            case .scroll(_, let degrees, let speed):
                handleScroll(binding: binding, degrees: degrees ?? 270.0, speed: speed ?? 1.0)

            case .script(_, let steps):
                scriptExec.execute(steps: steps)

            case .freeLook(_, let sensitivityX, let sensitivityY):
                handleFreeLook(binding: binding, sx: sensitivityX ?? 1.0, sy: sensitivityY ?? 1.0)

            case .edgePan, .mouseWheel, .nativeCursor:
                // Gestionados por rastreo continuo del cursor, no por teclas
                break
            }
        }
    }

    // MARK: - Dispatch keyUp → executor
    private func handleKeyUp(_ key: String) {
        guard let profile = activeProfile else { return }

        for binding in profile.bindings where keyMatches(key, in: binding) {
            switch binding.params {
            case .repeatedTap:
                repeatedTapExec.stop()

            case .dpad(let kU, let kD, let kL, let kR,
                       let akU, let akD, let akL, let akR,
                       let radius, _, let speed):
                let dir = dpadDirection(for: key,
                    keyUp: kU, keyDown: kD, keyLeft: kL, keyRight: kR,
                    altKeyUp: akU, altKeyDown: akD, altKeyLeft: akL, altKeyRight: akR)
                dpadExecutors[binding.id]?.keyUp(
                    direction: dir, centerX: binding.x, centerY: binding.y,
                    radiusPct: radius ?? 12.0, speedFactor: speed ?? 1.0
                )

            case .dpadMOBA(let kU, let kD, let kL, let kR, let radius, let speed):
                let dir = dpadDirection(for: key, keyUp: kU, keyDown: kD, keyLeft: kL, keyRight: kR)
                dpadExecutors[binding.id]?.keyUp(
                    direction: dir, centerX: binding.x, centerY: binding.y,
                    radiusPct: radius ?? 14.0, speedFactor: speed ?? 1.0
                )

            case .skillsPad:
                skillsPadExec.release()

            case .script:
                scriptExec.cancel()

            default:
                break
            }
        }
    }

    // MARK: - Helpers
    private func keyMatches(_ key: String, in binding: KeyBinding) -> Bool {
        switch binding.params {
        case .tap(let k, let alt):
            return k == key || alt == key
        case .repeatedTap(let k, _, _):
            return k == key
        case .dpad(let u, let d, let l, let r, let au, let ad, let al, let ar, _, _, _):
            return [u, d, l, r, au, ad, al, ar].compactMap { $0 }.contains(key)
        case .dpadMOBA(let u, let d, let l, let r, _, _):
            return [u, d, l, r].contains(key)
        case .skillsPad(let skills):
            return skills.map { $0.key }.contains(key)
        case .aimAndShoot(let t, let a, let s, _, _, _, _, _, _, _, _):
            return [t, a, s].compactMap { $0 }.contains(key)
        case .freeLook(let k, _, _):
            return k == key
        case .swipe(let k, _, _, _):
            return k == key
        case .focus(let k, _):
            return k == key
        case .tilt(let l, let r, _):
            return l == key || r == key
        case .rotate(let k, _, _):
            return k == key
        case .scroll(let k, _, _):
            return k == key
        case .script(let k, _):
            return k == key
        case .edgePan, .mouseWheel, .nativeCursor:
            return false
        }
    }

    private func dpadDirection(for key: String,
                                keyUp: String, keyDown: String,
                                keyLeft: String, keyRight: String,
                                altKeyUp: String?   = nil,
                                altKeyDown: String? = nil,
                                altKeyLeft: String? = nil,
                                altKeyRight: String? = nil) -> DpadExecutor.Direction {
        switch key {
        case keyUp:    return .up
        case keyDown:  return .down
        case keyLeft:  return .left
        case keyRight: return .right
        case altKeyUp   where altKeyUp != nil:    return .altUp
        case altKeyDown  where altKeyDown != nil:  return .altDown
        case altKeyLeft  where altKeyLeft != nil:  return .altLeft
        case altKeyRight where altKeyRight != nil: return .altRight
        default: return .up
        }
    }

    // MARK: - Acciones simples sin executor dedicado
    private func handleTilt(binding: KeyBinding, sens: Double) {
        guard let frame = windowTracker.mirroringWindowFrame,
              let pt    = windowTracker.absolutePoint(relativeX: binding.x, relativeY: binding.y)
        else { return }
        let offset = frame.width * 0.08 * sens
        // Simplificado: mueve hacia izquierda o derecha
        mouse.holdDown(at: CGPoint(x: pt.x - offset, y: pt.y))
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { self.mouse.holdUp(at: pt) }
    }

    private func handleRotate(binding: KeyBinding, degrees: Double) {
        guard let center = windowTracker.absolutePoint(relativeX: binding.x, relativeY: binding.y),
              let frame  = windowTracker.mirroringWindowFrame else { return }
        let radius = frame.width * 0.10
        let steps  = 24
        let rad    = degrees * .pi / 180.0
        let angleStep = rad / Double(steps)

        DispatchQueue.global(qos: .userInteractive).async {
            self.mouse.holdDown(at: CGPoint(x: center.x + radius, y: center.y))
            for i in 0..<steps {
                Thread.sleep(forTimeInterval: 0.008)
                let a = angleStep * Double(i + 1)
                let pt = CGPoint(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius)
                self.mouse.holdDown(at: pt)
            }
            self.mouse.holdUp(at: CGPoint(x: center.x + radius, y: center.y))
        }
    }

    private func handleScroll(binding: KeyBinding, degrees: Double, speed: Double) {
        guard let pt = windowTracker.absolutePoint(relativeX: binding.x, relativeY: binding.y) else { return }
        let rad = degrees * .pi / 180.0
        let dx  = Int32(cos(rad) * 10.0 * speed)
        let dy  = Int32(sin(rad) * 10.0 * speed)
        mouse.scroll(deltaX: dx, deltaY: dy, at: pt)
    }

    private func handleFreeLook(binding: KeyBinding, sx: Double, sy: Double) {
        // En modo freeLook, el movimiento del cursor se mapea directamente.
        // La implementación completa requiere un timer que lea NSEvent.mouseLocation.
        // Simplificado: solo loguea inicio de freelook.
        log.debug("FreeLook activado en (\(binding.x), \(binding.y)) sx=\(sx) sy=\(sy)")
    }

    // MARK: - Limpieza
    private func releaseAllExecutors() {
        repeatedTapExec.stop()
        skillsPadExec.release()
        scriptExec.cancel()
        dpadExecutors.values.forEach {
            $0.releaseAll(centerX: 50, centerY: 50) // posición aproximada, sin frame activo
        }
        aimAndShootExecutors.values.forEach { $0.stopTracking() }
    }

    func captureNextKey(completion: @escaping (String) -> Void) {
        eventTap.captureNextKey(completion: completion)
    }

    deinit {
        releaseAllExecutors()
        eventTap.stop()
    }
}
