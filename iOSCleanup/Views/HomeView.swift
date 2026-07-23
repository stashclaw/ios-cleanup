import SwiftUI

struct HomeView: View {
    @ObservedObject var viewModel: HomeViewModel
    @Binding var isHomeTabSelected: Bool
    @EnvironmentObject private var purchaseManager: PurchaseManager
    @EnvironmentObject private var deletionManager: DeletionManager

    @State private var showPaywall = false
    @State private var showCompletion = false
    @State private var showReviewResults = false
    @State private var openReviewAfterCompletion = false
    @State private var showICloudScanConfirmation = false
    @State private var showNotificationPrePrompt = false
    @State private var showNotificationSettingsAlert = false
    private var totalGroups: Int { viewModel.photoGroups.count }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    topBar
                    heroCard
                    if viewModel.photoAccessNeedsSettings || viewModel.hasLimitedPhotoAccess {
                        photoAccessBanner
                    }
                    if viewModel.contactScanState == .permissionRequired {
                        contactsAccessBanner
                    }
                    if let warning = viewModel.persistenceWarningMessage {
                        persistenceWarning(warning)
                    }
                    if viewModel.scanState == .completed, viewModel.unanalyzedPhotoCount > 0 {
                        iCloudAnalysisBanner
                    }
                    ctaButton
                    statsRow
                    categoryGrid
                    storageCard
                    if viewModel.scanState == .scanning || viewModel.scanState == .paused {
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
        .sheet(isPresented: $showCompletion, onDismiss: {
            if openReviewAfterCompletion {
                openReviewAfterCompletion = false
                showReviewResults = true
            }
        }) {
            CompletionOverlay(
                viewModel: viewModel,
                onReview: {
                    openReviewAfterCompletion = true
                    showCompletion = false
                }
            )
        }
        .sheet(isPresented: $showReviewResults) {
            NavigationStack {
                PhotoResultsView(groups: viewModel.photoGroups)
                    .environmentObject(purchaseManager)
                    .environmentObject(deletionManager)
            }
            .deletionUndoToast()
        }
        .confirmationDialog(
            "Analyze iCloud photos?",
            isPresented: $showICloudScanConfirmation,
            titleVisibility: .visible
        ) {
            Button("Download and Rescan") {
                viewModel.retryIncludingICloudPhotos()
            }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("PhotoDuck may download original photo data from iCloud. This can use network data and temporary device storage.")
        }
        .confirmationDialog(
            "Notify you when the scan is ready?",
            isPresented: $showNotificationPrePrompt,
            titleVisibility: .visible
        ) {
            Button("Allow Completion Alerts") {
                Task {
                    let enabled = await viewModel.requestCompletionNotifications()
                    showNotificationSettingsAlert = !enabled
                }
            }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("PhotoDuck sends only local scan-completion alerts. Your photos and scan results remain on this device.")
        }
        .alert("Notifications are off", isPresented: $showNotificationSettingsAlert) {
            Button("Open Settings") {
                viewModel.openPhotoAccessSettings()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enable notifications in Settings if you want PhotoDuck to alert you when a background scan is ready.")
        }
        .onChange(of: viewModel.scanState) { state in
            if state == .completed, isHomeTabSelected, viewModel.lastCompletedAt != nil {
                DuckHaptics.success()
                showCompletion = true
            }
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            PhotoDuckBrandLockup(iconSize: 32, wordmarkHeight: 25)
            Spacer()
            if !purchaseManager.isPurchased {
                Button { showPaywall = true } label: {
                    Label("Unlock", systemImage: "lock.fill")
                }
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
        PrimaryMetricCard(
            title: viewModel.heroStatusLabel,
            value: viewModel.heroPrimaryMetricValue,
            detail: viewModel.heroDetailText,
            accent: heroAccent,
            progress: heroProgress
        ) {
            PhotoDuckMascotArt(size: 72)
        }
    }

    private var heroAccent: Color {
        switch viewModel.heroState {
        case .deepCleanPaused:
            return .duckOrange
        case .permissionRequired, .scanFailure:
            return .duckRose
        default:
            return .duckPink
        }
    }

    private var heroProgress: Double? {
        switch viewModel.heroState {
        case .speedCleanActive, .deepCleanActive, .deepCleanPaused:
            return viewModel.progressFraction
        case .completedResultsAvailable:
            return 1
        default:
            return nil
        }
    }

    // MARK: - Primary CTA Button

    private var ctaTitle: String {
        switch viewModel.heroState {
        case .permissionRequired:
            return "Open Photos settings"
        case .speedCleanActive:
            return viewModel.hasPartialResults ? "Review quick wins" : "Speed Clean is scanning…"
        case .deepCleanActive:
            return "Scanning your library…"
        case .deepCleanPaused:
            return "Continue scanning"
        case .completedResultsAvailable, .reviewReadyPartialResults:
            return totalGroups > 0 ? "Review \(totalGroups) groups ready" : "All clean!"
        case .scanFailure, .idlePrompt:
            return "Start scan"
        }
    }

    private var ctaSubtitle: String {
        switch viewModel.heroState {
        case .speedCleanActive:
            return viewModel.scanProgressLabel
        case .deepCleanActive:
            return "Tap to pause"
        case .deepCleanPaused:
            return "\(viewModel.processedPhotoCount.formatted()) photos safely scanned so far"
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
                    PhotoDuckIconMark(size: 30)
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
        case .permissionRequired:
            viewModel.openPhotoAccessSettings()
        case .scanFailure, .idlePrompt:
            viewModel.startDeepClean()
        case .speedCleanActive:
            if viewModel.hasPartialResults {
                showReviewResults = true
            }
        case .deepCleanActive:
            viewModel.pauseDeepClean()
        case .deepCleanPaused:
            viewModel.resumeDeepClean()
        case .reviewReadyPartialResults, .completedResultsAvailable:
            if !viewModel.photoGroups.isEmpty {
                showReviewResults = true
            } else {
                viewModel.startSpeedClean()
            }
        }
    }

    private var photoAccessBanner: some View {
        DuckCard {
            HStack(spacing: 12) {
                Image(systemName: viewModel.hasLimitedPhotoAccess ? "photo.badge.plus" : "exclamationmark.triangle.fill")
                    .foregroundStyle(viewModel.hasLimitedPhotoAccess ? Color.duckOrange : Color.duckRose)

                VStack(alignment: .leading, spacing: 3) {
                    Text(viewModel.hasLimitedPhotoAccess ? "Limited Photos access" : "Photos access is off")
                        .font(.duckBody.weight(.semibold))
                        .foregroundStyle(Color.duckBerry)
                    Text(viewModel.hasLimitedPhotoAccess
                        ? "PhotoDuck can only scan the photos currently selected."
                        : "Open Settings to allow PhotoDuck to scan your library.")
                        .font(.duckCaption)
                        .foregroundStyle(Color.duckRose)
                }

                Spacer()

                Button(viewModel.hasLimitedPhotoAccess ? "Manage" : "Settings") {
                    if viewModel.hasLimitedPhotoAccess {
                        viewModel.manageLimitedPhotoSelection()
                    } else {
                        viewModel.openPhotoAccessSettings()
                    }
                }
                .font(.duckCaption.weight(.semibold))
                .foregroundStyle(Color.duckPink)
            }
            .padding(14)
        }
    }

    private var contactsAccessBanner: some View {
        DuckCard {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .foregroundStyle(Color.duckRose)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Contacts access is off")
                        .font(.duckBody.weight(.semibold))
                        .foregroundStyle(Color.duckBerry)
                    Text("Allow access in Settings to scan for duplicate contacts.")
                        .font(.duckCaption)
                        .foregroundStyle(Color.duckRose)
                }
                Spacer()
                Button("Settings") {
                    viewModel.openPhotoAccessSettings()
                }
                .font(.duckCaption.weight(.semibold))
                .foregroundStyle(Color.duckPink)
            }
            .padding(14)
        }
    }

    private func persistenceWarning(_ message: String) -> some View {
        DuckCard {
            HStack(spacing: 12) {
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .foregroundStyle(Color.duckWarning)
                Text(message)
                    .font(.duckCaption)
                    .foregroundStyle(Color.duckBerry)
                Spacer()
                Button("Dismiss") {
                    viewModel.dismissPersistenceWarning()
                }
                .font(.duckCaption.weight(.semibold))
                .foregroundStyle(Color.duckPink)
            }
            .padding(14)
        }
    }

    private var iCloudAnalysisBanner: some View {
        DuckCard {
            HStack(spacing: 12) {
                Image(systemName: "icloud.and.arrow.down")
                    .foregroundStyle(Color.duckPink)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(viewModel.unanalyzedPhotoCount.formatted()) photos not analyzed")
                        .font(.duckBody.weight(.semibold))
                        .foregroundStyle(Color.duckBerry)
                    Text("They appear to be stored in iCloud. Your current results may be incomplete.")
                        .font(.duckCaption)
                        .foregroundStyle(Color.duckRose)
                }
                Spacer()
                Button("Rescan") {
                    showICloudScanConfirmation = true
                }
                .font(.duckCaption.weight(.semibold))
                .foregroundStyle(Color.duckPink)
            }
            .padding(14)
        }
    }

    // MARK: - Stats Row

    private var statsRow: some View {
        let photosScanned: String = {
            guard viewModel.scanState != .idle else { return "0" }
            return viewModel.processedPhotoCount.formatted()
        }()
        return HStack(spacing: 8) {
            StatMiniCard(value: photosScanned, label: "Photos scanned")
            StatMiniCard(value: viewModel.photoGroups.count.formatted(), label: "Groups found")
            StatMiniCard(
                value: viewModel.reviewablePhotosCount.formatted(),
                label: "Reviewable"
            )
            StatMiniCard(value: viewModel.reclaimableFormatted, label: "Reclaimable")
        }
    }

    // MARK: - Category Grid

    private var categoryGrid: some View {
        let duplicateGroups = viewModel.photoGroups.filter { $0.reason != .visuallySimilar }
        let visuallySimilarGroups = viewModel.photoGroups.filter { $0.reason == .visuallySimilar }
        let largeFileBytes = viewModel.largeFiles.reduce(Int64(0)) { $0 + $1.byteSize }

        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            HomeCategoryTile(
                icon: "photo.on.rectangle.angled",
                color: .duckPink,
                title: "Duplicates",
                count: duplicateGroups.count,
                status: categoryStatus(for: duplicateGroups.count),
                note: categoryNote(for: duplicateGroups),
                destination: {
                    PhotoResultsView(groups: duplicateGroups)
                        .environmentObject(purchaseManager)
                        .environmentObject(deletionManager)
                }
            )

            HomeCategoryTile(
                icon: "rectangle.stack.fill",
                color: .duckOrange,
                title: "Similar",
                count: visuallySimilarGroups.count,
                status: categoryStatus(for: visuallySimilarGroups.count),
                note: categoryNote(for: visuallySimilarGroups),
                destination: {
                    PhotoResultsView(groups: visuallySimilarGroups)
                        .environmentObject(purchaseManager)
                        .environmentObject(deletionManager)
                }
            )

            HomeCategoryTile(
                icon: "person.2.fill",
                color: .duckRose,
                title: "Contacts",
                count: viewModel.contactMatches.count,
                status: supportingScanStatus(viewModel.contactScanState),
                note: viewModel.contactMatches.isEmpty ? "0 found" : "\(viewModel.contactMatches.count) contacts",
                destination: {
                    ContactResultsView(
                        matches: viewModel.contactMatches,
                        onRefresh: { await viewModel.scanContacts(force: true) }
                    )
                        .environmentObject(purchaseManager)
                }
            )

            HomeCategoryTile(
                icon: "video.fill",
                color: .duckOrange,
                title: "Large Videos",
                count: viewModel.largeFiles.count,
                status: supportingScanStatus(viewModel.fileScanState),
                note: viewModel.largeFiles.isEmpty ? "0 found" : "\(viewModel.largeFiles.count) items",
                sizeBadge: (viewModel.fileScanState == .completed && !viewModel.largeFiles.isEmpty)
                    ? ByteCountFormatter.string(fromByteCount: largeFileBytes, countStyle: .file) : nil,
                destination: {
                    FileResultsView(
                        files: viewModel.largeFiles,
                        onRefresh: { await viewModel.scanFiles(force: true) }
                    )
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
                            .frame(width: geo.size.width * used)
                        Color.gray.opacity(0.15)
                            .frame(maxWidth: .infinity)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .frame(height: 10)
                HStack(spacing: 12) {
                    legendItem(color: .duckPink, label: viewModel.storageUsedFormatted)
                    legendItem(color: .gray.opacity(0.3), label: viewModel.storageFreeFormatted)
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
                .font(.duckMicro)
                .foregroundStyle(Color.duckRose)
        }
    }

    // MARK: - Scan Footer Card

    private var scanFooterCard: some View {
        DuckCard {
            VStack(spacing: 12) {
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
                        Text(viewModel.scanState == .paused ? "Scan paused" : "Scan in progress")
                            .font(.duckBody)
                            .fontWeight(.medium)
                            .foregroundStyle(Color.duckBerry)
                        Text("\(viewModel.scanProgressLabel) · \(viewModel.progressPercentLabel)")
                            .font(.duckCaption)
                            .foregroundStyle(Color.duckRose)
                            .lineLimit(2)
                    }
                    Spacer()
                    Button(viewModel.scanState == .paused ? "Continue" : "Pause") {
                        if viewModel.scanState == .paused {
                            viewModel.resumeDeepClean()
                        } else {
                            viewModel.pauseDeepClean()
                        }
                    }
                    .font(.duckCaption)
                    .foregroundStyle(Color.duckPink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .overlay(Capsule().stroke(Color.duckPink, lineWidth: 1))
                }

                Button {
                    if !viewModel.notificationEligible {
                        showNotificationPrePrompt = true
                    }
                } label: {
                    Label(
                        viewModel.notificationEligible
                            ? "Completion alert enabled"
                            : "Notify me when this scan is ready",
                        systemImage: viewModel.notificationEligible ? "bell.fill" : "bell"
                    )
                    .font(.duckCaption.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .foregroundStyle(viewModel.notificationEligible ? Color.duckSuccess : Color.duckRose)
                .background(Color.duckCream, in: Capsule())
                .disabled(viewModel.notificationEligible)
            }
            .padding(16)
        }
    }

    // MARK: - Helpers

    private func categoryStatus(for count: Int) -> String {
        if viewModel.scanState == .scanning {
            return count > 0 ? "Partial" : "Scanning"
        }
        if viewModel.scanState == .paused {
            return count > 0 ? "Partial" : "Paused"
        }
        if count > 0 {
            return "Ready"
        }
        if viewModel.scanState == .completed {
            return "0 found"
        }
        return "Idle"
    }

    private func supportingScanStatus(_ state: HomeViewModel.ScanState) -> String {
        switch state {
        case .idle:
            return "Not scanned"
        case .scanning:
            return "Scanning"
        case .paused:
            return "Paused"
        case .completed:
            return "Ready"
        case .failed:
            return "Try again"
        case .permissionRequired:
            return "Access needed"
        }
    }

    private func categoryNote(for groups: [PhotoGroup]) -> String {
        if groups.isEmpty {
            if viewModel.scanState == .paused {
                return "\(viewModel.processedPhotoCount.formatted()) photos checked"
            }
            return viewModel.scanState == .completed ? "No issues found" : "Waiting for scan"
        }
        let bytes = groups.reduce(Int64(0)) { $0 + $1.reclaimableBytes }
        if bytes > 0 {
            return "\(groups.count) groups · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
        }
        return "\(groups.count) review-only groups"
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
                    .font(.duckBody(17, weight: .semibold, relativeTo: .headline))
                    .foregroundStyle(Color.duckBerry)
                Text(label)
                    .font(.duckMicro)
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
                    .font(.duckMicro)
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
    let onReview: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Spacer(minLength: 20)

                PrimaryMetricCard(
                    title: "Scan complete",
                    value: "\(viewModel.lastCompletedGroupsCount) groups ready",
                    detail: "\(viewModel.lastCompletedReviewableCount) photos to review · \(ByteCountFormatter.string(fromByteCount: viewModel.lastCompletedReclaimableBytes, countStyle: .file)) potentially reclaimable",
                    accent: .duckPink,
                    progress: 1
                ) {
                    PhotoDuckMascotArt(size: 84)
                }

                HStack(spacing: 10) {
                    StatPill(
                        title: "Reviewable",
                        value: "\(viewModel.lastCompletedReviewableCount)",
                        accent: .duckPink,
                        icon: "photo.stack"
                    )
                    StatPill(
                        title: "Potential",
                        value: ByteCountFormatter.string(fromByteCount: viewModel.lastCompletedReclaimableBytes, countStyle: .file),
                        accent: .duckYellow,
                        icon: "sparkles"
                    )
                }

                DuckCard {
                    VStack(spacing: 12) {
                        DuckPrimaryButton(title: viewModel.photoGroups.isEmpty ? "Scan Again" : "Review Now") {
                            if viewModel.photoGroups.isEmpty {
                                viewModel.startSpeedClean()
                                dismiss()
                            } else {
                                onReview()
                            }
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
