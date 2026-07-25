import SwiftUI
import Photos
import UIKit

private struct DiagnosticShareItem: Identifiable {
    let id = UUID()
    let fileURL: URL
}

private struct DiagnosticActivityView: UIViewControllerRepresentable {
    let fileURL: URL

    final class Coordinator {
        private let fileURL: URL
        private let cleanupLock = NSLock()
        private var didRemoveTemporaryFile = false

        init(fileURL: URL) {
            self.fileURL = fileURL
        }

        func removeTemporaryFile() {
            cleanupLock.lock()
            guard !didRemoveTemporaryFile else {
                cleanupLock.unlock()
                return
            }
            didRemoveTemporaryFile = true
            cleanupLock.unlock()

            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(fileURL: fileURL)
    }

    func makeUIViewController(
        context: Context
    ) -> UIActivityViewController {
        let activityViewController = UIActivityViewController(
            activityItems: [fileURL],
            applicationActivities: nil
        )
        let coordinator = context.coordinator
        activityViewController.completionWithItemsHandler = { _, _, _, _ in
            coordinator.removeTemporaryFile()
        }
        return activityViewController
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}

    static func dismantleUIViewController(
        _ uiViewController: UIActivityViewController,
        coordinator: Coordinator
    ) {
        coordinator.removeTemporaryFile()
    }
}

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
    @State private var showDiagnosticsDisclosure = false
    @State private var isPreparingDiagnostics = false
    @State private var diagnosticShareItem: DiagnosticShareItem?
    @State private var diagnosticExportError: String?
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
                    if viewModel.photoAccessNotYetRequested {
                        photoAccessGrantBanner
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
        .sheet(item: $diagnosticShareItem) { item in
            DiagnosticActivityView(fileURL: item.fileURL)
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
        .confirmationDialog(
            "Share diagnostics?",
            isPresented: $showDiagnosticsDisclosure,
            titleVisibility: .visible
        ) {
            Button("Prepare Diagnostic File") {
                prepareDiagnosticReport()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Includes scan states, counts, timings, cache decisions, and sanitized error codes. "
                    + "It never includes photos, videos, filenames, library identifiers, or locations."
            )
        }
        .alert("Notifications are off", isPresented: $showNotificationSettingsAlert) {
            Button("Open Settings") {
                viewModel.openPhotoAccessSettings()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enable notifications in Settings if you want PhotoDuck to alert you when a background scan is ready.")
        }
        .alert(
            "Couldn’t prepare diagnostics",
            isPresented: Binding(
                get: { diagnosticExportError != nil },
                set: { if !$0 { diagnosticExportError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                diagnosticExportError = nil
            }
        } message: {
            Text(diagnosticExportError ?? "Try again.")
        }
        .onChange(of: viewModel.activeScanRunIsComplete) { isComplete in
            if isComplete, isHomeTabSelected, viewModel.lastCompletedAt != nil {
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
            Menu {
                Button {
                    showDiagnosticsDisclosure = true
                } label: {
                    Label(
                        "Share Diagnostics…",
                        systemImage: "square.and.arrow.up"
                    )
                }
            } label: {
                if isPreparingDiagnostics {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "questionmark.circle")
                        .font(.duckBody.weight(.semibold))
                }
            }
            .frame(width: 36, height: 36)
            .foregroundStyle(Color.textSecondary)
            .background(Color.surface, in: Circle())
            .disabled(isPreparingDiagnostics)
            .accessibilityLabel("Support and diagnostics")
            .accessibilityHint("Opens an option to share a privacy-safe diagnostic log")
#if DEBUG
            Button {
                purchaseManager.setAdminAccessEnabled(!purchaseManager.isAdminAccessEnabled)
                DuckHaptics.success()
            } label: {
                Label(
                    purchaseManager.isAdminAccessEnabled ? "Admin On" : "Admin",
                    systemImage: purchaseManager.isAdminAccessEnabled ? "key.fill" : "key"
                )
            }
            .font(.duckCaption.weight(.semibold))
            .foregroundStyle(
                purchaseManager.isAdminAccessEnabled
                    ? Color.success
                    : Color.textSecondary
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.surface, in: Capsule())
            .accessibilityHint(
                purchaseManager.isAdminAccessEnabled
                    ? "Disables developer full access"
                    : "Enables developer full access"
            )
#endif
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

    private func prepareDiagnosticReport() {
        guard !isPreparingDiagnostics else { return }
        isPreparingDiagnostics = true
        Task {
            defer { isPreparingDiagnostics = false }
            do {
                let fileURL = try await viewModel.makeDiagnosticReport()
                diagnosticShareItem = DiagnosticShareItem(fileURL: fileURL)
            } catch {
                diagnosticExportError = error.localizedDescription
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
            if viewModel.isCompletingActiveScan {
                return viewModel.isFinishingSupportingScans
                    ? "Finishing video scan…"
                    : "Finishing photo scan…"
            }
            if totalGroups > 0 {
                return "Review \(totalGroups) groups ready"
            }
            return viewModel.unanalyzedPhotoCount > 0
                ? "Retry \(viewModel.unanalyzedPhotoCount.formatted()) unanalyzed photos"
                : "Scan again"
        case .scanFailure, .idlePrompt:
            return "Start scan"
        }
    }

    private var ctaSubtitle: String {
        switch viewModel.heroState {
        case .speedCleanActive:
            return viewModel.scanProgressLabel
        case .deepCleanActive:
            return viewModel.scanActivityMessage ?? "Tap to pause"
        case .deepCleanPaused:
            return "\(viewModel.processedPhotoCount.formatted()) photos safely scanned so far"
        case .completedResultsAvailable, .reviewReadyPartialResults:
            if viewModel.isFinishingSupportingScans {
                return viewModel.fileScanProgress.statusMessage
                    ?? "Checking large videos after the photo scan"
            }
            if viewModel.isFinalizingPhotoScan {
                return "Saving the completed photo results"
            }
            if totalGroups > 0 {
                return "Tap to start cleaning now"
            }
            return viewModel.unanalyzedPhotoCount > 0
                ? "Some photos couldn't be checked yet"
                : "No photo issues found · runs a fresh photo scan"
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
        .disabled(viewModel.isCompletingActiveScan)
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
            } else if viewModel.unanalyzedPhotoCount > 0 {
                showICloudScanConfirmation = true
            } else {
                viewModel.restartPhotoScan()
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

    private var photoAccessGrantBanner: some View {
        DuckCard {
            HStack(spacing: 12) {
                Image(systemName: "photo.on.rectangle.angled")
                    .foregroundStyle(Color.accentPrimary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Photos access not set up")
                        .font(.duckBody.weight(.semibold))
                        .foregroundStyle(Color.textPrimary)
                    Text("PhotoDuck needs photo access before it can find duplicates.")
                        .font(.duckCaption)
                        .foregroundStyle(Color.textSecondary)
                }
                Spacer()
                Button("Allow") {
                    viewModel.requestPhotoAccess()
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
                    Text("These couldn't be checked, so results may be incomplete. Rescan retries them and downloads originals from iCloud if needed.")
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
            StatMiniCard(
                value: viewModel.reclaimableFormatted,
                label: "Photos + videos"
            )
            StatMiniCard(
                value: deletionManager.lifetimeBytesFreed.formattedBytesStat,
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
        let duplicateGroups = viewModel.duplicatePhotoGroups
        let visuallySimilarGroups = viewModel.visuallySimilarPhotoGroups
        let largeFileBytes = viewModel.dashboardSummary.largeFileBytes

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
                icon: "video.fill",
                color: .warning,
                title: "Large Videos",
                count: viewModel.largeFiles.count,
                status: supportingScanStatus(viewModel.fileScanState),
                note: viewModel.largeFiles.isEmpty
                    ? largeVideoCategoryNote
                    : viewModel.fileScanState == .scanning
                        ? viewModel.fileScanProgress.statusMessage
                            ?? "\(viewModel.largeFiles.count) items"
                        : "\(viewModel.largeFiles.count) items",
                sizeBadge: (viewModel.fileScanState == .completed && !viewModel.largeFiles.isEmpty)
                    ? ByteCountFormatter.string(fromByteCount: largeFileBytes, countStyle: .file) : nil,
                destination: {
                    FileResultsView(
                        files: viewModel.largeFiles,
                        scanState: viewModel.fileScanState,
                        scanProgress: viewModel.fileScanProgress,
                        onRefresh: {
                            await viewModel.scanFiles(force: true)
                        },
                        onAssetDeleted: {
                            viewModel.removeLargeFileFromResults(
                                assetID: $0
                            )
                        }
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
                        Color.textSecondary.opacity(0.12)
                            .frame(maxWidth: .infinity)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .frame(height: 10)
                HStack(spacing: 12) {
                    legendItem(color: .decorPink, label: viewModel.storageUsedFormatted)
                    if foundFraction > 0 {
                        legendItem(color: .accentPrimary, label: "Found by PhotoDuck: \(viewModel.reclaimableFormatted)")
                    }
                    legendItem(color: .textSecondary.opacity(0.25), label: viewModel.storageFreeFormatted)
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

    private var largeVideoCategoryNote: String {
        switch viewModel.fileScanState {
        case .idle:
            return "Waiting for scan"
        case .scanning:
            return viewModel.fileScanProgress.statusMessage
                ?? "Preparing video scan"
        case .paused:
            return viewModel.fileScanProgress.statusMessage
                ?? "Scan paused"
        case .completed:
            return "0 found"
        case .failed:
            return "Scan didn’t finish"
        case .permissionRequired:
            return "Photos access needed"
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
                        .font(.duckBody)
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
                        value: viewModel.lastCompletedReclaimableBytes.formattedBytesStat,
                        accent: .mascotYellow,
                        icon: "sparkles"
                    )
                }

                DuckCard {
                    VStack(spacing: 12) {
                        DuckPrimaryButton(title: viewModel.photoGroups.isEmpty ? "Scan Again" : "Review Now") {
                            if viewModel.photoGroups.isEmpty {
                                viewModel.restartPhotoScan()
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
        categoryAssets.filter {
            selectedAssetIDs.contains($0.localIdentifier)
        }
    }

    private var categoryAssets: [PHAsset] {
        PhotoAssetIdentity.unique(assets)
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
                        ForEach(categoryAssets, id: \.localIdentifier) { asset in
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
                HStack(spacing: 6) {
                    if selectedAssetIDs.count > 1, !purchaseManager.isPurchased {
                        Image(systemName: "lock.fill")
                    }
                    Text(actionTitle)
                }
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
                Text("\(selectedAssetIDs.count) selected · \(selectedBytes.formattedBytesStat)")
                    .font(.duckCaption)
                    .foregroundStyle(Color.textSecondary)
            }
            if selectedAssetIDs.count > 1, !purchaseManager.isPurchased {
                // Say up front what the lock means so nobody selects 40 photos
                // and only then discovers multi-delete is paid.
                Text("Deleting several at once is a Pro feature. Deleting one photo at a time is free.")
                    .font(.duckCaption)
                    .foregroundStyle(Color.textSecondary)
                    .multilineTextAlignment(.center)
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

struct ExternalPhotoExportProgressStatusView: View {
    @ObservedObject var store: ExternalPhotoExportProgressStore
    let onCancel: () -> Void
    let cancellationHelp: String

    var body: some View {
        VStack(spacing: 8) {
            ProgressView(value: store.progress?.overallFraction ?? 0)
                .tint(Color.accentPrimary)

            Text(progressLabel)
                .font(.duckCaption.weight(.semibold))
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)

            Button("Cancel Export", action: onCancel)
                .font(.duckCaption.weight(.semibold))
                .foregroundStyle(Color.danger)

            Text(cancellationHelp)
                .font(.duckMicro)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    private var progressLabel: String {
        guard let progress = store.progress else {
            return "Preparing export…"
        }
        let position = min(
            progress.completedFileCount + 1,
            max(progress.totalFileCount, 1)
        )
        if let filename = progress.currentFilename {
            let percent = Int(
                (progress.currentFileFraction * 100).rounded()
            )
            return "File \(position) of \(progress.totalFileCount) · \(filename) · \(percent)%"
        }
        return "\(progress.completedFileCount) of \(progress.totalFileCount) files done · verifying…"
    }
}

struct ExportAlbumView: View {
    @EnvironmentObject private var exportAlbum: ExportAlbumStore
    @EnvironmentObject private var deletionManager: DeletionManager
    @Environment(\.scenePhase) private var scenePhase

    @State private var showExternalFolderPicker = false
    @State private var showPostExportActions = false
    @State private var showDeleteWithoutExportConfirmation = false
    @State private var pendingDeletionAssetIDs: Set<String> = []
    @State private var isExporting = false
    @State private var exportResult: ExternalPhotoExportResult?
    @State private var exportedAssetIDs: Set<String> = []
    @State private var exportStatus: String?
    @State private var errorMessage: String?
    @State private var exportProgressStore =
        ExternalPhotoExportProgressStore()
    @State private var exportTask: Task<Void, Never>?
    @State private var deleteAfterExport = false
    @State private var liveActivity = ExportLiveActivityController()
    @State private var selectedAssetIDs = Set<String>()
    @State private var hasInitializedSelection = false

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

    private var albumAssets: [PHAsset] {
        PhotoAssetIdentity.unique(exportAlbum.assets)
    }

    private var availableAssetIDs: Set<String> {
        Set(albumAssets.map(\.localIdentifier))
    }

    private var selectedAssets: [PHAsset] {
        ExportAlbumSelection.selectedAssets(
            in: albumAssets,
            assetIDs: selectedAssetIDs
        )
    }

    private var selectedBytes: Int64 {
        selectedAssets.reduce(into: Int64(0)) {
            $0 += $1.estimatedFileSize
        }
    }

    private var allAvailableAssetsAreSelected: Bool {
        !availableAssetIDs.isEmpty
            && selectedAssetIDs == availableAssetIDs
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

                        Text("Add photos or videos while reviewing, then choose an SSD or another folder in Files. PhotoDuck copies and verifies every resource before offering to delete originals.")
                            .font(.duckCaption)
                            .foregroundStyle(Color.textSecondary)

                        if let exportStatus {
                            Text(exportStatus)
                                .font(.duckCaption.weight(.semibold))
                                .foregroundStyle(
                                    exportResult?.wasCancelled == true
                                        || exportResult?.failures.isEmpty
                                            == false
                                        ? Color.warning
                                        : Color.success
                                )
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

                if albumAssets.isEmpty {
                    EmptyStateView(
                        title: "Export Album is empty",
                        icon: "externaldrive.badge.plus",
                        message: "Select photos or large videos in a review screen and tap Add to Export."
                    )
                } else {
                    selectionHeader

                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(albumAssets, id: \.localIdentifier) { asset in
                            ZStack(alignment: .topTrailing) {
                                Button {
                                    toggleSelection(asset.localIdentifier)
                                } label: {
                                    CategoryPhotoThumbnail(
                                        asset: asset,
                                        isSelected: selectedAssetIDs.contains(
                                            asset.localIdentifier
                                        ),
                                        // Export selection is not destructive.
                                        selectionAccent: .accentPrimary
                                    )
                                }
                                .buttonStyle(.plain)
                                .disabled(isExporting)
                                .accessibilityLabel(
                                    selectedAssetIDs.contains(
                                        asset.localIdentifier
                                    )
                                        ? "Selected for export"
                                        : "Not selected for export"
                                )

                                Button {
                                    exportAlbum.remove(
                                        assetIDs: [asset.localIdentifier]
                                    )
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.duckTitle)
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, Color.berryBlack.opacity(0.72))
                                        .padding(6)
                                }
                                .buttonStyle(.plain)
                                .disabled(isExporting)
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
        .navigationBarBackButtonHidden(isExporting)
        .safeAreaInset(edge: .bottom) {
            if exportAlbum.count > 0 {
                exportActionBar
            }
        }
        .onAppear {
            Task {
                await exportAlbum.refreshAssets()
                initializeOrReconcileSelection()
            }
        }
        .onChange(of: deletionManager.undoEventID) { _ in
            // Covers both a tapped Undo and a declined system confirmation —
            // the manager reports the latter through the same channel.
            restoreAlbumAfterFailedDeletion(deletionManager.lastUndoneAssetIDs)
        }
        .onChange(of: deletionManager.lastDeletionError) { error in
            guard error != nil else { return }
            restoreAlbumAfterFailedDeletion(deletionManager.lastFailedAssetIDs)
        }
        .onChange(of: deletionManager.lastCommittedToastID) { toastID in
            guard toastID != nil else { return }
            pendingDeletionAssetIDs.removeAll()
        }
        .onChange(of: exportAlbum.assets.map(\.localIdentifier)) { _ in
            guard hasInitializedSelection else { return }
            selectedAssetIDs =
                ExportAlbumSelection.reconciledAssetIDs(
                    selectedAssetIDs,
                    availableAssetIDs: availableAssetIDs
                )
        }
        .onChange(of: scenePhase) { phase in
            guard isExporting else { return }
            switch phase {
            case .background:
                // Keep copying under the active UIKit background assertion.
                // Its expiration handler marks the activity paused only if
                // iOS actually runs out of granted execution time.
                break
            case .active:
                guard let exportProgress =
                        exportProgressStore.progress else {
                    return
                }
                Task { @MainActor in
                    await liveActivity.resume(with: exportProgress)
                }
            default:
                break
            }
        }
        .sheet(isPresented: $showExternalFolderPicker) {
            ExternalFolderPicker { directoryURL in
                showExternalFolderPicker = false
                exportTask = Task { await exportAlbum(to: directoryURL) }
            }
        }
        .confirmationDialog(
            "Delete without exporting?",
            isPresented: $showDeleteWithoutExportConfirmation,
            titleVisibility: .visible
        ) {
            Button(
                "Delete \(selectedAssets.count) from Photos",
                role: .destructive
            ) {
                Task { await deleteSelectedWithoutExporting() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("These move to Recently Deleted without being copied to a drive first. You'll have 10 seconds to undo.")
        }
        .confirmationDialog(
            "Export verified",
            isPresented: $showPostExportActions,
            titleVisibility: .visible
        ) {
            Button("Delete Originals", role: .destructive) {
                Task { await deleteExportedOriginals() }
            }
            Button("Remove Exported from Album") {
                clearSuccessfullyExportedAssets()
            }
            Button("Keep in Export Album", role: .cancel) {}
        } message: {
            if let exportResult {
                Text(exportCompletionMessage(exportResult))
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

    private var exportCompletionTitle: String {
        guard let exportResult else { return "Export Complete" }
        if exportResult.wasCancelled {
            return "Export Stopped"
        }
        return exportResult.failures.isEmpty
            ? "Export Complete"
            : "Export Complete with Issues"
    }

    private func exportCompletionMessage(
        _ result: ExternalPhotoExportResult
    ) -> String {
        var message =
            "\(result.assetCount) of \(result.requestedAssetCount) items were copied and verified"
            + " (\(ByteCountFormatter.string(fromByteCount: result.totalBytes, countStyle: .file)))"
            + " in \(result.directoryURL.lastPathComponent)."
        if result.failedAssetCount > 0 {
            message +=
                " \(result.failedAssetCount) item(s) could not be exported and remain in the album."
        }
        if result.wasCancelled {
            message +=
                " Completed items are safe; unattempted items remain selected."
        }
        return message
    }

    private var selectionHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(
                    "\(selectedAssetIDs.count) of \(albumAssets.count) selected"
                )
                .font(.duckBody.weight(.semibold))
                .foregroundStyle(Color.textPrimary)

                Text(
                    ByteCountFormatter.string(
                        fromByteCount: selectedBytes,
                        countStyle: .file
                    )
                )
                .font(.duckCaption)
                .foregroundStyle(Color.textSecondary)
            }

            Spacer()

            Button(
                allAvailableAssetsAreSelected ? "Clear" : "Select All"
            ) {
                if allAvailableAssetsAreSelected {
                    selectedAssetIDs.removeAll()
                } else {
                    selectedAssetIDs = availableAssetIDs
                }
            }
            .font(.duckCaption.weight(.semibold))
            .foregroundStyle(Color.accentPrimary)
            .disabled(isExporting)
        }
        .padding(.horizontal, 2)
    }

    private var exportActionBar: some View {
        VStack(spacing: 8) {
            if isExporting {
                exportProgressCard
            } else {
                HStack(spacing: 10) {
                    Button {
                        deleteAfterExport = false
                        showExternalFolderPicker = true
                    } label: {
                        Text(
                            selectedAssetIDs.isEmpty
                                ? "Select Items"
                                : "Export \(selectedAssetIDs.count)"
                        )
                            .font(.duckButton)
                            .foregroundStyle(Color.accentPrimary)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(
                                Color.surface,
                                in: RoundedRectangle(cornerRadius: DuckRadius.m)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: DuckRadius.m)
                                    .stroke(Color.accentPrimary.opacity(0.4), lineWidth: 1)
                            )
                    }
                    .disabled(selectedAssets.isEmpty)

                    Button {
                        deleteAfterExport = true
                        showExternalFolderPicker = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "externaldrive.badge.plus")
                            Text(
                                selectedAssetIDs.isEmpty
                                    ? "Select Items"
                                    : "Export & Delete \(selectedAssetIDs.count)"
                            )
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
                        deletionManager.hasPendingDeletion
                            || selectedAssets.isEmpty
                    )
                }

                // Some items are already backed up elsewhere, so deleting
                // without exporting is a legitimate goal — not every album
                // item needs a fresh copy first.
                Button {
                    showDeleteWithoutExportConfirmation = true
                } label: {
                    Text(
                        selectedAssetIDs.isEmpty
                            ? "Delete from Photos"
                            : "Delete \(selectedAssetIDs.count) from Photos"
                    )
                    .font(.duckButton)
                    .foregroundStyle(Color.danger)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(
                        Color.danger.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: DuckRadius.m)
                    )
                }
                .disabled(
                    deletionManager.hasPendingDeletion
                        || selectedAssets.isEmpty
                )

                Text("Export & Delete moves originals to Recently Deleted only after every file is copied and verified. Delete from Photos skips the copy entirely.")
                    .font(.duckMicro)
                    .foregroundStyle(Color.textSecondary)
                    .multilineTextAlignment(.center)

                Button("Remove Selected from Album") {
                    exportAlbum.remove(assetIDs: selectedAssetIDs)
                    selectedAssetIDs.removeAll()
                    exportStatus = nil
                }
                .font(.duckCaption.weight(.semibold))
                .foregroundStyle(Color.textSecondary)
                .disabled(selectedAssetIDs.isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    // Multi-gigabyte videos can take minutes per file (iCloud download plus a
    // slow Files provider). Without live per-file progress and a way out, the
    // export reads as a frozen app.
    private var exportProgressCard: some View {
        ExternalPhotoExportProgressStatusView(
            store: exportProgressStore,
            onCancel: {
                exportTask?.cancel()
            },
            cancellationHelp:
                "Cancel stops the current item; every verified item stays on the drive. If PhotoDuck is interrupted, choose the same destination again to resume."
        )
    }

    @MainActor
    private func exportAlbum(to directoryURL: URL) async {
        let explicitAssets = selectedAssets
        guard !isExporting,
              !explicitAssets.isEmpty,
              explicitAssets.count == selectedAssetIDs.count else {
            errorMessage =
                "Some selected items are unavailable. Choose the available items again before exporting."
            return
        }
        guard let exportSessionToken =
                ExternalPhotoExportSessionGate.shared.acquire() else {
            errorMessage =
                "Another export is already running. Return to it and wait for it to finish or cancel it."
            return
        }

        isExporting = true
        exportStatus = nil
        exportProgressStore.reset()
        // Commit the small progress UI before ActivityKit, security-scoped
        // Files access, or PhotoKit resource enumeration begins.
        await Task.yield()
        // A multi-gigabyte export must survive auto-lock, and a quick app
        // switch shouldn't kill it mid-file. iOS only grants ~30 s of
        // background grace for user-initiated work; when it expires the app
        // simply suspends and the export resumes on return — the Live
        // Activity tells the user to come back.
        UIApplication.shared.isIdleTimerDisabled = true
        var backgroundTaskID = UIBackgroundTaskIdentifier.invalid
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(
            withName: "PhotoDuck Export"
        ) {
            Task { @MainActor in
                await liveActivity.markPaused()
            }
            if backgroundTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTaskID)
                backgroundTaskID = .invalid
            }
        }
        // The service counts *resources*, not assets — Live Photos, RAW+JPEG
        // pairs and edited photos each carry several. Seeding this with the
        // asset count made the card jump from "File 1 of 12" to "of 27" on the
        // first update. Zero renders as "Preparing export…" until the real
        // total arrives.
        liveActivity.start(
            destinationName: directoryURL.lastPathComponent,
            totalFileCount: 0
        )
        defer {
            ExternalPhotoExportSessionGate.shared.release(
                exportSessionToken
            )
            isExporting = false
            exportProgressStore.reset()
            exportTask = nil
            UIApplication.shared.isIdleTimerDisabled = false
            if backgroundTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTaskID)
            }
        }

        do {
            let result = try await ExternalPhotoExportService().export(
                assets: explicitAssets,
                to: directoryURL,
                onProgress: { progress in
                    Task { @MainActor in
                        exportProgressStore.update(progress)
                        await liveActivity.update(with: progress)
                    }
                }
            )
            exportResult = result
            // Items already verified on this drive from a previous export are
            // just as safe as ones copied now, so they stay eligible for the
            // delete-originals offer.
            exportedAssetIDs = Set(result.exportedAssetIDs)
                .union(result.alreadyExportedAssetIDs)
            let skippedNote = result.alreadyExportedAssetIDs.isEmpty
                ? ""
                : " \(result.alreadyExportedAssetIDs.count) already on this drive — skipped."
            if result.wasCancelled {
                exportStatus =
                    "Stopped after verifying \(result.assetCount) of \(result.requestedAssetCount) items.\(skippedNote)"
            } else if result.failedAssetCount > 0 {
                exportStatus =
                    "Verified \(result.assetCount) items; \(result.failedAssetCount) need another try.\(skippedNote)"
            } else if result.assetCount == 0, !result.alreadyExportedAssetIDs.isEmpty {
                exportStatus =
                    "Everything selected is already on this drive — nothing needed copying."
            } else {
                exportStatus =
                    "Verified all \(result.assetCount) items in \(result.directoryURL.lastPathComponent).\(skippedNote)"
            }
            let activityPhase:
                PhotoDuckExportActivityAttributes.ContentState.Phase =
                    result.wasCancelled
                        ? .cancelled
                        : (
                            result.failures.isEmpty
                                ? .finished
                                : .completedWithFailures
                        )
            await liveActivity.end(
                phase: activityPhase,
                completedFileCount: result.processedFileCount,
                totalFileCount: result.totalPlannedFileCount
            )
            if deleteAfterExport,
               !result.wasCancelled,
               !exportedAssetIDs.isEmpty {
                // The user chose Export & Delete up front; deletion still runs
                // through DeletionManager's undo window and the system's own
                // delete confirmation. Only assets individually copied and
                // verified are eligible; failures remain untouched.
                await deleteExportedOriginals()
            } else if !exportedAssetIDs.isEmpty {
                showPostExportActions = true
            } else if !result.failures.isEmpty {
                // Nothing was verified and every item failed (drive removed,
                // writes rejected). Previously this produced no alert and no
                // dialog — only a caption above the fold — so the export looked
                // like it had simply finished.
                let detail = result.failures.first?.message
                    ?? "PhotoDuck could not copy the selected items."
                errorMessage = result.failures.count == 1
                    ? detail
                    : "\(result.failures.count) items could not be exported. \(detail) Nothing was deleted."
            }
        } catch is CancellationError {
            exportResult = nil
            exportedAssetIDs.removeAll()
            exportStatus =
                "Export stopped. Verified items remain on the drive and no originals were deleted."
            await liveActivity.end(
                phase: .cancelled,
                completedFileCount:
                    exportProgressStore.progress?.completedFileCount ?? 0,
                totalFileCount:
                    exportProgressStore.progress?.totalFileCount ?? 0
            )
        } catch {
            exportResult = nil
            exportedAssetIDs.removeAll()
            errorMessage = error.localizedDescription
            await liveActivity.end(
                phase: .failed,
                completedFileCount:
                    exportProgressStore.progress?.completedFileCount ?? 0,
                totalFileCount:
                    exportProgressStore.progress?.totalFileCount ?? 0
            )
        }
    }

    /// Deletes the current selection straight from Photos with no export.
    /// Routed through DeletionManager so the 10-second undo window, the system
    /// confirmation, and freed-byte accounting all still apply.
    @MainActor
    private func deleteSelectedWithoutExporting() async {
        let assetsToDelete = selectedAssets
        guard !assetsToDelete.isEmpty else { return }
        let deletedIDs = Set(assetsToDelete.map(\.localIdentifier))

        do {
            try await deletionManager.delete(assets: assetsToDelete)
            pendingDeletionAssetIDs = deletedIDs
            exportAlbum.remove(assetIDs: deletedIDs)
            selectedAssetIDs.subtract(deletedIDs)
            exportStatus =
                "Deleting \(deletedIDs.count) items — undo is available for 10 seconds."
        } catch {
            guard !DeletionManager.isUserCancellation(error) else { return }
            errorMessage =
                "PhotoDuck could not delete those items: \(error.localizedDescription)"
        }
    }

    /// A scheduled deletion is only durable once PhotoKit confirms it. Until
    /// then the album removal above is optimistic and must be reversible.
    @MainActor
    private func restoreAlbumAfterFailedDeletion(_ assetIDs: Set<String>) {
        let restorable = pendingDeletionAssetIDs.intersection(assetIDs)
        guard !restorable.isEmpty else { return }
        pendingDeletionAssetIDs.subtract(restorable)
        exportStatus = nil
        Task { await exportAlbum.restore(assetIDs: restorable) }
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
            pendingDeletionAssetIDs = exportedAssetIDs
            exportAlbum.remove(assetIDs: exportedAssetIDs)
            exportedAssetIDs.removeAll()
            exportStatus =
                "Original deletion is waiting in the undo window."
        } catch {
            // Declining Photos' confirmation is an answer, not a failure.
            guard !DeletionManager.isUserCancellation(error) else { return }
            errorMessage =
                "The export is safe, but PhotoDuck could not delete the originals: \(error.localizedDescription)"
        }
    }

    private func clearSuccessfullyExportedAssets() {
        exportAlbum.remove(assetIDs: exportedAssetIDs)
        selectedAssetIDs.subtract(exportedAssetIDs)
        exportedAssetIDs.removeAll()
    }

    private func initializeOrReconcileSelection() {
        if hasInitializedSelection {
            selectedAssetIDs =
                ExportAlbumSelection.reconciledAssetIDs(
                    selectedAssetIDs,
                    availableAssetIDs: availableAssetIDs
                )
        } else {
            // Preserve the old one-tap "export everything" workflow while
            // making every tile independently selectable.
            selectedAssetIDs = availableAssetIDs
            hasInitializedSelection = true
        }
    }

    private func toggleSelection(_ assetID: String) {
        if selectedAssetIDs.contains(assetID) {
            selectedAssetIDs.remove(assetID)
        } else if availableAssetIDs.contains(assetID) {
            selectedAssetIDs.insert(assetID)
        }
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
    /// Destructive red is correct when the selection feeds a deletion, but this
    /// same tile is reused for Export Album selection, where nothing is
    /// removed — showing a delete-styled selection there is misleading.
    var selectionAccent: Color = .danger
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
                    .font(.duckTitle)
                    .foregroundStyle(isSelected ? selectionAccent : Color.white)
                    .shadow(color: .black.opacity(0.35), radius: 2)
                    .padding(7)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isSelected ? selectionAccent : Color.clear, lineWidth: 3)
        }
        .task(id: asset.localIdentifier) {
            image = await PhotoImageRepository.shared.image(
                for: asset,
                targetSize: CGSize(width: 300, height: 300),
                qualityIntent: .thumbnail,
                allowNetworkAccess: false
            )
        }
    }
}
