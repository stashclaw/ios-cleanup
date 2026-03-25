import SwiftUI
import Photos

// Shared image cache for this file — detail grid + fullscreen preview reuse the same entries.
fileprivate let _detailImageCache: NSCache<NSString, UIImage> = {
    let c = NSCache<NSString, UIImage>()
    c.countLimit = 120
    c.totalCostLimit = 100 * 1024 * 1024
    return c
}()

struct PhotoGroupDetailView: View {
    let groups: [PhotoGroup]        // all groups in this category
    let startIndex: Int             // which group to show first
    @Binding var markedIDs: Set<String>
    @EnvironmentObject private var purchaseManager: PurchaseManager
    @Environment(\.dismiss) private var dismiss

    @State private var currentIndex: Int = 0

    // Per-group state — reset whenever currentIndex changes.
    /// localIdentifiers of assets the user chose to KEEP (not delete).
    @State private var keptAssets = Set<String>()
    /// The asset the user designated as "best" — defaults to first in group.
    @State private var bestAssetID: String? = nil
    @State private var showPaywall = false
    @State private var deleteError: String?
    /// True briefly after queueing — shows confirmation tick before auto-advancing.
    @State private var showQueued = false
    @State private var showPreview = false
    @State private var previewIndex = 0
    /// Assets re-ranked by quality score; falls back to original order if ranking fails.
    @State private var rankedAssets: [PHAsset] = []
    @State private var isRanking = false

    private var currentGroup: PhotoGroup { groups[currentIndex] }
    private var isFirst: Bool { currentIndex == 0 }
    private var isLast: Bool { currentIndex == groups.count - 1 }

    var body: some View {
        Group {
            if showQueued {
                queuedConfirmation
            } else {
                mainContent
            }
        }
        .navigationTitle("Group \(currentIndex + 1) of \(groups.count)")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            currentIndex = startIndex
            resetGroupState()
        }
        .onChange(of: currentIndex) { _ in
            resetGroupState()
        }
        .task(id: currentIndex) {
            await rankAssets()
        }
        .sheet(isPresented: $showPaywall) { PaywallView().environmentObject(purchaseManager) }
        .fullScreenCover(isPresented: $showPreview) {
            FullscreenPhotoPreview(
                assets: currentGroup.assets,
                startIndex: previewIndex,
                keptAssets: $keptAssets,
                isPurchased: purchaseManager.isPurchased,
                onShowPaywall: { showPreview = false; showPaywall = true }
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .purchaseDidSucceed)) { _ in
            showPaywall = false
        }
    }

    // MARK: - Queued confirmation screen

    private var queuedConfirmation: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(Color(red: 1, green: 0.42, blue: 0.67))
            Text("Queued for Delete")
                .font(.title2.bold())
            Text("Delete from the queue when you're ready")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Spacer()
        }
    }

    // MARK: - Main content

    private var mainContent: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 16) {
                    reasonBadge
                    assetGrid
                    actionButtons
                }
                .padding()
                // Extra bottom padding so content clears the nav bar.
                .padding(.bottom, 72)
            }

            groupNavBar
        }
    }

    // MARK: - Bottom group navigation bar

    private var groupNavBar: some View {
        HStack(spacing: 0) {
            // Prev button
            Button {
                guard !isFirst else { return }
                withAnimation { currentIndex -= 1 }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("Prev")
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isFirst ? Color.secondary : Color(red: 1, green: 0.42, blue: 0.67))
            }
            .disabled(isFirst)
            .frame(maxWidth: .infinity, alignment: .leading)

            // Counter
            Text("\(currentIndex + 1) of \(groups.count)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()

            // Skip / Done button
            Button {
                if isLast {
                    dismiss()
                } else {
                    withAnimation { currentIndex += 1 }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(isLast ? "Done" : "Skip")
                    if !isLast {
                        Image(systemName: "chevron.right")
                    }
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color(red: 1, green: 0.42, blue: 0.67))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: - Reason badge

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

    // MARK: - Asset grid

    private var assetGrid: some View {
        let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
        let displayAssets = rankedAssets.isEmpty ? currentGroup.assets : rankedAssets
        return VStack(spacing: 8) {
            if isRanking {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Analyzing quality…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(Array(displayAssets.enumerated()), id: \.element.localIdentifier) { index, asset in
                    let id = asset.localIdentifier
                    AssetCompareCell(
                        asset: asset,
                        isBest: bestAssetID == id,
                        isKept: keptAssets.contains(id),
                        onPreview: {
                            previewIndex = index
                            showPreview = true
                        },
                        onSetBest: bestAssetID == id ? nil : {
                            bestAssetID = id
                            keptAssets = [id]
                        },
                        onToggleKeep: {
                            if keptAssets.contains(id) {
                                keptAssets.remove(id)
                            } else {
                                keptAssets.insert(id)
                            }
                        }
                    )
                }
            }
        }
    }

    // MARK: - Action buttons

    private var actionButtons: some View {
        let displayAssets = rankedAssets.isEmpty ? currentGroup.assets : rankedAssets
        let deleteCount = displayAssets.filter { !keptAssets.contains($0.localIdentifier) }.count
        return VStack(spacing: 12) {
            if let error = deleteError {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            // Primary: queue all unkept photos for delete (free), then auto-advance.
            Button(action: queueUnselected) {
                Label(
                    deleteCount > 0 ? "Queue \(deleteCount) for Delete" : "All Photos Kept",
                    systemImage: "trash.fill"
                )
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding()
                .background(deleteCount > 0 ? Color.duckPink : Color.secondary.opacity(0.15))
                .foregroundStyle(deleteCount > 0 ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .disabled(deleteCount == 0)

            // Shortcut: reset to keeping only the best.
            Button(action: selectBestOnly) {
                Label("Keep Best Only", systemImage: "star.fill")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.secondary.opacity(0.12))
                    .foregroundStyle(Color.orange)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }

            // Delete entire group including the best photo.
            Button(action: queueAll) {
                Label("Delete Entire Group", systemImage: "trash.slash.fill")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.red.opacity(0.10))
                    .foregroundStyle(Color.red)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    // MARK: - Actions

    /// Resets per-group UI state when the group changes.
    private func resetGroupState() {
        showQueued = false
        rankedAssets = []
        isRanking = false
        let assets = currentGroup.assets
        let alreadyQueued = Set(assets.map(\.localIdentifier)).intersection(markedIDs)
        let defaultKept = Set(assets.map(\.localIdentifier)).subtracting(alreadyQueued)
        keptAssets = defaultKept.isEmpty
            ? Set([assets.first?.localIdentifier].compactMap { $0 })
            : defaultKept
        bestAssetID = assets.first?.localIdentifier
    }

    /// Re-ranks group assets by quality score and updates bestAssetID + keptAssets accordingly.
    private func rankAssets() async {
        isRanking = true
        defer { isRanking = false }

        let assets = currentGroup.assets
        guard assets.count > 1 else {
            // Single-asset group — just set defaults.
            rankedAssets = assets
            applyDefaults(ranked: assets)
            return
        }

        // Fetch scores concurrently.
        var scores: [String: Float] = [:]
        await withTaskGroup(of: (String, Float).self) { group in
            for asset in assets {
                group.addTask {
                    let score = await PhotoQualityAnalyzer.shared.qualityScore(for: asset)
                    return (asset.localIdentifier, score)
                }
            }
            for await (id, score) in group {
                scores[id] = score
            }
        }

        // Sort descending by score; fall back to original order on tie.
        let sorted = assets.sorted { a, b in
            (scores[a.localIdentifier] ?? 0.5) > (scores[b.localIdentifier] ?? 0.5)
        }

        rankedAssets = sorted
        applyDefaults(ranked: sorted)
    }

    /// Sets keptAssets / bestAssetID based on the ranked asset order.
    private func applyDefaults(ranked: [PHAsset]) {
        let alreadyQueued = Set(ranked.map(\.localIdentifier)).intersection(markedIDs)
        let defaultKept = Set(ranked.map(\.localIdentifier)).subtracting(alreadyQueued)
        keptAssets = defaultKept.isEmpty
            ? Set([ranked.first?.localIdentifier].compactMap { $0 })
            : defaultKept
        bestAssetID = ranked.first?.localIdentifier
    }

    /// Queue all photos NOT in keptAssets for deletion, then auto-advance after 0.4 s.
    private func queueUnselected() {
        let displayAssets = rankedAssets.isEmpty ? currentGroup.assets : rankedAssets
        displayAssets
            .filter { !keptAssets.contains($0.localIdentifier) }
            .forEach { markedIDs.insert($0.localIdentifier) }

        showQueued = true

        Task {
            try? await Task.sleep(nanoseconds: 400_000_000) // 0.4 s
            if isLast {
                dismiss()
            } else {
                withAnimation { currentIndex += 1 }
            }
        }
    }

    /// Queues every photo in the group for deletion (including the best).
    private func queueAll() {
        keptAssets = []
        bestAssetID = nil
        let displayAssets = rankedAssets.isEmpty ? currentGroup.assets : rankedAssets
        displayAssets.forEach { markedIDs.insert($0.localIdentifier) }
        showQueued = true
        Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if isLast { dismiss() } else { withAnimation { currentIndex += 1 } }
        }
    }

    /// Reset kept set to just the best photo.
    private func selectBestOnly() {
        let firstRanked = rankedAssets.first?.localIdentifier ?? currentGroup.assets.first?.localIdentifier
        if let bestID = bestAssetID ?? firstRanked {
            keptAssets = [bestID]
        }
    }

    // MARK: - Reason badge helpers

    private var badgeIcon: String {
        switch currentGroup.reason {
        case .nearDuplicate, .exactDuplicate: return "doc.on.doc.fill"
        case .visuallySimilar: return "eye.fill"
        case .burstShot: return "burst.fill"
        }
    }

    private var badgeLabel: String {
        switch currentGroup.reason {
        case .nearDuplicate:   return "Near Duplicate"
        case .exactDuplicate:  return "Exact Duplicate"
        case .visuallySimilar: return "Visually Similar"
        case .burstShot:       return "Burst Shot"
        }
    }

    private var badgeColor: Color {
        switch currentGroup.reason {
        case .nearDuplicate, .exactDuplicate: return .red
        case .visuallySimilar: return .orange
        case .burstShot: return .purple
        }
    }
}

// MARK: - Asset Compare Cell

private struct AssetCompareCell: View {
    let asset: PHAsset
    let isBest: Bool
    let isKept: Bool        // true = user chose to keep, false = will be queued for delete
    let onPreview: () -> Void
    let onSetBest: (() -> Void)?   // nil when already best
    let onToggleKeep: () -> Void

    @State private var image: UIImage?

    private var aspectRatio: CGFloat {
        guard asset.pixelHeight > 0 else { return 1 }
        return CGFloat(asset.pixelWidth) / CGFloat(asset.pixelHeight)
    }

    var body: some View {
        Button(action: onPreview) {
            ZStack(alignment: .bottomLeading) {
                imageContent
                    // Green tint = kept, red tint = will be deleted
                    .overlay(isKept ? Color.green.opacity(0.18) : Color.red.opacity(0.22))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(isKept ? Color.green : Color.red.opacity(0.7), lineWidth: 2)
                    )

                // BEST badge / Set as Best button
                if isBest {
                    Text("BEST")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.green)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .padding(6)
                } else if let setAsBest = onSetBest {
                    Button(action: setAsBest) {
                        Label("Set Best", systemImage: "star")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.55))
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                }
            }
            // Keep/delete toggle — top-right circle
            .overlay(alignment: .topTrailing) {
                Button(action: onToggleKeep) {
                    ZStack {
                        Circle()
                            .fill(isKept ? Color.green : Color.red.opacity(0.85))
                            .frame(width: 24, height: 24)
                        Image(systemName: isKept ? "checkmark" : "trash")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)
                .frame(width: 44, height: 44)
                .padding(2)
            }
        }
        .buttonStyle(.plain)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: asset.localIdentifier) { image = await loadImage() }
    }

    private var imageContent: some View {
        Group {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.gray.opacity(0.15)
                    .overlay(ProgressView())
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(aspectRatio, contentMode: .fill)
        .frame(maxHeight: 300)
        .clipped()
    }

    private func loadImage() async -> UIImage? {
        let key = "\(asset.localIdentifier)_grid400" as NSString
        if let cached = _detailImageCache.object(forKey: key) { return cached }
        return await withCheckedContinuation { continuation in
            var resumed = false
            let opts = PHImageRequestOptions()
            opts.deliveryMode = .opportunistic
            opts.isNetworkAccessAllowed = true
            opts.isSynchronous = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 400, height: 400),
                contentMode: .aspectFit,
                options: opts
            ) { image, info in
                guard !resumed else { return }
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !isDegraded else { return }
                resumed = true
                if let image {
                    let cost = Int(image.size.width * image.size.height * 4)
                    _detailImageCache.setObject(image, forKey: key, cost: cost)
                }
                continuation.resume(returning: image)
            }
        }
    }
}

// MARK: - Fullscreen Photo Preview

private struct FullscreenPhotoPreview: View {
    let assets: [PHAsset]
    let startIndex: Int
    @Binding var keptAssets: Set<String>
    let isPurchased: Bool
    let onShowPaywall: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int = 0
    @GestureState private var dragY: CGFloat = 0

    var body: some View {
        let opacity = max(0.0, 1.0 - abs(dragY) / 180.0)

        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // Top bar
                HStack {
                    Text("\(currentIndex + 1) / \(assets.count)")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                    Spacer()
                    if keptAssets.contains(assets[currentIndex].localIdentifier) {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                            Text("Keeping")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.green)
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "trash.fill")
                            Text("Will Delete")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.red)
                    }
                    Spacer()
                    Button("Done") { dismiss() }
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 10)

                // Photo pager
                TabView(selection: $currentIndex) {
                    ForEach(Array(assets.enumerated()), id: \.offset) { idx, asset in
                        PreviewPhotoCell(asset: asset)
                            .tag(idx)
                            .gesture(
                                TapGesture(count: 2).onEnded { toggleKeep(asset: asset) }
                            )
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .offset(y: dragY)
                .gesture(
                    DragGesture(minimumDistance: 20)
                        .updating($dragY) { value, state, _ in
                            if value.translation.height > 0 { state = value.translation.height }
                        }
                        .onEnded { value in
                            if value.translation.height > 100 { dismiss() }
                        }
                )

                // Thumbnail strip
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Array(assets.enumerated()), id: \.offset) { idx, asset in
                                ThumbnailStripCell(
                                    asset: asset,
                                    isActive: idx == currentIndex,
                                    isMarked: !keptAssets.contains(asset.localIdentifier)
                                )
                                .id(idx)
                                .onTapGesture { currentIndex = idx }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .onChange(of: currentIndex) { idx in
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo(idx, anchor: .center)
                        }
                    }
                }
                .frame(height: 76)
                .padding(.vertical, 8)
            }
        }
        .opacity(opacity)
        .onAppear { currentIndex = startIndex }
    }

    private func toggleKeep(asset: PHAsset) {
        let id = asset.localIdentifier
        if keptAssets.contains(id) {
            if keptAssets.count > 1 { keptAssets.remove(id) }
        } else {
            keptAssets.insert(id)
        }
    }
}

// MARK: - Preview Photo Cell (fullscreen)

private struct PreviewPhotoCell: View {
    let asset: PHAsset
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .task { image = await loadImage() }
    }

    private func loadImage() async -> UIImage? {
        let key = "\(asset.localIdentifier)_preview1080" as NSString
        if let cached = _detailImageCache.object(forKey: key) { return cached }
        return await withCheckedContinuation { continuation in
            var resumed = false
            let opts = PHImageRequestOptions()
            opts.deliveryMode = .highQualityFormat
            opts.isNetworkAccessAllowed = true
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 1080, height: 1080),
                contentMode: .aspectFit,
                options: opts
            ) { image, _ in
                guard !resumed else { return }
                resumed = true
                if let image {
                    let cost = Int(image.size.width * image.size.height * 4)
                    _detailImageCache.setObject(image, forKey: key, cost: cost)
                }
                continuation.resume(returning: image)
            }
        }
    }
}

// MARK: - Thumbnail Strip Cell

private struct ThumbnailStripCell: View {
    let asset: PHAsset
    let isActive: Bool
    let isMarked: Bool
    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let img = image {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.gray.opacity(0.3)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        isActive ? Color.white : (isMarked ? Color.red.opacity(0.8) : Color.clear),
                        lineWidth: isActive ? 2.5 : 1.5
                    )
            )
            .opacity(isActive ? 1 : 0.6)

            if isMarked {
                Image(systemName: "trash.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(3)
                    .background(Color.red, in: Circle())
                    .padding(3)
            }
        }
        .task { image = await loadThumbnail() }
    }

    private func loadThumbnail() async -> UIImage? {
        let key = "\(asset.localIdentifier)_strip" as NSString
        if let cached = _detailImageCache.object(forKey: key) { return cached }
        return await withCheckedContinuation { continuation in
            var resumed = false
            let opts = PHImageRequestOptions()
            opts.deliveryMode = .fastFormat
            opts.isNetworkAccessAllowed = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 120, height: 120),
                contentMode: .aspectFill,
                options: opts
            ) { image, _ in
                guard !resumed else { return }
                resumed = true
                if let image { _detailImageCache.setObject(image, forKey: key) }
                continuation.resume(returning: image)
            }
        }
    }
}
