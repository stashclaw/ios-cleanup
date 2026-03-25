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

    // Age buckets: screenshots older than 30 days are "safe to delete".
    private static let oldDays = 30
    private var cutoff: Date {
        Calendar.current.date(byAdding: .day, value: -Self.oldDays, to: Date()) ?? Date()
    }
    private var oldAssets: [PHAsset]    { assets.filter { ($0.creationDate ?? .distantPast) < cutoff } }
    private var recentAssets: [PHAsset] { assets.filter { ($0.creationDate ?? .distantPast) >= cutoff } }

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
                        if let error = deleteError {
                            Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal)
                        }
                        if !oldAssets.isEmpty {
                            sectionHeader(
                                title: "Safe to Delete",
                                subtitle: "\(oldAssets.count) · \(Self.oldDays)+ days old",
                                color: Color(red: 1, green: 0.42, blue: 0.67)
                            )
                            screenshotGrid(for: oldVisible, sentinel: visibleCount < assets.count)
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
        .toolbar {
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
                    .onAppear { visibleCount = min(visibleCount + 60, assets.count) }
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
            if bytes > 0 {
                NotificationCenter.default.post(name: .didFreeBytes, object: nil,
                                                userInfo: ["bytes": bytes])
            }
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
    let onTap: () -> Void

    @State private var thumbnail: UIImage?
    @State private var requestID: PHImageRequestID?

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

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20)).foregroundStyle(.white)
                        .background(Circle().fill(Color.duckPink).padding(2))
                        .padding(5)
                }
            }
        }
        .buttonStyle(.plain)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(isSelected ? Color.duckPink : Color.duckSoftPink.opacity(0.3), lineWidth: isSelected ? 2 : 1))
        .onAppear { startLoading() }
        .onDisappear { cancelLoading() }
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
