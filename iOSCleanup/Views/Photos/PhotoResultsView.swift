import SwiftUI
import Photos

struct PhotoResultsView: View {
    let groups: [PhotoGroup]
    @EnvironmentObject private var purchaseManager: PurchaseManager

    @State private var selectedGroups = Set<UUID>()
    @State private var isSelectMode = false
    @State private var showPaywall = false
    @State private var showSwipeMode = false
    @State private var deletionError: String?

    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        Group {
            if groups.isEmpty {
                EmptyStateView(title: "No Duplicates Found", icon: "photo.on.rectangle.angled", message: "Your photo library looks clean.")
            } else {
                ScrollView {
                    if let error = deletionError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal)
                    }
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(groups) { group in
                            NavigationLink(destination: PhotoGroupDetailView(group: group)) {
                                GroupThumbnail(
                                    group: group,
                                    isSelected: selectedGroups.contains(group.id),
                                    isSelectMode: isSelectMode
                                )
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Similar Photos")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button("Swipe") { showSwipeMode = true }
                    .font(.subheadline)

                if isSelectMode {
                    Button("Delete (\(selectedGroups.count))") {
                        guard purchaseManager.isPurchased else { showPaywall = true; return }
                        Task { await bulkDelete() }
                    }
                    .disabled(selectedGroups.isEmpty)
                    .tint(.red)
                } else {
                    Button(purchaseManager.isPurchased ? "Select" : "Select 🔒") {
                        guard purchaseManager.isPurchased else { showPaywall = true; return }
                        isSelectMode = true
                    }
                }
            }
            if isSelectMode {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isSelectMode = false
                        selectedGroups.removeAll()
                    }
                }
            }
        }
        .sheet(isPresented: $showPaywall) { PaywallView() }
        .fullScreenCover(isPresented: $showSwipeMode) {
            SwipeModeView(groups: groups)
        }
        .onReceive(NotificationCenter.default.publisher(for: .purchaseDidSucceed)) { _ in
            showPaywall = false
        }
    }

    private func bulkDelete() async {
        // Collect all non-first assets from selected groups (keep best = first)
        let toDelete = groups
            .filter { selectedGroups.contains($0.id) }
            .flatMap { Array($0.assets.dropFirst()) }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(toDelete as NSFastEnumeration)
            }
            selectedGroups.removeAll()
            isSelectMode = false
        } catch {
            deletionError = error.localizedDescription
        }
    }
}

// MARK: - Group thumbnail tile

private struct GroupThumbnail: View {
    let group: PhotoGroup
    let isSelected: Bool
    let isSelectMode: Bool

    @State private var thumbnail: UIImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let img = thumbnail {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.gray.opacity(0.2)
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fill)
            .clipped()

            // Badge: count
            Text("\(group.assets.count)")
                .font(.caption2.bold())
                .padding(4)
                .background(.black.opacity(0.6))
                .foregroundStyle(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .padding(4)

            // Select indicator
            if isSelectMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .blue : .white)
                    .font(.title3)
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
        .task {
            thumbnail = await loadThumbnail(for: group.assets.first)
        }
    }

    private func loadThumbnail(for asset: PHAsset?) async -> UIImage? {
        guard let asset else { return nil }
        return await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .fastFormat
            options.isNetworkAccessAllowed = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 200, height: 200),
                contentMode: .aspectFill,
                options: options
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }
}
