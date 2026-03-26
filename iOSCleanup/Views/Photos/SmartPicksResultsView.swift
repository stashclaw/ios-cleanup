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

private func spIsStoredLocally(_ asset: PHAsset) -> Bool {
    let resources = PHAssetResource.assetResources(for: asset)
    guard let resource = resources.first(where: { $0.type == .photo || $0.type == .fullSizePhoto }) else { return true }
    return (resource.value(forKey: "locallyAvailable") as? Bool) ?? true
}

// MARK: - Filter tag

private enum SmartPickFilter: Hashable {
    case all
    case wasted(WastedReason)

    var label: String {
        switch self {
        case .all:               return "All"
        case .wasted(let r):     return r.label
        }
    }

    var icon: String? {
        switch self {
        case .all:               return nil
        case .wasted(let r):     return r.icon
        }
    }

    var color: Color {
        switch self {
        case .all:               return Color.white.opacity(0.7)
        case .wasted(let r):     return r.color
        }
    }
}

// MARK: - Main view

struct SmartPicksResultsView: View {
    let assets: [PHAsset]
    /// Keyed by localIdentifier — only present for wasted-shot flagged photos.
    let reasons: [String: WastedReason]

    @EnvironmentObject private var purchaseManager: PurchaseManager

    @State private var selectedAssets = Set<String>()
    @State private var isDeleting = false
    @State private var deleteError: String?
    @State private var deletedIDs = Set<String>()
    @State private var showPaywall = false
    @State private var visibleCount = 60
    @State private var showICloudDeleteAlert = false
    @State private var activeFilter: SmartPickFilter = .all

    private let bg = Color(red: 0.05, green: 0.05, blue: 0.08)

    private var visibleAssets: [PHAsset] {
        assets.filter { !deletedIDs.contains($0.localIdentifier) }
    }

    /// Assets that pass the active filter
    private var filteredAssets: [PHAsset] {
        switch activeFilter {
        case .all:
            return visibleAssets
        case .wasted(let r):
            return visibleAssets.filter { reasons[$0.localIdentifier] == r }
        }
    }

    /// Which wasted reasons are present in the current visible set
    private var presentReasons: [WastedReason] {
        var seen = Set<WastedReason>()
        var ordered: [WastedReason] = []
        for asset in visibleAssets {
            if let r = reasons[asset.localIdentifier], seen.insert(r).inserted {
                ordered.append(r)
            }
        }
        return ordered
    }

    private var availableFilters: [SmartPickFilter] {
        [.all] + presentReasons.map { .wasted($0) }
    }

    private let columns = [GridItem(.fixed(0)), GridItem(.fixed(0)), GridItem(.fixed(0))]  // overridden below

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
                        // Filter pills — only show when wasted shots are present
                        if availableFilters.count > 1 {
                            filterPills
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
                        filteredAssets.prefix(visibleCount).forEach {
                            selectedAssets.insert($0.localIdentifier)
                        }
                    }
                    .font(.system(size: 14))
                    .foregroundStyle(Color(red: 1, green: 0.8, blue: 0.2))
                } else {
                    Button("Delete (\(selectedAssets.count))") {
                        guard purchaseManager.isPurchased else { showPaywall = true; return }
                        let toDelete = filteredAssets.filter { selectedAssets.contains($0.localIdentifier) }
                        if toDelete.contains(where: { !spIsStoredLocally($0) }) {
                            showICloudDeleteAlert = true
                        } else {
                            Task { await deleteSelected() }
                        }
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
        .confirmationDialog(
            "Some Photos Are in iCloud",
            isPresented: $showICloudDeleteAlert,
            titleVisibility: .visible
        ) {
            Button("Delete from iCloud Too", role: .destructive) {
                Task { await deleteSelected() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Some selected photos are stored only in iCloud. Deleting will remove them from iCloud and all your devices, but won't free local storage on this device.")
        }
        .onChange(of: activeFilter) { _ in
            visibleCount = 60
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
                Text(heroSubtitle)
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

    private var heroSubtitle: String {
        let wastedCount = reasons.count
        if wastedCount > 0 {
            return "low-quality photos · \(wastedCount) wasted shots"
        }
        return "low-quality photos flagged"
    }

    // MARK: - Filter pills

    private var filterPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(availableFilters, id: \.self) { filter in
                    Button {
                        activeFilter = filter
                    } label: {
                        HStack(spacing: 4) {
                            if let icon = filter.icon {
                                Image(systemName: icon)
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            Text(filter.label)
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(activeFilter == filter ? .black : filter.color)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            activeFilter == filter
                                ? filter.color
                                : filter.color.opacity(0.12),
                            in: Capsule()
                        )
                        .overlay(
                            Capsule().strokeBorder(
                                activeFilter == filter ? Color.clear : filter.color.opacity(0.3),
                                lineWidth: 1
                            )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
    }

    // MARK: - Photo grid (3 columns)

    private var photoGrid: some View {
        let cardPt = _smartPicksCardPt
        let fixedColumns = Array(repeating: GridItem(.fixed(cardPt), spacing: 2), count: 3)
        return LazyVGrid(columns: fixedColumns, spacing: 2) {
            ForEach(filteredAssets.prefix(visibleCount), id: \.localIdentifier) { asset in
                SmartPickCell(
                    asset: asset,
                    wastedReason: reasons[asset.localIdentifier],
                    isSelected: selectedAssets.contains(asset.localIdentifier),
                    cellSize: cardPt,
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
            if visibleCount < filteredAssets.count {
                Color.clear
                    .frame(height: 1)
                    .gridCellColumns(3)
                    .onAppear {
                        visibleCount = min(visibleCount + 60, filteredAssets.count)
                    }
            }
        }
    }

    // MARK: - Delete (single, free)

    private func deleteSingle(_ asset: PHAsset) {
        let bytes = PHAssetResource.assetResources(for: asset)
            .first.flatMap { $0.value(forKey: "fileSize") as? Int64 } ?? 0
        let reason = reasons[asset.localIdentifier]
        Task {
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.deleteAssets([asset] as NSFastEnumeration)
                }
                deletedIDs.insert(asset.localIdentifier)
                selectedAssets.remove(asset.localIdentifier)
                // Record affinity signal so Smart Picks learns what to surface more
                if let r = reason {
                    await WastedReasonAffinityStore.shared.recordDeletion(reason: r)
                }
                NotificationCenter.default.post(
                    name: .didFreeBytes, object: nil,
                    userInfo: ["bytes": bytes, "count": 1]
                )
            } catch {
                deleteError = error.localizedDescription
            }
        }
    }

    // MARK: - Delete (bulk, paid)

    private func deleteSelected() async {
        isDeleting = true
        defer { isDeleting = false }
        let toDelete = filteredAssets.filter { selectedAssets.contains($0.localIdentifier) }
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
            // Record affinity signals for all wasted-reason deletions
            for asset in toDelete {
                if let r = reasons[asset.localIdentifier] {
                    await WastedReasonAffinityStore.shared.recordDeletion(reason: r)
                }
            }
            NotificationCenter.default.post(
                name: .didFreeBytes, object: nil,
                userInfo: ["bytes": bytes, "count": toDelete.count]
            )
        } catch {
            deleteError = error.localizedDescription
        }
    }
}

// MARK: - Cell (self-loading, with quality score + wasted-reason badges)

private struct SmartPickCell: View {
    let asset: PHAsset
    let wastedReason: WastedReason?
    let isSelected: Bool
    let cellSize: CGFloat
    let onTap: () -> Void
    let onDelete: () -> Void

    @State private var thumbnail: UIImage?
    @State private var requestID: PHImageRequestID?
    @State private var qualityScore: Float? = nil
    @State private var isICloud = false

    /// Score → badge color: red (<0.2), orange (<0.35), yellow otherwise
    private var scoreColor: Color {
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
                .frame(width: cellSize, height: cellSize)
                .clipped()
                .overlay(isSelected ? Color(red: 1, green: 0.8, blue: 0.2).opacity(0.3) : Color.clear)

                // Quality score badge (bottom-right) — only shown when no wasted reason label
                if let score = qualityScore, wastedReason == nil {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(scoreColor)
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

                // ── Bottom-left: wasted reason label ────────────────────────
                if let reason = wastedReason {
                    VStack {
                        Spacer()
                        HStack {
                            HStack(spacing: 3) {
                                Image(systemName: reason.icon)
                                    .font(.system(size: 9, weight: .bold))
                                Text(reason.label)
                                    .font(.system(size: 9, weight: .bold))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 3)
                            .background(reason.color.opacity(0.85), in: Capsule())
                            .padding(5)
                            Spacer()
                        }
                    }
                }

                // iCloud badge — top-left when no selection; top-right when wasted label may be present
                if isICloud && !isSelected {
                    VStack {
                        HStack {
                            Spacer()
                            Image(systemName: "icloud")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(4)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 5))
                                .padding(5)
                        }
                        Spacer()
                    }
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
        .frame(width: cellSize, height: cellSize)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isSelected
                        ? Color(red: 1, green: 0.8, blue: 0.2)
                        : (wastedReason != nil ? wastedReason!.color.opacity(0.4) : Color.white.opacity(0.1)),
                    lineWidth: isSelected ? 2 : (wastedReason != nil ? 1 : 0.5)
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
            isICloud = !spIsStoredLocally(asset)
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
