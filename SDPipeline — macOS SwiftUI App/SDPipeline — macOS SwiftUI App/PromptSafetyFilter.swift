import Foundation

// MARK: - PromptSafetyFilter
// Valida el JSON del Model Builder y el prompt final ANTES de enviar a SD.
// Objetivo: mantener la "Safe Zone" de arte erótico y cumplir con OnlyFans TOS.
// Este filtro es una capa de seguridad personal — no sustituye el juicio artístico.

struct PromptSafetyFilter {

    // MARK: - Result

    enum FilterResult {
        case allowed
        case blocked(reason: String, matchedTerms: [String])
        case flagged(warnings: [String])  // Permite pero advierte — revisión recomendada
    }

    // MARK: - Blacklist
    // Términos que BLOQUEAN la generación por completo.
    // Organizado por categoría para mantenimiento.

    private static let hardBlocks: [String: [String]] = [

        "Menores (protección absoluta)": [
            "child", "children", "kid", "kids", "minor", "minors",
            "underage", "teen", "teenager", "juvenile", "infant", "toddler",
            "preteen", "pre-teen", "adolescent", "schoolgirl", "schoolboy",
            "loli", "lolita", "shota", "niño", "niña", "menor", "adolescente",
            "colegiala", "infantil", "bebé", "joven", "jovencita", "jovencito",
            "young girl", "young boy", "little girl", "little boy", "petite minor",
        ],

        "Actos ilegales": [
            "rape", "non-consent", "nonconsent", "non consent", "forced sex",
            "sexual assault", "molest", "molestation", "violación", "abuso sexual",
            "bestiality", "zoophilia", "zoo", "animal sex", "bestialismo",
            "necrophilia", "necrofilia",
            "snuff", "torture sexual", "gore sexual",
        ],

        "Contenido explícitamente prohibido en plataformas": [
            // Incesto (prohibido en OnlyFans TOS)
            "incest", "incesto", "inbreeding",
            "step-sister explicit", "step-brother explicit", "step-mom explicit",
            // Otros
            "fisting explicit", "scat", "coprophilia", "urophilia extreme",
            "extreme BDSM non-consent",
        ],
    ]

    // MARK: - Flagged Terms
    // Términos que no bloquean pero emiten advertencia para revisión humana.

    private static let softFlags: [String] = [
        "very young", "barely legal", "18+", "eighteen",
        "tight", "petite", "small", "tiny" ,
        "innocent", "naive", "pure",
        "schoolgirl", "uniform", "pigtails",
        "blood", "violence", "degrading",
        "extreme", "brutal",
    ]

    // MARK: - JSON Schema Safety Fields
    // Campos del Model Builder JSON que deben tener valores seguros.

    private static let requiredSafetyFields: [String: (keyPath: [String], expectedValue: Bool)] = [
        "minor_protection":  (["safety_compliance_layer", "minor_protection_enforced"], true),
        "sexual_act_block":  (["safety_compliance_layer", "sexual_act_block"],          true),
        "explicit_block":    (["safety_compliance_layer", "explicit_content_block"],    true),
    ]

    // MARK: - Public API

    /// Validar el JSON completo del Model Builder antes de parsear el prompt.
    static func validateJSON(_ json: Any) -> FilterResult {
        var warnings: [String] = []

        guard let dict = json as? [String: Any] else { return .allowed }

        // Verificar campos de safety_compliance_layer
        for (name, field) in requiredSafetyFields {
            let value = resolveKeyPath(field.keyPath, in: dict) as? Bool
            if value != field.expectedValue {
                warnings.append("⚠️ Campo de seguridad '\(name)' tiene valor incorrecto o falta en el schema.")
            }
        }

        // Extraer todo el texto del JSON y validar contra blacklist
        let allText = extractAllStrings(from: json).joined(separator: " ").lowercased()

        // Validar contra hard blocks
        for (category, terms) in hardBlocks {
            let matched = terms.filter { term in
                allText.contains(term.lowercased())
            }
            if !matched.isEmpty {
                return .blocked(
                    reason: "Contenido bloqueado: \(category)",
                    matchedTerms: matched
                )
            }
        }

        // Validar soft flags
        let flagged = softFlags.filter { allText.contains($0.lowercased()) }
        if !flagged.isEmpty {
            warnings.append("🔍 Términos bajo revisión detectados: \(flagged.joined(separator: ", ")). Verifica que el contexto sea apropiado.")
        }

        return warnings.isEmpty ? .allowed : .flagged(warnings: warnings)
    }

    /// Validar el prompt final (positivo + negativo) antes de enviar a SD.
    static func validatePrompt(positive: String, negative: String) -> FilterResult {
        let combined = "\(positive) \(negative)".lowercased()
        var warnings: [String] = []

        // Hard blocks
        for (category, terms) in hardBlocks {
            let matched = terms.filter { combined.contains($0.lowercased()) }
            if !matched.isEmpty {
                return .blocked(
                    reason: "Prompt bloqueado: \(category)",
                    matchedTerms: matched
                )
            }
        }

        // Soft flags en el prompt positivo (negativo puede contener estos términos como bloqueo)
        let positiveOnly = positive.lowercased()
        let flagged = softFlags.filter { positiveOnly.contains($0.lowercased()) }
        if !flagged.isEmpty {
            warnings.append("Términos bajo revisión en prompt positivo: \(flagged.joined(separator: ", "))")
        }

        return warnings.isEmpty ? .allowed : .flagged(warnings: warnings)
    }

    // MARK: - Logging

    /// Registrar resultados de filtrado — ahora cifrado con AES-GCM vía ZeroKnowledgeLog.
    static func logResult(_ result: FilterResult, prompt: String) {
        // ZeroKnowledgeLog.shared es @MainActor — llamar desde Task para no bloquear
        Task { @MainActor in
            logResultZK(result, prompt: prompt)
        }

        // Fallback plaintext legacy para compatibilidad (puede eliminarse en próxima iteración)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let truncated = String(prompt.prefix(80)) + (prompt.count > 80 ? "..." : "")

        switch result {
        case .allowed:
            break
        case .blocked(let reason, let terms):
            let entry = "[\(timestamp)] BLOCKED | \(reason) | Terms: \(terms.joined(separator: ",")) | Prompt: \(truncated)"
            appendToSecurityLog(entry)
        case .flagged(let warnings):
            let entry = "[\(timestamp)] FLAGGED | \(warnings.joined(separator: " | ")) | Prompt: \(truncated)"
            appendToSecurityLog(entry)
        }
    }

    // MARK: - Private Helpers

    private static func resolveKeyPath(_ keys: [String], in dict: [String: Any]) -> Any? {
        var current: Any = dict
        for key in keys {
            guard let d = current as? [String: Any], let next = d[key] else { return nil }
            current = next
        }
        return current
    }

    private static func extractAllStrings(from value: Any) -> [String] {
        switch value {
        case let str as String: return [str]
        case let dict as [String: Any]: return dict.values.flatMap { extractAllStrings(from: $0) }
        case let arr as [Any]: return arr.flatMap { extractAllStrings(from: $0) }
        default: return []
        }
    }

    private static func appendToSecurityLog(_ entry: String) {
        guard let logURL = VaultManager.shared.vaultMetaURL?.appending(path: "security.log") else { return }
        let line = entry + "\n"
        if let data = line.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            } else {
                try? data.write(to: logURL, options: .atomic)
            }
        }
    }
}

// MARK: - FilterResult Helpers para UI

extension PromptSafetyFilter.FilterResult {
    var isBlocked: Bool {
        if case .blocked = self { return true }
        return false
    }

    var isFlagged: Bool {
        if case .flagged = self { return true }
        return false
    }

    var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }

    var userMessage: String? {
        switch self {
        case .allowed: return nil
        case .blocked(let reason, _): return "🚫 \(reason)"
        case .flagged(let warnings): return warnings.first
        }
    }
}
