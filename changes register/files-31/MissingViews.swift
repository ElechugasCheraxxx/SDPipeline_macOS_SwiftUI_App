import SwiftUI
import AppKit
import CoreImage

// MARK: - MissingViews v4
// Contiene:
//   • BatchRatingView — curador masivo (original)
//   • IPAdapterModel alias (puente al enum de IPAdapterEngine)
//   • CharacterProfile.baseImagePath helper (puente a UserDefaults)
//   • ZeroKnowledgeLogView compatibility shim
//   • CIImage init helper para steg verification

// MARK: - BatchRatingView (curador masivo rápido)

struct BatchRatingView: View {

    @StateObject private var store = AssetStore.shared
    @State private var assets:     [GeneratedAsset] = []
    @State private var currentIdx: Int = 0

    var currentAsset: GeneratedAsset? {
        assets.indices.contains(currentIdx) ? assets[currentIdx] : nil
    }

    var body: some View {
        VStack(spacing: 16) {
            if assets.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 32)).foregroundColor(Color(hex: "#34d399"))
                    Text("Todos los assets están calificados")
                        .font(.system(size: 13)).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let asset = currentAsset {
                // Progress
                Text("\(currentIdx + 1) / \(assets.count)")
                    .font(.system(size: 11)).foregroundColor(.secondary)

                // Image
                if let t = asset.thumbnail {
                    Image(nsImage: t).resizable().aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 300).cornerRadius(8)
                }

                // Prompt
                Text((asset.promptPositive ?? "").truncated(80))
                    .font(.system(size: 11)).foregroundColor(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: .infinity)

                // Rating buttons
                HStack(spacing: 12) {
                    ForEach(1...5, id: \.self) { r in
                        Button(action: { rate(r) }) {
                            VStack(spacing: 4) {
                                Image(systemName: "star.fill").font(.system(size: 18))
                                    .foregroundColor(ratingColor(r))
                                Text("\(r)").font(.system(size: 10, weight: .bold)).foregroundColor(.secondary)
                            }
                            .frame(width: 48, height: 48)
                            .background(ratingColor(r).opacity(0.1)).cornerRadius(8)
                        }.buttonStyle(.plain)
                    }
                }

                HStack(spacing: 16) {
                    Button("Saltar") { next() }.buttonStyle(.plain)
                        .font(.system(size: 11)).foregroundColor(.secondary)
                    Button("Rechazar") {
                        AssetStore.shared.updateStatus(asset, status: .rejected)
                        next()
                    }.buttonStyle(.plain)
                        .font(.system(size: 11)).foregroundColor(Color(hex: "#ef4444"))
                }
            }
        }
        .padding(20)
        .onAppear { loadUnrated() }
    }

    private func loadUnrated() {
        assets = store.fetchAllAssets(limit: 200).filter { $0.rating == 0 }
        currentIdx = 0
    }

    private func rate(_ rating: Int) {
        guard let asset = currentAsset else { return }
        store.updateRating(asset, rating: rating)
        if rating >= 4 { store.updateStatus(asset, status: .approved) }
        next()
    }

    private func next() {
        if currentIdx + 1 < assets.count { currentIdx += 1 }
        else { assets = [] }
    }

    private func ratingColor(_ r: Int) -> Color {
        switch r {
        case 5: return Color(hex: "#34d399")
        case 4: return Color(hex: "#3de3c0")
        case 3: return Color(hex: "#fbbf24")
        case 2: return Color(hex: "#f97316")
        default: return Color(hex: "#ef4444")
        }
    }
}

// MARK: - IPAdapterModel typealias
// Puente para archivos que referencian IPAdapterModel directamente.

typealias IPAdapterModel = IPAdapterEngine.IPAdapterModel

// MARK: - CIImage steg helper

extension CIImage {
    init?(nsImage: NSImage) {
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

// MARK: - GeneratedAsset display helpers

extension GeneratedAsset {
    var displayTitle: String {
        baseName ?? id?.uuidString.prefix(8).description ?? "Asset"
    }
}

// MARK: - String truncation helper

extension String {
    func truncated(_ length: Int) -> String {
        count > length ? String(prefix(length)) + "…" : self
    }
}
