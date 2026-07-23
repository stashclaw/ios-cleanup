import SwiftUI
import Photos

struct SwipeModeView: View {
    let groups: [PhotoGroup]
    @EnvironmentObject private var deletionManager: DeletionManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: SwipeModeViewModel

    init(groups: [PhotoGroup]) {
        self.groups = groups
        _viewModel = StateObject(wrappedValue: SwipeModeViewModel(groups: groups))
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isComplete {
                    DuckModeCompletion(
                        viewModel: viewModel,
                        deletionManager: deletionManager,
                        onDismiss: { dismiss() }
                    )
                } else {
                    cardStack
                }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Duck Mode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Color.white)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        viewModel.undoLastSwipe()
                    } label: {
                        Label("Undo Swipe", systemImage: "arrow.uturn.backward")
                    }
                    .foregroundStyle(Color.white)
                    .disabled(!viewModel.canUndoLastSwipe)
                }
            }
        }
        .onChange(of: deletionManager.undoEventID) { _ in
            viewModel.restoreUndoneAssets(deletionManager.lastUndoneAssetIDs)
        }
        .onChange(of: deletionManager.lastDeletionError) { error in
            guard error != nil else { return }
            viewModel.restoreUndoneAssets(deletionManager.lastFailedAssetIDs)
        }
    }

    // MARK: - Card Stack

    @State private var dragOffset: CGSize = .zero

    private var swipeThreshold: CGFloat { 100 }

    private var cardStack: some View {
        ZStack {
            // Background cards (depth effect)
            ForEach(upcomingEntries.reversed().prefix(2), id: \.id) { entry in
                if case .asset(let asset, _) = entry, entry.id != viewModel.current?.id {
                    DuckAssetCard(
                        asset: asset,
                        estimatedFileSize: viewModel.fileSize(for: asset.localIdentifier)
                    )
                        .scaleEffect(0.93)
                        .opacity(0.5)
                }
            }

            // Side strips — always visible, intensity driven by drag
            HStack(spacing: 0) {
                // Left: red strip (delete)
                ZStack {
                    Color.red.opacity(0.85 + leftStripIntensity * 0.15)
                    Image(systemName: "trash")
                        .font(.duckBody(20, weight: .semibold, relativeTo: .title3))
                        .foregroundStyle(.white)
                        .scaleEffect(1 + leftStripIntensity * 0.4)
                }
                .frame(width: 32)
                .frame(maxHeight: .infinity)

                Spacer()

                // Right: green strip (keep)
                ZStack {
                    Color.green.opacity(0.85 + rightStripIntensity * 0.15)
                    Image(systemName: "checkmark")
                        .font(.duckBody(20, weight: .semibold, relativeTo: .title3))
                        .foregroundStyle(.white)
                        .scaleEffect(1 + rightStripIntensity * 0.4)
                }
                .frame(width: 32)
                .frame(maxHeight: .infinity)
            }
            .ignoresSafeArea()

            // Current card
            if let current = viewModel.current, case .asset(let asset, _) = current {
                DuckAssetCard(
                    asset: asset,
                    estimatedFileSize: viewModel.fileSize(for: asset.localIdentifier),
                    monthHeader: currentMonthHeader
                )
                    .offset(cardOffset)
                    .rotationEffect(.degrees(Double(cardOffset.width) / 20))
                    .gesture(
                        DragGesture()
                            .onChanged {
                                guard !viewModel.isTransitioning else { return }
                                dragOffset = $0.translation
                            }
                            .onEnded { value in
                                withAnimation(.duckSpring) {
                                    if value.translation.width < -swipeThreshold { swipeLeft() }
                                    else if value.translation.width > swipeThreshold { swipeRight() }
                                    else { dragOffset = .zero }
                                }
                            }
                    )
                    .allowsHitTesting(!viewModel.isTransitioning)
            }

            // Progress + round buttons overlay
            VStack {
                // Progress strip at top
                HStack {
                    StatusBadge(title: "\(viewModel.reviewedCount) / \(viewModel.totalReviewableCount) reviewed", accent: .duckPink)
                    Spacer()
                    StatusBadge(title: "\(viewModel.remainingCount) left", accent: .duckRose)
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)

                DuckProgressBar(progress: viewModel.progress, color: .duckPink)
                    .frame(height: 4)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)

                Spacer()

                // Round action buttons
                HStack(spacing: 48) {
                    // Duck it — pink filled
                    Button { swipeLeft() } label: {
                        ZStack {
                            Circle()
                                .fill(Color.duckPink)
                                .frame(width: 64, height: 64)
                            Image(systemName: "trash")
                                .font(.duckBody(24, weight: .semibold, relativeTo: .title2))
                                .foregroundStyle(.white)
                        }
                    }
                    .accessibilityLabel("Duck it")
                    .disabled(viewModel.isTransitioning)

                    // Keep it — white outlined
                    Button { swipeRight() } label: {
                        ZStack {
                            Circle()
                                .strokeBorder(.white, lineWidth: 2)
                                .frame(width: 64, height: 64)
                            Image(systemName: "heart")
                                .font(.duckBody(24, weight: .semibold, relativeTo: .title2))
                                .foregroundStyle(.white)
                        }
                    }
                    .accessibilityLabel("Keep it")
                    .disabled(viewModel.isTransitioning)
                }
                .padding(.bottom, 48)
            }
        }
    }

    // MARK: - Strip intensity (0…1)

    private var leftStripIntensity: Double {
        guard cardOffset.width < 0 else { return 0 }
        return min(Double(-cardOffset.width) / Double(swipeThreshold), 1)
    }

    private var rightStripIntensity: Double {
        guard cardOffset.width > 0 else { return 0 }
        return min(Double(cardOffset.width) / Double(swipeThreshold), 1)
    }

    // MARK: - Helpers

    private var upcomingEntries: [SwipeModeViewModel.QueueEntry] {
        Array(viewModel.queue.dropFirst(viewModel.currentIndex).prefix(3))
    }

    private var currentMonthHeader: String? {
        let preceding = viewModel.queue.prefix(viewModel.currentIndex + 1)
        return preceding.reversed().compactMap { entry -> String? in
            if case .monthHeader(let s) = entry { return s }
            return nil
        }.first
    }

    private var cardOffset: CGSize {
        switch viewModel.transitionDecision {
        case .delete: return CGSize(width: -500, height: 0)
        case .keep: return CGSize(width: 500, height: 0)
        case nil: return dragOffset
        }
    }

    private func swipeLeft() {
        guard !viewModel.isTransitioning else { return }
        dragOffset = .zero
        withAnimation(.easeOut(duration: 0.25)) {
            viewModel.delete()
        }
    }

    private func swipeRight() {
        guard !viewModel.isTransitioning else { return }
        dragOffset = .zero
        withAnimation(.easeOut(duration: 0.25)) {
            viewModel.keep()
        }
    }
}

// MARK: - Completion Screen

private struct DuckModeCompletion: View {
    @ObservedObject var viewModel: SwipeModeViewModel
    let deletionManager: DeletionManager
    let onDismiss: () -> Void

    private var pendingGB: String {
        ByteCountFormatter.string(fromByteCount: viewModel.pendingDeleteBytes, countStyle: .file)
    }

    private var isEmptyReview: Bool {
        viewModel.totalReviewableCount == 0
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer(minLength: 32)

                PhotoDuckMascotArt(size: 120)

                Text(completionTitle)
                    .font(.duckTitle)
                    .foregroundStyle(Color.duckBerry)
                    .multilineTextAlignment(.center)

                if isEmptyReview {
                    Text("There are no high-confidence cleanup suggestions in this review. Similar photos that need judgment stay review-only.")
                        .font(.duckBody)
                        .foregroundStyle(Color.duckRose)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                }

                if viewModel.pendingDeleteBytes > 0 {
                    Text("Potential space: \(pendingGB)")
                        .font(.duckDisplay)
                        .foregroundStyle(Color.duckPink)
                }

                if viewModel.hasPendingDeletes {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Selected for Recently Deleted")
                            .font(.duckBody.weight(.semibold))
                            .foregroundStyle(Color.duckBerry)

                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 8) {
                                ForEach(
                                    viewModel.pendingDeleteAssets,
                                    id: \.localIdentifier
                                ) { asset in
                                    PendingDeleteThumbnail(asset: asset)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                }

                if let error = viewModel.deleteError {
                    Text(error).font(.duckCaption).foregroundStyle(.red)
                }

                if deletionManager.isDeleting {
                    VStack(spacing: 12) {
                        StatusBadge(title: "Moving to Recently Deleted...", accent: .duckPink)
                        DuckProgressBar(progress: deletionManager.deletionProgress, color: .duckPink)
                            .frame(height: 12)
                            .padding(.horizontal, 20)
                        Text("\(ByteCountFormatter.string(fromByteCount: deletionManager.bulkProcessedBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: deletionManager.bulkTotalBytes, countStyle: .file)) selected")
                            .font(.duckBody)
                            .foregroundStyle(Color.duckRose)
                        Text("\(deletionManager.bulkProcessedCount) of \(deletionManager.bulkTotalCount) photos")
                            .font(.duckCaption)
                            .foregroundStyle(Color.duckBerry)
                        Text("Space is permanently reclaimed after Recently Deleted is emptied.")
                            .font(.duckCaption)
                            .foregroundStyle(Color.duckRose)
                            .multilineTextAlignment(.center)
                    }
                } else {
                    VStack(spacing: 12) {
                        if viewModel.hasPendingDeletes {
                            DuckPrimaryButton(title: "Move to Recently Deleted") {
                                Task {
                                    await viewModel.commitDeletes(using: deletionManager)
                                }
                            }
                            .padding(.horizontal, 32)

                            Text("Potential space is reclaimed after Recently Deleted is emptied.")
                                .font(.duckCaption)
                                .foregroundStyle(Color.duckRose)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                        }

                        if !isEmptyReview {
                            DuckOutlineButton(title: "Review again", color: .duckRose) {
                                viewModel.resetQueue()
                            }
                            .padding(.horizontal, 20)
                        }
                    }
                }

                Spacer(minLength: 32)

                DuckOutlineButton(title: "✓ Back to Library", color: .duckPink) { onDismiss() }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 40)
            }
        }
        .background(Color.duckBlush.ignoresSafeArea())
    }

    private var completionTitle: String {
        if isEmptyReview {
            return "Nothing to review"
        }
        if viewModel.duckedCount == 0 {
            return "You kept every photo"
        }
        return "Selected \(viewModel.duckedCount) photo\(viewModel.duckedCount == 1 ? "" : "s")"
    }
}

private struct PendingDeleteThumbnail: View {
    let asset: PHAsset
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.duckSoftPink.opacity(0.4)
                    .overlay(ProgressView().tint(.white))
            }
        }
        .frame(width: 88, height: 88)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Image(systemName: "trash.fill")
                .font(.duckMicro.weight(.bold))
                .foregroundStyle(.white)
                .padding(6)
                .background(Color.duckDanger, in: Circle())
                .padding(5)
        }
        .accessibilityLabel("Selected for Recently Deleted")
        .task {
            image = await asset.loadImage(
                targetSize: CGSize(width: 176, height: 176),
                deliveryMode: .opportunistic,
                allowNetwork: true,
                contentMode: .aspectFill,
                acceptsDegradedResult: true
            )
        }
    }
}

// MARK: - Duck Asset Card

private struct DuckAssetCard: View {
    let asset: PHAsset
    let estimatedFileSize: Int64?
    var monthHeader: String? = nil
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    var body: some View {
        GeometryReader { geo in
            let targetSize = CGSize(
                width: max(geo.size.width * displayScale, 1),
                height: max(geo.size.height * displayScale, 1)
            )

            ZStack(alignment: .bottom) {
                // Photo — edge-to-edge, scaledToFill
                Group {
                    if let img = image {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color.gray.opacity(0.3)
                            .overlay(ProgressView().tint(.white))
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()

                // Bottom gradient overlay — 100pt
                LinearGradient(
                    colors: [.clear, .black.opacity(0.75)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 100)

                // Date + file size
                VStack(alignment: .leading, spacing: 4) {
                    if let header = monthHeader {
                        Text(header)
                            .font(.duckCaption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    if let date = asset.creationDate {
                        Text(Self.dateFormatter.string(from: date))
                            .font(.duckBody.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                    if let fileSizeLabel {
                        Text(fileSizeLabel)
                            .font(.duckCaption)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 44) // inset from side strips
                .padding(.bottom, 20)
            }
            .task(id: "\(Int(targetSize.width.rounded()))x\(Int(targetSize.height.rounded()))") {
                image = await asset.loadImage(
                    targetSize: targetSize,
                    deliveryMode: .opportunistic,
                    allowNetwork: true,
                    contentMode: .aspectFill,
                    acceptsDegradedResult: true
                )
            }
        }
    }

    private var fileSizeLabel: String? {
        guard let estimatedFileSize, estimatedFileSize > 0 else { return nil }
        let size = ByteCountFormatter.string(fromByteCount: estimatedFileSize, countStyle: .file)
        return "Est. \(size)"
    }

}
