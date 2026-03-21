import Photos

struct PhotoGroup: Identifiable, @unchecked Sendable {
    let id: UUID
    let assets: [PHAsset]
    let similarity: Float
    let reason: SimilarityReason
    let groupType: SimilarGroupType
    let groupConfidence: SimilarGroupConfidence
    let reviewState: SimilarReviewState
    let recommendedAction: SimilarRecommendedAction?
    let keeperAssetID: String?
    let deleteCandidateIDs: [String]
    let bestShotPhotoId: String?
    let groupReasonsSummary: [String]
    let blockerFlags: [BlockerFlag]
    let scoreBreakdown: ScoreBreakdown?
    let captureDateRange: DateInterval?
    let candidates: [SimilarPhotoCandidate]
    let reclaimableBytes: Int64

    init(
        id: UUID = UUID(),
        assets: [PHAsset],
        similarity: Float,
        reason: SimilarityReason,
        groupType: SimilarGroupType? = nil,
        groupConfidence: SimilarGroupConfidence? = nil,
        reviewState: SimilarReviewState = .unreviewed,
        recommendedAction: SimilarRecommendedAction? = nil,
        keeperAssetID: String? = nil,
        deleteCandidateIDs: [String] = [],
        bestShotPhotoId: String? = nil,
        groupReasonsSummary: [String] = [],
        blockerFlags: [BlockerFlag] = [],
        scoreBreakdown: ScoreBreakdown? = nil,
        captureDateRange: DateInterval? = nil,
        candidates: [SimilarPhotoCandidate] = [],
        reclaimableBytes: Int64? = nil
    ) {
        let effectiveKeeperAssetID =
            keeperAssetID
            ?? bestShotPhotoId
            ?? candidates.first(where: \.isBestShot)?.photoId
        let resolvedGroupConfidence = groupConfidence ?? reason.defaultConfidence(for: similarity, photoCount: assets.count)
        let resolvedRecommendedAction = recommendedAction ?? resolvedGroupConfidence.defaultRecommendedAction
        let shouldExposeDeleteCandidates = resolvedRecommendedAction == .keepBestTrashRest

        let resolvedDeleteCandidateIDs: [String]
        if !deleteCandidateIDs.isEmpty {
            if let effectiveKeeperAssetID {
                resolvedDeleteCandidateIDs = Self.unique(deleteCandidateIDs.filter { $0 != effectiveKeeperAssetID })
            } else {
                resolvedDeleteCandidateIDs = Self.unique(deleteCandidateIDs)
            }
        } else if shouldExposeDeleteCandidates, let effectiveKeeperAssetID {
            resolvedDeleteCandidateIDs = assets
                .map(\.localIdentifier)
                .filter { $0 != effectiveKeeperAssetID }
        } else {
            resolvedDeleteCandidateIDs = []
        }

        self.id = id
        self.assets = assets
        self.similarity = similarity
        self.reason = reason
        self.groupType = groupType ?? reason.defaultGroupType
        self.groupConfidence = resolvedGroupConfidence
        self.reviewState = reviewState
        self.recommendedAction = resolvedRecommendedAction
        self.keeperAssetID = effectiveKeeperAssetID
        self.deleteCandidateIDs = resolvedDeleteCandidateIDs
        self.bestShotPhotoId = effectiveKeeperAssetID
        self.groupReasonsSummary = groupReasonsSummary
        self.blockerFlags = blockerFlags
        self.scoreBreakdown = scoreBreakdown
        self.captureDateRange = captureDateRange ?? Self.makeDateRange(from: assets)
        self.candidates = candidates.isEmpty
            ? Self.makeCandidates(from: assets, keeperAssetID: effectiveKeeperAssetID, exposeDeleteCandidates: shouldExposeDeleteCandidates)
            : Self.reconcileCandidates(candidates, keeperAssetID: effectiveKeeperAssetID, exposeDeleteCandidates: shouldExposeDeleteCandidates)
        self.reclaimableBytes = reclaimableBytes ?? Self.estimateReclaimableBytes(from: assets, deleteCandidateIDs: self.deleteCandidateIDs)
    }

    enum SimilarityReason: String, CaseIterable, Identifiable, Sendable, Codable {
        case nearDuplicate
        case visuallySimilar
        case burstShot

        var id: String { rawValue }
    }

    var groupId: String { id.uuidString }
    var photoCount: Int { assets.count }
    var reasons: [String] { groupReasonsSummary }
    var deleteCandidateAssets: [PHAsset] {
        let deleteIDSet = Set(deleteCandidateIDs)
        return assets.filter { deleteIDSet.contains($0.localIdentifier) }
    }
    var bestAsset: PHAsset? {
        guard let keeperAssetID else { return nil }
        return assets.first { $0.localIdentifier == keeperAssetID }
    }

    private static func makeDateRange(from assets: [PHAsset]) -> DateInterval? {
        let dates = assets.compactMap(\.creationDate).sorted()
        guard let first = dates.first, let last = dates.last else { return nil }
        return DateInterval(start: first, end: last)
    }

    private static func makeCandidates(from assets: [PHAsset], keeperAssetID: String?, exposeDeleteCandidates: Bool) -> [SimilarPhotoCandidate] {
        assets.map { asset in
            let isBest = asset.localIdentifier == keeperAssetID
            return SimilarPhotoCandidate(
                photoId: asset.localIdentifier,
                assetReference: asset.localIdentifier,
                captureTimestamp: asset.creationDate,
                isBestShot: isBest,
                bestShotScore: isBest ? 0.95 : 0.45,
                bestShotReasons: isBest ? ["Best overall balance"] : [],
                issueFlags: isBest ? [] : [.lowConfidence],
                isProtected: false,
                isSelectedForTrash: exposeDeleteCandidates && keeperAssetID != nil ? !isBest : false,
                isViewed: false,
                selectionState: keeperAssetID == nil ? .undecided : (isBest ? .keep : (exposeDeleteCandidates ? .trash : .undecided)),
                technicalScores: SimilarTechnicalScores(sharpness: isBest ? 0.95 : 0.68, focus: isBest ? 0.9 : 0.62, exposure: 0.8, framing: isBest ? 0.92 : 0.64)
            )
        }
    }

    private static func reconcileCandidates(_ candidates: [SimilarPhotoCandidate], keeperAssetID: String?, exposeDeleteCandidates: Bool) -> [SimilarPhotoCandidate] {
        guard let keeperAssetID else { return candidates }
        return candidates.map { candidate in
            let isBest = candidate.photoId == keeperAssetID
            let selectionState: SimilarSelectionState
            if isBest {
                selectionState = .keep
            } else if candidate.selectionState == .protected {
                selectionState = .protected
            } else if exposeDeleteCandidates, candidate.selectionState == .trash {
                selectionState = .trash
            } else {
                selectionState = .undecided
            }

            return SimilarPhotoCandidate(
                photoId: candidate.photoId,
                assetReference: candidate.assetReference,
                captureTimestamp: candidate.captureTimestamp,
                isBestShot: isBest,
                bestShotScore: candidate.bestShotScore,
                bestShotReasons: candidate.bestShotReasons,
                issueFlags: candidate.issueFlags,
                isProtected: candidate.isProtected,
                isSelectedForTrash: isBest ? false : (exposeDeleteCandidates ? candidate.isSelectedForTrash : false),
                isViewed: candidate.isViewed,
                selectionState: selectionState,
                technicalScores: candidate.technicalScores
            )
        }
    }

    private static func estimateReclaimableBytes(from assets: [PHAsset], deleteCandidateIDs: [String]) -> Int64 {
        guard !deleteCandidateIDs.isEmpty else { return 0 }
        let deleteIDSet = Set(deleteCandidateIDs)
        return assets.reduce(into: Int64(0)) { acc, asset in
            guard deleteIDSet.contains(asset.localIdentifier) else { return }
            acc += asset.estimatedFileSize
        }
    }

    private static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }
}

struct SimilarPhotoCandidate: Identifiable, Hashable, Sendable, Codable {
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

    var id: String { photoId }
}

struct SimilarTechnicalScores: Hashable, Sendable, Codable {
    let sharpness: Double
    let focus: Double
    let exposure: Double
    let framing: Double
}

enum IssueFlag: String, CaseIterable, Identifiable, Sendable, Codable {
    case eyesClosed
    case softFocus
    case motionBlur
    case poorExpression
    case worseFraming
    case underexposed
    case overexposed
    case duplicate
    case blockedSubject
    case lowConfidence

    var id: String { rawValue }

    var title: String {
        switch self {
        case .eyesClosed: return "Eyes closed"
        case .softFocus: return "Soft focus"
        case .motionBlur: return "Motion blur"
        case .poorExpression: return "Poor expression"
        case .worseFraming: return "Worse framing"
        case .underexposed: return "Underexposed"
        case .overexposed: return "Overexposed"
        case .duplicate: return "Duplicate"
        case .blockedSubject: return "Blocked subject"
        case .lowConfidence: return "Low confidence"
        }
    }

    var systemImage: String {
        switch self {
        case .eyesClosed: return "eye.slash"
        case .softFocus, .motionBlur: return "camera.macro"
        case .poorExpression: return "face.dashed"
        case .worseFraming: return "crop"
        case .underexposed, .overexposed: return "sun.max"
        case .duplicate: return "photo.on.rectangle"
        case .blockedSubject: return "rectangle.portrait.and.arrow.right"
        case .lowConfidence: return "questionmark.circle"
        }
    }
}

enum SimilarGroupType: String, CaseIterable, Identifiable, Sendable, Codable {
    case burst
    case nearDuplicate
    case sameMoment
    case bracketed
    case unknown

    var id: String { rawValue }
}

enum SimilarGroupConfidence: String, CaseIterable, Identifiable, Sendable, Codable {
    case high
    case medium
    case low

    var id: String { rawValue }
}

enum SimilarReviewState: String, CaseIterable, Identifiable, Sendable, Codable {
    case unreviewed
    case inProgress
    case resolved
    case skipped
    case reviewLater

    var id: String { rawValue }
}

enum SimilarRecommendedAction: String, CaseIterable, Identifiable, Sendable, Codable {
    case keepBestTrashRest
    case reviewManually
    case keepAll

    var id: String { rawValue }
}

enum SimilarSelectionState: String, CaseIterable, Identifiable, Sendable, Codable {
    case keep
    case trash
    case undecided
    case protected

    var id: String { rawValue }
}

extension PhotoGroup.SimilarityReason {
    var displayName: String {
        switch self {
        case .nearDuplicate:
            return "Near duplicates"
        case .visuallySimilar:
            return "Visually similar"
        case .burstShot:
            return "Burst"
        }
    }

    var defaultGroupType: SimilarGroupType {
        switch self {
        case .nearDuplicate: return .nearDuplicate
        case .visuallySimilar: return .sameMoment
        case .burstShot: return .burst
        }
    }

    func defaultConfidence(for similarity: Float, photoCount: Int) -> SimilarGroupConfidence {
        switch self {
        case .nearDuplicate:
            return similarity < 0.05 ? .high : .medium
        case .burstShot:
            return photoCount >= 3 ? .high : .medium
        case .visuallySimilar:
            return similarity < 0.1 ? .medium : .low
        }
    }
}

extension SimilarGroupType {
    var displayName: String {
        switch self {
        case .burst:
            return "Burst"
        case .nearDuplicate:
            return "Near duplicate"
        case .sameMoment:
            return "Similar"
        case .bracketed:
            return "Bracketed"
        case .unknown:
            return "Similar"
        }
    }
}

extension SimilarGroupConfidence {
    var displayName: String {
        switch self {
        case .high:
            return "High confidence"
        case .medium:
            return "Needs review"
        case .low:
            return "Needs review"
        }
    }

    var defaultRecommendedAction: SimilarRecommendedAction {
        switch self {
        case .high: return .keepBestTrashRest
        case .medium: return .reviewManually
        case .low: return .reviewManually
        }
    }
}
