import Foundation

// ══════════════════════════════════════════════════════
//  Function1UseCase.swift
//  Domain/UseCases/Function1/
// ══════════════════════════════════════════════════════

protocol Function1UseCaseProtocol {
    func execute(input: Function1Input, onProgress: @escaping (String) -> Void) async -> Function1Output
}

final class Function1UseCase: Function1UseCaseProtocol {

    private let emulatorRepository: EmulatorRepositoryProtocol
    private let adbRepository:      ADBRepositoryProtocol

    init(
        emulatorRepository: EmulatorRepositoryProtocol,
        adbRepository:      ADBRepositoryProtocol
    ) {
        self.emulatorRepository = emulatorRepository
        self.adbRepository      = adbRepository
    }

    func execute(input: Function1Input, onProgress: @escaping (String) -> Void) async -> Function1Output {

        // 1. Verificar ADB
        onProgress("Verificando ADB...")
        guard await adbRepository.isAvailable(adbPath: input.adbPath) else {
            return .failed(reason: "ADB no encontrado en \(input.adbPath)")
        }
        onProgress("ADB encontrado ✓")

        // 2. Abrir BlueStacks
        onProgress("Abriendo BlueStacks...")
        _ = await emulatorRepository.open(appPath: input.bluestacksPath)

        // 3. Esperar inicio
        if input.launchWaitSeconds > 0 {
            onProgress("Esperando \(input.launchWaitSeconds)s que BlueStacks inicie...")
            try? await Task.sleep(nanoseconds: input.launchWaitSeconds * 1_000_000_000)
        }

        // 4. Reiniciar ADB — BlueStacks se registra solo como emulator-5554
        onProgress("Reiniciando servidor ADB...")
        await adbRepository.restartServer(adbPath: input.adbPath)

        // 5. Polling: verificar adb devices hasta que aparezca
        //    BlueStacks puede tardar 5-15s en registrarse tras el restart
        onProgress("Esperando conexión de BlueStacks...")
        var devices = ""
        let maxAttempts = 8
        for attempt in 1...maxAttempts {
            try? await Task.sleep(nanoseconds: 3_000_000_000)  // 3s entre intentos
            devices = await adbRepository.listDevices(adbPath: input.adbPath)
            if devices.contains("device") {
                onProgress("BlueStacks detectado ✓ (intento \(attempt)/\(maxAttempts))")
                break
            }
            onProgress("Esperando... (\(attempt)/\(maxAttempts))")
        }

        guard devices.contains("device") else {
            return .failed(reason: "BlueStacks no responde tras \(maxAttempts * 3)s. ¿Está corriendo?")
        }

        // 6. Lanzar Free Fire
        onProgress("Lanzando Free Fire...")
        let launchResult = await adbRepository.launchActivity(
            adbPath: input.adbPath,
            target:  "\(input.packageName)/\(input.activityName)"
        )

        if launchResult.contains("Starting: Intent") {
            return .launchedSuccessfully(message: "Free Fire iniciado ✓")
        }

        return .failed(reason: "Free Fire no respondió: \(launchResult)")
    }
}
