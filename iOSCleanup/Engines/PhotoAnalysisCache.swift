import Foundation
import OSLog
import Photos

struct CachedPhotoAssetMetadata: Codable, Hashable, Sendable {
    let localIdentifier: String
    let modificationDate: Date?
    let pixelWidth: Int
    let pixelHeight: Int
    let mediaSubtypesRawValue: UInt
}

struct CachedPhotoAnalysisSnapshot: Codable, Sendable {
    // Checkpoint fields are additive and decode safely from existing version 7
    // completed snapshots, avoiding a one-time full rescan after this update.
    static let schemaVersion = 7

    let schemaVersion: Int
    /// Monotonic persistence ordering. Version-7 snapshots written by older
    /// builds decode as generation zero.
    let persistenceGeneration: UInt64
    let savedAt: Date
    let libraryTotalCount: Int
    let scanTargetCount: Int
    let processedPhotoCount: Int
    let analyzedPhotoCount: Int
    let unanalyzedPhotoCount: Int
    let progressFraction: Double
    let groupsFoundCount: Int
    let reviewablePhotosCount: Int
    let reclaimableBytesFoundSoFar: Int64
    let cleanupMode: CleanupMode
    let resultsFreshnessState: CleanupResultsFreshnessState
    let isComplete: Bool
    let evaluatedAssetIdentifiers: [String]
    let scanTargetAssetIdentifiers: [String]
    /// Assets that were attempted but produced no usable analysis. They are
    /// also present in `evaluatedAssetIdentifiers` (attempted), which is what
    /// keeps completion consistent — but the resume planner folds this set
    /// back into every subsequent scan, so a failure is retried rather than
    /// treated as permanently covered. See `hasCompleteAnalysisCoverage`.
    let unanalyzedAssetIdentifiers: [String]
    let groups: [CachedPhotoGroup]
    let screenshotAssetIdentifiers: [String]
    let blurryAssetIdentifiers: [String]
    let libraryAssetIdentifiers: [String]
    let libraryAssets: [CachedPhotoAssetMetadata]

    /// `evaluatedAssetIdentifiers` records assets that were *attempted*, which
    /// is what keeps `hasConsistentCompletionState` meaningful — excluding
    /// failures would make any scan with one bad photo permanently incomplete
    /// and trigger a resume on every launch. Analysis coverage is therefore a
    /// separate question, and this is the property to use before telling the
    /// user their library has actually been checked.
    var hasCompleteAnalysisCoverage: Bool {
        hasConsistentCompletionState
            && isComplete
            && unanalyzedAssetIdentifiers.isEmpty
    }

    var hasConsistentCompletionState: Bool {
        guard isComplete else { return true }
        let knownLibraryIDs = Set(libraryAssetIdentifiers).union(
            libraryAssets.map(\.localIdentifier)
        )
        let evaluatedIDs = Set(evaluatedAssetIdentifiers)

        if libraryTotalCount == 0, knownLibraryIDs.isEmpty {
            return evaluatedIDs.isEmpty
                && scanTargetCount == 0
                && processedPhotoCount == 0
                && progressFraction >= 0.999
        }
        guard libraryTotalCount > 0,
              !knownLibraryIDs.isEmpty,
              scanTargetCount > 0,
              processedPhotoCount >= scanTargetCount,
              progressFraction >= 0.999 else {
            return false
        }
        let knownLibraryCount = max(libraryTotalCount, knownLibraryIDs.count)
        guard evaluatedIDs.count >= min(scanTargetCount, knownLibraryCount) else {
            return false
        }
        guard cleanupMode == .deepClean else { return true }

        // A completed Deep Clean must cover the complete image inventory, not
        // merely a nonzero target. This rejects poisoned snapshots such as
        // "1 / 1 complete" for a 50,000-photo library, which would otherwise
        // make the incremental planner return an empty work set forever.
        guard scanTargetCount >= knownLibraryCount else { return false }
        return knownLibraryIDs.isSubset(of: evaluatedIDs)
    }

    func repairingPrematureCompletion(
        evaluatedAssetIdentifiers: [String],
        scanTargetAssetIdentifiers: [String]
    ) -> CachedPhotoAnalysisSnapshot {
        CachedPhotoAnalysisSnapshot(
            savedAt: Date(),
            libraryTotalCount: libraryTotalCount,
            scanTargetCount: scanTargetAssetIdentifiers.count,
            processedPhotoCount: evaluatedAssetIdentifiers.count,
            analyzedPhotoCount: min(
                analyzedPhotoCount,
                evaluatedAssetIdentifiers.count
            ),
            unanalyzedPhotoCount: max(
                evaluatedAssetIdentifiers.count
                    - min(analyzedPhotoCount, evaluatedAssetIdentifiers.count),
                0
            ),
            progressFraction: scanTargetAssetIdentifiers.isEmpty
                ? 1
                : Double(evaluatedAssetIdentifiers.count)
                    / Double(scanTargetAssetIdentifiers.count),
            groupsFoundCount: groupsFoundCount,
            reviewablePhotosCount: reviewablePhotosCount,
            reclaimableBytesFoundSoFar: reclaimableBytesFoundSoFar,
            cleanupMode: cleanupMode,
            resultsFreshnessState: .lastKnown,
            isComplete: false,
            evaluatedAssetIdentifiers: evaluatedAssetIdentifiers,
            scanTargetAssetIdentifiers: scanTargetAssetIdentifiers,
            unanalyzedAssetIdentifiers: unanalyzedAssetIdentifiers,
            groups: groups,
            screenshotAssetIdentifiers: screenshotAssetIdentifiers,
            blurryAssetIdentifiers: blurryAssetIdentifiers,
            libraryAssetIdentifiers: libraryAssetIdentifiers,
            libraryAssets: libraryAssets
        )
    }

    init(
        savedAt: Date = Date(),
        persistenceGeneration: UInt64 = 0,
        libraryTotalCount: Int,
        scanTargetCount: Int,
        processedPhotoCount: Int,
        analyzedPhotoCount: Int,
        unanalyzedPhotoCount: Int,
        progressFraction: Double,
        groupsFoundCount: Int,
        reviewablePhotosCount: Int,
        reclaimableBytesFoundSoFar: Int64,
        cleanupMode: CleanupMode,
        resultsFreshnessState: CleanupResultsFreshnessState,
        isComplete: Bool = true,
        evaluatedAssetIdentifiers: [String] = [],
        scanTargetAssetIdentifiers: [String] = [],
        unanalyzedAssetIdentifiers: [String] = [],
        groups: [CachedPhotoGroup],
        screenshotAssetIdentifiers: [String] = [],
        blurryAssetIdentifiers: [String] = [],
        libraryAssetIdentifiers: [String] = [],
        libraryAssets: [CachedPhotoAssetMetadata] = []
    ) {
        self.schemaVersion = Self.schemaVersion
        self.persistenceGeneration = persistenceGeneration
        self.savedAt = savedAt
        self.libraryTotalCount = libraryTotalCount
        self.scanTargetCount = scanTargetCount
        self.processedPhotoCount = processedPhotoCount
        self.analyzedPhotoCount = analyzedPhotoCount
        self.unanalyzedPhotoCount = unanalyzedPhotoCount
        self.progressFraction = progressFraction
        self.groupsFoundCount = groupsFoundCount
        self.reviewablePhotosCount = reviewablePhotosCount
        self.reclaimableBytesFoundSoFar = reclaimableBytesFoundSoFar
        self.cleanupMode = cleanupMode
        self.resultsFreshnessState = resultsFreshnessState
        self.isComplete = isComplete
        self.evaluatedAssetIdentifiers = evaluatedAssetIdentifiers
        self.scanTargetAssetIdentifiers = scanTargetAssetIdentifiers
        self.unanalyzedAssetIdentifiers = unanalyzedAssetIdentifiers
        self.groups = groups
        self.screenshotAssetIdentifiers = screenshotAssetIdentifiers
        self.blurryAssetIdentifiers = blurryAssetIdentifiers
        self.libraryAssetIdentifiers = libraryAssetIdentifiers
        self.libraryAssets = libraryAssets
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case persistenceGeneration
        case savedAt
        case libraryTotalCount
        case scanTargetCount
        case processedPhotoCount
        case analyzedPhotoCount
        case unanalyzedPhotoCount
        case progressFraction
        case groupsFoundCount
        case reviewablePhotosCount
        case reclaimableBytesFoundSoFar
        case cleanupMode
        case resultsFreshnessState
        case isComplete
        case evaluatedAssetIdentifiers
        case scanTargetAssetIdentifiers
        case unanalyzedAssetIdentifiers
        case groups
        case screenshotAssetIdentifiers
        case blurryAssetIdentifiers
        case libraryAssetIdentifiers
        case libraryAssets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        persistenceGeneration = try container.decodeIfPresent(
            UInt64.self,
            forKey: .persistenceGeneration
        ) ?? 0
        savedAt = try container.decode(Date.self, forKey: .savedAt)
        libraryTotalCount = try container.decode(Int.self, forKey: .libraryTotalCount)
        scanTargetCount = try container.decode(Int.self, forKey: .scanTargetCount)
        processedPhotoCount = try container.decode(Int.self, forKey: .processedPhotoCount)
        analyzedPhotoCount = try container.decode(Int.self, forKey: .analyzedPhotoCount)
        unanalyzedPhotoCount = try container.decode(Int.self, forKey: .unanalyzedPhotoCount)
        progressFraction = try container.decode(Double.self, forKey: .progressFraction)
        groupsFoundCount = try container.decode(Int.self, forKey: .groupsFoundCount)
        reviewablePhotosCount = try container.decode(Int.self, forKey: .reviewablePhotosCount)
        reclaimableBytesFoundSoFar = try container.decode(
            Int64.self,
            forKey: .reclaimableBytesFoundSoFar
        )
        cleanupMode = try container.decode(CleanupMode.self, forKey: .cleanupMode)
        resultsFreshnessState = try container.decode(
            CleanupResultsFreshnessState.self,
            forKey: .resultsFreshnessState
        )
        isComplete = try container.decodeIfPresent(Bool.self, forKey: .isComplete) ?? true
        groups = try container.decode([CachedPhotoGroup].self, forKey: .groups)
        screenshotAssetIdentifiers = try container.decode(
            [String].self,
            forKey: .screenshotAssetIdentifiers
        )
        blurryAssetIdentifiers = try container.decode(
            [String].self,
            forKey: .blurryAssetIdentifiers
        )
        libraryAssetIdentifiers = try container.decode(
            [String].self,
            forKey: .libraryAssetIdentifiers
        )
        libraryAssets = try container.decode(
            [CachedPhotoAssetMetadata].self,
            forKey: .libraryAssets
        )
        evaluatedAssetIdentifiers = try container.decodeIfPresent(
            [String].self,
            forKey: .evaluatedAssetIdentifiers
        ) ?? (isComplete ? libraryAssetIdentifiers : [])
        scanTargetAssetIdentifiers = try container.decodeIfPresent(
            [String].self,
            forKey: .scanTargetAssetIdentifiers
        ) ?? []
        unanalyzedAssetIdentifiers = try container.decodeIfPresent(
            [String].self,
            forKey: .unanalyzedAssetIdentifiers
        ) ?? []
    }
}

enum PhotoScanResumePlanner {
    static func requiredAssetIDs(
        snapshot: CachedPhotoAnalysisSnapshot?,
        currentAssetIDs: Set<String>,
        currentMetadata: [String: CachedPhotoAssetMetadata],
        mode: CleanupMode,
        forceFullRescan: Bool,
        retryAssetIDs: Set<String> = []
    ) -> Set<String>? {
        guard !forceFullRescan, let snapshot else { return nil }
        guard snapshot.hasConsistentCompletionState else { return nil }

        let previouslyUnanalyzedIDs = Set(snapshot.unanalyzedAssetIdentifiers)

        let cachedMetadata = Dictionary(
            uniqueKeysWithValues: snapshot.libraryAssets.map {
                ($0.localIdentifier, $0)
            }
        )
        let modifiedIDs = Set(
            currentMetadata.compactMap { id, metadata -> String? in
                guard let cached = cachedMetadata[id] else { return nil }
                return cached == metadata ? nil : id
            }
        )

        if !snapshot.isComplete {
            let evaluatedIDs = Set(snapshot.evaluatedAssetIdentifiers)
            let plannedIDs = Set(snapshot.scanTargetAssetIdentifiers)
            // A pause/background checkpoint can be written before the scan
            // engine publishes its first target plan. Treat that checkpoint as
            // uninitialized work, not as an empty completed target. Returning
            // nil rebuilds the selected Speed/Deep plan safely.
            if plannedIDs.isEmpty, !currentAssetIDs.isEmpty {
                return nil
            }
            let validPlannedIDs = plannedIDs.intersection(currentAssetIDs)
            let newIDs = currentAssetIDs.subtracting(
                snapshot.libraryAssetIdentifiers
            )
            return validPlannedIDs
                .subtracting(evaluatedIDs)
                .union(modifiedIDs)
                .union(newIDs)
                .union(retryAssetIDs.intersection(currentAssetIDs))
                .union(previouslyUnanalyzedIDs.intersection(currentAssetIDs))
        }

        guard !snapshot.libraryAssetIdentifiers.isEmpty,
              snapshot.cleanupMode == .deepClean || mode == .speedClean else {
            return nil
        }
        return currentAssetIDs
            .subtracting(snapshot.libraryAssetIdentifiers)
            .union(modifiedIDs)
            .union(retryAssetIDs.intersection(currentAssetIDs))
            // Assets that were attempted but produced no analysis are marked
            // evaluated so completion stays consistent. Without folding them
            // back in here they would be treated as covered forever, and only
            // the explicit retry CTA could ever reach them — so a plain
            // "Scan again" silently skipped the very photos it failed on.
            .union(previouslyUnanalyzedIDs.intersection(currentAssetIDs))
    }
}

struct CachedPhotoGroup: Codable, Sendable {
    let id: UUID
    let assetIdentifiers: [String]
    let similarity: Float
    let reason: PhotoGroup.SimilarityReason
    let groupType: SimilarGroupType
    let groupConfidence: SimilarGroupConfidence
    let reviewState: SimilarReviewState
    let recommendedAction: SimilarRecommendedAction?
    let keeperAssetID: String?
    let deleteCandidateIDs: [String]
    let bestShotPhotoId: String?
    let groupReasonsSummary: [String]
    let blockerFlags: [BlockerFlag]?
    let scoreBreakdown: ScoreBreakdown?
    let preferenceQueuePriority: Double?
    let preferenceAdjustmentReasons: [String]?
    let captureDateStart: Date?
    let captureDateEnd: Date?
    let candidates: [CachedSimilarPhotoCandidate]
    let reclaimableBytes: Int64

    init(
        id: UUID,
        assetIdentifiers: [String],
        similarity: Float,
        reason: PhotoGroup.SimilarityReason,
        groupType: SimilarGroupType,
        groupConfidence: SimilarGroupConfidence,
        reviewState: SimilarReviewState,
        recommendedAction: SimilarRecommendedAction?,
        keeperAssetID: String?,
        deleteCandidateIDs: [String],
        bestShotPhotoId: String?,
        groupReasonsSummary: [String],
        blockerFlags: [BlockerFlag]? = nil,
        scoreBreakdown: ScoreBreakdown? = nil,
        preferenceQueuePriority: Double? = nil,
        preferenceAdjustmentReasons: [String]? = nil,
        captureDateStart: Date? = nil,
        captureDateEnd: Date? = nil,
        candidates: [CachedSimilarPhotoCandidate] = [],
        reclaimableBytes: Int64
    ) {
        self.id = id
        self.assetIdentifiers = assetIdentifiers
        self.similarity = similarity
        self.reason = reason
        self.groupType = groupType
        self.groupConfidence = groupConfidence
        self.reviewState = reviewState
        self.recommendedAction = recommendedAction
        self.keeperAssetID = keeperAssetID
        self.deleteCandidateIDs = deleteCandidateIDs
        self.bestShotPhotoId = bestShotPhotoId
        self.groupReasonsSummary = groupReasonsSummary
        self.blockerFlags = blockerFlags
        self.scoreBreakdown = scoreBreakdown
        self.preferenceQueuePriority = preferenceQueuePriority
        self.preferenceAdjustmentReasons = preferenceAdjustmentReasons
        self.captureDateStart = captureDateStart
        self.captureDateEnd = captureDateEnd
        self.candidates = candidates
        self.reclaimableBytes = reclaimableBytes
    }

    func resolvedAssetIdentifiers(using availableIdentifiers: Set<String>) -> [String]? {
        let resolved = assetIdentifiers.filter { availableIdentifiers.contains($0) }
        return resolved.count >= 2 ? resolved : nil
    }

    func makeGroup(using assetsByID: [String: PHAsset]) -> PhotoGroup? {
        guard let resolvedIdentifiers = resolvedAssetIdentifiers(using: Set(assetsByID.keys)) else { return nil }
        let assets = resolvedIdentifiers.compactMap { assetsByID[$0] }
        let resolvedIDSet = Set(resolvedIdentifiers)
        let allMembersResolved = resolvedIdentifiers.count == assetIdentifiers.count
        let resolvedKeeperAssetID = keeperAssetID.flatMap {
            resolvedIDSet.contains($0) ? $0 : nil
        }
        let safeRecommendedAction = allMembersResolved
            ? (recommendedAction ?? .reviewManually)
            : .reviewManually
        let safeDeleteCandidateIDs = allMembersResolved
            ? deleteCandidateIDs.filter(resolvedIDSet.contains)
            : []

        let captureDateRange: DateInterval?
        if let start = captureDateStart, let end = captureDateEnd, start <= end {
            captureDateRange = DateInterval(start: start, end: end)
        } else {
            captureDateRange = nil
        }

        return PhotoGroup(
            id: id,
            assets: assets,
            similarity: similarity,
            reason: reason,
            groupType: groupType,
            groupConfidence: groupConfidence,
            reviewState: reviewState,
            // Complete identifier membership is stable persisted classifier
            // evidence. Missing members conservatively downgrade the group.
            recommendedAction: safeRecommendedAction,
            keeperAssetID: resolvedKeeperAssetID,
            deleteCandidateIDs: safeDeleteCandidateIDs,
            bestShotPhotoId: resolvedKeeperAssetID,
            groupReasonsSummary: allMembersResolved
                ? groupReasonsSummary
                : groupReasonsSummary + ["Group changed since its last scan; review manually."],
            blockerFlags: blockerFlags ?? [],
            scoreBreakdown: scoreBreakdown,
            preferenceQueuePriority: preferenceQueuePriority,
            preferenceAdjustmentReasons: preferenceAdjustmentReasons ?? [],
            captureDateRange: captureDateRange,
            candidates: candidates
                .filter { resolvedIDSet.contains($0.photoId) }
                .map { $0.makeCandidate() },
            reclaimableBytes: allMembersResolved ? reclaimableBytes : 0
        )
    }
}

struct CachedSimilarPhotoCandidate: Codable, Sendable {
    let photoId: String
    let assetReference: String
    let captureTimestamp: Date?
    let isBestShot: Bool
    let bestShotScore: Double
    let bestShotReasons: [String]
    let issueFlags: [IssueFlag]
    let isProtected: Bool
    let isSelectedForTrash: Bool
    let isViewed: Bool
    let selectionState: SimilarSelectionState
    let technicalScores: SimilarTechnicalScores?

    func makeCandidate() -> SimilarPhotoCandidate {
        SimilarPhotoCandidate(
            photoId: photoId,
            assetReference: assetReference,
            captureTimestamp: captureTimestamp,
            isBestShot: isBestShot,
            bestShotScore: bestShotScore,
            bestShotReasons: bestShotReasons,
            issueFlags: issueFlags,
            isProtected: isProtected,
            isSelectedForTrash: isSelectedForTrash,
            isViewed: isViewed,
            selectionState: selectionState,
            technicalScores: technicalScores
        )
    }
}

actor PhotoAnalysisCache {
    static let shared = PhotoAnalysisCache()

    private static let logger = Logger(subsystem: "com.photoduck.app", category: "PhotoAnalysisCache")
    private static let maximumCacheBytes = 64 * 1024 * 1024
    private let fileURL: URL
    private let backupFileURL: URL
    private(set) var persistenceHealthy = true
    private var latestSavedAt: Date = .distantPast
    private var latestGeneration: UInt64 = 0
    private var hasHydratedDiskOrdering = false
    private var pendingSnapshot: CachedPhotoAnalysisSnapshot?
    private var isWriting = false
    private var activeWriteGeneration: UInt64 = 0
    private var flushWaiters: [
        (generation: UInt64, continuation: CheckedContinuation<Bool, Never>)
    ] = []

    #if DEBUG
    private(set) var activeEncodeCount = 0
    private(set) var maximumObservedActiveEncodeCount = 0
    private(set) var completedWriteCount = 0
    private(set) var lastEncodeWriteDuration: TimeInterval = 0
    private(set) var lastEncodedByteCount = 0
    #endif

    init() {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = baseURL.appendingPathComponent("PhotoDuck", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            persistenceHealthy = false
            Self.logger.error("Could not create cache directory: \(error.localizedDescription, privacy: .public)")
        }
        fileURL = directory.appendingPathComponent("photo-analysis-cache.json")
        backupFileURL = directory.appendingPathComponent("photo-analysis-cache.backup.json")
    }

    func loadSnapshot() -> CachedPhotoAnalysisSnapshot? {
        let snapshots = snapshotsOnDisk()
        hasHydratedDiskOrdering = true
        guard let newest = newestSnapshot(in: snapshots) else { return nil }
        recordPersistenceOrdering(from: newest)
        return newest
    }

    private func hydrateDiskOrderingIfNeeded() {
        guard !hasHydratedDiskOrdering else { return }
        hasHydratedDiskOrdering = true
        guard let newest = newestSnapshot(in: snapshotsOnDisk()) else {
            return
        }
        recordPersistenceOrdering(from: newest)
    }

    private func snapshotsOnDisk() -> [CachedPhotoAnalysisSnapshot] {
        [fileURL, backupFileURL].compactMap { loadSnapshot(from: $0) }
    }

    private func newestSnapshot(
        in snapshots: [CachedPhotoAnalysisSnapshot]
    ) -> CachedPhotoAnalysisSnapshot? {
        snapshots.max { lhs, rhs in
            if lhs.persistenceGeneration != rhs.persistenceGeneration {
                return lhs.persistenceGeneration < rhs.persistenceGeneration
            }
            return lhs.savedAt < rhs.savedAt
        }
    }

    private func recordPersistenceOrdering(
        from snapshot: CachedPhotoAnalysisSnapshot
    ) {
        latestSavedAt = max(latestSavedAt, snapshot.savedAt)
        latestGeneration = max(
            latestGeneration,
            snapshot.persistenceGeneration
        )
    }

    private func loadSnapshot(
        from candidateURL: URL
    ) -> CachedPhotoAnalysisSnapshot? {
        let data: Data
        do {
            let attributes = try FileManager.default.attributesOfItem(
                atPath: candidateURL.path
            )
            if let byteCount = attributes[.size] as? NSNumber,
               byteCount.intValue > Self.maximumCacheBytes {
                persistenceHealthy = false
                Self.logger.error("Ignoring oversized photo analysis cache")
                return nil
            }
            data = try Data(contentsOf: candidateURL, options: [.mappedIfSafe])
            let snapshot = try JSONDecoder().decode(CachedPhotoAnalysisSnapshot.self, from: data)
            guard snapshot.schemaVersion == CachedPhotoAnalysisSnapshot.schemaVersion else {
                Self.logger.info("Ignoring cache from schema \(snapshot.schemaVersion)")
                return nil
            }
            if !snapshot.hasConsistentCompletionState {
                persistenceHealthy = false
                Self.logger.error(
                    "Loaded a cache marked complete before its scan target was processed"
                )
            }
            return snapshot
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch {
            persistenceHealthy = false
            Self.logger.error("Could not decode cache: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Enqueues the newest checkpoint and returns immediately. At most one
    /// encode/write is active and a superseded pending checkpoint is discarded.
    func scheduleSnapshot(_ snapshot: CachedPhotoAnalysisSnapshot) {
        enqueue(snapshot)
    }

    /// Durability boundary used for pause, cancellation, backgrounding, and
    /// completion. It waits for this generation (or a newer one) to commit.
    func saveSnapshot(_ snapshot: CachedPhotoAnalysisSnapshot) async {
        let generation = enqueue(snapshot)
        guard latestGeneration < generation else { return }
        _ = await withCheckedContinuation { continuation in
            flushWaiters.append((generation, continuation))
        }
    }

    @discardableResult
    private func enqueue(
        _ snapshot: CachedPhotoAnalysisSnapshot
    ) -> UInt64 {
        // A lifecycle checkpoint can arrive before startup restoration. Read
        // the on-disk generation first so a targetless scalar-only checkpoint
        // can never overwrite a newer durable resume snapshot as generation 1.
        hydrateDiskOrderingIfNeeded()
        let highestPendingGeneration = pendingSnapshot?.persistenceGeneration ?? 0
        let highestKnownGeneration = max(
            latestGeneration,
            max(highestPendingGeneration, activeWriteGeneration)
        )
        let generation: UInt64
        if snapshot.persistenceGeneration > 0 {
            guard snapshot.persistenceGeneration > highestKnownGeneration else {
                return highestKnownGeneration
            }
            generation = snapshot.persistenceGeneration
        } else {
            generation = highestKnownGeneration + 1
        }
        let orderedSnapshot = snapshot.withPersistenceGeneration(generation)
        if pendingSnapshot == nil
            || generation >= (pendingSnapshot?.persistenceGeneration ?? 0) {
            pendingSnapshot = orderedSnapshot
        }
        startWriterIfNeeded()
        return generation
    }

    private func startWriterIfNeeded() {
        guard !isWriting, pendingSnapshot != nil else { return }
        isWriting = true
        Task { await drainPendingSnapshots() }
    }

    private func drainPendingSnapshots() async {
        while let snapshot = pendingSnapshot {
            pendingSnapshot = nil
            activeWriteGeneration = snapshot.persistenceGeneration
            #if DEBUG
            activeEncodeCount += 1
            maximumObservedActiveEncodeCount = max(
                maximumObservedActiveEncodeCount,
                activeEncodeCount
            )
            #endif
            let fileURL = self.fileURL
            let backupFileURL = self.backupFileURL
            let maximumCacheBytes = Self.maximumCacheBytes
            let outcome: PhotoAnalysisSnapshotWriteOutcome = await Task.detached(
                priority: .utility
            ) {
                let startedAt = Date().timeIntervalSinceReferenceDate
                do {
                    let data = try JSONEncoder().encode(snapshot)
                    guard data.count <= maximumCacheBytes else {
                        throw PhotoAnalysisCacheError.snapshotTooLarge(data.count)
                    }
                    let primaryCandidate = photoAnalysisCacheCandidate(
                        at: fileURL,
                        maximumCacheBytes: maximumCacheBytes
                    )
                    let backupCandidate = photoAnalysisCacheCandidate(
                        at: backupFileURL,
                        maximumCacheBytes: maximumCacheBytes
                    )
                    // The backup can legitimately be newer than the primary
                    // after recovery. Never replace that recovery point with a
                    // stale primary before the new primary is durable.
                    if let primaryCandidate {
                        let backupIsNewer = photoAnalysisCacheSnapshot(
                            backupCandidate?.snapshot,
                            isNewerThan: primaryCandidate.snapshot
                        )
                        if !backupIsNewer {
                            try primaryCandidate.data.write(
                                to: backupFileURL,
                                options: [.atomic]
                            )
                        }
                    }
                    try data.write(to: fileURL, options: [.atomic])
                    return PhotoAnalysisSnapshotWriteOutcome(
                        byteCount: data.count,
                        duration: Date().timeIntervalSinceReferenceDate - startedAt,
                        errorDescription: nil
                    )
                } catch {
                    return PhotoAnalysisSnapshotWriteOutcome(
                        byteCount: 0,
                        duration: Date().timeIntervalSinceReferenceDate - startedAt,
                        errorDescription: error.localizedDescription
                    )
                }
            }.value
            #if DEBUG
            activeEncodeCount -= 1
            #endif

            if outcome.errorDescription == nil {
                latestGeneration = max(
                    latestGeneration,
                    snapshot.persistenceGeneration
                )
                latestSavedAt = max(latestSavedAt, snapshot.savedAt)
                persistenceHealthy = true
                #if DEBUG
                completedWriteCount += 1
                lastEncodeWriteDuration = outcome.duration
                lastEncodedByteCount = outcome.byteCount
                Self.logger.debug(
                    "Committed checkpoint generation \(snapshot.persistenceGeneration) bytes=\(outcome.byteCount) duration_ms=\(outcome.duration * 1_000)"
                )
                #endif
            } else {
                persistenceHealthy = false
                Self.logger.error(
                    "Could not save cache: \(outcome.errorDescription ?? "unknown error", privacy: .public)"
                )
            }
            activeWriteGeneration = 0
            resumeEligibleWaiters(writeSucceeded: outcome.errorDescription == nil)
        }
        isWriting = false
        // An enqueue can interleave after the loop condition but before the
        // writer flag is cleared.
        startWriterIfNeeded()
    }

    private func resumeEligibleWaiters(writeSucceeded: Bool) {
        var remaining: [
            (generation: UInt64, continuation: CheckedContinuation<Bool, Never>)
        ] = []
        for waiter in flushWaiters {
            if latestGeneration >= waiter.generation {
                waiter.continuation.resume(returning: true)
            } else if !writeSucceeded && pendingSnapshot == nil {
                waiter.continuation.resume(returning: false)
            } else {
                remaining.append(waiter)
            }
        }
        flushWaiters = remaining
    }

    func rehydrateGroups(from snapshot: CachedPhotoAnalysisSnapshot) -> [PhotoGroup] {
        let identifiers = snapshot.groups.flatMap(\.assetIdentifiers)
        guard !identifiers.isEmpty else { return [] }

        let result = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var assetsByID: [String: PHAsset] = [:]
        result.enumerateObjects { asset, _, _ in
            assetsByID[asset.localIdentifier] = asset
        }

        return snapshot.groups.compactMap { $0.makeGroup(using: assetsByID) }
    }

    func rehydrateAssets(with identifiers: [String]) -> [PHAsset] {
        let uniqueIdentifiers = PhotoAssetIdentity.uniqueIdentifiers(
            identifiers
        )
        guard !uniqueIdentifiers.isEmpty else { return [] }
        let result = PHAsset.fetchAssets(
            withLocalIdentifiers: uniqueIdentifiers,
            options: nil
        )
        var assetsByID: [String: PHAsset] = [:]
        result.enumerateObjects { asset, _, _ in
            assetsByID[asset.localIdentifier] = asset
        }
        return uniqueIdentifiers.compactMap { assetsByID[$0] }
    }
}

private enum PhotoAnalysisCacheError: LocalizedError {
    case snapshotTooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .snapshotTooLarge(let byteCount):
            return "Photo analysis cache is too large to persist safely (\(byteCount) bytes)."
        }
    }
}

private struct PhotoAnalysisSnapshotWriteOutcome: Sendable {
    let byteCount: Int
    let duration: TimeInterval
    let errorDescription: String?
}

private struct PhotoAnalysisCacheDiskCandidate: Sendable {
    let data: Data
    let snapshot: CachedPhotoAnalysisSnapshot
}

private func photoAnalysisCacheCandidate(
    at url: URL,
    maximumCacheBytes: Int
) -> PhotoAnalysisCacheDiskCandidate? {
    guard let attributes = try? FileManager.default.attributesOfItem(
        atPath: url.path
    ),
    let byteCount = attributes[.size] as? NSNumber,
    byteCount.intValue <= maximumCacheBytes,
    let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
    let snapshot = try? JSONDecoder().decode(
        CachedPhotoAnalysisSnapshot.self,
        from: data
    ),
    snapshot.schemaVersion == CachedPhotoAnalysisSnapshot.schemaVersion else {
        return nil
    }
    return PhotoAnalysisCacheDiskCandidate(
        data: data,
        snapshot: snapshot
    )
}

private func photoAnalysisCacheSnapshot(
    _ candidate: CachedPhotoAnalysisSnapshot?,
    isNewerThan reference: CachedPhotoAnalysisSnapshot
) -> Bool {
    guard let candidate else { return false }
    if candidate.persistenceGeneration != reference.persistenceGeneration {
        return candidate.persistenceGeneration > reference.persistenceGeneration
    }
    return candidate.savedAt > reference.savedAt
}

extension CachedPhotoAnalysisSnapshot {
    func withPersistenceGeneration(
        _ generation: UInt64
    ) -> CachedPhotoAnalysisSnapshot {
        CachedPhotoAnalysisSnapshot(
            savedAt: savedAt,
            persistenceGeneration: generation,
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
            resultsFreshnessState: resultsFreshnessState,
            isComplete: isComplete,
            evaluatedAssetIdentifiers: evaluatedAssetIdentifiers,
            scanTargetAssetIdentifiers: scanTargetAssetIdentifiers,
            unanalyzedAssetIdentifiers: unanalyzedAssetIdentifiers,
            groups: groups,
            screenshotAssetIdentifiers: screenshotAssetIdentifiers,
            blurryAssetIdentifiers: blurryAssetIdentifiers,
            libraryAssetIdentifiers: libraryAssetIdentifiers,
            libraryAssets: libraryAssets
        )
    }
}
