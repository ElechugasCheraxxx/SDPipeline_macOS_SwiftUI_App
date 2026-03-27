import Foundation

// ══════════════════════════════════════════════════════
//  HomeState.swift — Features · Home · Presentation
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

    var statusText: String {
        switch self {
        case .idle:
            return "xxxxxxxxxxx"
        case .loading(let function):
            switch function {
            case .function1: return "Ejecutando Funcion_1..."
            case .function2: return "Ejecutando Funcion_2..."
            case .function3: return "Ejecutando Funcion_3..."
            }
        case .success(let message):
            return message
        case .failure(let message):
            return "Error: \(message)"
        }
    }
}
