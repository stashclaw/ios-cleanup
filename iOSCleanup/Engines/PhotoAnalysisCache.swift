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
    /// Assets that were attempted but produced no usable analysis. These stay
    /// persisted across completed scans so an explicit retry can target them;
    /// they are never silently folded into "evaluated and clean".
    let unanalyzedAssetIdentifiers: [String]
    let groups: [CachedPhotoGroup]
    let screenshotAssetIdentifiers: [String]
    let blurryAssetIdentifiers: [String]
    let libraryAssetIdentifiers: [String]
    let libraryAssets: [CachedPhotoAssetMetadata]

    var hasConsistentCompletionState: Bool {
        guard isComplete else { return true }
        guard scanTargetCount > 0 else { return true }
        return processedPhotoCount >= scanTargetCount
            && progressFraction >= 0.999
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
            let validPlannedIDs = plannedIDs.intersection(currentAssetIDs)
            return validPlannedIDs
                .subtracting(evaluatedIDs)
                .union(modifiedIDs.intersection(evaluatedIDs))
        }

        guard !snapshot.libraryAssetIdentifiers.isEmpty,
              snapshot.cleanupMode == .deepClean || mode == .speedClean else {
            return nil
        }
        return currentAssetIDs
            .subtracting(snapshot.libraryAssetIdentifiers)
            .union(modifiedIDs)
            .union(retryAssetIDs.intersection(currentAssetIDs))
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
    private let fileURL: URL
    private(set) var persistenceHealthy = true
    private var latestSavedAt: Date = .distantPast

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
    }

    func loadSnapshot() -> CachedPhotoAnalysisSnapshot? {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch {
            persistenceHealthy = false
            Self.logger.error("Could not read cache: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        do {
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
            latestSavedAt = max(latestSavedAt, snapshot.savedAt)
            return snapshot
        } catch {
            persistenceHealthy = false
            Self.logger.error("Could not decode cache: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func saveSnapshot(_ snapshot: CachedPhotoAnalysisSnapshot) {
        // Snapshot writes are launched off the main actor. Ignore an older task
        // that arrives after a newer checkpoint or completed result.
        guard snapshot.savedAt >= latestSavedAt else { return }
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: fileURL, options: [.atomic])
            latestSavedAt = snapshot.savedAt
            persistenceHealthy = true
        } catch {
            persistenceHealthy = false
            Self.logger.error("Could not save cache: \(error.localizedDescription, privacy: .public)")
        }
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
        guard !identifiers.isEmpty else { return [] }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var assetsByID: [String: PHAsset] = [:]
        result.enumerateObjects { asset, _, _ in
            assetsByID[asset.localIdentifier] = asset
        }
        return identifiers.compactMap { assetsByID[$0] }
    }
}
