import Foundation
import Combine

// ══════════════════════════════════════════════════════
//  HomeViewModel.swift — Features · Home · Presentation
//  Consume UseCases del Domain. La View no tiene lógica.
// ══════════════════════════════════════════════════════

final class HomeViewModel: ObservableObject {
    @Published private(set) var state: HomeState = .idle

    // ── Dependencias (inyectadas desde DI) ────────────
    // private let function1UseCase: Function1UseCaseProtocol
    // private let function2UseCase: Function2UseCaseProtocol
    // private let function3UseCase: Function3UseCaseProtocol

    private var cancellables = Set<AnyCancellable>()

    init() {
        // Cuando UseCases estén implementados:
        // self.function1UseCase = function1UseCase
    }

    // ── Intent público ────────────────────────────────
    func executeFunction(_ function: HomeFunction) {
        switch function {
        case .function1: runFunction1()
        case .function2: runFunction2()
        case .function3: runFunction3()
        }
    }

    // ── Handlers privados ─────────────────────────────
    //  Aquí conectarás cada UseCase cuando esté listo.
    //  Por ahora actualizan el estado directamente.

    private func runFunction1() {
        state = .loading(function: .function1)
        // TODO: function1UseCase.execute()
        //   .receive(on: DispatchQueue.main)
        //   .sink(receiveCompletion: { ... }, receiveValue: { ... })
        //   .store(in: &cancellables)
        state = .success(message: "Funcion_1 ejecutada")
    }

    private func runFunction2() {
        state = .loading(function: .function2)
        // TODO: function2UseCase.execute()
        state = .success(message: "Funcion_2 ejecutada")
    }

    private func runFunction3() {
        state = .loading(function: .function3)
        // TODO: function3UseCase.execute()
        state = .success(message: "Funcion_3 ejecutada")
    }
}
