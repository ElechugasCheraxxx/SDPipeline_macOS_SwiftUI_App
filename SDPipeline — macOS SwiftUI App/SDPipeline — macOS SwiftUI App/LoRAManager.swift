import Foundation
import AppKit
import SwiftUI
import Combine

// MARK: - LoRAManager
// LoRAEntry and SelectedLoRA are defined in Models.swift (single source of truth)

@MainActor
final class LoRAManager: ObservableObject {

    static let shared = LoRAManager()
    private init() { loadFavorites() }

    // MARK: - Published State

    @Published var availableLoRAs:  [LoRAEntry]    = []
    @Published var selectedLoRAs:   [SelectedLoRA] = []
    @Published var isLoading:       Bool           = false
    @Published var error:           String?        = nil
    @Published var searchText:      String         = ""
    @Published var filterFavorites: Bool           = false

    // Persisted favorites (lora.name)
    @Published private(set) var favorites: Set<String> = []

    private var baseURL: String = "http://127.0.0.1:7860"
    private let favoritesKey   = "loramanager.favorites.v1"

    // MARK: - Configuration

    func configure(baseURL: String) {
        self.baseURL = baseURL
    }

    // MARK: - Fetch from A1111 API

    func fetchLoRAs() async {
        isLoading = true
        error     = nil

        guard let url = URL(string: "\(baseURL)/sdapi/v1/loras") else {
            error     = "URL inválida: \(baseURL)"
            isLoading = false
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            var loras     = try JSONDecoder().decode([LoRAEntry].self, from: data)

            // Ordenar: favoritos primero, luego alfabético por displayName
            loras.sort {
                let aFav = favorites.contains($0.name)
                let bFav = favorites.contains($1.name)
                if aFav != bFav { return aFav }
                return $0.displayName.lowercased() < $1.displayName.lowercased()
            }

            availableLoRAs = loras

        } catch {
            self.error = "Error: \(error.localizedDescription)"
        }

        isLoading = false
    }

    // MARK: - Selection

    func selectLoRA(_ lora: LoRAEntry, weight: Double = 0.8) {
        guard !selectedLoRAs.contains(where: { $0.lora.name == lora.name }) else { return }
        selectedLoRAs.append(SelectedLoRA(lora: lora, weight: weight))
    }

    func removeLoRA(id: UUID) {
        selectedLoRAs.removeAll { $0.id == id }
    }

    func updateWeight(id: UUID, weight: Double) {
        guard let idx = selectedLoRAs.firstIndex(where: { $0.id == id }) else { return }
        selectedLoRAs[idx].weight = weight
    }

    func clearSelection() {
        selectedLoRAs.removeAll()
    }

    var isSelected: (_ lora: LoRAEntry) -> Bool {
        { [weak self] lora in
            self?.selectedLoRAs.contains(where: { $0.lora.name == lora.name }) ?? false
        }
    }

    // MARK: - Prompt Injection

    /// Tokens para añadir al final del prompt positivo.
    var promptTokens: String {
        selectedLoRAs.map { $0.promptToken }.joined(separator: " ")
    }

    /// Inyectar tokens LoRA en el prompt dado.
    func inject(into prompt: String) -> String {
        guard !selectedLoRAs.isEmpty else { return prompt }
        return "\(prompt) \(promptTokens)"
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Favorites

    func toggleFavorite(_ lora: LoRAEntry) {
        if favorites.contains(lora.name) {
            favorites.remove(lora.name)
        } else {
            favorites.insert(lora.name)
        }
        // Re-sort para reflejar cambio
        availableLoRAs.sort {
            let aFav = favorites.contains($0.name)
            let bFav = favorites.contains($1.name)
            if aFav != bFav { return aFav }
            return $0.displayName.lowercased() < $1.displayName.lowercased()
        }
        saveFavorites()
    }

    func isFavorite(_ lora: LoRAEntry) -> Bool { favorites.contains(lora.name) }

    private func saveFavorites() {
        UserDefaults.standard.set(Array(favorites), forKey: favoritesKey)
    }

    private func loadFavorites() {
        let saved = UserDefaults.standard.stringArray(forKey: favoritesKey) ?? []
        favorites = Set(saved)
    }

    // MARK: - Filtered List

    var filteredLoRAs: [LoRAEntry] {
        var list = availableLoRAs

        if filterFavorites {
            list = list.filter { favorites.contains($0.name) }
        }

        if !searchText.isEmpty {
            let q = searchText.lowercased()
            list = list.filter {
                $0.displayName.lowercased().contains(q) ||
                $0.name.lowercased().contains(q)   ||
                (($0.metadata?.tags?.first)?.lowercased().contains(q) ?? false)
            }
        }

        return list
    }

    var selectedWeight: (_ id: UUID) -> Double {
        { [weak self] id in
            self?.selectedLoRAs.first(where: { $0.id == id })?.weight ?? 0.8
        }
    }
}

// MARK: - LoRAManagerView

struct LoRAManagerView: View {

    @ObservedObject var manager  = LoRAManager.shared
    @State private var expanded  = true

    var body: some View {
        VStack(spacing: 0) {

            // ── Header colapsable ──────────────────────────────────────
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } }) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#7c6af7"))
                    Text("LoRA Manager")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)

                    if !manager.selectedLoRAs.isEmpty {
                        Text("\(manager.selectedLoRAs.count) activos")
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "#3de3c0"))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color(hex: "#3de3c0").opacity(0.12))
                            .cornerRadius(4)
                    }

                    Spacer()

                    // Refresh
                    Button(action: { Task { await manager.fetchLoRAs() } }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .rotationEffect(
                                .degrees(manager.isLoading ? 360 : 0)
                            )
                            .animation(
                                manager.isLoading
                                    ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                                    : .default,
                                value: manager.isLoading
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Recargar LoRAs desde A1111")

                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Color.white.opacity(0.03))
            }
            .buttonStyle(.plain)

            if expanded {
                Divider().background(Color.white.opacity(0.06))

                // ── Search + Favorites filter ──────────────────────────
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    TextField("Buscar LoRA…", text: $manager.searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundColor(.white)
                    if !manager.searchText.isEmpty {
                        Button(action: { manager.searchText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }.buttonStyle(.plain)
                    }
                    Divider().frame(height: 14).background(Color.white.opacity(0.1))
                    Button(action: { manager.filterFavorites.toggle() }) {
                        Image(systemName: manager.filterFavorites ? "star.fill" : "star")
                            .font(.system(size: 11))
                            .foregroundColor(manager.filterFavorites ? .yellow : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(manager.filterFavorites ? "Mostrar todos" : "Solo favoritos")
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.white.opacity(0.04))

                Divider().background(Color.white.opacity(0.05))

                // ── Lista disponibles ──────────────────────────────────
                loraList

                // ── Panel activos ──────────────────────────────────────
                if !manager.selectedLoRAs.isEmpty {
                    Divider().background(Color.white.opacity(0.07))
                    activePanel
                }

                // Error
                if let err = manager.error {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 10))
                            .foregroundColor(.yellow)
                        Text(err)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                }
            }
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.115))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.07), lineWidth: 1))
        .task {
            if manager.availableLoRAs.isEmpty {
                await manager.fetchLoRAs()
            }
        }
    }

    // MARK: - LoRA List

    @ViewBuilder
    var loraList: some View {
        if manager.isLoading {
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.65)
                Text("Cargando LoRAs…")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)

        } else if manager.filteredLoRAs.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "sparkles.slash")
                    .font(.system(size: 24))
                    .foregroundColor(.white.opacity(0.1))
                Text(manager.availableLoRAs.isEmpty
                     ? "Sin LoRAs.\nVerifica que A1111 esté online."
                     : "Sin resultados para \"\(manager.searchText)\"")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)

        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(manager.filteredLoRAs) { lora in
                        LoRARowView(lora: lora)
                        if lora != manager.filteredLoRAs.last {
                            Divider()
                                .background(Color.white.opacity(0.04))
                                .padding(.leading, 32)
                        }
                    }
                }
            }
            .frame(maxHeight: 200) // Scroll contenido — no ocupa toda la pantalla
        }
    }

    // MARK: - Active LoRAs Panel

    var activePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Activos")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
                Spacer()
                Button("Limpiar todo") { manager.clearSelection() }
                    .font(.system(size: 10))
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
            }

            ForEach(manager.selectedLoRAs) { selected in
                HStack(spacing: 8) {
                    // Nombre
                    Text(selected.lora.displayName)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(Color(hex: "#7c6af7"))
                        .lineLimit(1)
                        .frame(maxWidth: 100, alignment: .leading)

                    // Weight slider
                    Slider(
                        value: Binding(
                            get: { selected.weight },
                            set: { manager.updateWeight(id: selected.id, weight: $0) }
                        ),
                        in: 0.0...1.5,
                        step: 0.05
                    )
                    .tint(
                        selected.weight > 1.0
                            ? .yellow
                            : Color(hex: "#3de3c0")
                    )

                    // Valor
                    Text(String(format: "%.2f", selected.weight))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(
                            selected.weight > 1.0
                                ? .yellow
                                : .secondary
                        )
                        .frame(width: 30, alignment: .trailing)

                    // Eliminar
                    Button(action: { manager.removeLoRA(id: selected.id) }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Preview del token que se inyectará al prompt
            if !manager.promptTokens.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Tokens a inyectar:")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text(manager.promptTokens)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Color(hex: "#3de3c0").opacity(0.85))
                        .lineLimit(3)
                        .padding(8)
                        .background(Color.black.opacity(0.25))
                        .cornerRadius(6)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.025))
    }
}

// MARK: - LoRARowView

struct LoRARowView: View {

    let lora: LoRAEntry
    @ObservedObject var manager = LoRAManager.shared
    @State private var hovered  = false

    var isSelected: Bool { manager.selectedLoRAs.contains(where: { $0.lora.name == lora.name }) }
    var isFav: Bool { manager.isFavorite(lora) }

    var body: some View {
        HStack(spacing: 10) {
            // Status dot
            Circle()
                .fill(isSelected ? Color(hex: "#7c6af7") : Color.white.opacity(0.15))
                .frame(width: 6, height: 6)

            // Info
            VStack(alignment: .leading, spacing: 1) {
                Text(lora.displayName)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? .white : Color.white.opacity(0.75))
                    .lineLimit(1)

                if let base = lora.metadata?.tags?.first {
                    Text(base)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // Favorite toggle
            Button(action: { manager.toggleFavorite(lora) }) {
                Image(systemName: isFav ? "star.fill" : "star")
                    .font(.system(size: 10))
                    .foregroundColor(isFav ? .yellow : Color.secondary.opacity(hovered ? 0.8 : 0))
            }
            .buttonStyle(.plain)

            // Add / Remove
            Button(action: {
                if isSelected {
                    if let sel = manager.selectedLoRAs.first(where: { $0.lora.name == lora.name }) {
                        manager.removeLoRA(id: sel.id)
                    }
                } else {
                    manager.selectLoRA(lora)
                }
            }) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 15))
                    .foregroundColor(isSelected ? Color(hex: "#3de3c0") : Color.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(
            isSelected
                ? Color(hex: "#7c6af7").opacity(0.07)
                : hovered
                    ? Color.white.opacity(0.035)
                    : Color.clear
        )
        .onHover { hovered = $0 }
    }
}
