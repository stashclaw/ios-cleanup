import Foundation
import Contacts
import Photos
import PhotosUI
import SwiftUI
import UIKit
import UserNotifications

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

@MainActor
final class HomeViewModel: ObservableObject {

    enum ScanState: String, Codable {
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

    // MARK: - Legacy scan states kept for the existing contact/file surfaces

    @Published var photoGroups: [PhotoGroup] = []
    @Published var screenshotAssets: [PHAsset] = []
    @Published var blurryAssets: [PHAsset] = []
    @Published var contactMatches: [ContactMatch] = []
    @Published var largeFiles: [LargeFile] = []

    @Published var contactScanState: ScanState = .idle
    @Published var fileScanState: ScanState = .idle

    // MARK: - Cleanup dashboard state

    @Published var cleanupMode: CleanupMode = .deepClean
    @Published var scanState: ScanState = .idle
    @Published var isPaused: Bool = false
    @Published var isBackgroundExecutionState: Bool = false
    @Published var hasPartialResults: Bool = false
    @Published var isReadyForReview: Bool = false
    @Published var resultsFreshnessState: CleanupResultsFreshnessState = .live
    @Published var lastCompletedAt: Date?
    @Published var notificationEligible: Bool = false
    @Published private(set) var persistenceWarningMessage: String?
    @Published private(set) var photoAuthorizationStatus: PHAuthorizationStatus =
        PHPhotoLibrary.authorizationStatus(for: .readWrite)

    @Published var libraryTotalCount: Int = 0
    @Published var scanTargetCount: Int = 0
    @Published var processedPhotoCount: Int = 0
    @Published var analyzedPhotoCount: Int = 0
    @Published var unanalyzedPhotoCount: Int = 0
    @Published var progressFraction: Double = 0
    @Published var scanRatePhotosPerMinute: Double = 0
    @Published var groupsFoundCount: Int = 0
    @Published var reviewablePhotosCount: Int = 0
    @Published var reclaimableBytesFoundSoFar: Int64 = 0

    @Published var lastCompletedMode: CleanupMode?
    @Published var lastCompletedLibraryTotalCount: Int = 0
    @Published var lastCompletedScanTargetCount: Int = 0
    @Published var lastCompletedGroupsCount: Int = 0
    @Published var lastCompletedReviewableCount: Int = 0
    @Published var lastCompletedReclaimableBytes: Int64 = 0

    @Published var scanErrorMessage: String?

    private var scanTask: Task<Void, Never>?
    private var libraryChangeTask: Task<Void, Never>?
    private var activePhotoScanEngine: PhotoScanEngine?
    private var activeScanID: UUID?
    private var lastNotificationKey: String?
    private var lastPersistTime: Date = .distantPast
    private var lastRateSampleAt: Date?
    private var lastRateSampleProcessedCount = 0
    private var startedSupportingScansForActiveScan = false
    private var knownLibraryAssetIdentifiers: Set<String> = []
    private var knownLibraryAssetMetadata: [String: CachedPhotoAssetMetadata] = [:]
    private let analysisCache = PhotoAnalysisCache.shared
    private let mlBridge = PhotoMLBridge.shared
    private lazy var photoLibraryObserver = PhotoLibraryChangeObserverProxy { [weak self] in
        Task { @MainActor [weak self] in
            self?.schedulePhotoLibraryRefresh()
        }
    }

    init() {
        loadPersistedCleanupState()
        _ = photoLibraryObserver
        Task(priority: .utility) {
            await restoreCachedAnalysisIfNeeded()
            await scanNewPhotosIfNeeded()
            await refreshPersistenceHealth()
            await refreshNotificationAuthorization()
        }
    }

    // MARK: - Legacy helpers

    var photoScanState: ScanState { scanState }

    var reclaimableBytes: Int64 {
        let fromFiles  = largeFiles.reduce(Int64(0)) { $0 + $1.byteSize }
        let fromPhotos = photoGroups.reduce(Int64(0)) { $0 + $1.reclaimableBytes }
        return fromFiles + fromPhotos
    }

    var reclaimableFormatted: String {
        ByteCountFormatter.string(fromByteCount: reclaimableBytes, countStyle: .file)
    }

    var hasAnyResult: Bool {
        !photoGroups.isEmpty
            || !screenshotAssets.isEmpty
            || !blurryAssets.isEmpty
            || !contactMatches.isEmpty
            || !largeFiles.isEmpty
    }

    var photoReviewCategoryCount: Int {
        screenshotAssets.count + blurryAssets.count
    }

    var isAnyScanning: Bool {
        scanState == .scanning || contactScanState == .scanning || fileScanState == .scanning
    }

    var isAllDone: Bool {
        let states = [scanState, contactScanState, fileScanState]
        return states.contains { $0 != .idle }
            && states.allSatisfy { $0 == .completed || $0 == .idle }
    }

    var hasLimitedPhotoAccess: Bool {
        photoAuthorizationStatus == .limited
    }

    var photoAccessNeedsSettings: Bool {
        photoAuthorizationStatus == .denied || photoAuthorizationStatus == .restricted
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
            return "0 found"
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
            if unanalyzedPhotoCount > 0 {
                return "\(unanalyzedPhotoCount.formatted()) photos could not be analyzed without downloading from iCloud."
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
            return "\(unanalyzedPhotoCount.formatted()) photos still need an iCloud-enabled pass."
        }
        if lastCompletedGroupsCount == 0 {
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

    func resumeDeepClean() {
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
        scanState = .paused
        isPaused = true
        isBackgroundExecutionState = false
        persistCleanupState()
        if let activePhotoScanEngine {
            Task(priority: .utility) {
                await activePhotoScanEngine.pause()
            }
        }
    }

    func scanPhotos() async {
        await scanPhotos(mode: .deepClean)
    }

    func scanPhotos(
        mode: CleanupMode,
        allowNetworkAccess: Bool = PhotoScanDefaults.allowNetworkAccess,
        forceFullRescan: Bool = false
    ) async {
        if let activePhotoScanEngine {
            await activePhotoScanEngine.resume()
        }
        scanTask?.cancel()

        await restoreCachedAnalysisIfNeeded()
        await refreshLibraryMetadata()

        let cachedSnapshot = await analysisCache.loadSnapshot()
        let cachedLibraryIDs = Set(cachedSnapshot?.libraryAssetIdentifiers ?? [])
        let cachedMetadata = Dictionary(
            uniqueKeysWithValues: (cachedSnapshot?.libraryAssets ?? []).map {
                ($0.localIdentifier, $0)
            }
        )
        let incrementalRequiredIDs: Set<String>?
        if !forceFullRescan,
           !cachedLibraryIDs.isEmpty,
           cachedSnapshot?.cleanupMode == .deepClean || mode == .speedClean {
            let newIDs = knownLibraryAssetIdentifiers.subtracting(cachedLibraryIDs)
            let modifiedIDs = Set<String>(
                knownLibraryAssetMetadata.compactMap { entry -> String? in
                    let (id, metadata) = entry
                    guard let cached = cachedMetadata[id] else { return nil }
                    return cached == metadata ? nil : id
                }
            )
            incrementalRequiredIDs = newIDs.union(modifiedIDs)
        } else {
            incrementalRequiredIDs = nil
        }

        if let incrementalRequiredIDs, incrementalRequiredIDs.isEmpty {
            // An unchanged inventory means persisted analysis is still current.
            // Do not rerun Vision just because the app was reopened.
            scanState = .completed
            isPaused = false
            resultsFreshnessState = .live
            lastCompletedAt = cachedSnapshot?.savedAt ?? lastCompletedAt
            lastCompletedLibraryTotalCount = knownLibraryAssetIdentifiers.count
            persistCleanupState()
            saveCompletedAnalysisSnapshot()
            return
        }

        let preservedGroups = incrementalRequiredIDs == nil ? [] : photoGroups
        let preservedScreenshots = incrementalRequiredIDs == nil ? [] : screenshotAssets
        let preservedBlurryAssets = incrementalRequiredIDs == nil ? [] : blurryAssets

        let scanID = UUID()
        activeScanID = scanID
        cleanupMode = mode
        scanState = .scanning
        isPaused = false
        isReadyForReview = false
        hasPartialResults = false
        scanErrorMessage = nil
        resultsFreshnessState = .live
        lastNotificationKey = nil
        lastRateSampleAt = Date()
        lastRateSampleProcessedCount = 0
        startedSupportingScansForActiveScan = false
        scanRatePhotosPerMinute = 0
        processedPhotoCount = 0
        analyzedPhotoCount = 0
        unanalyzedPhotoCount = 0
        screenshotAssets = []
        blurryAssets = []
        progressFraction = 0
        groupsFoundCount = 0
        reviewablePhotosCount = 0
        reclaimableBytesFoundSoFar = 0

        persistCleanupState()

        let engine = PhotoScanEngine()
        activePhotoScanEngine = engine

        let worker = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                for try await update in engine.scan(
                    mode: mode,
                    allowNetworkAccess: allowNetworkAccess,
                    requiredAssetIDs: incrementalRequiredIDs
                ) {
                    await MainActor.run {
                        guard self.activeScanID == scanID else { return }
                        self.apply(
                            update: update,
                            preservingGroups: preservedGroups,
                            preservingScreenshots: preservedScreenshots,
                            preservingBlurryAssets: preservedBlurryAssets
                        )
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
                    self.lastCompletedScanTargetCount = self.libraryTotalCount
                    self.lastCompletedGroupsCount = self.groupsFoundCount
                    self.lastCompletedReviewableCount = self.reviewablePhotosCount
                    self.lastCompletedReclaimableBytes = self.reclaimableBytesFoundSoFar
                    self.resultsFreshnessState = .live
                    self.persistCleanupState()

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
                                ? "\(self.unanalyzedPhotoCount) iCloud photos need an optional downloaded pass."
                            : self.groupsFoundCount == 0
                                ? "Tap to review \(self.photoReviewCategoryCount) screenshot or blurry-photo suggestions."
                            : "Tap to review \(self.groupsFoundCount) groups and reclaim \(ByteCountFormatter.string(fromByteCount: self.reclaimableBytesFoundSoFar, countStyle: .file))."
                    )
                    self.saveCompletedAnalysisSnapshot()
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard self.activeScanID == scanID else { return }
                    self.scanState = .paused
                    self.isPaused = true
                    self.persistCleanupState()
                }
            } catch let error as ScanError {
                await MainActor.run {
                    guard self.activeScanID == scanID else { return }
                    switch error {
                    case .permissionDenied:
                        self.scanState = .permissionRequired
                        self.scanErrorMessage = "Allow Photos access to start cleanup."
                    }
                    self.persistCleanupState()
                }
            } catch {
                await MainActor.run {
                    guard self.activeScanID == scanID else { return }
                    self.scanErrorMessage = error.localizedDescription
                    self.scanState = .failed
                    self.persistCleanupState()
                }
            }
        }

        scanTask = worker
        await worker.value
        if activeScanID == scanID {
            scanTask = nil
            activePhotoScanEngine = nil
        }
    }

    func retryIncludingICloudPhotos() {
        Task(priority: .utility) {
            await scanPhotos(
                mode: .deepClean,
                allowNetworkAccess: true,
                forceFullRescan: true
            )
        }
    }

    // MARK: - Other scans

    func scanContacts(force: Bool = false) async {
        guard force || contactScanState == .idle || contactScanState == .failed else { return }
        guard contactScanState != .scanning else { return }
        contactScanState = .scanning
        let engine = ContactScanEngine()
        do {
            contactMatches = try await Task(priority: .utility) {
                try await engine.scan()
            }.value
            contactScanState = .completed
        } catch {
            let status = CNContactStore.authorizationStatus(for: .contacts)
            contactScanState = (status == .denied || status == .restricted)
                ? .permissionRequired
                : .failed
        }
    }

    func scanFiles(force: Bool = false) async {
        guard force || fileScanState == .idle || fileScanState == .failed else { return }
        guard fileScanState != .scanning else { return }
        fileScanState = .scanning
        let engine = FileScanEngine()
        do {
            largeFiles = try await Task(priority: .utility) {
                try await engine.scan()
            }.value
            fileScanState = .completed
        } catch let error as FileScanError {
            fileScanState = .permissionRequired
            scanErrorMessage = error.localizedDescription
            photoAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        } catch {
            fileScanState = .failed
        }
    }

    // MARK: - Scene / refresh

    func updateScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background:
            isBackgroundExecutionState = scanState == .scanning && cleanupMode == .deepClean
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
        let currentMetadata = await currentLibraryPhotoMetadata()
        knownLibraryAssetMetadata = currentMetadata
        knownLibraryAssetIdentifiers = Set(currentMetadata.keys)
        let currentCount = currentMetadata.count
        let previousTotal = libraryTotalCount
        libraryTotalCount = currentCount

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
        preservingBlurryAssets: [PHAsset] = []
    ) {
        libraryTotalCount = update.libraryTotalCount
        scanTargetCount = update.scanTargetCount
        processedPhotoCount = update.processedPhotoCount
        analyzedPhotoCount = update.analyzedPhotoCount
        unanalyzedPhotoCount = update.unanalyzedPhotoCount
        progressFraction = update.progressFraction
        let replacedIDs = update.evaluatedAssetIDs
        let unaffectedGroups = preservingGroups.filter { group in
            replacedIDs.isDisjoint(
                with: group.assets.map(\.localIdentifier)
            )
        }
        photoGroups = unaffectedGroups + update.groups
        screenshotAssets = preservingScreenshots.filter {
            !replacedIDs.contains($0.localIdentifier)
        } + update.screenshotAssets
        blurryAssets = preservingBlurryAssets.filter {
            !replacedIDs.contains($0.localIdentifier)
        } + update.blurryAssets
        groupsFoundCount = photoGroups.count
        reviewablePhotosCount = PhotoReviewCategoryClassifier.reviewableCount(
            groups: photoGroups,
            screenshotAssets: screenshotAssets,
            blurryAssets: blurryAssets
        )
        reclaimableBytesFoundSoFar = photoGroups.totalReclaimableBytes
        hasPartialResults = update.hasPartialResults
        isReadyForReview = !photoGroups.isEmpty
            || !screenshotAssets.isEmpty
            || !blurryAssets.isEmpty
        updateScanRate(processedCount: update.processedPhotoCount)
        scanState = update.isComplete ? .completed : (isPaused ? .paused : .scanning)
        resultsFreshnessState = .live

        if !startedSupportingScansForActiveScan {
            startedSupportingScansForActiveScan = true
            Task { await scanSupportingCategoriesIfNeeded() }
        }

        // Throttle UserDefaults writes: at most once every 3 s during scanning,
        // always on completion so the final state is never lost.
        let now = Date()
        if update.isComplete || isPaused || now.timeIntervalSince(lastPersistTime) >= 3 {
            persistCleanupState()
            lastPersistTime = now
        }

    }

    private func scanSupportingCategoriesIfNeeded() async {
        // Keep system permission prompts serialized. Concurrent Photos and
        // Contacts prompts are easy to dismiss accidentally and can strand a scan.
        await scanFiles()
        await scanContacts()
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
        await refreshLibraryMetadata()
        persistCleanupState()
        if let snapshot = await analysisCache.loadSnapshot(),
           !assetIDsRequiringAnalysis(comparedTo: snapshot).isEmpty {
            await scanPhotos(mode: lastCompletedMode ?? snapshot.cleanupMode)
        } else {
            saveCompletedAnalysisSnapshot()
        }
    }

    private func scanNewPhotosIfNeeded() async {
        guard scanTask == nil,
              scanState == .completed || scanState == .idle,
              photoAuthorizationStatus == .authorized
                || photoAuthorizationStatus == .limited,
              let snapshot = await analysisCache.loadSnapshot(),
              !snapshot.libraryAssetIdentifiers.isEmpty else {
            await refreshLibraryMetadata()
            return
        }

        await refreshLibraryMetadata()
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

    private func saveCompletedAnalysisSnapshot() {
        let snapshot = CachedPhotoAnalysisSnapshot(
            libraryTotalCount: libraryTotalCount,
            scanTargetCount: scanTargetCount,
            processedPhotoCount: processedPhotoCount,
            analyzedPhotoCount: analyzedPhotoCount,
            unanalyzedPhotoCount: unanalyzedPhotoCount,
            progressFraction: progressFraction,
            groupsFoundCount: groupsFoundCount,
            reviewablePhotosCount: reviewablePhotosCount,
            reclaimableBytesFoundSoFar: reclaimableBytesFoundSoFar,
            cleanupMode: cleanupMode,
            resultsFreshnessState: .lastKnown,
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

        let groupAssets = photoGroups.flatMap(\.assets)
        Task(priority: .utility) { [weak self, analysisCache, mlBridge] in
            await analysisCache.saveSnapshot(snapshot)
            let featureRecords = await Task.detached(priority: .utility) {
                mlBridge.makeFeatureRecords(for: groupAssets, embeddings: [:])
            }.value
            await mlBridge.persistFeatureRecords(featureRecords)
            await self?.refreshPersistenceHealth()
        }
    }

    private func restoreCachedAnalysisIfNeeded() async {
        guard photoGroups.isEmpty else { return }
        guard let snapshot = await analysisCache.loadSnapshot() else { return }

        let restoredGroups = await analysisCache.rehydrateGroups(from: snapshot)
        let restoredScreenshots = await analysisCache.rehydrateAssets(
            with: snapshot.screenshotAssetIdentifiers
        )
        let restoredBlurryAssets = await analysisCache.rehydrateAssets(
            with: snapshot.blurryAssetIdentifiers
        )
        guard !restoredGroups.isEmpty
                || !restoredScreenshots.isEmpty
                || !restoredBlurryAssets.isEmpty else {
            return
        }

        photoGroups = restoredGroups
        screenshotAssets = restoredScreenshots
        blurryAssets = restoredBlurryAssets
        cleanupMode = snapshot.cleanupMode
        scanState = .completed
        isPaused = false
        isBackgroundExecutionState = false
        processedPhotoCount = snapshot.processedPhotoCount
        analyzedPhotoCount = snapshot.analyzedPhotoCount
        unanalyzedPhotoCount = snapshot.unanalyzedPhotoCount
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
        resultsFreshnessState = .lastKnown
        persistCleanupState()
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
        let snapshot = PersistedCleanupState(
            cleanupMode: cleanupMode,
            scanState: scanState,
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
