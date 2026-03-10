import Foundation
import AppKit
import SwiftUI
import Combine

// MARK: - CLIPSearchEngine
//
// Búsqueda semántica de imágenes usando CLIP vía A1111 /sdapi/v1/interrogate.
//
// Modos de búsqueda:
//   .textQuery   — "mujer con luz dorada" → busca imágenes que coincidan semánticamente
//   .imageQuery  — imagen de referencia → encuentra imágenes visualmente similares
//   .promptMatch — compara prompts almacenados como texto
//
// Implementación:
//   1. Para cada asset en el vault, obtener su "caption" CLIP vía A1111
//   2. Guardar caption en index local (Vault/clip_index.json)
//   3. Búsqueda por similitud de texto: TF-IDF simplificado sobre captions
//   4. Búsqueda por imagen: interrogar la query y comparar captions
//
// Notas:
//   - El index se construye una sola vez y se actualiza incremetalmente
//   - CLIP tiene una latencia de ~2-5s por imagen según hardware
//   - Requiere A1111 online con modelo CLIP cargado
//
// ROADMAP: "Buscador por vectores (CLIP)" (🟡 MEDIO PLAZO)

// MARK: - Models

struct CLIPEntry: Codable, Identifiable {
    var id:         UUID
    var assetID:    UUID
    var caption:    String
    var keywords:   [String]    // tokenizados del caption
    var generatedAt: Date
    var baseName:   String
}

struct CLIPSearchResult: Identifiable {
    let id          = UUID()
    let asset:      GeneratedAsset
    let caption:    String
    let score:      Double       // 0.0 – 1.0 (similitud)
    let matchedKeywords: [String]
}

// MARK: - CLIPSearchEngine

@MainActor
final class CLIPSearchEngine: ObservableObject {

    static let shared = CLIPSearchEngine()
    private init() { loadIndex() }

    // MARK: - State

    @Published var index:          [CLIPEntry]       = []
    @Published var isIndexing:     Bool              = false
    @Published var isSearching:    Bool              = false
    @Published var indexProgress:  Double            = 0
    @Published var indexText:      String            = ""
    @Published var searchResults:  [CLIPSearchResult] = []
    @Published var lastQuery:      String            = ""
    @Published var errorMessage:   String?           = nil

    var indexedCount: Int { index.count }
    var totalAssets:  Int { AssetStore.shared.fetchAllAssets(limit: 10_000).count }

    // MARK: - Indexing

    /// Construir/actualizar el índice CLIP para todos los assets no indexados.
    func buildIndex(baseURL: String) async {
        guard !isIndexing else { return }
        isIndexing    = true
        errorMessage  = nil
        indexProgress = 0
        indexText     = "Cargando assets…"

        let assets     = AssetStore.shared.fetchAllAssets(limit: 10_000)
        let indexedIDs = Set(index.compactMap { $0.assetID })
        let pending    = assets.filter { asset in
            guard let id = asset.id else { return false }
            return !indexedIDs.contains(id)
        }

        guard !pending.isEmpty else {
            indexText  = "Índice actualizado ✓ (\(index.count) assets)"
            isIndexing = false
            return
        }

        indexText = "Indexando \(pending.count) assets con CLIP…"
        let total = Double(pending.count)
        var done  = 0

        for asset in pending {
            guard let id   = asset.id,
                  let path = asset.imagePath,
                  let img  = NSImage(contentsOfFile: path)
            else {
                done += 1
                continue
            }

            if let caption = await interrogateCLIP(image: img, baseURL: baseURL) {
                let entry = CLIPEntry(
                    id:          UUID(),
                    assetID:     id,
                    caption:     caption,
                    keywords:    tokenize(caption),
                    generatedAt: Date(),
                    baseName:    asset.baseName ?? id.uuidString
                )
                index.append(entry)
            }

            done += 1
            indexProgress = Double(done) / total
            indexText     = "CLIP: \(done)/\(Int(total)) (\(Int(indexProgress * 100))%)"

            // Save periodically
            if done % 10 == 0 { saveIndex() }
        }

        saveIndex()
        indexText  = "Índice CLIP completado — \(index.count) assets"
        isIndexing = false
    }

    /// Indexar un único asset recién generado.
    func indexAsset(_ asset: GeneratedAsset, baseURL: String) async {
        guard let id   = asset.id,
              let path = asset.imagePath,
              let img  = NSImage(contentsOfFile: path),
              !index.contains(where: { $0.assetID == id })
        else { return }

        if let caption = await interrogateCLIP(image: img, baseURL: baseURL) {
            let entry = CLIPEntry(
                id:          UUID(),
                assetID:     id,
                caption:     caption,
                keywords:    tokenize(caption),
                generatedAt: Date(),
                baseName:    asset.baseName ?? id.uuidString
            )
            index.append(entry)
            saveIndex()
        }
    }

    // MARK: - Search

    /// Buscar por texto (query semántica).
    func search(query: String, limit: Int = 20) {
        guard !query.isEmpty else { searchResults = []; return }
        isSearching = true
        lastQuery   = query

        let queryKeywords = tokenize(query.lowercased())
        let allAssets     = AssetStore.shared.fetchAllAssets(limit: 10_000)
        let assetMap      = Dictionary(uniqueKeysWithValues: allAssets.compactMap { a in
            a.id.map { ($0, a) }
        })

        // Score cada entrada indexada
        var scored: [(entry: CLIPEntry, score: Double, matched: [String])] = index.compactMap { entry in
            guard assetMap[entry.assetID] != nil else { return nil }
            let (score, matched) = computeScore(queryKeywords: queryKeywords, entryKeywords: entry.keywords, caption: entry.caption)
            guard score > 0 else { return nil }
            return (entry, score, matched)
        }

        // Fallback a búsqueda por prompt si hay pocos resultados CLIP
        if scored.count < 3 {
            let promptMatches = allAssets.filter {
                let positive = ($0.promptPositive ?? "").lowercased()
                return queryKeywords.contains(where: { positive.contains($0) })
            }
            for asset in promptMatches {
                guard let id = asset.id, !scored.contains(where: { $0.entry.assetID == id }) else { continue }
                let fakeEntry = CLIPEntry(id: UUID(), assetID: id, caption: asset.promptPositive ?? "",
                                         keywords: tokenize(asset.promptPositive ?? ""),
                                         generatedAt: Date(), baseName: asset.baseName ?? "")
                scored.append((fakeEntry, 0.3, queryKeywords.filter {
                    (asset.promptPositive ?? "").lowercased().contains($0)
                }))
            }
        }

        // Sort by score descending
        scored.sort { $0.score > $1.score }

        searchResults = scored.prefix(limit).compactMap { item in
            guard let asset = assetMap[item.entry.assetID] else { return nil }
            return CLIPSearchResult(
                asset:           asset,
                caption:         item.entry.caption,
                score:           item.score,
                matchedKeywords: item.matched
            )
        }

        isSearching = false
    }

    /// Buscar por imagen de referencia (interroga la imagen y busca similares).
    func searchByImage(_ image: NSImage, baseURL: String, limit: Int = 20) async {
        isSearching = true
        defer { isSearching = false }

        guard let caption = await interrogateCLIP(image: image, baseURL: baseURL) else {
            errorMessage = "No se pudo obtener caption de la imagen con CLIP"
            return
        }

        search(query: caption, limit: limit)
        lastQuery = "Imagen similar: \(caption.prefix(40))…"
    }

    // MARK: - A1111 CLIP Interrogation

    private func interrogateCLIP(image: NSImage, baseURL: String) async -> String? {
        guard let b64 = imageToBase64(image),
              let url = URL(string: "\(baseURL)/sdapi/v1/interrogate")
        else { return nil }

        let payload: [String: Any] = ["image": b64, "model": "clip"]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }

        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody  = body

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let caption = json["caption"] as? String
        else { return nil }

        return caption.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Scoring

    private func computeScore(
        queryKeywords: [String],
        entryKeywords: [String],
        caption: String
    ) -> (score: Double, matched: [String]) {
        guard !queryKeywords.isEmpty else { return (0, []) }

        let captionLower = caption.lowercased()
        var matched: [String] = []
        var score: Double = 0

        for kw in queryKeywords {
            if entryKeywords.contains(kw) {
                score  += 1.0
                matched.append(kw)
            } else if captionLower.contains(kw) {
                score  += 0.5
                matched.append(kw)
            }
        }

        // Normalize: full match = 1.0
        let normalizedScore = min(score / Double(queryKeywords.count), 1.0)
        return (normalizedScore, matched)
    }

    // MARK: - Tokenizer

    private func tokenize(_ text: String) -> [String] {
        let stopWords: Set<String> = ["a", "an", "the", "in", "on", "at", "of", "with",
                                       "and", "or", "is", "are", "was", "has", "have",
                                       "de", "en", "con", "y", "el", "la", "los", "las"]
        return text.lowercased()
            .components(separatedBy: .init(charactersIn: " ,.:;!?()[]{}\"'"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 3 && !stopWords.contains($0) }
    }

    // MARK: - Helpers

    private func imageToBase64(_ image: NSImage) -> String? {
        guard let tiff = image.tiffRepresentation,
              let bmp  = NSBitmapImageRep(data: tiff),
              let png  = bmp.representation(using: .png, properties: [:])
        else { return nil }
        return png.base64EncodedString()
    }

    // MARK: - Persistence

    private var indexURL: URL? {
        VaultManager.shared.vaultMetaURL?.appending(path: "clip_index.json")
    }

    func saveIndex() {
        guard let url  = indexURL,
              let data = try? JSONEncoder.pretty.encode(index) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func loadIndex() {
        guard let url  = indexURL,
              let data = try? Data(contentsOf: url),
              let idx  = try? JSONDecoder.iso8601.decode([CLIPEntry].self, from: data)
        else { return }
        index = idx
    }

    func clearIndex() {
        index = []
        saveIndex()
    }
}

// MARK: - CLIPSearchView

struct CLIPSearchView: View {

    @StateObject private var engine = CLIPSearchEngine.shared
    @State private var query:       String  = ""
    @State private var baseURL:     String  = "http://127.0.0.1:7860"
    @State private var showIndexer  = false
    @State private var refImage:    NSImage? = nil

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider().background(Color.white.opacity(0.06))

            // Search bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12)).foregroundColor(.secondary)
                TextField("Buscar por semántica… (ej: 'mujer luz dorada')", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 12)).foregroundColor(.white)
                    .onSubmit { engine.search(query: query) }

                if engine.isSearching {
                    ProgressView().controlSize(.small)
                } else if !query.isEmpty {
                    Button(action: { engine.search(query: query) }) {
                        Image(systemName: "return").font(.system(size: 11))
                            .foregroundColor(Color(hex: "#7c6af7"))
                    }
                    .buttonStyle(.plain)
                }

                Button(action: { pickReferenceImage() }) {
                    Image(systemName: "photo.badge.magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Buscar por imagen de referencia")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.white.opacity(0.04))

            Divider().background(Color.white.opacity(0.04))

            // Index status
            if engine.isIndexing {
                HStack(spacing: 8) {
                    ProgressView(value: engine.indexProgress).tint(Color(hex: "#7c6af7")).frame(maxWidth: 120)
                    Text(engine.indexText).font(.system(size: 10)).foregroundColor(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color(hex: "#7c6af7").opacity(0.06))
            } else if engine.indexedCount < engine.totalAssets {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 11))
                        .foregroundColor(Color(hex: "#f59e0b"))
                    Text("\(engine.indexedCount)/\(engine.totalAssets) indexados")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                    Spacer()
                    Button("Indexar") {
                        Task { await engine.buildIndex(baseURL: baseURL) }
                    }
                    .buttonStyle(.plain).font(.system(size: 10))
                    .foregroundColor(Color(hex: "#7c6af7"))
                }
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Color(hex: "#f59e0b").opacity(0.06))
            }

            // Results
            if engine.searchResults.isEmpty {
                emptyState
            } else {
                resultsList
            }
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.07), lineWidth: 1))
    }

    var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "brain")
                .font(.system(size: 12)).foregroundColor(Color(hex: "#7c6af7"))
            Text("Búsqueda CLIP")
                .font(.system(size: 13, weight: .bold)).foregroundColor(.white)
            Spacer()
            Text("\(engine.indexedCount) indexados")
                .font(.system(size: 10)).foregroundColor(.secondary)
            if !engine.searchResults.isEmpty {
                Text("· \(engine.searchResults.count) resultados")
                    .font(.system(size: 10)).foregroundColor(Color(hex: "#7c6af7"))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.white.opacity(0.03))
    }

    var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "brain")
                .font(.system(size: 30)).foregroundColor(.white.opacity(0.07))
            Text(engine.lastQuery.isEmpty
                 ? "Escribe una descripción semántica para buscar"
                 : "Sin resultados para "\(engine.lastQuery.truncated(30))"")
                .font(.system(size: 12)).foregroundColor(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 220)
        }
        .frame(maxWidth: .infinity).padding(30)
    }

    var resultsList: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6)], spacing: 6) {
                ForEach(engine.searchResults) { result in
                    clipResultCell(result)
                }
            }
            .padding(10)
        }
    }

    func clipResultCell(_ result: CLIPSearchResult) -> some View {
        VStack(spacing: 4) {
            Group {
                if let path = result.asset.imagePath,
                   let img  = NSImage(contentsOfFile: path) {
                    Image(nsImage: img)
                        .resizable().scaledToFill()
                        .frame(height: 100).clipped()
                } else {
                    RoundedRectangle(cornerRadius: 0)
                        .fill(Color.white.opacity(0.06))
                        .frame(height: 100)
                        .overlay(Image(systemName: "photo").foregroundColor(.secondary))
                }
            }
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(hex: "#7c6af7").opacity(result.score * 0.8), lineWidth: 1.5)
            )

            // Score bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.04)).frame(height: 3)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(hex: "#7c6af7").opacity(0.7))
                        .frame(width: geo.size.width * result.score, height: 3)
                }
            }
            .frame(height: 3)

            Text(String(format: "%.0f%%", result.score * 100))
                .font(.system(size: 8, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .padding(2)
    }

    private func pickReferenceImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.canChooseFiles = true
        panel.title = "Imagen de referencia para búsqueda CLIP"
        guard panel.runModal() == .OK,
              let url = panel.url,
              let img = NSImage(contentsOf: url) else { return }
        refImage = img
        Task { await engine.searchByImage(img, baseURL: baseURL) }
    }
}
