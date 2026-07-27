import Foundation
import OSLog
import Photos
import PhotosUI
import SwiftUI
import UIKit
import UserNotifications

private enum ScanPersistenceTuning {
    /// Full JSON checkpoints are intentionally conservative because snapshot
    /// construction scales with the whole known library.
    static let periodicCheckpointInterval: TimeInterval = 20
}

@MainActor
private final class PhotoDuckBackgroundTaskLease {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(
            withName: name
        ) { [weak self] in
            Task { @MainActor [weak self] in
                self?.end()
            }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

private final class PhotoLibraryChangeObserverProxy: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    private let onChange: @Sendable () -> Void

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        super.init()
        PHPhotoLibrary.shared().register(self)
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        onChange()
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }
}

struct DashboardCollectionSummary: Equatable {
    static let empty = DashboardCollectionSummary(
        duplicateGroupCount: 0,
        visuallySimilarGroupCount: 0,
        reviewablePhotoCount: 0,
        deleteCandidateCount: 0,
        groupedPhotoCount: 0,
        reclaimablePhotoBytes: 0,
        largeFileBytes: 0
    )

    let duplicateGroupCount: Int
    let visuallySimilarGroupCount: Int
    let reviewablePhotoCount: Int
    let deleteCandidateCount: Int
    let groupedPhotoCount: Int
    let reclaimablePhotoBytes: Int64
    let largeFileBytes: Int64

    static func make(
        groups: [PhotoGroup],
        screenshotAssets: [PHAsset],
        blurryAssets: [PHAsset],
        largeFiles: [LargeFile]
    ) -> DashboardCollectionSummary {
        var duplicateGroupCount = 0
        var visuallySimilarGroupCount = 0
        var reviewableAssetIDs = Set<String>()
        var groupedAssetIDs = Set<String>()
        var deleteCandidateIDs = Set<String>()
        var reclaimablePhotoBytes: Int64 = 0

        for group in groups {
            if group.reason == .visuallySimilar {
                visuallySimilarGroupCount += 1
            } else {
                duplicateGroupCount += 1
            }
            reclaimablePhotoBytes += group.reclaimableBytes
            for asset in group.assets {
                groupedAssetIDs.insert(asset.localIdentifier)
                reviewableAssetIDs.insert(asset.localIdentifier)
            }
            deleteCandidateIDs.formUnion(group.deleteCandidateIDs)
        }
        for asset in screenshotAssets {
            reviewableAssetIDs.insert(asset.localIdentifier)
        }
        for asset in blurryAssets {
            reviewableAssetIDs.insert(asset.localIdentifier)
        }

        return DashboardCollectionSummary(
            duplicateGroupCount: duplicateGroupCount,
            visuallySimilarGroupCount: visuallySimilarGroupCount,
            reviewablePhotoCount: reviewableAssetIDs.count,
            deleteCandidateCount: deleteCandidateIDs.count,
            groupedPhotoCount: groupedAssetIDs.count,
            reclaimablePhotoBytes: reclaimablePhotoBytes,
            largeFileBytes: largeFiles.reduce(into: Int64(0)) {
                $0 += $1.byteSize
            }
        )
    }
}

struct ScanProgressSnapshot: Equatable {
    static let empty = ScanProgressSnapshot(
        libraryTotalCount: 0,
        scanTargetCount: 0,
        processedPhotoCount: 0,
        analyzedPhotoCount: 0,
        unanalyzedPhotoCount: 0,
        progressFraction: 0,
        scanRatePhotosPerMinute: 0,
        activityMessage: nil,
        groupsFoundCount: 0,
        reviewablePhotosCount: 0,
        reclaimableBytesFoundSoFar: 0
    )

    let libraryTotalCount: Int
    let scanTargetCount: Int
    let processedPhotoCount: Int
    let analyzedPhotoCount: Int
    let unanalyzedPhotoCount: Int
    let progressFraction: Double
    let scanRatePhotosPerMinute: Double
    let activityMessage: String?
    let groupsFoundCount: Int
    let reviewablePhotosCount: Int
    let reclaimableBytesFoundSoFar: Int64
}

@MainActor
final class HomeViewModel: ObservableObject {
    private static let scanDiagnosticsLogger = Logger(
        subsystem: "com.photoduck.iOSCleanup",
        category: "PhotoScanResume"
    )

    enum ScanState: String, Codable, Sendable {
        case idle
        case scanning
        case paused
        case completed
        case failed
        case permissionRequired
    }

    enum HeroState: Equatable {
        case permissionRequired
        case scanFailure(String)
        case speedCleanActive
        case deepCleanActive
        case deepCleanPaused
        case reviewReadyPartialResults
        case completedResultsAvailable
        case idlePrompt
    }

    private struct PersistedCleanupState: Codable {
        var cleanupMode: CleanupMode
        var scanState: ScanState
        var isPaused: Bool
        var isBackgroundExecutionState: Bool
        var libraryTotalCount: Int
        var scanTargetCount: Int
        var processedPhotoCount: Int
        var analyzedPhotoCount: Int?
        var unanalyzedPhotoCount: Int?
        var progressFraction: Double
        var groupsFoundCount: Int
        var reviewablePhotosCount: Int
        var reclaimableBytesFoundSoFar: Int64
        var hasPartialResults: Bool
        var isReadyForReview: Bool
        var lastCompletedAt: Date?
        var lastCompletedMode: CleanupMode?
        var lastCompletedLibraryTotalCount: Int
        var lastCompletedScanTargetCount: Int
        var lastCompletedGroupsCount: Int
        var lastCompletedReviewableCount: Int
        var lastCompletedReclaimableBytes: Int64
        var resultsFreshnessState: CleanupResultsFreshnessState
        var lastNotificationKey: String?
    }

    private enum PersistenceKey {
        static let cleanupState = "photoduck.cleanup-state.v2"
    }

    // MARK: - Legacy scan states kept for the existing file surfaces

    @Published var photoGroups: [PhotoGroup] = [] {
        didSet { rebuildCollectionSummary() }
    }
    @Published var screenshotAssets: [PHAsset] = [] {
        didSet { rebuildCollectionSummary() }
    }
    @Published var blurryAssets: [PHAsset] = [] {
        didSet { rebuildCollectionSummary() }
    }
    @Published var largeFiles: [LargeFile] = [] {
        didSet { rebuildCollectionSummary() }
    }
    private(set) var dashboardSummary = DashboardCollectionSummary.empty
    private(set) var duplicatePhotoGroups: [PhotoGroup] = []
    private(set) var visuallySimilarPhotoGroups: [PhotoGroup] = []

    @Published var fileScanState: ScanState = .idle
    @Published private(set) var fileScanProgress = FileScanProgress.idle

    // MARK: - Cleanup dashboard state

    @Published var cleanupMode: CleanupMode = .deepClean
    @Published var scanState: ScanState = .idle
    @Published var isPaused: Bool = false
    @Published var isBackgroundExecutionState: Bool = false
    @Published var hasPartialResults: Bool = false
    @Published var isReadyForReview: Bool = false
    @Published var resultsFreshnessState: CleanupResultsFreshnessState = .live
    @Published var lastCompletedAt: Date?
    @Published private(set) var isFinishingSupportingScans = false
    @Published private(set) var isFinalizingPhotoScan = false
    @Published var notificationEligible: Bool = false
    @Published private(set) var persistenceWarningMessage: String?
    @Published private(set) var photoAuthorizationStatus: PHAuthorizationStatus =
        PHPhotoLibrary.authorizationStatus(for: .readWrite)

    private(set) var libraryTotalCount: Int = 0
    private(set) var scanTargetCount: Int = 0
    private(set) var processedPhotoCount: Int = 0
    private(set) var analyzedPhotoCount: Int = 0
    private(set) var unanalyzedPhotoCount: Int = 0
    private(set) var progressFraction: Double = 0
    private(set) var scanRatePhotosPerMinute: Double = 0
    private(set) var scanActivityMessage: String?
    private(set) var groupsFoundCount: Int = 0
    private(set) var reviewablePhotosCount: Int = 0
    private(set) var reclaimableBytesFoundSoFar: Int64 = 0
    @Published private(set) var progressSnapshot = ScanProgressSnapshot.empty

    @Published var lastCompletedMode: CleanupMode?
    @Published var lastCompletedLibraryTotalCount: Int = 0
    @Published var lastCompletedScanTargetCount: Int = 0
    @Published var lastCompletedGroupsCount: Int = 0
    @Published var lastCompletedReviewableCount: Int = 0
    @Published var lastCompletedReclaimableBytes: Int64 = 0

    @Published var scanErrorMessage: String?

    private var scanTask: Task<Void, Never>?
    private var supportingScansTask: Task<Void, Never>?
    private var libraryChangeTask: Task<Void, Never>?
    private var activePhotoScanEngine: PhotoScanEngine?
    private var activeScanID: UUID?
    private var lastNotificationKey: String?
    private var lastPersistTime: Date = .distantPast
    private var lastCheckpointTime: Date = .distantPast
    private var lastRateSampleAt: Date?
    private var lastRateSampleProcessedCount = 0
    private var lastPhotoDiagnosticProgressBucket = -1
    private var lastVideoDiagnosticProgressBucket = -1
    private var diagnosticWriteTask: Task<Void, Never>?
    private var startedSupportingScansForActiveScan = false
    private var knownLibraryAssetIdentifiers: Set<String> = []
    private var knownLibraryAssetMetadata: [String: CachedPhotoAssetMetadata] = [:]
    private var checkpointEvaluatedAssetIDs = Set<String>()
    private var checkpointTargetAssetIDs = Set<String>()
    private var checkpointUnanalyzedAssetIDs = Set<String>()
    private var checkpointProcessedPhotoCount = 0
    private var checkpointAnalyzedPhotoCount = 0
    private var checkpointUnanalyzedPhotoCount = 0
    private let analysisCache = PhotoAnalysisCache.shared
    private let largeVideoResultCache = LargeVideoResultCache.shared
    private let mlBridge = PhotoMLBridge.shared
    private var photoLibraryObserver: PhotoLibraryChangeObserverProxy?
    private var hasBootstrappedLibraryState = false
    private var hasHydratedAnalysisCache = false
    private var hasHydratedLargeVideoCache = false
    private var analysisCacheHydrationTask: Task<Void, Never>?
    private var largeVideoCacheHydrationTask: Task<Void, Never>?

    init() {
        loadPersistedCleanupState()
        publishProgressSnapshot()
        recordDiagnostic(
            .restoredState(
                scanState: scanState.rawValue,
                processedCount: processedPhotoCount,
                targetCount: scanTargetCount,
                hasCompletionDate: lastCompletedAt != nil
            )
        )
        bootstrapLibraryStateIfNeeded()
    }

    /// Touching PhotoKit while authorization is undetermined triggers the
    /// system permission dialog. Onboarding owns that moment; stay out of the
    /// library entirely until the user has answered, then run the one-time
    /// startup restore. Safe to call repeatedly.
    func bootstrapLibraryStateIfNeeded() {
        photoAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard !hasBootstrappedLibraryState,
              photoAuthorizationStatus != .notDetermined else {
            return
        }
        hasBootstrappedLibraryState = true
        startPhotoLibraryObservationIfDetermined()
        Task(priority: .utility) {
            await restoreCachedLargeVideosIfNeeded()
            await restoreCachedAnalysisIfNeeded()
            await scanNewPhotosIfNeeded()
            await refreshPersistenceHealth()
            await refreshNotificationAuthorization()
        }
    }

    /// Registering a PHPhotoLibrary change observer while authorization is
    /// `.notDetermined` presents the system permission prompt. Register only
    /// once the user has made a choice.
    private func startPhotoLibraryObservationIfDetermined() {
        guard photoLibraryObserver == nil,
              PHPhotoLibrary.authorizationStatus(for: .readWrite) != .notDetermined else {
            return
        }
        photoLibraryObserver = PhotoLibraryChangeObserverProxy { [weak self] in
            Task { @MainActor [weak self] in
                self?.schedulePhotoLibraryRefresh()
            }
        }
    }

    // MARK: - Legacy helpers

    var photoScanState: ScanState { scanState }

    var reclaimableBytes: Int64 {
        dashboardSummary.largeFileBytes + dashboardSummary.reclaimablePhotoBytes
    }

    var reclaimableFormatted: String {
        ByteCountFormatter.string(fromByteCount: reclaimableBytes, countStyle: .file)
    }

    var hasAnyResult: Bool {
        !photoGroups.isEmpty
            || !screenshotAssets.isEmpty
            || !blurryAssets.isEmpty
            || !largeFiles.isEmpty
    }

    var photoReviewCategoryCount: Int {
        screenshotAssets.count + blurryAssets.count
    }

    private func rebuildCollectionSummary() {
        duplicatePhotoGroups = photoGroups.filter {
            $0.reason != .visuallySimilar
        }
        visuallySimilarPhotoGroups = photoGroups.filter {
            $0.reason == .visuallySimilar
        }
        dashboardSummary = DashboardCollectionSummary.make(
            groups: photoGroups,
            screenshotAssets: screenshotAssets,
            blurryAssets: blurryAssets,
            largeFiles: largeFiles
        )
    }

    private func publishProgressSnapshot() {
        let next = ScanProgressSnapshot(
            libraryTotalCount: libraryTotalCount,
            scanTargetCount: scanTargetCount,
            processedPhotoCount: processedPhotoCount,
            analyzedPhotoCount: analyzedPhotoCount,
            unanalyzedPhotoCount: unanalyzedPhotoCount,
            progressFraction: progressFraction,
            scanRatePhotosPerMinute: scanRatePhotosPerMinute,
            activityMessage: scanActivityMessage,
            groupsFoundCount: groupsFoundCount,
            reviewablePhotosCount: reviewablePhotosCount,
            reclaimableBytesFoundSoFar: reclaimableBytesFoundSoFar
        )
        if progressSnapshot != next {
            progressSnapshot = next
        }
    }

    private func recordDiagnostic(_ event: PhotoDuckDiagnosticEvent) {
        let precedingWrite = diagnosticWriteTask
        diagnosticWriteTask = Task.detached(priority: .utility) {
            await precedingWrite?.value
            await PhotoDuckDiagnosticLog.shared.record(event)
        }
    }

    private func recordPhotoProgressIfNeeded(
        isCompleteUpdate: Bool
    ) {
        let percent = scanTargetCount == 0
            ? (isCompleteUpdate ? 100 : 0)
            : min(
                max(
                    Int(
                        (
                            Double(processedPhotoCount)
                                / Double(scanTargetCount)
                                * 100
                        ).rounded(.down)
                    ),
                    0
                ),
                100
            )
        let bucket = percent / 10
        guard bucket != lastPhotoDiagnosticProgressBucket
            || isCompleteUpdate else {
            return
        }
        lastPhotoDiagnosticProgressBucket = bucket
        recordDiagnostic(
            .photoScanProgress(
                processedCount: processedPhotoCount,
                targetCount: scanTargetCount,
                analyzedCount: analyzedPhotoCount,
                unanalyzedCount: unanalyzedPhotoCount,
                groupCount: groupsFoundCount,
                progressPercent: percent,
                isCompleteUpdate: isCompleteUpdate
            )
        )
    }

    private func recordVideoProgressIfNeeded(
        _ update: FileScanUpdate
    ) {
        let total = update.progress.totalVideoCount
        let processed = update.progress.processedVideoCount
        let percent = total == 0
            ? (update.progress.isComplete ? 100 : 0)
            : min(
                max(
                    Int(
                        (
                            Double(processed)
                                / Double(total)
                                * 100
                        ).rounded(.down)
                    ),
                    0
                ),
                100
            )
        let bucket = percent / 10
        guard bucket != lastVideoDiagnosticProgressBucket
            || update.progress.isComplete else {
            return
        }
        lastVideoDiagnosticProgressBucket = bucket
        recordDiagnostic(
            .videoScanProgress(
                totalCount: total,
                processedCount: processed,
                cacheHitCount: update.progress.cacheHitCount,
                qualifyingCount: update.largeFiles?.count ?? largeFiles.count,
                progressPercent: percent,
                isComplete: update.progress.isComplete
            )
        )
    }

    var isAnyScanning: Bool {
        scanState == .scanning || fileScanState == .scanning
    }

    var isAllDone: Bool {
        let states = [scanState, fileScanState]
        return states.contains { $0 != .idle }
            && states.allSatisfy { $0 == .completed || $0 == .idle }
    }

    var activeScanRunIsComplete: Bool {
        Self.isScanRunComplete(
            scanState: scanState,
            isFinalizingPhotoScan: isFinalizingPhotoScan,
            isFinishingSupportingScans: isFinishingSupportingScans
        )
    }

    var isCompletingActiveScan: Bool {
        Self.isScanCompletionLocked(
            scanState: scanState,
            isFinalizingPhotoScan: isFinalizingPhotoScan,
            isFinishingSupportingScans: isFinishingSupportingScans
        )
    }

    nonisolated static func isScanRunComplete(
        scanState: ScanState,
        isFinalizingPhotoScan: Bool,
        isFinishingSupportingScans: Bool
    ) -> Bool {
        scanState == .completed
            && !isFinalizingPhotoScan
            && !isFinishingSupportingScans
    }

    nonisolated static func isScanCompletionLocked(
        scanState: ScanState,
        isFinalizingPhotoScan: Bool,
        isFinishingSupportingScans: Bool
    ) -> Bool {
        isFinishingSupportingScans
            || (scanState == .completed && isFinalizingPhotoScan)
    }

    var hasLimitedPhotoAccess: Bool {
        photoAuthorizationStatus == .limited
    }

    var photoAccessNeedsSettings: Bool {
        photoAuthorizationStatus == .denied || photoAuthorizationStatus == .restricted
    }

    var photoAccessNotYetRequested: Bool {
        photoAuthorizationStatus == .notDetermined
    }

    /// Explicit, user-initiated permission request for people who skipped the
    /// onboarding photos step. This is the only Home-screen path that may
    /// present the system dialog.
    func requestPhotoAccess() {
        Task {
            _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            bootstrapLibraryStateIfNeeded()
            await refreshLibraryMetadata()
        }
    }

    // MARK: - Storage usage (single cached filesystem stat)

    private struct StorageInfo {
        let used: Int64
        let total: Int64
        var free: Int64 { total - used }
        var fraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
    }

    private var _storageInfo: StorageInfo?
    private var storageInfo: StorageInfo {
        if let cached = _storageInfo { return cached }
        let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        let total = (attrs?[.systemSize] as? Int64) ?? 0
        let free  = (attrs?[.systemFreeSize] as? Int64) ?? 0
        let info = StorageInfo(used: total - free, total: total)
        _storageInfo = info
        return info
    }

    var storageUsedFraction: Double   { storageInfo.fraction }
    var storageUsedFormatted: String  { ByteCountFormatter.string(fromByteCount: storageInfo.used,  countStyle: .file) + " used" }
    var storageTotalFormatted: String { ByteCountFormatter.string(fromByteCount: storageInfo.total, countStyle: .file) + " total" }
    var storageFreeFormatted: String  { ByteCountFormatter.string(fromByteCount: storageInfo.free,  countStyle: .file) + " free" }
    var storageTotalBytesValue: Int64 { storageInfo.total }

    // MARK: - Hero Copy

    var heroState: HeroState {
        if scanState == .permissionRequired {
            return .permissionRequired
        }

        if scanState == .failed {
            return .scanFailure(scanErrorMessage ?? "PhotoDuck could not finish scanning.")
        }

        if scanState == .scanning {
            return cleanupMode == .deepClean ? .deepCleanActive : .speedCleanActive
        }

        if scanState == .paused {
            return .deepCleanPaused
        }

        if scanState == .completed {
            return .completedResultsAvailable
        }

        if hasPartialResults && isReadyForReview {
            return .reviewReadyPartialResults
        }

        if lastCompletedAt != nil {
            return .completedResultsAvailable
        }

        return .idlePrompt
    }

    var heroStatusLabel: String {
        switch heroState {
        case .permissionRequired:
            return "Photo access required"
        case .scanFailure:
            return "Scan failed"
        case .speedCleanActive:
            return "Speed Clean running"
        case .deepCleanActive:
            return "Deep Clean in progress"
        case .deepCleanPaused:
            return "Deep Clean paused"
        case .reviewReadyPartialResults:
            return "Review ready"
        case .completedResultsAvailable:
            if isCompletingActiveScan {
                return "Finishing cleanup"
            }
            return "Cleanup complete"
        case .idlePrompt:
            return "Ready to clean"
        }
    }

    var heroPrimaryMetricValue: String {
        switch heroState {
        case .speedCleanActive:
            return "\(processedPhotoCount.formatted())"
        case .deepCleanActive, .deepCleanPaused:
            return "\(processedPhotoCount.formatted()) / \(libraryTotalCount.formatted())"
        case .reviewReadyPartialResults:
            return "\(groupsFoundCount.formatted())"
        case .completedResultsAvailable:
            if lastCompletedGroupsCount > 0 {
                return "\(lastCompletedGroupsCount.formatted()) groups"
            }
            return "0 photo findings"
        case .permissionRequired:
            return "Allow access"
        case .scanFailure:
            return "Try again"
        case .idlePrompt:
            return "Start cleanup"
        }
    }

    var heroPrimaryMetricTitle: String {
        switch heroState {
        case .speedCleanActive:
            return "Quick wins reviewed"
        case .deepCleanActive, .deepCleanPaused:
            return "Photos scanned"
        case .reviewReadyPartialResults:
            return "Findings so far"
        case .completedResultsAvailable:
            return "Last known results"
        case .permissionRequired:
            return "Need access"
        case .scanFailure:
            return "Need another pass"
        case .idlePrompt:
            return "Start a clean"
        }
    }

    var heroDetailText: String {
        switch heroState {
        case .permissionRequired:
            return "Allow Photos access to start Speed Clean or Deep Clean."
        case .scanFailure(let message):
            return message
        case .speedCleanActive:
            return "Speed Clean is finding high-confidence clutter first · \(scanRateLabel)"
        case .deepCleanActive:
            return "\(scanProgressLabel) · \(scanRateLabel) · \(findingsSoFarLabel)"
        case .deepCleanPaused:
            return "\(scanProgressLabel) · paused at \(progressPercentLabel) · \(findingsSoFarLabel)"
        case .reviewReadyPartialResults:
            return "\(findingsSoFarLabel) · ready to review now"
        case .completedResultsAvailable:
            if isFinishingSupportingScans {
                return fileScanProgress.statusMessage
                    ?? "Checking large videos after the photo scan…"
            }
            if isFinalizingPhotoScan {
                return "Saving the completed photo results…"
            }
            if unanalyzedPhotoCount > 0 {
                return "\(unanalyzedPhotoCount.formatted()) photos couldn't be analyzed yet, so this result may be incomplete."
            }
            if resultsFreshnessState == .stale {
                return "Last known results · library changed since the last scan"
            }
            if let lastCompletedAt {
                return "Checked on \(lastCompletedAt.formatted(date: .abbreviated, time: .shortened))"
            }
            return "Your library looks clean."
        case .idlePrompt:
            return "Pick Speed Clean for quick wins or Deep Clean for full-library analysis."
        }
    }

    var heroSecondaryText: String {
        switch heroState {
        case .speedCleanActive:
            return findingsSoFarLabel
        case .deepCleanActive:
            return "Next best action: \(heroNextActionLabel)"
        case .deepCleanPaused:
            return findingsSoFarLabel
        case .reviewReadyPartialResults:
            return "Next best action: \(heroNextActionLabel)"
        case .completedResultsAvailable:
            return completedOutcomeLabel
        case .permissionRequired:
            return "No analysis can start until access is granted."
        case .scanFailure:
            return "Try another pass once access or conditions change."
        case .idlePrompt:
            return "Nothing has been scanned yet."
        }
    }

    var heroNextActionLabel: String {
        switch heroState {
        case .permissionRequired:
            return "Allow access"
        case .scanFailure:
            return "Try again"
        case .speedCleanActive:
            return hasPartialResults ? "Review quick wins" : "Keep scanning"
        case .deepCleanActive:
            return hasPartialResults ? "Review partial results" : "Keep scanning"
        case .deepCleanPaused:
            return "Continue scanning"
        case .reviewReadyPartialResults:
            return "Review results"
        case .completedResultsAvailable:
            if !photoGroups.isEmpty {
                return "Review results"
            }
            if resultsFreshnessState == .stale || lastCompletedGroupsCount > 0 {
                return "Refresh Deep Clean"
            }
            return "Start Speed Clean"
        case .idlePrompt:
            return "Start Speed Clean"
        }
    }

    var heroSecondaryActionLabel: String? {
        switch heroState {
        case .deepCleanActive where hasPartialResults:
            return "Review partial results"
        case .deepCleanPaused where hasPartialResults:
            return "Review partial results"
        case .completedResultsAvailable where lastCompletedGroupsCount > 0:
            return "Start Deep Clean"
        case .idlePrompt:
            return "Start Deep Clean"
        default:
            return nil
        }
    }

    var scanProgressLabel: String {
        guard libraryTotalCount > 0 else { return "Scanning your library" }
        let denominator = cleanupMode == .speedClean ? max(scanTargetCount, 1) : libraryTotalCount
        return "\(processedPhotoCount.formatted()) / \(denominator.formatted()) photos scanned"
    }

    var scanRateLabel: String {
        let perMinute = scanRatePhotosPerMinute
        guard perMinute.isFinite, perMinute > 0 else { return "0 photos/min" }
        if perMinute >= 60 {
            return "\(Int(perMinute.rounded())) photos/min"
        }
        return String(format: "%.1f photos/min", perMinute)
    }

    var progressPercentLabel: String {
        "\(Int((progressFraction * 100).rounded()))% complete"
    }

    var findingsSoFarLabel: String {
        let found = groupsFoundCount.formatted()
        let reviewable = reviewablePhotosCount.formatted()
        let bytes = ByteCountFormatter.string(fromByteCount: reclaimableBytesFoundSoFar, countStyle: .file)
        if groupsFoundCount == 0 && reviewablePhotosCount == 0 {
            return "No findings so far"
        }
        return "\(found) groups · \(reviewable) photos · \(bytes) found so far"
    }

    var completedOutcomeLabel: String {
        if unanalyzedPhotoCount > 0 {
            return "\(unanalyzedPhotoCount.formatted()) photos still need another pass. Tap Rescan to retry them."
        }
        if lastCompletedGroupsCount == 0 {
            if !largeFiles.isEmpty {
                return "\(largeFiles.count.formatted()) large videos are ready to review."
            }
            return "0 photos need attention."
        }
        let bytes = ByteCountFormatter.string(fromByteCount: lastCompletedReclaimableBytes, countStyle: .file)
        return "\(lastCompletedReviewableCount.formatted()) photos reviewable · \(bytes) reclaimable"
    }

    // MARK: - Scans

    func startSpeedClean() {
        Task(priority: .utility) { await scanPhotos(mode: .speedClean) }
    }

    func startDeepClean() {
        Task(priority: .utility) { await scanPhotos(mode: .deepClean) }
    }

    /// An explicit user-facing "Scan Again" is a real new pass. Automatic
    /// launch/resume paths remain incremental so unchanged completed work is
    /// still reused on app open.
    func restartPhotoScan() {
        if scanState == .paused {
            resumeDeepClean()
            return
        }
        Task(priority: .utility) {
            let snapshot = await analysisCache.loadSnapshot()
            if let snapshot, !snapshot.isComplete {
                await scanPhotos(mode: snapshot.cleanupMode)
            } else {
                await scanPhotos(
                    mode: lastCompletedMode ?? .deepClean,
                    forceFullRescan: true
                )
            }
        }
    }

    func resumeDeepClean() {
        recordDiagnostic(
            .photoScanControl(
                action: .resumeRequested,
                processedCount: processedPhotoCount,
                targetCount: scanTargetCount,
                engineWasActive: activePhotoScanEngine != nil
            )
        )
        if scanState == .paused,
           let activePhotoScanEngine,
           scanTask != nil {
            scanState = .scanning
            isPaused = false
            isBackgroundExecutionState = false
            lastRateSampleAt = Date()
            lastRateSampleProcessedCount = processedPhotoCount
            persistCleanupState()
            Task(priority: .utility) {
                await activePhotoScanEngine.resume()
            }
            return
        }

        Task(priority: .utility) { await scanPhotos(mode: cleanupMode) }
    }

    func pauseDeepClean() {
        guard scanState == .scanning else { return }
        recordDiagnostic(
            .photoScanControl(
                action: .pauseRequested,
                processedCount: processedPhotoCount,
                targetCount: scanTargetCount,
                engineWasActive: activePhotoScanEngine != nil
            )
        )
        scanState = .paused
        isPaused = true
        isBackgroundExecutionState = false
        // A paused engine parks in `waitWhilePaused()` indefinitely, so this
        // flag would otherwise stay true for the whole pause and silently
        // no-op Speed Clean, Deep Clean, the unanalyzed retry, the Files
        // refresh, and library reconciliation — with no feedback at all. The
        // scan is suspended, not finalizing.
        isFinalizingPhotoScan = false
        persistCleanupState()
        if let activePhotoScanEngine {
            Task(priority: .utility) { [weak self, analysisCache] in
                await activePhotoScanEngine.pause()
                guard let checkpoint = await MainActor.run(body: {
                    self?.makeAnalysisSnapshot(isComplete: false)
                }) else { return }
                await analysisCache.saveSnapshot(checkpoint)
            }
        } else {
            let checkpoint = makeAnalysisSnapshot(isComplete: false)
            Task(priority: .utility) {
                await analysisCache.saveSnapshot(checkpoint)
            }
        }
    }

    func scanPhotos() async {
        await scanPhotos(mode: .deepClean)
    }

    func scanPhotos(
        mode: CleanupMode,
        allowNetworkAccess: Bool = PhotoScanDefaults.allowNetworkAccess,
        forceFullRescan: Bool = false,
        retryUnanalyzed: Bool = false
    ) async {
        // Own the complete restore/plan/scan lifecycle, not only the worker
        // task. Startup reconciliation or a rapid second tap must not replace
        // the active scan while its 50k-photo inventory is still being read.
        guard !isFinalizingPhotoScan else { return }
        let previousScanState = scanState
        let scanID = UUID()
        activeScanID = scanID
        isFinalizingPhotoScan = true
        lastPhotoDiagnosticProgressBucket = -1
        recordDiagnostic(
            .photoScanRequested(
                mode: mode.rawValue,
                previousState: previousScanState.rawValue,
                forceFullRescan: forceFullRescan,
                retryUnanalyzed: retryUnanalyzed
            )
        )
        if let activePhotoScanEngine {
            await activePhotoScanEngine.resume()
        }
        scanTask?.cancel()
        supportingScansTask?.cancel()
        supportingScansTask = nil
        isFinishingSupportingScans = false

        await restoreCachedAnalysisIfNeeded()
        await refreshLibraryMetadata()

        let loadedSnapshot = await analysisCache.loadSnapshot()
        let loadedSnapshotWasFound = loadedSnapshot != nil
        let loadedSnapshotWasComplete = loadedSnapshot?.isComplete ?? false
        let loadedSnapshotWasConsistent =
            loadedSnapshot?.hasConsistentCompletionState ?? false
        var cachedSnapshot = loadedSnapshot
        var snapshotRepairOutcome: PhotoDuckDiagnosticSnapshotRepair =
            .notNeeded
        if let snapshot = cachedSnapshot,
           !snapshot.isComplete,
           snapshot.processedPhotoCount > 0,
           snapshot.scanTargetAssetIdentifiers.isEmpty,
           let repairedSnapshot = await repairPrematureCompletion(snapshot) {
            cachedSnapshot = repairedSnapshot
            snapshotRepairOutcome = .repaired
            await analysisCache.saveSnapshot(repairedSnapshot)
        }
        if let snapshot = cachedSnapshot,
           !snapshot.hasConsistentCompletionState {
            cachedSnapshot = await repairPrematureCompletion(snapshot)
            snapshotRepairOutcome = cachedSnapshot == nil
                ? .discarded
                : .repaired
            if let cachedSnapshot {
                await analysisCache.saveSnapshot(cachedSnapshot)
            }
        }
        guard activeScanID == scanID else { return }
        let incrementalRequiredIDs = PhotoScanResumePlanner.requiredAssetIDs(
            snapshot: cachedSnapshot,
            currentAssetIDs: knownLibraryAssetIdentifiers,
            currentMetadata: knownLibraryAssetMetadata,
            mode: mode,
            forceFullRescan: forceFullRescan,
            retryAssetIDs: retryUnanalyzed
                ? Set(cachedSnapshot?.unanalyzedAssetIdentifiers ?? [])
                : []
        )
        let isIncrementalPass = incrementalRequiredIDs != nil
        let isResumingCheckpoint = cachedSnapshot?.isComplete == false
            && isIncrementalPass
        let progressOffset = isIncrementalPass
            ? cachedSnapshot?.processedPhotoCount ?? 0
            : 0
        let analyzedOffset = isIncrementalPass
            ? cachedSnapshot?.analyzedPhotoCount ?? 0
            : 0
        let unanalyzedOffset = isIncrementalPass
            ? cachedSnapshot?.unanalyzedPhotoCount ?? 0
            : 0
        let plannedTargetCount = isIncrementalPass
            ? progressOffset + (incrementalRequiredIDs?.count ?? 0)
            : knownLibraryAssetIdentifiers.count
        recordDiagnostic(
            .photoScanPlanned(
                libraryCount: knownLibraryAssetIdentifiers.count,
                snapshotFound: loadedSnapshotWasFound,
                snapshotComplete: loadedSnapshotWasComplete,
                snapshotConsistent: loadedSnapshotWasConsistent,
                snapshotRepairOutcome: snapshotRepairOutcome,
                requiredCount: incrementalRequiredIDs?.count,
                isResume: isResumingCheckpoint,
                progressOffset: progressOffset,
                targetCount: plannedTargetCount
            )
        )
        #if DEBUG
        if isResumingCheckpoint {
            Self.scanDiagnosticsLogger.debug(
                "restored_checkpoint=\(progressOffset) required_ids=\(incrementalRequiredIDs?.count ?? 0)"
            )
        }
        #endif

        if let incrementalRequiredIDs, incrementalRequiredIDs.isEmpty {
            // An unchanged inventory means persisted analysis is still current.
            // Do not rerun Vision just because the app was reopened, and do not
            // rewrite the snapshot: re-stamping savedAt would claim a check
            // happened now, and a fabricated "complete" snapshot could mark
            // never-analyzed assets as evaluated.
            scanState = .completed
            isPaused = false
            resultsFreshnessState = .live
            lastCompletedAt = cachedSnapshot?.savedAt ?? lastCompletedAt
            lastCompletedLibraryTotalCount = knownLibraryAssetIdentifiers.count
            if let cachedSnapshot {
                // Legacy snapshots know the failure count but not the IDs;
                // never let the smaller number hide known failures.
                unanalyzedPhotoCount = max(
                    cachedSnapshot.unanalyzedAssetIdentifiers.count,
                    cachedSnapshot.unanalyzedPhotoCount
                )
            }
            publishProgressSnapshot()
            recordDiagnostic(
                .photoScanNoWork(
                    libraryCount: knownLibraryAssetIdentifiers.count,
                    processedCount: processedPhotoCount,
                    targetCount: scanTargetCount
                )
            )
            isFinalizingPhotoScan = false
            persistCleanupState()
            return
        }

        let preservedGroups = incrementalRequiredIDs == nil ? [] : photoGroups
        let preservedScreenshots = incrementalRequiredIDs == nil ? [] : screenshotAssets
        let preservedBlurryAssets = incrementalRequiredIDs == nil ? [] : blurryAssets
        let preservesExistingResults = incrementalRequiredIDs != nil
        let preservedReviewableCount = PhotoReviewCategoryClassifier.reviewableCount(
            groups: preservedGroups,
            screenshotAssets: preservedScreenshots,
            blurryAssets: preservedBlurryAssets
        )

        cleanupMode = mode
        scanState = .scanning
        isPaused = false
        isReadyForReview = preservesExistingResults
            && preservedReviewableCount > 0
        hasPartialResults = isReadyForReview
        scanErrorMessage = nil
        resultsFreshnessState = .live
        lastNotificationKey = nil
        lastRateSampleAt = Date()
        lastRateSampleProcessedCount = 0
        startedSupportingScansForActiveScan = false
        scanRatePhotosPerMinute = 0
        scanActivityMessage = isResumingCheckpoint
            ? "Restored saved results. Waiting for the next local or iCloud photo…"
            : preservesExistingResults
                ? "Keeping saved results while checking new or changed photos…"
                : "Preparing the first photo batch…"
        processedPhotoCount = progressOffset
        analyzedPhotoCount = analyzedOffset
        unanalyzedPhotoCount = preservesExistingResults
            ? max(
                unanalyzedOffset,
                max(
                    cachedSnapshot?.unanalyzedPhotoCount ?? 0,
                    cachedSnapshot?.unanalyzedAssetIdentifiers.count ?? 0
                )
            )
            : unanalyzedOffset
        screenshotAssets = preservesExistingResults ? preservedScreenshots : []
        blurryAssets = preservesExistingResults ? preservedBlurryAssets : []
        let preparedTargetAssetIDs: Set<String>
        if isResumingCheckpoint {
            preparedTargetAssetIDs = Set(
                cachedSnapshot?.scanTargetAssetIdentifiers ?? []
            )
        } else if mode == .deepClean {
            preparedTargetAssetIDs =
                incrementalRequiredIDs ?? knownLibraryAssetIdentifiers
        } else {
            preparedTargetAssetIDs = incrementalRequiredIDs ?? []
        }
        let preparedTargetCount = isResumingCheckpoint
            ? max(
                cachedSnapshot?.scanTargetCount ?? 0,
                progressOffset + (incrementalRequiredIDs?.count ?? 0)
            )
            : progressOffset + preparedTargetAssetIDs.count
        scanTargetCount = preparedTargetCount
        progressFraction = preparedTargetCount == 0
            ? 0
            : min(
                Double(progressOffset) / Double(preparedTargetCount),
                1
            )
        groupsFoundCount = preservesExistingResults ? preservedGroups.count : 0
        reviewablePhotosCount = preservesExistingResults
            ? preservedReviewableCount
            : 0
        reclaimableBytesFoundSoFar = preservesExistingResults
            ? preservedGroups.totalReclaimableBytes
            : 0
        checkpointEvaluatedAssetIDs = isIncrementalPass
            ? Set(cachedSnapshot?.evaluatedAssetIdentifiers ?? [])
            : []
        checkpointTargetAssetIDs = preparedTargetAssetIDs
        // Carry unanalyzed assets across any incremental pass (resume or
        // new-photos-only) so earlier failures are still reported and can be
        // retried later. A full rescan starts the record fresh.
        checkpointUnanalyzedAssetIDs = incrementalRequiredIDs == nil
            ? []
            : Set(cachedSnapshot?.unanalyzedAssetIdentifiers ?? [])
        checkpointProcessedPhotoCount = progressOffset
        checkpointAnalyzedPhotoCount = analyzedOffset
        checkpointUnanalyzedPhotoCount = unanalyzedOffset

        publishProgressSnapshot()
        persistCleanupState()

        let engine = PhotoScanEngine()
        activePhotoScanEngine = engine

        let worker = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                for try await update in engine.scan(
                    mode: mode,
                    allowNetworkAccess: allowNetworkAccess,
                    requiredAssetIDs: incrementalRequiredIDs,
                    expectedLibraryPhotoCount:
                        knownLibraryAssetIdentifiers.count
                ) {
                    let checkpoint: CachedPhotoAnalysisSnapshot? = await MainActor.run {
                        guard self.activeScanID == scanID else { return nil }
                        return self.apply(
                            update: update,
                            preservingGroups: preservedGroups,
                            preservingScreenshots: preservedScreenshots,
                            preservingBlurryAssets: preservedBlurryAssets,
                            progressOffset: progressOffset,
                            analyzedOffset: analyzedOffset,
                            unanalyzedOffset: unanalyzedOffset,
                            resumedTargetCount: isIncrementalPass
                                ? progressOffset + update.scanTargetCount
                                : nil
                        )
                    }
                    if let checkpoint {
                        if checkpoint.isComplete {
                            await self.analysisCache.saveSnapshot(checkpoint)
                        } else {
                            // The JSON checkpoint and its reusable per-asset
                            // analysis form one durability boundary.
                            await self.mlBridge.flushBufferedWrites()
                            // Normal scan work never waits on full-library JSON.
                            await self.analysisCache.scheduleSnapshot(checkpoint)
                        }
                    }
                }

                await MainActor.run {
                    guard self.activeScanID == scanID else { return }
                    self.scanState = .completed
                    self.isPaused = false
                    self.isReadyForReview = !self.photoGroups.isEmpty
                        || !self.screenshotAssets.isEmpty
                        || !self.blurryAssets.isEmpty
                    self.hasPartialResults = self.isReadyForReview
                    self.lastCompletedAt = Date()
                    self.lastCompletedMode = mode
                    self.lastCompletedLibraryTotalCount = self.libraryTotalCount
                    self.lastCompletedScanTargetCount = self.scanTargetCount
                    self.lastCompletedGroupsCount = self.groupsFoundCount
                    self.lastCompletedReviewableCount = self.reviewablePhotosCount
                    self.lastCompletedReclaimableBytes = self.reclaimableBytesFoundSoFar
                    self.resultsFreshnessState = .live

                    self.maybeScheduleNotification(
                        key: self.notificationKey(for: mode, completed: true),
                        title: self.groupsFoundCount == 0
                            && self.photoReviewCategoryCount == 0
                            && self.unanalyzedPhotoCount == 0
                            ? "Your library looks clean"
                            : "Deep Clean is ready",
                        body: self.groupsFoundCount == 0
                            && self.photoReviewCategoryCount == 0
                            && self.unanalyzedPhotoCount == 0
                            ? "PhotoDuck checked your library and found no actionable issues."
                            : self.groupsFoundCount == 0
                                && self.photoReviewCategoryCount == 0
                                ? "\(self.unanalyzedPhotoCount) photos couldn't be analyzed and can be retried."
                            : self.groupsFoundCount == 0
                                ? "Tap to review \(self.photoReviewCategoryCount) screenshot or blurry-photo suggestions."
                            : "Tap to review \(self.groupsFoundCount) groups and reclaim \(ByteCountFormatter.string(fromByteCount: self.reclaimableBytesFoundSoFar, countStyle: .file))."
                    )
                    self.scanActivityMessage = nil
                    self.publishProgressSnapshot()
                    self.recordDiagnostic(
                        .photoScanTerminated(
                            outcome: .completed,
                            processedCount: self.processedPhotoCount,
                            targetCount: self.scanTargetCount,
                            analyzedCount: self.analyzedPhotoCount,
                            unanalyzedCount: self.unanalyzedPhotoCount,
                            groupCount: self.groupsFoundCount
                        )
                    )
                    // Publish the completion barrier last so observers can
                    // never see a completed run with the previous timestamp.
                    self.isFinalizingPhotoScan = false
                    self.persistCleanupState()
                }
            } catch is CancellationError {
                let checkpoint: CachedPhotoAnalysisSnapshot? = await MainActor.run {
                    guard self.activeScanID == scanID else { return nil }
                    self.scanState = .paused
                    self.isPaused = true
                    self.isFinalizingPhotoScan = false
                    self.recordDiagnostic(
                        .photoScanTerminated(
                            outcome: .cancelled,
                            processedCount: self.processedPhotoCount,
                            targetCount: self.scanTargetCount,
                            analyzedCount: self.analyzedPhotoCount,
                            unanalyzedCount: self.unanalyzedPhotoCount,
                            groupCount: self.groupsFoundCount
                        )
                    )
                    self.persistCleanupState()
                    return self.makeAnalysisSnapshot(isComplete: false)
                }
                if let checkpoint {
                    await self.analysisCache.saveSnapshot(checkpoint)
                }
            } catch let error as ScanError {
                await MainActor.run {
                    guard self.activeScanID == scanID else { return }
                    let nsError = error as NSError
                    let diagnosticOutcome:
                        PhotoDuckDiagnosticTerminationOutcome
                    let diagnosticFailureKind:
                        PhotoDuckDiagnosticFailureKind
                    switch error {
                    case .permissionDenied:
                        self.scanState = .permissionRequired
                        self.scanErrorMessage = "Allow Photos access to start cleanup."
                        diagnosticOutcome = .permissionRequired
                        diagnosticFailureKind = .permission
                    case .photoLibraryTemporarilyUnavailable:
                        self.scanState = .failed
                        self.scanErrorMessage = error.localizedDescription
                        diagnosticOutcome = .failed
                        diagnosticFailureKind = .photoScan
                    }
                    self.isFinalizingPhotoScan = false
                    self.recordDiagnostic(
                        .photoScanTerminated(
                            outcome: diagnosticOutcome,
                            processedCount: self.processedPhotoCount,
                            targetCount: self.scanTargetCount,
                            analyzedCount: self.analyzedPhotoCount,
                            unanalyzedCount: self.unanalyzedPhotoCount,
                            groupCount: self.groupsFoundCount,
                            failure: PhotoDuckDiagnosticFailure(
                                kind: diagnosticFailureKind,
                                error: nsError
                            )
                        )
                    )
                    self.persistCleanupState()
                }
            } catch {
                await MainActor.run {
                    guard self.activeScanID == scanID else { return }
                    let nsError = error as NSError
                    self.scanErrorMessage = error.localizedDescription
                    self.scanState = .failed
                    self.isFinalizingPhotoScan = false
                    self.recordDiagnostic(
                        .photoScanTerminated(
                            outcome: .failed,
                            processedCount: self.processedPhotoCount,
                            targetCount: self.scanTargetCount,
                            analyzedCount: self.analyzedPhotoCount,
                            unanalyzedCount: self.unanalyzedPhotoCount,
                            groupCount: self.groupsFoundCount,
                            failure: PhotoDuckDiagnosticFailure(
                                kind: .photoScan,
                                error: nsError
                            )
                        )
                    )
                    self.persistCleanupState()
                }
            }
        }

        scanTask = worker
        await worker.value
        if activeScanID == scanID {
            scanTask = nil
            activePhotoScanEngine = nil
            if scanState == .completed,
               !isFinalizingPhotoScan,
               processedPhotoCount >= scanTargetCount,
               (scanTargetCount > 0
                    || knownLibraryAssetIdentifiers.isEmpty),
               (analyzedPhotoCount > 0
                    || knownLibraryAssetIdentifiers.isEmpty) {
                startSupportingScansAfterSuccessfulPhotoScan(
                    scanID: scanID
                )
            }
        }
    }

    func retryIncludingICloudPhotos() {
        Task(priority: .utility) {
            // Retry only the assets that previously failed analysis (plus any
            // new or changed photos), with iCloud download allowed. A full
            // rescan would throw away every already-valid result for nothing.
            // Snapshots written before per-asset failure tracking existed know
            // how many assets failed but not which ones — only they need the
            // full pass.
            let snapshot = await analysisCache.loadSnapshot()
            let isLegacyFailureRecord = (snapshot?.unanalyzedPhotoCount ?? 0) > 0
                && snapshot?.unanalyzedAssetIdentifiers.isEmpty == true
            await scanPhotos(
                mode: lastCompletedMode ?? .deepClean,
                allowNetworkAccess: true,
                forceFullRescan: isLegacyFailureRecord,
                retryUnanalyzed: true
            )
        }
    }

    // MARK: - Other scans


    func scanFiles(force: Bool = false) async {
        if !force {
            await restoreCachedLargeVideosIfNeeded()
        }
        // Large-video enumeration competes for the same PhotoKit resources as
        // image analysis. Never let a tab switch start it while the primary
        // photo run is still planning, scanning, paused in-memory, or flushing.
        guard !isFinalizingPhotoScan,
              scanState != .scanning else {
            return
        }
        let previousFileScanState = fileScanState
        guard force
            || fileScanState == .idle
            || fileScanState == .failed
            || fileScanState == .paused else {
            return
        }
        guard fileScanState != .scanning else { return }
        lastVideoDiagnosticProgressBucket = -1
        recordDiagnostic(
            .videoScanRequested(
                force: force,
                previousState: previousFileScanState.rawValue
            )
        )
        fileScanState = .scanning
        fileScanProgress = FileScanProgress(
            totalVideoCount: 0,
            processedVideoCount: 0,
            cacheHitCount: 0,
            isComplete: false,
            statusMessage: "Preparing your video library…"
        )
        let engine = FileScanEngine()
        do {
            let scannedFiles = try await engine.scan { [weak self] update in
                await self?.publishFileScanUpdate(update)
            }
            largeFiles = scannedFiles
            fileScanState = .completed
            await largeVideoResultCache.save(
                files: scannedFiles,
                totalVideoCount: fileScanProgress.totalVideoCount
            )
        } catch let error as FileScanError {
            let nsError = error as NSError
            fileScanState = .permissionRequired
            fileScanProgress = FileScanProgress(
                totalVideoCount: 0,
                processedVideoCount: 0,
                cacheHitCount: 0,
                isComplete: false,
                statusMessage: error.localizedDescription
            )
            scanErrorMessage = error.localizedDescription
            photoAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            recordDiagnostic(
                .videoScanTerminated(
                    outcome: .permissionRequired,
                    totalCount: fileScanProgress.totalVideoCount,
                    processedCount: fileScanProgress.processedVideoCount,
                    cacheHitCount: fileScanProgress.cacheHitCount,
                    failure: PhotoDuckDiagnosticFailure(
                        kind: .permission,
                        error: nsError
                    )
                )
            )
        } catch is CancellationError {
            fileScanState = .paused
            fileScanProgress = FileScanProgress(
                totalVideoCount: fileScanProgress.totalVideoCount,
                processedVideoCount: fileScanProgress.processedVideoCount,
                cacheHitCount: fileScanProgress.cacheHitCount,
                isComplete: false,
                statusMessage: "Video scan paused. Scan again to continue with saved sizes."
            )
            recordDiagnostic(
                .videoScanTerminated(
                    outcome: .cancelled,
                    totalCount: fileScanProgress.totalVideoCount,
                    processedCount: fileScanProgress.processedVideoCount,
                    cacheHitCount: fileScanProgress.cacheHitCount
                )
            )
        } catch {
            let nsError = error as NSError
            fileScanState = .failed
            fileScanProgress = FileScanProgress(
                totalVideoCount: fileScanProgress.totalVideoCount,
                processedVideoCount: fileScanProgress.processedVideoCount,
                cacheHitCount: fileScanProgress.cacheHitCount,
                isComplete: false,
                statusMessage: "Video scan didn’t finish. Try again."
            )
            recordDiagnostic(
                .videoScanTerminated(
                    outcome: .failed,
                    totalCount: fileScanProgress.totalVideoCount,
                    processedCount: fileScanProgress.processedVideoCount,
                    cacheHitCount: fileScanProgress.cacheHitCount,
                    failure: PhotoDuckDiagnosticFailure(
                        kind: .videoScan,
                        error: nsError
                    )
                )
            )
        }
    }

    private func publishFileScanUpdate(_ update: FileScanUpdate) {
        fileScanProgress = update.progress
        if let files = update.largeFiles {
            largeFiles = files
        }
        recordVideoProgressIfNeeded(update)
    }

    func removeLargeFileFromResults(assetID: String) {
        let previousCount = largeFiles.count
        largeFiles.removeAll {
            $0.photoAsset.localIdentifier == assetID
        }
        guard largeFiles.count != previousCount else { return }

        // Keep completed-scan counters honest without re-enumerating every
        // video. A later explicit refresh can still discover external changes.
        if fileScanProgress.isComplete {
            let nextTotal = max(
                fileScanProgress.totalVideoCount - 1,
                0
            )
            let nextProcessed = min(
                max(fileScanProgress.processedVideoCount - 1, 0),
                nextTotal
            )
            fileScanProgress = FileScanProgress(
                totalVideoCount: nextTotal,
                processedVideoCount: nextProcessed,
                cacheHitCount: min(
                    fileScanProgress.cacheHitCount,
                    nextProcessed
                ),
                isComplete: true,
                statusMessage:
                    "\(largeFiles.count) large videos ready to review."
            )
        }
        _storageInfo = nil
        publishProgressSnapshot()
        persistCleanupState()
        Task(priority: .utility) { [largeVideoResultCache] in
            await largeVideoResultCache.remove(assetIdentifier: assetID)
        }
    }

    // MARK: - Scene / refresh

    func updateScenePhase(_ phase: ScenePhase) {
        let diagnosticPhase: String
        switch phase {
        case .background:
            diagnosticPhase = "background"
        case .active:
            diagnosticPhase = "active"
        case .inactive:
            diagnosticPhase = "inactive"
        @unknown default:
            diagnosticPhase = "unknown"
        }
        recordDiagnostic(
            .sceneChanged(
                phase: diagnosticPhase,
                scanState: scanState.rawValue,
                processedCount: processedPhotoCount,
                targetCount: scanTargetCount
            )
        )
        switch phase {
        case .background:
            isBackgroundExecutionState = scanState == .scanning && cleanupMode == .deepClean
            let checkpoint = hasHydratedAnalysisCache
                && (scanState == .scanning || scanState == .paused)
                ? makeAnalysisSnapshot(isComplete: false)
                : nil
            let pendingDiagnosticWrite = diagnosticWriteTask
            let backgroundTaskLease = PhotoDuckBackgroundTaskLease(
                name: "PhotoDuck background checkpoint"
            )
            Task(priority: .utility) {
                [analysisCache, mlBridge, backgroundTaskLease] in
                await pendingDiagnosticWrite?.value
                await AssetFileSizeRepository.shared.flush()
                if let checkpoint {
                    await mlBridge.flushBufferedWrites()
                    await analysisCache.saveSnapshot(checkpoint)
                }
                // Include progress or termination events emitted while the
                // cache/checkpoint work above was running.
                let finalDiagnosticWrite = diagnosticWriteTask
                await finalDiagnosticWrite?.value
                backgroundTaskLease.end()
            }
        case .active:
            isBackgroundExecutionState = false
            Task { await refreshLibraryMetadata() }
        case .inactive:
            break
        @unknown default:
            break
        }
        persistCleanupState()
    }

    func refreshLibraryMetadata() async {
        photoAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        // Never fetch while undetermined: PhotoKit would raise the system
        // permission dialog outside the onboarding flow that owns it.
        guard photoAuthorizationStatus != .notDetermined else { return }
        startPhotoLibraryObservationIfDetermined()
        let currentMetadata = await currentLibraryPhotoMetadata()
        knownLibraryAssetMetadata = currentMetadata
        knownLibraryAssetIdentifiers = Set(currentMetadata.keys)
        // An unanalyzed photo that has since been deleted can never be
        // retried, but it still counted toward "N photos couldn't be
        // analyzed" and the retry planner drops it from the work set — so the
        // Retry CTA would resolve to nothing and the banner would never clear.
        if scanState != .scanning {
            let stillPresent = checkpointUnanalyzedAssetIDs
                .intersection(knownLibraryAssetIdentifiers)
            if stillPresent.count != checkpointUnanalyzedAssetIDs.count {
                checkpointUnanalyzedAssetIDs = stillPresent
                unanalyzedPhotoCount = stillPresent.count
            }
        }
        let currentCount = currentMetadata.count
        let previousTotal = libraryTotalCount
        libraryTotalCount = currentCount
        publishProgressSnapshot()

        if scanState == .idle || scanState == .completed {
            if lastCompletedLibraryTotalCount != 0, lastCompletedLibraryTotalCount != currentCount {
                resultsFreshnessState = .stale
            } else if lastCompletedAt != nil {
                resultsFreshnessState = .lastKnown
            }
        }

        if previousTotal != currentCount, scanState == .idle, lastCompletedAt != nil {
            resultsFreshnessState = .stale
        }

        persistCleanupState()
    }

    func openPhotoAccessSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    func manageLimitedPhotoSelection() {
        guard photoAuthorizationStatus == .limited,
              let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController
        else {
            return
        }

        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: root.topmostPresentedViewController)
    }

    func dismissPersistenceWarning() {
        persistenceWarningMessage = nil
    }

    func requestCompletionNotifications() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            notificationEligible = true
        case .notDetermined:
            do {
                notificationEligible = try await center.requestAuthorization(
                    options: [.alert, .sound]
                )
            } catch {
                notificationEligible = false
            }
        case .denied:
            notificationEligible = false
        @unknown default:
            notificationEligible = false
        }
        return notificationEligible
    }

    // MARK: - Apply updates

    private func apply(
        update: PhotoScanUpdate,
        preservingGroups: [PhotoGroup] = [],
        preservingScreenshots: [PHAsset] = [],
        preservingBlurryAssets: [PHAsset] = [],
        progressOffset: Int = 0,
        analyzedOffset: Int = 0,
        unanalyzedOffset: Int = 0,
        resumedTargetCount: Int? = nil
    ) -> CachedPhotoAnalysisSnapshot? {
        libraryTotalCount = update.libraryTotalCount
        scanTargetCount = resumedTargetCount.map {
            max($0, progressOffset + update.scanTargetCount)
        } ?? update.scanTargetCount
        processedPhotoCount = progressOffset + update.processedPhotoCount
        analyzedPhotoCount = analyzedOffset + update.analyzedPhotoCount
        progressFraction = scanTargetCount == 0
            ? 1
            : min(Double(processedPhotoCount) / Double(scanTargetCount), 1)
        checkpointEvaluatedAssetIDs.formUnion(update.evaluatedAssetIDs)
        checkpointTargetAssetIDs.formUnion(update.targetAssetIDs)
        // A retried asset that now succeeds leaves the unanalyzed record; a
        // fresh failure joins it. The published count is derived from the set
        // so carried-over failures are never double counted.
        checkpointUnanalyzedAssetIDs.subtract(update.evaluatedAssetIDs)
        checkpointUnanalyzedAssetIDs.formUnion(update.unanalyzedAssetIDs)
        unanalyzedPhotoCount = checkpointUnanalyzedAssetIDs.count
        checkpointProcessedPhotoCount = progressOffset
            + (update.committedProcessedPhotoCount ?? 0)
        checkpointAnalyzedPhotoCount = analyzedOffset
            + (update.committedAnalyzedPhotoCount ?? 0)
        checkpointUnanalyzedPhotoCount = unanalyzedOffset
            + (update.committedUnanalyzedPhotoCount ?? 0)
        scanActivityMessage = update.statusMessage
        let replacedIDs = update.evaluatedAssetIDs
        let unaffectedGroups = preservingGroups.filter { group in
            replacedIDs.isDisjoint(
                with: group.assets.map(\.localIdentifier)
            )
        }
        let nextGroups = unaffectedGroups + update.groups
        let nextScreenshots = PhotoAssetIdentity.unique(
            preservingScreenshots.filter {
                !replacedIDs.contains($0.localIdentifier)
            } + update.screenshotAssets
        )
        let nextBlurryAssets = PhotoAssetIdentity.unique(
            preservingBlurryAssets.filter {
                !replacedIDs.contains($0.localIdentifier)
            } + update.blurryAssets
        )
        if photoGroups.contentSignature != nextGroups.contentSignature {
            photoGroups = nextGroups
        }
        if screenshotAssets.identifierSignature != nextScreenshots.identifierSignature {
            screenshotAssets = nextScreenshots
        }
        if blurryAssets.identifierSignature != nextBlurryAssets.identifierSignature {
            blurryAssets = nextBlurryAssets
        }
        groupsFoundCount = photoGroups.count
        reviewablePhotosCount = PhotoReviewCategoryClassifier.reviewableCount(
            groups: photoGroups,
            screenshotAssets: screenshotAssets,
            blurryAssets: blurryAssets
        )
        reclaimableBytesFoundSoFar = photoGroups.totalReclaimableBytes
        if hasPartialResults != update.hasPartialResults {
            hasPartialResults = update.hasPartialResults
        }
        let nextIsReadyForReview = !photoGroups.isEmpty
            || !screenshotAssets.isEmpty
            || !blurryAssets.isEmpty
        if isReadyForReview != nextIsReadyForReview {
            isReadyForReview = nextIsReadyForReview
        }
        updateScanRate(processedCount: update.processedPhotoCount)
        let nextScanState: ScanState = update.isComplete
            ? .completed
            : (isPaused ? .paused : .scanning)
        if scanState != nextScanState {
            scanState = nextScanState
        }
        if resultsFreshnessState != .live {
            resultsFreshnessState = .live
        }
        publishProgressSnapshot()
        recordPhotoProgressIfNeeded(isCompleteUpdate: update.isComplete)

        // Cheap UserDefaults progress and expensive full JSON checkpoints have
        // independent cadences.
        let now = Date()
        if update.isComplete || isPaused || now.timeIntervalSince(lastPersistTime) >= 3 {
            persistCleanupState()
            lastPersistTime = now
        }
        if update.isComplete
            || isPaused
            || now.timeIntervalSince(lastCheckpointTime)
                >= ScanPersistenceTuning.periodicCheckpointInterval {
            lastCheckpointTime = now
            return makeAnalysisSnapshot(isComplete: update.isComplete)
        }

        return nil
    }

    private func scanSupportingCategoriesIfNeeded(scanID: UUID) async {
        // Keep system permission prompts serialized. Concurrent Photos and
        guard !Task.isCancelled, activeScanID == scanID else { return }
        await scanFiles()
        guard !Task.isCancelled, activeScanID == scanID else { return }
    }

    private func startSupportingScansAfterSuccessfulPhotoScan(
        scanID: UUID
    ) {
        guard !startedSupportingScansForActiveScan,
              supportingScansTask == nil else {
            return
        }
        startedSupportingScansForActiveScan = true
        isFinishingSupportingScans = true
        recordDiagnostic(
            .supportingScans(
                action: .started,
                fileState: fileScanState.rawValue
            )
        )
        supportingScansTask = Task { [weak self] in
            await self?.scanSupportingCategoriesIfNeeded(scanID: scanID)
            await MainActor.run { [weak self] in
                guard self?.activeScanID == scanID else { return }
                self?.isFinishingSupportingScans = false
                if let self {
                    self.recordDiagnostic(
                        .supportingScans(
                            action: .finished,
                            fileState: self.fileScanState.rawValue
                        )
                    )
                }
                self?.supportingScansTask = nil
            }
        }
    }

    private func schedulePhotoLibraryRefresh() {
        libraryChangeTask?.cancel()
        libraryChangeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.reconcilePhotoLibraryChange()
        }
    }

    private func reconcilePhotoLibraryChange() async {
        if isFinalizingPhotoScan {
            // The active scan owns its inventory and already checkpoints on its
            // committed cadence. A PhotoKit callback during restore/planning
            // must not serialize half-prepared scalar state over that checkpoint.
            persistCleanupState()
            return
        }
        if scanState == .scanning || scanState == .paused {
            // PhotoKit can report metadata changes while a scan is active.
            // Never let that observer mutate, finalize, restart, or expand the
            // inventory recorded by the active checkpoint. A post-scan/active
            // refresh will select the new or changed assets explicitly.
            persistCleanupState()
            if hasHydratedAnalysisCache {
                await mlBridge.flushBufferedWrites()
                await analysisCache.scheduleSnapshot(
                    makeAnalysisSnapshot(isComplete: false)
                )
            }
            return
        }

        let photoIDs = Set(photoGroups.flatMap(\.assets).map(\.localIdentifier))
            .union(screenshotAssets.map(\.localIdentifier))
            .union(blurryAssets.map(\.localIdentifier))
        let fileAssetIDs = Set(largeFiles.map(\.photoAsset.localIdentifier))
        let validIDs = await existingAssetIdentifiers(photoIDs.union(fileAssetIDs))

        photoGroups = photoGroups.compactMap { group in
            let survivingAssets = group.assets.filter { validIDs.contains($0.localIdentifier) }
            guard survivingAssets.count >= 2 else { return nil }
            return PhotoGroup(
                id: group.id,
                assets: survivingAssets,
                similarity: group.similarity,
                reason: group.reason,
                groupType: group.groupType,
                groupConfidence: group.groupConfidence,
                reviewState: group.reviewState,
                recommendedAction: group.recommendedAction,
                keeperAssetID: group.keeperAssetID,
                deleteCandidateIDs: group.deleteCandidateIDs.filter(validIDs.contains),
                bestShotPhotoId: group.bestShotPhotoId,
                groupReasonsSummary: group.groupReasonsSummary,
                blockerFlags: group.blockerFlags,
                scoreBreakdown: group.scoreBreakdown,
                preferenceQueuePriority: group.preferenceQueuePriority,
                preferenceAdjustmentReasons: group.preferenceAdjustmentReasons,
                captureDateRange: nil,
                candidates: group.candidates.filter { validIDs.contains($0.photoId) },
                reclaimableBytes: nil
            )
        }
        largeFiles.removeAll { !validIDs.contains($0.photoAsset.localIdentifier) }
        screenshotAssets.removeAll { !validIDs.contains($0.localIdentifier) }
        blurryAssets.removeAll { !validIDs.contains($0.localIdentifier) }

        groupsFoundCount = photoGroups.count
        reviewablePhotosCount = PhotoReviewCategoryClassifier.reviewableCount(
            groups: photoGroups,
            screenshotAssets: screenshotAssets,
            blurryAssets: blurryAssets
        )
        reclaimableBytesFoundSoFar = photoGroups.totalReclaimableBytes
        lastCompletedGroupsCount = groupsFoundCount
        lastCompletedReviewableCount = reviewablePhotosCount
        lastCompletedReclaimableBytes = reclaimableBytesFoundSoFar
        hasPartialResults = reviewablePhotosCount > 0
        isReadyForReview = reviewablePhotosCount > 0
        resultsFreshnessState = .stale
        _storageInfo = nil
        publishProgressSnapshot()
        await refreshLibraryMetadata()
        persistCleanupState()
        guard hasHydratedAnalysisCache else {
            // A PhotoKit change can arrive before the cached analysis has been
            // rehydrated. Writing a snapshot from this half-restored state
            // would persist empty groups as a *complete* result — with a newer
            // generation than the good snapshot — destroying the cache and
            // forcing a full rescan. Reconcile only after hydration.
            return
        }
        if let snapshot = await analysisCache.loadSnapshot(),
           !assetIDsRequiringAnalysis(comparedTo: snapshot).isEmpty {
            await scanPhotos(mode: lastCompletedMode ?? snapshot.cleanupMode)
        } else {
            saveAnalysisSnapshot(isComplete: true)
        }
    }

    private func scanNewPhotosIfNeeded() async {
        // An explicit scan owns restoration and metadata planning before
        // `scanTask` exists. Do not let bootstrap work supersede it in that gap.
        guard !isFinalizingPhotoScan else { return }
        guard scanTask == nil,
              scanState == .completed || scanState == .idle,
              photoAuthorizationStatus == .authorized
                || photoAuthorizationStatus == .limited,
              let snapshot = await analysisCache.loadSnapshot(),
              !snapshot.libraryAssetIdentifiers.isEmpty else {
            guard !isFinalizingPhotoScan else { return }
            await refreshLibraryMetadata()
            return
        }

        guard !isFinalizingPhotoScan else { return }
        await refreshLibraryMetadata()
        guard !isFinalizingPhotoScan else { return }
        guard !assetIDsRequiringAnalysis(comparedTo: snapshot).isEmpty else {
            return
        }

        await scanPhotos(
            mode: lastCompletedMode ?? snapshot.cleanupMode
        )
    }

    private func assetIDsRequiringAnalysis(
        comparedTo snapshot: CachedPhotoAnalysisSnapshot
    ) -> Set<String> {
        let cachedIDs = Set(snapshot.libraryAssetIdentifiers)
        let cachedMetadata = Dictionary(
            uniqueKeysWithValues: snapshot.libraryAssets.map {
                ($0.localIdentifier, $0)
            }
        )
        let newIDs = knownLibraryAssetIdentifiers.subtracting(cachedIDs)
        let modifiedIDs = Set<String>(
            knownLibraryAssetMetadata.compactMap { entry -> String? in
                let (id, metadata) = entry
                guard let cached = cachedMetadata[id] else { return nil }
                return cached == metadata ? nil : id
            }
        )
        return newIDs.union(modifiedIDs)
    }

    private func existingAssetIdentifiers(_ identifiers: Set<String>) async -> Set<String> {
        guard !identifiers.isEmpty else { return [] }
        return await Task.detached(priority: .utility) {
            let result = PHAsset.fetchAssets(withLocalIdentifiers: Array(identifiers), options: nil)
            var existing = Set<String>()
            result.enumerateObjects { asset, _, _ in
                existing.insert(asset.localIdentifier)
            }
            return existing
        }.value
    }

    private func updateScanRate(processedCount: Int) {
        let now = Date()
        guard let lastRateSampleAt else {
            self.lastRateSampleAt = now
            lastRateSampleProcessedCount = processedCount
            return
        }

        let elapsed = now.timeIntervalSince(lastRateSampleAt)
        guard elapsed >= 0.35 else { return }

        let processedDelta = max(processedCount - lastRateSampleProcessedCount, 0)
        if processedDelta > 0 {
            let instantaneousRate = Double(processedDelta) / elapsed * 60
            scanRatePhotosPerMinute = scanRatePhotosPerMinute == 0
                ? instantaneousRate
                : (scanRatePhotosPerMinute * 0.65) + (instantaneousRate * 0.35)
        }

        self.lastRateSampleAt = now
        lastRateSampleProcessedCount = processedCount
    }

    private func saveAnalysisSnapshot(isComplete: Bool) {
        let snapshot = makeAnalysisSnapshot(isComplete: isComplete)

        let groupAssets = snapshot.isComplete ? photoGroups.flatMap(\.assets) : []
        Task(priority: .utility) { [weak self, analysisCache, mlBridge] in
            await analysisCache.saveSnapshot(snapshot)
            if !groupAssets.isEmpty {
                let featureRecords = await Task.detached(priority: .utility) {
                    mlBridge.makeFeatureRecords(for: groupAssets, embeddings: [:])
                }.value
                await mlBridge.persistFeatureRecords(featureRecords)
            }
            await self?.refreshPersistenceHealth()
        }
    }

    private func makeAnalysisSnapshot(
        isComplete: Bool
    ) -> CachedPhotoAnalysisSnapshot {
        let hasCompletedTarget: Bool
        if libraryTotalCount == 0 {
            hasCompletedTarget = knownLibraryAssetIdentifiers.isEmpty
                && scanTargetCount == 0
                && processedPhotoCount == 0
        } else {
            hasCompletedTarget = scanTargetCount > 0
                && processedPhotoCount >= scanTargetCount
                && progressFraction >= 0.999
        }
        let snapshotIsComplete = isComplete
            && scanState == .completed
            && hasCompletedTarget
        let snapshotProcessedCount = snapshotIsComplete
            ? processedPhotoCount
            : checkpointProcessedPhotoCount
        let snapshotAnalyzedCount = snapshotIsComplete
            ? analyzedPhotoCount
            : checkpointAnalyzedPhotoCount
        let snapshotUnanalyzedCount = snapshotIsComplete
            ? unanalyzedPhotoCount
            : checkpointUnanalyzedPhotoCount
        let snapshotProgress = scanTargetCount == 0
            ? 1
            : min(Double(snapshotProcessedCount) / Double(scanTargetCount), 1)

        return CachedPhotoAnalysisSnapshot(
            libraryTotalCount: libraryTotalCount,
            scanTargetCount: scanTargetCount,
            processedPhotoCount: snapshotProcessedCount,
            analyzedPhotoCount: snapshotAnalyzedCount,
            unanalyzedPhotoCount: snapshotUnanalyzedCount,
            progressFraction: snapshotProgress,
            groupsFoundCount: groupsFoundCount,
            reviewablePhotosCount: reviewablePhotosCount,
            reclaimableBytesFoundSoFar: reclaimableBytesFoundSoFar,
            cleanupMode: cleanupMode,
            resultsFreshnessState: .lastKnown,
            isComplete: snapshotIsComplete,
            evaluatedAssetIdentifiers: checkpointEvaluatedAssetIDs.sorted(),
            scanTargetAssetIdentifiers: snapshotIsComplete
                ? []
                : checkpointTargetAssetIDs.sorted(),
            unanalyzedAssetIdentifiers: checkpointUnanalyzedAssetIDs.sorted(),
            groups: photoGroups.map { group in
                CachedPhotoGroup(
                    id: group.id,
                    assetIdentifiers: group.assets.map(\.localIdentifier),
                    similarity: group.similarity,
                    reason: group.reason,
                    groupType: group.groupType,
                    groupConfidence: group.groupConfidence,
                    reviewState: group.reviewState,
                    recommendedAction: group.recommendedAction,
                    keeperAssetID: group.keeperAssetID,
                    deleteCandidateIDs: group.deleteCandidateIDs,
                    bestShotPhotoId: group.bestShotPhotoId,
                    groupReasonsSummary: group.groupReasonsSummary,
                    blockerFlags: group.blockerFlags,
                    scoreBreakdown: group.scoreBreakdown,
                    preferenceQueuePriority: group.preferenceQueuePriority,
                    preferenceAdjustmentReasons: group.preferenceAdjustmentReasons,
                    captureDateStart: group.captureDateRange?.start,
                    captureDateEnd: group.captureDateRange?.end,
                    candidates: group.candidates.map {
                        CachedSimilarPhotoCandidate(
                            photoId: $0.photoId,
                            assetReference: $0.assetReference,
                            captureTimestamp: $0.captureTimestamp,
                            isBestShot: $0.isBestShot,
                            bestShotScore: $0.bestShotScore,
                            bestShotReasons: $0.bestShotReasons,
                            issueFlags: $0.issueFlags,
                            isProtected: $0.isProtected,
                            isSelectedForTrash: $0.isSelectedForTrash,
                            isViewed: $0.isViewed,
                            selectionState: $0.selectionState,
                            technicalScores: $0.technicalScores
                        )
                    },
                    reclaimableBytes: group.reclaimableBytes
                )
            },
            screenshotAssetIdentifiers: screenshotAssets.map(\.localIdentifier),
            blurryAssetIdentifiers: blurryAssets.map(\.localIdentifier),
            libraryAssetIdentifiers: knownLibraryAssetIdentifiers.sorted(),
            libraryAssets: knownLibraryAssetMetadata.values.sorted {
                $0.localIdentifier < $1.localIdentifier
            }
        )
    }

    private func restoreCachedAnalysisIfNeeded() async {
        if hasHydratedAnalysisCache {
            return
        }
        if let analysisCacheHydrationTask {
            await analysisCacheHydrationTask.value
            return
        }

        let hydrationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performCachedAnalysisRestore()
            self.hasHydratedAnalysisCache = true
            self.analysisCacheHydrationTask = nil
        }
        analysisCacheHydrationTask = hydrationTask
        await hydrationTask.value
    }

    private func restoreCachedLargeVideosIfNeeded() async {
        if hasHydratedLargeVideoCache {
            return
        }
        if let largeVideoCacheHydrationTask {
            await largeVideoCacheHydrationTask.value
            return
        }

        let hydrationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performCachedLargeVideoRestore()
            self.hasHydratedLargeVideoCache = true
            self.largeVideoCacheHydrationTask = nil
        }
        largeVideoCacheHydrationTask = hydrationTask
        await hydrationTask.value
    }

    private func performCachedLargeVideoRestore() async {
        guard largeFiles.isEmpty,
              photoAuthorizationStatus == .authorized
                || photoAuthorizationStatus == .limited,
              let restored = await largeVideoResultCache.restoreFiles()
        else {
            return
        }

        largeFiles = restored.files
        fileScanState = .completed
        fileScanProgress = FileScanProgress(
            totalVideoCount: restored.totalVideoCount,
            processedVideoCount: restored.totalVideoCount,
            cacheHitCount: restored.totalVideoCount,
            isComplete: true,
            statusMessage: restored.files.isEmpty
                ? "No large videos in the saved scan."
                : "\(restored.files.count.formatted()) large videos restored."
        )

        if restored.missingResultCount > 0 {
            await largeVideoResultCache.save(
                files: restored.files,
                totalVideoCount: restored.totalVideoCount
            )
        }
        publishProgressSnapshot()
    }

    private func performCachedAnalysisRestore() async {
        guard photoGroups.isEmpty else { return }
        guard let snapshot = await analysisCache.loadSnapshot() else { return }

        let restoredGroups = await analysisCache.rehydrateGroups(from: snapshot)
        let restoredScreenshots = await analysisCache.rehydrateAssets(
            with: snapshot.screenshotAssetIdentifiers
        )
        let restoredBlurryAssets = await analysisCache.rehydrateAssets(
            with: snapshot.blurryAssetIdentifiers
        )
        photoGroups = restoredGroups
        screenshotAssets = restoredScreenshots
        blurryAssets = restoredBlurryAssets
        cleanupMode = snapshot.cleanupMode
        let snapshotIsComplete = snapshot.isComplete
            && snapshot.hasConsistentCompletionState
        scanState = snapshotIsComplete ? .completed : .paused
        isPaused = !snapshotIsComplete
        isBackgroundExecutionState = false
        processedPhotoCount = snapshot.processedPhotoCount
        analyzedPhotoCount = snapshot.analyzedPhotoCount
        checkpointUnanalyzedAssetIDs = Set(snapshot.unanalyzedAssetIdentifiers)
        unanalyzedPhotoCount = max(
            snapshot.unanalyzedPhotoCount,
            checkpointUnanalyzedAssetIDs.count
        )
        scanTargetCount = snapshot.scanTargetCount
        progressFraction = snapshot.progressFraction
        groupsFoundCount = restoredGroups.count
        reviewablePhotosCount = PhotoReviewCategoryClassifier.reviewableCount(
            groups: restoredGroups,
            screenshotAssets: restoredScreenshots,
            blurryAssets: restoredBlurryAssets
        )
        // Rehydrated groups are review-only until a live scan revalidates them.
        reclaimableBytesFoundSoFar = restoredGroups.totalReclaimableBytes
        hasPartialResults = reviewablePhotosCount > 0
        isReadyForReview = reviewablePhotosCount > 0
        lastCompletedAt = snapshot.savedAt
        lastCompletedMode = snapshot.cleanupMode
        lastCompletedLibraryTotalCount = snapshot.libraryTotalCount
        lastCompletedScanTargetCount = snapshot.scanTargetCount
        lastCompletedGroupsCount = groupsFoundCount
        lastCompletedReviewableCount = reviewablePhotosCount
        lastCompletedReclaimableBytes = reclaimableBytesFoundSoFar
        knownLibraryAssetIdentifiers = Set(snapshot.libraryAssetIdentifiers)
        knownLibraryAssetMetadata = Dictionary(
            uniqueKeysWithValues: snapshot.libraryAssets.map {
                ($0.localIdentifier, $0)
            }
        )
        checkpointEvaluatedAssetIDs = snapshotIsComplete
            ? Set(snapshot.evaluatedAssetIdentifiers)
            : Set(
                snapshot.hasConsistentCompletionState
                    ? snapshot.evaluatedAssetIdentifiers
                    : []
            )
        checkpointTargetAssetIDs = snapshotIsComplete
            ? []
            : Set(
                snapshot.hasConsistentCompletionState
                    ? snapshot.scanTargetAssetIdentifiers
                    : []
            )
        checkpointProcessedPhotoCount = snapshot.processedPhotoCount
        checkpointAnalyzedPhotoCount = snapshot.analyzedPhotoCount
        checkpointUnanalyzedPhotoCount = snapshot.unanalyzedPhotoCount
        resultsFreshnessState = .lastKnown
        publishProgressSnapshot()
        persistCleanupState()
        recordDiagnostic(
            .restoredState(
                scanState: scanState.rawValue,
                processedCount: processedPhotoCount,
                targetCount: scanTargetCount,
                hasCompletionDate: lastCompletedAt != nil
            )
        )
    }

    private func repairPrematureCompletion(
        _ snapshot: CachedPhotoAnalysisSnapshot
    ) async -> CachedPhotoAnalysisSnapshot? {
        guard snapshot.cleanupMode == .deepClean,
              snapshot.processedPhotoCount > 0 else {
            return nil
        }

        let orderedIDs = await Task.detached(priority: .utility) {
            let result = PHAsset.fetchAssets(with: .image, options: nil)
            var assets: [PHAsset] = []
            assets.reserveCapacity(result.count)
            result.enumerateObjects { asset, _, _ in
                assets.append(asset)
            }
            return assets.sortedByCreationDate().map(\.localIdentifier)
        }.value
        guard Set(snapshot.libraryAssetIdentifiers)
                == knownLibraryAssetIdentifiers,
              Set(orderedIDs) == knownLibraryAssetIdentifiers,
              snapshot.processedPhotoCount < orderedIDs.count else {
            return nil
        }

        // Deep Clean's chronological ordering is deterministic, so the prefix
        // is the only safe reconstruction available for the legacy race.
        let evaluatedIDs = Array(
            orderedIDs.prefix(snapshot.processedPhotoCount)
        )
        return snapshot.repairingPrematureCompletion(
            evaluatedAssetIdentifiers: evaluatedIDs,
            scanTargetAssetIdentifiers: orderedIDs
        )
    }

    private func refreshPersistenceHealth() async {
        let cacheIsHealthy = await analysisCache.persistenceHealthy
        if !cacheIsHealthy {
            persistenceWarningMessage =
                "PhotoDuck could not save scan progress. Free a little storage before relying on cached results."
            return
        }

        if let mlFailure = await mlBridge.consumePersistenceFailureNotice() {
            persistenceWarningMessage =
                "Personalization data could not be saved (\(mlFailure)). Free a little storage and try again."
        } else {
            persistenceWarningMessage = nil
        }
    }

    private func maybeScheduleNotification(key: String, title: String, body: String) {
        guard notificationEligible else { return }
        guard lastNotificationKey != key else { return }
        lastNotificationKey = key
        persistCleanupState()
        CleanupNotificationScheduler.shared.schedule(title: title, body: body, target: .reviewResults)
    }

    private func refreshNotificationAuthorization() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationEligible = settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
            || settings.authorizationStatus == .ephemeral
    }

    private func notificationKey(for mode: CleanupMode, completed: Bool) -> String {
        "\(mode.rawValue)-\(completed ? "complete" : "partial")"
    }

    // MARK: - Persistence

    private func persistCleanupState() {
        // A final PhotoScanUpdate arrives before the worker finishes retention,
        // flushes, and stamps the new completion time. Persist that narrow
        // window as resumable work so a process kill cannot resurrect a
        // completed screen with the previous scan's timestamp.
        let durableScanState: ScanState =
            isFinalizingPhotoScan && scanState == .completed
                ? .scanning
                : scanState
        let snapshot = PersistedCleanupState(
            cleanupMode: cleanupMode,
            scanState: durableScanState,
            isPaused: isPaused,
            isBackgroundExecutionState: isBackgroundExecutionState,
            libraryTotalCount: libraryTotalCount,
            scanTargetCount: scanTargetCount,
            processedPhotoCount: processedPhotoCount,
            analyzedPhotoCount: analyzedPhotoCount,
            unanalyzedPhotoCount: unanalyzedPhotoCount,
            progressFraction: progressFraction,
            groupsFoundCount: groupsFoundCount,
            reviewablePhotosCount: reviewablePhotosCount,
            reclaimableBytesFoundSoFar: reclaimableBytesFoundSoFar,
            hasPartialResults: hasPartialResults,
            isReadyForReview: isReadyForReview,
            lastCompletedAt: lastCompletedAt,
            lastCompletedMode: lastCompletedMode,
            lastCompletedLibraryTotalCount: lastCompletedLibraryTotalCount,
            lastCompletedScanTargetCount: lastCompletedScanTargetCount,
            lastCompletedGroupsCount: lastCompletedGroupsCount,
            lastCompletedReviewableCount: lastCompletedReviewableCount,
            lastCompletedReclaimableBytes: lastCompletedReclaimableBytes,
            resultsFreshnessState: resultsFreshnessState,
            lastNotificationKey: lastNotificationKey
        )

        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: PersistenceKey.cleanupState)
    }

    func makeDiagnosticReport() async throws -> URL {
        let cachedSnapshot = await analysisCache.loadSnapshot()
        let cacheIsHealthy = await analysisCache.persistenceHealthy
        let checkpoint = cachedSnapshot.map {
            PhotoDuckDiagnosticCheckpointSummary(
                schemaVersion: $0.schemaVersion,
                generation: $0.persistenceGeneration,
                savedAt: $0.savedAt,
                libraryCount: $0.libraryTotalCount,
                targetCount: $0.scanTargetCount,
                processedCount: $0.processedPhotoCount,
                analyzedCount: $0.analyzedPhotoCount,
                unanalyzedCount: $0.unanalyzedPhotoCount,
                groupCount: $0.groupsFoundCount,
                reviewableCount: $0.reviewablePhotosCount,
                evaluatedIdentifierCount:
                    $0.evaluatedAssetIdentifiers.count,
                plannedIdentifierCount:
                    $0.scanTargetAssetIdentifiers.count,
                isComplete: $0.isComplete,
                isConsistent: $0.hasConsistentCompletionState
            )
        }
        let info = Bundle.main.infoDictionary
        let snapshot = PhotoDuckDiagnosticReportSnapshot(
            generatedAt: Date(),
            appVersion:
                info?["CFBundleShortVersionString"] as? String ?? "unknown",
            buildVersion:
                info?["CFBundleVersion"] as? String ?? "unknown",
            osVersion:
                "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            deviceModel: UIDevice.current.model,
            photoAuthorization:
                diagnosticAuthorizationLabel(photoAuthorizationStatus),
            scanState: scanState.rawValue,
            cleanupMode: cleanupMode.rawValue,
            freshnessState: resultsFreshnessState.rawValue,
            isPaused: isPaused,
            isFinalizingPhotoScan: isFinalizingPhotoScan,
            isFinishingSupportingScans: isFinishingSupportingScans,
            libraryCount: libraryTotalCount,
            targetCount: scanTargetCount,
            processedCount: processedPhotoCount,
            analyzedCount: analyzedPhotoCount,
            unanalyzedCount: unanalyzedPhotoCount,
            groupCount: groupsFoundCount,
            reviewableCount: reviewablePhotosCount,
            reclaimablePhotoBytes:
                dashboardSummary.reclaimablePhotoBytes,
            lastCompletedAt: lastCompletedAt,
            fileScanState: fileScanState.rawValue,
            videoTotalCount: fileScanProgress.totalVideoCount,
            videoProcessedCount: fileScanProgress.processedVideoCount,
            videoCacheHitCount: fileScanProgress.cacheHitCount,
            qualifyingLargeVideoCount: largeFiles.count,
            qualifyingLargeVideoBytes: dashboardSummary.largeFileBytes,
            cachePersistenceHealthy: cacheIsHealthy,
            checkpoint: checkpoint
        )
        // All events queued before this snapshot must be durable before the
        // actor reads its ring for export. This makes terminal scan evidence
        // deterministic even when the user shares immediately after failure.
        let diagnosticUptimeCutoff = ProcessInfo.processInfo.systemUptime
        let pendingWrite = diagnosticWriteTask
        await pendingWrite?.value
        return try await PhotoDuckDiagnosticLog.shared.exportReport(
            snapshot: snapshot,
            currentSessionUptimeCutoff: diagnosticUptimeCutoff
        )
    }

    private func diagnosticAuthorizationLabel(
        _ status: PHAuthorizationStatus
    ) -> String {
        switch status {
        case .notDetermined:
            return "not_determined"
        case .restricted:
            return "restricted"
        case .denied:
            return "denied"
        case .authorized:
            return "authorized"
        case .limited:
            return "limited"
        @unknown default:
            return "unknown"
        }
    }

    func learningDebugSummary() async -> String {
        let lines = await PhotoFeedbackStore.shared.feedbackSummaryLines()
        var mlLines: [String] = []
        do {
            let stats = try await mlBridge.stats()
            mlLines = [
                "--- ML Store ---",
                "features=\(stats.featureCount) embeddings=\(stats.embeddingCount)",
                "pairs=\(stats.pairCount) feedback=\(stats.feedbackEventCount)",
                "training=\(stats.trainingRowCount) (keeper=\(stats.keeperRowCount) group=\(stats.groupOutcomeRowCount))",
                "db=\(stats.formattedSize)"
            ]
        } catch {
            mlLines = ["ML Store: \(error.localizedDescription)"]
        }
        return (lines + mlLines).joined(separator: "\n")
    }

    private func loadPersistedCleanupState() {
        guard
            let data = UserDefaults.standard.data(forKey: PersistenceKey.cleanupState),
            let snapshot = try? JSONDecoder().decode(PersistedCleanupState.self, from: data)
        else {
            return
        }

        cleanupMode = snapshot.cleanupMode
        scanState = snapshot.scanState
        isPaused = snapshot.isPaused
        isBackgroundExecutionState = snapshot.isBackgroundExecutionState
        libraryTotalCount = snapshot.libraryTotalCount
        scanTargetCount = snapshot.scanTargetCount
        processedPhotoCount = snapshot.processedPhotoCount
        analyzedPhotoCount = snapshot.analyzedPhotoCount ?? snapshot.processedPhotoCount
        unanalyzedPhotoCount = snapshot.unanalyzedPhotoCount ?? 0
        progressFraction = snapshot.progressFraction
        groupsFoundCount = snapshot.groupsFoundCount
        reviewablePhotosCount = snapshot.reviewablePhotosCount
        reclaimableBytesFoundSoFar = snapshot.reclaimableBytesFoundSoFar
        hasPartialResults = snapshot.hasPartialResults
        isReadyForReview = snapshot.isReadyForReview
        lastCompletedAt = snapshot.lastCompletedAt
        lastCompletedMode = snapshot.lastCompletedMode
        lastCompletedLibraryTotalCount = snapshot.lastCompletedLibraryTotalCount
        lastCompletedScanTargetCount = snapshot.lastCompletedScanTargetCount
        lastCompletedGroupsCount = snapshot.lastCompletedGroupsCount
        lastCompletedReviewableCount = snapshot.lastCompletedReviewableCount
        lastCompletedReclaimableBytes = snapshot.lastCompletedReclaimableBytes
        resultsFreshnessState = snapshot.resultsFreshnessState
        lastNotificationKey = snapshot.lastNotificationKey

        if scanState == .scanning {
            scanState = .paused
            isPaused = true
            resultsFreshnessState = .lastKnown
        }

    }

    // MARK: - Utilities

    private func currentLibraryPhotoMetadata() async
        -> [String: CachedPhotoAssetMetadata] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = PHAsset.fetchAssets(with: .image, options: nil)
                var metadataByID: [String: CachedPhotoAssetMetadata] = [:]
                metadataByID.reserveCapacity(result.count)
                result.enumerateObjects { asset, _, _ in
                    metadataByID[asset.localIdentifier] =
                        CachedPhotoAssetMetadata(
                            localIdentifier: asset.localIdentifier,
                            modificationDate: asset.modificationDate,
                            pixelWidth: asset.pixelWidth,
                            pixelHeight: asset.pixelHeight,
                            mediaSubtypesRawValue: asset.mediaSubtypes.rawValue
                        )
                }
                continuation.resume(returning: metadataByID)
            }
        }
    }
}

private struct PhotoGroupContentSignature: Equatable {
    let id: UUID
    let assetIDs: [String]
    let keeperAssetID: String?
    let deleteCandidateIDs: [String]
    let similarity: Float
    let reason: PhotoGroup.SimilarityReason
    let groupType: SimilarGroupType
    let groupConfidence: SimilarGroupConfidence
    let reviewState: SimilarReviewState
    let recommendedAction: SimilarRecommendedAction?
    let reclaimableBytes: Int64
}

private extension Array where Element == PhotoGroup {
    var contentSignature: [PhotoGroupContentSignature] {
        map {
            PhotoGroupContentSignature(
                id: $0.id,
                assetIDs: $0.assets.map(\.localIdentifier),
                keeperAssetID: $0.keeperAssetID,
                deleteCandidateIDs: $0.deleteCandidateIDs,
                similarity: $0.similarity,
                reason: $0.reason,
                groupType: $0.groupType,
                groupConfidence: $0.groupConfidence,
                reviewState: $0.reviewState,
                recommendedAction: $0.recommendedAction,
                reclaimableBytes: $0.reclaimableBytes
            )
        }
    }
}

private extension Array where Element == PHAsset {
    var identifierSignature: [String] {
        map(\.localIdentifier)
    }
}

// MARK: - Notifications

enum CleanupReviewTarget: String, Sendable {
    case reviewResults
}

@MainActor
final class CleanupNotificationScheduler {
    static let shared = CleanupNotificationScheduler()
    private init() {}

    func schedule(title: String, body: String, target: CleanupReviewTarget) {
        Task { @MainActor in
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional
                    || settings.authorizationStatus == .ephemeral else { return }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.userInfo = ["cleanupTarget": target.rawValue]

            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            try? await UNUserNotificationCenter.current().add(request)
        }
    }
}

private extension UIViewController {
    var topmostPresentedViewController: UIViewController {
        if let presentedViewController {
            return presentedViewController.topmostPresentedViewController
        }
        if let navigationController = self as? UINavigationController,
           let visibleViewController = navigationController.visibleViewController {
            return visibleViewController.topmostPresentedViewController
        }
        if let tabBarController = self as? UITabBarController,
           let selectedViewController = tabBarController.selectedViewController {
            return selectedViewController.topmostPresentedViewController
        }
        return self
    }
}
