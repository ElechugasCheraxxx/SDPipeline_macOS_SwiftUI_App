import Foundation
import AppKit
import SwiftUI
import Combine

// MARK: - MpsOptimizer
//
// Optimizaciones específicas para Apple Silicon (M1/M2/M3/M4) en Stable Diffusion.
// Apple Silicon usa memoria unificada (UMA) — la GPU (MPS) comparte RAM con la CPU.
//
// Objetivos:
//   1. Generar el set óptimo de flags para WEBUI_FLAGS en webui.sh
//   2. Detectar el chip exacto y recomendar settings (steps, size, batch)
//   3. Gestionar umbrales de memoria para evitar swapping
//   4. Generar scripts de lanzamiento optimizados
//   5. Recomendar modelos según VRAM disponible
//
// ROADMAP: "Optimización Apple Silicon (flags MPS)" (🟠 CORTO PLAZO)

@MainActor
final class MpsOptimizer: ObservableObject {

    static let shared = MpsOptimizer()
    private init() { detectChip() }

    // MARK: - Apple Silicon Models

    enum AppleChip: String, CaseIterable {
        case m1        = "M1"
        case m1Pro     = "M1 Pro"
        case m1Max     = "M1 Max"
        case m1Ultra   = "M1 Ultra"
        case m2        = "M2"
        case m2Pro     = "M2 Pro"
        case m2Max     = "M2 Max"
        case m2Ultra   = "M2 Ultra"
        case m3        = "M3"
        case m3Pro     = "M3 Pro"
        case m3Max     = "M3 Max"
        case m4        = "M4"
        case m4Pro     = "M4 Pro"
        case m4Max     = "M4 Max"
        case unknown   = "Apple Silicon (unknown)"
        case intel     = "Intel"

        // GPU cores aproximados
        var gpuCores: Int {
            switch self {
            case .m1, .m2, .m3, .m4:           return 8
            case .m1Pro, .m2Pro, .m3Pro, .m4Pro: return 19
            case .m1Max, .m2Max, .m3Max, .m4Max: return 32
            case .m1Ultra, .m2Ultra:             return 64
            default:                             return 0
            }
        }

        // Memoria unificada recomendada (baseline para SD SDXL)
        var recommendedMinRAMGB: Int {
            switch self {
            case .m1, .m2, .m3, .m4:             return 16
            case .m1Pro, .m2Pro, .m3Pro, .m4Pro:  return 18
            case .m1Max, .m2Max, .m3Max, .m4Max,
                 .m1Ultra, .m2Ultra:              return 32
            default: return 8
            }
        }

        var isAppleSilicon: Bool { self != .intel && self != .unknown }
    }

    // MARK: - Optimization Profile

    struct OptimizationProfile {
        let chip:          AppleChip
        let totalRAMGB:    Int
        let usableVRAMGB:  Int    // ~70% de RAM total para MPS

        // Flags para webui.sh
        let webuiFlags:   [String]
        let envVars:      [String: String]

        // Settings recomendados
        let maxResolution: Int       // px por lado
        let maxBatchSize:  Int
        let recommendedSteps: Int
        let safeTileSizeSD15:   Int  // Para tiled upscale
        let safeTileSizeSDXL:   Int

        // Timeouts
        let generationTimeoutSec: Int

        // Script de lanzamiento
        var launchScript: String {
            var lines = ["#!/bin/bash", "# SDPipelineStudio — Launch script optimizado para \(chip.rawValue)", ""]

            for (key, value) in envVars.sorted(by: { $0.key < $1.key }) {
                lines.append("export \(key)=\"\(value)\"")
            }

            lines.append("")
            lines.append("# Flags de optimización MPS")
            let flagsStr = webuiFlags.joined(separator: " \\\n    ")
            lines.append("WEBUI_FLAGS=\"\(flagsStr)\" bash webui.sh \"$@\"")

            return lines.joined(separator: "\n")
        }
    }

    // MARK: - Published State

    @Published private(set) var detectedChip: AppleChip = .unknown
    @Published private(set) var totalRAMGB:   Int = 8
    @Published private(set) var profile:      OptimizationProfile?
    @Published var showAppleSiliconTips       = false

    // MARK: - Chip Detection

    func detectChip() {
        // Leer hardware via sysctl
        detectedChip = readAppleChip()
        totalRAMGB   = readTotalRAMGB()
        profile      = buildProfile(chip: detectedChip, ramGB: totalRAMGB)
    }

    private func readAppleChip() -> AppleChip {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        let cpuString = String(cString: buffer)

        if cpuString.contains("Intel") { return .intel }

        // Apple Silicon — leer chip exacto
        var modelSize = 0
        sysctlbyname("hw.model", nil, &modelSize, nil, 0)
        var modelBuf = [CChar](repeating: 0, count: modelSize)
        sysctlbyname("hw.model", &modelBuf, &modelSize, nil, 0)
        let model = String(cString: modelBuf)

        // Mapping basado en identificadores de hardware comunes
        // Los MacBook/Mac con chips específicos se identifican por el hw.model
        switch true {
        case model.contains("MacBookPro18"):  return .m1Pro   // 2021 MBP
        case model.contains("MacBookPro19"):  return .m2Pro
        case model.contains("Mac14"):         return .m2
        case model.contains("Mac15"):         return .m3
        case model.contains("Mac16"):         return .m4
        case model.contains("MacPro8"):       return .m2Ultra
        default: break
        }

        // Fallback: detectar por número de GPU cores reportados
        var gpuCores: Int32 = 0
        var gpuSize = MemoryLayout<Int32>.size
        sysctlbyname("hw.perflevel0.physicalcpu", &gpuCores, &gpuSize, nil, 0)

        // Heurística por RAM y generación (si no se puede identificar exactamente)
        let ram = readTotalRAMGB()
        if ram >= 64  { return .m1Ultra }
        if ram >= 32  { return .m1Max   }
        if ram >= 18  { return .m1Pro   }
        return .m1
    }

    private func readTotalRAMGB() -> Int {
        var physMem: Int64 = 0
        var size = MemoryLayout<Int64>.size
        sysctlbyname("hw.memsize", &physMem, &size, nil, 0)
        return Int(physMem / (1024 * 1024 * 1024))
    }

    // MARK: - Profile Builder

    private func buildProfile(chip: AppleChip, ramGB: Int) -> OptimizationProfile {
        let usable      = Int(Double(ramGB) * 0.65)  // 65% para MPS (Apple reserva ~15% para sistema)
        var flags       = baseFlags(chip: chip, ramGB: ramGB)
        let envVars     = baseMPSEnvironment(chip: chip)

        // Ajustes según RAM disponible
        let maxRes: Int
        let maxBatch: Int
        let steps: Int

        switch usable {
        case 0..<6:
            maxRes   = 512
            maxBatch = 1
            steps    = 20
            flags.append("--lowvram")
            flags.append("--no-half-vae")
        case 6..<10:
            maxRes   = 768
            maxBatch = 1
            steps    = 25
            flags.append("--medvram")
        case 10..<16:
            maxRes   = 1024
            maxBatch = 2
            steps    = 28
        case 16..<24:
            maxRes   = 1024
            maxBatch = 4
            steps    = 30
            flags.append("--opt-sdp-attention")
        default:
            maxRes   = 1536
            maxBatch = 8
            steps    = 30
            flags.append("--opt-sdp-attention")
            flags.append("--opt-channelslast")
        }

        return OptimizationProfile(
            chip:                 chip,
            totalRAMGB:           ramGB,
            usableVRAMGB:         usable,
            webuiFlags:           flags,
            envVars:              envVars,
            maxResolution:        maxRes,
            maxBatchSize:         maxBatch,
            recommendedSteps:     steps,
            safeTileSizeSD15:     min(512, maxRes),
            safeTileSizeSDXL:     min(1024, maxRes),
            generationTimeoutSec: max(120, 512 * 512 / max(1, usable) * 2)
        )
    }

    private func baseFlags(chip: AppleChip, ramGB: Int) -> [String] {
        var flags = [
            "--skip-torch-cuda-test",
            "--no-half",           // MPS no soporta half precision natively en SD 1.5
            "--use-cpu interrogate",  // CLIP interrogate es más estable en CPU
        ]

        if chip.isAppleSilicon {
            flags.append("--upcast-sampling")  // Evita artefactos en MPS
        }

        if ramGB >= 32 {
            flags.append("--always-batch-cond-uncond")  // Más rápido con RAM abundante
        }

        return flags
    }

    private func baseMPSEnvironment(chip: AppleChip) -> [String: String] {
        var env: [String: String] = [
            "PYTORCH_ENABLE_MPS_FALLBACK": "1",
            "PYTORCH_MPS_HIGH_WATERMARK_RATIO": "0.0",   // Sin límite rígido de VRAM
        ]

        if chip.isAppleSilicon {
            env["COMMANDLINE_ARGS"] = "--skip-torch-cuda-test --no-half --upcast-sampling"
        }

        return env
    }

    // MARK: - Export Launch Script

    func exportLaunchScript(to url: URL) throws {
        guard let p = profile else { throw MpsError.noProfile }
        let script = p.launchScript
        try Data(script.utf8).write(to: url, options: .atomic)

        // Hacer ejecutable
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }

    func saveLaunchScriptToVault() throws {
        guard let vaultRoot = VaultManager.shared.vaultRoot else { return }
        let scriptURL = vaultRoot.appendingPathComponent("Vault/launch_sd_optimized.sh")
        try exportLaunchScript(to: scriptURL)
    }

    // MARK: - Recommendations for GenerationSettings

    func applyRecommendations(to settings: inout GenerationSettings) {
        guard let p = profile else { return }
        if settings.width  > p.maxResolution { settings.width  = p.maxResolution }
        if settings.height > p.maxResolution { settings.height = p.maxResolution }
        if settings.steps  > p.recommendedSteps + 10 { settings.steps = p.recommendedSteps }
    }

    // MARK: - Errors
    enum MpsError: LocalizedError {
        case noProfile
        var errorDescription: String? { "Perfil MPS no generado aún." }
    }
}

// MARK: - MPS Optimizer View

struct MpsOptimizerView: View {
    @ObservedObject private var opt = MpsOptimizer.shared
    @State private var scriptCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Chip info
            HStack(spacing: 12) {
                Image(systemName: "cpu")
                    .font(.system(size: 24))
                    .foregroundColor(Color(hex: "#7c6af7"))
                VStack(alignment: .leading, spacing: 4) {
                    Text(opt.detectedChip.rawValue)
                        .font(.system(size: 14, weight: .semibold))
                    Text("RAM Total: \(opt.totalRAMGB) GB · Usable MPS: \(opt.profile?.usableVRAMGB ?? 0) GB")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Spacer()
                if opt.detectedChip.isAppleSilicon {
                    Text("MPS Activo")
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color(hex: "#34d399").opacity(0.2))
                        .foregroundColor(Color(hex: "#34d399"))
                        .cornerRadius(6)
                }
            }
            .padding(16)
            .background(Color.secondary.opacity(0.05))
            .cornerRadius(10)

            if let p = opt.profile {
                // Recommended settings
                VStack(alignment: .leading, spacing: 8) {
                    Text("SETTINGS RECOMENDADOS")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)

                    HStack(spacing: 16) {
                        SettingBadge(label: "Res. Máx.", value: "\(p.maxResolution)px")
                        SettingBadge(label: "Batch", value: "×\(p.maxBatchSize)")
                        SettingBadge(label: "Steps", value: "\(p.recommendedSteps)")
                        SettingBadge(label: "Tile SD1.5", value: "\(p.safeTileSizeSD15)px")
                    }
                }

                // Flags preview
                VStack(alignment: .leading, spacing: 6) {
                    Text("WEBUI FLAGS")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(p.webuiFlags, id: \.self) { flag in
                                Text(flag)
                                    .font(.system(size: 10, design: .monospaced))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color(hex: "#1e1e2e"))
                                    .foregroundColor(Color(hex: "#cdd6f4"))
                                    .cornerRadius(5)
                            }
                        }
                    }
                }

                // Export button
                HStack {
                    Button(action: {
                        try? opt.saveLaunchScriptToVault()
                        scriptCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { scriptCopied = false }
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: scriptCopied ? "checkmark" : "square.and.arrow.down")
                            Text(scriptCopied ? "Script Guardado!" : "Guardar launch_sd_optimized.sh")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color(hex: "#7c6af7").opacity(0.2))
                        .foregroundColor(Color(hex: "#7c6af7"))
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
    }
}

private struct SettingBadge: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundColor(Color(hex: "#7c6af7"))
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
        .frame(minWidth: 64)
        .padding(.vertical, 8)
        .background(Color(hex: "#7c6af7").opacity(0.08))
        .cornerRadius(8)
    }
}

