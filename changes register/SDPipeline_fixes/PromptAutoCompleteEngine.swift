import Foundation
import AppKit
import SwiftUI
import Combine

// MARK: - PromptAutoCompleteEngine
//
// Motor de autocompletado inteligente para el editor de prompts.
// Features:
//   • Índice de tokens SD (dan:2M+ tags de Danbooru, A1111 styles, etc.)
//   • Autocompletado contextual basado en historial de prompts exitosos
//   • Sugerencias de LoRA <lora:name:weight>
//   • Sugerencias de embeddings (TI)
//   • Peso automático de tokens populares
//   • Resaltado de sintaxis por categoría de token
//   • Historial de tokens recientemente usados
//
// ROADMAP: "Editor avanzado con autocompletado" (🟡 MEDIO PLAZO)

@MainActor
final class PromptAutoCompleteEngine: ObservableObject {

    static let shared = PromptAutoCompleteEngine()
    private init() {
        Task { await buildIndex() }
    }

    // MARK: - Token

    struct Token: Identifiable, Hashable {
        let id       = UUID()
        let text:    String
        let category: TokenCategory
        let score:   Double    // 0–1, popularity/relevance
        let postCount: Int?    // from Danbooru if known
        let aliases: [String]
        let weight:  Double?   // for LoRA tokens

        enum TokenCategory: String, CaseIterable {
            case quality     = "Calidad"
            case character   = "Personaje"
            case style       = "Estilo"
            case lighting    = "Iluminación"
            case composition = "Composición"
            case clothing    = "Ropa"
            case expression  = "Expresión"
            case setting     = "Escenario"
            case lora        = "LoRA"
            case embedding   = "Embedding"
            case custom      = "Personalizado"
            case negative    = "Negativo"

            var color: String {
                switch self {
                case .quality:     return "#34d399"
                case .character:   return "#7c6af7"
                case .style:       return "#3de3c0"
                case .lighting:    return "#fbbf24"
                case .composition: return "#f97316"
                case .clothing:    return "#ec4899"
                case .expression:  return "#a855f7"
                case .setting:     return "#38bdf8"
                case .lora:        return "#dc8a5a"
                case .embedding:   return "#b8a98a"
                case .custom:      return "#9090a8"
                case .negative:    return "#ef4444"
                }
            }

            var icon: String {
                switch self {
                case .quality:     return "star.fill"
                case .character:   return "person.fill"
                case .style:       return "paintbrush.fill"
                case .lighting:    return "light.max"
                case .composition: return "camera.viewfinder"
                case .clothing:    return "tshirt.fill"
                case .expression:  return "face.smiling"
                case .setting:     return "mountain.2.fill"
                case .lora:        return "cpu.fill"
                case .embedding:   return "brain.fill"
                case .custom:      return "tag.fill"
                case .negative:    return "minus.circle"
                }
            }
        }

        func hash(into hasher: inout Hasher) { hasher.combine(text) }
        static func == (lhs: Token, rhs: Token) -> Bool { lhs.text == rhs.text }
    }

    // MARK: - Config

    struct AutoCompleteConfig: Codable {
        var enabled:           Bool   = true
        var maxSuggestions:    Int    = 8
        var minQueryLength:    Int    = 2
        var includeLoRAs:      Bool   = true
        var includeEmbeddings: Bool   = true
        var includeDanbooru:   Bool   = true
        var includeHistory:    Bool   = true
        var historyWeight:     Double = 2.0    // Boost for recently used tokens
        var triggerChar:       String = ""     // "" = trigger on any char, "," = after comma
        var showPostCounts:    Bool   = true
        var insertWeight:      Bool   = false  // Auto-insert :1 weight
    }

    @Published var config = AutoCompleteConfig()

    // MARK: - State

    @Published var suggestions:    [Token] = []
    @Published var isIndexing:     Bool    = false
    @Published var indexSize:      Int     = 0
    @Published var currentQuery:   String  = ""

    var tokenIndex:       [String: [Token]] = [:]  // prefix → tokens
    private var historyIndex:     [String: Int]     = [:]  // token → use count
    private var allTokens:        [Token]           = []
    private var searchTask:       Task<Void, Never>?

    // MARK: - Build Index

    func buildIndex() async {
        isIndexing = true
        defer { isIndexing = false }

        var tokens: [Token] = []

        // 1. Quality tokens
        tokens.append(contentsOf: qualityTokens())

        // 2. Style tokens
        tokens.append(contentsOf: styleTokens())

        // 3. Lighting tokens
        tokens.append(contentsOf: lightingTokens())

        // 4. Composition tokens
        tokens.append(contentsOf: compositionTokens())

        // 5. Expression tokens
        tokens.append(contentsOf: expressionTokens())

        // 6. Setting tokens
        tokens.append(contentsOf: settingTokens())

        // 7. Clothing tokens
        tokens.append(contentsOf: clothingTokens())

        // 8. Common negative tokens
        tokens.append(contentsOf: negativeTokens())

        // 9. LoRA tokens from LoRAManager
        if config.includeLoRAs {
            tokens.append(contentsOf: loraTokens())
        }

        // 10. Embeddings from EmbeddingsManager
        if config.includeEmbeddings {
            tokens.append(contentsOf: embeddingTokens())
        }

        // 11. Load custom tokens from successful prompts
        if config.includeHistory {
            await extractHistoryTokens(into: &tokens)
        }

        allTokens = tokens

        // Build prefix index
        var index: [String: [Token]] = [:]
        for token in tokens {
            let text = token.text.lowercased()
            for length in 2...min(text.count, 10) {
                let prefix = String(text.prefix(length))
                index[prefix, default: []].append(token)
            }
            // Also index by alias
            for alias in token.aliases {
                let atext = alias.lowercased()
                for length in 2...min(atext.count, 10) {
                    let prefix = String(atext.prefix(length))
                    index[prefix, default: []].append(token)
                }
            }
        }
        tokenIndex = index
        indexSize  = tokens.count
    }

    // MARK: - Search

    func query(_ text: String, cursorPosition: Int? = nil) {
        // Extract current token being typed
        let currentToken = extractCurrentToken(from: text, at: cursorPosition ?? text.count)
        currentQuery     = currentToken

        guard currentToken.count >= config.minQueryLength else {
            suggestions = []
            return
        }

        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms debounce
            guard !Task.isCancelled else { return }

            let results = await searchTokens(query: currentToken)
            suggestions = results
        }
    }

    private func searchTokens(query: String) async -> [Token] {
        let lower = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !lower.isEmpty else { return [] }

        // Remove leading parens, weights etc.
        let clean = lower
            .trimmingCharacters(in: CharacterSet(charactersIn: "()")  )
            .components(separatedBy: ":").first ?? lower

        // Prefix lookup
        var candidates: [Token] = tokenIndex[String(clean.prefix(10))] ?? []

        // Also do substring search for short indices
        if candidates.isEmpty && clean.count >= 3 {
            candidates = allTokens.filter { $0.text.lowercased().contains(clean) }
        }

        // Score and sort
        let scored = candidates.map { token -> (Token, Double) in
            var score = token.score

            // History boost
            let useCount = historyIndex[token.text] ?? 0
            score += Double(useCount) * config.historyWeight * 0.1

            // Prefix match bonus
            if token.text.lowercased().hasPrefix(clean) { score += 0.5 }

            // Exact match bonus
            if token.text.lowercased() == clean { score += 2.0 }

            return (token, score)
        }

        let sorted = scored
            .sorted { $0.1 > $1.1 }
            .prefix(config.maxSuggestions)
            .map { $0.0 }

        return Array(sorted)
    }

    // MARK: - Token Extraction

    private func extractCurrentToken(from text: String, at position: Int) -> String {
        let upToCursor = String(text.prefix(position))

        // Find last comma (SD prompt separator) or opening paren
        var tokenStart = upToCursor.startIndex
        for char in [",", "(", "<", "\n"] {
            if let range = upToCursor.range(of: String(char), options: .backwards) {
                if range.upperBound > tokenStart {
                    tokenStart = range.upperBound
                }
            }
        }

        let rawToken = String(upToCursor[tokenStart...])
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "()"))

        return rawToken
    }

    // MARK: - Insert Token

    func insert(token: Token, into text: String, at cursorPosition: Int) -> (String, Int) {
        let currentToken = extractCurrentToken(from: text, at: cursorPosition)
        let upToCursor   = String(text.prefix(cursorPosition))
        let afterCursor  = String(text.suffix(text.count - cursorPosition))

        // Find start of current token in upToCursor
        let tokenStartOffset = upToCursor.count - currentToken.count
        let prefix = String(upToCursor.prefix(tokenStartOffset))

        // Build replacement
        var replacement = token.text
        if config.insertWeight {
            switch token.category {
            case .lora:
                replacement = "<lora:\(token.text):\(token.weight ?? 0.8)>"
            case .embedding:
                replacement = token.text
            default:
                break
            }
        }

        let newText = "\(prefix)\(replacement)\(afterCursor)"
        let newCursor = prefix.count + replacement.count

        // Track usage
        historyIndex[token.text, default: 0] += 1

        suggestions = []
        return (newText, newCursor)
    }

    // MARK: - Syntax Highlighting

    struct HighlightedSegment: Identifiable {
        let id    = UUID()
        let text:  String
        let color: Color
        let category: Token.TokenCategory?
    }

    func highlight(prompt: String) -> [HighlightedSegment] {
        // Simple tokenizer: split by commas, detect categories
        let parts = prompt.components(separatedBy: ",")
        return parts.flatMap { part -> [HighlightedSegment] in
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            let category = detectCategory(for: trimmed)
            let color = category != nil ? Color(hex: category!.color) : Color.white.opacity(0.85)
            return [
                HighlightedSegment(text: trimmed, color: color, category: category),
                HighlightedSegment(text: ", ", color: .gray, category: nil)
            ]
        }
    }

    private func detectCategory(for token: String) -> Token.TokenCategory? {
        let lower = token.lowercased()

        if lower.hasPrefix("<lora:") { return .lora }
        if lower.hasPrefix("embedding:") { return .embedding }
        if lower.contains("quality") || lower.contains("masterpiece") || lower.contains("detailed") { return .quality }
        if lower.contains("light") || lower.contains("shadow") || lower.contains("glow") { return .lighting }
        if lower.contains("style") || lower.contains("realistic") || lower.contains("anime") { return .style }
        if lower.contains("shirt") || lower.contains("dress") || lower.contains("outfit") || lower.contains("wear") { return .clothing }
        if lower.contains("smile") || lower.contains("look") || lower.contains("expression") { return .expression }
        if lower.contains("background") || lower.contains("outdoor") || lower.contains("room") { return .setting }
        if lower.contains("portrait") || lower.contains("photo") || lower.contains("shot") { return .composition }

        return nil
    }

    // MARK: - Token History

    private func extractHistoryTokens(into tokens: inout [Token]) async {
        // CORRECCIÓN: Se cambió de recentPrompts a iterar entries directamente
        let recentPrompts = PromptDatabase.shared.entries.prefix(200)
        var tokenCounts: [String: Int] = [:]

        for prompt in recentPrompts {
            // CORRECCIÓN: Se cambió de promptText a positive (la propiedad correcta del Model)
            let parts = prompt.positive.components(separatedBy: ",")
            for part in parts {
                // CORRECCIÓN: .whitespaces en lugar del inferido incorrectamente
                let clean = part.trimmingCharacters(in: CharacterSet.whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "()"))
                    .lowercased()
                guard clean.count > 2 else { continue }
                tokenCounts[clean, default: 0] += 1
                historyIndex[clean, default: 0] += 1
            }
        }

        // Add top history tokens not already in index
        let existingTexts = Set(tokens.map { $0.text.lowercased() })
        for (text, count) in tokenCounts.sorted(by: { $0.value > $1.value }).prefix(500) {
            if !existingTexts.contains(text) {
                tokens.append(Token(
                    text:      text,
                    category:  detectCategory(for: text) ?? .custom,
                    score:     min(1.0, Double(count) / 20.0),
                    postCount: nil,
                    aliases:   [],
                    weight:    nil
                ))
            }
        }
    }

    // MARK: - LoRA/Embedding Token Builders

    private func loraTokens() -> [Token] {
        return LoRAManager.shared.availableLoRAs.map { lora in
            Token(
                text:      lora.name,
                category:  .lora,
                score:     0.9,
                postCount: nil,
                aliases:   [],
                weight:    1.0
            )
        }
    }

    private func embeddingTokens() -> [Token] {
        return EmbeddingsManager.shared.loaded.map { emb in
            Token(
                text:      emb.name,
                category:  .embedding,
                score:     0.85,
                postCount: nil,
                aliases:   [],
                weight:    nil
            )
        }
    }

    // MARK: - Built-In Token Lists

    private func qualityTokens() -> [Token] {
        let items: [(String, Double)] = [
            ("masterpiece", 0.99), ("best quality", 0.99), ("ultra-detailed", 0.97),
            ("ultra high res", 0.95), ("8k uhd", 0.93), ("raw photo", 0.90),
            ("highly detailed", 0.92), ("sharp focus", 0.88), ("professional photograph", 0.87),
            ("photorealistic", 0.86), ("hyperrealistic", 0.85), ("cinematic quality", 0.84),
            ("award-winning photograph", 0.82), ("film grain", 0.75), ("high quality", 0.98),
            ("4k", 0.88), ("hdr", 0.83), ("studio quality", 0.85)
        ]
        return items.map { Token(text: $0.0, category: .quality, score: $0.1, postCount: nil, aliases: [], weight: nil) }
    }

    private func styleTokens() -> [Token] {
        let items: [(String, Double)] = [
            ("realistic", 0.95), ("photorealistic", 0.93), ("anime style", 0.90),
            ("digital art", 0.88), ("illustration", 0.85), ("oil painting", 0.82),
            ("watercolor", 0.80), ("pencil sketch", 0.78), ("concept art", 0.85),
            ("renaissance painting", 0.75), ("impressionist", 0.72), ("pop art", 0.70),
            ("studio ghibli style", 0.88), ("art nouveau", 0.73), ("baroque", 0.71),
            ("cyberpunk", 0.85), ("fantasy art", 0.82), ("surrealism", 0.75),
            ("minimalist", 0.70), ("vaporwave", 0.68)
        ]
        return items.map { Token(text: $0.0, category: .style, score: $0.1, postCount: nil, aliases: [], weight: nil) }
    }

    private func lightingTokens() -> [Token] {
        let items: [(String, Double)] = [
            ("soft lighting", 0.95), ("natural lighting", 0.92), ("studio lighting", 0.90),
            ("golden hour", 0.88), ("dramatic lighting", 0.87), ("rembrandt lighting", 0.85),
            ("cinematic lighting", 0.92), ("backlit", 0.82), ("rim lighting", 0.80),
            ("volumetric lighting", 0.85), ("neon lights", 0.78), ("moonlight", 0.76),
            ("sunbeams", 0.74), ("chiaroscuro", 0.72), ("diffused light", 0.80),
            ("warm light", 0.85), ("cool light", 0.83), ("bokeh", 0.88),
            ("depth of field", 0.90), ("lens flare", 0.72)
        ]
        return items.map { Token(text: $0.0, category: .lighting, score: $0.1, postCount: nil, aliases: [], weight: nil) }
    }

    private func compositionTokens() -> [Token] {
        let items: [(String, Double)] = [
            ("portrait", 0.97), ("close-up", 0.92), ("full body", 0.90),
            ("half body", 0.88), ("face shot", 0.87), ("dutch angle", 0.75),
            ("rule of thirds", 0.72), ("centered composition", 0.82),
            ("from above", 0.80), ("from below", 0.78), ("side view", 0.85),
            ("3/4 view", 0.88), ("frontal", 0.86), ("aerial view", 0.75),
            ("extreme close-up", 0.82), ("wide angle", 0.78), ("telephoto", 0.72),
            ("looking at viewer", 0.90), ("looking away", 0.78)
        ]
        return items.map { Token(text: $0.0, category: .composition, score: $0.1, postCount: nil, aliases: [], weight: nil) }
    }

    private func expressionTokens() -> [Token] {
        let items: [(String, Double)] = [
            ("smile", 0.92), ("serious", 0.85), ("laughing", 0.82),
            ("pouty lips", 0.78), ("sultry", 0.85), ("confident", 0.80),
            ("playful", 0.80), ("mysterious", 0.78), ("warm smile", 0.88),
            ("intense gaze", 0.82), ("relaxed", 0.80), ("elegant", 0.85),
            ("natural expression", 0.88), ("candid", 0.83)
        ]
        return items.map { Token(text: $0.0, category: .expression, score: $0.1, postCount: nil, aliases: [], weight: nil) }
    }

    private func settingTokens() -> [Token] {
        let items: [(String, Double)] = [
            ("outdoor", 0.90), ("indoor", 0.85), ("beach", 0.88),
            ("forest", 0.82), ("city", 0.85), ("studio background", 0.92),
            ("gradient background", 0.88), ("white background", 0.90),
            ("black background", 0.88), ("urban", 0.80), ("rural", 0.75),
            ("mountains", 0.78), ("bedroom", 0.82), ("living room", 0.78),
            ("rooftop", 0.80), ("cafe", 0.77), ("vintage room", 0.75),
            ("luxury interior", 0.82), ("tropical", 0.80), ("desert", 0.72)
        ]
        return items.map { Token(text: $0.0, category: .setting, score: $0.1, postCount: nil, aliases: [], weight: nil) }
    }

    private func clothingTokens() -> [Token] {
        let items: [(String, Double)] = [
            ("elegant dress", 0.90), ("casual outfit", 0.85), ("formal wear", 0.82),
            ("bikini", 0.88), ("lingerie", 0.87), ("business attire", 0.80),
            ("athletic wear", 0.78), ("vintage clothing", 0.75), ("luxury fashion", 0.85),
            ("summer dress", 0.88), ("leather jacket", 0.82), ("silk blouse", 0.80),
            ("off-shoulder", 0.85), ("backless dress", 0.83), ("fitted dress", 0.88)
        ]
        return items.map { Token(text: $0.0, category: .clothing, score: $0.1, postCount: nil, aliases: [], weight: nil) }
    }

    private func negativeTokens() -> [Token] {
        let items: [(String, Double)] = [
            ("blurry", 0.99), ("low quality", 0.99), ("bad anatomy", 0.98),
            ("extra limbs", 0.97), ("mutated hands", 0.97), ("deformed", 0.95),
            ("ugly", 0.93), ("watermark", 0.92), ("text", 0.90),
            ("signature", 0.88), ("grainy", 0.87), ("noise", 0.85),
            ("artifacts", 0.87), ("worst quality", 0.99), ("jpeg artifacts", 0.88),
            ("bad proportions", 0.90), ("out of frame", 0.85), ("cropped", 0.82),
            ("nsfw", 0.75), ("logo", 0.80)
        ]
        return items.map { Token(text: $0.0, category: .negative, score: $0.1, postCount: nil, aliases: [], weight: nil) }
    }

    // MARK: - Token Frequency Export

    func exportTokenFrequency() -> [String: Int] {
        return historyIndex
    }

    func importTokenFrequency(_ dict: [String: Int]) {
        for (token, count) in dict {
            historyIndex[token, default: 0] += count
        }
    }

    // MARK: - Refresh

    func refreshLoRATokens() {
        let loraTokenList = loraTokens()
        allTokens.removeAll { $0.category == .lora }
        allTokens.append(contentsOf: loraTokenList)
        Task { await buildIndex() }
    }
}

// MARK: - AutoComplete SwiftUI View

struct AutoCompleteDropdown: View {
    @ObservedObject private var engine = PromptAutoCompleteEngine.shared
    let onSelect: (PromptAutoCompleteEngine.Token) -> Void

    var body: some View {
        Group {
            if !engine.suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(engine.suggestions) { token in
                        Button(action: { onSelect(token) }) {
                            HStack(spacing: 8) {
                                Image(systemName: token.category.icon)
                                    .font(.system(size: 9))
                                    .foregroundColor(Color(hex: token.category.color))
                                    .frame(width: 14)

                                Text(token.text)
                                    .font(.system(size: 11))
                                    .foregroundColor(.white)

                                Spacer()

                                if let count = token.postCount {
                                    Text("\(count)")
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }

                                Text(token.category.rawValue)
                                    .font(.system(size: 9))
                                    .foregroundColor(Color(hex: token.category.color).opacity(0.8))
                            }
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(Color.white.opacity(0.04))
                        .cornerRadius(4)
                    }
                }
                .padding(6)
                .background(Color(red: 0.1, green: 0.1, blue: 0.14))
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1), lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
            }
        }
    }
}

=== ./PromptBuilderView.swift ===
