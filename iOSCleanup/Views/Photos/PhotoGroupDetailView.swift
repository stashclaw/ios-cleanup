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
    @State private var fileSizes: [String: Int64] = [:]
    @State private var showPaywall = false
    @State private var isDeleting = false
    @State private var deleteError: String?
    @State private var previewAssetID: String?

    init(group: PhotoGroup, groupIndex: Int = 0, totalGroups: Int = 1, onDeleteGroup: (() -> Void)? = nil) {
        self.group = group
        self.groupIndex = groupIndex
        self.totalGroups = totalGroups
        self.onDeleteGroup = onDeleteGroup
    }

    // MARK: - Computed

    private var keeperID: String? { group.keeperAssetID }

    private var deleteSavings: Int64 {
        group.assets
            .filter { deleteSet.contains($0.localIdentifier) }
            .reduce(Int64(0)) { $0 + (fileSizes[$1.localIdentifier] ?? 0) }
    }

    private var actionSummary: String {
        guard !deleteSet.isEmpty else { return "Tap photos to select them" }
        guard deleteSavings > 0 else { return "Move \(deleteSet.count) selected to Recently Deleted" }
        let savings = ByteCountFormatter.string(fromByteCount: deleteSavings, countStyle: .file)
        return "Move \(deleteSet.count) selected · \(savings) potential"
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                reviewGuidance

                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2)],
                    spacing: 2
                ) {
                    ForEach(group.assets, id: \.localIdentifier) { asset in
                        photoCell(asset: asset)
                    }
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("Group \(groupIndex + 1) of \(totalGroups)")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 4) {
                if let deleteError {
                    Text(deleteError)
                        .font(.duckCaption)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }

                if group.isAutoCleanEligible {
                    DuckPrimaryButton(title: isDeleting ? "Moving…" : "Keep Best") {
                        Task { await keepBest() }
                    }
                    .disabled(isDeleting)
                    .opacity(isDeleting ? 0.6 : 1)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                }

                DuckBottomActionBar(
                    summary: actionSummary,
                    primaryLabel: isDeleting ? "Moving…" : "Move Selected",
                    primaryEnabled: !deleteSet.isEmpty
                        && deleteSet.count < group.assets.count
                        && !isDeleting,
                    isPaid: !purchaseManager.isPurchased,
                    onPrimary: { Task { await deleteSelected() } },
                    onShowPaywall: { showPaywall = true }
                )

                Text("Potential space is reclaimed after Recently Deleted is emptied.")
                    .font(.duckCaption)
                    .foregroundStyle(Color.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 4)
            }
        }
        .task {
            deleteSet = group.isAutoCleanEligible ? Set(group.deleteCandidateIDs) : []
            fileSizes = Dictionary(uniqueKeysWithValues: group.assets.map {
                ($0.localIdentifier, $0.estimatedFileSize)
            })
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView().environmentObject(purchaseManager)
        }
        .fullScreenCover(isPresented: previewPresented) {
            if let previewAssetID {
                FullscreenGroupCompareView(
                    assets: group.assets,
                    initialAssetID: previewAssetID,
                    keeperAssetID: keeperID
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .purchaseDidSucceed)) { _ in
            showPaywall = false
        }
    }

    // MARK: - Photo cell

    @ViewBuilder
    private func photoCell(asset: PHAsset) -> some View {
        let inDelete = deleteSet.contains(asset.localIdentifier)

        PhotoGroupAssetCell(
            asset: asset,
            estimatedFileSize: fileSizes[asset.localIdentifier],
            isSelectedForDeletion: inDelete,
            isRecommendedKeeper: asset.localIdentifier == keeperID
        ) {
            deleteError = nil
            if deleteSet.contains(asset.localIdentifier) {
                deleteSet.remove(asset.localIdentifier)
            } else {
                let proposedSelection = deleteSet.union([asset.localIdentifier])
                guard proposedSelection.count < group.assets.count else {
                    deleteError = PhotoDeletionGuardrailError.wouldDeleteEntireGroup.localizedDescription
                    return
                }
                deleteSet = proposedSelection
            }
        } onPreview: {
            previewAssetID = asset.localIdentifier
        }
    }

    private var previewPresented: Binding<Bool> {
        Binding(
            get: { previewAssetID != nil },
            set: { isPresented in
                if !isPresented {
                    previewAssetID = nil
                }
            }
        )
    }

    // MARK: - Actions

    private func keepBest() async {
        guard group.isAutoCleanEligible, !isDeleting else { return }
        isDeleting = true
        defer { isDeleting = false }

        do {
            try await deletionManager.keepBest(from: group)
            _ = await PhotoFeedbackStore.shared.recordSimilarGroupDecision(
                group: group,
                kind: .keepBest,
                stage: .committed,
                selectedKeeperID: group.keeperAssetID,
                deletedAssetIDs: group.deleteCandidateIDs,
                keptAssetIDs: [group.keeperAssetID].compactMap { $0 },
                recommendationAccepted: true,
                note: "Keep Best from detail view"
            )
            onDeleteGroup?()
            dismiss()
        } catch is CancellationError {
            deleteError = nil
        } catch {
            deleteError = error.localizedDescription
        }
    }

    private func deleteSelected() async {
        guard !isDeleting else { return }
        do {
            try PhotoDeletionGuardrails.validateManualSelection(assetIDs: deleteSet, in: group)
        } catch {
            deleteError = error.localizedDescription
            return
        }

        let assetsToDelete = group.assets.filter { deleteSet.contains($0.localIdentifier) }
        let keptAssetIDs = group.assets
            .map(\.localIdentifier)
            .filter { !deleteSet.contains($0) }
        let selectedKeeperID = keeperID.flatMap { keptAssetIDs.contains($0) ? $0 : nil }
            ?? (keptAssetIDs.count == 1 ? keptAssetIDs[0] : nil)
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await deletionManager.delete(assets: assetsToDelete)
            _ = await PhotoFeedbackStore.shared.recordSimilarGroupDecision(
                group: group,
                kind: .deleteSelected,
                stage: .committed,
                selectedKeeperID: selectedKeeperID,
                deletedAssetIDs: Array(deleteSet),
                keptAssetIDs: keptAssetIDs,
                recommendationAccepted: group.isAutoCleanEligible
                    && deleteSet == Set(group.deleteCandidateIDs),
                note: "Grid delete from detail view"
            )
            onDeleteGroup?()
            dismiss()
        } catch is CancellationError {
            deleteError = nil
        } catch {
            deleteError = error.localizedDescription
        }
    }

    @ViewBuilder
    private var reviewGuidance: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(group.recommendedAction == .keepBestTrashRest ? "High-confidence cleanup" : "Review together")
                .font(.duckCaption.weight(.semibold))
                .foregroundStyle(group.isAutoCleanEligible ? Color.green : Color.duckRose)

            if let reason = group.reasons.first {
                Text(reason)
                    .font(.duckCaption)
                    .foregroundStyle(Color.white.opacity(0.8))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
    }

}

private struct PhotoGroupAssetCell: View {
    let asset: PHAsset
    let estimatedFileSize: Int64?
    let isSelectedForDeletion: Bool
    let isRecommendedKeeper: Bool
    let onToggle: () -> Void
    let onPreview: () -> Void

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        Button(action: onToggle) {
            GeometryReader { proxy in
                let pixelSide = max(proxy.size.width * displayScale, 1)

                ZStack(alignment: .bottom) {
                    Group {
                        if let image {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Color.gray.opacity(0.25)
                                .overlay(ProgressView().tint(.white))
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()

                    if isSelectedForDeletion {
                        Color.red.opacity(0.35)
                    }

                    LinearGradient(
                        colors: [.clear, .black.opacity(0.72)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 52)

                    HStack(alignment: .bottom, spacing: 4) {
                        Text(fileSizeLabel)
                            .font(.duckLabel)
                            .foregroundStyle(.white.opacity(0.9))

                        Spacer()

                        Image(systemName: isSelectedForDeletion ? "xmark.circle.fill" : "checkmark.circle.fill")
                            .font(.duckHeading)
                            .foregroundStyle(isSelectedForDeletion ? Color.red : Color.green)
                            .shadow(radius: 2)
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .task(id: Int(pixelSide.rounded())) {
                    image = await asset.loadImage(
                        targetSize: CGSize(width: pixelSide, height: pixelSide),
                        deliveryMode: .opportunistic,
                        allowNetwork: true,
                        contentMode: .aspectFill,
                        acceptsDegradedResult: true
                    )
                }
            }
        }
        .buttonStyle(.plain)
        .aspectRatio(1, contentMode: .fit)
        .clipped()
        .overlay(alignment: .topLeading) {
            if isRecommendedKeeper {
                Label("Best", systemImage: "star.fill")
                    .font(.duckMicro.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.duckPink, in: Capsule())
                    .padding(7)
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button(action: onPreview) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.duckCaption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.55), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(4)
            .accessibilityLabel("Open fullscreen comparison")
        }
        .accessibilityLabel(isRecommendedKeeper ? "Photo, recommended keeper" : "Photo")
        .accessibilityValue(isSelectedForDeletion ? "Selected for deletion" : "Kept")
        .accessibilityHint(isSelectedForDeletion ? "Double tap to keep this photo" : "Double tap to mark this photo for deletion")
        .accessibilityAddTraits(isSelectedForDeletion ? .isSelected : [])
    }

    private var fileSizeLabel: String {
        guard let estimatedFileSize, estimatedFileSize > 0 else {
            return "Size unavailable"
        }
        let size = ByteCountFormatter.string(fromByteCount: estimatedFileSize, countStyle: .file)
        return "Est. \(size)"
    }
}

private struct FullscreenGroupCompareView: View {
    let assets: [PHAsset]
    let keeperAssetID: String?

    @Environment(\.dismiss) private var dismiss
    @State private var selectedAssetID: String

    init(assets: [PHAsset], initialAssetID: String, keeperAssetID: String?) {
        self.assets = assets
        self.keeperAssetID = keeperAssetID
        _selectedAssetID = State(initialValue: initialAssetID)
    }

    private var selectedAsset: PHAsset? {
        assets.first { $0.localIdentifier == selectedAssetID }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let selectedAsset {
                    ZoomablePhotoCanvas(asset: selectedAsset)
                        .id(selectedAsset.localIdentifier)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(assets, id: \.localIdentifier) { asset in
                            Button {
                                selectedAssetID = asset.localIdentifier
                            } label: {
                                CompareThumbnail(
                                    asset: asset,
                                    isSelected: asset.localIdentifier == selectedAssetID,
                                    isKeeper: asset.localIdentifier == keeperAssetID
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(
                                asset.localIdentifier == keeperAssetID
                                    ? "Recommended keeper"
                                    : "Comparison photo"
                            )
                            .accessibilityAddTraits(
                                asset.localIdentifier == selectedAssetID ? .isSelected : []
                            )
                        }
                    }
                    .padding(12)
                }
                .background(Color.black.opacity(0.92))
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Compare")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct ZoomablePhotoCanvas: View {
    let asset: PHAsset

    @State private var image: UIImage?
    @State private var scale: CGFloat = 1
    @State private var committedScale: CGFloat = 1

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .scaleEffect(scale)
                        .gesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    scale = min(max(committedScale * value, 1), 5)
                                }
                                .onEnded { _ in
                                    committedScale = scale
                                }
                        )
                        .onTapGesture(count: 2) {
                            withAnimation(.duckSpring) {
                                scale = 1
                                committedScale = 1
                            }
                        }
                } else {
                    ProgressView()
                        .tint(.white)
                }
            }
            .clipped()
        }
        .task {
            image = await asset.loadImage(
                targetSize: CGSize(width: 1_600, height: 1_600),
                deliveryMode: .highQualityFormat,
                allowNetwork: true,
                contentMode: .aspectFit,
                acceptsDegradedResult: false
            )
        }
        .accessibilityLabel("Fullscreen photo comparison")
        .accessibilityHint("Pinch to zoom. Double tap to reset zoom.")
    }
}

private struct CompareThumbnail: View {
    let asset: PHAsset
    let isSelected: Bool
    let isKeeper: Bool

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.gray.opacity(0.35)
                    .overlay(ProgressView().tint(.white))
            }
        }
        .frame(width: 72, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isSelected ? Color.duckPink : Color.white.opacity(0.25), lineWidth: isSelected ? 3 : 1)
        )
        .overlay(alignment: .topTrailing) {
            if isKeeper {
                Image(systemName: "star.fill")
                    .font(.duckMicro.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(5)
                    .background(Color.duckPink, in: Circle())
                    .padding(4)
            }
        }
        .task {
            image = await asset.loadImage(
                targetSize: CGSize(width: 144, height: 144),
                deliveryMode: .opportunistic,
                allowNetwork: true,
                contentMode: .aspectFill,
                acceptsDegradedResult: true
            )
        }
    }
}
