import SwiftUI
import Photos
import UIKit
import UniformTypeIdentifiers

struct HomeView: View {
    @ObservedObject var viewModel: HomeViewModel
    @Binding var isHomeTabSelected: Bool
    @EnvironmentObject private var purchaseManager: PurchaseManager
    @EnvironmentObject private var deletionManager: DeletionManager
    @EnvironmentObject private var exportAlbum: ExportAlbumStore

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
                    if viewModel.scanState == .failed {
                        scanFailureBanner
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
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
            .background(Color.backgroundBlush.ignoresSafeArea())
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
                    .font(.duckCaption.weight(.semibold))
                    .foregroundStyle(Color.accentPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.surface, in: Capsule())
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
            return .warning
        case .permissionRequired:
            return .warning
        case .scanFailure:
            return .danger
        default:
            return .accentPrimary
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
            .background(LinearGradient.duckPrimaryCTA, in: RoundedRectangle(cornerRadius: DuckRadius.m, style: .continuous))
            .duckPrimaryGlow()
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
                    .foregroundStyle(viewModel.hasLimitedPhotoAccess ? Color.warning : Color.danger)

                VStack(alignment: .leading, spacing: 3) {
                    Text(viewModel.hasLimitedPhotoAccess ? "Limited Photos access" : "Photos access is off")
                        .font(.duckBody.weight(.semibold))
                        .foregroundStyle(Color.textPrimary)
                    Text(viewModel.hasLimitedPhotoAccess
                        ? "PhotoDuck can only scan the photos currently selected."
                        : "Open Settings to allow PhotoDuck to scan your library.")
                        .font(.duckCaption)
                        .foregroundStyle(Color.textSecondary)
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
                .foregroundStyle(Color.accentPrimary)
            }
            .padding(14)
        }
    }

    private var contactsAccessBanner: some View {
        DuckCard {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .foregroundStyle(Color.textSecondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Contacts access is off")
                        .font(.duckBody.weight(.semibold))
                        .foregroundStyle(Color.textPrimary)
                    Text("Allow access in Settings to scan for duplicate contacts.")
                        .font(.duckCaption)
                        .foregroundStyle(Color.textSecondary)
                }
                Spacer()
                Button("Settings") {
                    viewModel.openPhotoAccessSettings()
                }
                .font(.duckCaption.weight(.semibold))
                .foregroundStyle(Color.accentPrimary)
            }
            .padding(14)
        }
    }

    private func persistenceWarning(_ message: String) -> some View {
        DuckCard {
            HStack(spacing: 12) {
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .foregroundStyle(Color.warning)
                Text(message)
                    .font(.duckCaption)
                    .foregroundStyle(Color.textPrimary)
                Spacer()
                Button("Dismiss") {
                    viewModel.dismissPersistenceWarning()
                }
                .font(.duckCaption.weight(.semibold))
                .foregroundStyle(Color.accentPrimary)
            }
            .padding(14)
        }
    }

    private var iCloudAnalysisBanner: some View {
        DuckCard {
            HStack(spacing: 12) {
                Image(systemName: "icloud.and.arrow.down")
                    .foregroundStyle(Color.accentPrimary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(viewModel.unanalyzedPhotoCount.formatted()) photos not analyzed")
                        .font(.duckBody.weight(.semibold))
                        .foregroundStyle(Color.textPrimary)
                    Text("They appear to be stored in iCloud. Your current results may be incomplete.")
                        .font(.duckCaption)
                        .foregroundStyle(Color.textSecondary)
                }
                Spacer()
                Button("Rescan") {
                    showICloudScanConfirmation = true
                }
                .font(.duckCaption.weight(.semibold))
                .foregroundStyle(Color.accentPrimary)
            }
            .padding(14)
        }
    }

    private var scanFailureBanner: some View {
        DuckCard {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundStyle(Color.danger)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Scan didn't finish")
                        .font(.duckBody.weight(.semibold))
                        .foregroundStyle(Color.textPrimary)
                    Text(viewModel.scanErrorMessage ?? "Something interrupted the last scan. Try again.")
                        .font(.duckCaption)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(3)
                }
                Spacer()
                Button("Retry") {
                    viewModel.startDeepClean()
                }
                .font(.duckCaption.weight(.semibold))
                .foregroundStyle(Color.accentPrimary)
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
        return LazyVGrid(
            columns: [GridItem(.flexible()), GridItem(.flexible())],
            spacing: 8
        ) {
            StatMiniCard(value: photosScanned, label: "Photos scanned")
            StatMiniCard(value: viewModel.photoGroups.count.formatted(), label: "Groups found")
            StatMiniCard(
                value: viewModel.reviewablePhotosCount.formatted(),
                label: "Reviewable"
            )
            StatMiniCard(value: viewModel.reclaimableFormatted, label: "Reclaimable")
            StatMiniCard(
                value: ByteCountFormatter.string(
                    fromByteCount: deletionManager.lifetimeBytesFreed,
                    countStyle: .file
                ),
                label: "Freed with PhotoDuck"
            )
            StatMiniCard(
                value: deletionManager.lifetimeItemsFreed.formatted(),
                label: "Items cleaned"
            )
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
                color: .accentPrimary,
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
                color: .warning,
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
                icon: "rectangle.on.rectangle",
                color: .accentDeep,
                title: "Screenshots",
                count: viewModel.screenshotAssets.count,
                status: categoryStatus(for: viewModel.screenshotAssets.count),
                note: viewModel.screenshotAssets.isEmpty
                    ? "0 found"
                    : "\(viewModel.screenshotAssets.count) ready to review",
                destination: {
                    PhotoCategoryReviewView(
                        title: "Screenshots",
                        subtitle: "Screenshots stay separate from camera photos.",
                        assets: viewModel.screenshotAssets
                    )
                    .environmentObject(purchaseManager)
                    .environmentObject(deletionManager)
                }
            )

            HomeCategoryTile(
                icon: "camera.macro",
                color: .warning,
                title: "Blurry",
                count: viewModel.blurryAssets.count,
                status: categoryStatus(for: viewModel.blurryAssets.count),
                note: viewModel.blurryAssets.isEmpty
                    ? "0 found"
                    : "\(viewModel.blurryAssets.count) review only",
                destination: {
                    PhotoCategoryReviewView(
                        title: "Blurry Photos",
                        subtitle: "Conservative suggestions. Nothing is selected automatically.",
                        assets: viewModel.blurryAssets
                    )
                    .environmentObject(purchaseManager)
                    .environmentObject(deletionManager)
                }
            )

            HomeCategoryTile(
                icon: "externaldrive.fill.badge.checkmark",
                color: .accentPrimary,
                title: "Export Album",
                count: exportAlbum.count,
                status: exportAlbum.count > 0 ? "Ready" : "Empty",
                note: exportAlbum.count > 0
                    ? "\(exportAlbum.count) queued"
                    : "Add photos from review",
                navigatesWhenEmpty: true,
                destination: {
                    ExportAlbumView()
                }
            )

            HomeCategoryTile(
                icon: "person.2.fill",
                color: .textSecondary,
                title: "Contacts",
                count: viewModel.contactMatches.count,
                status: supportingScanStatus(viewModel.contactScanState),
                note: viewModel.contactMatches.isEmpty
                    ? (viewModel.contactScanState == .idle ? "Waiting for scan" : "0 found")
                    : "\(viewModel.contactMatches.count) contacts",
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
                color: .warning,
                title: "Large Videos",
                count: viewModel.largeFiles.count,
                status: supportingScanStatus(viewModel.fileScanState),
                note: viewModel.largeFiles.isEmpty
                    ? (viewModel.fileScanState == .idle ? "Waiting for scan" : "0 found")
                    : "\(viewModel.largeFiles.count) items",
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

    // One honest Used bar from the real filesystem fraction. After a completed
    // scan, an accent segment inside "used" shows what PhotoDuck can free,
    // computed from PHAsset estimated file sizes — never a flat per-group guess.
    private var foundFraction: Double {
        guard viewModel.scanState == .completed, viewModel.storageTotalBytesValue > 0 else { return 0 }
        let fraction = Double(viewModel.reclaimableBytes) / Double(viewModel.storageTotalBytesValue)
        return min(max(fraction, 0), viewModel.storageUsedFraction)
    }

    private var storageCard: some View {
        DuckCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("iPhone storage")
                        .font(.duckHeading)
                        .foregroundStyle(Color.textPrimary)
                    Spacer()
                    Text(viewModel.storageFreeFormatted)
                        .font(.duckCaption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.accentPrimary, in: Capsule())
                }
                GeometryReader { geo in
                    let used = viewModel.storageUsedFraction
                    let found = foundFraction
                    HStack(spacing: 2) {
                        Color.decorPink
                            .frame(width: geo.size.width * max(used - found, 0))
                        if found > 0 {
                            Color.accentPrimary
                                .frame(width: max(geo.size.width * found, 2))
                        }
                        Color.gray.opacity(0.15)
                            .frame(maxWidth: .infinity)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .frame(height: 10)
                HStack(spacing: 12) {
                    legendItem(color: .decorPink, label: viewModel.storageUsedFormatted)
                    if foundFraction > 0 {
                        legendItem(color: .accent, label: "Found by PhotoDuck: \(viewModel.reclaimableFormatted)")
                    }
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
                .foregroundStyle(Color.textSecondary)
        }
    }

    // MARK: - Scan Footer Card

    private var scanFooterCard: some View {
        DuckCard {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .stroke(Color.decorPink, lineWidth: 3)
                        Circle()
                            .trim(from: 0, to: viewModel.progressFraction)
                            .stroke(Color.mascotYellow, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(viewModel.scanState == .paused ? "Scan paused" : "Scan in progress")
                            .font(.duckBody)
                            .fontWeight(.medium)
                            .foregroundStyle(Color.textPrimary)
                        Text("\(viewModel.scanProgressLabel) · \(viewModel.progressPercentLabel)")
                            .font(.duckCaption)
                            .foregroundStyle(Color.textSecondary)
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
                    .foregroundStyle(Color.accentPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .overlay(Capsule().stroke(Color.accentPrimary, lineWidth: 1))
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
                .foregroundStyle(viewModel.notificationEligible ? Color.success : Color.textSecondary)
                .background(Color.surface, in: Capsule())
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
                    .font(.duckStat)
                    .foregroundStyle(Color.textPrimary)
                Text(label)
                    .font(.duckMicro)
                    .foregroundStyle(Color.textSecondary)
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
    var navigatesWhenEmpty = false
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        DuckCard {
            Group {
                if count > 0 || navigatesWhenEmpty {
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
                StatusBadge(title: status, accent: count > 0 ? color : .textSecondary)
            }

            Text(title)
                .font(.duckBody)
                .foregroundStyle(Color.textPrimary)

            Text(count == 0 ? "0" : "\(count)")
                .font(.duckDisplay(24))
                .foregroundStyle(count > 0 ? color : Color.textSecondary.opacity(0.55))

            if let badge = sizeBadge {
                Text(badge)
                    .font(.duckMicro)
                    .foregroundStyle(Color.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.decorPink, in: Capsule())
            } else {
                Text(note)
                    .font(.duckCaption)
                    .foregroundStyle(Color.textSecondary)
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
                    value: viewModel.lastCompletedGroupsCount > 0
                        ? "\(viewModel.lastCompletedGroupsCount) groups ready"
                        : "\(viewModel.photoReviewCategoryCount) photos to review",
                    detail: "\(viewModel.lastCompletedReviewableCount) photos to review · \(ByteCountFormatter.string(fromByteCount: viewModel.lastCompletedReclaimableBytes, countStyle: .file)) potentially reclaimable",
                    accent: .accentPrimary,
                    progress: 1
                ) {
                    PhotoDuckMascotArt(size: 84)
                }

                HStack(spacing: 10) {
                    StatPill(
                        title: "Reviewable",
                        value: "\(viewModel.lastCompletedReviewableCount)",
                        accent: .accentPrimary,
                        icon: "photo.stack"
                    )
                    StatPill(
                        title: "Potential",
                        value: ByteCountFormatter.string(fromByteCount: viewModel.lastCompletedReclaimableBytes, countStyle: .file),
                        accent: .mascotYellow,
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
                        DuckOutlineButton(title: "Back to Library", color: .textSecondary) {
                            dismiss()
                        }
                    }
                    .padding(16)
                }

                Spacer(minLength: 20)
            }
            .padding(.horizontal, 16)
        }
        .background(Color.backgroundBlush.ignoresSafeArea())
    }
}

private struct PhotoCategoryReviewView: View {
    let title: String
    let subtitle: String
    let assets: [PHAsset]

    @EnvironmentObject private var purchaseManager: PurchaseManager
    @EnvironmentObject private var deletionManager: DeletionManager
    @EnvironmentObject private var exportAlbum: ExportAlbumStore
    @State private var selectedAssetIDs: Set<String> = []
    @State private var showPaywall = false
    @State private var deletionError: String?
    @State private var exportChipMessage: String?

    private let columns = [
        GridItem(.flexible(), spacing: 4),
        GridItem(.flexible(), spacing: 4),
        GridItem(.flexible(), spacing: 4)
    ]

    private var selectedAssets: [PHAsset] {
        assets.filter { selectedAssetIDs.contains($0.localIdentifier) }
    }

    private var selectedBytes: Int64 {
        selectedAssets.reduce(into: Int64(0)) { $0 += $1.estimatedFileSize }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                DuckCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(subtitle)
                            .font(.duckBody)
                            .foregroundStyle(Color.textPrimary)
                        Text("Select photos explicitly before deleting. Items remain in Recently Deleted for up to 30 days.")
                            .font(.duckCaption)
                            .foregroundStyle(Color.textSecondary)

                        Button {
                            let explicitSelection = selectedAssets
                            exportAlbum.add(explicitSelection)
                            exportChipMessage = "\(explicitSelection.count) added to Export Album"
                        } label: {
                            Label(
                                selectedAssetIDs.isEmpty
                                    ? "Add to Export"
                                    : "Add \(selectedAssetIDs.count) to Export",
                                systemImage: "plus"
                            )
                            .font(.duckCaption.weight(.semibold))
                            .foregroundStyle(Color.accentPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                Color.accentPrimary.opacity(0.1),
                                in: Capsule()
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(selectedAssetIDs.isEmpty)
                        .opacity(selectedAssetIDs.isEmpty ? 0.5 : 1)
                        .accessibilityHint("Adds the selected photos to the Export Album without deleting them")

                        if let exportChipMessage {
                            Text(exportChipMessage)
                                .font(.duckCaption.weight(.semibold))
                                .foregroundStyle(Color.success)
                        }
                    }
                    .padding(14)
                }

                if assets.isEmpty {
                    EmptyStateView(
                        title: "Nothing to review",
                        icon: "checkmark.circle",
                        message: "Run a fresh photo scan after adding new photos."
                    )
                } else {
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(assets, id: \.localIdentifier) { asset in
                            Button {
                                toggleSelection(for: asset)
                            } label: {
                                CategoryPhotoThumbnail(
                                    asset: asset,
                                    isSelected: selectedAssetIDs.contains(asset.localIdentifier)
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(
                                selectedAssetIDs.contains(asset.localIdentifier)
                                    ? "Selected photo"
                                    : "Unselected photo"
                            )
                        }
                    }
                }
            }
            .padding(16)
            .padding(.bottom, 96)
        }
        .background(Color.backgroundBlush.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if !assets.isEmpty {
                categoryActionBar
            }
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView().environmentObject(purchaseManager)
        }
        .alert(
            "Couldn’t Delete Photos",
            isPresented: Binding(
                get: { deletionError != nil },
                set: { if !$0 { deletionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { deletionError = nil }
        } message: {
            Text(deletionError ?? "")
        }
    }

    private var categoryActionBar: some View {
        VStack(spacing: 6) {
            Button {
                if selectedAssetIDs.count > 1, !purchaseManager.isPurchased {
                    showPaywall = true
                } else {
                    Task { await deleteSelectedAssets() }
                }
            } label: {
                Text(actionTitle)
                    .font(.duckButton)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(
                        selectedAssetIDs.isEmpty ? Color.textSecondary : Color.danger,
                        in: RoundedRectangle(cornerRadius: DuckRadius.m, style: .continuous)
                    )
            }
            .disabled(selectedAssetIDs.isEmpty || deletionManager.hasPendingDeletion)

            if !selectedAssetIDs.isEmpty {
                Text("\(selectedAssetIDs.count) selected · \(ByteCountFormatter.string(fromByteCount: selectedBytes, countStyle: .file))")
                    .font(.duckCaption)
                    .foregroundStyle(Color.textSecondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var actionTitle: String {
        guard !selectedAssetIDs.isEmpty else { return "Select Photos" }
        if selectedAssetIDs.count > 1, !purchaseManager.isPurchased {
            return "Delete Selected · Pro"
        }
        return selectedAssetIDs.count == 1 ? "Delete 1 Photo" : "Delete Selected"
    }

    private func toggleSelection(for asset: PHAsset) {
        let id = asset.localIdentifier
        if selectedAssetIDs.contains(id) {
            selectedAssetIDs.remove(id)
        } else {
            selectedAssetIDs.insert(id)
        }
    }

    @MainActor
    private func deleteSelectedAssets() async {
        let explicitSelection = selectedAssets
        guard !explicitSelection.isEmpty else { return }
        do {
            try await deletionManager.delete(assets: explicitSelection)
            selectedAssetIDs.removeAll()
        } catch {
            deletionError = error.localizedDescription
        }
    }
}

private struct ExportAlbumView: View {
    @EnvironmentObject private var exportAlbum: ExportAlbumStore
    @EnvironmentObject private var deletionManager: DeletionManager

    @State private var showExternalFolderPicker = false
    @State private var showPostExportActions = false
    @State private var isExporting = false
    @State private var exportResult: ExternalPhotoExportResult?
    @State private var exportedAssetIDs: Set<String> = []
    @State private var exportStatus: String?
    @State private var errorMessage: String?

    private let columns = [
        GridItem(.flexible(), spacing: 4),
        GridItem(.flexible(), spacing: 4),
        GridItem(.flexible(), spacing: 4)
    ]

    private var unavailableAssetIDs: Set<String> {
        Set(exportAlbum.assetIDs).subtracting(
            exportAlbum.assets.map(\.localIdentifier)
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                DuckCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(
                            "One album, one export",
                            systemImage: "externaldrive.fill.badge.checkmark"
                        )
                        .font(.duckBody.weight(.semibold))
                        .foregroundStyle(Color.textPrimary)

                        Text("Add photos while reviewing, then choose an SSD or another folder in Files. PhotoDuck copies and verifies every resource before offering to delete originals.")
                            .font(.duckCaption)
                            .foregroundStyle(Color.textSecondary)

                        if let exportStatus {
                            Text(exportStatus)
                                .font(.duckCaption.weight(.semibold))
                                .foregroundStyle(Color.success)
                        }
                    }
                    .padding(14)
                }

                if !unavailableAssetIDs.isEmpty {
                    DuckCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(unavailableAssetIDs.count) queued item(s) are no longer available with the current Photos access.")
                                .font(.duckCaption)
                                .foregroundStyle(Color.warning)

                            Button("Remove Unavailable") {
                                exportAlbum.remove(assetIDs: unavailableAssetIDs)
                            }
                            .font(.duckCaption.weight(.semibold))
                            .foregroundStyle(Color.accentPrimary)
                        }
                        .padding(14)
                    }
                }

                if exportAlbum.assets.isEmpty {
                    EmptyStateView(
                        title: "Export Album is empty",
                        icon: "externaldrive.badge.plus",
                        message: "Select photos in a review screen and tap Add to Export."
                    )
                } else {
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(exportAlbum.assets, id: \.localIdentifier) { asset in
                            ZStack(alignment: .topTrailing) {
                                CategoryPhotoThumbnail(
                                    asset: asset,
                                    isSelected: false,
                                    showsSelectionIndicator: false
                                )

                                Button {
                                    exportAlbum.remove(
                                        assetIDs: [asset.localIdentifier]
                                    )
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.title3)
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, Color.berryBlack.opacity(0.72))
                                        .padding(6)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove from Export Album")
                            }
                        }
                    }
                }
            }
            .padding(16)
            .padding(.bottom, 104)
        }
        .background(Color.backgroundBlush.ignoresSafeArea())
        .navigationTitle("Export Album")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if exportAlbum.count > 0 {
                exportActionBar
            }
        }
        .onAppear {
            exportAlbum.refreshAssets()
        }
        .sheet(isPresented: $showExternalFolderPicker) {
            ExternalFolderPicker { directoryURL in
                showExternalFolderPicker = false
                Task { await exportAlbum(to: directoryURL) }
            }
        }
        .confirmationDialog(
            "Export verified",
            isPresented: $showPostExportActions,
            titleVisibility: .visible
        ) {
            Button("Delete Originals", role: .destructive) {
                Task { await deleteExportedOriginals() }
            }
            Button("Export Only & Clear Album") {
                clearSuccessfullyExportedAssets()
            }
            Button("Keep in Export Album", role: .cancel) {}
        } message: {
            if let exportResult {
                Text(
                    "\(exportResult.fileCount) files (\(ByteCountFormatter.string(fromByteCount: exportResult.totalBytes, countStyle: .file))) were verified in \(exportResult.directoryURL.lastPathComponent)."
                )
            }
        }
        .alert(
            "Export Couldn’t Finish",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var exportActionBar: some View {
        VStack(spacing: 8) {
            Button {
                showExternalFolderPicker = true
            } label: {
                HStack(spacing: 8) {
                    if isExporting {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "externaldrive.badge.plus")
                    }
                    Text(isExporting ? "Exporting & Verifying…" : "Export Album")
                }
                .font(.duckButton)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(
                    Color.accentPrimary,
                    in: RoundedRectangle(cornerRadius: DuckRadius.m)
                )
            }
            .disabled(
                isExporting
                    || deletionManager.hasPendingDeletion
                    || !unavailableAssetIDs.isEmpty
                    || exportAlbum.assets.isEmpty
            )
            .opacity(
                isExporting || !unavailableAssetIDs.isEmpty ? 0.6 : 1
            )

            Button("Clear Album") {
                exportAlbum.clear()
                exportStatus = nil
            }
            .font(.duckCaption.weight(.semibold))
            .foregroundStyle(Color.textSecondary)
            .disabled(isExporting)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    @MainActor
    private func exportAlbum(to directoryURL: URL) async {
        let explicitAssets = exportAlbum.assets
        let explicitIDs = Set(explicitAssets.map(\.localIdentifier))
        guard !isExporting,
              !explicitAssets.isEmpty,
              explicitAssets.count == exportAlbum.assetIDs.count else {
            errorMessage =
                "Some queued photos are unavailable. Remove unavailable items before exporting."
            return
        }

        isExporting = true
        exportStatus = nil
        defer { isExporting = false }

        do {
            let result = try await ExternalPhotoExportService().export(
                assets: explicitAssets,
                to: directoryURL
            )
            exportResult = result
            exportedAssetIDs = explicitIDs
            exportStatus =
                "Verified \(result.fileCount) files in \(result.directoryURL.lastPathComponent)."
            showPostExportActions = true
        } catch {
            exportResult = nil
            exportedAssetIDs.removeAll()
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func deleteExportedOriginals() async {
        let assetsToDelete = exportAlbum.assets.filter {
            exportedAssetIDs.contains($0.localIdentifier)
        }
        guard !exportedAssetIDs.isEmpty,
              assetsToDelete.count == exportedAssetIDs.count else {
            errorMessage =
                "The album changed after export. The copied files are safe, and no originals were deleted."
            exportedAssetIDs.removeAll()
            return
        }

        do {
            try await deletionManager.delete(assets: assetsToDelete)
            exportAlbum.remove(assetIDs: exportedAssetIDs)
            exportedAssetIDs.removeAll()
            exportStatus =
                "Original deletion is waiting in the undo window."
        } catch {
            errorMessage =
                "The export is safe, but PhotoDuck could not delete the originals: \(error.localizedDescription)"
        }
    }

    private func clearSuccessfullyExportedAssets() {
        exportAlbum.remove(assetIDs: exportedAssetIDs)
        exportedAssetIDs.removeAll()
    }
}

struct ExternalFolderPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.folder],
            asCopy: false
        )
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(
        _ uiViewController: UIDocumentPickerViewController,
        context: Context
    ) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void

        init(onPick: @escaping (URL) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}

private struct CategoryPhotoThumbnail: View {
    let asset: PHAsset
    let isSelected: Bool
    var showsSelectionIndicator = true
    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.surfaceElevated
                        .overlay { ProgressView().tint(Color.accentPrimary) }
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .clipped()

            if showsSelectionIndicator {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(isSelected ? Color.danger : Color.white)
                    .shadow(color: .black.opacity(0.35), radius: 2)
                    .padding(7)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isSelected ? Color.danger : Color.clear, lineWidth: 3)
        }
        .task(id: asset.localIdentifier) {
            image = await asset.loadImage(
                targetSize: CGSize(width: 300, height: 300),
                deliveryMode: .opportunistic,
                allowNetwork: true
            )
        }
    }
}
