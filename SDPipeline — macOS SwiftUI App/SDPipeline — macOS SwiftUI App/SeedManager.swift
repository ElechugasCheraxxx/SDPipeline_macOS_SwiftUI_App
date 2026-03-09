import Foundation
import SwiftUI
import Combine

// MARK: - SeedManager
//
// Gestiona el ciclo de vida de los seeds de generación:
//   1. Favoritos etiquetados con hint de prompt
//   2. Historial completo de seeds usados (LIFO, cap 500)
//   3. Conteo de uso por seed (para ranking)
//   4. Vinculación de seeds a personajes (delegado a CharacterEngine)
//   5. Exportación de seeds como JSON auditeable
//
// Persistencia: JSON en Vault/seeds_registry.json
// (No Core Data — seeds son metadatos ligeros, JSON es más portable)

@MainActor
final class SeedManager: ObservableObject {

    static let shared = SeedManager()
    private init() { load() }

    // MARK: - Models

    struct FavoriteSeed: Codable, Identifiable, Hashable {
        var id:          UUID   = UUID()
        var seed:        Int
        var label:       String              // Nombre amigable
        var promptHint:  String             // Primeros 50 chars del prompt
        var createdAt:   Date  = Date()
        var usageCount:  Int   = 1
        var characterID: UUID? = nil         // Si está anclado a un personaje
        var tags:        [String] = []
        var rating:      Int   = 0           // 0-5 — igual que los assets

        func hash(into hasher: inout Hasher) { hasher.combine(seed) }
        static func == (lhs: FavoriteSeed, rhs: FavoriteSeed) -> Bool { lhs.seed == rhs.seed }
    }

    struct SeedHistoryEntry: Codable, Identifiable {
        var id:         UUID   = UUID()
        var seed:       Int
        var usedAt:     Date   = Date()
        var promptHint: String = ""
        var width:      Int    = 512
        var height:     Int    = 768
    }

    // MARK: - Published State

    @Published var favorites: [FavoriteSeed]       = []
    @Published var history:   [SeedHistoryEntry]   = []

    // Capacidad máxima del historial (evitar crecimiento descontrolado)
    private let historyCapacity = 500

    // MARK: - Public API — Favoritos

    /// Añadir seed a favoritos. Si ya existe, actualiza label y promptHint.
    @discardableResult
    func addFavorite(
        seed:        Int,
        label:       String,
        promptHint:  String,
        characterID: UUID?   = nil,
        tags:        [String] = []
    ) -> FavoriteSeed {
        if let existing = favorites.first(where: { $0.seed == seed }) {
            // Ya existe — actualizar si el label nuevo no es el default
            var updated = existing
            if !label.isEmpty && label != "Seed \(seed)" { updated.label = label }
            updated.promptHint = promptHint
            updated.usageCount += 1
            if let idx = favorites.firstIndex(where: { $0.seed == seed }) {
                favorites[idx] = updated
            }
            save()
            return updated
        }

        let fav = FavoriteSeed(
            seed:        seed,
            label:       label.isEmpty ? "Seed \(seed)" : label,
            promptHint:  promptHint,
            characterID: characterID,
            tags:        tags
        )
        favorites.insert(fav, at: 0)    // Más reciente primero
        save()
        return fav
    }

    /// Eliminar seed de favoritos.
    func removeFavorite(seed: Int) {
        favorites.removeAll { $0.seed == seed }
        save()
    }

    /// ¿Está el seed en favoritos?
    func isFavorite(_ seed: Int) -> Bool {
        favorites.contains { $0.seed == seed }
    }

    /// Actualizar rating de un seed favorito (0-5).
    func updateRating(seed: Int, rating: Int) {
        guard let idx = favorites.firstIndex(where: { $0.seed == seed }) else { return }
        favorites[idx].rating = max(0, min(5, rating))
        save()
    }

    /// Vincular seed favorito a un personaje.
    func linkToCharacter(seed: Int, characterID: UUID) {
        guard let idx = favorites.firstIndex(where: { $0.seed == seed }) else { return }
        favorites[idx].characterID = characterID
        save()
    }

    /// Seeds favoritos de un personaje específico.
    func favorites(for characterID: UUID) -> [FavoriteSeed] {
        favorites.filter { $0.characterID == characterID }
    }

    // MARK: - Public API — Historial

    /// Registrar un seed en el historial de uso.
    func recordUsage(
        seed:       Int,
        promptHint: String = "",
        width:      Int    = 512,
        height:     Int    = 768
    ) {
        let entry = SeedHistoryEntry(
            seed:       seed,
            promptHint: promptHint,
            width:      width,
            height:     height
        )
        history.insert(entry, at: 0)

        // Limitar capacidad
        if history.count > historyCapacity {
            history = Array(history.prefix(historyCapacity))
        }

        save()
    }

    /// Incrementar contador de uso de un seed (si está en favoritos).
    func incrementUsage(seed: Int) {
        guard seed > 0 else { return }   // Ignorar seed -1 (random)
        if let idx = favorites.firstIndex(where: { $0.seed == seed }) {
            favorites[idx].usageCount += 1
            save()
        }
    }

    // MARK: - Public API — Búsqueda y Filtros

    /// Seeds favoritos filtrados por personaje o query.
    func search(query: String, characterID: UUID? = nil) -> [FavoriteSeed] {
        var result = favorites

        if let charID = characterID {
            result = result.filter { $0.characterID == charID }
        }

        if !query.isEmpty {
            let q = query.lowercased()
            result = result.filter {
                $0.label.lowercased().contains(q) ||
                $0.promptHint.lowercased().contains(q) ||
                $0.tags.contains(where: { $0.lowercased().contains(q) }) ||
                String($0.seed).contains(q)
            }
        }

        return result
    }

    /// Top N seeds más usados.
    func topSeeds(count: Int = 10) -> [FavoriteSeed] {
        Array(
            favorites
                .sorted { $0.usageCount > $1.usageCount }
                .prefix(count)
        )
    }

    // MARK: - Export / Import

    /// Exportar todos los seeds como JSON auditeable.
    func exportJSON() -> Data? {
        let payload: [String: Any] = [
            "version":    "SeedManager.v1",
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "favorites":  (try? JSONEncoder.pretty.encode(favorites)).flatMap {
                try? JSONSerialization.jsonObject(with: $0)
            } ?? [],
            "historyCount": history.count
        ]
        return try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: - Persistence

    private func save() {
        guard let url = persistenceURL else { return }

        let payload = SeedRegistry(
            favorites: favorites,
            history:   history
        )

        if let data = try? JSONEncoder.pretty.encode(payload) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func load() {
        guard let url = persistenceURL,
              let data = try? Data(contentsOf: url),
              let registry = try? JSONDecoder.iso8601.decode(SeedRegistry.self, from: data)
        else { return }

        self.favorites = registry.favorites
        self.history   = registry.history
    }

    private var persistenceURL: URL? {
        VaultManager.shared.vaultMetaURL?.appending(path: "seeds_registry.json")
    }

    // MARK: - Internal types

    private struct SeedRegistry: Codable {
        var favorites: [FavoriteSeed]
        var history:   [SeedHistoryEntry]
    }
}

// MARK: - SeedPickerView
// Componente reutilizable para seleccionar un seed desde favoritos.
// Usar en el panel de settings del pipeline.

struct SeedPickerView: View {

    @Binding var selectedSeed: Int
    var characterID: UUID? = nil
    var onPick: ((Int) -> Void)? = nil

    @StateObject private var manager = SeedManager.shared
    @State private var query: String = ""
    @State private var showHistory = false

    var seeds: [SeedManager.FavoriteSeed] {
        manager.search(query: query, characterID: characterID)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Barra de búsqueda
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                TextField("Buscar seed…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                if !query.isEmpty {
                    Button(action: { query = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Button(action: { showHistory.toggle() }) {
                    Image(systemName: showHistory ? "clock.fill" : "clock")
                        .font(.system(size: 11))
                        .foregroundColor(showHistory ? Color(hex: "#7c6af7") : .secondary)
                }
                .buttonStyle(.plain)
                .help("Ver historial de seeds")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.05))
            .cornerRadius(6)
            .padding(.horizontal, 8)
            .padding(.top, 8)

            Divider().background(Color.white.opacity(0.06)).padding(.top, 6)

            if showHistory {
                historyList
            } else {
                favoritesList
            }
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    var favoritesList: some View {
        Group {
            if seeds.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "star.slash")
                        .font(.system(size: 24))
                        .foregroundColor(.white.opacity(0.15))
                    Text("Sin seeds favoritos")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(seeds) { fav in
                            seedRow(fav)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    var historyList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(manager.history.prefix(50)) { entry in
                    Button(action: {
                        selectedSeed = entry.seed
                        onPick?(entry.seed)
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "clock")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .frame(width: 16)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(entry.seed)")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(.white)
                                if !entry.promptHint.isEmpty {
                                    Text(entry.promptHint.truncated(40))
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            Text("\(entry.width)×\(entry.height)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary.opacity(0.6))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            selectedSeed == entry.seed
                                ? Color(hex: "#7c6af7").opacity(0.15)
                                : Color.clear
                        )
                        .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
    }

    func seedRow(_ fav: SeedManager.FavoriteSeed) -> some View {
        Button(action: {
            selectedSeed = fav.seed
            SeedManager.shared.incrementUsage(seed: fav.seed)
            onPick?(fav.seed)
        }) {
            HStack(spacing: 8) {
                Image(systemName: "star.fill")
                    .font(.system(size: 9))
                    .foregroundColor(.yellow.opacity(0.8))
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text("\(fav.seed)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.white)
                        if !fav.label.isEmpty && fav.label != "Seed \(fav.seed)" {
                            Text("· \(fav.label)")
                                .font(.system(size: 10))
                                .foregroundColor(Color(hex: "#7c6af7").opacity(0.8))
                        }
                    }
                    if !fav.promptHint.isEmpty {
                        Text(fav.promptHint.truncated(45))
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()

                // Uso count
                Text("×\(fav.usageCount)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.5))

                // Botón quitar favorito
                Button(action: { SeedManager.shared.removeFavorite(seed: fav.seed) }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary.opacity(0.4))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                selectedSeed == fav.seed
                    ? Color(hex: "#7c6af7").opacity(0.15)
                    : Color.clear
            )
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }
}
