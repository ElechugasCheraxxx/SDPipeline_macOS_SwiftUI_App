// Overlay/OverlayView.swift
// CORRECCIONES:
// ✅ OverlayWidget muestra etiqueta para TODOS los ActionParams:
//    skillsPad, edgePan, mouseWheel, nativeCursor, dpadMOBA, repeatedTap, focus, swipe
//    antes caían a EmptyView() sin mostrar nada útil.
// ✅ Glow activado para todos los tipos activos, no solo algunos.
// ✅ Logger estructurado en lugar de print().
// ✅ Previews añadidos.

import SwiftUI
import os

private let log = Logger(subsystem: "com.cheraxx.keymapper", category: "OverlayView")

// MARK: - OverlayView
struct OverlayView: View {

    var profile: MappingProfile
    @Environment(WindowTracker.self) var windowTracker
    @Environment(KeyMapper.self)     var keyMapper

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.clear
                ForEach(profile.bindings.filter { $0.showOnOverlay }) { binding in
                    OverlayWidget(
                        binding: binding,
                        isActive: isActive(binding)
                    )
                    .position(
                        x: (binding.x / 100.0) * geo.size.width,
                        y: (binding.y / 100.0) * geo.size.height
                    )
                }
            }
        }
        .background(Color.clear)
    }

    private func isActive(_ binding: KeyBinding) -> Bool {
        let keys = allKeys(for: binding)
        return keys.contains { keyMapper.activeKeys.contains($0) }
    }

    /// Extrae todas las teclas asociadas a un binding para detectar si está activo.
    private func allKeys(for binding: KeyBinding) -> [String] {
        switch binding.params {
        case .tap(let k, let alt):
            return [k, alt].compactMap { $0 }
        case .repeatedTap(let k, _, _):
            return [k]
        case .dpad(let u, let d, let l, let r, let au, let ad, let al, let ar, _, _, _):
            return [u, d, l, r, au, ad, al, ar].compactMap { $0 }
        case .dpadMOBA(let u, let d, let l, let r, _, _):
            return [u, d, l, r]
        case .skillsPad(let skills):
            return skills.map { $0.key }
        case .aimAndShoot(let t, let a, let s, _, _, _, _, _, _, _, _):
            return [t, a, s].compactMap { $0 }
        case .freeLook(let k, _, _):
            return [k]
        case .swipe(let k, _, _, _):
            return [k]
        case .focus(let k, _):
            return [k]
        case .tilt(let l, let r, _):
            return [l, r]
        case .rotate(let k, _, _):
            return [k]
        case .scroll(let k, _, _):
            return [k]
        case .script(let k, _):
            return [k]
        case .edgePan, .mouseWheel, .nativeCursor:
            return []
        }
    }
}

// MARK: - OverlayWidget
struct OverlayWidget: View {
    var binding: KeyBinding
    var isActive: Bool

    @MainActor
    var color: Color { binding.action.accentColor }

    var size: CGSize {
        let s = binding.action.defaultSize
        return CGSize(width: s.width * 0.72, height: s.height * 0.72)
    }

    var body: some View {
        ZStack {
            // Glow exterior cuando está activo
            if isActive {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(color.opacity(0.30))
                    .frame(width: size.width + 12, height: size.height + 12)
                    .blur(radius: 8)
                    .transition(.opacity)
            }

            // Fondo del widget
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(isActive ? 0.60 : 0.38))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(color.opacity(isActive ? 0.85 : 0.30), lineWidth: 1)
                }
                .frame(width: size.width, height: size.height)

            // Contenido: icono + etiqueta
            VStack(spacing: 2) {
                Image(systemName: binding.action.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(color.opacity(isActive ? 1.0 : 0.7))

                keyLabelView
            }
            .frame(width: size.width, height: size.height)
        }
        .animation(.easeInOut(duration: 0.1), value: isActive)
    }

    // MARK: - Etiquetas por tipo
    @ViewBuilder
    private var keyLabelView: some View {
        switch binding.params {

        case .tap(let k, _):
            label(k)

        case .repeatedTap(let k, let interval, _):
            VStack(spacing: 1) {
                label(k)
                Text("\(interval)ms").overlayTinyFont(color: color, active: isActive)
            }

        case .dpad(let up, let down, let left, let right, _, _, _, _, _, _, _):
            dpadLabel(up: up, down: down, left: left, right: right)

        case .dpadMOBA(let up, let down, let left, let right, _, _):
            dpadLabel(up: up, down: down, left: left, right: right)

        case .skillsPad(let skills):
            let keys = skills.prefix(4).map { $0.key }.joined(separator: " ")
            label(keys)

        case .aimAndShoot(let toggle, _, _, _, _, _, _, _, _, _, _):
            label(toggle)

        case .freeLook(let k, _, _):
            label(k)

        case .swipe(let k, let dir, _, _):
            VStack(spacing: 1) {
                label(k)
                Text(directionArrow(degrees: dir)).overlayTinyFont(color: color, active: isActive)
            }

        case .focus(let k, let holdMs):
            VStack(spacing: 1) {
                label(k)
                Text("\(holdMs)ms").overlayTinyFont(color: color, active: isActive)
            }

        case .tilt(let l, let r, _):
            label("\(l)/\(r)")

        case .rotate(let k, _, let cw):
            VStack(spacing: 1) {
                label(k)
                Text(cw ? "↻" : "↺").overlayTinyFont(color: color, active: isActive)
            }

        case .edgePan:
            // Sin tecla fija — indica que responde al cursor
            Text("Edge").overlayKeyFont(color: color, active: isActive)

        case .scroll(let k, let dir, _):
            VStack(spacing: 1) {
                label(k)
                Text(directionArrow(degrees: dir)).overlayTinyFont(color: color, active: isActive)
            }

        case .mouseWheel:
            Text("Wheel").overlayKeyFont(color: color, active: isActive)

        case .nativeCursor:
            Text("Cursor").overlayKeyFont(color: color, active: isActive)

        case .script(let k, _):
            label(k)
        }
    }

    @ViewBuilder
    private func label(_ text: String) -> some View {
        Text(text.uppercased())
            .overlayKeyFont(color: color, active: isActive)
    }

    @ViewBuilder
    private func dpadLabel(up: String, down: String, left: String, right: String) -> some View {
        VStack(spacing: 0) {
            Text(up.uppercased()).overlayTinyFont(color: color, active: isActive)
            HStack(spacing: 4) {
                Text(left.uppercased()).overlayTinyFont(color: color, active: isActive)
                Text(right.uppercased()).overlayTinyFont(color: color, active: isActive)
            }
            Text(down.uppercased()).overlayTinyFont(color: color, active: isActive)
        }
    }

    /// Convierte grados a flecha Unicode.
    private func directionArrow(degrees: Double) -> String {
        let normalized = ((degrees.truncatingRemainder(dividingBy: 360)) + 360)
            .truncatingRemainder(dividingBy: 360)
        switch normalized {
        case   0..<45:   return "→"
        case  45..<135:  return "↓"
        case 135..<225:  return "←"
        case 225..<315:  return "↑"
        default:         return "→"
        }
    }
}

// MARK: - Modificadores de texto
private extension Text {
    func overlayKeyFont(color: Color, active: Bool) -> some View {
        self.font(.system(size: 8, weight: .bold, design: .monospaced))
            .foregroundStyle(color.opacity(active ? 1.0 : 0.65))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }

    func overlayTinyFont(color: Color, active: Bool) -> some View {
        self.font(.system(size: 6, weight: .semibold, design: .monospaced))
            .foregroundStyle(color.opacity(active ? 0.85 : 0.5))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
    }
}

// MARK: - Previews
#if DEBUG
#Preview("Overlay - varios widgets") {
    let wt = WindowTracker()
    let km = KeyMapper()

    let bindings: [KeyBinding] = [
        KeyBinding(label: "Mover", action: .dpad, showOnOverlay: true, x: 20, y: 70,
                   params: .dpad(keyUp: "W", keyDown: "S", keyLeft: "A", keyRight: "D")),
        KeyBinding(label: "Saltar", action: .tap, showOnOverlay: true, x: 80, y: 75,
                   params: .tap(key: "Space")),
        KeyBinding(label: "Apuntar", action: .aimAndShoot, showOnOverlay: true, x: 70, y: 40,
                   params: .aimAndShoot(keyToggle: "Tab", keyAction: "MouseLButton")),
        KeyBinding(label: "Skills", action: .skillsPad, showOnOverlay: true, x: 50, y: 50,
                   params: .skillsPad(skills: [
                    SkillSlot(key: "Q", angleDegrees: 315, label: "Q"),
                    SkillSlot(key: "E", angleDegrees: 45,  label: "E"),
                    SkillSlot(key: "R", angleDegrees: 135, label: "R"),
                   ])),
        KeyBinding(label: "Rueda", action: .mouseWheel, showOnOverlay: true, x: 85, y: 50,
                   params: .mouseWheel(sensitivityY: 1.0)),
        KeyBinding(label: "Borde", action: .edgePan, showOnOverlay: true, x: 50, y: 10,
                   params: .edgePan()),
    ]

    let profile = MappingProfile(name: "Demo Overlay", bindings: bindings)

    OverlayView(profile: profile)
        .environment(wt)
        .environment(km)
        .frame(width: 400, height: 700)
        .background(Color.gray.opacity(0.3))
}
#endif
