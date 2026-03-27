import Foundation

// ══════════════════════════════════════════════════════
//  Function1Models.swift
//  Domain/UseCases/Function1/
//
//  Input y Output del caso de uso. Cero dependencias externas.
// ══════════════════════════════════════════════════════

struct Function1Input {
    let bluestacksPath: String
    let adbPath:        String
    let adbHost:        String
    let adbPort:        Int
    let packageName:    String
    let activityName:   String
    let launchWaitSeconds: UInt64
    let adbWaitSeconds:    UInt64

    // Valores por defecto — se pueden sobrescribir desde config
    static let `default` = Function1Input(
        bluestacksPath:    "/Applications/BlueStacks.app",
        adbPath:           "/opt/homebrew/bin/adb",
        adbHost:           "127.0.0.1",
        adbPort:           5555,
        packageName:       "com.dts.freefireth",
        activityName:      "com.dts.freefireth.FFMainActivity",
        launchWaitSeconds: 20,
        adbWaitSeconds:    10
    )
}

enum Function1Output {
    case launchedSuccessfully(message: String)
    case launchedFallback(message: String)
    case failed(reason: String)
}
