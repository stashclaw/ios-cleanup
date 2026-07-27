import SwiftUI
import Photos

struct PhotoResultsView: View {
    let groups: [PhotoGroup]
    @EnvironmentObject private var purchaseManager: PurchaseManager
    @EnvironmentObject private var deletionManager: DeletionManager

    @State private var hiddenGroupIDs: Set<UUID> = []
    @State private var deferredGroupIDs: [UUID] = []
    @State private var keepBestInFlightGroupIDs: Set<UUID> = []
    @State private var showPaywall = false
    @State private var showAutoCleanAllConfirm = false
    @State private var isAutoCleaningAll = false
    @State private var pendingAutoCleanGroups: [PhotoGroup] = []
    @State private var startAutoCleanAfterDismiss = false
    @State private var deletionError: String?
    @State private var activeFilter: FilterPill = .all
    @State private var reviewLaterToastVisible = false
    @State private var reviewLaterDismissToken = 0

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
        PhotoDeletionGuardrails.compatibleAutoCleanGroups(
            from: filteredGroups.filter(\.isAutoCleanEligible)
        )
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

                    if reviewLaterToastVisible {
                        VStack {
                            Spacer()
                            DuckToast(
                                style: .info,
                                message: "Moved to end of list",
                                actionLabel: "Undo",
                                onAction: { undoReviewLater() }
                            )
                            // Sit above the deletion undo toast when both are
                            // on screen instead of overlapping it.
                            .padding(.bottom, deletionManager.toastVisible ? 84 : 8)
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
        }
        .navigationTitle("Similar Photos")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // One toolbar action. Duck Mode lives on the dashboard hero CTA,
            // not up here. Lock only while the purchase is missing.
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    guard purchaseManager.isPurchased else { showPaywall = true; return }
                    let plannedGroups = autoCleanEligibleGroups
                    guard !plannedGroups.isEmpty else {
                        deletionError = "No high-confidence duplicate groups are safe to auto-clean in this filter. Similar-only groups need review."
                        DuckHaptics.rigid()
                        return
                    }
                    deletionError = nil
                    pendingAutoCleanGroups = plannedGroups
                    showAutoCleanAllConfirm = true
                } label: {
                    if isAutoCleaningAll {
                        ProgressView()
                    } else if purchaseManager.isPurchased {
                        Text("Auto-clean all")
                    } else {
                        Label("Auto-clean all", systemImage: "lock.fill")
                    }
                }
                .font(.duckCaption.weight(.semibold))
                .foregroundStyle(Color.textSecondary)
                .disabled(isAutoCleaningAll)
                .accessibilityHint(purchaseManager.isPurchased ? "" : "Requires PhotoDuck unlock")
            }
        }
        .sheet(
            isPresented: $showAutoCleanAllConfirm,
            onDismiss: { startPendingAutoCleanIfNeeded() }
        ) {
            NavigationStack {
                AutoCleanConfirmationSheet(
                    groups: pendingAutoCleanGroups,
                    onConfirm: {
                        // PhotoKit must present its own confirmation dialog.
                        // Wait until this sheet has completely dismissed before
                        // starting the request or iOS may suppress that dialog.
                        startAutoCleanAfterDismiss = true
                        showAutoCleanAllConfirm = false
                    },
                    onCancel: {
                        startAutoCleanAfterDismiss = false
                        showAutoCleanAllConfirm = false
                    }
                )
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showPaywall) { PaywallView().environmentObject(purchaseManager) }
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

    private func startPendingAutoCleanIfNeeded() {
        let groupsToClean = pendingAutoCleanGroups
        let shouldStart = startAutoCleanAfterDismiss
        pendingAutoCleanGroups = []
        startAutoCleanAfterDismiss = false
        guard shouldStart, !groupsToClean.isEmpty else { return }

        Task {
            // Give UIKit one run-loop turn after SwiftUI's sheet teardown so
            // Photos can reliably present the system deletion confirmation.
            await Task.yield()
            await autoCleanAll(groups: groupsToClean)
        }
    }

    private func autoCleanAll(groups groupsToClean: [PhotoGroup]) async {
        guard !groupsToClean.isEmpty, !isAutoCleaningAll else {
            return
        }
        isAutoCleaningAll = true
        deletionError = nil
        defer { isAutoCleaningAll = false }

        do {
            try await deletionManager.keepBestImmediately(
                from: groupsToClean
            )
            let cleanedIDs = Set(groupsToClean.map(\.id))
            if groupsToClean.count <= 100 {
                withAnimation(.duckSpring) {
                    hiddenGroupIDs.formUnion(cleanedIDs)
                }
            } else {
                // Animating hundreds or thousands of rows at once can stall
                // SwiftUI long after PhotoKit has completed the deletion.
                hiddenGroupIDs.formUnion(cleanedIDs)
            }

            recordAutoCleanFeedback(groupsToClean)
        } catch is CancellationError {
            deletionError = nil
        } catch {
            deletionError = DeletionManager.isUserCancellation(error)
                ? nil
                : error.localizedDescription
        }
    }

    private func recordAutoCleanFeedback(_ cleanedGroups: [PhotoGroup]) {
        Task(priority: .utility) {
            await PhotoFeedbackStore.shared.recordAutoCleanDecisions(
                groups: cleanedGroups
            )
        }
    }

    // MARK: - Review later

    private func deferGroupForReviewLater(_ group: PhotoGroup) {
        withAnimation(.duckSpring) {
            deferredGroupIDs.removeAll { $0 == group.id }
            deferredGroupIDs.append(group.id)
        }
        withAnimation { reviewLaterToastVisible = true }
        reviewLaterDismissToken += 1
        let token = reviewLaterDismissToken
        Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard token == reviewLaterDismissToken else { return }
            withAnimation { reviewLaterToastVisible = false }
        }
    }

    private func undoReviewLater() {
        DuckHaptics.rigid()
        reviewLaterDismissToken += 1
        withAnimation(.duckSpring) {
            if let lastDeferred = deferredGroupIDs.last {
                deferredGroupIDs.removeAll { $0 == lastDeferred }
            }
            reviewLaterToastVisible = false
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
                        .foregroundStyle(Color.danger)
                        .padding(.horizontal)
                }
                groupList
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
        .background(Color.backgroundBlush.ignoresSafeArea())
    }

    // MARK: - Hero card

    private var heroCard: some View {
        PrimaryMetricCard(
            title: "Review progress",
            value: "\(filteredGroups.count) / \(groups.count) groups shown",
            detail: "\(currentReviewCount) photos in current review set · \(currentDeletableCount) move candidates",
            accent: .accentPrimary,
            progress: groups.isEmpty ? 0 : Double(filteredGroups.count) / Double(groups.count)
        ) {
            PhotoDuckMascotArt(size: 72)
        }
    }

    private var metricRow: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                StatPill(title: "Groups", value: "\(filteredGroups.count)", accent: .accentPrimary, icon: "photo.stack")
                StatPill(title: "Current set", value: "\(currentReviewCount) photos", accent: .warning, icon: "photo.stack")
            }
            StatPill(title: "Potential space", value: ByteCountFormatter.string(fromByteCount: reclaimableBytes, countStyle: .file), accent: .textSecondary, icon: "sparkles")
        }
    }

    // MARK: - Filter pills

    private func count(for pill: FilterPill) -> Int {
        switch pill {
        case .all:           return visibleGroups.count
        case .nearDuplicate: return visibleGroups.filter { $0.reason == .nearDuplicate }.count
        case .similar:       return visibleGroups.filter { $0.reason == .visuallySimilar }.count
        case .burst:         return visibleGroups.filter { $0.reason == .burstShot }.count
        }
    }

    private var filterPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(FilterPill.allCases, id: \.self) { pill in
                    Button("\(pill.rawValue) \(count(for: pill))") {
                        activeFilter = pill
                    }
                    .font(.duckCaption.weight(.semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)   // ≥44pt target
                    .background(
                        activeFilter == pill ? Color.accentPrimary : Color.surface,
                        in: Capsule()
                    )
                    .foregroundStyle(activeFilter == pill ? Color.white : Color.textSecondary)
                    .accessibilityAddTraits(activeFilter == pill ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    // MARK: - Group list

    private var groupList: some View {
        let groups = filteredGroups
        let indexByID = Dictionary(
            uniqueKeysWithValues: groups.enumerated().map {
                ($0.element.id, $0.offset)
            }
        )
        return LazyVStack(spacing: 12) {
            ForEach(groups) { group in
                DuckCard {
                    VStack(spacing: 12) {
                        NavigationLink {
                            PhotoGroupDetailView(
                                group: group,
                                groupIndex: indexByID[group.id] ?? 0,
                                totalGroups: groups.count,
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
                                    // A rapid double-tap must not enqueue the
                                    // same group twice or double-record feedback.
                                    guard keepBestInFlightGroupIDs.insert(group.id).inserted else { return }
                                    Task {
                                        defer { keepBestInFlightGroupIDs.remove(group.id) }
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
                                        .background(LinearGradient.duckPrimaryCTA, in: Capsule())
                                }
                                .disabled(keepBestInFlightGroupIDs.contains(group.id))
                            } else {
                                Text("Review only")
                                    .font(.duckCaption.weight(.semibold))
                                    .foregroundStyle(Color.textSecondary)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .frame(minHeight: 44)
                                    .background(Color.surface, in: Capsule())
                            }

                            Button {
                                deferGroupForReviewLater(group)
                            } label: {
                                Text("Review Later")
                                    .font(.duckCaption.weight(.semibold))
                                    .foregroundStyle(Color.textSecondary)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .frame(minHeight: 44)
                                    .background(Color.surface, in: Capsule())
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
    private static let previewLimit = 30

    private let assets: [PHAsset]
    private let potentialBytes: Int64
    let onConfirm: () -> Void
    let onCancel: () -> Void

    init(
        groups: [PhotoGroup],
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        var seen = Set<String>()
        assets = groups
            .flatMap(\.deleteCandidateAssets)
            .filter { seen.insert($0.localIdentifier).inserted }
        potentialBytes = groups.reduce(into: Int64(0)) {
            $0 += $1.reclaimableBytes
        }
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    private var previewAssets: ArraySlice<PHAsset> {
        assets.prefix(Self.previewLimit)
    }

    private var hiddenPreviewCount: Int {
        max(assets.count - previewAssets.count, 0)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Review Auto-clean")
                        .font(.duckTitle)
                        .foregroundStyle(Color.textPrimary)
                    Text("\(assets.count) high-confidence duplicate\(assets.count == 1 ? "" : "s") selected")
                        .font(.duckBody)
                        .foregroundStyle(Color.textSecondary)
                    Text("\(potentialBytes.formattedBytes) potential space")
                        .font(.duckCaption.weight(.semibold))
                        .foregroundStyle(Color.accentPrimary)
                }

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 82), spacing: 8)],
                    spacing: 8
                ) {
                    ForEach(previewAssets, id: \.localIdentifier) { asset in
                        AutoCleanDeleteThumbnail(asset: asset)
                    }
                }

                if hiddenPreviewCount > 0 {
                    Text("+ \(hiddenPreviewCount.formatted()) more selected")
                        .font(.duckCaption.weight(.semibold))
                        .foregroundStyle(Color.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }

                Text("Recommended keepers are excluded. These photos move to Recently Deleted, and space is permanently reclaimed only after that album is emptied.")
                    .font(.duckCaption)
                    .foregroundStyle(Color.textSecondary)

                DuckPrimaryButton(title: "Move \(assets.count) to Recently Deleted") {
                    onConfirm()
                }
                .disabled(assets.isEmpty)

                DuckOutlineButton(title: "Cancel", color: .textSecondary) {
                    onCancel()
                }
            }
            .padding(20)
        }
        .background(Color.backgroundBlush.ignoresSafeArea())
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
                Color.decorPink.opacity(0.35)
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
                .background(Color.danger, in: Circle())
                .padding(5)
        }
        .accessibilityLabel("Selected for Recently Deleted")
        .task {
            image = await PhotoImageRepository.shared.image(
                for: asset,
                targetSize: CGSize(width: 180, height: 180),
                contentMode: .aspectFill,
                qualityIntent: .thumbnail,
                allowNetworkAccess: false
            )
        }
    }
}

// MARK: - Group Row

private struct GroupOverviewCard: View {
    let group: PhotoGroup
    @State private var thumbnails: [String: UIImage] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            thumbnailRow

            HStack(spacing: 8) {
                Text(reasonLabel)
                    .font(.duckBody)
                    .foregroundStyle(Color.textPrimary)

                StatusBadge(title: confidenceLabel, accent: confidenceColor)

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.duckCaption.weight(.semibold))
                    .foregroundStyle(Color.decorPink)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(group.photoCount) photos")
                    .font(.duckCaption)
                    .foregroundStyle(Color.textSecondary)

                Spacer(minLength: 8)

                Text(actionLabel)
                    .font(.duckCaption.weight(.semibold))
                    .foregroundStyle(Color.accentPrimary)
                    .multilineTextAlignment(.trailing)
            }

            if let reason = group.reasons.first {
                Text(reason)
                    .font(.duckCaption)
                    .foregroundStyle(Color.textSecondary.opacity(0.8))
                    .lineLimit(2)
            }
        }
        .task(id: group.id) { await loadThumbnails() }
    }

    private var thumbnailRow: some View {
        let assets = previewAssets
        return HStack(spacing: 6) {
            ForEach(assets, id: \.localIdentifier) { asset in
                ZStack {
                    if let image = thumbnails[asset.localIdentifier] {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color.decorPink.opacity(0.4)
                            .overlay(ProgressView().scaleEffect(0.6).tint(.white))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 104)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: DuckRadius.s, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DuckRadius.s, style: .continuous)
                        .stroke(Color.decorPink.opacity(0.55), lineWidth: 1)
                )
                .overlay(alignment: .topLeading) {
                    if asset.localIdentifier == group.keeperAssetID {
                        Image(systemName: "star.fill")
                            .font(.duckMicro.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(Color.accentPrimary, in: Circle())
                            .padding(6)
                            .accessibilityHidden(true)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if asset.localIdentifier == assets.last?.localIdentifier,
                       group.assets.count > assets.count {
                        Text("+\(group.assets.count - assets.count)")
                            .font(.duckMicro.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 5)
                            .background(Color.black.opacity(0.62), in: Capsule())
                            .padding(6)
                    }
                }
            }
        }
    }

    private var previewAssets: [PHAsset] {
        let keeper = group.keeperAssetID.flatMap { keeperID in
            group.assets.first { $0.localIdentifier == keeperID }
        }
        let remaining = group.assets.filter { $0.localIdentifier != keeper?.localIdentifier }
        return Array(([keeper].compactMap { $0 } + remaining).prefix(3))
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

    // High confidence reads as a trust signal, not an ad — success green,
    // never pink. Anything needing review is warning amber.
    private var confidenceColor: Color {
        switch group.groupConfidence {
        case .high:   return .success
        case .medium: return .warning
        case .low:    return .warning
        }
    }

    private var actionLabel: String {
        if group.isAutoCleanEligible {
            return "Save \(ByteCountFormatter.string(fromByteCount: group.reclaimableBytes, countStyle: .file))"
        }
        if !group.blockerFlags.isEmpty {
            return "Review only · \(group.blockerFlags.count) safeguard\(group.blockerFlags.count == 1 ? "" : "s")"
        }
        return "Review together only"
    }

    private func loadThumbnails() async {
        let assets = previewAssets
        var loaded: [String: UIImage] = [:]
        await withTaskGroup(of: (String, UIImage?).self) { taskGroup in
            for asset in assets {
                taskGroup.addTask {
                    (asset.localIdentifier, await requestThumb(asset))
                }
            }
            for await (assetID, image) in taskGroup {
                loaded[assetID] = image
            }
        }
        thumbnails = loaded
    }

    private func requestThumb(_ asset: PHAsset) async -> UIImage? {
        await PhotoImageRepository.shared.image(
            for: asset,
            targetSize: CGSize(width: 144, height: 144),
            contentMode: .aspectFill,
            qualityIntent: .thumbnail,
            allowNetworkAccess: false
        )
    }
}
