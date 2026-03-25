import SwiftUI
import Photos

struct LargePhotosResultsView: View {
    @EnvironmentObject private var purchaseManager: PurchaseManager
    @EnvironmentObject private var homeViewModel: HomeViewModel

    private var items: [LargePhotoItem] { homeViewModel.largePhotos }

    @State private var selectedIDs  = Set<UUID>()
    @State private var isDeleting   = false
    @State private var deleteError: String?
    @State private var showPaywall  = false
    @State private var visibleCount = 60

    private let bg = Color(red: 0.05, green: 0.05, blue: 0.08)
    private let accent = Color(red: 0.98, green: 0.75, blue: 0.25)   // amber — "large/heavy"

    var body: some View {
        ZStack {
            bg.ignoresSafeArea()
            Group {
                if items.isEmpty && homeViewModel.largePhotoScanState != .scanning {
                    VStack(spacing: 12) {
                        Image(systemName: "photo.badge.checkmark")
                            .font(.system(size: 48))
                            .foregroundStyle(accent.opacity(0.6))
                        Text("No Large Photos")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                        Text("No photos over 10 MB found.")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.white.opacity(0.4))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 14) {
                            if homeViewModel.largePhotoScanState == .scanning {
                                ScanningBanner(message: "Finding large photos…", color: Color(red: 0.98, green: 0.75, blue: 0.25))
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
                }
            }
        }
        .navigationTitle("Large Photos")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(bg, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if selectedIDs.isEmpty {
                    Button(purchaseManager.isPurchased ? "Select All" : "Select 🔒") {
                        guard purchaseManager.isPurchased else { showPaywall = true; return }
                        items.prefix(visibleCount).forEach { selectedIDs.insert($0.id) }
                    }
                    .font(.system(size: 14))
                    .foregroundStyle(accent)
                } else {
                    Button("Delete (\(selectedIDs.count))") {
                        guard purchaseManager.isPurchased else { showPaywall = true; return }
                        Task { await deleteSelected() }
                    }
                    .disabled(isDeleting)
                    .foregroundStyle(accent)
                }
            }
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView().environmentObject(purchaseManager)
        }
        .onReceive(NotificationCenter.default.publisher(for: .purchaseDidSucceed)) { _ in
            showPaywall = false
        }
    }

    // MARK: - Hero card

    private var heroCard: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(items.count)")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(accent)
                    .monospacedDigit()
                Text("large photos")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.5))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(totalSizeFormatted)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                Text("total size")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.5))
            }
        }
        .padding(16)
        .background(Color(white: 1, opacity: 0.05), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(accent.opacity(0.25)))
    }

    private var totalSizeFormatted: String {
        let total = items.reduce(Int64(0)) { $0 + $1.byteSize }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    // MARK: - Photo grid (3 columns, rounded square cells)

    private var photoGrid: some View {
        let gap: CGFloat = 10
        let cardPt = (UIScreen.main.bounds.width - 52) / 3   // 16+16 padding + 10+10 gaps
        let columns = Array(repeating: GridItem(.flexible(), spacing: gap), count: 3)
        return LazyVGrid(columns: columns, spacing: gap) {
            ForEach(items.prefix(visibleCount)) { item in
                LargePhotoCell(
                    item: item,
                    isSelected: selectedIDs.contains(item.id),
                    accent: accent,
                    onTap: {
                        if selectedIDs.contains(item.id) {
                            selectedIDs.remove(item.id)
                        } else {
                            selectedIDs.insert(item.id)
                        }
                    }
                )
                .frame(height: cardPt)
                .clipped()
            }
            if visibleCount < items.count {
                Color.clear.frame(height: 1).gridCellColumns(3)
                    .onAppear { visibleCount = min(visibleCount + 60, items.count) }
            }
        }
    }

    // MARK: - Delete

    private func deleteSelected() async {
        isDeleting = true
        defer { isDeleting = false }
        let toDelete = items.filter { selectedIDs.contains($0.id) }
        let bytes    = toDelete.reduce(Int64(0)) { $0 + $1.byteSize }
        let assets   = toDelete.map(\.asset) as NSArray
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets)
            }
            if bytes > 0 {
                NotificationCenter.default.post(
                    name: .didFreeBytes, object: nil,
                    userInfo: ["bytes": bytes]
                )
            }
            selectedIDs.removeAll()
        } catch {
            deleteError = error.localizedDescription
        }
    }
}

// MARK: - Cell (self-loading, no parent re-render)

private let _largePhotoCellCache: NSCache<NSString, UIImage> = {
    let c = NSCache<NSString, UIImage>()
    c.countLimit = 300
    c.totalCostLimit = 40 * 1024 * 1024   // 40 MB
    return c
}()

@MainActor
private let _largePhotoCellPx: CGFloat = {
    let scale = UIScreen.main.scale
    return ((UIScreen.main.bounds.width - 32 - 20) / 3) * scale
}()

@MainActor
private let _largeCardPt: CGFloat = (UIScreen.main.bounds.width - 52) / 3  // 16+16 padding + 10+10 gaps

private struct LargePhotoCell: View {
    let item: LargePhotoItem
    let isSelected: Bool
    let accent: Color
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
                        Color.gray.opacity(0.12).overlay(ProgressView().scaleEffect(0.6))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .overlay(isSelected ? accent.opacity(0.35) : Color.clear)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20)).foregroundStyle(.white)
                        .background(Circle().fill(accent).padding(2))
                        .padding(5)
                }

                // Size badge — bottom leading
                VStack {
                    Spacer()
                    HStack {
                        Text(item.formattedSize)
                            .font(.system(size: 9, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.black.opacity(0.6), in: Capsule())
                            .padding(6)
                        Spacer()
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(isSelected ? accent : accent.opacity(0.25), lineWidth: isSelected ? 2 : 1))
        .onAppear { load() }
        .onDisappear { cancel() }
    }

    private func load() {
        let key = "\(item.asset.localIdentifier)_lgp" as NSString
        if let cached = _largePhotoCellCache.object(forKey: key) { thumbnail = cached; return }
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .opportunistic
        opts.isNetworkAccessAllowed = false
        opts.resizeMode = .fast
        let px = _largePhotoCellPx
        requestID = PHImageManager.default().requestImage(
            for: item.asset, targetSize: CGSize(width: px, height: px),
            contentMode: .aspectFill, options: opts
        ) { image, info in
            guard let image else { return }
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            if !degraded {
                _largePhotoCellCache.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * 4))
            }
            DispatchQueue.main.async { thumbnail = image }
        }
    }

    private func cancel() {
        if let id = requestID { PHImageManager.default().cancelImageRequest(id); requestID = nil }
    }
}
