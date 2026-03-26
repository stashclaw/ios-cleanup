import SwiftUI
import Photos

struct ScreenshotsResultsView: View {
    @EnvironmentObject private var purchaseManager: PurchaseManager
    @EnvironmentObject private var homeViewModel: HomeViewModel

    private var assets: [PHAsset] { homeViewModel.screenshotAssets }

    @State private var selectedAssets = Set<String>()
    @State private var isDeleting = false
    @State private var deleteError: String?
    @State private var showPaywall = false
    @State private var visibleCount = 60          // progressive loading cap across all sections

    @State private var showSwipeReview = false

    // OCR tagging
    @State private var assetTags: [String: ScreenshotTag] = [:]
    @State private var isTagging = false
    @State private var selectedTag: ScreenshotTag? = nil

    // Age buckets: screenshots older than 30 days are "safe to delete".
    private static let oldDays = 30
    private var cutoff: Date {
        Calendar.current.date(byAdding: .day, value: -Self.oldDays, to: Date()) ?? Date()
    }

    /// All assets after applying the active tag filter.
    private var filteredAssets: [PHAsset] {
        guard let tag = selectedTag else { return assets }
        return assets.filter { assetTags[$0.localIdentifier] == tag }
    }

    private var oldAssets: [PHAsset]    { filteredAssets.filter { ($0.creationDate ?? .distantPast) < cutoff } }
    private var recentAssets: [PHAsset] { filteredAssets.filter { ($0.creationDate ?? .distantPast) >= cutoff } }

    /// Tags that have at least one matching asset — determines which pills to show.
    private var presentTags: [ScreenshotTag] {
        ScreenshotTag.allCases.filter { tag in
            assets.contains { assetTags[$0.localIdentifier] == tag }
        }
    }

    /// Per-section slice counts. Old items fill first, then recent items get the remainder.
    private var oldVisible: [PHAsset] {
        Array(oldAssets.prefix(min(oldAssets.count, visibleCount)))
    }
    private var recentVisible: [PHAsset] {
        let remainder = max(0, visibleCount - oldAssets.count)
        return Array(recentAssets.prefix(remainder))
    }

    var body: some View {
        Group {
            if assets.isEmpty && homeViewModel.screenshotScanState != .scanning {
                EmptyStateView(
                    title: "No Screenshots",
                    icon: "rectangle.on.rectangle",
                    message: "No screenshots found in your library."
                )
            } else {
                ScrollView {
                    VStack(spacing: 14) {
                        if homeViewModel.screenshotScanState == .scanning {
                            ScanningBanner(message: "Finding screenshots…", color: Color(red: 0.18, green: 0.72, blue: 0.95))
                        }
                        heroCard
                        if !assetTags.isEmpty {
                            tagFilterPills
                        } else if isTagging {
                            HStack(spacing: 8) {
                                ProgressView().scaleEffect(0.75)
                                Text("Tagging screenshots…")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.duckRose)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                        }
                        if let error = deleteError {
                            Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal)
                        }
                        if !oldAssets.isEmpty {
                            sectionHeader(
                                title: "Safe to Delete",
                                subtitle: "\(oldAssets.count) · \(Self.oldDays)+ days old",
                                color: Color(red: 1, green: 0.42, blue: 0.67)
                            )
                            screenshotGrid(for: oldVisible, sentinel: visibleCount < filteredAssets.count)
                        }
                        if !recentAssets.isEmpty {
                            sectionHeader(
                                title: "Recent",
                                subtitle: "\(recentAssets.count) · last \(Self.oldDays) days",
                                color: Color(red: 0.18, green: 0.72, blue: 0.95)
                            )
                            screenshotGrid(for: recentVisible, sentinel: false)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
                .background(Color.duckBlush.ignoresSafeArea())
            }
        }
        .navigationTitle("Screenshots")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard assets.count > 0 && assetTags.isEmpty && !isTagging else { return }
            isTagging = true
            let engine = ScreenshotTagEngine()
            do {
                for try await event in engine.tag(assets: assets) {
                    switch event {
                    case .progress:
                        break   // could show inline progress if desired
                    case .tagsFound(let tags):
                        assetTags = tags
                    }
                }
            } catch {
                // Tagging is best-effort; silently drop errors
            }
            isTagging = false
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                if !assets.isEmpty {
                    NavigationLink(destination: ScreenshotSwipeView(assets: filteredAssets)) {
                        Label("Review", systemImage: "hand.draw")
                            .font(.system(size: 14))
                            .foregroundStyle(Color(red: 0.18, green: 0.72, blue: 0.95))
                    }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if selectedAssets.isEmpty {
                    Button(purchaseManager.isPurchased ? "Select All" : "Select 🔒") {
                        guard purchaseManager.isPurchased else { showPaywall = true; return }
                        assets.prefix(visibleCount).forEach { selectedAssets.insert($0.localIdentifier) }
                    }
                    .font(.system(size: 14))
                    .foregroundStyle(Color.duckPink)
                } else {
                    Button("Delete (\(selectedAssets.count))") {
                        guard purchaseManager.isPurchased else { showPaywall = true; return }
                        Task { await deleteSelected() }
                    }
                    .disabled(isDeleting)
                    .foregroundStyle(Color.duckRose)
                }
            }
        }
        .sheet(isPresented: $showPaywall) { PaywallView().environmentObject(purchaseManager) }
        .onReceive(NotificationCenter.default.publisher(for: .purchaseDidSucceed)) { _ in
            showPaywall = false
        }
    }

    // MARK: - Tag filter pills

    private var tagFilterPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // "All" pill
                Button {
                    selectedTag = nil
                } label: {
                    Text("All")
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            selectedTag == nil
                                ? Color.duckPink
                                : Color.duckSoftPink.opacity(0.15)
                        )
                        .foregroundStyle(
                            selectedTag == nil
                                ? Color.white
                                : Color.duckRose
                        )
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .strokeBorder(
                                    selectedTag == nil ? Color.clear : Color.duckSoftPink.opacity(0.4),
                                    lineWidth: 1
                                )
                        )
                }
                .buttonStyle(.plain)

                ForEach(presentTags, id: \.rawValue) { tag in
                    Button {
                        selectedTag = (selectedTag == tag) ? nil : tag
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: tag.icon)
                                .font(.system(size: 11))
                            Text(tag.rawValue)
                                .font(.system(size: 13, weight: .medium))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            selectedTag == tag
                                ? Color.duckPink
                                : Color.duckSoftPink.opacity(0.15)
                        )
                        .foregroundStyle(
                            selectedTag == tag
                                ? Color.white
                                : Color.duckRose
                        )
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .strokeBorder(
                                    selectedTag == tag ? Color.clear : Color.duckSoftPink.opacity(0.4),
                                    lineWidth: 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
        }
    }

    // MARK: - Hero card

    private var heroCard: some View {
        DuckCard {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(assets.count)")
                        .font(Font.custom("FredokaOne-Regular", size: 32))
                        .foregroundStyle(Color.duckPink)
                    Text("screenshots")
                        .font(.duckCaption)
                        .foregroundStyle(Color.duckRose)
                }
                Spacer()
                if !oldAssets.isEmpty {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("\(oldAssets.count)")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(Color(red: 1, green: 0.42, blue: 0.67))
                        Text("safe to delete")
                            .font(.duckCaption)
                            .foregroundStyle(Color.duckRose)
                    }
                } else {
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.largeTitle)
                        .foregroundStyle(Color.duckSoftPink)
                }
            }
            .padding(16)
        }
    }

    // MARK: - Section header

    private func sectionHeader(title: String, subtitle: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(Color(red: 0.5, green: 0.4, blue: 0.45))
            Spacer()
        }
        .padding(.horizontal)
        .padding(.top, 20)
        .padding(.bottom, 6)
    }

    // MARK: - Photo grid (3 columns, rounded square cells)

    private func screenshotGrid(for slice: [PHAsset], sentinel: Bool) -> some View {
        let gap: CGFloat = 10
        let cardW = (UIScreen.main.bounds.width - 52) / 3    // 16+16 padding + 10+10 gaps
        let cardH = cardW * (19.5 / 9)
        let columns = Array(repeating: GridItem(.flexible(), spacing: gap), count: 3)
        return LazyVGrid(columns: columns, spacing: gap) {
            ForEach(slice, id: \.localIdentifier) { asset in
                ScreenshotCell(
                    asset: asset,
                    isSelected: selectedAssets.contains(asset.localIdentifier),
                    tag: assetTags[asset.localIdentifier],
                    onTap: {
                        if selectedAssets.contains(asset.localIdentifier) {
                            selectedAssets.remove(asset.localIdentifier)
                        } else {
                            selectedAssets.insert(asset.localIdentifier)
                        }
                    }
                )
                .frame(width: cardW, height: cardH)
                .clipped()
            }
            // Sentinel loads the next page — only placed in the first (old) grid.
            if sentinel {
                Color.clear
                    .frame(height: 1)
                    .gridCellColumns(3)
                    .onAppear { visibleCount = min(visibleCount + 60, filteredAssets.count) }
            }
        }
    }

    // MARK: - Delete

    private func deleteSelected() async {
        isDeleting = true
        defer { isDeleting = false }
        let toDelete = assets.filter { selectedAssets.contains($0.localIdentifier) }
        let bytes = toDelete.reduce(Int64(0)) { sum, asset in
            let size = PHAssetResource.assetResources(for: asset)
                .first.flatMap { $0.value(forKey: "fileSize") as? Int64 } ?? 0
            return sum + size
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(toDelete as NSFastEnumeration)
            }
            NotificationCenter.default.post(name: .didFreeBytes, object: nil,
                                            userInfo: ["bytes": bytes, "count": toDelete.count])
            selectedAssets.removeAll()
        } catch {
            deleteError = error.localizedDescription
        }
    }
}

// MARK: - Cell (self-loading — no parent re-render on each load)

// Shared cache — file-level avoids per-view lifecycle issues.
private let _screenshotCellCache: NSCache<NSString, UIImage> = {
    let c = NSCache<NSString, UIImage>()
    c.countLimit = 200
    c.totalCostLimit = 80 * 1024 * 1024   // 80 MB — larger for hi-res thumbnails
    return c
}()

// Pixel size for a 3-column cell on any iPhone (covers 3× display).
// @MainActor because UIScreen.main is main-actor-isolated.
@MainActor
private let _ssCellPixelSize: CGSize = {
    let scale = UIScreen.main.scale
    let cellPt: CGFloat = UIScreen.main.bounds.width / 3
    let w = cellPt * scale
    let h = w * (19.5 / 9)
    return CGSize(width: w, height: h)
}()

@MainActor
private let _ssCardWidth: CGFloat = (UIScreen.main.bounds.width - 52) / 3   // 16+16 padding + 10+10 gaps
@MainActor
private let _ssCardHeight: CGFloat = ((UIScreen.main.bounds.width - 52) / 3) * (19.5 / 9)

private struct ScreenshotCell: View {
    let asset: PHAsset
    let isSelected: Bool
    let tag: ScreenshotTag?
    let onTap: () -> Void

    @State private var thumbnail: UIImage?
    @State private var requestID: PHImageRequestID?
    @State private var isICloud = false

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let img = thumbnail {
                        Image(uiImage: img).resizable().scaledToFill()
                    } else {
                        Color.duckSoftPink.opacity(0.3).overlay(ProgressView().scaleEffect(0.6))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .overlay(isSelected ? Color.duckPink.opacity(0.35) : Color.clear)

                // Top-right: iCloud badge or selection checkmark
                VStack {
                    HStack {
                        Spacer()
                        if isICloud {
                            Image(systemName: "icloud")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.9))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 3)
                                .background(Color.black.opacity(0.55))
                                .clipShape(Capsule())
                                .padding(5)
                        } else if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 20)).foregroundStyle(.white)
                                .background(Circle().fill(Color.duckPink).padding(2))
                                .padding(5)
                        }
                    }
                    Spacer()
                }

                // When iCloud badge shown and item is selected, put checkmark bottom-right
                if isICloud && isSelected {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 18)).foregroundStyle(.white)
                                .background(Circle().fill(Color.duckPink).padding(2))
                                .padding(5)
                        }
                    }
                }

                // Tag badge — bottom-left corner
                if let tag {
                    VStack {
                        Spacer()
                        HStack {
                            HStack(spacing: 3) {
                                Image(systemName: tag.icon)
                                    .font(.system(size: 9, weight: .medium))
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                            .foregroundStyle(Color.secondary)
                            Spacer()
                        }
                        .padding(5)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(isSelected ? Color.duckPink : Color.duckSoftPink.opacity(0.3), lineWidth: isSelected ? 2 : 1))
        .onAppear {
            startLoading()
            isICloud = !Self.isStoredLocally(asset)
        }
        .onDisappear { cancelLoading() }
    }

    private static func isStoredLocally(_ asset: PHAsset) -> Bool {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .photo || $0.type == .video }) else { return true }
        return (resource.value(forKey: "locallyAvailable") as? Bool) ?? true
    }

    private func startLoading() {
        let cacheKey = asset.localIdentifier as NSString
        if let cached = _screenshotCellCache.object(forKey: cacheKey) {
            thumbnail = cached
            return
        }
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .opportunistic   // fast low-res first, then crisp
        opts.isNetworkAccessAllowed = false
        opts.resizeMode = .fast
        requestID = PHImageManager.default().requestImage(
            for: asset,
            targetSize: _ssCellPixelSize,    // correct pixel density — no upscale blur
            contentMode: .aspectFill,
            options: opts
        ) { image, info in
            guard let image else { return }
            let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            if !isDegraded {
                _screenshotCellCache.setObject(
                    image, forKey: cacheKey,
                    cost: Int(image.size.width * image.size.height * 4)
                )
            }
            DispatchQueue.main.async { thumbnail = image }
        }
    }

    private func cancelLoading() {
        if let id = requestID {
            PHImageManager.default().cancelImageRequest(id)
            requestID = nil
        }
    }
}
