import Foundation
import AppKit

// ══════════════════════════════════════════════════════
//  EmulatorRepository.swift
//  Data/Repositories/
//
//  Implementación concreta. Usa NSWorkspace (macOS).
// ══════════════════════════════════════════════════════

final class EmulatorRepository: EmulatorRepositoryProtocol {
    func open(appPath: String) async -> Bool {
        let url = URL(fileURLWithPath: appPath)
        return NSWorkspace.shared.open(url)
    }
}

// ══════════════════════════════════════════════════════
//  ADBRepository.swift
//  Data/Repositories/
//
//  Implementación concreta. Ejecuta procesos ADB reales.
// ══════════════════════════════════════════════════════

final class ADBRepository: ADBRepositoryProtocol {

    func isAvailable(adbPath: String) async -> Bool {
        FileManager.default.fileExists(atPath: adbPath)
    }

    func restartServer(adbPath: String) async {
        _ = try? await run(adbPath, ["kill-server"],  timeout: 10)
        _ = try? await run(adbPath, ["start-server"], timeout: 10)
    }

    func connect(adbPath: String, endpoint: String) async {
        _ = try? await run(adbPath, ["connect", endpoint], timeout: 10)
    }

    func listDevices(adbPath: String) async -> String {
        (try? await run(adbPath, ["devices"], timeout: 10)) ?? ""
    }

    func launchActivity(adbPath: String, target: String) async -> String {
        let args = ["shell", "am", "start", "-n", target]
        return (try? await run(adbPath, args, timeout: 30)) ?? ""
    }

    func launchWithMonkey(adbPath: String, packageName: String) async {
        let args = [
            "shell", "monkey",
            "-p", packageName,
            "-c", "android.intent.category.LAUNCHER", "1"
        ]
        _ = try? await run(adbPath, args, timeout: 30)
    }

    // ── Utilidad privada ──────────────────────────────
    private func run(
        _ launchPath: String,
        _ arguments: [String],
        timeout: TimeInterval
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let pipe    = Pipe()

            process.executableURL = URL(fileURLWithPath: launchPath)
            process.arguments     = arguments
            process.standardOutput = pipe
            process.standardError  = pipe

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { process.terminate() }
            }

            process.terminationHandler = { _ in
                let data   = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: output)
            }
        }
    }
}
