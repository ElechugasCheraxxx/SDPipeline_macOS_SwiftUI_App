import SwiftUI
import AppKit
import CoreImage

// MARK: - MissingViews v4
// Contiene:
//   • IPAdapterModel alias (puente al enum de IPAdapterEngine)
//   • CharacterProfile.baseImagePath helper (puente a UserDefaults)
//   • ZeroKnowledgeLogView compatibility shim
//   • CIImage init helper para steg verification

// MARK: - IPAdapterModel typealias
// Puente para archivos que referencian IPAdapterModel directamente.

typealias IPAdapterModel = IPAdapterEngine.IPAdapterModel

// MARK: - CIImage steg helper

extension CIImage {
    convenience init?(nsImage: NSImage) {
        guard let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        self.init(cgImage: cgImage)
    }
}

// MARK: - ZeroKnowledgeLog category filter

extension ZeroKnowledgeLog {
    func entries(category: LogCategory) -> [LogEntry] {
        entries(limit: 1000).filter { $0.category == category }
    }
}

// MARK: - PromptAutoCompleteEngine bridge methods (v3)
// Bridges para métodos referenciados en PromptBuilderView y PipelineConnector
// que no existían en la API pública del engine.

extension PromptAutoCompleteEngine {

    /// Limpia las sugerencias actuales y oculta el overlay.
    func clearSuggestions() {
        suggestions = []
        currentQuery = ""
    }

    /// Registra el uso de un token para mejorar el ranking futuro.
    func recordUsage(_ token: Token) {
        insertIntoHistoryIndex(text: token.text)
        // Refrescar sugerencias si hay query activa
        if !currentQuery.isEmpty {
            query(currentQuery)
        }
    }

    /// Construye el índice con listas adicionales de LoRAs y Embeddings instalados.
    func buildIndex(loraNames: [String], embeddingNames: [String]) async {
        await buildIndex()   // índice base existente
        // Inyectar LoRAs y embeddings en el prefixIndex
        let loraTokens = loraNames.map {
            Token(text: "<lora:\($0):1>", category: .lora, score: 2.0,
                  postCount: nil, aliases: [], weight: 1.0)
        }
        let embTokens = embeddingNames.map {
            Token(text: $0, category: .custom, score: 1.5,
                  postCount: nil, aliases: [], weight: nil)
        }
        injectTokens(loraTokens + embTokens)
    }

    /// Inserta tokens adicionales en el índice de prefijos (LoRAs, embeddings, custom).
    private func injectTokens(_ tokens: [Token]) {
        for token in tokens {
            let text   = token.text.lowercased()
            let prefixLen = min(text.count, 4)
            for i in 1...max(1, prefixLen) {
                let prefix = String(text.prefix(i))
                if tokenIndex[prefix] == nil { tokenIndex[prefix] = [] }
                if tokenIndex[prefix]!.count < 200 {
                    tokenIndex[prefix]!.append(token)
                }
            }
        }
        indexSize += tokens.count
    }

    /// Inserta un texto en el historial de uso interno.
    private func insertIntoHistoryIndex(text: String) {
        let key = text.lowercased()
        // historyIndex es privado en el engine; refrescamos via importTokenFrequency
        var freq = exportTokenFrequency()
        freq[key] = (freq[key] ?? 0) + 1
        importTokenFrequency(freq)
    }
}

// MARK: - ADetailerEngine.isInstalled bridge

extension ADetailerEngine {
    /// Retorna true si ADetailer está disponible en el A1111 detectado.
    /// Se comprueba vía el flag persistido tras la última conexión exitosa.
    var isInstalled: Bool {
        get { UserDefaults.standard.bool(forKey: "adetailer.isInstalled") }
        set { UserDefaults.standard.set(newValue, forKey: "adetailer.isInstalled") }
    }
}

// MARK: - SidecarJSON manager bridge

/// Manager singleton para SidecarJSON (el struct en SidecarJSON.swift ya tiene save(to:)).
final class SidecarJSONManager {
    static let shared = SidecarJSONManager()
    private init() {}

    /// Escribe el sidecar JSON junto a la imagen exportada.
    func write(for asset: GeneratedAsset, imageURL: URL) throws {
        let sidecarURL = imageURL.deletingLastPathComponent()
            .appendingPathComponent(asset.baseName ?? asset.id.uuidString)
            .appendingPathExtension("json")
        var sidecar = SidecarJSON()
        sidecar.assetID       = asset.id.uuidString
        sidecar.promptPositive = asset.promptPositive ?? ""
        sidecar.promptNegative = asset.promptNegative ?? ""
        sidecar.seed           = Int(asset.seed)
        sidecar.steps          = Int(asset.steps)
        sidecar.cfgScale       = asset.cfgScale
        sidecar.samplerName    = asset.samplerName ?? ""
        sidecar.width          = Int(asset.width)
        sidecar.height         = Int(asset.height)
        sidecar.checkpoint     = asset.checkpoint ?? ""
        sidecar.generatedAt    = asset.createdAt ?? Date()
        try sidecar.save(to: sidecarURL)
    }
}
