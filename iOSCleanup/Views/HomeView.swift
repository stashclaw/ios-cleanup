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
    @State private var isPulsing = false

    private var totalGroups: Int { viewModel.photoGroups.count }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    topBar
                    heroCard
                    ctaButton
                    statsRow
                    categoryGrid
                    storageCard
                    if viewModel.isAnyScanning {
                        scanFooterCard
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .background(Color.photoduckBlushBackground.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
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
        .onChange(of: viewModel.isAllDone) { _ in
            presentCompletionIfNeeded()
        }
        .onAppear {
            presentCompletionIfNeeded()
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            HStack(spacing: 8) {
                Image("photoduck_icon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                Text("PhotoDuck")
                    .font(.duckDisplay(17))
                    .foregroundStyle(Color.duckBerry)
            }
            Spacer()
            if !purchaseManager.isPurchased {
                Button("Unlock 🔒") { showPaywall = true }
                    .font(.duckCaption)
                    .foregroundStyle(Color.duckPink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.duckCream, in: Capsule())
            }
        }
    }

    // MARK: - Hero Card

    private var heroCard: some View {
        DuckCard {
            VStack(spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Reclaimable space")
                            .font(.duckCaption)
                            .foregroundStyle(Color.duckRose)
                        Text(viewModel.reclaimableFormatted)
                            .font(.system(size: 32, weight: .bold))
                            .foregroundStyle(Color.duckBerry)
                    }
                    Spacer()
                    statusPill
                }
                DuckProgressBar(progress: viewModel.storageUsedFraction, color: .duckPink)
                    .frame(height: 8)
                HStack {
                    Text("\(Int((viewModel.storageUsedFraction * 100).rounded()))% analyzed")
                        .font(.duckCaption)
                        .foregroundStyle(Color.duckRose)
                    Spacer()
                    Text("\(viewModel.storageUsedFormatted) / \(viewModel.storageTotalFormatted)")
                        .font(.duckCaption)
                        .foregroundStyle(Color.duckRose)
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        if viewModel.isAnyScanning {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.duckYellow)
                    .frame(width: 8, height: 8)
                    .scaleEffect(isPulsing ? 1.3 : 1.0)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPulsing)
                    .onAppear { isPulsing = true }
                    .onDisappear { isPulsing = false }
                Text("Scanning")
                    .font(.duckCaption)
                    .foregroundStyle(Color.duckBerry)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.duckSoftPink, in: Capsule())
        } else if viewModel.isAllDone {
            Text("Done ✓")
                .font(.duckCaption)
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.green, in: Capsule())
        } else {
            Text("Ready")
                .font(.duckCaption)
                .foregroundStyle(Color.duckRose)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.gray.opacity(0.15), in: Capsule())
        }
    }

    // MARK: - Primary CTA Button

    private var ctaTitle: String {
        switch viewModel.heroState {
        case .speedCleanActive, .deepCleanActive:
            return "Scanning your library…"
        case .completedResultsAvailable, .reviewReadyPartialResults:
            return totalGroups > 0 ? "Review \(totalGroups) groups ready" : "All clean!"
        default:
            return "Start scan"
        }
    }

    private var ctaSubtitle: String {
        switch viewModel.heroState {
        case .speedCleanActive, .deepCleanActive:
            return "Tap to pause"
        case .completedResultsAvailable, .reviewReadyPartialResults:
            return totalGroups > 0 ? "Tap to start cleaning now" : "Nothing to review right now"
        default:
            return "Find duplicates & free up space"
        }
    }

    private var ctaButton: some View {
        Button(action: handleCTAAction) {
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(0.25))
                        .frame(width: 40, height: 40)
                    Image("photoduck_icon")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 24, height: 24)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(ctaTitle)
                        .font(.duckBody)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                    Text(ctaSubtitle)
                        .font(.duckCaption)
                        .foregroundStyle(.white.opacity(0.8))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.white.opacity(0.9))
            }
            .padding(16)
            .background(Color.duckPink, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func handleCTAAction() {
        switch viewModel.heroState {
        case .permissionRequired, .scanFailure, .idlePrompt, .deepCleanPaused:
            viewModel.startDeepClean()
        case .speedCleanActive, .deepCleanActive:
            viewModel.pauseDeepClean()
        case .reviewReadyPartialResults, .completedResultsAvailable:
            if !viewModel.photoGroups.isEmpty {
                showReviewResults = true
            } else {
                viewModel.startSpeedClean()
            }
        }
    }

    // MARK: - Stats Row

    private var statsRow: some View {
        let photosScanned: String = {
            guard viewModel.scanState != .idle else { return "0" }
            return viewModel.photoGroups.flatMap(\.assets).count.formatted()
        }()
        return HStack(spacing: 8) {
            StatMiniCard(value: photosScanned, label: "Photos scanned")
            StatMiniCard(value: viewModel.photoGroups.count.formatted(), label: "Groups found")
            StatMiniCard(
                value: viewModel.photoGroups.filter { $0.assets.count > 1 }.count.formatted(),
                label: "Reviewable"
            )
            StatMiniCard(value: viewModel.reclaimableFormatted, label: "Reclaimable")
        }
    }

    // MARK: - Category Grid

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
                sizeBadge: (viewModel.fileScanState == .completed && !viewModel.largeFiles.isEmpty)
                    ? viewModel.reclaimableFormatted : nil,
                destination: {
                    FileResultsView(files: viewModel.largeFiles)
                        .environmentObject(purchaseManager)
                }
            )
        }
    }

    // MARK: - Storage Card

    private var storageCard: some View {
        DuckCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("iPhone storage")
                        .font(.duckHeading)
                        .foregroundStyle(Color.duckBerry)
                    Spacer()
                    Text(viewModel.storageFreeFormatted)
                        .font(.duckCaption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.duckPink, in: Capsule())
                }
                GeometryReader { geo in
                    let used = viewModel.storageUsedFraction
                    HStack(spacing: 2) {
                        Color.duckPink
                            .frame(width: geo.size.width * used * 0.40)
                        Color.red.opacity(0.7)
                            .frame(width: geo.size.width * used * 0.25)
                        Color.blue.opacity(0.6)
                            .frame(width: geo.size.width * used * 0.20)
                        Color.green.opacity(0.6)
                            .frame(width: geo.size.width * used * 0.15)
                        Color.gray.opacity(0.15)
                            .frame(maxWidth: .infinity)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .frame(height: 10)
                HStack(spacing: 12) {
                    legendItem(color: .duckPink, label: "Photos")
                    legendItem(color: .red.opacity(0.7), label: "Videos")
                    legendItem(color: .blue.opacity(0.6), label: "Apps")
                    legendItem(color: .green.opacity(0.6), label: "Other")
                }
            }
            .padding(16)
        }
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Color.duckRose)
        }
    }

    // MARK: - Scan Footer Card

    private var scanFooterCard: some View {
        DuckCard {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .stroke(Color.duckSoftPink, lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: viewModel.progressFraction)
                        .stroke(Color.duckYellow, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scan in progress")
                        .font(.duckBody)
                        .fontWeight(.medium)
                        .foregroundStyle(Color.duckBerry)
                    Text("Est. completing soon")
                        .font(.duckCaption)
                        .foregroundStyle(Color.duckRose)
                }
                Spacer()
                Button("Pause") {
                    viewModel.pauseDeepClean()
                }
                .font(.duckCaption)
                .foregroundStyle(Color.duckPink)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .overlay(Capsule().stroke(Color.duckPink, lineWidth: 1))
            }
            .padding(16)
        }
    }

    // MARK: - Helpers

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

// MARK: - StatMiniCard

private struct StatMiniCard: View {
    let value: String
    let label: String
    var body: some View {
        DuckCard {
            VStack(spacing: 4) {
                Text(value)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.duckBerry)
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.duckRose)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .padding(10)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - HomeCategoryTile

private struct HomeCategoryTile<Destination: View>: View {
    let icon: String
    let color: Color
    let title: String
    let count: Int
    let status: String
    let note: String
    var sizeBadge: String? = nil
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
                ZStack {
                    Circle()
                        .fill(color.opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: icon)
                        .font(.body)
                        .foregroundStyle(color)
                }
                Spacer()
                StatusBadge(title: status, accent: color)
            }

            Text(title)
                .font(.duckBody)
                .foregroundStyle(Color.duckBerry)

            Text(count == 0 ? "0" : "\(count)")
                .font(.duckDisplay(24))
                .foregroundStyle(count > 0 ? color : Color.duckSoftPink)

            if let badge = sizeBadge {
                Text(badge)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.duckBerry)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.duckSoftPink, in: Capsule())
            } else {
                Text(note)
                    .font(.duckCaption)
                    .foregroundStyle(Color.duckRose)
            }
        }
    }
}

// MARK: - CompletionOverlay

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
