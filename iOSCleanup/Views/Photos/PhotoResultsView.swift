import SwiftUI
import Photos

struct PhotoResultsView: View {
    let title: String
    let groups: [PhotoGroup]   // snapshot — used only for GroupReviewViewModel init
    @EnvironmentObject private var purchaseManager: PurchaseManager
    @EnvironmentObject private var homeViewModel: HomeViewModel
    @StateObject private var reviewVM: GroupReviewViewModel

    init(title: String = "Photos", groups: [PhotoGroup]) {
        self.title  = title
        self.groups = groups
        _reviewVM = StateObject(wrappedValue: GroupReviewViewModel(groups: groups))
    }

    @State private var selectedGroups = Set<UUID>()
    @State private var isSelectMode = false
    @State private var showPaywall = false
    @State private var showReviewMode = false
    @State private var deletionError: String?
    @State private var activeFilter: FilterPill = .all
    @State private var visibleCount = 10
    /// Tracks skipped keys locally so un-skipping refreshes the UI without reloading UserDefaults.
    @State private var skippedKeys: Set<String> = {
        Set(UserDefaults.standard.stringArray(forKey: GroupReviewViewModel.skippedKey) ?? [])
    }()

    // Card dimensions derived from screen width — GeometryReader-free per CLAUDE.md
    // 16+16 outer padding + 12 gap between columns = 44pt total
    private let cardPt: CGFloat = (UIScreen.main.bounds.width - 44) / 2
    // Each tile in the 2×2 mosaic: half card minus the 2pt intra-tile gap
    private var tilePt: CGFloat { (cardPt - 2) / 2 }
    private var tilePx: CGFloat { tilePt * UIScreen.main.scale }
    private let labelH: CGFloat = 0

    /// Live groups from the view model, filtered by this view's category.
    private var liveGroups: [PhotoGroup] {
        if title == "Duplicates" {
            return homeViewModel.photoGroups.filter { $0.reason != .visuallySimilar }
        }
        return homeViewModel.photoGroups.filter { $0.reason == .visuallySimilar }
    }

    enum FilterPill: String, CaseIterable {
        case all            = "All"
        case exactDuplicate = "Exact"
        case nearDuplicate  = "Near"
        case similar        = "Similar"
        case burst          = "Burst"
    }

    /// Only show pills for reasons that actually exist in the live groups.
    private var availableFilters: [FilterPill] {
        let reasons = Set(liveGroups.map(\.reason))
        var pills: [FilterPill] = [.all]
        if reasons.contains(.exactDuplicate)  { pills.append(.exactDuplicate) }
        if reasons.contains(.nearDuplicate)   { pills.append(.nearDuplicate) }
        if reasons.contains(.visuallySimilar) { pills.append(.similar) }
        if reasons.contains(.burstShot)       { pills.append(.burst) }
        return pills
    }

    private var filteredGroups: [PhotoGroup] {
        let base: [PhotoGroup]
        switch activeFilter {
        case .all:            base = liveGroups
        case .exactDuplicate: base = liveGroups.filter { $0.reason == .exactDuplicate }
        case .nearDuplicate:  base = liveGroups.filter { $0.reason == .nearDuplicate }
        case .similar:        base = liveGroups.filter { $0.reason == .visuallySimilar }
        case .burst:          base = liveGroups.filter { $0.reason == .burstShot }
        }
        // Strip skipped groups — they appear in the separate Skipped section below.
        return base.filter { !skippedKeys.contains(GroupReviewViewModel.groupKey(for: $0)) }
    }

    private var skippedGroups: [PhotoGroup] {
        liveGroups.filter { skippedKeys.contains(GroupReviewViewModel.groupKey(for: $0)) }
    }

    var body: some View {
        Group {
            if liveGroups.isEmpty && homeViewModel.photoScanState != .scanning {
                EmptyStateView(title: "No Duplicates Found", icon: "photo.on.rectangle.angled",
                               message: "Your photo library looks clean.")
            } else {
                ScrollView {
                    VStack(spacing: 14) {
                        if homeViewModel.photoScanState == .scanning {
                            ScanningBanner(message: "Finding \(title.lowercased())…", color: Color.duckPink)
                        }
                        heroCard
                        filterPills
                        if let error = deletionError {
                            Text(error).font(.duckCaption).foregroundStyle(.red).padding(.horizontal)
                        }
                        groupGrid
                        if !skippedGroups.isEmpty {
                            skippedSection
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
                .background(Color.duckBlush.ignoresSafeArea())
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button("Review All") { showReviewMode = true }
                    .font(.duckCaption)
                    .foregroundStyle(Color.duckPink)

                if isSelectMode {
                    Button("Delete (\(selectedGroups.count))") {
                        guard purchaseManager.isPurchased else { showPaywall = true; return }
                        Task { await bulkDelete() }
                    }
                    .disabled(selectedGroups.isEmpty)
                    .foregroundStyle(Color.duckRose)
                } else {
                    Menu {
                        Button(purchaseManager.isPurchased ? "Select Photos" : "Select Photos 🔒") {
                            guard purchaseManager.isPurchased else { showPaywall = true; return }
                            isSelectMode = true
                        }
                        Button(role: .destructive) {
                            guard purchaseManager.isPurchased else { showPaywall = true; return }
                            reviewVM.queueAll()
                        } label: {
                            Label(
                                purchaseManager.isPurchased ? "Queue All for Delete" : "Queue All 🔒",
                                systemImage: "trash"
                            )
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundStyle(Color.duckPink)
                    }
                }
            }
            if isSelectMode {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isSelectMode = false
                        selectedGroups.removeAll()
                    }
                    .foregroundStyle(Color.duckRose)
                }
            }
        }
        .sheet(isPresented: $showPaywall) { PaywallView().environmentObject(purchaseManager) }
        .fullScreenCover(isPresented: $showReviewMode) {
            GroupReviewView(viewModel: reviewVM).environmentObject(purchaseManager)
        }
        .onReceive(NotificationCenter.default.publisher(for: .purchaseDidSucceed)) { _ in
            showPaywall = false
        }
        .onChange(of: activeFilter) { _ in visibleCount = 10 }
        .overlay(alignment: .bottom) {
            if reviewVM.markedIDs.count > 0 { floatingDeleteBar }
        }
    }

    // MARK: - Floating delete bar

    private var floatingDeleteBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(reviewVM.markedIDs.count) photo\(reviewVM.markedIDs.count == 1 ? "" : "s") · \(reviewVM.markedGroupCount) group\(reviewVM.markedGroupCount == 1 ? "" : "s")")
                    .font(.duckCaption.bold())
                    .foregroundStyle(.white)
                Text("queued for delete")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.5))
            }
            Spacer()
            Button {
                guard purchaseManager.isPurchased else { showPaywall = true; return }
                Task {
                    do { try await reviewVM.commitDeletes() }
                    catch { deletionError = error.localizedDescription }
                }
            } label: {
                Text(purchaseManager.isPurchased ? "Delete All" : "Delete 🔒")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(Color.duckRose, in: Capsule())
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: - Hero card

    private var heroCard: some View {
        DuckCard {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(filteredGroups.count)")
                        .font(Font.custom("FredokaOne-Regular", size: 32))
                        .foregroundStyle(Color.duckPink)
                    Text(activeFilter == .all
                         ? "groups to review"
                         : "\(filteredGroups.count) of \(groups.count) total")
                        .font(.duckCaption)
                        .foregroundStyle(Color.duckRose)
                }
                Spacer()
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.largeTitle)
                    .foregroundStyle(Color.duckSoftPink)
            }
            .padding(16)
        }
    }

    // MARK: - Filter pills

    @ViewBuilder
    private var filterPills: some View {
        if availableFilters.count > 2 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(availableFilters, id: \.self) { pill in
                        Button(pill.rawValue) { activeFilter = pill }
                            .font(.duckCaption)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                activeFilter == pill ? Color.duckPink : Color.duckCream,
                                in: Capsule()
                            )
                            .foregroundStyle(activeFilter == pill ? Color.white : Color.duckRose)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    // MARK: - Group grid

    private var groupGrid: some View {
        let gap: CGFloat = 12
        let columns = [GridItem(.fixed(cardPt), spacing: gap),
                       GridItem(.fixed(cardPt), spacing: gap)]
        let visibleGroups = Array(filteredGroups.prefix(visibleCount))
        return LazyVGrid(columns: columns, spacing: gap) {
            ForEach(Array(visibleGroups.enumerated()), id: \.element.id) { index, group in
                let selected = selectedGroups.contains(group.id)
                GroupCard(
                    group: group,
                    cardPt: cardPt, tilePt: tilePt, tilePx: tilePx,
                    isSelected: selected,
                    isSelectMode: isSelectMode,
                    onSelect: {
                        if selected { selectedGroups.remove(group.id) }
                        else { selectedGroups.insert(group.id) }
                    },
                    destination: {
                        PhotoGroupDetailView(
                            groups: filteredGroups,
                            startIndex: index,
                            markedIDs: $reviewVM.markedIDs
                        )
                        .environmentObject(purchaseManager)
                    }
                )
            }
            if visibleCount < filteredGroups.count {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .gridCellColumns(2)
                    .onAppear { visibleCount += 10 }
            }
        }
    }

    // MARK: - Skipped section

    private var skippedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "archivebox.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.35))
                Text("SKIPPED")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(Color.white.opacity(0.35))
                    .kerning(1.2)
                Text("(\(skippedGroups.count))")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.2))
                Spacer()
                Text("Tap to restore")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.25))
            }
            .padding(.top, 8)

            // Same 2-column grid, but with a gray overlay + "SKIPPED" badge
            let gap: CGFloat = 12
            let columns = [GridItem(.fixed(cardPt), spacing: gap),
                           GridItem(.fixed(cardPt), spacing: gap)]
            LazyVGrid(columns: columns, spacing: gap) {
                ForEach(skippedGroups, id: \.id) { group in
                    GroupCard(
                        group: group,
                        cardPt: cardPt, tilePt: tilePt, tilePx: tilePx,
                        isSelected: false,
                        isSelectMode: false,
                        onSelect: { },
                        destination: { Color.clear }   // no navigation from skipped card
                    )
                    .overlay(
                        ZStack {
                            Color.black.opacity(0.45)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            VStack {
                                Spacer()
                                HStack {
                                    Spacer()
                                    Button {
                                        GroupReviewViewModel.unskipGroup(group)
                                        skippedKeys.remove(GroupReviewViewModel.groupKey(for: group))
                                    } label: {
                                        Label("Restore", systemImage: "arrow.uturn.backward")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 6)
                                            .background(Color(white: 1, opacity: 0.15), in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                    Spacer()
                                }
                                .padding(.bottom, 12)
                            }
                        }
                    )
                }
            }
        }
    }

    // MARK: - Bulk delete

    private func bulkDelete() async {
        let toDelete = liveGroups
            .filter { selectedGroups.contains($0.id) }
            .flatMap { Array($0.assets.dropFirst()) }
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
                NotificationCenter.default.post(name: .didFreeBytes, object: nil, userInfo: ["bytes": bytes])
            }
            selectedGroups.removeAll()
            isSelectMode = false
        } catch {
            deletionError = error.localizedDescription
        }
    }
}

// MARK: - Shared thumbnail cache

private let _groupCardCache: NSCache<NSString, UIImage> = {
    let c = NSCache<NSString, UIImage>()
    c.countLimit = 600
    c.totalCostLimit = 80 * 1024 * 1024
    return c
}()

// MARK: - Group Card (2×2 photo mosaic + label strip)

private struct GroupCard<Destination: View>: View {
    let group: PhotoGroup
    let cardPt: CGFloat
    let tilePt: CGFloat
    let tilePx: CGFloat
    let isSelected: Bool
    let isSelectMode: Bool
    let onSelect: () -> Void
    @ViewBuilder let destination: () -> Destination

    private let radius: CGFloat = 16
    private let tileGap: CGFloat = 2

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Card body — NavigationLink wraps when not selecting
            if isSelectMode {
                cardBody.onTapGesture { onSelect() }
            } else {
                NavigationLink(destination: destination()) {
                    cardBody
                }
                .buttonStyle(.plain)
            }

            // Select-mode checkmark badge
            if isSelectMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle.fill")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.duckPink : Color.white.opacity(0.85))
                    .shadow(radius: 2)
                    .padding(8)
                    .allowsHitTesting(false) // let the tap-gesture above fire
            }
        }
        .frame(width: cardPt, height: cardPt)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.duckPink : Color.duckSoftPink.opacity(0.4),
                    lineWidth: isSelected ? 2.5 : 1
                )
        )
        .shadow(color: Color.duckPink.opacity(0.10), radius: 6, x: 0, y: 3)
    }

    private var cardBody: some View {
        ZStack(alignment: .bottomTrailing) {
            mosaicArea
                .frame(width: cardPt, height: cardPt)
                .clipped()

            // Count badge overlay
            Text("\(group.assets.count)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(minWidth: 22, minHeight: 22)
                .padding(.horizontal, 5)
                .background(Color.duckPink, in: Capsule())
                .padding(8)
        }
    }

    @ViewBuilder
    private var mosaicArea: some View {
        let slots = Array(group.assets.prefix(4))
        switch slots.count {
        case 1:
            MosaicTile(asset: slots[0], sizePt: cardPt, sizePx: cardPt * UIScreen.main.scale,
                       cacheKey: key(0))
                .frame(width: cardPt, height: cardPt)

        case 2:
            HStack(spacing: tileGap) {
                MosaicTile(asset: slots[0], sizePt: tilePt, sizePx: tilePx, cacheKey: key(0))
                    .frame(width: tilePt, height: cardPt)
                MosaicTile(asset: slots[1], sizePt: tilePt, sizePx: tilePx, cacheKey: key(1))
                    .frame(width: tilePt, height: cardPt)
            }

        case 3:
            HStack(spacing: tileGap) {
                MosaicTile(asset: slots[0], sizePt: tilePt, sizePx: tilePx, cacheKey: key(0))
                    .frame(width: tilePt, height: cardPt)
                VStack(spacing: tileGap) {
                    MosaicTile(asset: slots[1], sizePt: tilePt, sizePx: tilePx, cacheKey: key(1))
                        .frame(width: tilePt, height: tilePt)
                    MosaicTile(asset: slots[2], sizePt: tilePt, sizePx: tilePx, cacheKey: key(2))
                        .frame(width: tilePt, height: tilePt)
                }
            }

        default: // 4 tiles — 2×2
            VStack(spacing: tileGap) {
                HStack(spacing: tileGap) {
                    MosaicTile(asset: slots[0], sizePt: tilePt, sizePx: tilePx, cacheKey: key(0))
                        .frame(width: tilePt, height: tilePt)
                    MosaicTile(asset: slots[1], sizePt: tilePt, sizePx: tilePx, cacheKey: key(1))
                        .frame(width: tilePt, height: tilePt)
                }
                HStack(spacing: tileGap) {
                    MosaicTile(asset: slots[2], sizePt: tilePt, sizePx: tilePx, cacheKey: key(2))
                        .frame(width: tilePt, height: tilePt)
                    MosaicTile(asset: slots[3], sizePt: tilePt, sizePx: tilePx, cacheKey: key(3))
                        .frame(width: tilePt, height: tilePt)
                }
            }
        }
    }

    private func key(_ index: Int) -> NSString {
        "\(group.id.uuidString)_\(index)_mosaic" as NSString
    }
}

// MARK: - Mosaic tile (self-loading, cancellable, fixed size)

private struct MosaicTile: View {
    let asset: PHAsset
    let sizePt: CGFloat
    let sizePx: CGFloat
    let cacheKey: NSString

    @State private var thumbnail: UIImage?
    @State private var requestID: PHImageRequestID?

    var body: some View {
        ZStack {
            Color(red: 0.15, green: 0.15, blue: 0.18)
            if let img = thumbnail {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                ProgressView().scaleEffect(0.5).tint(Color.white.opacity(0.3))
            }
        }
        .clipped()
        .onAppear { load() }
        .onDisappear { cancel() }
    }

    private func load() {
        if let cached = _groupCardCache.object(forKey: cacheKey) { thumbnail = cached; return }
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .opportunistic
        opts.isNetworkAccessAllowed = false
        opts.resizeMode = .fast
        let size = CGSize(width: sizePx, height: sizePx)
        requestID = PHImageManager.default().requestImage(
            for: asset, targetSize: size, contentMode: .aspectFill, options: opts
        ) { image, info in
            guard let image else { return }
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            if !degraded {
                _groupCardCache.setObject(image, forKey: cacheKey,
                                          cost: Int(image.size.width * image.size.height * 4))
            }
            Task { @MainActor in thumbnail = image }
        }
    }

    private func cancel() {
        if let id = requestID { PHImageManager.default().cancelImageRequest(id); requestID = nil }
    }
}
