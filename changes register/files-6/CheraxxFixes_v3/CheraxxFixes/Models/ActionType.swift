// Models/ActionType.swift
// CORRECCIONES APLICADAS EN ESTA VERSION:
// ✅ SkillSlot: añadidos targetX y targetY (requeridos por SkillsPadExecutor).
//    Sin estos campos ActionExecutors.swift no compilaba.
// ✅ MappingProfile.bindings: valor por defecto [] para que ContentView
//    pueda crear MappingProfile(name:) sin pasar bindings explícitamente.
// ✅ ActionType.accentColor marcado @MainActor — compatible con Swift 6.
// ✅ ActionParams: implementación Codable manual completa para enum con
//    associated values. El compilador NO genera Codable automático.
// ✅ appBundleID en MappingProfile (para auto-switch de perfil por app).

import Foundation
import SwiftUI

// MARK: - ActionType
enum ActionType: String, Codable, CaseIterable, Identifiable {
    var id: String { rawValue }

    case tap            = "tap"
    case repeatedTap    = "repeatedTap"
    case dpad           = "dpad"
    case dpadMOBA       = "dpadMOBA"
    case skillsPad      = "skillsPad"
    case aimAndShoot    = "aimAndShoot"
    case freeLook       = "freeLook"
    case swipe          = "swipe"
    case focus          = "focus"
    case tilt           = "tilt"
    case rotate         = "rotate"
    case edgePan        = "edgePan"
    case scroll         = "scroll"
    case mouseWheel     = "mouseWheel"
    case nativeCursor   = "nativeCursor"
    case script         = "script"

    var displayName: String {
        switch self {
        case .tap:          return "Tocar Punto"
        case .repeatedTap:  return "Toques Repetidos"
        case .dpad:         return "D-Pad"
        case .dpadMOBA:     return "D-Pad MOBA"
        case .skillsPad:    return "Pad de Habilidades"
        case .aimAndShoot:  return "Apunta y Dispara"
        case .freeLook:     return "Mirada Libre"
        case .swipe:        return "Deslizar"
        case .focus:        return "Enfocar"
        case .tilt:         return "Inclinación"
        case .rotate:       return "Rotar"
        case .edgePan:      return "Desplaz. de Borde"
        case .scroll:       return "Desplazarse"
        case .mouseWheel:   return "Rueda de Ratón"
        case .nativeCursor: return "Cursor Nativo"
        case .script:       return "Script / Macro"
        }
    }

    var icon: String {
        switch self {
        case .tap:          return "hand.tap.fill"
        case .repeatedTap:  return "repeat"
        case .dpad:         return "dpad.fill"
        case .dpadMOBA:     return "circle.grid.cross.fill"
        case .skillsPad:    return "circle.hexagongrid.fill"
        case .aimAndShoot:  return "scope"
        case .freeLook:     return "eye.fill"
        case .swipe:        return "hand.draw.fill"
        case .focus:        return "camera.metering.center.weighted"
        case .tilt:         return "iphone.gen3.motion"
        case .rotate:       return "arrow.clockwise.circle.fill"
        case .edgePan:      return "arrow.up.and.down.and.arrow.left.and.right"
        case .scroll:       return "rectangle.and.hand.point.up.left.fill"
        case .mouseWheel:   return "scroll.fill"
        case .nativeCursor: return "cursor.rays"
        case .script:       return "chevron.left.forwardslash.chevron.right"
        }
    }

    @MainActor
    var accentColor: Color {
        switch self {
        case .tap, .repeatedTap:                  return CheraxxTheme.accentCyan
        case .dpad, .dpadMOBA, .skillsPad:        return CheraxxTheme.accentOrange
        case .aimAndShoot, .freeLook:             return CheraxxTheme.accentRed
        case .swipe, .focus, .rotate:             return Color(hex: "A855F7")
        case .tilt, .edgePan:                     return Color(hex: "EAB308")
        case .scroll, .mouseWheel:                return CheraxxTheme.accentGreen
        case .nativeCursor:                       return CheraxxTheme.textSecondary
        case .script:                             return Color(hex: "F97316")
        }
    }

    var defaultSize: CGSize {
        switch self {
        case .dpad, .dpadMOBA:   return CGSize(width: 110, height: 110)
        case .skillsPad:         return CGSize(width: 130, height: 130)
        case .aimAndShoot:       return CGSize(width: 160, height: 120)
        case .edgePan:           return CGSize(width: 200, height: 40)
        default:                 return CGSize(width: 54, height: 54)
        }
    }
}

// MARK: - ActionParams
enum ActionParams {
    case tap(key: String, altKey: String? = nil)
    case repeatedTap(key: String, intervalMs: Int = 100, autofire: Bool = false)
    case dpad(
        keyUp: String, keyDown: String, keyLeft: String, keyRight: String,
        altKeyUp: String? = nil, altKeyDown: String? = nil,
        altKeyLeft: String? = nil, altKeyRight: String? = nil,
        xRadius: Double = 7.64, deadzoneRadius: Double = 0.0, speedMs: Double = 200.0
    )
    case dpadMOBA(
        keyUp: String, keyDown: String, keyLeft: String, keyRight: String,
        xRadius: Double = 10.0, isFloating: Bool = true
    )
    case skillsPad(skills: [SkillSlot])
    case aimAndShoot(
        keyToggle: String,
        keyAction: String,
        keySuspend: String? = nil,
        sensitivityX: Double = 1.4,
        sensitivityY: Double = 1.0,
        shootOnClick: Bool = true,
        mouseAcceleration: Bool = false,
        left: Double = 250, right: Double = 250,
        top: Double = 1000, bottom: Double = 1000
    )
    case freeLook(keyHold: String, sensitivityX: Double = 1.0, sensitivityY: Double = 1.0)
    case swipe(
        key: String, directionDegrees: Double = 270.0,
        distancePct: Double = 10.0, durationMs: Int = 200
    )
    case focus(keyHold: String, holdDurationMs: Int = 500)
    case tilt(keyLeft: String, keyRight: String, intensity: Double = 1.0)
    case rotate(key: String, angleDegrees: Double = 90.0, clockwise: Bool = true)
    case edgePan(sensitivityX: Double = 1.0, sensitivityY: Double = 1.0,
                 edgeThresholdPct: Double = 5.0)
    case scroll(key: String, directionDegrees: Double = 180.0, speedPps: Double = 500.0)
    case mouseWheel(sensitivityY: Double = 1.0)
    case nativeCursor
    case script(key: String, steps: [MacroStep])
}

// MARK: - ActionParams + Codable
extension ActionParams: Codable {
    private enum CodingKeys: String, CodingKey { case type, payload }
    private enum TypeTag: String, Codable {
        case tap, repeatedTap, dpad, dpadMOBA, skillsPad,
             aimAndShoot, freeLook, swipe, focus, tilt, rotate,
             edgePan, scroll, mouseWheel, nativeCursor, script
    }

    private struct TapPayload: Codable { var key: String; var altKey: String? }
    private struct RepeatedTapPayload: Codable { var key: String; var intervalMs: Int; var autofire: Bool }
    private struct DpadPayload: Codable {
        var keyUp, keyDown, keyLeft, keyRight: String
        var altKeyUp, altKeyDown, altKeyLeft, altKeyRight: String?
        var xRadius, deadzoneRadius, speedMs: Double
    }
    private struct DpadMOBAPayload: Codable {
        var keyUp, keyDown, keyLeft, keyRight: String
        var xRadius: Double; var isFloating: Bool
    }
    private struct SkillsPadPayload: Codable { var skills: [SkillSlot] }
    private struct AimAndShootPayload: Codable {
        var keyToggle, keyAction: String; var keySuspend: String?
        var sensitivityX, sensitivityY: Double
        var shootOnClick, mouseAcceleration: Bool
        var left, right, top, bottom: Double
    }
    private struct FreeLookPayload: Codable { var keyHold: String; var sensitivityX, sensitivityY: Double }
    private struct SwipePayload: Codable { var key: String; var directionDegrees, distancePct: Double; var durationMs: Int }
    private struct FocusPayload: Codable { var keyHold: String; var holdDurationMs: Int }
    private struct TiltPayload: Codable { var keyLeft, keyRight: String; var intensity: Double }
    private struct RotatePayload: Codable { var key: String; var angleDegrees: Double; var clockwise: Bool }
    private struct EdgePanPayload: Codable { var sensitivityX, sensitivityY, edgeThresholdPct: Double }
    private struct ScrollPayload: Codable { var key: String; var directionDegrees, speedPps: Double }
    private struct MouseWheelPayload: Codable { var sensitivityY: Double }
    private struct ScriptPayload: Codable { var key: String; var steps: [MacroStep] }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .tap(let k, let a):
            try c.encode(TypeTag.tap, forKey: .type)
            try c.encode(TapPayload(key: k, altKey: a), forKey: .payload)
        case .repeatedTap(let k, let i, let af):
            try c.encode(TypeTag.repeatedTap, forKey: .type)
            try c.encode(RepeatedTapPayload(key: k, intervalMs: i, autofire: af), forKey: .payload)
        case .dpad(let u, let d, let l, let r, let au, let ad, let al, let ar, let xr, let dz, let sp):
            try c.encode(TypeTag.dpad, forKey: .type)
            try c.encode(DpadPayload(keyUp: u, keyDown: d, keyLeft: l, keyRight: r,
                                     altKeyUp: au, altKeyDown: ad, altKeyLeft: al, altKeyRight: ar,
                                     xRadius: xr, deadzoneRadius: dz, speedMs: sp), forKey: .payload)
        case .dpadMOBA(let u, let d, let l, let r, let xr, let fl):
            try c.encode(TypeTag.dpadMOBA, forKey: .type)
            try c.encode(DpadMOBAPayload(keyUp: u, keyDown: d, keyLeft: l, keyRight: r,
                                          xRadius: xr, isFloating: fl), forKey: .payload)
        case .skillsPad(let skills):
            try c.encode(TypeTag.skillsPad, forKey: .type)
            try c.encode(SkillsPadPayload(skills: skills), forKey: .payload)
        case .aimAndShoot(let kt, let ka, let ks, let sx, let sy, let sc, let ma, let lft, let rgt, let tp, let bt):
            try c.encode(TypeTag.aimAndShoot, forKey: .type)
            try c.encode(AimAndShootPayload(keyToggle: kt, keyAction: ka, keySuspend: ks,
                                             sensitivityX: sx, sensitivityY: sy,
                                             shootOnClick: sc, mouseAcceleration: ma,
                                             left: lft, right: rgt, top: tp, bottom: bt), forKey: .payload)
        case .freeLook(let kh, let sx, let sy):
            try c.encode(TypeTag.freeLook, forKey: .type)
            try c.encode(FreeLookPayload(keyHold: kh, sensitivityX: sx, sensitivityY: sy), forKey: .payload)
        case .swipe(let k, let dir, let dist, let dur):
            try c.encode(TypeTag.swipe, forKey: .type)
            try c.encode(SwipePayload(key: k, directionDegrees: dir, distancePct: dist, durationMs: dur), forKey: .payload)
        case .focus(let kh, let hold):
            try c.encode(TypeTag.focus, forKey: .type)
            try c.encode(FocusPayload(keyHold: kh, holdDurationMs: hold), forKey: .payload)
        case .tilt(let kl, let kr, let i):
            try c.encode(TypeTag.tilt, forKey: .type)
            try c.encode(TiltPayload(keyLeft: kl, keyRight: kr, intensity: i), forKey: .payload)
        case .rotate(let k, let ang, let cw):
            try c.encode(TypeTag.rotate, forKey: .type)
            try c.encode(RotatePayload(key: k, angleDegrees: ang, clockwise: cw), forKey: .payload)
        case .edgePan(let sx, let sy, let et):
            try c.encode(TypeTag.edgePan, forKey: .type)
            try c.encode(EdgePanPayload(sensitivityX: sx, sensitivityY: sy, edgeThresholdPct: et), forKey: .payload)
        case .scroll(let k, let dir, let sp):
            try c.encode(TypeTag.scroll, forKey: .type)
            try c.encode(ScrollPayload(key: k, directionDegrees: dir, speedPps: sp), forKey: .payload)
        case .mouseWheel(let sy):
            try c.encode(TypeTag.mouseWheel, forKey: .type)
            try c.encode(MouseWheelPayload(sensitivityY: sy), forKey: .payload)
        case .nativeCursor:
            try c.encode(TypeTag.nativeCursor, forKey: .type)
        case .script(let k, let steps):
            try c.encode(TypeTag.script, forKey: .type)
            try c.encode(ScriptPayload(key: k, steps: steps), forKey: .payload)
        }
    }

    init(from decoder: Decoder) throws {
        let c   = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(TypeTag.self, forKey: .type)
        switch tag {
        case .tap:
            let p = try c.decode(TapPayload.self, forKey: .payload)
            self = .tap(key: p.key, altKey: p.altKey)
        case .repeatedTap:
            let p = try c.decode(RepeatedTapPayload.self, forKey: .payload)
            self = .repeatedTap(key: p.key, intervalMs: p.intervalMs, autofire: p.autofire)
        case .dpad:
            let p = try c.decode(DpadPayload.self, forKey: .payload)
            self = .dpad(keyUp: p.keyUp, keyDown: p.keyDown, keyLeft: p.keyLeft, keyRight: p.keyRight,
                         altKeyUp: p.altKeyUp, altKeyDown: p.altKeyDown,
                         altKeyLeft: p.altKeyLeft, altKeyRight: p.altKeyRight,
                         xRadius: p.xRadius, deadzoneRadius: p.deadzoneRadius, speedMs: p.speedMs)
        case .dpadMOBA:
            let p = try c.decode(DpadMOBAPayload.self, forKey: .payload)
            self = .dpadMOBA(keyUp: p.keyUp, keyDown: p.keyDown, keyLeft: p.keyLeft, keyRight: p.keyRight,
                              xRadius: p.xRadius, isFloating: p.isFloating)
        case .skillsPad:
            let p = try c.decode(SkillsPadPayload.self, forKey: .payload)
            self = .skillsPad(skills: p.skills)
        case .aimAndShoot:
            let p = try c.decode(AimAndShootPayload.self, forKey: .payload)
            self = .aimAndShoot(keyToggle: p.keyToggle, keyAction: p.keyAction, keySuspend: p.keySuspend,
                                sensitivityX: p.sensitivityX, sensitivityY: p.sensitivityY,
                                shootOnClick: p.shootOnClick, mouseAcceleration: p.mouseAcceleration,
                                left: p.left, right: p.right, top: p.top, bottom: p.bottom)
        case .freeLook:
            let p = try c.decode(FreeLookPayload.self, forKey: .payload)
            self = .freeLook(keyHold: p.keyHold, sensitivityX: p.sensitivityX, sensitivityY: p.sensitivityY)
        case .swipe:
            let p = try c.decode(SwipePayload.self, forKey: .payload)
            self = .swipe(key: p.key, directionDegrees: p.directionDegrees,
                          distancePct: p.distancePct, durationMs: p.durationMs)
        case .focus:
            let p = try c.decode(FocusPayload.self, forKey: .payload)
            self = .focus(keyHold: p.keyHold, holdDurationMs: p.holdDurationMs)
        case .tilt:
            let p = try c.decode(TiltPayload.self, forKey: .payload)
            self = .tilt(keyLeft: p.keyLeft, keyRight: p.keyRight, intensity: p.intensity)
        case .rotate:
            let p = try c.decode(RotatePayload.self, forKey: .payload)
            self = .rotate(key: p.key, angleDegrees: p.angleDegrees, clockwise: p.clockwise)
        case .edgePan:
            let p = try c.decode(EdgePanPayload.self, forKey: .payload)
            self = .edgePan(sensitivityX: p.sensitivityX, sensitivityY: p.sensitivityY,
                            edgeThresholdPct: p.edgeThresholdPct)
        case .scroll:
            let p = try c.decode(ScrollPayload.self, forKey: .payload)
            self = .scroll(key: p.key, directionDegrees: p.directionDegrees, speedPps: p.speedPps)
        case .mouseWheel:
            let p = try c.decode(MouseWheelPayload.self, forKey: .payload)
            self = .mouseWheel(sensitivityY: p.sensitivityY)
        case .nativeCursor:
            self = .nativeCursor
        case .script:
            let p = try c.decode(ScriptPayload.self, forKey: .payload)
            self = .script(key: p.key, steps: p.steps)
        }
    }
}

// MARK: - SkillSlot
// FIX: añadidos targetX y targetY (coordenadas relativas 0–100 del objetivo de la skill).
// SkillsPadExecutor los necesita para simular el tap en la posición correcta.
// El usuario los configura arrastrando en el canvas. Por defecto: centro (50, 50).
struct SkillSlot: Codable, Identifiable, Sendable {
    var id: UUID            = UUID()
    var key: String
    var angleDegrees: Double
    var label: String?
    var holdDurationMs: Int = 0

    /// Coordenada X relativa (0–100) del botón de habilidad en la pantalla de Mirroring.
    var targetX: Double     = 50.0

    /// Coordenada Y relativa (0–100) del botón de habilidad en la pantalla de Mirroring.
    var targetY: Double     = 50.0
}

// MARK: - MacroStep
struct MacroStep: Codable, Identifiable, Sendable {
    var id: UUID = UUID()

    enum StepType: String, Codable, Sendable {
        case tap    // Tap en coordenada (x, y)
        case swipe  // Swipe desde (x, y)
        case wait   // Espera delayMs ms sin acción
    }

    var type: StepType

    /// Coordenada X relativa (0–100). Requerida para .tap y .swipe.
    var x: Double?

    /// Coordenada Y relativa (0–100). Requerida para .tap y .swipe.
    var y: Double?

    /// Retardo antes de este paso en milisegundos (mín. 0).
    var delayMs: Int = 0 {
        didSet { if delayMs < 0 { delayMs = 0 } }
    }

    var comment: String?
}

// MARK: - KeyBinding
struct KeyBinding: Codable, Identifiable, Sendable {
    var id: UUID = UUID()
    var label: String
    var action: ActionType
    var showOnOverlay: Bool  = true
    var x: Double
    var y: Double
    var params: ActionParams
    var customColor: String?
    var isEnabled: Bool      = true
    var notes: String?
}

// MARK: - MappingProfile
struct MappingProfile: Codable, Identifiable, Sendable {
    var id: UUID            = UUID()
    var name: String
    /// Bundle ID de la app objetivo para auto-switch de perfil.
    var appBundleID: String?
    var description: String?
    var version: Int        = 1
    var createdAt: Date     = Date()
    var updatedAt: Date     = Date()

    // FIX: valor por defecto = [] para que ContentView pueda construir
    // MappingProfile(name: "Sin perfil") sin pasar bindings explícitamente.
    var bindings: [KeyBinding] = []

    var isActive: Bool      = false
    var iconName: String?
    var accentHex: String?

    @MainActor
    var accentColor: Color {
        if let hex = accentHex { return Color(hex: hex) }
        return CheraxxTheme.accentCyan
    }
}
