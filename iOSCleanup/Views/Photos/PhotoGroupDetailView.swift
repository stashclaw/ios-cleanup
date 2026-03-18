import SwiftUI
import Photos

struct PhotoGroupDetailView: View {
    let group: PhotoGroup
    @EnvironmentObject private var purchaseManager: PurchaseManager
    @Environment(\.dismiss) private var dismiss

    @State private var images: [PHAsset: UIImage] = [:]
    @State private var selectedAssets = Set<String>()  // localIdentifiers to delete
    @State private var showPaywall = false
    @State private var deleteError: String?
    @State private var isDeleting = false
    @State private var isDeleted = false

    var body: some View {
        Group {
            if isDeleted {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.green)
                    Text("Cleaned!")
                        .font(.title2.bold())
                    Spacer()
                }
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        reasonBadge
                        assetGrid
                        actionButtons
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("Photo Group")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPaywall) { PaywallView() }
        .task { await loadImages() }
        .onReceive(NotificationCenter.default.publisher(for: .purchaseDidSucceed)) { _ in
            showPaywall = false
        }
    }

    // MARK: - Sub-views

    private var reasonBadge: some View {
        HStack {
            Image(systemName: badgeIcon)
            Text(badgeLabel)
        }
        .font(.caption.bold())
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(badgeColor.opacity(0.15))
        .foregroundStyle(badgeColor)
        .clipShape(Capsule())
    }

    private var assetGrid: some View {
        let columns = [GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(group.assets, id: \.localIdentifier) { asset in
                AssetCompareCell(
                    asset: asset,
                    image: images[asset],
                    isBest: asset.localIdentifier == group.assets.first?.localIdentifier,
                    isSelected: selectedAssets.contains(asset.localIdentifier),
                    onTap: {
                        guard purchaseManager.isPurchased else { showPaywall = true; return }
                        if selectedAssets.contains(asset.localIdentifier) {
                            selectedAssets.remove(asset.localIdentifier)
                        } else {
                            selectedAssets.insert(asset.localIdentifier)
                        }
                    }
                )
            }
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 12) {
            if let error = deleteError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            // Keep Best — free
            Button(action: keepBest) {
                Label("Keep Best, Delete Others", systemImage: "star.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.orange)
                    .foregroundStyle(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .disabled(isDeleting)

            // Select & Delete — paid
            Button(action: {
                guard purchaseManager.isPurchased else { showPaywall = true; return }
                Task { await deleteSelected() }
            }) {
                Label(
                    selectedAssets.isEmpty
                        ? (purchaseManager.isPurchased ? "Select photos above to delete" : "Select & Delete 🔒")
                        : "Delete \(selectedAssets.count) Selected",
                    systemImage: "trash"
                )
                .font(.subheadline)
                .frame(maxWidth: .infinity)
                .padding()
                .background(selectedAssets.isEmpty ? Color.secondary.opacity(0.15) : Color.red)
                .foregroundStyle(selectedAssets.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.white))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .disabled(isDeleting || (purchaseManager.isPurchased && selectedAssets.isEmpty))
        }
    }

    // MARK: - Actions

    private func keepBest() {
        // Keep first (oldest = best keeper per spec), delete all others — free action
        let toDelete = Array(group.assets.dropFirst())
        Task {
            isDeleting = true
            defer { isDeleting = false }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.deleteAssets(toDelete as NSFastEnumeration)
                }
                isDeleted = true
            } catch {
                deleteError = error.localizedDescription
            }
        }
    }

    private func deleteSelected() async {
        isDeleting = true
        defer { isDeleting = false }
        let toDelete = group.assets.filter { selectedAssets.contains($0.localIdentifier) }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(toDelete as NSFastEnumeration)
            }
            if selectedAssets.count == group.assets.count { isDeleted = true }
            selectedAssets.removeAll()
        } catch {
            deleteError = error.localizedDescription
        }
    }

    private func loadImages() async {
        for asset in group.assets {
            let img = await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
                let options = PHImageRequestOptions()
                options.deliveryMode = .opportunistic
                options.isNetworkAccessAllowed = true
                PHImageManager.default().requestImage(
                    for: asset,
                    targetSize: CGSize(width: 400, height: 400),
                    contentMode: .aspectFit,
                    options: options
                ) { image, _ in continuation.resume(returning: image) }
            }
            if let img { images[asset] = img }
        }
    }

    // MARK: - Reason badge helpers

    private var badgeIcon: String {
        switch group.reason {
        case .nearDuplicate: return "doc.on.doc.fill"
        case .visuallySimilar: return "eye.fill"
        case .burstShot: return "burst.fill"
        }
    }

    private var badgeLabel: String {
        switch group.reason {
        case .nearDuplicate: return "Near Duplicate"
        case .visuallySimilar: return "Visually Similar"
        case .burstShot: return "Burst Shot"
        }
    }

    private var badgeColor: Color {
        switch group.reason {
        case .nearDuplicate: return .red
        case .visuallySimilar: return .orange
        case .burstShot: return .purple
        }
    }
}

// MARK: - Asset compare cell

private struct AssetCompareCell: View {
    let asset: PHAsset
    let image: UIImage?
    let isBest: Bool
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let img = image {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color.gray.opacity(0.2)
                            .overlay(ProgressView())
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fill)
                .clipped()
                .overlay(isSelected ? Color.red.opacity(0.3) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 0)
                        .strokeBorder(isSelected ? Color.red : Color.clear, lineWidth: 3)
                )

                if isBest {
                    Text("BEST")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.green)
                        .foregroundStyle(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .padding(6)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

