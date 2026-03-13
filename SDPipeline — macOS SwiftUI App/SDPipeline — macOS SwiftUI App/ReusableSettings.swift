import Foundation
import SwiftUI

// MARK: - ReusableSettings
// Snapshot of pipeline settings that can be saved from any generated asset
// and later re-applied to the ContentView (via RightPanelView "Reuse Settings" button).

struct ReusableSettings: Codable, Identifiable {

    var id:             UUID    = UUID()
    var savedAt:        Date    = Date()
    var label:          String  = ""      // Optional user-assigned name

    // Prompt
    var promptPositive: String  = ""
    var promptNegative: String  = ""

    // Core params
    var seed:           Int     = -1
    var steps:          Int     = 28
    var cfgScale:       Double  = 7.0
    var samplerName:    String  = "DPM++ 2M Karras"
    var width:          Int     = 512
    var height:         Int     = 768

    // Model
    var checkpoint:     String  = ""
    var vaeUsed:        String  = ""
    var loraWeights:    [String: Double] = [:]

    // Hires
    var enableHR:           Bool   = false
    var hrUpscaler:         String = "4x-UltraSharp"
    var hrScale:            Double = 2.0
    var hrSteps:            Int    = 15
    var denoisingStrength:  Double = 0.45
    var restoreFaces:       Bool   = false

    // Display helpers
    var summaryLabel: String {
        "\(width)×\(height) · \(steps)s · CFG\(String(format:"%.1f", cfgScale))"
    }

    var seedDisplay: String {
        seed == -1 ? "Random" : "\(seed)"
    }

    var modelDisplay: String {
        checkpoint.isEmpty ? "Unknown model" : checkpoint
    }
}

// MARK: - ReusableSettings persistence

extension ReusableSettings {

    private static let storageKey = "sdpipeline.reusableSettings.v2"

    static func loadAll() -> [ReusableSettings] {
        UserDefaults.standard.decode([ReusableSettings].self, forKey: storageKey) ?? []
    }

    static func save(_ settings: ReusableSettings) {
        var all = loadAll()
        all.removeAll { $0.id == settings.id }
        all.insert(settings, at: 0)
        let capped = Array(all.prefix(50))   // Keep last 50
        UserDefaults.standard.encode(capped, forKey: storageKey)
    }

    static func delete(id: UUID) {
        var all = loadAll()
        all.removeAll { $0.id == id }
        UserDefaults.standard.encode(all, forKey: storageKey)
    }

    static func deleteAll() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}

// MARK: - View: ReusableSettingsRow

struct ReusableSettingsRow: View {
    let settings: ReusableSettings
    let onApply:  (ReusableSettings) -> Void
    let onDelete: (UUID) -> Void

    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if !settings.label.isEmpty {
                        Text(settings.label)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    Text(settings.summaryLabel)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Text(settings.promptPositive.truncated(60))
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text("Seed: \(settings.seedDisplay)")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    if !settings.checkpoint.isEmpty {
                        Text(settings.modelDisplay.truncated(24))
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Text(settings.savedAt.relativeLabel)
                        .font(.system(size: 9))
                        .foregroundColor(Color.secondary.opacity(0.6))
                }
            }
            Spacer()
            if hovered {
                Button(action: { onApply(settings) }) {
                    Text("Apply")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color(hex: "#7c6af7"))
                        .cornerRadius(5)
                }
                .buttonStyle(.plain)

                Button(action: { onDelete(settings.id) }) {
                    Image(systemName: "trash").font(.system(size: 10)).foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(Color.white.opacity(hovered ? 0.05 : 0.02))
        .cornerRadius(7)
        .onHover { hovered = $0 }
    }
}
