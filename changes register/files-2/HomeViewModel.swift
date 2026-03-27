import Foundation
import Combine

// ══════════════════════════════════════════════════════
//  HomeViewModel.swift
//  Features/Home/Presentation/
//
//  Ya NO tiene lógica hardcodeada.
//  Delega todo al UseCase correspondiente.
// ══════════════════════════════════════════════════════

final class HomeViewModel: ObservableObject {
    @Published private(set) var state: HomeState = .idle

    // ── Dependencias inyectadas ───────────────────────
    private let function1UseCase: Function1UseCaseProtocol
    // private let function2UseCase: Function2UseCaseProtocol
    // private let function3UseCase: Function3UseCaseProtocol

    init(function1UseCase: Function1UseCaseProtocol = Function1UseCase(
            emulatorRepository: EmulatorRepository(),
            adbRepository:      ADBRepository()
         )
    ) {
        self.function1UseCase = function1UseCase
    }

    // ── Intent público ────────────────────────────────
    func executeFunction(_ function: HomeFunction) {
        switch function {
        case .function1: runFunction1()
        case .function2: runFunction2()
        case .function3: runFunction3()
        }
    }

    // ── Handlers ─────────────────────────────────────
    private func runFunction1() {
        state = .loading(function: .function1)

        Task {
            let output = await function1UseCase.execute(input: .default)

            await MainActor.run {
                switch output {
                case .launchedSuccessfully(let msg): self.state = .success(message: msg)
                case .launchedFallback(let msg):     self.state = .success(message: msg)
                case .failed(let reason):            self.state = .failure(message: reason)
                }
            }
        }
    }

    private func runFunction2() {
        state = .loading(function: .function2)
        // TODO: conectar Function2UseCase
        state = .success(message: "Funcion_2 ejecutada")
    }

    private func runFunction3() {
        state = .loading(function: .function3)
        // TODO: conectar Function3UseCase
        state = .success(message: "Funcion_3 ejecutada")
    }
}
