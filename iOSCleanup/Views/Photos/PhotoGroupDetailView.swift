import Photos
import SwiftUI

struct PhotoGroupDetailView: View {
    let group: PhotoGroup
    let groupIndex: Int
    let totalGroups: Int
    let onDeleteGroup: (() -> Void)?

    @EnvironmentObject private var purchaseManager: PurchaseManager
    @EnvironmentObject private var deletionManager: DeletionManager
    @EnvironmentObject private var exportAlbum: ExportAlbumStore
    @Environment(\.dismiss) private var dismiss

    @State private var deleteSet: Set<String> = []
    @State private var fileSizes: [String: Int64] = [:]
    @State private var showPaywall = false
    @State private var isDeleting = false
    @State private var deleteError: String?
    @State private var previewAssetID: String?
    @State private var exportChipMessage: String?

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
            VStack(spacing: 12) {
                reviewGuidance
                    .padding(.horizontal, 12)
                    .padding(.top, 8)

                LazyVStack(spacing: 12) {
                    ForEach(Array(group.assets.enumerated()), id: \.element.localIdentifier) { index, asset in
                        photoCell(asset: asset, index: index)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .background(Color.berryBlack.ignoresSafeArea())
        .navigationTitle("Group \(groupIndex + 1) of \(totalGroups)")
        .navigationBarTitleDisplayMode(.inline)
        // Dark-native translucent chrome over the grid; needs no global
        // appearance because every screen owns its own toolbar now.
        .toolbarBackground(Color.black.opacity(0.001), for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 4) {
                if let deleteError {
                    Text(deleteError)
                        .font(.duckCaption)
                        .foregroundStyle(Color.danger)
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

                // When the selection is exactly the classifier's recommended
                // set, the free Keep Best button above already commits it.
                // Showing a paid "Delete Selected" for the identical action
                // would route free users into the paywall for nothing.
                if !selectionMatchesRecommendation {
                    DuckBottomActionBar(
                        summary: actionSummary,
                        primaryLabel: isDeleting
                            ? "Moving…"
                            : (purchaseManager.isPurchased ? "Delete Selected" : "Delete Selected — Pro"),
                        primaryEnabled: !deleteSet.isEmpty
                            && deleteSet.count < group.assets.count
                            && !isDeleting,
                        isPaid: !purchaseManager.isPurchased,
                        isDark: true,
                        onPrimary: { Task { await deleteSelected() } },
                        onShowPaywall: { showPaywall = true }
                    )
                }

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
    private func photoCell(asset: PHAsset, index: Int) -> some View {
        let inDelete = deleteSet.contains(asset.localIdentifier)

        PhotoGroupAssetCell(
            asset: asset,
            index: index,
            totalCount: group.assets.count,
            estimatedFileSize: fileSizes[asset.localIdentifier],
            isSelectedForDeletion: inDelete,
            isRecommendedKeeper: asset.localIdentifier == keeperID
        ) {
            toggleSelection(for: asset)
        } onPreview: {
            previewAssetID = asset.localIdentifier
        }
    }

    private func toggleSelection(for asset: PHAsset) {
        deleteError = nil

        // The keeper guardrail, made visible: the recommended keeper cannot
        // be marked for deletion from the grid.
        guard asset.localIdentifier != keeperID else {
            deleteError = "The recommended keeper is protected from deletion."
            DuckHaptics.rigid()
            UIAccessibility.post(notification: .announcement, argument: "Keeper is protected from deletion")
            return
        }

        let nowSelected: Bool
        if deleteSet.contains(asset.localIdentifier) {
            deleteSet.remove(asset.localIdentifier)
            nowSelected = false
        } else {
            let proposedSelection = deleteSet.union([asset.localIdentifier])
            guard proposedSelection.count < group.assets.count else {
                deleteError = PhotoDeletionGuardrailError.wouldDeleteEntireGroup.localizedDescription
                return
            }
            deleteSet = proposedSelection
            nowSelected = true
        }

        DuckHaptics.selection()
        UIAccessibility.post(
            notification: .announcement,
            argument: nowSelected ? "Marked for deletion" : "Kept"
        )
    }

    private var selectionMatchesRecommendation: Bool {
        group.isAutoCleanEligible && deleteSet == Set(group.deleteCandidateIDs)
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

    private func addSelectionToExportAlbum() {
        let explicitSelection = group.assets.filter {
            deleteSet.contains($0.localIdentifier)
        }
        guard !explicitSelection.isEmpty else { return }
        exportAlbum.add(explicitSelection)
        exportChipMessage = "\(explicitSelection.count) added to Export Album"
    }

    @ViewBuilder
    private var reviewGuidance: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                StatusBadge(
                    title: group.recommendedAction == .keepBestTrashRest ? "High-confidence cleanup" : "Review together",
                    accent: group.isAutoCleanEligible ? .success : .textSecondary
                )

                Spacer(minLength: 4)

                Button(action: addSelectionToExportAlbum) {
                    Label("Add to Export", systemImage: "plus")
                        .font(.duckCaption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.14), in: Capsule())
                        .overlay {
                            Capsule()
                                .stroke(Color.white.opacity(0.28), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .disabled(deleteSet.isEmpty)
                .opacity(deleteSet.isEmpty ? 0.45 : 1)
                .accessibilityHint("Adds the selected photos to the Export Album without deleting them")
            }

            if let reason = group.reasons.first {
                Text(reason)
                    .font(.duckCaption)
                    .foregroundStyle(Color.white.opacity(0.8))
            }

            if let exportChipMessage {
                Text(exportChipMessage)
                    .font(.duckCaption.weight(.semibold))
                    .foregroundStyle(Color.success)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
    }

}

private struct PhotoGroupAssetCell: View {
    let asset: PHAsset
    let index: Int
    let totalCount: Int
    let estimatedFileSize: Int64?
    let isSelectedForDeletion: Bool
    let isRecommendedKeeper: Bool
    let onToggle: () -> Void
    let onPreview: () -> Void

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { proxy in
            let targetSize = displayTargetSize(for: proxy.size.width)

            ZStack(alignment: .bottom) {
                Group {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                    } else {
                        Color.gray.opacity(0.25)
                            .overlay(ProgressView().tint(.white))
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)

                if isSelectedForDeletion {
                    Color.danger.opacity(0.30)
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
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)

                    Spacer()

                    Image(systemName: isSelectedForDeletion ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, isSelectedForDeletion ? Color.danger : Color.success)
                        .font(.title2)
                        .shadow(radius: 2)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .task(id: "\(Int(targetSize.width))x\(Int(targetSize.height))") {
                image = await asset.loadImage(
                    targetSize: targetSize,
                    deliveryMode: .highQualityFormat,
                    allowNetwork: true,
                    contentMode: .aspectFit,
                    acceptsDegradedResult: false,
                    timeout: 20
                )
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onPreview)
        .onTapGesture(count: 1, perform: onToggle)
        .aspectRatio(assetAspectRatio, contentMode: .fit)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: DuckRadius.s, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DuckRadius.s, style: .continuous)
                .stroke(
                    isSelectedForDeletion
                        ? Color.danger
                        : (isRecommendedKeeper ? Color.success : Color.white.opacity(0.12)),
                    lineWidth: isSelectedForDeletion || isRecommendedKeeper ? 3 : 1
                )
        }
        .overlay(alignment: .topLeading) {
            if isRecommendedKeeper {
                HStack(spacing: 3) {
                    Image(systemName: "star.fill")
                        .font(.duckMicro.weight(.bold))
                    Text("Keeper")
                        .font(.duckLabel)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.success, in: Capsule())
                .padding(6)
                .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button(action: onPreview) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.duckCaption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(.black.opacity(0.55), in: Circle())
            }
            .frame(width: 44, height: 44)
            .buttonStyle(.plain)
            .padding(4)
            .accessibilityLabel("Open fullscreen comparison")
        }
        .accessibilityLabel(
            isRecommendedKeeper
                ? "Photo \(index + 1) of \(totalCount), \(fileSizeLabel), recommended keeper"
                : "Photo \(index + 1) of \(totalCount), \(fileSizeLabel)"
        )
        .accessibilityValue(isSelectedForDeletion ? "Marked for deletion" : "Kept")
        .accessibilityHint(
            isRecommendedKeeper
                ? "The keeper is protected from deletion"
                : (isSelectedForDeletion ? "Double tap to keep this photo" : "Double tap to mark this photo for deletion")
        )
        .accessibilityAddTraits(isSelectedForDeletion ? .isSelected : [])
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Toggle selection", onToggle)
        .accessibilityAction(named: "Open fullscreen comparison", onPreview)
    }

    private var assetAspectRatio: CGFloat {
        CGFloat(max(asset.pixelWidth, 1)) / CGFloat(max(asset.pixelHeight, 1))
    }

    private func displayTargetSize(for displayWidth: CGFloat) -> CGSize {
        let pixelWidth = min(max(displayWidth * displayScale, 1_200), 2_048)
        let pixelHeight = min(
            max(pixelWidth / assetAspectRatio, 1),
            2_048
        )
        return CGSize(width: pixelWidth, height: pixelHeight)
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
                targetSize: PHImageManagerMaximumSize,
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
                .stroke(isSelected ? Color.accentPrimary : Color.white.opacity(0.25), lineWidth: isSelected ? 3 : 1)
        )
        .overlay(alignment: .topTrailing) {
            if isKeeper {
                Image(systemName: "star.fill")
                    .font(.duckMicro.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(5)
                    .background(Color.accentPrimary, in: Circle())
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
