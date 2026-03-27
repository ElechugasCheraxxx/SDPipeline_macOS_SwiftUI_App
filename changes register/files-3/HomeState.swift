import Foundation

// ══════════════════════════════════════════════════════
//  HomeState.swift
//  Features/Home/Presentation/
// ══════════════════════════════════════════════════════

enum HomeFunction {
    case function1
    case function2
    case function3
}

enum HomeState {
    case idle
    case loading(function: HomeFunction)
    case success(message: String)
    case failure(message: String)

    // Convierte el estado en una entrada de log
    func toLogEntry() -> StatusLogEntry {
        switch self {
        case .idle:
            return StatusLogEntry(text: "En espera", type: .info)
        case .loading(let fn):
            switch fn {
            case .function1: return StatusLogEntry(text: "Ejecutando Funcion_1...", type: .loading)
            case .function2: return StatusLogEntry(text: "Ejecutando Funcion_2...", type: .loading)
            case .function3: return StatusLogEntry(text: "Ejecutando Funcion_3...", type: .loading)
            }
        case .success(let msg):
            return StatusLogEntry(text: msg, type: .success)
        case .failure(let msg):
            return StatusLogEntry(text: msg, type: .failure)
        }
    }
}
