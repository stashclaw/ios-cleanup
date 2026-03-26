import SwiftUI
import Photos

struct GroupReviewView: View {
    @ObservedObject var viewModel: GroupReviewViewModel
    @EnvironmentObject private var purchaseManager: PurchaseManager
    @Environment(\.dismiss) private var dismiss

    let onComplete: () -> Void

    private let bg = Color(red: 0.05, green: 0.05, blue: 0.08)

    init(viewModel: GroupReviewViewModel, onComplete: @escaping () -> Void = {}) {
        self.viewModel = viewModel
        self.onComplete = onComplete
    }

    @State private var showCacheBanner = false
    @State private var showPaywall = false
    @State private var isDeleting = false

    var body: some View {
        ZStack {
            bg.ignoresSafeArea()
            if viewModel.isComplete { summaryScreen } else { reviewScreen }
        }
        .onAppear {
            if viewModel.hasCachedSession && viewModel.currentIndex == 0 {
                showCacheBanner = true
            }
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView().environmentObject(purchaseManager)
        }
        .onReceive(NotificationCenter.default.publisher(for: .purchaseDidSucceed)) { _ in
            showPaywall = false
            isDeleting = true
            Task {
                try? await viewModel.commitDeletes()
                isDeleting = false
                dismiss()
                onComplete()
            }
        }
    }

    // MARK: - Review screen

    private var reviewScreen: some View {
        VStack(spacing: 0) {
            if showCacheBanner { cacheBanner }

            progressHeader
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 14)

            if let group = viewModel.currentGroup {
                photoStrip(group: group)

                groupInfoRow(group: group)
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
            }

            Spacer()

            if viewModel.markedIDs.count > 0 {
                committedCountBar
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }

            actionRow
                .padding(.horizontal, 20)
                .padding(.bottom, 36)
        }
    }

    // MARK: - Progress header

    private var progressHeader: some View {
        VStack(spacing: 10) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.5))
                        .frame(width: 32, height: 32)
                        .background(Color.white.opacity(0.08), in: Circle())
                }
                Spacer()
                Text("Group \(viewModel.currentIndex + 1) of \(viewModel.queue.count)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.7))
                Spacer()
                Color.clear.frame(width: 32, height: 32)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 4)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LinearGradient(
                            colors: [Color(red: 1, green: 0.42, blue: 0.67),
                                     Color(red: 0.45, green: 0.4, blue: 1)],
                            startPoint: .leading, endPoint: .trailing
                        ))
                        .frame(width: geo.size.width * viewModel.progress, height: 4)
                        .animation(.easeInOut(duration: 0.3), value: viewModel.progress)
                }
            }
            .frame(height: 4)
        }
    }

    // MARK: - Photo strip

    private func photoStrip(group: PhotoGroup) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(group.assets, id: \.localIdentifier) { asset in
                    let id = asset.localIdentifier
                    let isBest   = viewModel.bestIDForCurrentGroup == id
                    let isMarked = viewModel.pendingMarked.contains(id)

                    ReviewPhotoCell(
                        asset: asset,
                        isBest: isBest,
                        isMarked: isMarked,
                        onSetBest: { viewModel.selectBest(id) },
                        onToggleMark: { viewModel.togglePendingMark(id) }
                    )
                }
            }
            .padding(.horizontal, 20)
        }
    }

    // MARK: - Group info row

    private func groupInfoRow(group: PhotoGroup) -> some View {
        HStack(spacing: 8) {
            Text("\(group.assets.count) photos in group")
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.35))

            let pending = viewModel.pendingCount
            if pending > 0 {
                Text("·")
                    .foregroundStyle(Color.white.opacity(0.2))
                Text("\(pending) queued")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(red: 1, green: 0.42, blue: 0.67).opacity(0.8))
            }
            Spacer()

            // Hint label
            Text("Tap to change best  ·  Keep to unqueue")
                .font(.system(size: 10))
                .foregroundStyle(Color.white.opacity(0.2))
        }
    }

    // MARK: - Committed count bar (shows total across all reviewed groups)

    private var committedCountBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "trash.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color(red: 1, green: 0.42, blue: 0.67))
            Text("\(viewModel.markedIDs.count) photo\(viewModel.markedIDs.count == 1 ? "" : "s") queued from \(viewModel.markedGroupCount) group\(viewModel.markedGroupCount == 1 ? "" : "s")")
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.5))
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color(red: 1, green: 0.42, blue: 0.67).opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Action row

    private var actionRow: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button(action: { viewModel.skipGroup() }) {
                    Text("Skip")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.55))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                }

                Button(action: { viewModel.queueAndAdvance() }) {
                    HStack(spacing: 5) {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 13))
                        Text(viewModel.pendingCount > 0
                             ? "Queue \(viewModel.pendingCount) for Delete"
                             : "Keep All & Next")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        LinearGradient(
                            colors: viewModel.pendingCount > 0
                                ? [Color(red: 1, green: 0.42, blue: 0.67),
                                   Color(red: 0.45, green: 0.4, blue: 1)]
                                : [Color.white.opacity(0.15), Color.white.opacity(0.1)],
                            startPoint: .leading, endPoint: .trailing
                        ),
                        in: RoundedRectangle(cornerRadius: 14)
                    )
                }
            }

            // Delete every photo in the group (including the best).
            Button(action: { viewModel.deleteAllAndAdvance() }) {
                HStack(spacing: 5) {
                    Image(systemName: "trash.slash.fill")
                        .font(.system(size: 12))
                    Text("Delete Entire Group")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(Color.red.opacity(0.85))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    // MARK: - Cache banner

    private var cacheBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 16))
                .foregroundStyle(Color(red: 0.98, green: 0.57, blue: 0.24))
            VStack(alignment: .leading, spacing: 4) {
                Text("\(viewModel.markedIDs.count) photos queued from a previous session")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                HStack(spacing: 12) {
                    Button("Continue") { showCacheBanner = false }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(red: 0.29, green: 0.85, blue: 0.6))
                    Button("Start Fresh") {
                        viewModel.startFresh()
                        showCacheBanner = false
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.4))
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(red: 0.98, green: 0.57, blue: 0.24).opacity(0.12))
    }

    // MARK: - Summary screen

    private var summaryScreen: some View {
        VStack(spacing: 0) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color(red: 1, green: 0.42, blue: 0.67).opacity(0.12))
                    .frame(width: 100, height: 100)
                Image(systemName: viewModel.markedIDs.isEmpty ? "checkmark.circle" : "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(Color(red: 1, green: 0.42, blue: 0.67))
            }

            Text("Review Complete")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)
                .padding(.top, 20)

            if viewModel.markedIDs.isEmpty {
                Text("No photos queued for deletion")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.white.opacity(0.4))
                    .padding(.top, 6)
            } else {
                Text("\(viewModel.markedIDs.count) photo\(viewModel.markedIDs.count == 1 ? "" : "s") from \(viewModel.markedGroupCount) group\(viewModel.markedGroupCount == 1 ? "" : "s")")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .padding(.top, 6)
            }

            if let error = viewModel.deleteError {
                Text(error)
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
            }

            Spacer()

            VStack(spacing: 12) {
                if !viewModel.markedIDs.isEmpty {
                    Button {
                        guard purchaseManager.isPurchased else { showPaywall = true; return }
                        isDeleting = true
                        Task {
                            try? await viewModel.commitDeletes()
                            isDeleting = false
                            dismiss()
                            onComplete()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if isDeleting {
                                ProgressView().tint(.white).scaleEffect(0.8)
                            } else {
                                Image(systemName: purchaseManager.isPurchased ? "trash.fill" : "lock.fill")
                            }
                            Text(purchaseManager.isPurchased
                                 ? (isDeleting ? "Deleting…"
                                    : "Delete \(viewModel.markedIDs.count) Photo\(viewModel.markedIDs.count == 1 ? "" : "s")")
                                 : "Delete Photos 🔒")
                        }
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            LinearGradient(
                                colors: [Color(red: 1, green: 0.42, blue: 0.67),
                                         Color(red: 0.45, green: 0.4, blue: 1)],
                                startPoint: .leading, endPoint: .trailing
                            ),
                            in: RoundedRectangle(cornerRadius: 16)
                        )
                    }
                    .disabled(isDeleting)
                }

                Button {
                    viewModel.startFresh()
                    dismiss()
                } label: {
                    Text("Start Over")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.55))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                }

                Button {
                    viewModel.clearCache()
                    dismiss()
                } label: {
                    Text("Cancel")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.white.opacity(0.35))
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 52)
        }
    }
}

// MARK: - Review Photo Cell

private struct ReviewPhotoCell: View {
    let asset: PHAsset
    let isBest: Bool
    let isMarked: Bool
    let onSetBest: () -> Void
    let onToggleMark: () -> Void

    @State private var thumbnail: UIImage?
    @State private var requestID: PHImageRequestID?
    @State private var qualityLabels: [PhotoQualityLabel] = []

    private let size: CGFloat = 155

    var body: some View {
        ZStack(alignment: .bottom) {
            // Photo + state overlay
            ZStack(alignment: .topLeading) {
                // Background / image
                Group {
                    if let img = thumbnail {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color.white.opacity(0.06)
                            .overlay(ProgressView().scaleEffect(0.65).tint(.white))
                    }
                }
                .frame(width: size, height: size)
                .clipped()
                // Red tint when queued
                .overlay(isMarked ? Color.red.opacity(0.28) : Color.clear)

                // BEST badge — top-left (green)
                if isBest {
                    Label("BEST", systemImage: "star.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color(red: 0.18, green: 0.78, blue: 0.54), in: Capsule())
                        .padding(8)
                }

                // QUEUED label — bottom-left, only when marked
                if isMarked {
                    Label("QUEUED", systemImage: "clock.badge.xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.red.opacity(0.75), in: Capsule())
                        .padding(8)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            // Tap cell: set as best (non-best photos), or toggle mark (best photo when already marked)
            .contentShape(Rectangle())
            .onTapGesture {
                if !isBest { onSetBest() } else if isMarked { onToggleMark() }
            }

            // ↩ Keep button — top-right, only when marked
            // Green "Keep" pill clearly signals rescue/undo, not another delete action
            .overlay(alignment: .topTrailing) {
                if isMarked {
                    Button(action: onToggleMark) {
                        Label("Keep", systemImage: "arrow.uturn.left")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(Color(red: 0.18, green: 0.78, blue: 0.54), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                }
            }

            // Quality labels — bottom strip (shown only if labels exist)
            if !qualityLabels.isEmpty {
                qualityLabelStrip
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isMarked ? Color.red.opacity(0.7) :
                    isBest   ? Color(red: 0.18, green: 0.78, blue: 0.54).opacity(0.6) :
                               Color.white.opacity(0.1),
                    lineWidth: (isMarked || isBest) ? 2.5 : 1
                )
        )
        .onAppear { loadImage(); loadQuality() }
        .onDisappear { cancelImage() }
    }

    // MARK: - Quality label strip

    private var qualityLabelStrip: some View {
        HStack(spacing: 4) {
            ForEach(qualityLabels, id: \.rawValue) { label in
                HStack(spacing: 3) {
                    Image(systemName: label.icon)
                        .font(.system(size: 8, weight: .semibold))
                    Text(label.rawValue)
                        .font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(Color.black.opacity(0.65), in: Capsule())
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color.clear, Color.black.opacity(0.45)],
                startPoint: .top, endPoint: .bottom
            )
        )
    }

    // MARK: - Image loading

    private func loadImage() {
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .opportunistic
        opts.isNetworkAccessAllowed = false
        opts.resizeMode = .fast
        requestID = PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: 310, height: 310),
            contentMode: .aspectFill,
            options: opts
        ) { image, info in
            guard let image else { return }
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            Task { @MainActor in
                if thumbnail == nil || !degraded { thumbnail = image }
            }
        }
    }

    private func cancelImage() {
        if let id = requestID {
            PHImageManager.default().cancelImageRequest(id)
            requestID = nil
        }
    }

    // MARK: - Quality analysis

    private func loadQuality() {
        Task {
            let labels = await PhotoQualityAnalyzer.shared.labels(for: asset)
            await MainActor.run { qualityLabels = labels }
        }
    }
}
