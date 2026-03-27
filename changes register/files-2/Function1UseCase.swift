import Foundation

// ══════════════════════════════════════════════════════
//  Function1UseCase.swift
//  Domain/UseCases/Function1/
//
//  Orquesta la lógica de negocio. No sabe nada de UI.
//  Depende de protocolos, no de implementaciones.
// ══════════════════════════════════════════════════════

protocol Function1UseCaseProtocol {
    func execute(input: Function1Input) async -> Function1Output
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

    func execute(input: Function1Input) async -> Function1Output {

        // 1. Abrir BlueStacks
        let opened = await emulatorRepository.open(appPath: input.bluestacksPath)
        guard opened else {
            return .failed(reason: "No se pudo abrir BlueStacks.app")
        }

        // 2. Esperar a que el emulador inicie
        try? await Task.sleep(nanoseconds: input.launchWaitSeconds * 1_000_000_000)

        // 3. Verificar que ADB existe
        guard await adbRepository.isAvailable(adbPath: input.adbPath) else {
            return .failed(reason: "ADB no encontrado en \(input.adbPath)")
        }

        // 4. Reiniciar servidor ADB
        await adbRepository.restartServer(adbPath: input.adbPath)
        try? await Task.sleep(nanoseconds: input.adbWaitSeconds * 1_000_000_000)

        // 5. Conectar al emulador
        let endpoint = "\(input.adbHost):\(input.adbPort)"
        await adbRepository.connect(adbPath: input.adbPath, endpoint: endpoint)

        // 6. Verificar dispositivos
        let devices = await adbRepository.listDevices(adbPath: input.adbPath)
        if !devices.contains("device") {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await adbRepository.connect(adbPath: input.adbPath, endpoint: endpoint)
        }

        // 7. Lanzar la app
        let target = "\(input.packageName)/\(input.activityName)"
        let launchResult = await adbRepository.launchActivity(
            adbPath: input.adbPath,
            target:  target
        )

        if launchResult.contains("Starting: Intent") {
            return .launchedSuccessfully(message: "Free Fire iniciado correctamente")
        }

        // Fallback con monkey
        await adbRepository.launchWithMonkey(
            adbPath:     input.adbPath,
            packageName: input.packageName
        )
        return .launchedFallback(message: "Free Fire iniciado (fallback monkey)")
    }
}
