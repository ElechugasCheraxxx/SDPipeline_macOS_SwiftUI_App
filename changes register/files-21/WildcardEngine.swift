import Foundation
import SwiftUI
import Combine

// MARK: - WildcardEngine
//
// Resuelve wildcards dinámicos en prompts antes de enviarlos a SD.
// Formato: __nombre_wildcard__ → reemplazado por un término aleatorio del grupo.
//
// Grupos built-in: lighting, mood, camera, style, color_palette, weather,
//                  time_of_day, texture, outfit, location_interior, location_exterior
//
// Grupos custom: cargados desde Vault/wildcards/{nombre}.txt
// Cada archivo .txt contiene un término por línea.
//
// Uso:
//   let resolved = WildcardEngine.shared.resolve("a woman in __outfit__, __lighting__")
//   // → "a woman in silk evening dress, golden hour backlight"
//
// ROADMAP: "Wildcards dinámicos para entornos/vestuario" (Sección 🟡 Medio Plazo)

@MainActor
final class WildcardEngine: ObservableObject {

    static let shared = WildcardEngine()
    private init() {
        loadCustomWildcards()
    }

    // MARK: - Published State

    @Published var customGroups: [String: [String]] = [:]
    @Published var resolvedHistory: [(original: String, resolved: String)] = []

    // MARK: - Built-in Wildcards

    private let builtins: [String: [String]] = [

        "lighting": [
            "soft golden hour backlight", "hard chiaroscuro lighting",
            "rembrandt lighting", "cinematic rim light", "neon glow accent",
            "soft diffused studio light", "candlelight", "moonlight",
            "high-key studio lighting", "low-key dramatic shadows",
            "warm sunflare", "cool blue backlight", "dappled forest light",
        ],
        "mood": [
            "ethereal and dreamy", "intense and dramatic", "serene and peaceful",
            "mysterious and dark", "playful and vibrant", "intimate and warm",
            "melancholic and cinematic", "confident and powerful",
            "sensual and sophisticated", "raw and emotional",
        ],
        "camera": [
            "close-up portrait", "medium shot", "full body shot",
            "over-the-shoulder", "low angle", "high angle", "dutch angle",
            "wide establishing shot", "macro detail", "bokeh background",
            "shallow depth of field", "deep focus",
        ],
        "style": [
            "photorealistic", "cinematic film grain", "editorial fashion",
            "fine art photography", "high-fashion editorial", "analog film look",
            "digital art", "oil painting style", "watercolor",
            "hyperrealistic 8k", "documentary style", "noir",
        ],
        "color_palette": [
            "warm golden tones", "cool blue and teal", "moody desaturated",
            "vibrant high saturation", "pastel soft tones", "classic black and white",
            "sepia vintage", "rich jewel tones", "earth tones", "neon cyberpunk",
        ],
        "weather": [
            "clear golden sunlight", "soft overcast clouds", "light rain",
            "dramatic storm clouds", "foggy mist", "light snow",
            "blazing midday sun", "soft dusk glow", "blue hour twilight",
        ],
        "time_of_day": [
            "golden hour", "blue hour", "midnight", "midday harsh sun",
            "soft morning light", "overcast noon", "late afternoon",
            "sunrise", "sunset", "pre-dawn",
        ],
        "texture": [
            "silk fabric", "leather", "lace detail", "velvet",
            "wet skin", "dewy skin", "matte skin", "glossy finish",
            "rough concrete background", "smooth marble", "wood grain",
        ],
        "outfit": [
            "elegant evening gown", "business suit", "casual summer dress",
            "lingerie set", "swimwear", "athleisure wear", "vintage dress",
            "haute couture", "minimalist outfit", "statement piece",
            "leather jacket", "flowing bohemian dress",
        ],
        "location_interior": [
            "luxury penthouse apartment", "cozy bedroom", "modern minimalist studio",
            "hotel suite", "art gallery", "baroque mansion", "industrial loft",
            "spa and wellness center", "rooftop terrace", "kitchen",
        ],
        "location_exterior": [
            "tropical beach at sunset", "urban city street", "forest clearing",
            "mountain vista", "desert dunes", "rooftop cityscape",
            "cobblestone european street", "lavender field", "rocky coastline",
            "modern architecture exterior",
        ],
        "composition": [
            "rule of thirds", "centered symmetry", "leading lines",
            "negative space", "framing within frame", "diagonal tension",
        ],
    ]

    // MARK: - Regex pattern for __wildcard__

    private static let wildcardPattern = try! NSRegularExpression(
        pattern: #"__([a-zA-Z0-9_]+)__"#,
        options: []
    )

    // MARK: - Public API

    /// Resolve all __wildcards__ in a prompt string.
    /// Each wildcard is replaced with a random term from its group.
    /// Unresolved wildcards are left as-is.
    func resolve(_ prompt: String) -> String {
        var result = prompt
        let range  = NSRange(result.startIndex..., in: result)
        let matches = Self.wildcardPattern.matches(in: result, range: range)

        // Process in reverse order to preserve string indices
        for match in matches.reversed() {
            guard let keyRange  = Range(match.range(at: 1), in: result),
                  let fullRange = Range(match.range(at: 0), in: result)
            else { continue }

            let key = String(result[keyRange]).lowercased()

            if let replacement = randomTerm(for: key) {
                result.replaceSubrange(fullRange, with: replacement)
            }
            // If no group found, leave __wildcard__ intact (user will see it)
        }

        // Track history (cap at 50)
        if result != prompt {
            resolvedHistory.insert((original: prompt, resolved: result), at: 0)
            if resolvedHistory.count > 50 {
                resolvedHistory = Array(resolvedHistory.prefix(50))
            }
        }

        return result
    }

    /// Preview what a wildcard group contains.
    func terms(for key: String) -> [String] {
        customGroups[key.lowercased()] ?? builtins[key.lowercased()] ?? []
    }

    /// All available wildcard keys (builtin + custom).
    var allKeys: [String] {
        let all = Set(builtins.keys).union(customGroups.keys)
        return all.sorted()
    }

    /// Add or update a custom wildcard group.
    func setCustomGroup(key: String, terms: [String]) {
        let normalKey = key.lowercased().replacingOccurrences(of: " ", with: "_")
        customGroups[normalKey] = terms
        saveCustomWildcards()
    }

    /// Remove a custom wildcard group.
    func removeCustomGroup(key: String) {
        customGroups.removeValue(forKey: key.lowercased())
        saveCustomWildcards()
    }

    // MARK: - Private

    private func randomTerm(for key: String) -> String? {
        let lower = key.lowercased()
        let list = customGroups[lower] ?? builtins[lower]
        guard let list = list, !list.isEmpty else { return nil }
        return list.randomElement()
    }

    // MARK: - Persistence (custom wildcards in Vault)

    private var customWildcardsURL: URL? {
        VaultManager.shared.vaultMetaURL?.appending(path: "wildcards.json")
    }

    private func loadCustomWildcards() {
        guard let url  = customWildcardsURL,
              let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: [String]].self, from: data)
        else { return }
        customGroups = dict
    }

    private func saveCustomWildcards() {
        guard let url  = customWildcardsURL,
              let data = try? JSONEncoder.pretty.encode(customGroups)
        else { return }
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - WildcardEditorView

struct WildcardEditorView: View {

    @StateObject private var engine = WildcardEngine.shared
    @State private var selectedKey: String? = nil
    @State private var newKey:   String = ""
    @State private var newTerms: String = ""
    @State private var showAddSheet = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "shuffle")
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "#7c6af7"))
                Text("Wildcards")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Button(action: { showAddSheet = true }) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 13))
                        .foregroundColor(Color(hex: "#7c6af7"))
                }
                .buttonStyle(.plain)
                .help("Nuevo grupo wildcard")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.white.opacity(0.03))

            Divider().background(Color.white.opacity(0.06))

            HStack(spacing: 0) {
                // Keys list
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(engine.allKeys, id: \.self) { key in
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(engine.customGroups[key] != nil
                                          ? Color(hex: "#7c6af7") : Color.white.opacity(0.2))
                                    .frame(width: 5, height: 5)
                                Text("__\(key)__")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(selectedKey == key ? .white : .secondary)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(engine.terms(for: key).count)")
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(selectedKey == key ? Color.white.opacity(0.07) : Color.clear)
                            .cornerRadius(4)
                            .contentShape(Rectangle())
                            .onTapGesture { selectedKey = key }
                        }
                    }
                    .padding(6)
                }
                .frame(width: 150)
                .background(Color.white.opacity(0.02))

                Divider().background(Color.white.opacity(0.06))

                // Terms for selected key
                if let key = selectedKey {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("__\(key)__")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(Color(hex: "#7c6af7"))
                            Spacer()
                            if engine.customGroups[key] != nil {
                                Button(action: { engine.removeCustomGroup(key: key); selectedKey = nil }) {
                                    Image(systemName: "trash")
                                        .font(.system(size: 10))
                                        .foregroundColor(.red.opacity(0.7))
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(engine.terms(for: key), id: \.self) { term in
                                    Text("• \(term)")
                                        .font(.system(size: 10))
                                        .foregroundColor(.white.opacity(0.75))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }

                        // Live preview
                        Button(action: {}) {
                            HStack(spacing: 4) {
                                Image(systemName: "dice")
                                    .font(.system(size: 10))
                                Text("→ \(engine.terms(for: key).randomElement() ?? "—")")
                                    .font(.system(size: 10, design: .monospaced))
                            }
                            .foregroundColor(Color(hex: "#3de3c0"))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    Text("Selecciona un wildcard")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.07), lineWidth: 1))
        .sheet(isPresented: $showAddSheet) {
            addGroupSheet
        }
    }

    var addGroupSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Nuevo grupo wildcard")
                .font(.system(size: 14, weight: .semibold)).foregroundColor(.white)

            VStack(alignment: .leading, spacing: 4) {
                Text("Nombre (sin espacios)").font(.system(size: 11)).foregroundColor(.secondary)
                TextField("ej: hairstyle", text: $newKey)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Términos (uno por línea)").font(.system(size: 11)).foregroundColor(.secondary)
                TextEditor(text: $newTerms)
                    .font(.system(size: 11))
                    .frame(height: 120)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(6)
            }
            HStack {
                Spacer()
                Button("Cancelar") { showAddSheet = false }
                    .buttonStyle(.plain).foregroundColor(.secondary)
                Button("Guardar") {
                    let terms = newTerms
                        .components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    if !newKey.isEmpty && !terms.isEmpty {
                        engine.setCustomGroup(key: newKey, terms: terms)
                        showAddSheet = false
                        newKey = ""; newTerms = ""
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(Color(hex: "#7c6af7"))
                .disabled(newKey.isEmpty || newTerms.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
        .background(Color(red: 0.1, green: 0.1, blue: 0.13))
    }
}
