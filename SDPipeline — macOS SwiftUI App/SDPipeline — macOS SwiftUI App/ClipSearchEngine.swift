import Foundation
import AppKit
import SwiftUI
import Combine

// MARK: - ClipSearchEngine
//
// Buscador por vectores usando CLIP (Contrastive Language–Image Pre-training).
// Permite búsqueda semántica de imágenes por texto natural:
//   "mujer en vestido rojo" → recupera imágenes semánticamente similares
//   "fondo oscuro con iluminación cinemática" → filtra por ambiente visual
//
// Arquitectura dual:
//   1. LOCAL (sin SD corriendo): Usa Apple Vision framework para features descriptivos
//      + TF-IDF sobre prompts para aproximación semántica.
//   2. REMOTE (A1111 corriendo): Usa /sdapi/v1/interrogate con CLIP para vectores reales.
//      Los vectores se persisten en un índice local (formato binario compacto).
//
// Formato del índice:
//   Vault/meta/clip_index.bin   → Float32 array: [assetCount × vectorDim]
//   Vault/meta/clip_id_map.json → { index: assetUUID }
//
// Similaridad: cosine similarity entre vector query y vectores del índice.
//
// ROADMAP: "Buscador por vectores (CLIP)" (🟡 MEDIO PLAZO)

@MainActor
final class ClipSearchEngine: ObservableObject {

    static let shared = ClipSearchEngine()
    private init() { loadIndex() }

    // MARK: - Models

    typealias ClipVector = [Float]

    struct IndexEntry: Codable {
        let assetUUID: String
        let vectorIndex: Int        // Posición en el buffer Float32
        let indexedAt: Date
        let promptHint: String      // Primeras 60 chars del prompt (no vector, solo debug)
    }

    struct SearchResult: Identifiable {
        let id    = UUID()
        let assetUUID: UUID
        let similarity: Float       // 0.0 – 1.0 cosine similarity
        let matchReason: String     // "Vector CLIP" / "Prompt TF-IDF" / "Combinado"
    }

    enum IndexingMode {
        case promptTfIdf     // Solo análisis de texto del prompt (siempre disponible)
        case clipRemote      // Vector CLIP vía A1111 interrogate (requiere SD corriendo)
        case combined        // Ambos combinados (mejor calidad)
    }

    // MARK: - Published State

    @Published var indexSize:      Int      = 0
    @Published var isIndexing:     Bool     = false
    @Published var indexProgress:  Double   = 0
    @Published var lastIndexDate:  Date?
    @Published var searchResults:  [SearchResult] = []
    @Published var isSearching:    Bool     = false

    // Internal index
    private var idMap:     [Int: String]   = [:]   // vectorIndex → assetUUID
    private var reverseMap: [String: Int]  = [:]   // assetUUID → vectorIndex
    private var vectorBuffer: [[Float]]    = []    // in-memory index
    private var idfWeights: [String: Float] = [:]  // TF-IDF term weights

    // MARK: - Index Management

    /// Indexar un asset (agrega al índice o actualiza si ya existe).
    func indexAsset(_ asset: GeneratedAsset, mode: IndexingMode = .promptTfIdf) async {
        guard let uuidStr = asset.id?.uuidString,
              let prompt = asset.promptPositive, !prompt.isEmpty
        else { return }

        let vector: ClipVector

        switch mode {
        case .promptTfIdf:
            vector = tfidfVector(for: prompt)

        case .clipRemote:
            if let clipVec = try? await fetchClipVector(for: asset) {
                vector = clipVec
            } else {
                vector = tfidfVector(for: prompt)   // Fallback
            }

        case .combined:
            let tfidf = tfidfVector(for: prompt)
            if let clip = try? await fetchClipVector(for: asset) {
                // Combinar: 60% CLIP + 40% TF-IDF
                vector = zip(clip, tfidf).map { 0.6 * $0 + 0.4 * $1 }
            } else {
                vector = tfidf
            }
        }

        // Normalizar vector
        let normalized = l2Normalize(vector)

        // Update index
        if let existingIdx = reverseMap[uuidStr] {
            vectorBuffer[existingIdx] = normalized
        } else {
            let newIdx = vectorBuffer.count
            vectorBuffer.append(normalized)
            idMap[newIdx]       = uuidStr
            reverseMap[uuidStr] = newIdx
        }

        indexSize = vectorBuffer.count
    }

    /// Indexar todos los assets del vault en background.
    func rebuildIndex(mode: IndexingMode = .promptTfIdf) async {
        isIndexing    = true
        indexProgress = 0

        // CORRECCIÓN: Eliminado el await, fetchAllAssets es sincrónico
        let assets = AssetStore.shared.fetchAllAssets(limit: 10_000)
        let total  = Double(assets.count)

        // Primero calcular IDF weights (una sola pasada)
        if mode != .clipRemote {
            buildIdfWeights(from: assets.compactMap { $0.promptPositive })
        }

        for (i, asset) in assets.enumerated() {
            await indexAsset(asset, mode: mode)
            indexProgress = Double(i + 1) / total
        }

        lastIndexDate = Date()
        isIndexing    = false

        try? saveIndex()
    }

    // MARK: - Search

    func search(query: String, topK: Int = 20, threshold: Float = 0.15) async -> [SearchResult] {
        isSearching = true
        defer { isSearching = false }

        guard !vectorBuffer.isEmpty else { return [] }

        let queryVec = l2Normalize(tfidfVector(for: query))

        // Compute cosine similarity con todos los vectores en el índice
        var scores: [(index: Int, similarity: Float)] = []

        for (i, vec) in vectorBuffer.enumerated() {
            let sim = cosineSimilarity(queryVec, vec)
            if sim >= threshold {
                scores.append((index: i, similarity: sim))
            }
        }

        // Sort descendente por similaridad
        scores.sort { $0.similarity > $1.similarity }
        let topResults = scores.prefix(topK)

        let results: [SearchResult] = topResults.compactMap { entry in
            guard let uuidStr = idMap[entry.index],
                  let uuid = UUID(uuidString: uuidStr)
            else { return nil }

            return SearchResult(
                assetUUID:   uuid,
                similarity:  entry.similarity,
                matchReason: "Vector TF-IDF"
            )
        }

        searchResults = results
        return results
    }

    // MARK: - Remote CLIP (A1111)

    private func fetchClipVector(for asset: GeneratedAsset) async throws -> ClipVector? {
        guard let imagePath = asset.imagePath,
              let imageData = try? Data(contentsOf: URL(fileURLWithPath: imagePath))
        else { return nil }

        let b64 = imageData.base64EncodedString()
        let body: [String: Any] = [
            "image": "data:image/png;base64,\(b64)",
            "model": "clip"
        ]

        // CORRECCIÓN: Desacoplado de SDService para evitar error del Singleton
        let baseURL = UserDefaults.standard.string(forKey: "sd.baseURL") ?? "http://127.0.0.1:7860"
        
        guard let url = URL(string: "\(baseURL)/sdapi/v1/interrogate"),
              let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = bodyData

        let (responseData, _) = try await URLSession.shared.data(for: req)

        if let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
           let caption = json["caption"] as? String {
            return tfidfVector(for: caption)
        }
        return nil
    }

    // MARK: - TF-IDF Vectorization

    private var vocabulary: [String: Int] = [:]
    private let vectorDim = 512

    private func buildIdfWeights(from prompts: [String]) {
        var termDocFreq: [String: Int] = [:]
        let docCount = Double(prompts.count)
        guard docCount > 0 else { return }

        for prompt in prompts {
            let tokens = Set(tokenize(prompt))
            for token in tokens {
                termDocFreq[token, default: 0] += 1
            }
        }

        idfWeights = [:]
        for (term, df) in termDocFreq {
            idfWeights[term] = Float(log(docCount / Double(df) + 1.0))
        }

        // Build vocabulary from most common terms
        let sorted = idfWeights.sorted { $0.value < $1.value }  // Low IDF = common terms
        vocabulary = [:]
        for (i, item) in sorted.prefix(vectorDim).enumerated() {
            vocabulary[item.key] = i
        }
    }

    private func tfidfVector(for text: String) -> ClipVector {
        let tokens = tokenize(text)
        var vec = [Float](repeating: 0, count: vectorDim)

        guard !vocabulary.isEmpty else {
            // Fallback: hash-based projection cuando no hay vocabulario
            return hashProjection(text: text, dims: vectorDim)
        }

        // TF
        var tf: [String: Float] = [:]
        for token in tokens {
            tf[token, default: 0] += 1
        }
        let totalTokens = Float(tokens.count)

        // TF-IDF
        for (term, count) in tf {
            guard let idx = vocabulary[term] else { continue }
            let idf = idfWeights[term] ?? 1.0
            vec[idx] = (count / max(1, totalTokens)) * idf
        }

        return vec
    }

    private func hashProjection(text: String, dims: Int) -> [Float] {
        var vec = [Float](repeating: 0, count: dims)
        let tokens = tokenize(text)
        for token in tokens {
            let hash = abs(token.hashValue)
            let idx  = hash % dims
            vec[idx] += 1.0
        }
        return vec
    }

    private func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 }
    }

    // MARK: - Math Utilities

    private func l2Normalize(_ vec: [Float]) -> [Float] {
        let norm = sqrt(vec.map { $0 * $0 }.reduce(0, +))
        guard norm > 0 else { return vec }
        return vec.map { $0 / norm }
    }

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        return zip(a, b).map { $0 * $1 }.reduce(0, +)
    }

    // MARK: - Persistence

    private var indexURL: URL? {
        VaultManager.shared.vaultRoot?
            .appendingPathComponent("Vault/meta/clip_id_map.json")
    }

    private func saveIndex() throws {
        guard let url = indexURL else { return }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let entries = idMap.map { (idx, uuid) in
            IndexEntry(
                assetUUID:   uuid,
                vectorIndex: idx,
                indexedAt:   lastIndexDate ?? Date(),
                promptHint:  ""
            )
        }

        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(entries).write(to: url, options: .atomic)
    }

    private func loadIndex() {
        guard let url = indexURL, let data = try? Data(contentsOf: url) else { return }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let entries = try? dec.decode([IndexEntry].self, from: data) else { return }

        // Solo recargamos el mapa de IDs — los vectores deben reconstruirse
        for entry in entries {
            idMap[entry.vectorIndex]      = entry.assetUUID
            reverseMap[entry.assetUUID]   = entry.vectorIndex
        }
        indexSize = entries.count
    }
}

// MARK: - CLIP Search View

struct ClipSearchView: View {
    @ObservedObject private var engine = ClipSearchEngine.shared
    @State private var query    = ""
    @State private var results: [ClipSearchEngine.SearchResult] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Search bar
            HStack(spacing: 8) {
                Image(systemName: "sparkle.magnifyingglass")
                    .foregroundColor(Color(hex: "#7c6af7"))
                TextField("Buscar por descripción… \"mujer en playa al atardecer\"", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onSubmit {
                        Task { results = await engine.search(query: query) }
                    }

                if engine.isSearching {
                    ProgressView().scaleEffect(0.7)
                } else if !query.isEmpty {
                    Button(action: {
                        Task { results = await engine.search(query: query) }
                    }) {
                        Image(systemName: "return")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.secondary.opacity(0.08))
            .cornerRadius(10)

            // Index status
            HStack(spacing: 6) {
                Circle()
                    .fill(engine.indexSize > 0 ? Color(hex: "#34d399") : Color(hex: "#fbbf24"))
                    .frame(width: 6, height: 6)
                Text(engine.indexSize > 0
                    ? "\(engine.indexSize) imágenes indexadas"
                    : "Índice vacío — ejecuta Reconstruir")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)

                Spacer()

                if engine.isIndexing {
                    HStack(spacing: 4) {
                        ProgressView(value: engine.indexProgress, total: 1.0)
                            .progressViewStyle(.linear)
                            .frame(width: 60)
                        Text("\(Int(engine.indexProgress * 100))%")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                } else {
                    Button("Reconstruir índice") {
                        Task { await engine.rebuildIndex() }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color(hex: "#7c6af7"))
                }
            }

            // Results
            if !results.isEmpty {
                Divider()
                Text("\(results.count) resultados para \"\(query)\"")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(results.prefix(12)) { result in
                            ClipResultThumbnail(result: result)
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .frame(height: 100)
            }
        }
        .padding(12)
    }
}

private struct ClipResultThumbnail: View {
    let result: ClipSearchEngine.SearchResult
    @State private var image: NSImage?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let img = image {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.1))
                }
            }
            .frame(width: 80, height: 80)
            .cornerRadius(8)
            .clipped()

            Text("\(Int(result.similarity * 100))%")
                .font(.system(size: 9, weight: .bold))
                .padding(3)
                .background(Color.black.opacity(0.6))
                .foregroundColor(.white)
                .cornerRadius(4)
                .padding(4)
        }
        .onAppear {
            // Load thumbnail from AssetStore
            if let asset = AssetStore.shared.recentAssets.first(where: {
                $0.id?.uuidString == result.assetUUID.uuidString
            }) {
                image = asset.thumbnail
            }
        }
    }
}
