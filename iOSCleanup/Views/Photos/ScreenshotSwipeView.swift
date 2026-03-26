import SwiftUI
import Photos

// MARK: - Shared cache + screen-size constants

private let _swipeCellCache: NSCache<NSString, UIImage> = {
    let c = NSCache<NSString, UIImage>()
    c.countLimit = 30
    c.totalCostLimit = 60 * 1024 * 1024
    return c
}()

/// Card point dimensions (main-actor because UIScreen is main-actor isolated).
@MainActor
private let _swipeCardPt: CGSize = {
    let w = UIScreen.main.bounds.width - 40   // 20pt padding × 2
    return CGSize(width: w, height: w * (19.5 / 9))
}()

/// Pixel dimensions for loading full-resolution screenshots at display scale.
@MainActor
private let _swipeCardPx: CGSize = {
    let scale = UIScreen.main.scale
    let pt = _swipeCardPt
    return CGSize(width: pt.width * scale, height: pt.height * scale)
}()

// MARK: - ScreenshotSwipeView

/// Card-by-card keep/delete review flow for a flat [PHAsset] list.
struct ScreenshotSwipeView: View {
    let assets: [PHAsset]
    @Environment(\.dismiss) private var dismiss

    @State private var currentIndex = 0
    @State private var deletedIDs   = Set<String>()
    @State private var keptIDs      = Set<String>()
    @State private var isComplete   = false
    @State private var isDeleting   = false
    @State private var deleteError: String?
    @State private var dragOffset: CGFloat = 0
    @State private var dragOpacity: Double = 1

    private let bg = Color(red: 0.05, green: 0.05, blue: 0.08)

    private var current: PHAsset? {
        guard currentIndex < assets.count else { return nil }
        return assets[currentIndex]
    }

    var body: some View {
        ZStack {
            bg.ignoresSafeArea()
            if isComplete {
                summaryScreen
            } else {
                reviewScreen
            }
        }
        .navigationTitle("Review Screenshots")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(bg, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    // MARK: - Review screen

    private var reviewScreen: some View {
        VStack(spacing: 0) {
            progressBar
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 16)

            if let asset = current {
                SwipeCard(asset: asset, dragOffset: dragOffset)
                    .padding(.horizontal, 20)
                    .offset(x: dragOffset)
                    .opacity(dragOpacity)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                dragOffset = value.translation.width
                                let absX = abs(dragOffset)
                                dragOpacity = Double(max(0.4, 1 - absX / 300))
                            }
                            .onEnded { value in
                                let threshold: CGFloat = 100
                                if value.translation.width < -threshold {
                                    commitDelete(asset)
                                } else if value.translation.width > threshold {
                                    commitKeep(asset)
                                } else {
                                    withAnimation(.spring(response: 0.3)) {
                                        dragOffset = 0
                                        dragOpacity = 1
                                    }
                                }
                            }
                    )
                    .animation(.interactiveSpring(), value: dragOffset)
            }

            Spacer()

            if let error = deleteError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 4)
            }

            actionButtons
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
        }
    }

    // MARK: - Progress bar

    private var progressBar: some View {
        HStack(spacing: 6) {
            Text("\(currentIndex + 1) / \(assets.count)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.4))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(Color(red: 0.18, green: 0.72, blue: 0.95))
                        .frame(width: geo.size.width * CGFloat(currentIndex) / CGFloat(max(assets.count - 1, 1)))
                        .animation(.easeInOut(duration: 0.2), value: currentIndex)
                }
            }
            .frame(height: 4)
        }
    }

    // MARK: - Action buttons

    private var actionButtons: some View {
        HStack(spacing: 16) {
            // Delete
            Button {
                guard let asset = current else { return }
                commitDelete(asset)
            } label: {
                VStack(spacing: 6) {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 22))
                    Text("Delete")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(Color(red: 1, green: 0.35, blue: 0.35).opacity(0.85), in: RoundedRectangle(cornerRadius: 20))
            }
            .buttonStyle(.plain)

            // Keep
            Button {
                guard let asset = current else { return }
                commitKeep(asset)
            } label: {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 22, weight: .semibold))
                    Text("Keep")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(Color(red: 0.18, green: 0.72, blue: 0.6).opacity(0.85), in: RoundedRectangle(cornerRadius: 20))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Summary screen

    private var summaryScreen: some View {
        VStack(spacing: 28) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color(red: 0.18, green: 0.72, blue: 0.95).opacity(0.15))
                    .frame(width: 100, height: 100)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(Color(red: 0.18, green: 0.72, blue: 0.95))
            }

            VStack(spacing: 8) {
                Text("Review Complete")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                HStack(spacing: 24) {
                    statPill(icon: "trash", label: "\(deletedIDs.count) to delete",
                             color: Color(red: 1, green: 0.35, blue: 0.35))
                    statPill(icon: "checkmark", label: "\(keptIDs.count) kept",
                             color: Color(red: 0.18, green: 0.72, blue: 0.6))
                }
            }

            if let error = deleteError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            if !deletedIDs.isEmpty {
                Button {
                    Task { await performDeletes() }
                } label: {
                    if isDeleting {
                        ProgressView().tint(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    } else {
                        Text("Delete \(deletedIDs.count) Screenshot\(deletedIDs.count == 1 ? "" : "s")")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }
                }
                .background(Color(red: 1, green: 0.35, blue: 0.35).opacity(0.85), in: RoundedRectangle(cornerRadius: 16))
                .disabled(isDeleting)
                .padding(.horizontal, 24)
            }

            Button("Done") { dismiss() }
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.5))

            Spacer()
        }
    }

    private func statPill(icon: String, label: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
            Text(label)
                .font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(color.opacity(0.12), in: Capsule())
    }

    // MARK: - Navigation helpers

    private func commitDelete(_ asset: PHAsset) {
        deletedIDs.insert(asset.localIdentifier)
        advance()
    }

    private func commitKeep(_ asset: PHAsset) {
        keptIDs.insert(asset.localIdentifier)
        advance()
    }

    private func advance() {
        withAnimation(.easeInOut(duration: 0.15)) {
            dragOffset = 0
            dragOpacity = 1
        }
        if currentIndex + 1 >= assets.count {
            isComplete = true
        } else {
            currentIndex += 1
        }
    }

    // MARK: - Bulk delete

    private func performDeletes() async {
        isDeleting = true
        defer { isDeleting = false }
        let toDelete = assets.filter { deletedIDs.contains($0.localIdentifier) }
        guard !toDelete.isEmpty else { dismiss(); return }
        let bytes = toDelete.reduce(Int64(0)) { sum, asset in
            let size = PHAssetResource.assetResources(for: asset)
                .first.flatMap { $0.value(forKey: "fileSize") as? Int64 } ?? 0
            return sum + size
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(toDelete as NSFastEnumeration)
            }
            if bytes > 0 {
                NotificationCenter.default.post(
                    name: .didFreeBytes, object: nil, userInfo: ["bytes": bytes]
                )
            }
            dismiss()
        } catch {
            deleteError = error.localizedDescription
        }
    }
}

// MARK: - SwipeCard (self-loading screenshot cell)

private struct SwipeCard: View {
    let asset: PHAsset
    let dragOffset: CGFloat

    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID?
    @State private var showFullScreen = false

    /// Rotation hint: tilt slightly toward the drag direction
    private var rotationDegrees: Double { Double(dragOffset) / 20 }
    /// Action label: show "DELETE" on leftward drag, "KEEP" on rightward drag
    private var actionLabel: (text: String, color: Color)? {
        if dragOffset < -40 { return ("DELETE", Color(red: 1, green: 0.35, blue: 0.35)) }
        if dragOffset >  40 { return ("KEEP",   Color(red: 0.18, green: 0.72, blue: 0.6)) }
        return nil
    }

    var body: some View {
        let cardPt = _swipeCardPt
        return ZStack(alignment: .topLeading) {
            Group {
                if let img = image {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.white.opacity(0.07)
                        .overlay(ProgressView().tint(Color.white.opacity(0.4)))
                }
            }
            .frame(width: cardPt.width, height: cardPt.height)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
            .onTapGesture(count: 2) { showFullScreen = true }

            if let label = actionLabel {
                Text(label.text)
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(label.color)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(label.color.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(label.color.opacity(0.6), lineWidth: 2)
                    )
                    .rotationEffect(.degrees(-15))
                    .padding(20)
                    .opacity(min(1, Double(abs(dragOffset) - 40) / 60))
            }
        }
        .frame(width: cardPt.width, height: cardPt.height)
        .rotationEffect(.degrees(rotationDegrees))
        .shadow(color: .black.opacity(0.4), radius: 20, x: 0, y: 8)
        .task { await loadImage() }
        .onDisappear { cancelLoad() }
        .fullScreenCover(isPresented: $showFullScreen) {
            FullScreenPhotoView(asset: asset)
        }
    }

    private func loadImage() async {
        let key = "\(asset.localIdentifier)_swipe" as NSString
        if let cached = _swipeCellCache.object(forKey: key) {
            image = cached
            return
        }

        // Phase 1: show locally-cached thumbnail immediately (fast, possibly degraded)
        // Phase 2: full-quality version loads from iCloud if needed
        // Both phases update `image`; only the final non-degraded version is cached.
        let px = _swipeCardPx
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .opportunistic       // deliver local draft first, then full quality
        opts.isNetworkAccessAllowed = true       // allow iCloud download for full quality
        opts.resizeMode = .exact

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var resumed = false
            requestID = PHImageManager.default().requestImage(
                for: asset,
                targetSize: px,
                contentMode: .aspectFill,
                options: opts
            ) { img, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                let isDone = !isDegraded
                if let img {
                    if isDone {
                        _swipeCellCache.setObject(img, forKey: key,
                                                  cost: Int(img.size.width * img.size.height * 4))
                    }
                    // Always update image (both passes) so user sees something immediately
                    DispatchQueue.main.async { self.image = img }
                }
                if isDone, !resumed {
                    resumed = true
                    continuation.resume()
                }
            }
        }
    }

    private func cancelLoad() {
        if let id = requestID {
            PHImageManager.default().cancelImageRequest(id)
            requestID = nil
        }
    }
}

// MARK: - Full-screen photo viewer

private struct FullScreenPhotoView: View {
    let asset: PHAsset
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .ignoresSafeArea()
            } else {
                ProgressView().tint(.white)
            }
            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.white)
                            .padding(16)
                    }
                }
                Spacer()
            }
        }
        .task { await loadFullResImage() }
    }

    private func loadFullResImage() async {
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .highQualityFormat
        opts.isNetworkAccessAllowed = true
        opts.resizeMode = .none
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var resumed = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: PHImageManagerMaximumSize,
                contentMode: .aspectFit,
                options: opts
            ) { img, info in
                let isDone = !((info?[PHImageResultIsDegradedKey] as? Bool) ?? false)
                if let img { DispatchQueue.main.async { self.image = img } }
                if isDone, !resumed { resumed = true; continuation.resume() }
            }
        }
    }
}
