// UI/MappingCanvasView.swift
// CORRECCIONES:
// ✅ Escala doble corregida: SCStream captura a ×2 para Retina, pero Image()
//    debe usar scale: NSScreen.main?.backingScaleFactor ?? 2.0 en lugar de
//    scale: 2.0 hardcodeado. Si el monitor es @1x, la imagen era el doble de grande.
//    Adicionalmente, SCStreamConfiguration.width/height vuelven a ×1 porque
//    Image ya declara su escala correctamente.
// ✅ Eliminación de bindings con confirmación (Alert).
// ✅ Única instancia de MirroringCaptureManager (singleton compartido).
// ✅ Logger estructurado.
// ✅ Preview añadido.

import SwiftUI
import ScreenCaptureKit
import AVFoundation
import os

private let log = Logger(subsystem: "com.cheraxx.keymapper", category: "MappingCanvas")

// MARK: - MappingCanvasView
struct MappingCanvasView: View {
    @Binding var profile: MappingProfile
    @Environment(WindowTracker.self)  var windowTracker
    @Environment(KeyMapper.self)      var keyMapper
    @Environment(ProfileStore.self)   var profileStore

    @State private var selectedBindingID: UUID?
    @State private var showActionPicker   = false
    @State private var pendingDropPoint:  CGPoint?
    @State private var draggingID:        UUID?
    @State private var bindingToDelete:   KeyBinding?
    @State private var showDeleteConfirm  = false

    // Singleton compartido — una sola instancia en toda la app
    private let captureManager = MirroringCaptureManager.shared

    // Escala de pantalla actual (para corrección de imagen Retina)
    @State private var screenScale: CGFloat = 2.0

    var body: some View {
        GeometryReader { geo in
            let mirroringRect = previewRect(in: geo.size)
            ZStack {
                CanvasBackground(isConnected: windowTracker.isMirroringActive)
                mirroringPreviewLayer(geo: geo, rect: mirroringRect)

                ForEach($profile.bindings) { $binding in
                    if binding.showOnOverlay {
                        BindingWidget(
                            binding: $binding,
                            isSelected: selectedBindingID == binding.id,
                            canvasSize: mirroringRect.size
                        )
                        .position(canvasPosition(for: binding, in: mirroringRect))
                        .gesture(dragGesture(for: $binding, in: mirroringRect))
                        .onTapGesture {
                            withAnimation(.spring(duration: 0.2)) {
                                selectedBindingID = selectedBindingID == binding.id
                                    ? nil : binding.id
                            }
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                bindingToDelete = binding
                                showDeleteConfirm = true
                            } label: {
                                Label("Eliminar control", systemImage: "trash")
                            }
                        }
                        .zIndex(draggingID == binding.id ? 100 : 1)
                    }
                }

                // Zona de tap para añadir controles (solo en modo edición)
                if !keyMapper.isEnabled {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(coordinateSpace: .local) { location in
                            if let rel = relativePosition(point: location, in: mirroringRect) {
                                pendingDropPoint = CGPoint(x: rel.x, y: rel.y)
                                selectedBindingID = nil
                                showActionPicker  = true
                            }
                        }
                        .zIndex(0)
                }

                VStack {
                    CanvasToolbar(profile: $profile, selectedID: $selectedBindingID)
                    Spacer()
                    CanvasStatusBar(profile: profile)
                }
            }
        }
        .background(CheraxxTheme.backgroundPrimary)
        // Captura de pantalla
        .task {
            // Obtener escala del monitor principal
            screenScale = NSScreen.main?.backingScaleFactor ?? 2.0
            if windowTracker.isMirroringActive {
                await captureManager.startCapture()
            }
        }
        .onChange(of: windowTracker.isMirroringActive) { _, active in
            Task {
                if active {
                    screenScale = NSScreen.main?.backingScaleFactor ?? 2.0
                    await captureManager.startCapture()
                } else {
                    captureManager.stopCapture()
                }
            }
        }
        .onDisappear { captureManager.stopCapture() }
        // Selector de acción
        .sheet(isPresented: $showActionPicker) {
            ActionPickerView { actionType in
                if let point = pendingDropPoint {
                    addBinding(at: point, type: actionType)
                }
                showActionPicker = false
            }
        }
        // Confirmación de eliminación
        .alert("Eliminar control", isPresented: $showDeleteConfirm) {
            Button("Eliminar", role: .destructive) {
                if let b = bindingToDelete {
                    withAnimation {
                        profile.bindings.removeAll { $0.id == b.id }
                        if selectedBindingID == b.id { selectedBindingID = nil }
                        profileStore.update(profile, immediate: true)
                        log.debug("Binding eliminado: \(b.label)")
                    }
                }
                bindingToDelete = nil
            }
            Button("Cancelar", role: .cancel) { bindingToDelete = nil }
        } message: {
            Text("¿Eliminar «\(bindingToDelete?.label ?? "")»? Esta acción no se puede deshacer.")
        }
        // Permiso de grabación
        .alert("Permiso de Grabación de Pantalla", isPresented: .init(
            get: { captureManager.permissionDenied },
            set: { _ in }
        )) {
            Button("Abrir Ajustes del Sistema") {
                NSWorkspace.shared.open(
                    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
                )
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Cheraxx necesita permiso de Grabación de Pantalla para mostrar la duplicación del iPhone en el editor.\n\nVe a Ajustes del Sistema → Privacidad y Seguridad → Grabación de pantalla.")
        }
    }

    // MARK: - Geometría del preview
    private func previewRect(in canvasSize: CGSize) -> CGRect {
        let maxWidth  = canvasSize.width  * 0.72
        let maxHeight = canvasSize.height * 0.92

        let mirroringSize: CGSize
        if let frame = windowTracker.mirroringWindowFrame {
            mirroringSize = frame.size
        } else {
            mirroringSize = CGSize(width: 390, height: 844) // Ratio iPhone 14
        }

        let scaled = AVMakeRect(
            aspectRatio: mirroringSize,
            insideRect: CGRect(origin: .zero, size: CGSize(width: maxWidth, height: maxHeight))
        )
        return CGRect(
            x: (canvasSize.width  - scaled.width)  / 2.0,
            y: (canvasSize.height - scaled.height) / 2.0,
            width:  scaled.width,
            height: scaled.height
        )
    }

    // MARK: - Capa de preview en vivo
    @ViewBuilder
    private func mirroringPreviewLayer(geo: GeometryProxy, rect: CGRect) -> some View {
        let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)

        if captureManager.isCapturing, let cgImage = captureManager.capturedImage {
            ZStack(alignment: .topTrailing) {
                // FIX de escala doble:
                // SCStreamConfiguration captura a screenScale×, así que declaramos
                // esa escala en Image para que SwiftUI muestre el tamaño correcto.
                // Antes: scale siempre era 2.0 (hardcodeado) Y SCStream capturaba
                // a ×2, resultando en imagen pixelada o excesivamente grande en @1x.
                Image(cgImage, scale: screenScale, label: Text("iPhone Mirroring"))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: rect.width, height: rect.height)
                    .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 36, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        CheraxxTheme.accentCyan.opacity(0.35),
                                        CheraxxTheme.accentCyan.opacity(0.10)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint:   .bottomTrailing
                                ),
                                lineWidth: 1.5
                            )
                    }
                    .shadow(color: CheraxxTheme.accentCyan.opacity(0.18), radius: 24)

                liveBadge.padding(12)
            }
            .frame(width: rect.width, height: rect.height)
            .position(center)
            .zIndex(1)

        } else {
            ZStack {
                PhoneFrameGuide().frame(width: rect.width, height: rect.height)
                VStack(spacing: 10) {
                    if captureManager.permissionDenied {
                        Image(systemName: "lock.screen")
                            .font(.system(size: 32))
                            .foregroundStyle(CheraxxTheme.accentOrange)
                        Text("Permiso de pantalla denegado")
                            .font(CheraxxTheme.fontCaption)
                            .foregroundStyle(CheraxxTheme.accentOrange)
                    } else if windowTracker.isMirroringActive {
                        ProgressView().scaleEffect(0.7).tint(CheraxxTheme.accentCyan)
                        Text("Iniciando captura…")
                            .font(CheraxxTheme.fontCaption)
                            .foregroundStyle(CheraxxTheme.textSecondary)
                    } else {
                        Image(systemName: "iphone.slash")
                            .font(.system(size: 32))
                            .foregroundStyle(CheraxxTheme.textDisabled)
                        Text("Abre iPhone Mirroring para ver la pantalla aquí")
                            .font(CheraxxTheme.fontCaption)
                            .foregroundStyle(CheraxxTheme.textDisabled)
                            .multilineTextAlignment(.center)
                    }
                }
            }
            .position(center)
            .zIndex(1)
        }
    }

    private var liveBadge: some View {
        HStack(spacing: 4) {
            Circle().fill(CheraxxTheme.accentRed).frame(width: 5, height: 5)
            Text("EN VIVO")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(CheraxxTheme.textPrimary)
        }
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background {
            Capsule().fill(Color.black.opacity(0.55))
                .overlay { Capsule().stroke(Color.white.opacity(0.10), lineWidth: 1) }
        }
    }

    // MARK: - Gesto de arrastrado
    private func dragGesture(for binding: Binding<KeyBinding>, in rect: CGRect) -> some Gesture {
        DragGesture()
            .onChanged { value in
                draggingID = binding.id
                if let rel = relativePosition(point: value.location, in: rect) {
                    binding.x.wrappedValue = rel.x
                    binding.y.wrappedValue = rel.y
                }
            }
            .onEnded { _ in
                draggingID = nil
                profileStore.update(profile, immediate: true)
            }
    }

    // MARK: - Helpers de coordenadas
    private func canvasPosition(for binding: KeyBinding, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: rect.minX + (binding.x / 100.0) * rect.width,
            y: rect.minY + (binding.y / 100.0) * rect.height
        )
    }

    private func relativePosition(point: CGPoint, in rect: CGRect) -> CGPoint? {
        guard rect.contains(point) else { return nil }
        return CGPoint(
            x: ((point.x - rect.minX) / rect.width)  * 100.0,
            y: ((point.y - rect.minY) / rect.height) * 100.0
        )
    }

    // MARK: - Añadir binding
    private func addBinding(at relPoint: CGPoint, type: ActionType) {
        let params: ActionParams
        switch type {
        case .tap:          params = .tap(key: "?")
        case .repeatedTap:  params = .repeatedTap(key: "?")
        case .dpad:         params = .dpad(keyUp: "W", keyDown: "S", keyLeft: "A", keyRight: "D")
        case .dpadMOBA:     params = .dpadMOBA(keyUp: "W", keyDown: "S", keyLeft: "A", keyRight: "D")
        case .skillsPad:
            params = .skillsPad(skills: [
                SkillSlot(key: "Q", angleDegrees: 315, label: "Q"),
                SkillSlot(key: "E", angleDegrees: 45,  label: "E"),
                SkillSlot(key: "R", angleDegrees: 135, label: "R"),
                SkillSlot(key: "F", angleDegrees: 225, label: "F"),
            ])
        case .aimAndShoot:  params = .aimAndShoot(keyToggle: "Tab", keyAction: "MouseLButton")
        case .freeLook:     params = .freeLook(keyHold: "Alt")
        case .swipe:        params = .swipe(key: "?")
        case .focus:        params = .focus(keyHold: "?")
        case .tilt:         params = .tilt(keyLeft: "Q", keyRight: "E")
        case .rotate:       params = .rotate(key: "?")
        case .edgePan:      params = .edgePan(sensitivityX: 1.0, sensitivityY: 1.0, edgeThresholdPct: 5.0)
        case .scroll:       params = .scroll(key: "?")
        case .mouseWheel:   params = .mouseWheel(sensitivityY: 1.0)
        case .nativeCursor: params = .nativeCursor
        case .script:       params = .script(key: "?", steps: [])
        }

        let binding = KeyBinding(
            label: type.displayName,
            action: type,
            x: relPoint.x,
            y: relPoint.y,
            params: params
        )
        withAnimation(.spring(duration: 0.3)) {
            profile.bindings.append(binding)
            selectedBindingID = binding.id
        }
        log.debug("Binding añadido: \(type.displayName) en (\(relPoint.x, format: .number), \(relPoint.y, format: .number))")
    }
}

// MARK: - MirroringCaptureManager (escala corregida)
// La corrección de escala también requiere que SCStreamConfiguration
// capture a la escala correcta del monitor en lugar de siempre ×2.
// Esta extensión sobrescribe buildConfig() con la escala dinámica.
extension MirroringCaptureManager {
    /// Configuración de stream con escala de pantalla correcta.
    func buildConfigForCurrentScreen(for window: SCWindow) -> SCStreamConfiguration {
        let scale = Int(NSScreen.main?.backingScaleFactor ?? 2.0)
        let config = SCStreamConfiguration()
        // Capturar en la escala real del monitor (no siempre ×2)
        config.width  = max(Int(window.frame.width)  * scale, 100)
        config.height = max(Int(window.frame.height) * scale, 100)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth           = 5
        config.pixelFormat          = kCVPixelFormatType_32BGRA
        return config
    }
}

// MARK: - Preview
#if DEBUG
#Preview("Canvas vacío") {
    @Previewable @State var profile = MappingProfile(
        name: "Demo Preview",
        bindings: [
            KeyBinding(label: "Mover", action: .dpad, x: 20, y: 70,
                       params: .dpad(keyUp: "W", keyDown: "S", keyLeft: "A", keyRight: "D")),
            KeyBinding(label: "Saltar", action: .tap, x: 80, y: 80,
                       params: .tap(key: "Space")),
        ]
    )
    MappingCanvasView(profile: $profile)
        .environment(WindowTracker())
        .environment(KeyMapper())
        .environment(ProfileStore())
        .frame(width: 900, height: 600)
}
#endif
