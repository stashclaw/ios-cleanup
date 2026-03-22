import Photos
import SwiftUI

struct PhotoGroupDetailView: View {
    let group: PhotoGroup
    let groupIndex: Int
    let totalGroups: Int
    let onDeleteGroup: (() -> Void)?

    @EnvironmentObject private var purchaseManager: PurchaseManager
    @EnvironmentObject private var deletionManager: DeletionManager
    @Environment(\.dismiss) private var dismiss

    @State private var deleteSet: Set<String> = []
    @State private var images: [String: UIImage] = [:]
    @State private var fileSizes: [String: Int64] = [:]
    @State private var showPaywall = false
    @State private var isDeleting = false
    @State private var deleteError: String?

    init(group: PhotoGroup, groupIndex: Int = 0, totalGroups: Int = 1, onDeleteGroup: (() -> Void)? = nil) {
        self.group = group
        self.groupIndex = groupIndex
        self.totalGroups = totalGroups
        self.onDeleteGroup = onDeleteGroup
    }

    // MARK: - Computed

    private var keeperID: String? { group.assets.first?.localIdentifier }

    private var deleteSavings: Int64 {
        group.assets
            .filter { deleteSet.contains($0.localIdentifier) }
            .reduce(Int64(0)) { $0 + (fileSizes[$1.localIdentifier] ?? 3_670_016) }
    }

    private var actionSummary: String {
        guard !deleteSet.isEmpty else { return "Tap photos to mark for deletion" }
        let savings = ByteCountFormatter.string(fromByteCount: deleteSavings, countStyle: .file)
        return "Delete \(deleteSet.count) · Save \(savings)"
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2)],
                spacing: 2
            ) {
                ForEach(group.assets, id: \.localIdentifier) { asset in
                    photoCell(asset: asset)
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("Group \(groupIndex + 1) of \(totalGroups)")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            DuckBottomActionBar(
                summary: actionSummary,
                primaryLabel: isDeleting ? "Deleting…" : "Delete Selected",
                primaryEnabled: !deleteSet.isEmpty && !isDeleting,
                isPaid: !purchaseManager.isPurchased,
                onPrimary: { Task { await deleteSelected() } },
                onShowPaywall: { showPaywall = true }
            )
        }
        .task {
            // Auto-select all except first asset
            deleteSet = Set(group.assets.dropFirst().map(\.localIdentifier))
            // Load file sizes (synchronous)
            fileSizes = Dictionary(uniqueKeysWithValues: group.assets.map {
                ($0.localIdentifier, assetFileSize($0))
            })
            // Load images concurrently
            await loadAllImages()
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView().environmentObject(purchaseManager)
        }
        .onReceive(NotificationCenter.default.publisher(for: .purchaseDidSucceed)) { _ in
            showPaywall = false
        }
    }

    // MARK: - Photo cell

    @ViewBuilder
    private func photoCell(asset: PHAsset) -> some View {
        let inDelete = deleteSet.contains(asset.localIdentifier)

        ZStack(alignment: .bottom) {
            // Photo
            Group {
                if let img = images[asset.localIdentifier] {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.gray.opacity(0.25)
                        .overlay(ProgressView().tint(.white))
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fill)
            .clipped()

            // Delete overlay
            if inDelete {
                Color.red.opacity(0.35)
            }

            // Bottom size strip
            LinearGradient(
                colors: [.clear, .black.opacity(0.72)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 52)

            HStack(alignment: .bottom, spacing: 4) {
                Text(ByteCountFormatter.string(
                    fromByteCount: fileSizes[asset.localIdentifier] ?? 3_670_016,
                    countStyle: .file
                ))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))

                Spacer()

                Image(systemName: inDelete ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(inDelete ? Color.red : Color.green)
                    .shadow(radius: 2)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .aspectRatio(1, contentMode: .fill)
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture {
            if deleteSet.contains(asset.localIdentifier) {
                deleteSet.remove(asset.localIdentifier)
            } else {
                deleteSet.insert(asset.localIdentifier)
            }
        }
    }

    // MARK: - Actions

    private func deleteSelected() async {
        let assetsToDelete = group.assets.filter { deleteSet.contains($0.localIdentifier) }
        guard !assetsToDelete.isEmpty else { return }
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await deletionManager.delete(assets: assetsToDelete)
            _ = await PhotoFeedbackStore.shared.recordSimilarGroupDecision(
                group: group,
                kind: .deleteSelected,
                stage: .committed,
                selectedKeeperID: keeperID,
                deletedAssetIDs: Array(deleteSet),
                keptAssetIDs: group.assets
                    .map(\.localIdentifier)
                    .filter { !deleteSet.contains($0) },
                recommendationAccepted: true,
                note: "Grid delete from detail view"
            )
            onDeleteGroup?()
            dismiss()
        } catch {
            deleteError = error.localizedDescription
        }
    }

    // MARK: - Image loading

    private func loadAllImages() async {
        var loaded: [String: UIImage] = [:]
        await withTaskGroup(of: (String, UIImage?).self) { tg in
            for asset in group.assets {
                tg.addTask { (asset.localIdentifier, await requestImage(for: asset)) }
            }
            for await (id, img) in tg {
                if let img { loaded[id] = img }
            }
        }
        images = loaded
    }

    private func requestImage(for asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.isNetworkAccessAllowed = true
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 600, height: 600),
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
                guard !isDegraded else { return }
                continuation.resume(returning: image)
            }
        }
    }

    private func assetFileSize(_ asset: PHAsset) -> Int64 {
        let resources = PHAssetResource.assetResources(for: asset)
        var total: Int64 = 0
        for resource in resources {
            if let size = resource.value(forKey: "fileSize") as? Int64 { total += size }
            else if let size = resource.value(forKey: "fileSize") as? Int { total += Int64(size) }
        }
        return total > 0 ? total : 3_670_016
    }
}
