import Foundation
import Combine

// ══════════════════════════════════════════════════════
//  HomeViewModel.swift
//  Features/Home/Presentation/
// ══════════════════════════════════════════════════════

final class HomeViewModel: ObservableObject {
    @Published private(set) var state: HomeState       = .idle
    @Published private(set) var log:   [StatusLogEntry] = []

    private let function1UseCase: Function1UseCaseProtocol

    init(function1UseCase: Function1UseCaseProtocol = Function1UseCase(
            emulatorRepository: EmulatorRepository(),
            adbRepository:      ADBRepository()
         )
    ) {
        self.function1UseCase = function1UseCase
    }

    // ── Intent ────────────────────────────────────────
    func executeFunction(_ function: HomeFunction) {
        switch function {
        case .function1: runFunction1()
        case .function2: runFunction2()
        case .function3: runFunction3()
        }
    }

    // ── Helpers ───────────────────────────────────────
    private func setState(_ newState: HomeState) {
        state = newState
        log.append(newState.toLogEntry())
    }

    // ── Handlers ─────────────────────────────────────
    private func runFunction1() {
        setState(.loading(function: .function1))

        Task {
            let output = await function1UseCase.execute(input: .default)

            await MainActor.run {
                switch output {
                case .launchedSuccessfully(let msg): self.setState(.success(message: msg))
                case .launchedFallback(let msg):     self.setState(.success(message: msg))
                case .failed(let reason):            self.setState(.failure(message: reason))
                }
            }
        }
    }

    private func runFunction2() {
        setState(.loading(function: .function2))
        // TODO: conectar Function2UseCase
        setState(.success(message: "Funcion_2 ejecutada"))
    }

    private func runFunction3() {
        setState(.loading(function: .function3))
        // TODO: conectar Function3UseCase
        setState(.success(message: "Funcion_3 ejecutada"))
    }
}
