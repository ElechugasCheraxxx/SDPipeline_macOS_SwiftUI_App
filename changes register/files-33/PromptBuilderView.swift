import SwiftUI
import AppKit
import Combine

// MARK: - PromptBuilderView
//
// Editor visual de prompts para Stable Diffusion.
// Features:
//   • Bloques de prompt por categoría (sujeto, estilo, iluminación, etc.)
//   • Drag-and-drop para reordenar bloques
//   • Autocompletado desde base de datos de tokens SD
//   • Peso por bloque (emphasis con paréntesis)
//   • Preview del prompt final ensamblado
//   • Guardar/cargar desde PromptVersioningStore
//   • Wildcards integrados
//   • Clipboard del historial de prompts exitosos
//
// ROADMAP: "Prompt Builder drag-and-drop" + "Editor avanzado con autocompletado" (🟡 MEDIO PLAZO)

// MARK: - Prompt Block Model

struct PromptBlock: Identifiable, Codable, Equatable {
    var id:       UUID    = UUID()
    var category: BlockCategory
    var text:     String
    var weight:   Double  = 1.0   // 1.0 = sin énfasis, 1.3 = (texto:1.3)
    var enabled:  Bool    = true

    enum BlockCategory: String, CaseIterable, Codable {
        case subject     = "Sujeto"
        case style       = "Estilo"
        case lighting    = "Iluminación"
        case environment = "Entorno"
        case quality     = "Calidad"
        case camera      = "Cámara"
        case color       = "Color"
        case mood        = "Mood"
        case lora        = "LoRA"
        case custom      = "Custom"

        var color: Color {
            switch self {
            case .subject:     return Color(hex: "#7c6af7")
            case .style:       return Color(hex: "#3de3c0")
            case .lighting:    return Color(hex: "#fbbf24")
            case .environment: return Color(hex: "#34d399")
            case .quality:     return Color(hex: "#60a5fa")
            case .camera:      return Color(hex: "#f472b6")
            case .color:       return Color(hex: "#fb923c")
            case .mood:        return Color(hex: "#a78bfa")
            case .lora:        return Color(hex: "#94a3b8")
            case .custom:      return Color(hex: "#6b7280")
            }
        }

        var icon: String {
            switch self {
            case .subject:     return "person.fill"
            case .style:       return "paintbrush.fill"
            case .lighting:    return "light.max"
            case .environment: return "mountain.2.fill"
            case .quality:     return "star.fill"
            case .camera:      return "camera.fill"
            case .color:       return "circle.hexagongrid.fill"
            case .mood:        return "heart.fill"
            case .lora:        return "cpu.fill"
            case .custom:      return "ellipsis.circle.fill"
            }
        }

        var suggestions: [String] {
            switch self {
            case .subject:
                return ["beautiful woman", "man", "girl", "boy", "couple",
                        "model", "athlete", "portrait", "solo", "multiple girls"]
            case .style:
                return ["photorealistic", "cinematic", "oil painting", "watercolor",
                        "anime", "digital art", "illustration", "photography",
                        "hyperrealistic", "3d render", "unreal engine"]
            case .lighting:
                return ["soft lighting", "dramatic lighting", "studio lighting",
                        "golden hour", "rim lighting", "backlight", "neon lights",
                        "candlelight", "chiaroscuro", "butterfly lighting", "Rembrandt lighting"]
            case .environment:
                return ["outdoor", "indoor", "beach", "forest", "city", "studio",
                        "bedroom", "kitchen", "rooftop", "garden", "ocean", "desert"]
            case .quality:
                return ["masterpiece", "best quality", "high quality", "ultra detailed",
                        "8k", "4k", "hdr", "raw photo", "sharp focus", "award winning photography"]
            case .camera:
                return ["portrait lens", "wide angle", "macro", "telephoto",
                        "35mm", "85mm", "50mm", "f/1.8", "f/2.8", "shallow depth of field",
                        "bokeh", "shot on Canon EOS R5", "shot on Sony A7III"]
            case .color:
                return ["vibrant colors", "muted tones", "black and white", "monochrome",
                        "warm tones", "cool tones", "pastel", "dark moody colors", "golden tones"]
            case .mood:
                return ["cheerful", "melancholic", "mysterious", "romantic", "dramatic",
                        "peaceful", "energetic", "sensual", "ethereal", "confident"]
            case .lora:
                return []  // Se rellena dinámicamente desde LoRAManager
            case .custom:
                return []
            }
        }
    }

    /// Texto con énfasis aplicado según el peso.
    var emphasizedText: String {
        guard enabled && !text.isEmpty else { return "" }
        if abs(weight - 1.0) < 0.01 { return text }
        let formatted = String(format: "%.1f", weight)
        return "(\(text):\(formatted))"
    }
}

// MARK: - PromptBuilderViewModel

@MainActor
final class PromptBuilderViewModel: ObservableObject {

    @Published var positiveBlocks: [PromptBlock] = []
    @Published var negativeBlocks: [PromptBlock] = []
    @Published var wildcardEngine: WildcardEngine = .shared

    // Assembled prompts
    var assembledPositive: String {
        positiveBlocks
            .filter { $0.enabled }
            .map { $0.emphasizedText }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    var assembledNegative: String {
        negativeBlocks
            .filter { $0.enabled }
            .map { $0.emphasizedText }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    // MARK: - Block operations

    func addBlock(category: PromptBlock.BlockCategory, text: String = "", isNegative: Bool = false) {
        let block = PromptBlock(category: category, text: text)
        if isNegative { negativeBlocks.append(block) }
        else           { positiveBlocks.append(block) }
    }

    func removeBlock(_ block: PromptBlock, isNegative: Bool = false) {
        if isNegative { negativeBlocks.removeAll { $0.id == block.id } }
        else           { positiveBlocks.removeAll { $0.id == block.id } }
    }

    func moveBlock(from source: IndexSet, to destination: Int, isNegative: Bool = false) {
        if isNegative { negativeBlocks.move(fromOffsets: source, toOffset: destination) }
        else           { positiveBlocks.move(fromOffsets: source, toOffset: destination) }
    }

    // MARK: - Presets

    func applyQualityPreset() {
        let qualityTokens = ["masterpiece", "best quality", "ultra detailed", "sharp focus", "8k uhd"]
        for token in qualityTokens {
            if !positiveBlocks.contains(where: { $0.text.contains(token) }) {
                positiveBlocks.append(PromptBlock(category: .quality, text: token, weight: 1.1))
            }
        }
        let negQuality = ["lowres", "bad anatomy", "bad hands", "text", "error", "missing fingers",
                          "extra digit", "fewer digits", "cropped", "worst quality", "low quality",
                          "normal quality", "jpeg artifacts", "signature", "watermark", "username", "blurry"]
        for token in negQuality {
            if !negativeBlocks.contains(where: { $0.text == token }) {
                negativeBlocks.append(PromptBlock(category: .quality, text: token))
            }
        }
    }

    func applyPhotographyPreset() {
        let blocks: [(PromptBlock.BlockCategory, String, Double)] = [
            (.quality,  "RAW photo",            1.1),
            (.camera,   "85mm portrait lens",   1.0),
            (.camera,   "shallow depth of field", 1.0),
            (.lighting, "professional studio lighting", 1.0),
            (.quality,  "photorealistic",       1.2),
        ]
        for (cat, text, weight) in blocks {
            positiveBlocks.append(PromptBlock(category: cat, text: text, weight: weight))
        }
    }

    func clear() {
        positiveBlocks = []
        negativeBlocks = []
    }

    func loadFromVersion(_ version: PromptVersioningStore.PromptVersion) {
        clear()
        // Parsear prompt positivo en bloques por comas
        let posTokens = version.positive.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        for token in posTokens where !token.isEmpty {
            positiveBlocks.append(PromptBlock(category: .custom, text: token))
        }
        let negTokens = version.negative.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        for token in negTokens where !token.isEmpty {
            negativeBlocks.append(PromptBlock(category: .quality, text: token))
        }
    }
}

// MARK: - PromptBuilderView

struct PromptBuilderView: View {

    @StateObject private var vm            = PromptBuilderViewModel()
    @StateObject private var versionStore  = PromptVersioningStore.shared
    @StateObject private var wildcards     = WildcardEngine.shared
    @StateObject private var autocomplete  = PromptAutoCompleteEngine.shared   // ← NEW

    @Binding var positivePrompt: String
    @Binding var negativePrompt: String

    @State private var showNegative      = true
    @State private var draggedBlock:     PromptBlock?
    @State private var autoSuggest:      [String] = []
    @State private var suggestField:     String   = ""
    @State private var suggestCategory:  PromptBlock.BlockCategory = .custom
    @State private var showVersionPicker  = false
    @State private var showWildcardPicker = false
    @State private var showACOverlay      = false   // autocompletado overlay

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ─────────────────────────────────────────────────
            headerBar

            // ── Assembled Preview ───────────────────────────────────────
            promptPreview

            // ── Positive Blocks ─────────────────────────────────────────
            blockSection(title: "Positivo", blocks: $vm.positiveBlocks, isNegative: false)

            // ── Negative Blocks ─────────────────────────────────────────
            if showNegative {
                Divider().background(Color.white.opacity(0.08))
                blockSection(title: "Negativo", blocks: $vm.negativeBlocks, isNegative: true)
            }

            // ── Add Block Bar + Autocomplete Overlay ────────────────────
            ZStack(alignment: .bottomLeading) {
                addBlockBar

                // Autocomplete suggestions overlay
                if showACOverlay && !autocomplete.suggestions.isEmpty {
                    autocompleteOverlay
                        .offset(y: -38)
                }
            }
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
        .cornerRadius(10)
        .onChange(of: vm.assembledPositive) { _, v in positivePrompt = v }
        .onChange(of: vm.assembledNegative) { _, v in negativePrompt = v }
        .sheet(isPresented: $showVersionPicker)  { versionPickerSheet  }
        .sheet(isPresented: $showWildcardPicker) { wildcardPickerSheet }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "#7c6af7"))
            Text("Prompt Builder")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)

            Spacer()

            Button("Calidad") { vm.applyQualityPreset() }
                .buttonStyle(MiniChipStyle())
            Button("Foto") { vm.applyPhotographyPreset() }
                .buttonStyle(MiniChipStyle())
            Button("Versiones") { showVersionPicker = true }
                .buttonStyle(MiniChipStyle())
            Button("Wildcards") { showWildcardPicker = true }
                .buttonStyle(MiniChipStyle())
            Button("Limpiar") { vm.clear() }
                .buttonStyle(MiniChipStyle(color: Color(hex: "#ef4444").opacity(0.3)))

            Toggle("Neg.", isOn: $showNegative)
                .toggleStyle(.button)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.white.opacity(0.03))
    }

    // MARK: - Prompt Preview

    private var promptPreview: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(vm.assembledPositive.isEmpty ? "Prompt positivo vacío…" : vm.assembledPositive)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(vm.assembledPositive.isEmpty ? Color.secondary : Color.white.opacity(0.8))
                .lineLimit(3)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.04))
                .cornerRadius(6)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    // MARK: - Block Section

    private func blockSection(title: String, blocks: Binding<[PromptBlock]>, isNegative: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 12).padding(.top, 8)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 4) {
                    ForEach(blocks) { block in
                        PromptBlockRow(
                            block: block,
                            onDelete: { vm.removeBlock(block, isNegative: isNegative) },
                            onUpdate: { updated in
                                if let idx = blocks.wrappedValue.firstIndex(where: { $0.id == block.id }) {
                                    blocks.wrappedValue[idx] = updated
                                }
                            }
                        )
                        .padding(.horizontal, 10)
                    }
                    .onMove { from, to in vm.moveBlock(from: from, to: to, isNegative: isNegative) }
                }
            }
            .frame(maxHeight: 200)
        }
    }

    // MARK: - Autocomplete Overlay

    private var autocompleteOverlay: some View {
        VStack(spacing: 0) {
            // Index status bar
            if autocomplete.isIndexing {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.5)
                    Text("Indexando tokens SD…")
                        .font(.system(size: 9)).foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Color.white.opacity(0.04))
            }

            // Suggestions list
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(autocomplete.suggestions.prefix(8)) { token in
                        Button(action: { selectToken(token) }) {
                            HStack(spacing: 4) {
                                Image(systemName: token.category.icon)
                                    .font(.system(size: 8))
                                    .foregroundColor(Color(hex: token.category.color))
                                Text(token.text)
                                    .font(.system(size: 10))
                                    .foregroundColor(.white)
                                if autocomplete.config.showPostCounts, token.postCount > 0 {
                                    Text(token.postCount.compactFormatted)
                                        .font(.system(size: 8))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(Color(hex: "#7c6af7").opacity(0.25))
                            .cornerRadius(5)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
            }
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(red: 0.10, green: 0.10, blue: 0.14))
                    .shadow(color: .black.opacity(0.5), radius: 8, y: -3)
            )
        }
        .frame(maxWidth: .infinity)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.spring(response: 0.2), value: showACOverlay)
    }

    private func selectToken(_ token: PromptAutoCompleteEngine.Token) {
        vm.addBlock(category: suggestCategory, text: token.text)
        autocomplete.recordUsage(token)
        suggestField    = ""
        showACOverlay   = false
        autoSuggest     = []
        autocomplete.clearSuggestions()
    }

    // MARK: - Add Block Bar (v2 — wired to PromptAutoCompleteEngine)

    private var addBlockBar: some View {
        HStack(spacing: 6) {
            Picker("", selection: $suggestCategory) {
                ForEach(PromptBlock.BlockCategory.allCases, id: \.self) { cat in
                    Label(cat.rawValue, systemImage: cat.icon).tag(cat)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 120)
            .font(.system(size: 10))

            ZStack(alignment: .trailing) {
                TextField("Agregar token…", text: $suggestField)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(6)
                    .onSubmit { commitBlock() }
                    .onChange(of: suggestField) { _, text in
                        // 1. Sugerencias de categoría (locales)
                        autoSuggest = suggestCategory.suggestions.filter {
                            $0.lowercased().contains(text.lowercased()) && !text.isEmpty
                        }.prefix(4).map { $0 }

                        // 2. Autocompletado del índice SD (PromptAutoCompleteEngine)
                        if text.count >= autocomplete.config.minQueryLength {
                            autocomplete.query(text)
                            showACOverlay = true
                        } else {
                            autocomplete.clearSuggestions()
                            showACOverlay = false
                        }
                    }

                // Indicador indexando
                if autocomplete.isIndexing {
                    ProgressView()
                        .scaleEffect(0.4)
                        .padding(.trailing, 6)
                }
            }

            Button(action: commitBlock) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(Color(hex: "#7c6af7"))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Color.white.opacity(0.03))
    }

    private func commitBlock() {
        guard !suggestField.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        vm.addBlock(category: suggestCategory, text: suggestField)
        suggestField = ""
        autoSuggest  = []
    }

    // MARK: - Version Picker Sheet

    private var versionPickerSheet: some View {
        VStack(spacing: 0) {
            Text("Versiones de Prompt")
                .font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                .padding()
            Divider()
            List(versionStore.versions.prefix(30)) { version in
                Button {
                    vm.loadFromVersion(version)
                    showVersionPicker = false
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(version.title.isEmpty ? "(sin título)" : version.title)
                            .font(.system(size: 12, weight: .medium)).foregroundColor(.white)
                        Text(version.positive.prefix(80) + "…")
                            .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(2)
                    }
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
        .frame(width: 500, height: 400)
        .background(Color(red: 0.10, green: 0.10, blue: 0.13))
    }

    // MARK: - Wildcard Picker Sheet

    private var wildcardPickerSheet: some View {
        VStack(spacing: 0) {
            Text("Wildcards")
                .font(.system(size: 14, weight: .bold)).foregroundColor(.white).padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(wildcards.allKeys, id: \.self) { key in
                        HStack {
                            Text("__\(key)__")
                                .font(.system(size: 12, design: .monospaced)).foregroundColor(Color(hex: "#7c6af7"))
                            Spacer()
                            Text("\(wildcards.terms(for: key).count) términos")
                                .font(.system(size: 10)).foregroundColor(.secondary)
                            Button("Insertar") {
                                vm.addBlock(category: .custom, text: "__\(key)__")
                                showWildcardPicker = false
                            }
                            .buttonStyle(MiniChipStyle())
                        }
                        .padding(8).background(Color.white.opacity(0.04)).cornerRadius(6)
                    }
                }
                .padding()
            }
        }
        .frame(width: 460, height: 380)
        .background(Color(red: 0.10, green: 0.10, blue: 0.13))
    }
}

// MARK: - PromptBlockRow

struct PromptBlockRow: View {
    var block:    PromptBlock
    var onDelete: () -> Void
    var onUpdate: (PromptBlock) -> Void

    @State private var localBlock: PromptBlock
    init(block: PromptBlock, onDelete: @escaping () -> Void, onUpdate: @escaping (PromptBlock) -> Void) {
        self.block    = block
        self.onDelete = onDelete
        self.onUpdate = onUpdate
        _localBlock   = State(initialValue: block)
    }

    var body: some View {
        HStack(spacing: 6) {
            // Drag handle
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10))
                .foregroundColor(.secondary)

            // Category color chip
            Circle()
                .fill(localBlock.category.color)
                .frame(width: 8, height: 8)

            // Text field
            TextField("", text: $localBlock.text)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(.white)
                .onChange(of: localBlock.text) { _, _ in onUpdate(localBlock) }

            // Weight
            if abs(localBlock.weight - 1.0) > 0.01 {
                Text(String(format: "×%.1f", localBlock.weight))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(localBlock.category.color)
            }

            Stepper("", value: $localBlock.weight, in: 0.1...2.0, step: 0.05)
                .labelsHidden()
                .scaleEffect(0.65)
                .frame(width: 56)
                .onChange(of: localBlock.weight) { _, _ in onUpdate(localBlock) }

            // Enable toggle
            Toggle("", isOn: $localBlock.enabled)
                .toggleStyle(.switch).scaleEffect(0.65)
                .onChange(of: localBlock.enabled) { _, _ in onUpdate(localBlock) }

            // Delete
            Button(action: onDelete) {
                Image(systemName: "xmark").font(.system(size: 9)).foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(localBlock.enabled ? Color.white.opacity(0.05) : Color.clear)
        .cornerRadius(6)
        .opacity(localBlock.enabled ? 1.0 : 0.5)
    }
}

// MARK: - MiniChipStyle

struct MiniChipStyle: ButtonStyle {
    var color: Color = Color.white.opacity(0.08)
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10))
            .foregroundColor(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(configuration.isPressed ? color.opacity(1.4) : color)
            .cornerRadius(5)
    }
}
