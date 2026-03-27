import Foundation
import AppKit
import SwiftUI

// MARK: - NSFWDetector
//
// Detector de contenido NSFW post-generación.
// Dos capas:
//   1. PromptScorer  — análisis inmediato del prompt (sin red, sin latencia)
//   2. ImageScorer   — vía A1111 /sdapi/v1/interrogate con CLIP
//      (asíncrono, solo si está disponible)
//
// Acciones configurables: .flag, .blur, .quarantine, .log
// Persistencia del log en Vault/nsfw_log.jsonl

// MARK: - Models

enum NSFWLevel: Int, Codable, CaseIterable, Comparable {
    case safe     = 0
    case mild     = 1
    case moderate = 2
    case explicit = 3

    static func < (lhs: NSFWLevel, rhs: NSFWLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .safe:     return "Safe"
        case .mild:     return "Mild"
        case .moderate: return "Moderate"
        case .explicit: return "Explicit"
        }
    }

    var color: Color {
        switch self {
        case .safe:     return Color(hex: "#34d399")
        case .mild:     return Color(hex: "#fbbf24")
        case .moderate: return Color(hex: "#f97316")
        case .explicit: return Color(hex: "#ef4444")
        }
    }

    var icon: String {
        switch self {
        case .safe:     return "checkmark.shield.fill"
        case .mild:     return "exclamationmark.shield"
        case .moderate: return "exclamationmark.shield.fill"
        case .explicit: return "xmark.shield.fill"
        }
    }
}

struct NSFWDetectionResult: Identifiable, Codable {
    var id:            UUID        = UUID()
    var timestamp:     Date        = Date()
    var promptLevel:   NSFWLevel
    var imageLevel:    NSFWLevel?  = nil    // nil si no se hizo imagen análisis
    var finalLevel:    NSFWLevel
    var triggerWords:  [String]    = []     // palabras que activaron la detección
    var action:        NSFWAction
    var prompt:        String
    var imagePath:     String?     = nil
}

enum NSFWAction: String, Codable {
    case none        = "Ninguna"
    case flag        = "Flagged"
    case blur        = "Blurred"
    case quarantine  = "Quarantined"
    case blocked     = "Blocked"
}

struct NSFWPolicy: Codable {
    var thresholdForFlag:       NSFWLevel = .moderate
    var thresholdForQuarantine: NSFWLevel = .explicit
    var enableImageAnalysis:    Bool      = true      // llama a CLIP vía A1111
    var logAll:                 Bool      = true
    var autoBlurPreview:        Bool      = true
}

// MARK: - NSFWDetector

@MainActor
final class NSFWDetector: ObservableObject {

    static let shared = NSFWDetector()
    private init() { loadLog() }

    // MARK: - State

    @Published var lastResult:  NSFWDetectionResult?   = nil
    @Published var isAnalyzing: Bool                   = false
    @Published var log:         [NSFWDetectionResult]  = []
    @Published var policy:      NSFWPolicy             = NSFWPolicy()

    // MARK: - Prompt Analysis (sincrónico, sin red)

    func analyzePrompt(_ prompt: String) -> (level: NSFWLevel, triggers: [String]) {
        let lower = prompt.lowercased()
        var triggers: [String] = []
        var maxLevel = NSFWLevel.safe

        for (keyword, level) in Self.keywordMap {
            if lower.contains(keyword) {
                triggers.append(keyword)
                if level > maxLevel { maxLevel = level }
            }
        }

        return (maxLevel, triggers)
    }

    // MARK: - Full Detection Pipeline

    func detect(
        prompt:    String,
        image:     NSImage?,
        imagePath: String?  = nil,
        baseURL:   String   = ""
    ) async -> NSFWDetectionResult {
        isAnalyzing = true
        defer { isAnalyzing = false }

        // Capa 1: Prompt score
        let (promptLevel, triggers) = analyzePrompt(prompt)

        // Capa 2: Imagen con CLIP (si está habilitado y hay imagen)
        var imageLevel: NSFWLevel? = nil
        if policy.enableImageAnalysis, let img = image, !baseURL.isEmpty {
            imageLevel = await analyzeImageWithCLIP(img, baseURL: baseURL)
        }

        // Nivel final = máximo de ambas capas
        let finalLevel = imageLevel.map { max(promptLevel, $0) } ?? promptLevel

        // Determinar acción
        let action: NSFWAction = {
            if finalLevel >= policy.thresholdForQuarantine { return .quarantine }
            if finalLevel >= policy.thresholdForFlag       { return .flag }
            return .none
        }()

        let result = NSFWDetectionResult(
            promptLevel:  promptLevel,
            imageLevel:   imageLevel,
            finalLevel:   finalLevel,
            triggerWords: triggers,
            action:       action,
            prompt:       String(prompt.prefix(100)),
            imagePath:    imagePath
        )

        lastResult = result

        if policy.logAll || action != .none {
            appendToLog(result)
        }

        return result
    }

    // MARK: - CLIP Analysis via A1111

    private func analyzeImageWithCLIP(_ image: NSImage, baseURL: String) async -> NSFWLevel {
        guard let tiff = image.tiffRepresentation,
              let bmp  = NSBitmapImageRep(data: tiff),
              let png  = bmp.representation(using: .png, properties: [:])
        else { return .safe }

        let b64     = png.base64EncodedString()
        let payload: [String: Any] = ["image": b64, "model": "clip"]

        guard let url  = URL(string: "\(baseURL)/sdapi/v1/interrogate"),
              let body = try? JSONSerialization.data(withJSONObject: payload)
        else { return .safe }

        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody  = body

        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let caption = json["caption"] as? String
        else { return .safe }

        // Analizar la descripción generada por CLIP
        let (level, _) = analyzePrompt(caption)
        return level
    }

    // MARK: - Log

    func clearLog() {
        log.removeAll()
        if let url = logURL { try? FileManager.default.removeItem(at: url) }
    }

    private func appendToLog(_ result: NSFWDetectionResult) {
        log.insert(result, at: 0)
        if log.count > 1000 { log = Array(log.prefix(1000)) }

        guard let url  = logURL,
              let line = (try? JSONEncoder().encode(result)).flatMap({ String(data: $0, encoding: .utf8) })
        else { return }

        let lineWithNewline = line + "\n"
        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(lineWithNewline.data(using: .utf8)!)
                handle.closeFile()
            }
        } else {
            try? lineWithNewline.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func loadLog() {
        guard let url  = logURL,
              let text = try? String(contentsOf: url) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        log = lines.compactMap {
            try? JSONDecoder.iso8601.decode(NSFWDetectionResult.self, from: Data($0.utf8))
        }.reversed()
    }

    private var logURL: URL? {
        VaultManager.shared.vaultMetaURL?.appending(path: "nsfw_log.jsonl")
    }

    // MARK: - Keyword Map

    // Niveles calibrados para contenido de arte adulto profesional
    // safe = tokens de posado artístico neutro
    // mild = contenido sugerente / semi-adulto
    // moderate = contenido adulto explícito
    // explicit = contenido que requiere revisión

    static let keywordMap: [String: NSFWLevel] = {
        var map: [String: NSFWLevel] = [:]
        // Mild
        let mild = ["lingerie", "bikini", "topless", "shirtless", "seductive",
                    "sensual", "provocative", "suggestive", "erotic", "alluring",
                    "revealing", "cleavage", "panties", "bra", "underwear"]
        // Moderate
        let moderate = ["nude", "naked", "nsfw", "explicit", "adult content",
                        "18+", "sexual", "intimate", "bedroom scene", "undressed"]
        // Explicit
        let explicit = ["pornographic", "xxx", "genitals", "intercourse",
                        "uncensored adult", "sexually explicit"]

        for w in mild     { map[w] = .mild }
        for w in moderate { map[w] = .moderate }
        for w in explicit { map[w] = .explicit }
        return map
    }()
}

// MARK: - NSFWStatusBadge (componente reutilizable)

struct NSFWStatusBadge: View {
    let level: NSFWLevel
    var compact: Bool = false

    var body: some View {
        HStack(spacing: compact ? 3 : 5) {
            Image(systemName: level.icon)
                .font(.system(size: compact ? 9 : 11))
            if !compact {
                Text(level.label)
                    .font(.system(size: 10, weight: .semibold))
            }
        }
        .foregroundColor(level.color)
        .padding(.horizontal, compact ? 5 : 8)
        .padding(.vertical, compact ? 2 : 4)
        .background(level.color.opacity(0.12))
        .cornerRadius(compact ? 4 : 6)
    }
}

// MARK: - NSFWLogView

struct NSFWLogView: View {

    @ObservedObject var detector = NSFWDetector.shared
    @State private var filterLevel: NSFWLevel? = nil

    var filtered: [NSFWDetectionResult] {
        guard let f = filterLevel else { return detector.log }
        return detector.log.filter { $0.finalLevel >= f }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Log NSFW").font(.system(size: 13, weight: .bold)).foregroundColor(.white)
                Spacer()
                Button(action: { detector.clearLog() }) {
                    Image(systemName: "trash").font(.system(size: 11)).foregroundColor(.secondary)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color.white.opacity(0.03))

            // Filtro por nivel
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    filterPill(nil, "Todos")
                    ForEach(NSFWLevel.allCases, id: \.self) { l in
                        filterPill(l, l.label)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
            }
            .background(Color.white.opacity(0.02))

            Divider().background(Color.white.opacity(0.06))

            if filtered.isEmpty {
                Text("Sin entradas en el log").font(.system(size: 12)).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity).padding(30)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered.prefix(100)) { entry in
                            logRow(entry)
                            Divider().background(Color.white.opacity(0.04))
                        }
                    }
                }
            }
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(Color.white.opacity(0.07), lineWidth: 1))
    }

    func logRow(_ entry: NSFWDetectionResult) -> some View {
        HStack(spacing: 10) {
            NSFWStatusBadge(level: entry.finalLevel, compact: true)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.prompt.truncated(50))
                    .font(.system(size: 11)).foregroundColor(.white.opacity(0.8)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(entry.timestamp, style: .relative)
                        .font(.system(size: 9)).foregroundColor(.secondary)
                    if !entry.triggerWords.isEmpty {
                        Text(entry.triggerWords.prefix(3).joined(separator: ", "))
                            .font(.system(size: 9)).foregroundColor(.secondary.opacity(0.6))
                    }
                }
            }

            Spacer()

            if entry.action != .none {
                Text(entry.action.rawValue)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(entry.action == .quarantine ? .red : .orange)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background((entry.action == .quarantine ? Color.red : Color.orange).opacity(0.12))
                    .cornerRadius(4)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
    }

    func filterPill(_ level: NSFWLevel?, _ label: String) -> some View {
        let isSelected = filterLevel == level
        return Button(action: { filterLevel = level }) {
            Text(label).font(.system(size: 10, weight: .medium))
                .foregroundColor(isSelected ? .white : .secondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(isSelected ? Color.white.opacity(0.15) : Color.white.opacity(0.04))
                .cornerRadius(5)
        }.buttonStyle(.plain)
    }
}
