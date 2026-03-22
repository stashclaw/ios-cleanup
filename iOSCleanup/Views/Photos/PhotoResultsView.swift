import SwiftUI
import Photos

struct PhotoResultsView: View {
    let groups: [PhotoGroup]
    @EnvironmentObject private var purchaseManager: PurchaseManager
    @EnvironmentObject private var deletionManager: DeletionManager

    @State private var visibleGroups: [PhotoGroup]
    @State private var showPaywall = false
    @State private var showSwipeMode = false
    @State private var showAutoCleanAllConfirm = false
    @State private var deletionError: String?
    @State private var activeFilter: FilterPill = .all
    @State private var reviewLaterToastVisible = false

    enum FilterPill: String, CaseIterable {
        case all = "All"
        case nearDuplicate = "Near Duplicates"
        case similar = "Similar"
        case burst = "Burst"
    }

    init(groups: [PhotoGroup]) {
        self.groups = groups
        _visibleGroups = State(initialValue: groups)
    }

    private var filteredGroups: [PhotoGroup] {
        switch activeFilter {
        case .all:           return visibleGroups
        case .nearDuplicate: return visibleGroups.filter { $0.reason == .nearDuplicate }
        case .similar:       return visibleGroups.filter { $0.reason == .visuallySimilar }
        case .burst:         return visibleGroups.filter { $0.reason == .burstShot }
        }
    }

    private var reclaimableBytes: Int64 {
        visibleGroups.reduce(into: Int64(0)) { $0 += $1.reclaimableBytes }
    }

    private var totalPhotoCount: Int {
        groups.reduce(0) { $0 + $1.assets.count }
    }

    private var currentReviewCount: Int {
        filteredGroups.reduce(0) { $0 + $1.assets.count }
    }

    private var currentDeletableCount: Int {
        filteredGroups.reduce(0) { $0 + $1.deleteCandidateIDs.count }
    }

    var body: some View {
        Group {
            if visibleGroups.isEmpty {
                EmptyStateView(
                    title: "Your library looks clean",
                    icon: "photo.on.rectangle.angled",
                    message: "0 of \(totalPhotoCount) photos need attention right now."
                )
            } else if filteredGroups.isEmpty {
                EmptyStateView(
                    title: "No results in this filter",
                    icon: "photo.on.rectangle.angled",
                    message: "Try a different filter or reset to All."
                )
            } else {
                ZStack {
                    mainContent

                    if deletionManager.isDeleting {
                        bulkProgressOverlay
                    }

                    if reviewLaterToastVisible {
                        VStack {
                            Spacer()
                            Text("Moved to end of list")
                                .font(.duckCaption.weight(.semibold))
                                .foregroundStyle(Color.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(Color.duckBerry.opacity(0.9), in: Capsule())
                                .padding(.bottom, 24)
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .allowsHitTesting(false)
                    }
                }
            }
        }
        .navigationTitle("Similar Photos")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button("Duck Mode") { showSwipeMode = true }
                    .font(.duckCaption)
                    .foregroundStyle(Color.duckPink)

                Button(purchaseManager.isPurchased ? "Auto-clean all" : "Auto-clean all 🔒") {
                    guard purchaseManager.isPurchased else { showPaywall = true; return }
                    showAutoCleanAllConfirm = true
                }
                .font(.duckCaption)
                .foregroundStyle(Color.duckRose)
            }
        }
        .alert("Auto-clean all groups?", isPresented: $showAutoCleanAllConfirm) {
            Button("Clean \(filteredGroups.count) groups", role: .destructive) {
                Task { await autoCleanAll() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The best shot from each group will be kept. All other duplicates will be removed.")
        }
        .sheet(isPresented: $showPaywall) { PaywallView().environmentObject(purchaseManager) }
        .fullScreenCover(isPresented: $showSwipeMode) {
            SwipeModeView(groups: visibleGroups)
                .environmentObject(purchaseManager)
                .environmentObject(deletionManager)
        }
        .onReceive(NotificationCenter.default.publisher(for: .purchaseDidSucceed)) { _ in
            showPaywall = false
        }
    }

    // MARK: - Auto-clean all

    private func autoCleanAll() async {
        for group in filteredGroups {
            do {
                try await deletionManager.keepBest(from: group)
                _ = await PhotoFeedbackStore.shared.recordSimilarGroupDecision(
                    group: group,
                    kind: .keepBest,
                    stage: .committed,
                    selectedKeeperID: group.keeperAssetID,
                    keptAssetIDs: [group.keeperAssetID].compactMap { $0 },
                    recommendationAccepted: true,
                    note: "Auto-clean all from results list"
                )
                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                    visibleGroups.removeAll { $0.id == group.id }
                }
            } catch {
                deletionError = error.localizedDescription
                break
            }
        }
    }

    // MARK: - Main content

    private var mainContent: some View {
        ScrollView {
            VStack(spacing: 16) {
                heroCard
                filterPills
                metricRow
                if let error = deletionError {
                    Text(error)
                        .font(.duckCaption)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }
                groupList
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
        .background(Color.duckBlush.ignoresSafeArea())
    }

    // MARK: - Bulk progress overlay

    private var bulkProgressOverlay: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()

            VStack(spacing: 20) {
                VStack(spacing: 12) {
                    Text("Freeing your space...")
                        .font(.duckTitle)
                        .foregroundStyle(Color.duckBerry)

                    DuckProgressBar(progress: deletionManager.deletionProgress, color: .duckPink)
                        .frame(height: 12)

                    VStack(spacing: 6) {
                        Text(
                            "\(ByteCountFormatter.string(fromByteCount: deletionManager.bulkProcessedBytes, countStyle: .file)) freed of \(ByteCountFormatter.string(fromByteCount: deletionManager.bulkTotalBytes, countStyle: .file))"
                        )
                        .font(.duckBody)
                        .foregroundStyle(Color.duckRose)
                        .multilineTextAlignment(.center)

                        Text("\(deletionManager.bulkProcessedCount) of \(deletionManager.bulkTotalCount) photos")
                            .font(.duckCaption)
                            .foregroundStyle(Color.duckBerry)
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity)
                .background(Color.duckCream, in: RoundedRectangle(cornerRadius: 22))
            }
            .padding(.horizontal, 40)
        }
    }

    // MARK: - Hero card

    private var heroCard: some View {
        PrimaryMetricCard(
            title: "Review progress",
            value: "\(filteredGroups.count) / \(groups.count) groups shown",
            detail: "\(currentReviewCount) photos in current review set · \(currentDeletableCount) removable",
            accent: .duckPink,
            progress: groups.isEmpty ? 0 : Double(filteredGroups.count) / Double(groups.count)
        ) {
            PhotoDuckAssetImage(
                assetNames: ["photoduck_mascot", "photoduck_logo"],
                fallback: { PhotoDuckMascotFallback(size: 54) }
            )
            .frame(width: 72, height: 72)
        }
    }

    private var metricRow: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            StatPill(title: "Groups", value: "\(filteredGroups.count)", accent: .duckPink, icon: "photo.stack")
            StatPill(title: "Current set", value: "\(currentReviewCount) photos", accent: .duckOrange, icon: "photo.stack")
            StatPill(title: "Reclaimable", value: ByteCountFormatter.string(fromByteCount: reclaimableBytes, countStyle: .file), accent: .duckRose, icon: "sparkles")
        }
    }

    // MARK: - Filter pills

    private var filterPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(FilterPill.allCases, id: \.self) { pill in
                    Button(pill.rawValue) {
                        activeFilter = pill
                    }
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

    // MARK: - Group list

    private var groupList: some View {
        VStack(spacing: 12) {
            ForEach(Array(filteredGroups.enumerated()), id: \.element.id) { index, group in
                DuckCard {
                    VStack(spacing: 12) {
                        NavigationLink {
                            PhotoGroupDetailView(
                                group: group,
                                groupIndex: index,
                                totalGroups: filteredGroups.count,
                                onDeleteGroup: {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                        visibleGroups.removeAll { $0.id == group.id }
                                    }
                                }
                            )
                            .environmentObject(purchaseManager)
                            .environmentObject(deletionManager)
                        } label: {
                            GroupOverviewCard(group: group)
                                .contentShape(Rectangle())
                        }

                        HStack(spacing: 10) {
                            Button {
                                guard purchaseManager.isPurchased else { showPaywall = true; return }
                                Task {
                                    do {
                                        try await deletionManager.keepBest(from: group)
                                        _ = await PhotoFeedbackStore.shared.recordSimilarGroupDecision(
                                            group: group,
                                            kind: .keepBest,
                                            stage: .committed,
                                            selectedKeeperID: group.keeperAssetID,
                                            keptAssetIDs: [group.keeperAssetID].compactMap { $0 },
                                            recommendationAccepted: true,
                                            note: "Keep Best from results list"
                                        )
                                        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                            visibleGroups.removeAll { $0.id == group.id }
                                        }
                                    } catch {
                                        deletionError = error.localizedDescription
                                    }
                                }
                            } label: {
                                Text(purchaseManager.isPurchased ? "Auto-clean" : "Auto-clean 🔒")
                                    .font(.duckCaption.weight(.semibold))
                                    .foregroundStyle(Color.white)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(Color.duckPink, in: Capsule())
                            }

                            Button {
                                if let idx = visibleGroups.firstIndex(where: { $0.id == group.id }) {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                        let deferred = visibleGroups.remove(at: idx)
                                        visibleGroups.append(deferred)
                                    }
                                }
                                withAnimation { reviewLaterToastVisible = true }
                                Task {
                                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                                    withAnimation { reviewLaterToastVisible = false }
                                }
                            } label: {
                                Text("Review Later")
                                    .font(.duckCaption.weight(.semibold))
                                    .foregroundStyle(Color.duckRose)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(Color.duckCream, in: Capsule())
                            }
                        }
                    }
                    .padding(14)
                }
            }
        }
    }
}

// MARK: - Group Row

private struct GroupOverviewCard: View {
    let group: PhotoGroup
    @State private var thumbnails: [UIImage?] = [nil, nil, nil]

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            thumbnailRow

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(reasonLabel)
                        .font(.duckBody)
                        .foregroundStyle(Color.duckBerry)

                    StatusBadge(title: confidenceLabel, accent: confidenceColor)
                }

                Text("\(group.photoCount) photos")
                    .font(.duckCaption)
                    .foregroundStyle(Color.duckRose)

                Text(ByteCountFormatter.string(fromByteCount: group.reclaimableBytes, countStyle: .file))
                    .font(.duckCaption.weight(.semibold))
                    .foregroundStyle(Color.duckPink)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(Color.duckSoftPink)
        }
        .task { await loadThumbnails() }
    }

    private var thumbnailRow: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Group {
                    if i < group.assets.count, let img = thumbnails[i] {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                    } else if i < group.assets.count {
                        Color.duckSoftPink.opacity(0.4)
                            .overlay(ProgressView().scaleEffect(0.6).tint(.white))
                    } else {
                        Color.duckSoftPink.opacity(0.15)
                    }
                }
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var reasonLabel: String {
        switch group.reason {
        case .nearDuplicate:   return "Near Duplicate"
        case .visuallySimilar: return "Similar"
        case .burstShot:       return "Burst Shot"
        }
    }

    private var confidenceLabel: String {
        switch group.groupConfidence {
        case .high:   return "High confidence"
        case .medium: return "Needs review"
        case .low:    return "Needs review"
        }
    }

    private var confidenceColor: Color {
        switch group.groupConfidence {
        case .high:   return .duckPink
        case .medium: return .duckOrange
        case .low:    return .duckRose
        }
    }

    private func loadThumbnails() async {
        let assets = group.assets.prefix(3)
        var loaded = [UIImage?](repeating: nil, count: 3)
        await withTaskGroup(of: (Int, UIImage?).self) { tg in
            for (i, asset) in assets.enumerated() {
                tg.addTask { (i, await requestThumb(asset)) }
            }
            for await (i, img) in tg {
                loaded[i] = img
            }
        }
        thumbnails = loaded
    }

    private func requestThumb(_ asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .fastFormat
            options.isNetworkAccessAllowed = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 144, height: 144),
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
                guard !isDegraded else { return }
                continuation.resume(returning: image)
            }
        }
    }
}
