import Foundation

// ══════════════════════════════════════════════════════
//  EmulatorRepositoryProtocol.swift
//  Domain/RepositoryContracts/
// ══════════════════════════════════════════════════════

protocol EmulatorRepositoryProtocol {
    /// Abre una app por su path. Retorna true si tuvo éxito.
    func open(appPath: String) async -> Bool
}

// ══════════════════════════════════════════════════════
//  ADBRepositoryProtocol.swift
//  Domain/RepositoryContracts/
// ══════════════════════════════════════════════════════

protocol ADBRepositoryProtocol {
    func isAvailable(adbPath: String) async -> Bool
    func restartServer(adbPath: String) async
    func connect(adbPath: String, endpoint: String) async
    func listDevices(adbPath: String) async -> String
    func launchActivity(adbPath: String, target: String) async -> String
    func launchWithMonkey(adbPath: String, packageName: String) async
}
