import SwiftUI
import AppKit

// MARK: - MissingViews.swift v3
//
// ❌ ELIMINADO — ya existen en otros archivos:
//   • AssetInspectorView       → GalleryView.swift:441
//   • RatingCuratorView        → GalleryView.swift:640  (toma `asset: GeneratedAsset`)
//   • JobQueueView             → JobQueueManager.swift:389
//   • StudioPublishView        → PublishView.swift:11
//   • NewSessionSheet          → ContentView.swift:626
//
//   • ContentSessionManager.SessionCategory    → nested en ContentSession (ya tiene .icon)
//   • ContentSessionManager.TargetPlatform     → nested en ContentSession (ya tiene .icon)
//
// ✅ ESTE ARCHIVO SOLO CONTIENE:
//   • BatchRatingView — modo curador masivo, no existe en ningún original

// MARK: - BatchRatingView

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
                        .font(.system(size: 32))
                        .foregroundColor(Color(hex: "#34d399"))
                    Text("Todos los assets están calificados")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let asset = currentAsset {
                if let t = asset.thumbnail {
                    Image(nsImage: t)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 300)
                        .cornerRadius(8)
                }

                Text((asset.promptPositive ?? "").truncated(80))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)

                HStack(spacing: 12) {
                    ForEach(1...5, id: \.self) { r in
                        Button(action: { rate(r) }) {
                            VStack(spacing: 4) {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 18))
                                    .foregroundColor(ratingColor(r))
                                Text("\(r)")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.secondary)
                            }
                            .frame(width: 48, height: 48)
                            .background(ratingColor(r).opacity(0.1))
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Button("Saltar") { next() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                Text("\(currentIdx + 1) de \(assets.count) sin calificar")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .padding(20)
        .onAppear { loadUnrated() }
    }

    private func loadUnrated() {
        assets = store.fetchAllAssets(limit: 200).filter { $0.rating == 0 }
        currentIdx = 0
    }
    private func rate(_ r: Int) {
        guard let asset = currentAsset else { return }
        store.updateRating(asset, rating: r)
        next()
    }
    private func next() {
        if currentIdx + 1 < assets.count { currentIdx += 1 } else { loadUnrated() }
    }
    private func ratingColor(_ r: Int) -> Color {
        [1: "#6b7280", 2: "#f97316", 3: "#fbbf24", 4: "#34d399", 5: "#7c6af7"][r]
            .map { Color(hex: $0) } ?? .gray
    }
}
