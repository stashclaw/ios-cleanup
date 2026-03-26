import SwiftUI
import Photos

struct BlurResultsView: View {
    @EnvironmentObject private var purchaseManager: PurchaseManager
    @EnvironmentObject private var homeViewModel: HomeViewModel

    private var assets: [PHAsset] { homeViewModel.blurPhotos }

    @State private var selectedAssets = Set<String>()
    @State private var isDeleting = false
    @State private var deleteError: String?
    @State private var showPaywall = false
    @State private var visibleCount = 60
    @State private var showICloudDeleteAlert = false
    @State private var previewAsset: PHAsset? = nil   // full-screen preview

    var body: some View {
        Group {
            if assets.isEmpty && homeViewModel.blurScanState != .scanning {
                EmptyStateView(
                    title: "No Blurry Photos",
                    icon: "camera.filters",
                    message: "Your photos are all in focus!"
                )
            } else {
                ScrollView {
                    VStack(spacing: 14) {
                        if homeViewModel.blurScanState == .scanning {
                            ScanningBanner(message: "Finding blurry photos…", color: Color(red: 0.45, green: 0.4, blue: 1))
                        }
                        heroCard
                        if let error = deleteError {
                            Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal)
                        }
                        photoGrid
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
                .background(Color.duckBlush.ignoresSafeArea())
            }
        }
        .navigationTitle("Blurry Photos")
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
                        let hasICloud = selectedAssets.contains { id in
                            guard let asset = assets.first(where: { $0.localIdentifier == id }) else { return false }
                            return !BlurPhotoCell.isStoredLocally(asset)
                        }
                        if hasICloud {
                            showICloudDeleteAlert = true
                        } else {
                            Task { await deleteSelected() }
                        }
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
        .fullScreenCover(item: $previewAsset) { asset in
            BlurFullScreenView(asset: asset)
        }
        .confirmationDialog(
            "Some photos are stored in iCloud",
            isPresented: $showICloudDeleteAlert,
            titleVisibility: .visible
        ) {
            Button("Delete from iCloud Too", role: .destructive) {
                Task { await deleteSelected() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("These photos exist only in iCloud. Deleting them will remove them from iCloud and all your devices.")
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
                    Text("blurry photos")
                        .font(.duckCaption)
                        .foregroundStyle(Color.duckRose)
                }
                Spacer()
                Image(systemName: "camera.filters")
                    .font(.largeTitle)
                    .foregroundStyle(Color.duckSoftPink)
            }
            .padding(16)
        }
    }

    // MARK: - Photo grid (3 columns, rounded square cells)

    private var photoGrid: some View {
        let gap: CGFloat = 4
        let cardPt = (UIScreen.main.bounds.width - 32 - gap * 2) / 3   // 16+16 h-padding + 2 gaps
        let columns = Array(repeating: GridItem(.fixed(cardPt), spacing: gap), count: 3)
        return LazyVGrid(columns: columns, spacing: gap) {
            ForEach(assets.prefix(visibleCount), id: \.localIdentifier) { asset in
                BlurPhotoCell(
                    asset: asset,
                    cellSize: cardPt,
                    isSelected: selectedAssets.contains(asset.localIdentifier),
                    onTap: { previewAsset = asset },   // tap = full-screen preview
                    onSelect: {                         // long-press = toggle selection
                        if selectedAssets.contains(asset.localIdentifier) {
                            selectedAssets.remove(asset.localIdentifier)
                        } else {
                            selectedAssets.insert(asset.localIdentifier)
                        }
                    }
                )
            }
            if visibleCount < assets.count {
                Color.clear.frame(height: 1).gridCellColumns(3)
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
            NotificationCenter.default.post(name: .didFreeBytes, object: nil,
                                            userInfo: ["bytes": bytes, "count": toDelete.count])
            selectedAssets.removeAll()
        } catch {
            deleteError = error.localizedDescription
        }
    }
}

// MARK: - Cell cache + size constants

private let _blurCellCache: NSCache<NSString, UIImage> = {
    let c = NSCache<NSString, UIImage>()
    c.countLimit = 300
    c.totalCostLimit = 40 * 1024 * 1024
    return c
}()

// MARK: - Cell

private struct BlurPhotoCell: View {
    let asset: PHAsset
    let cellSize: CGFloat    // explicit pt side-length (square) passed from grid
    let isSelected: Bool
    let onTap: () -> Void    // single tap → full-screen preview
    let onSelect: () -> Void // long press → toggle selection

    @State private var thumbnail: UIImage?
    @State private var requestID: PHImageRequestID?
    @State private var isICloud = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // ── Image ──────────────────────────────────────────────────────
            Group {
                if let img = thumbnail {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.duckSoftPink.opacity(0.3)
                        .overlay(ProgressView().scaleEffect(0.6))
                }
            }
            // Explicit fixed frame prevents scaledToFill from bleeding into
            // adjacent columns (the root cause of the overlap bug).
            .frame(width: cellSize, height: cellSize)
            .clipped()
            .overlay(isSelected ? Color.duckPink.opacity(0.35) : Color.clear)

            // ── Badges ─────────────────────────────────────────────────────
            VStack {
                HStack {
                    Spacer()
                    if isICloud {
                        Image(systemName: "icloud")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.9))
                            .padding(.horizontal, 5).padding(.vertical, 3)
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
        }
        .frame(width: cellSize, height: cellSize)   // outer frame locks ZStack to grid slot
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? Color.duckPink : Color.duckSoftPink.opacity(0.3),
                              lineWidth: isSelected ? 2 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .onLongPressGesture { onSelect() }
        .onAppear { load(); isICloud = !Self.isStoredLocally(asset) }
        .onDisappear { cancel() }
    }

    static func isStoredLocally(_ asset: PHAsset) -> Bool {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let r = resources.first(where: { $0.type == .photo || $0.type == .video }) else { return true }
        return (r.value(forKey: "locallyAvailable") as? Bool) ?? true
    }

    private func load() {
        let key = "\(asset.localIdentifier)_blur" as NSString
        if let cached = _blurCellCache.object(forKey: key) { thumbnail = cached; return }
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .opportunistic
        opts.isNetworkAccessAllowed = false
        opts.resizeMode = .fast
        let scale = UIScreen.main.scale
        let px = cellSize * scale
        requestID = PHImageManager.default().requestImage(
            for: asset, targetSize: CGSize(width: px, height: px),
            contentMode: .aspectFill, options: opts
        ) { img, info in
            guard let img else { return }
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            if !degraded {
                _blurCellCache.setObject(img, forKey: key,
                                         cost: Int(img.size.width * img.size.height * 4))
            }
            DispatchQueue.main.async { thumbnail = img }
        }
    }

    private func cancel() {
        if let id = requestID { PHImageManager.default().cancelImageRequest(id); requestID = nil }
    }
}

// MARK: - Full-screen photo viewer

/// Conform PHAsset to Identifiable so it can drive .fullScreenCover(item:).
extension PHAsset: @retroactive Identifiable {
    public var id: String { localIdentifier }
}

private struct BlurFullScreenView: View {
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
            // Close button
            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(20)
                    }
                }
                Spacer()
            }
        }
        .task { await loadFullRes() }
    }

    private func loadFullRes() async {
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .opportunistic
        opts.isNetworkAccessAllowed = true
        opts.resizeMode = .none
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            var done = false
            PHImageManager.default().requestImage(
                for: asset, targetSize: PHImageManagerMaximumSize,
                contentMode: .aspectFit, options: opts
            ) { img, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if let img { DispatchQueue.main.async { self.image = img } }
                if !isDegraded, !done { done = true; c.resume() }
            }
        }
    }
}
