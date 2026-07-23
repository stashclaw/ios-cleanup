import SwiftUI
import Photos

struct PhotoResultsView: View {
    let groups: [PhotoGroup]
    @EnvironmentObject private var purchaseManager: PurchaseManager
    @EnvironmentObject private var deletionManager: DeletionManager

    @State private var hiddenGroupIDs: Set<UUID> = []
    @State private var deferredGroupIDs: [UUID] = []
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

    private var visibleGroups: [PhotoGroup] {
        let available = groups.filter { !hiddenGroupIDs.contains($0.id) }
        let deferredSet = Set(deferredGroupIDs)
        let regular = available.filter { !deferredSet.contains($0.id) }
        let byID = Dictionary(uniqueKeysWithValues: available.map { ($0.id, $0) })
        return regular + deferredGroupIDs.compactMap { byID[$0] }
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

    private var autoCleanEligibleGroups: [PhotoGroup] {
        filteredGroups.filter(\.isAutoCleanEligible)
    }

    private var totalPhotoCount: Int {
        groups.reduce(0) { $0 + $1.assets.count }
    }

    private var currentReviewCount: Int {
        filteredGroups.reduce(0) { $0 + $1.assets.count }
    }

    private var currentDeletableCount: Int {
        Set(filteredGroups.flatMap(\.deleteCandidateIDs)).count
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

                Button {
                    guard purchaseManager.isPurchased else { showPaywall = true; return }
                    showAutoCleanAllConfirm = true
                } label: {
                    HStack(spacing: 4) {
                        if !purchaseManager.isPurchased {
                            Image(systemName: "lock.fill")
                        }
                        Text("Auto-clean all")
                    }
                }
                .font(.duckCaption)
                .foregroundStyle(Color.duckRose)
                .disabled(autoCleanEligibleGroups.isEmpty)
                .accessibilityHint(purchaseManager.isPurchased ? "" : "Requires PhotoDuck unlock")
            }
        }
        .sheet(isPresented: $showAutoCleanAllConfirm) {
            NavigationStack {
                AutoCleanConfirmationSheet(
                    groups: autoCleanEligibleGroups,
                    onConfirm: {
                        showAutoCleanAllConfirm = false
                        Task { await autoCleanAll() }
                    },
                    onCancel: {
                        showAutoCleanAllConfirm = false
                    }
                )
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showPaywall) { PaywallView().environmentObject(purchaseManager) }
        .fullScreenCover(isPresented: $showSwipeMode) {
            SwipeModeView(groups: visibleGroups)
                .environmentObject(purchaseManager)
                .environmentObject(deletionManager)
                .deletionUndoToast()
        }
        .onReceive(NotificationCenter.default.publisher(for: .purchaseDidSucceed)) { _ in
            showPaywall = false
        }
        .onChange(of: groups.map(\.id)) { currentIDs in
            let currentIDSet = Set(currentIDs)
            hiddenGroupIDs.formIntersection(currentIDSet)
            deferredGroupIDs.removeAll { !currentIDSet.contains($0) }
        }
        .onChange(of: deletionManager.undoEventID) { _ in
            restoreGroupsAffectedByUndo()
        }
        .onChange(of: deletionManager.lastDeletionError) { error in
            guard error != nil else { return }
            withAnimation(.duckSpring) {
                hiddenGroupIDs.removeAll()
            }
        }
    }

    // MARK: - Auto-clean all

    private func autoCleanAll() async {
        let groupsToClean = autoCleanEligibleGroups
        guard !groupsToClean.isEmpty else { return }

        do {
            try await deletionManager.keepBest(from: groupsToClean)
            for group in groupsToClean {
                _ = await PhotoFeedbackStore.shared.recordSimilarGroupDecision(
                    group: group,
                    kind: .keepBest,
                    stage: .committed,
                    selectedKeeperID: group.keeperAssetID,
                    deletedAssetIDs: group.deleteCandidateIDs,
                    keptAssetIDs: [group.keeperAssetID].compactMap { $0 },
                    recommendationAccepted: true,
                    note: "Auto-clean all from results list"
                )
            }

            let cleanedIDs = Set(groupsToClean.map(\.id))
            withAnimation(.duckSpring) {
                hiddenGroupIDs.formUnion(cleanedIDs)
            }
        } catch is CancellationError {
            deletionError = nil
        } catch {
            deletionError = error.localizedDescription
        }
    }

    private func restoreGroupsAffectedByUndo() {
        let undoneAssetIDs = deletionManager.lastUndoneAssetIDs
        guard !undoneAssetIDs.isEmpty else { return }

        let restoredGroupIDs = groups.reduce(into: Set<UUID>()) { result, group in
            if group.assets.contains(where: { undoneAssetIDs.contains($0.localIdentifier) }) {
                result.insert(group.id)
            }
        }

        withAnimation(.duckSpring) {
            hiddenGroupIDs.subtract(restoredGroupIDs)
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
                    Text("Moving to Recently Deleted...")
                        .font(.duckTitle)
                        .foregroundStyle(Color.duckBerry)

                    DuckProgressBar(progress: deletionManager.deletionProgress, color: .duckPink)
                        .frame(height: 12)

                    VStack(spacing: 6) {
                        Text(
                            "\(ByteCountFormatter.string(fromByteCount: deletionManager.bulkProcessedBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: deletionManager.bulkTotalBytes, countStyle: .file)) selected"
                        )
                        .font(.duckBody)
                        .foregroundStyle(Color.duckRose)
                        .multilineTextAlignment(.center)

                        Text("\(deletionManager.bulkProcessedCount) of \(deletionManager.bulkTotalCount) photos")
                            .font(.duckCaption)
                            .foregroundStyle(Color.duckBerry)

                        Text("Potential space is permanently reclaimed after Recently Deleted is emptied.")
                            .font(.duckCaption)
                            .foregroundStyle(Color.duckRose)
                            .multilineTextAlignment(.center)
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
            detail: "\(currentReviewCount) photos in current review set · \(currentDeletableCount) move candidates",
            accent: .duckPink,
            progress: groups.isEmpty ? 0 : Double(filteredGroups.count) / Double(groups.count)
        ) {
            PhotoDuckMascotArt(size: 72)
        }
    }

    private var metricRow: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            StatPill(title: "Groups", value: "\(filteredGroups.count)", accent: .duckPink, icon: "photo.stack")
            StatPill(title: "Current set", value: "\(currentReviewCount) photos", accent: .duckOrange, icon: "photo.stack")
            StatPill(title: "Potential space", value: ByteCountFormatter.string(fromByteCount: reclaimableBytes, countStyle: .file), accent: .duckRose, icon: "sparkles")
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
                    .frame(minHeight: 44)
                    .background(
                        activeFilter == pill ? Color.duckPink : Color.duckCream,
                        in: Capsule()
                    )
                    .foregroundStyle(activeFilter == pill ? Color.white : Color.duckRose)
                    .accessibilityAddTraits(activeFilter == pill ? .isSelected : [])
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
                                    withAnimation(SwiftUI.Animation.spring(response: 0.35, dampingFraction: 0.82)) {
                                        _ = hiddenGroupIDs.insert(group.id)
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
                            if group.isAutoCleanEligible {
                                Button {
                                    Task {
                                        do {
                                            try await deletionManager.keepBest(from: group)
                                            _ = await PhotoFeedbackStore.shared.recordSimilarGroupDecision(
                                                group: group,
                                                kind: .keepBest,
                                                stage: .committed,
                                                selectedKeeperID: group.keeperAssetID,
                                                deletedAssetIDs: group.deleteCandidateIDs,
                                                keptAssetIDs: [group.keeperAssetID].compactMap { $0 },
                                                recommendationAccepted: true,
                                                note: "Keep Best from results list"
                                            )
                                            withAnimation(.duckSpring) {
                                                _ = hiddenGroupIDs.insert(group.id)
                                            }
                                        } catch is CancellationError {
                                            deletionError = nil
                                        } catch {
                                            deletionError = error.localizedDescription
                                        }
                                    }
                                } label: {
                                    Text("Keep Best")
                                        .font(.duckCaption.weight(.semibold))
                                        .foregroundStyle(Color.white)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 8)
                                        .frame(minHeight: 44)
                                        .background(Color.duckPink, in: Capsule())
                                }
                            } else {
                                Text("Review only")
                                    .font(.duckCaption.weight(.semibold))
                                    .foregroundStyle(Color.duckRose)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .frame(minHeight: 44)
                                    .background(Color.duckCream, in: Capsule())
                            }

                            Button {
                                withAnimation(.duckSpring) {
                                    deferredGroupIDs.removeAll { $0 == group.id }
                                    deferredGroupIDs.append(group.id)
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
                                    .frame(minHeight: 44)
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

private struct AutoCleanConfirmationSheet: View {
    let groups: [PhotoGroup]
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private var assets: [PHAsset] {
        var seen = Set<String>()
        return groups
            .flatMap(\.deleteCandidateAssets)
            .filter { seen.insert($0.localIdentifier).inserted }
    }

    private var potentialBytes: Int64 {
        groups.reduce(into: Int64(0)) { $0 += $1.reclaimableBytes }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Review Auto-clean")
                        .font(.duckTitle)
                        .foregroundStyle(Color.duckBerry)
                    Text("\(assets.count) high-confidence duplicate\(assets.count == 1 ? "" : "s") selected")
                        .font(.duckBody)
                        .foregroundStyle(Color.duckRose)
                    Text("\(potentialBytes.formattedBytes) potential space")
                        .font(.duckCaption.weight(.semibold))
                        .foregroundStyle(Color.duckPink)
                }

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 82), spacing: 8)],
                    spacing: 8
                ) {
                    ForEach(assets, id: \.localIdentifier) { asset in
                        AutoCleanDeleteThumbnail(asset: asset)
                    }
                }

                Text("Recommended keepers are excluded. These photos move to Recently Deleted, and space is permanently reclaimed only after that album is emptied.")
                    .font(.duckCaption)
                    .foregroundStyle(Color.duckRose)

                DuckPrimaryButton(title: "Move \(assets.count) to Recently Deleted") {
                    onConfirm()
                }
                .disabled(assets.isEmpty)

                DuckOutlineButton(title: "Cancel", color: .duckRose) {
                    onCancel()
                }
            }
            .padding(20)
        }
        .background(Color.duckBlush.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AutoCleanDeleteThumbnail: View {
    let asset: PHAsset
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.duckSoftPink.opacity(0.35)
                    .overlay(ProgressView().tint(.white))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Image(systemName: "trash.fill")
                .font(.duckMicro.weight(.bold))
                .foregroundStyle(.white)
                .padding(6)
                .background(Color.duckDanger, in: Circle())
                .padding(5)
        }
        .accessibilityLabel("Selected for Recently Deleted")
        .task {
            image = await asset.loadImage(
                targetSize: CGSize(width: 180, height: 180),
                deliveryMode: .opportunistic,
                allowNetwork: true,
                contentMode: .aspectFill,
                acceptsDegradedResult: true
            )
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

                Text(actionLabel)
                    .font(.duckCaption.weight(.semibold))
                    .foregroundStyle(Color.duckPink)

                if let reason = group.reasons.first {
                    Text(reason)
                        .font(.duckCaption)
                        .foregroundStyle(Color.duckRose.opacity(0.8))
                        .lineLimit(1)
                }
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

    private var actionLabel: String {
        if group.isAutoCleanEligible {
            return "\(ByteCountFormatter.string(fromByteCount: group.reclaimableBytes, countStyle: .file)) potential space"
        }
        if !group.blockerFlags.isEmpty {
            return "Review only · \(group.blockerFlags.count) safeguard\(group.blockerFlags.count == 1 ? "" : "s")"
        }
        return "Review together only"
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
        await asset.loadImage(
            targetSize: CGSize(width: 144, height: 144),
            deliveryMode: .opportunistic,
            allowNetwork: true,
            contentMode: .aspectFill,
            acceptsDegradedResult: true
        )
    }
}
