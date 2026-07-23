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
        VStack(spacing: 0) {
            reviewProgressHeader

            ZStack {
                if let current = viewModel.current, case .asset(let asset, _) = current {
                    DuckAssetCard(
                        asset: asset,
                        estimatedFileSize: viewModel.fileSize(for: asset.localIdentifier),
                        monthHeader: currentMonthHeader
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(Color.white.opacity(0.14), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.35), radius: 14, x: 0, y: 8)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
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
                    .overlay(alignment: .topLeading) {
                        swipeCue(
                            title: "Delete",
                            icon: "trash.fill",
                            color: .duckDanger,
                            intensity: deleteCueIntensity
                        )
                        .padding(34)
                    }
                    .overlay(alignment: .topTrailing) {
                        swipeCue(
                            title: "Keep",
                            icon: "heart.fill",
                            color: .duckSuccess,
                            intensity: keepCueIntensity
                        )
                        .padding(34)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            actionButtons
        }
    }

    private var reviewProgressHeader: some View {
        VStack(spacing: 8) {
            HStack {
                StatusBadge(
                    title: "\(viewModel.reviewedCount) / \(viewModel.totalReviewableCount) reviewed",
                    accent: .duckPink
                )
                Spacer()
                StatusBadge(title: "\(viewModel.remainingCount) left", accent: .duckRose)
            }

            DuckProgressBar(progress: viewModel.progress, color: .duckPink)
                .frame(height: 4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.black)
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button { swipeLeft() } label: {
                Label("Delete", systemImage: "trash.fill")
                    .font(.duckButton)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(Color.duckDanger, in: RoundedRectangle(cornerRadius: 16))
            }
            .accessibilityLabel("Delete photo")
            .disabled(viewModel.isTransitioning)

            Button { swipeRight() } label: {
                Label("Keep", systemImage: "heart.fill")
                    .font(.duckButton)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(Color.duckSuccess, in: RoundedRectangle(cornerRadius: 16))
            }
            .accessibilityLabel("Keep photo")
            .disabled(viewModel.isTransitioning)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 16)
        .background(Color.black)
    }

    private func swipeCue(title: String, icon: String, color: Color, intensity: Double) -> some View {
        Label(title, systemImage: icon)
            .font(.duckCaption.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(color.opacity(0.92), in: Capsule())
            .opacity(intensity)
            .scaleEffect(0.85 + intensity * 0.15)
    }

    // MARK: - Swipe cue intensity (0…1)

    private var deleteCueIntensity: Double {
        guard cardOffset.width < 0 else { return 0 }
        return min(Double(-cardOffset.width) / Double(swipeThreshold), 1)
    }

    private var keepCueIntensity: Double {
        guard cardOffset.width > 0 else { return 0 }
        return min(Double(cardOffset.width) / Double(swipeThreshold), 1)
    }

    // MARK: - Helpers

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
                    Text(error).font(.duckCaption).foregroundStyle(Color.danger)
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
                .padding(.horizontal, 18)
                .padding(.bottom, 20)
            }
            .task(id: "\(Int(targetSize.width.rounded()))x\(Int(targetSize.height.rounded()))") {
                image = await asset.loadImage(
                    targetSize: targetSize,
                    deliveryMode: .highQualityFormat,
                    allowNetwork: true,
                    contentMode: .aspectFill,
                    acceptsDegradedResult: false,
                    timeout: 20
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
