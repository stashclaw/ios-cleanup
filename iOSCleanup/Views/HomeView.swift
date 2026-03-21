import SwiftUI

struct HomeView: View {
    @ObservedObject var viewModel: HomeViewModel
    @Binding var isHomeTabSelected: Bool
    @EnvironmentObject private var purchaseManager: PurchaseManager
    @EnvironmentObject private var deletionManager: DeletionManager

    @State private var showPaywall = false
    @State private var showCompletion = false
    @State private var showReviewResults = false
    @State private var lastPresentedFreedBytes: Int64 = 0
    @State private var lastPresentedFreedItems: Int = 0
    @State private var completionFreedBytes: Int64 = 0
    @State private var completionFreedItems: Int = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    heroCard
                    nextActionCard
                    findingsRow
                    categoryGrid
                    storageCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .background(Color.photoduckBlushBackground.ignoresSafeArea())
            .navigationTitle("PhotoDuck")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !purchaseManager.isPurchased {
                        Button("Unlock") { showPaywall = true }
                            .font(.duckCaption)
                            .foregroundStyle(Color.duckPink)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.duckCream, in: Capsule())
                    }
                }
            }
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView().environmentObject(purchaseManager)
        }
        .sheet(isPresented: $showCompletion) {
            CompletionOverlay(
                viewModel: viewModel,
                freedItems: completionFreedItems,
                freedBytes: completionFreedBytes
            )
        }
        .sheet(isPresented: $showReviewResults) {
            NavigationStack {
                PhotoResultsView(groups: viewModel.photoGroups)
                    .environmentObject(purchaseManager)
                    .environmentObject(deletionManager)
            }
        }
        .onChange(of: deletionManager.totalBytesFreed) { _ in
            presentCompletionIfNeeded()
        }
        .onChange(of: isHomeTabSelected) { isVisible in
            if isVisible {
                presentCompletionIfNeeded()
            }
        }
        .onAppear {
            presentCompletionIfNeeded()
        }
    }

    private var heroCard: some View {
        PrimaryMetricCard(
            title: viewModel.heroStatusLabel,
            value: viewModel.heroPrimaryMetricValue,
            detail: "\(viewModel.heroDetailText)\n\(viewModel.heroSecondaryText)",
            accent: heroAccent,
            progress: heroProgress
        ) {
            PhotoDuckAssetImage(
                assetNames: ["photoduck_mascot", "photoduck_logo"],
                fallback: { PhotoDuckMascotFallback(size: 72) }
            )
            .frame(width: 90, height: 90)
        }
        // Announce state transitions to VoiceOver, so status changes are not
        // communicated by colour alone (accessibility colour-blindness requirement).
        .accessibilityValue(viewModel.heroStatusLabel)
    }

    private var nextActionCard: some View {
        DuckCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Next best action")
                        .font(.duckHeading)
                        .foregroundStyle(Color.duckBerry)
                    Spacer()
                    StatusBadge(title: viewModel.heroNextActionLabel, accent: heroAccent)
                }

                VStack(spacing: 10) {
                    primaryCTA
                    if hasSecondaryAction {
                        secondaryActionButton
                    }
                }
            }
            .padding(16)
        }
    }

    private var findingsRow: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            StatPill(
                title: "Scanned",
                value: viewModel.scanProgressLabel,
                accent: .duckPink,
                icon: "photo.on.rectangle.angled"
            )
            StatPill(
                title: "Rate",
                value: viewModel.scanRateLabel,
                accent: .duckYellow,
                icon: "speedometer"
            )
            StatPill(
                title: "Groups",
                value: viewModel.groupsFoundCount.formatted(),
                accent: .duckRose,
                icon: "rectangle.stack.fill"
            )
            StatPill(
                title: "Reviewable",
                value: viewModel.reviewablePhotosCount.formatted(),
                accent: .duckOrange,
                icon: "sparkles"
            )
        }
    }

    private var categoryGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            HomeCategoryTile(
                icon: "photo.on.rectangle.angled",
                color: .duckPink,
                title: "Duplicates",
                count: viewModel.groupsFoundCount,
                status: categoryStatus(for: viewModel.groupsFoundCount),
                note: categoryNote(for: viewModel.groupsFoundCount),
                destination: {
                    PhotoResultsView(groups: viewModel.photoGroups)
                        .environmentObject(purchaseManager)
                        .environmentObject(deletionManager)
                }
            )

            HomeCategoryTile(
                icon: "rectangle.stack.fill",
                color: .duckOrange,
                title: "Similar",
                count: viewModel.photoGroups.filter { $0.reason == .visuallySimilar }.count,
                status: categoryStatus(for: viewModel.photoGroups.filter { $0.reason == .visuallySimilar }.count),
                note: categoryNote(for: viewModel.photoGroups.filter { $0.reason == .visuallySimilar }.count),
                destination: {
                    PhotoResultsView(groups: viewModel.photoGroups)
                        .environmentObject(purchaseManager)
                        .environmentObject(deletionManager)
                }
            )

            HomeCategoryTile(
                icon: "person.2.fill",
                color: .duckRose,
                title: "Contacts",
                count: viewModel.contactMatches.count,
                status: viewModel.contactScanState == .scanning ? "Scanning" : viewModel.contactScanState == .completed ? "Ready" : "Idle",
                note: viewModel.contactMatches.isEmpty ? "0 found" : "\(viewModel.contactMatches.count) contacts",
                destination: {
                    ContactResultsView(matches: viewModel.contactMatches)
                        .environmentObject(purchaseManager)
                }
            )

            HomeCategoryTile(
                icon: "video.fill",
                color: .duckOrange,
                title: "Large Videos",
                count: viewModel.largeFiles.count,
                status: viewModel.fileScanState == .scanning ? "Scanning" : viewModel.fileScanState == .completed ? "Ready" : "Idle",
                note: viewModel.largeFiles.isEmpty ? "0 found" : "\(viewModel.largeFiles.count) items",
                destination: {
                    FileResultsView(files: viewModel.largeFiles)
                        .environmentObject(purchaseManager)
                }
            )
        }
    }

    private var storageCard: some View {
        DuckCard {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Device storage")
                        .font(.duckHeading)
                        .foregroundStyle(Color.duckBerry)
                    Text("\(viewModel.storageUsedFormatted) used of \(viewModel.storageTotalFormatted)")
                        .font(.duckCaption)
                        .foregroundStyle(Color.duckRose)
                    DuckProgressBar(progress: viewModel.storageUsedFraction, color: .duckPink)
                        .frame(height: 8)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(viewModel.reclaimableFormatted)
                        .font(.duckTitle)
                        .foregroundStyle(.duckPink)
                    Text("cleanup value")
                        .font(.duckLabel)
                        .foregroundStyle(Color.duckRose)
                }
            }
            .padding(16)
        }
    }

    private var primaryCTA: some View {
        Group {
            switch viewModel.heroState {
            case .permissionRequired:
                DuckPrimaryButton(title: "Allow Photos Access") {
                    viewModel.startDeepClean()
                }
            case .scanFailure:
                DuckPrimaryButton(title: "Try Again") {
                    viewModel.startDeepClean()
                }
            case .speedCleanActive:
                if viewModel.photoGroups.isEmpty {
                    StatusBadge(title: "Scanning in progress", accent: .duckYellow)
                } else {
                    DuckPrimaryButton(title: "Review quick wins") {
                        openReviewFlow()
                    }
                }
            case .deepCleanActive:
                DuckPrimaryButton(title: "Pause Deep Clean") {
                    viewModel.pauseDeepClean()
                }
            case .deepCleanPaused:
                DuckPrimaryButton(title: "Continue scanning") {
                    viewModel.resumeDeepClean()
                }
            case .reviewReadyPartialResults:
                DuckPrimaryButton(title: "Review Results") {
                    openReviewFlow()
                }
            case .completedResultsAvailable:
                DuckPrimaryButton(title: viewModel.photoGroups.isEmpty ? "Start Speed Clean" : "Review Results") {
                    if viewModel.photoGroups.isEmpty {
                        viewModel.startSpeedClean()
                    } else {
                        openReviewFlow()
                    }
                }
            case .idlePrompt:
                DuckPrimaryButton(title: "Start Speed Clean") {
                    viewModel.startSpeedClean()
                }
            }
        }
    }

    private var hasSecondaryAction: Bool {
        switch viewModel.heroState {
        case .speedCleanActive where !viewModel.photoGroups.isEmpty:
            return true
        case .deepCleanActive where viewModel.hasPartialResults && !viewModel.photoGroups.isEmpty:
            return true
        case .deepCleanPaused where viewModel.hasPartialResults && !viewModel.photoGroups.isEmpty:
            return true
        case .reviewReadyPartialResults:
            return true
        case .completedResultsAvailable where viewModel.photoGroups.isEmpty:
            return true
        case .idlePrompt:
            return true
        default:
            return false
        }
    }

    @ViewBuilder
    private var secondaryActionButton: some View {
        switch viewModel.heroState {
        case .speedCleanActive where !viewModel.photoGroups.isEmpty:
            DuckOutlineButton(title: "Review quick wins", color: .duckRose) {
                openReviewFlow()
            }
        case .deepCleanActive where viewModel.hasPartialResults && !viewModel.photoGroups.isEmpty:
            DuckOutlineButton(title: "Review partial results", color: .duckRose) {
                openReviewFlow()
            }
        case .deepCleanPaused where viewModel.hasPartialResults && !viewModel.photoGroups.isEmpty:
            DuckOutlineButton(title: "Review partial results", color: .duckRose) {
                openReviewFlow()
            }
        case .deepCleanPaused:
            DuckOutlineButton(title: "Start Deep Clean", color: .duckPink) {
                viewModel.startDeepClean()
            }
        case .reviewReadyPartialResults:
            DuckOutlineButton(title: "Start Deep Clean", color: .duckPink) {
                viewModel.startDeepClean()
            }
        case .completedResultsAvailable where viewModel.photoGroups.isEmpty:
            DuckOutlineButton(title: "Refresh Deep Clean", color: .duckPink) {
                viewModel.startDeepClean()
            }
        case .idlePrompt:
            DuckOutlineButton(title: "Start Deep Clean", color: .duckPink) {
                viewModel.startDeepClean()
            }
        default:
            EmptyView()
        }
    }

    private var heroAccent: Color {
        switch viewModel.heroState {
        case .permissionRequired:
            return .duckOrange
        case .scanFailure:
            return .duckRose
        case .speedCleanActive:
            return .duckYellow
        case .deepCleanActive:
            return .duckPink
        case .deepCleanPaused:
            return .duckRose
        case .reviewReadyPartialResults:
            return .duckOrange
        case .completedResultsAvailable:
            return .duckPink
        case .idlePrompt:
            return .duckPink
        }
    }

    private var heroProgress: Double? {
        switch viewModel.heroState {
        case .speedCleanActive, .deepCleanActive, .deepCleanPaused:
            return viewModel.progressFraction
        case .reviewReadyPartialResults, .completedResultsAvailable:
            return 1
        default:
            return nil
        }
    }

    private func categoryStatus(for count: Int) -> String {
        if viewModel.scanState == .scanning {
            return count > 0 ? "Partial" : "Scanning"
        }
        if count > 0 {
            return "Ready"
        }
        if viewModel.scanState == .completed {
            return "0 found"
        }
        return "Idle"
    }

    private func categoryNote(for count: Int) -> String {
        if count == 0 {
            return viewModel.scanState == .completed ? "No issues found" : "Waiting for scan"
        }
        let bytes = ByteCountFormatter.string(fromByteCount: Int64(count) * 250_000_000, countStyle: .file)
        return "\(count) found · \(bytes) est."
    }

    private func openReviewFlow() {
        guard !viewModel.photoGroups.isEmpty else {
            viewModel.startDeepClean()
            return
        }
        showReviewResults = true
    }

    private func presentCompletionIfNeeded() {
        guard isHomeTabSelected else { return }
        guard deletionManager.totalBytesFreed > 0 else { return }
        guard deletionManager.totalBytesFreed != lastPresentedFreedBytes else { return }
        completionFreedItems = max(deletionManager.totalItemsFreed - lastPresentedFreedItems, 0)
        completionFreedBytes = max(deletionManager.totalBytesFreed - lastPresentedFreedBytes, 0)
        lastPresentedFreedItems = deletionManager.totalItemsFreed
        lastPresentedFreedBytes = deletionManager.totalBytesFreed
        showCompletion = true
    }
}

private struct HomeCategoryTile<Destination: View>: View {
    let icon: String
    let color: Color
    let title: String
    let count: Int
    let status: String
    let note: String
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        DuckCard {
            Group {
                if count > 0 {
                    NavigationLink(destination: destination) {
                        tileContent
                    }
                } else {
                    tileContent
                }
            }
            .padding(14)
        }
    }

    private var tileContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(color)
                Spacer()
                StatusBadge(title: status, accent: color)
            }

            Text(title)
                .font(.duckBody)
                .foregroundStyle(Color.duckBerry)

            Text(count == 0 ? "0" : "\(count)")
                .font(.duckDisplay(24))
                .foregroundStyle(count > 0 ? color : Color.duckSoftPink)

            Text(note)
                .font(.duckCaption)
                .foregroundStyle(Color.duckRose)
        }
    }
}

private struct CompletionOverlay: View {
    @ObservedObject var viewModel: HomeViewModel
    let freedItems: Int
    let freedBytes: Int64
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Spacer(minLength: 20)

                PrimaryMetricCard(
                    title: "Cleanup complete",
                    value: "\(freedItems) photos removed",
                    detail: "\(ByteCountFormatter.string(fromByteCount: freedBytes, countStyle: .file)) reclaimed · \(viewModel.heroSecondaryText)",
                    accent: .duckPink,
                    progress: 1
                ) {
                    PhotoDuckAssetImage(
                        assetNames: ["photoduck_mascot", "photoduck_logo"],
                        fallback: { PhotoDuckMascotFallback(size: 64) }
                    )
                    .frame(width: 84, height: 84)
                }

                HStack(spacing: 10) {
                    StatPill(
                        title: "Removed",
                        value: "\(freedItems)",
                        accent: .duckPink,
                        icon: "trash.fill"
                    )
                    StatPill(
                        title: "Saved",
                        value: ByteCountFormatter.string(fromByteCount: freedBytes, countStyle: .file),
                        accent: .duckYellow,
                        icon: "sparkles"
                    )
                }

                DuckCard {
                    VStack(spacing: 12) {
                        DuckPrimaryButton(title: viewModel.photoGroups.isEmpty ? "Start Speed Clean" : "Continue Cleanup") {
                            if viewModel.photoGroups.isEmpty {
                                viewModel.startSpeedClean()
                            }
                            dismiss()
                        }
                        DuckOutlineButton(title: "Back to Library", color: .duckRose) {
                            dismiss()
                        }
                    }
                    .padding(16)
                }

                Spacer(minLength: 20)
            }
            .padding(.horizontal, 16)
        }
        .background(Color.photoduckBlushBackground.ignoresSafeArea())
    }
}
