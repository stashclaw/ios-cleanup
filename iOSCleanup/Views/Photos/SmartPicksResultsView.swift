import SwiftUI
import Photos

// MARK: - File-level NSCache (not in view struct — shared across all cell instances)

private let _smartPicksCellCache: NSCache<NSString, UIImage> = {
    let c = NSCache<NSString, UIImage>()
    c.countLimit = 300
    c.totalCostLimit = 40 * 1024 * 1024
    return c
}()

@MainActor
private let _smartPicksCellPx: CGFloat = {
    let scale = UIScreen.main.scale
    return ((UIScreen.main.bounds.width - 32 - 4) / 3) * scale  // 16pt padding × 2, 2pt gap × 2
}()

@MainActor
private let _smartPicksCardPt: CGFloat = (UIScreen.main.bounds.width - 32 - 4) / 3

// MARK: - Main view

struct SmartPicksResultsView: View {
    let assets: [PHAsset]
    @EnvironmentObject private var purchaseManager: PurchaseManager

    @State private var selectedAssets = Set<String>()
    @State private var isDeleting = false
    @State private var deleteError: String?
    @State private var deletedIDs = Set<String>()
    @State private var showPaywall = false
    @State private var visibleCount = 60

    private let bg = Color(red: 0.05, green: 0.05, blue: 0.08)

    private var visibleAssets: [PHAsset] {
        assets.filter { !deletedIDs.contains($0.localIdentifier) }
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        ZStack {
            bg.ignoresSafeArea()
            if visibleAssets.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 14) {
                        heroCard
                        if let error = deleteError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .padding(.horizontal)
                        }
                        photoGrid
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
            }
        }
        .navigationTitle("Smart Picks")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(bg, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if selectedAssets.isEmpty {
                    Button(purchaseManager.isPurchased ? "Select All" : "Select 🔒") {
                        guard purchaseManager.isPurchased else { showPaywall = true; return }
                        visibleAssets.prefix(visibleCount).forEach {
                            selectedAssets.insert($0.localIdentifier)
                        }
                    }
                    .font(.system(size: 14))
                    .foregroundStyle(Color(red: 1, green: 0.8, blue: 0.2))
                } else {
                    Button("Delete (\(selectedAssets.count))") {
                        guard purchaseManager.isPurchased else { showPaywall = true; return }
                        Task { await deleteSelected() }
                    }
                    .disabled(isDeleting)
                    .foregroundStyle(Color(red: 1, green: 0.35, blue: 0.35))
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

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundStyle(Color(red: 1, green: 0.8, blue: 0.2))
            Text("No Low-Quality Photos")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
            Text("Run a scan first to find candidates.")
                .font(.system(size: 14))
                .foregroundStyle(Color.white.opacity(0.4))
                .multilineTextAlignment(.center)
        }
        .padding(40)
    }

    // MARK: - Hero card

    private var heroCard: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(visibleAssets.count)")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(Color(red: 1, green: 0.8, blue: 0.2))
                Text("low-quality photos flagged")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.5))
            }
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 28))
                .foregroundStyle(Color(red: 1, green: 0.8, blue: 0.2))
        }
        .padding(16)
        .background(Color(white: 1, opacity: 0.05), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color(white: 1, opacity: 0.08)))
    }

    // MARK: - Photo grid (3 columns)

    private var photoGrid: some View {
        let cardPt = _smartPicksCardPt
        return LazyVGrid(columns: columns, spacing: 2) {
            ForEach(visibleAssets.prefix(visibleCount), id: \.localIdentifier) { asset in
                SmartPickCell(
                    asset: asset,
                    isSelected: selectedAssets.contains(asset.localIdentifier),
                    onTap: {
                        if selectedAssets.contains(asset.localIdentifier) {
                            selectedAssets.remove(asset.localIdentifier)
                        } else {
                            selectedAssets.insert(asset.localIdentifier)
                        }
                    },
                    onDelete: {
                        deleteSingle(asset)
                    }
                )
                .frame(width: cardPt, height: cardPt)
                .clipped()
            }
            // Progressive loading sentinel
            if visibleCount < visibleAssets.count {
                Color.clear
                    .frame(height: 1)
                    .gridCellColumns(3)
                    .onAppear {
                        visibleCount = min(visibleCount + 60, visibleAssets.count)
                    }
            }
        }
    }

    // MARK: - Delete (single, free)

    private func deleteSingle(_ asset: PHAsset) {
        let bytes = PHAssetResource.assetResources(for: asset)
            .first.flatMap { $0.value(forKey: "fileSize") as? Int64 } ?? 0
        Task {
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.deleteAssets([asset] as NSFastEnumeration)
                }
                deletedIDs.insert(asset.localIdentifier)
                selectedAssets.remove(asset.localIdentifier)
                if bytes > 0 {
                    NotificationCenter.default.post(
                        name: .didFreeBytes, object: nil,
                        userInfo: ["bytes": bytes]
                    )
                }
            } catch {
                deleteError = error.localizedDescription
            }
        }
    }

    // MARK: - Delete (bulk, paid)

    private func deleteSelected() async {
        isDeleting = true
        defer { isDeleting = false }
        let toDelete = visibleAssets.filter { selectedAssets.contains($0.localIdentifier) }
        let bytes = toDelete.reduce(Int64(0)) { sum, asset in
            let size = PHAssetResource.assetResources(for: asset)
                .first.flatMap { $0.value(forKey: "fileSize") as? Int64 } ?? 0
            return sum + size
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(toDelete as NSFastEnumeration)
            }
            toDelete.forEach { deletedIDs.insert($0.localIdentifier) }
            selectedAssets.removeAll()
            if bytes > 0 {
                NotificationCenter.default.post(
                    name: .didFreeBytes, object: nil,
                    userInfo: ["bytes": bytes]
                )
            }
        } catch {
            deleteError = error.localizedDescription
        }
    }
}

// MARK: - Cell (self-loading, with quality score badge)

private struct SmartPickCell: View {
    let asset: PHAsset
    let isSelected: Bool
    let onTap: () -> Void
    let onDelete: () -> Void

    @State private var thumbnail: UIImage?
    @State private var requestID: PHImageRequestID?
    @State private var qualityScore: Float? = nil

    /// Score → badge color: red (<0.2), orange (<0.35), yellow otherwise
    private var badgeColor: Color {
        guard let s = qualityScore else { return Color.white.opacity(0.4) }
        if s < 0.2  { return Color(red: 1.0, green: 0.3, blue: 0.3) }
        if s < 0.35 { return Color(red: 1.0, green: 0.6, blue: 0.1) }
        return Color(red: 1, green: 0.8, blue: 0.2)
    }

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .bottomTrailing) {
                // Thumbnail
                Group {
                    if let img = thumbnail {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color.white.opacity(0.07)
                            .overlay(
                                ProgressView()
                                    .tint(Color.white.opacity(0.3))
                                    .scaleEffect(0.6)
                            )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .overlay(isSelected ? Color(red: 1, green: 0.8, blue: 0.2).opacity(0.3) : Color.clear)

                // Quality score badge (bottom-right)
                if let score = qualityScore {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(badgeColor)
                            .frame(width: 6, height: 6)
                        Text(String(format: "%.1f", score))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.6))
                    .clipShape(Capsule())
                    .padding(5)
                }

                // Selection checkmark (top-right)
                if isSelected {
                    VStack {
                        HStack {
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(.white)
                                .background(
                                    Circle()
                                        .fill(Color(red: 1, green: 0.8, blue: 0.2))
                                        .padding(2)
                                )
                                .padding(5)
                        }
                        Spacer()
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isSelected
                        ? Color(red: 1, green: 0.8, blue: 0.2)
                        : Color.white.opacity(0.1),
                    lineWidth: isSelected ? 2 : 0.5
                )
        )
        .contextMenu {
            Button(role: .destructive) { onDelete() } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .task {
            await loadThumbnail()
            qualityScore = await PhotoQualityAnalyzer.shared.qualityScore(for: asset)
        }
        .onDisappear { cancelLoad() }
    }

    private func loadThumbnail() async {
        let key = "\(asset.localIdentifier)_sp" as NSString
        if let cached = _smartPicksCellCache.object(forKey: key) {
            thumbnail = cached
            return
        }
        let px = await _smartPicksCellPx
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .opportunistic
        opts.isNetworkAccessAllowed = false
        opts.resizeMode = .fast

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var resumed = false
            requestID = PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: px, height: px),
                contentMode: .aspectFill,
                options: opts
            ) { image, info in
                let isDone = !((info?[PHImageResultIsDegradedKey] as? Bool) ?? false)
                if let image = image {
                    if isDone {
                        _smartPicksCellCache.setObject(
                            image, forKey: key,
                            cost: Int(image.size.width * image.size.height * 4)
                        )
                    }
                    DispatchQueue.main.async { self.thumbnail = image }
                }
                // Resume once we reach the final delivery (non-degraded or error)
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
