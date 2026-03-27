import Foundation
import Photos
import SwiftUI
import UserNotifications

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

    @Published var libraryTotalCount: Int = 0
    @Published var scanTargetCount: Int = 0
    @Published var processedPhotoCount: Int = 0
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
    private var lastNotificationKey: String?
    private var lastPersistTime: Date = .distantPast
    private var scanStartedAt: Date?
    private let analysisCache = PhotoAnalysisCache.shared
    private let mlBridge = PhotoMLBridge.shared

    init() {
        loadPersistedCleanupState()
        Task(priority: .utility) { await restoreCachedAnalysisIfNeeded() }
        Task { await refreshLibraryMetadata() }
    }

    // MARK: - Legacy helpers

    var photoScanState: ScanState { scanState }

    var reclaimableBytes: Int64 {
        let fromFiles  = largeFiles.reduce(Int64(0)) { $0 + $1.byteSize }
        let fromPhotos = photoGroups.reduce(Int64(0)) { $0 + $1.estimatedSavingsBytes }
        let fromScan   = max(reclaimableBytesFoundSoFar, lastCompletedReclaimableBytes)
        return max(fromFiles + fromPhotos, fromScan)
    }

    var reclaimableFormatted: String {
        ByteCountFormatter.string(fromByteCount: reclaimableBytes, countStyle: .file)
    }

    var hasAnyResult: Bool {
        !photoGroups.isEmpty || !contactMatches.isEmpty || !largeFiles.isEmpty
    }

    var isAnyScanning: Bool {
        scanState == .scanning || contactScanState == .scanning || fileScanState == .scanning
    }

    var isAllDone: Bool {
        let states = [scanState, contactScanState, fileScanState]
        return states.allSatisfy { $0 == .completed || $0 == .idle }
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
            return "Deep Clean is paused. Resume to keep scanning your library · \(scanRateLabel)"
        case .reviewReadyPartialResults:
            return "\(findingsSoFarLabel) · ready to review now"
        case .completedResultsAvailable:
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
        guard let scanStartedAt else { return "0 photos/min" }
        let elapsed = max(Date().timeIntervalSince(scanStartedAt), 1)
        let perMinute = Double(processedPhotoCount) / elapsed * 60
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
        cleanupMode = .deepClean
        startDeepClean()
    }

    func pauseDeepClean() {
        guard scanState == .scanning, cleanupMode == .deepClean else { return }
        scanTask?.cancel()
        scanTask = nil
        scanState = .paused
        isPaused = true
        persistCleanupState()
    }

    func scanPhotos() async {
        await scanPhotos(mode: .deepClean)
    }

    func scanPhotos(mode: CleanupMode) async {
        scanTask?.cancel()

        cleanupMode = mode
        scanState = .scanning
        isPaused = false
        isReadyForReview = false
        hasPartialResults = false
        notificationEligible = false
        scanErrorMessage = nil
        resultsFreshnessState = .live
        lastNotificationKey = nil
        scanStartedAt = Date()
        scanRatePhotosPerMinute = 0

        await refreshLibraryMetadata()
        persistCleanupState()

        let engine = PhotoScanEngine()

        scanTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                for try await update in engine.scan(mode: mode) {
                    await MainActor.run {
                        self.apply(update: update)
                    }
                }

                await MainActor.run {
                    self.scanState = .completed
                    self.isPaused = false
                    self.isReadyForReview = !self.photoGroups.isEmpty
                    self.hasPartialResults = self.isReadyForReview
                    self.lastCompletedAt = Date()
                    self.lastCompletedMode = mode
                    self.lastCompletedLibraryTotalCount = self.libraryTotalCount
                    self.lastCompletedScanTargetCount = self.scanTargetCount
                    self.lastCompletedGroupsCount = self.groupsFoundCount
                    self.lastCompletedReviewableCount = self.reviewablePhotosCount
                    self.lastCompletedReclaimableBytes = self.reclaimableBytesFoundSoFar
                    self.resultsFreshnessState = .live
                    self.persistCleanupState()

                    self.maybeScheduleNotification(
                        key: self.notificationKey(for: mode, completed: true),
                        title: self.groupsFoundCount == 0 ? "Your library looks clean" : "Deep Clean is ready",
                        body: self.groupsFoundCount == 0
                            ? "PhotoDuck checked your library and found no actionable issues."
                            : "Tap to review \(self.groupsFoundCount) groups and reclaim \(ByteCountFormatter.string(fromByteCount: self.reclaimableBytesFoundSoFar, countStyle: .file))."
                    )
                    self.saveCompletedAnalysisSnapshot()
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.scanState = .paused
                    self.isPaused = true
                    self.persistCleanupState()
                }
            } catch let error as ScanError {
                await MainActor.run {
                    switch error {
                    case .permissionDenied:
                        self.scanState = .permissionRequired
                        self.scanErrorMessage = "Allow Photos access to start cleanup."
                    }
                    self.persistCleanupState()
                }
            } catch {
                await MainActor.run {
                    self.scanErrorMessage = error.localizedDescription
                    self.scanState = .failed
                    self.persistCleanupState()
                }
            }
        }

        await scanTask?.value
        scanTask = nil
    }

    // MARK: - Other scans

    func scanContacts() async {
        contactScanState = .scanning
        let engine = ContactScanEngine()
        do {
            contactMatches = try await Task(priority: .utility) {
                try await engine.scan()
            }.value
            contactScanState = .completed
        } catch {
            contactScanState = .failed
        }
    }

    func scanFiles() async {
        fileScanState = .scanning
        let engine = FileScanEngine()
        do {
            largeFiles = try await Task(priority: .utility) {
                try await engine.scan()
            }.value
            fileScanState = .completed
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
        let currentCount = await currentLibraryPhotoCount()
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

    // MARK: - Apply updates

    private func apply(update: PhotoScanUpdate) {
        libraryTotalCount = update.libraryTotalCount
        scanTargetCount = update.scanTargetCount
        processedPhotoCount = update.processedPhotoCount
        progressFraction = update.progressFraction
        photoGroups = update.groups
        groupsFoundCount = update.groupsFoundCount
        reviewablePhotosCount = update.reviewablePhotosCount
        reclaimableBytesFoundSoFar = update.reclaimableBytesFoundSoFar
        hasPartialResults = update.hasPartialResults
        isReadyForReview = update.groupsFoundCount > 0
        if let scanStartedAt {
            let elapsed = max(Date().timeIntervalSince(scanStartedAt), 1)
            scanRatePhotosPerMinute = Double(update.processedPhotoCount) / elapsed * 60
        }
        scanState = update.isComplete ? .completed : .scanning
        resultsFreshnessState = .live

        // Throttle UserDefaults writes: at most once every 3 s during scanning,
        // always on completion so the final state is never lost.
        let now = Date()
        if update.isComplete || now.timeIntervalSince(lastPersistTime) >= 3 {
            persistCleanupState()
            lastPersistTime = now
        }

        if update.hasPartialResults {
            maybeScheduleNotification(
                key: notificationKey(for: update.mode, completed: false),
                title: update.mode == .speedClean ? "Speed Clean found quick wins" : "Partial results are ready",
                body: "Tap to review \(update.groupsFoundCount) groups and reclaim \(ByteCountFormatter.string(fromByteCount: update.reclaimableBytesFoundSoFar, countStyle: .file))."
            )
        }
    }

    private func saveCompletedAnalysisSnapshot() {
        let snapshot = CachedPhotoAnalysisSnapshot(
            libraryTotalCount: libraryTotalCount,
            scanTargetCount: scanTargetCount,
            processedPhotoCount: processedPhotoCount,
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
            }
        )

        let groupAssets = photoGroups.flatMap(\.assets)
        Task(priority: .utility) { [analysisCache, mlBridge] in
            await analysisCache.saveSnapshot(snapshot)
            // Persist photo metadata to SQLite ML store for training data
            if !groupAssets.isEmpty {
                await mlBridge.persistFeatures(for: groupAssets, prints: [:])
            }
        }
    }

    private func restoreCachedAnalysisIfNeeded() async {
        guard photoGroups.isEmpty else { return }
        guard let snapshot = await analysisCache.loadSnapshot() else { return }

        let restoredGroups = await analysisCache.rehydrateGroups(from: snapshot)
        guard !restoredGroups.isEmpty else { return }

        photoGroups = restoredGroups
        cleanupMode = snapshot.cleanupMode
        scanState = .completed
        isPaused = false
        isBackgroundExecutionState = false
        processedPhotoCount = snapshot.processedPhotoCount
        scanTargetCount = snapshot.scanTargetCount
        progressFraction = snapshot.progressFraction
        groupsFoundCount = snapshot.groupsFoundCount
        reviewablePhotosCount = snapshot.reviewablePhotosCount
        reclaimableBytesFoundSoFar = snapshot.reclaimableBytesFoundSoFar
        hasPartialResults = snapshot.groupsFoundCount > 0
        isReadyForReview = snapshot.groupsFoundCount > 0
        lastCompletedAt = snapshot.savedAt
        lastCompletedMode = snapshot.cleanupMode
        lastCompletedLibraryTotalCount = snapshot.libraryTotalCount
        lastCompletedScanTargetCount = snapshot.scanTargetCount
        lastCompletedGroupsCount = snapshot.groupsFoundCount
        lastCompletedReviewableCount = snapshot.reviewablePhotosCount
        lastCompletedReclaimableBytes = snapshot.reclaimableBytesFoundSoFar
        resultsFreshnessState = .lastKnown
        persistCleanupState()
    }

    private func maybeScheduleNotification(key: String, title: String, body: String) {
        guard lastNotificationKey != key else { return }
        lastNotificationKey = key
        notificationEligible = true
        persistCleanupState()
        CleanupNotificationScheduler.shared.schedule(title: title, body: body, target: .reviewResults)
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

    private func currentLibraryPhotoCount() async -> Int {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = PHAsset.fetchAssets(with: .image, options: nil)
                continuation.resume(returning: result.count)
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

    private var didRequestAuthorization = false

    func schedule(title: String, body: String, target: CleanupReviewTarget) {
        Task { @MainActor in
            if !didRequestAuthorization {
                didRequestAuthorization = true
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            }

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
