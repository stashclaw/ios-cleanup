import Foundation
import Photos

struct CachedPhotoAnalysisSnapshot: Codable, Sendable {
    static let schemaVersion = 2

    let schemaVersion: Int
    let savedAt: Date
    let libraryTotalCount: Int
    let scanTargetCount: Int
    let processedPhotoCount: Int
    let progressFraction: Double
    let groupsFoundCount: Int
    let reviewablePhotosCount: Int
    let reclaimableBytesFoundSoFar: Int64
    let cleanupMode: CleanupMode
    let resultsFreshnessState: CleanupResultsFreshnessState
    let groups: [CachedPhotoGroup]

    init(
        savedAt: Date = Date(),
        libraryTotalCount: Int,
        scanTargetCount: Int,
        processedPhotoCount: Int,
        progressFraction: Double,
        groupsFoundCount: Int,
        reviewablePhotosCount: Int,
        reclaimableBytesFoundSoFar: Int64,
        cleanupMode: CleanupMode,
        resultsFreshnessState: CleanupResultsFreshnessState,
        groups: [CachedPhotoGroup]
    ) {
        self.schemaVersion = Self.schemaVersion
        self.savedAt = savedAt
        self.libraryTotalCount = libraryTotalCount
        self.scanTargetCount = scanTargetCount
        self.processedPhotoCount = processedPhotoCount
        self.progressFraction = progressFraction
        self.groupsFoundCount = groupsFoundCount
        self.reviewablePhotosCount = reviewablePhotosCount
        self.reclaimableBytesFoundSoFar = reclaimableBytesFoundSoFar
        self.cleanupMode = cleanupMode
        self.resultsFreshnessState = resultsFreshnessState
        self.groups = groups
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
            recommendedAction: recommendedAction,
            keeperAssetID: keeperAssetID,
            deleteCandidateIDs: deleteCandidateIDs,
            bestShotPhotoId: bestShotPhotoId,
            groupReasonsSummary: groupReasonsSummary,
            blockerFlags: blockerFlags ?? [],
            scoreBreakdown: scoreBreakdown,
            preferenceQueuePriority: preferenceQueuePriority,
            preferenceAdjustmentReasons: preferenceAdjustmentReasons ?? [],
            captureDateRange: captureDateRange,
            candidates: candidates.map { $0.makeCandidate() },
            reclaimableBytes: reclaimableBytes
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

    private let fileURL: URL

    init() {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = baseURL.appendingPathComponent("PhotoDuck", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("photo-analysis-cache.json")
    }

    func loadSnapshot() -> CachedPhotoAnalysisSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(CachedPhotoAnalysisSnapshot.self, from: data)
    }

    func saveSnapshot(_ snapshot: CachedPhotoAnalysisSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: [.atomic])
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
}
