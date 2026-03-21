import Photos
import SwiftUI

struct PhotoGroupDetailView: View {
    let onDeleteGroup: (() -> Void)?

    @EnvironmentObject private var purchaseManager: PurchaseManager
    @EnvironmentObject private var deletionManager: DeletionManager
    @Environment(\.dismiss) private var dismiss

    @StateObject private var viewModel: SimilarGroupReviewViewModel
    @State private var images: [String: UIImage] = [:]
    @State private var showPaywall = false
    @State private var showTrashUndoBar = false
    @State private var showWhyThisShot = false

    init(group: PhotoGroup, allGroups: [PhotoGroup]? = nil, onDeleteGroup: (() -> Void)? = nil) {
        self.onDeleteGroup = onDeleteGroup
        _viewModel = StateObject(
            wrappedValue: SimilarGroupReviewViewModel(
                groups: allGroups ?? [group],
                startGroupID: group.id
            )
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ReviewDecisionHUD(
                    groupPosition: viewModel.currentGroupPositionLabel,
                    photoCount: viewModel.currentPhotoCount,
                    reclaimableBytes: viewModel.currentGroupReclaimableBytes,
                    confidenceLabel: viewModel.confidenceLabel,
                    contextLabel: [viewModel.currentGroupSummaryLabel, viewModel.currentGroupContextLabel]
                        .filter { !$0.isEmpty }
                        .joined(separator: " · ")
                )

                photoCarousel

                recommendationBlock

                ThumbnailRail(
                    candidates: viewModel.currentGroup?.candidates ?? [],
                    currentIndex: viewModel.currentPhotoIndex,
                    selectedKeeperID: viewModel.selectedKeeperCandidate?.photoId,
                    onSelect: { viewModel.setFocusedPhoto(index: $0) }
                )
                .frame(height: 96)

                ActionBar(
                    keepTitle: "Keep Best",
                    neutralTitle: "Skip Group",
                    destructiveTitle: trashButtonTitle,
                    destructiveIsPaid: !purchaseManager.isPurchased,
                    onKeep: { Task { await handleKeepBest() } },
                    onNeutral: { Task { await handleSkipGroup() } },
                    onDestructive: { Task { await handleTrashSelected() } }
                )

                if let recentAction = viewModel.recentTrashAction, showTrashUndoBar {
                    UndoFeedbackBar(
                        movedCount: recentAction.movedCount,
                        reclaimedBytes: recentAction.reclaimedBytes,
                        onUndo: {
                            deletionManager.undoLast()
                            viewModel.undoLastTrashSelection()
                            showTrashUndoBar = false
                        },
                        onReviewTrash: nil
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .background(Color.duckBlush.ignoresSafeArea())
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPaywall) {
            PaywallView()
                .environmentObject(purchaseManager)
        }
        .task(id: imageLoadKey) {
            await loadVisibleImages()
        }
        .onReceive(NotificationCenter.default.publisher(for: .purchaseDidSucceed)) { _ in
            showPaywall = false
        }
    }

    private var navigationTitle: String {
        if let group = viewModel.currentGroup, let date = group.captureDateRange?.start {
            return date.formatted(.dateTime.month(.abbreviated).day().year())
        }
        return "Similar Review"
    }

    private var trashButtonTitle: String {
        "Move Others to Trash"
    }

    private var recommendationBlock: some View {
        DuckCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(viewModel.recommendationTitle)
                            .font(.duckHeading)
                            .foregroundStyle(Color.duckBerry)
                        Text(viewModel.recommendationSubtitle)
                            .font(.duckCaption)
                            .foregroundStyle(Color.duckRose)
                    }

                    Spacer(minLength: 8)

                    if viewModel.selectedKeeperCandidate?.photoId == viewModel.currentBestShot?.photoId {
                        BestShotBadge(
                            isRecommended: true,
                            needsReview: viewModel.currentGroup?.groupConfidence != .high
                        )
                    }
                }

                DisclosureGroup(isExpanded: $showWhyThisShot) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Selected because:")
                            .font(.duckCaption.weight(.semibold))
                            .foregroundStyle(Color.duckRose)

                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(viewModel.selectedKeeperReasons.prefix(4), id: \.self) { reason in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(Color.duckPink)
                                    Text(reason)
                                        .font(.duckBody)
                                        .foregroundStyle(Color.duckBerry)
                                    Spacer(minLength: 0)
                                }
                            }
                        }

                        if !viewModel.currentIssueFlags.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Watch for:")
                                    .font(.duckCaption.weight(.semibold))
                                    .foregroundStyle(Color.duckRose)
                                ForEach(viewModel.currentIssueFlags.prefix(3), id: \.self) { flag in
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: flag.systemImage)
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(Color.duckOrange)
                                        Text(flag.title)
                                            .font(.duckBody)
                                            .foregroundStyle(Color.duckBerry)
                                        Spacer(minLength: 0)
                                    }
                                }
                            }
                        }

                        Text(viewModel.trustNote)
                            .font(.duckCaption)
                            .foregroundStyle(Color.duckRose)
                            .padding(.top, 2)
                    }
                    .padding(.top, 6)
                } label: {
                    Text("Why this shot?")
                        .font(.duckLabel.weight(.semibold))
                        .foregroundStyle(Color.duckPink)
                }
            }
            .padding(16)
        }
    }

    private var photoCarousel: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let gap: CGFloat = 14
            let cardWidth = max((width - gap) / 2, 0)
            let cardHeight = proxy.size.height

            HStack(spacing: gap) {
                photoCard(
                    candidate: currentCandidate,
                    image: currentCandidate.flatMap { images[$0.photoId] },
                    isSelectedKeeper: currentCandidate?.photoId == viewModel.selectedKeeperCandidate?.photoId,
                    width: cardWidth,
                    height: cardHeight,
                    onTap: {
                        if let index = viewModel.currentGroup?.candidates.firstIndex(where: { $0.photoId == currentCandidate?.photoId }) {
                            viewModel.setFocusedPhoto(index: index)
                        }
                    }
                )

                photoCard(
                    candidate: nextCandidate,
                    image: nextCandidate.flatMap { images[$0.photoId] },
                    isSelectedKeeper: nextCandidate?.photoId == viewModel.selectedKeeperCandidate?.photoId,
                    width: cardWidth,
                    height: cardHeight,
                    onTap: {
                        guard let nextCandidate, let index = viewModel.currentGroup?.candidates.firstIndex(where: { $0.photoId == nextCandidate.photoId }) else { return }
                        viewModel.setFocusedPhoto(index: index)
                    }
                )
            }
            .gesture(
                DragGesture(minimumDistance: 20)
                    .onEnded { value in
                        if value.translation.width < -40 {
                            viewModel.moveToNextPhoto()
                        } else if value.translation.width > 40 {
                            viewModel.moveToPreviousPhoto()
                        }
                    }
            )
            .contentShape(Rectangle())
        }
        .frame(height: 420)
    }

    private var currentCandidate: SimilarPhotoCandidate? {
        viewModel.currentFocusedPhoto ?? viewModel.currentBestShot
    }

    private var nextCandidate: SimilarPhotoCandidate? {
        guard let group = viewModel.currentGroup, viewModel.currentPhotoIndex + 1 < group.candidates.count else { return nil }
        return group.candidates[viewModel.currentPhotoIndex + 1]
    }

    private var imageLoadKey: String {
        let groupID = viewModel.currentGroup?.id.uuidString ?? "none"
        return "\(groupID)-\(viewModel.currentPhotoIndex)"
    }

    private func photoCard(
        candidate: SimilarPhotoCandidate?,
        image: UIImage?,
        isSelectedKeeper: Bool,
        width: CGFloat,
        height: CGFloat,
        onTap: @escaping () -> Void
    ) -> some View {
        Button(action: onTap) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.duckSoftPink.opacity(0.6), Color.duckCream],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        Group {
                            if let image {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: width, height: height)
                                    .clipped()
                            } else {
                                ProgressView()
                                    .tint(Color.duckPink)
                            }
                        }
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))

                VStack(alignment: .leading, spacing: 8) {
                    if isSelectedKeeper {
                        BestShotBadge(
                            isRecommended: true,
                            needsReview: viewModel.currentGroup?.groupConfidence != .high
                        )
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(isSelectedKeeper ? "Recommended keeper" : "Compare")
                            .font(.duckLabel.weight(.semibold))
                            .foregroundStyle(isSelectedKeeper ? Color.white : Color.white.opacity(0.88))
                        Text(isSelectedKeeper ? (candidate?.bestShotReasons.first ?? "Selected by tap") : "Tap to select this keeper")
                            .font(.duckCaption)
                            .foregroundStyle(Color.white)
                            .lineLimit(2)
                    }
                }
                .padding(16)
                .shadow(color: Color.black.opacity(0.18), radius: 8, x: 0, y: 2)
            }
            .frame(width: width, height: height)
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(isSelectedKeeper ? Color.duckPink : Color.white.opacity(0.15), lineWidth: isSelectedKeeper ? 3 : 1.25)
            )
            .shadow(color: Color.duckPink.opacity(isSelectedKeeper ? 0.26 : 0.10), radius: isSelectedKeeper ? 20 : 10, x: 0, y: 10)
        }
        .buttonStyle(.plain)
    }

    private func loadVisibleImages() async {
        guard let group = viewModel.currentGroup else {
            images.removeAll()
            return
        }

        let lowerBound = max(viewModel.currentPhotoIndex - 1, 0)
        let upperBound = min(viewModel.currentPhotoIndex + 1, group.candidates.count - 1)
        guard lowerBound <= upperBound else {
            images.removeAll()
            return
        }

        let visibleCandidates = Array(group.candidates[lowerBound...upperBound])
        let visibleIDs = Set(visibleCandidates.map(\.photoId))

        // Keep only the images that are still relevant for the current carousel.
        images = images.filter { visibleIDs.contains($0.key) }

        let missingCandidates = visibleCandidates.filter { images[$0.photoId] == nil }
        guard !missingCandidates.isEmpty else { return }

        var loaded = images
        await withTaskGroup(of: (String, UIImage?).self) { taskGroup in
            for candidate in missingCandidates {
                guard let asset = group.assets.first(where: { $0.localIdentifier == candidate.photoId }) else { continue }
                taskGroup.addTask {
                    let image = await self.requestImage(for: asset)
                    return (candidate.photoId, image)
                }
            }
            for await (id, image) in taskGroup {
                if let image { loaded[id] = image }
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
                targetSize: CGSize(width: 900, height: 900),
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                // .opportunistic delivers a degraded image first, then the final.
                // Only resume on the final delivery to avoid resuming the continuation twice.
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
                guard !isDegraded else { return }
                continuation.resume(returning: image)
            }
        }
    }

    private func handleKeepBest() async {
        guard let group = viewModel.currentGroup else { return }
        guard purchaseManager.isPurchased else {
            showPaywall = true
            return
        }

        viewModel.keepBest()

        if group.groupConfidence == .high {
            await commitSelection(for: group, useBestBestPath: true)
        }
    }

    private func handleTrashSelected() async {
        guard let group = viewModel.currentGroup else { return }
        guard purchaseManager.isPurchased else {
            showPaywall = true
            return
        }

        if viewModel.selectedTrashPhotoIDs.isEmpty {
            viewModel.keepBest()
        }
        await commitSelection(for: group, useBestBestPath: false)
    }

    private func handleSkipGroup() async {
        guard viewModel.currentGroup != nil else { return }
        let wasLastGroup = viewModel.currentGroupIndex == viewModel.totalGroups - 1
        viewModel.skipGroup()
        if wasLastGroup {
            dismiss()
        }
    }

    private func commitSelection(for group: PhotoGroup, useBestBestPath: Bool) async {
        let wasLastGroup = viewModel.currentGroupIndex == viewModel.totalGroups - 1
        let selectedIDs = viewModel.selectedTrashPhotoIDs
        guard !selectedIDs.isEmpty else { return }
        guard group.keeperAssetID != nil || !group.deleteCandidateIDs.isEmpty else { return }

        let allowedDeleteIDs: Set<String>
        if !group.deleteCandidateIDs.isEmpty {
            allowedDeleteIDs = Set(group.deleteCandidateIDs)
        } else if let keeperAssetID = group.keeperAssetID {
            allowedDeleteIDs = Set(group.assets.map(\.localIdentifier).filter { $0 != keeperAssetID })
        } else {
            allowedDeleteIDs = []
        }
        guard !allowedDeleteIDs.isEmpty else { return }
        let effectiveSelectedIDs = selectedIDs.intersection(allowedDeleteIDs)
        let selectedAssets = group.assets.filter { effectiveSelectedIDs.contains($0.localIdentifier) }
        guard !selectedAssets.isEmpty else { return }

        do {
            if useBestBestPath, effectiveSelectedIDs.count == allowedDeleteIDs.count, group.groupConfidence == .high {
                try await deletionManager.keepBest(from: group)
            } else {
                try await deletionManager.delete(assets: selectedAssets)
            }

            showTrashUndoBar = true
            viewModel.resolveTrashAction()
            onDeleteGroup?()

            if wasLastGroup {
                dismiss()
            }
        } catch {
            viewModel.lastActionSummary = error.localizedDescription
        }
    }
}
