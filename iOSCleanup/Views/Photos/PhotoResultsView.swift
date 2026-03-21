import SwiftUI
import Photos

struct PhotoResultsView: View {
    let groups: [PhotoGroup]
    @EnvironmentObject private var purchaseManager: PurchaseManager
    @EnvironmentObject private var deletionManager: DeletionManager

    @State private var visibleGroups: [PhotoGroup]
    @State private var selectedGroups = Set<UUID>()
    @State private var isSelectMode = false
    @State private var showPaywall = false
    @State private var showSwipeMode = false
    @State private var showBulkConfirm = false
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

    private var selectedAssets: [PHAsset] {
        filteredGroups
            .filter { selectedGroups.contains($0.id) }
            .flatMap { $0.deleteCandidateAssets }
    }

    private var selectedBytes: Int64 {
        selectedAssets.reduce(into: Int64(0)) { acc, a in acc += Int64(a.pixelWidth * a.pixelHeight / 100) }
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

                if isSelectMode {
                    Button("Delete (\(selectedGroups.count))") {
                        guard purchaseManager.isPurchased else { showPaywall = true; return }
                        guard !selectedGroups.isEmpty else { return }
                        showBulkConfirm = true
                    }
                    .disabled(selectedGroups.isEmpty)
                    .foregroundStyle(Color.duckRose)
                } else {
                    Button(purchaseManager.isPurchased ? "Select" : "Select 🔒") {
                        guard purchaseManager.isPurchased else { showPaywall = true; return }
                        isSelectMode = true
                    }
                    .foregroundStyle(Color.duckPink)
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
        .fullScreenCover(isPresented: $showSwipeMode) {
            SwipeModeView(groups: visibleGroups)
                .environmentObject(purchaseManager)
                .environmentObject(deletionManager)
        }
        .sheet(isPresented: $showBulkConfirm) {
            DuckConfirmSheet(
                assetCount: selectedAssets.count,
                bytes: selectedBytes,
                onConfirm: {
                    showBulkConfirm = false
                    Task {
                            do {
                                try await deletionManager.bulkDelete(groups: selectedGroups.compactMap { id in
                                    visibleGroups.first(where: { $0.id == id })
                                })
                                for group in visibleGroups where selectedGroups.contains(group.id) {
                                    _ = await PhotoFeedbackStore.shared.recordSimilarGroupDecision(
                                        group: group,
                                        kind: .deleteSelected,
                                        stage: .committed,
                                        selectedKeeperID: group.keeperAssetID,
                                        deletedAssetIDs: group.deleteCandidateIDs,
                                        keptAssetIDs: [group.keeperAssetID].compactMap { $0 },
                                        recommendationAccepted: true,
                                        note: "Bulk delete from results list"
                                    )
                                }
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                    visibleGroups.removeAll { selectedGroups.contains($0.id) }
                                    selectedGroups.removeAll()
                                    isSelectMode = false
                                }
                        } catch {
                            deletionError = error.localizedDescription
                        }
                    }
                },
                onCancel: { showBulkConfirm = false }
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .purchaseDidSucceed)) { _ in
            showPaywall = false
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
            StatPill(title: "Selected", value: "\(selectedAssets.count) / \(currentDeletableCount)", accent: .duckPink, icon: "checkmark.circle.fill")
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
            ForEach(filteredGroups) { group in
                DuckCard {
                    VStack(spacing: 12) {
                        NavigationLink {
                            PhotoGroupDetailView(group: group, allGroups: filteredGroups) {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                    visibleGroups.removeAll { $0.id == group.id }
                                    selectedGroups.remove(group.id)
                                }
                            }
                            .environmentObject(purchaseManager)
                            .environmentObject(deletionManager)
                        } label: {
                            GroupOverviewCard(
                                group: group,
                                isSelected: selectedGroups.contains(group.id),
                                isSelectMode: isSelectMode
                            )
                            .contentShape(Rectangle())
                        }
                        .simultaneousGesture(TapGesture().onEnded {
                            if isSelectMode {
                                if selectedGroups.contains(group.id) {
                                    selectedGroups.remove(group.id)
                                } else {
                                    selectedGroups.insert(group.id)
                                }
                            }
                        })

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
                                            selectedGroups.remove(group.id)
                                        }
                                    } catch {
                                        // Keep the existing error handling surface unchanged for now.
                                    }
                                }
                            } label: {
                                Text("Keep Best")
                                    .font(.duckCaption.weight(.semibold))
                                    .foregroundStyle(Color.duckPink)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Color.duckCream, in: Capsule())
                            }

                            Button {
                                // Move the group to the end of the visible list so it's
                                // deferred without disrupting the active filter or select mode.
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
                                    .padding(.horizontal, 12)
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

// MARK: - Bulk confirm sheet

private struct DuckConfirmSheet: View {
    let assetCount: Int
    let bytes: Int64
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private var gbLabel: String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    var body: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.duckSoftPink)
                .frame(width: 40, height: 4)
                .padding(.top, 12)
                .padding(.bottom, 24)

            Image(systemName: "photo.stack")
                .font(.system(size: 32))
                .foregroundStyle(Color.duckSoftPink)
                .padding(.bottom, 16)

            Text("Free up \(gbLabel)?")
                .font(.duckTitle)
                .foregroundStyle(Color.duckBerry)
                .padding(.bottom, 8)

            Text("The best shot from each group will be kept. \(assetCount) photo\(assetCount == 1 ? "" : "s") will be removed.")
                .font(.duckCaption)
                .foregroundStyle(Color.duckRose)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.bottom, 32)

            VStack(spacing: 12) {
                DuckPrimaryButton(title: "Confirm · Free \(gbLabel)", action: onConfirm)
                DuckOutlineButton(title: "Cancel", color: .duckRose, action: onCancel)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity)
        .background(Color.duckCream)
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 28,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 28
            )
        )
    }
}

// MARK: - Group Row

private struct GroupOverviewCard: View {
    let group: PhotoGroup
    let isSelected: Bool
    let isSelectMode: Bool
    @State private var thumbnail: UIImage?

    init(
        group: PhotoGroup,
        isSelected: Bool,
        isSelectMode: Bool
    ) {
        self.group = group
        self.isSelected = isSelected
        self.isSelectMode = isSelectMode
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                thumbnailStack
                    .accessibilityHidden(true) // Described by the combined label below

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

                if isSelectMode {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.duckPink : Color.duckSoftPink)
                        .font(.title3)
                } else {
                    BestShotBadge(
                        isRecommended: group.keeperAssetID != nil,
                        needsReview: group.groupConfidence != .high
                    )
                }
            }

            if !group.reasons.isEmpty {
                ReasonChipsRow(reasons: Array(group.reasons.prefix(3)))
            }
        }
        .task { thumbnail = await loadThumbnail(for: group.assets.first) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(reasonLabel), \(confidenceLabel), \(group.photoCount) photos, \(ByteCountFormatter.string(fromByteCount: group.reclaimableBytes, countStyle: .file)) reclaimable")
    }

    private var thumbnailStack: some View {
        ZStack {
            ForEach(0..<min(3, group.assets.count), id: \.self) { i in
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.duckSoftPink.opacity(0.4))
                    .frame(width: 48, height: 48)
                    .offset(x: CGFloat(i) * 4, y: CGFloat(-i) * 4)
            }
            if let img = thumbnail {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(width: 60, height: 60)
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
        case .high: return "High confidence"
        case .medium: return "Needs review"
        case .low: return "Needs review"
        }
    }

    private var confidenceColor: Color {
        switch group.groupConfidence {
        case .high: return .duckPink
        case .medium: return .duckOrange
        case .low: return .duckRose
        }
    }

    private func loadThumbnail(for asset: PHAsset?) async -> UIImage? {
        guard let asset else { return nil }
        return await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .fastFormat
            options.isNetworkAccessAllowed = false
            PHImageManager.default().requestImage(
                for: asset, targetSize: CGSize(width: 100, height: 100),
                contentMode: .aspectFill, options: options
            ) { image, info in
                // .fastFormat can fire twice: degraded first, then final.
                // Guard prevents resuming the continuation twice → crash.
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
                guard !isDegraded else { return }
                continuation.resume(returning: image)
            }
        }
    }
}
