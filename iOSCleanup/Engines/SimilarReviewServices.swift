import Foundation
import Photos

protocol SimilarPhotoGroupingService: Sendable {
    func makeGroups(from assets: [PHAsset]) async -> [PhotoGroup]
}

protocol BestShotRankingService: Sendable {
    func rank(assets: [PHAsset], groupType: SimilarGroupType) async -> [SimilarPhotoCandidate]
}

struct SimilarTrashAction: Sendable {
    let groupID: UUID
    let movedCount: Int
    let reclaimedBytes: Int64
    let summary: String
    let timestamp: Date
}

@MainActor
final class SimilarPhotoReviewCoordinator: ObservableObject {
    @Published var groupsReviewedCount: Int = 0
    @Published var photosMovedToTrashCount: Int = 0
    @Published var bytesReclaimedThisSession: Int64 = 0
    @Published var lastActionSummary: String = ""
    @Published var undoAvailable: Bool = false
    @Published var recentTrashAction: SimilarTrashAction?

    private var reviewedGroupIDs = Set<UUID>()

    func markReviewed(groupID: UUID) {
        reviewedGroupIDs.insert(groupID)
        groupsReviewedCount = reviewedGroupIDs.count
    }

    func registerTrashAction(groupID: UUID, movedCount: Int, reclaimedBytes: Int64, summary: String) {
        let action = SimilarTrashAction(
            groupID: groupID,
            movedCount: movedCount,
            reclaimedBytes: reclaimedBytes,
            summary: summary,
            timestamp: Date()
        )
        recentTrashAction = action
        lastActionSummary = summary
        photosMovedToTrashCount += movedCount
        bytesReclaimedThisSession += reclaimedBytes
        undoAvailable = movedCount > 0
        markReviewed(groupID: groupID)
    }

    func clearUndo() {
        undoAvailable = false
        recentTrashAction = nil
    }

    func resetSession() {
        groupsReviewedCount = 0
        photosMovedToTrashCount = 0
        bytesReclaimedThisSession = 0
        lastActionSummary = ""
        undoAvailable = false
        recentTrashAction = nil
        reviewedGroupIDs.removeAll()
    }
}

// Compatibility adapter for older review flows.
// The authoritative keeper ranking now lives in ConservativeKeeperRankingService.
struct HeuristicBestShotRankingService: BestShotRankingService {
    private let keeperRankingService = ConservativeKeeperRankingService()

    func rank(assets: [PHAsset], groupType: SimilarGroupType) async -> [SimilarPhotoCandidate] {
        guard !assets.isEmpty else { return [] }

        let descriptors = assets.map { SimilaritySignalBuilder.descriptor(for: $0) }
        let keeperSignalsByAssetID = Dictionary(
            uniqueKeysWithValues: assets.map { ($0.localIdentifier, SimilaritySignalBuilder.keeperSignals(for: $0)) }
        )
        let keeperResult = keeperRankingService.rankKeeper(
            in: SimilarityClusterInput(
                assets: descriptors,
                keeperSignalsByAssetID: keeperSignalsByAssetID
            )
        )

        let candidateDetails = assets.map { asset -> (PHAsset, [String], [IssueFlag], SimilarTechnicalScores) in
            let pixels = Double(max(asset.pixelWidth * asset.pixelHeight, 1))
            let resolutionScore = min(log10(pixels) / 8.0, 1.0)
            let aspect = Double(asset.pixelWidth) / max(Double(asset.pixelHeight), 1)
            let aspectDistance = min(abs(aspect - 1.0), abs(aspect - 4.0 / 3.0), abs(aspect - 3.0 / 4.0))
            let framingScore = max(0.0, 1.0 - min(aspectDistance, 1.0))
            let favoriteBonus = asset.isFavorite ? 0.08 : 0.0
            let technicalScores = SimilarTechnicalScores(
                sharpness: resolutionScore,
                focus: resolutionScore * 0.92,
                exposure: 0.72 + (favoriteBonus > 0 ? 0.08 : 0),
                framing: framingScore
            )

            let keeperSignals = keeperResult.scoreBreakdownByAssetID[asset.localIdentifier] ?? SimilaritySignalBuilder.keeperSignals(for: asset)

            var reasons = keeperResult.reasonsByAssetID[asset.localIdentifier] ?? []
            if reasons.isEmpty {
                reasons = ["Best overall balance"]
            }
            if asset.mediaSubtypes.contains(.photoScreenshot) && groupType == .nearDuplicate {
                reasons.insert("Screenshot in near-duplicate group", at: 0)
            }

            var issues: [IssueFlag] = []
            if keeperSignals.blurPenalty > 0.45 { issues.append(.softFocus) }
            if keeperSignals.framingScore < 0.42 { issues.append(.worseFraming) }
            if asset.pixelWidth * asset.pixelHeight < 1_000_000 { issues.append(.lowConfidence) }
            if asset.mediaSubtypes.contains(.photoScreenshot) && groupType == .nearDuplicate {
                issues.append(.duplicate)
            }

            return (asset, reasons, issues, technicalScores)
        }

        let detailsByID = Dictionary(uniqueKeysWithValues: candidateDetails.map { ($0.0.localIdentifier, $0) })

        return keeperResult.rankedAssetIDs.compactMap { assetID in
            guard let entry = detailsByID[assetID] else { return nil }
            let isBest = assetID == keeperResult.keeperAssetID
            return SimilarPhotoCandidate(
                photoId: entry.0.localIdentifier,
                assetReference: entry.0.localIdentifier,
                captureTimestamp: entry.0.creationDate,
                isBestShot: isBest,
                bestShotScore: keeperResult.scoreByAssetID[assetID] ?? 0,
                bestShotReasons: entry.1.prefix(isBest ? 4 : 2).map { $0 },
                issueFlags: isBest ? [] : (entry.2.isEmpty ? [.lowConfidence] : entry.2),
                isProtected: false,
                isSelectedForTrash: !isBest,
                isViewed: false,
                selectionState: isBest ? .keep : .trash,
                technicalScores: entry.3
            )
        }
    }
}

// Compatibility adapter for older UI/search flows.
// The scan pipeline uses ConservativeSimilarityPolicyEngine directly.
struct HeuristicSimilarPhotoGroupingService: SimilarPhotoGroupingService {
    private let rankingService: BestShotRankingService
    private let classifier: SimilarityClassificationService

    init(rankingService: BestShotRankingService = HeuristicBestShotRankingService()) {
        self.rankingService = rankingService
        self.classifier = BundledCoreMLSimilarityClassifier()
    }

    func makeGroups(from assets: [PHAsset]) async -> [PhotoGroup] {
        let rankingService = rankingService
        let sortedAssets = assets.sorted {
            ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast)
        }

        let burstGroups = Dictionary(grouping: sortedAssets) { $0.burstIdentifier ?? "" }
            .values
            .filter { group in group.first?.burstIdentifier != nil && group.count >= 2 }
            .map { Array($0) }

        let nonBurstAssets = sortedAssets.filter { $0.burstIdentifier == nil }
        let windows = stride(from: 0, to: nonBurstAssets.count, by: 3).map {
            Array(nonBurstAssets[$0..<min($0 + 6, nonBurstAssets.count)])
        }

        let groupedAssets = burstGroups + windows.filter { $0.count >= 2 }

        var result: [PhotoGroup] = []
        for assets in groupedAssets {
            let ranked = await rankingService.rank(
                assets: assets,
                groupType: assets.first?.burstIdentifier != nil ? .burst : .sameMoment
            )
            guard let bestCandidate = ranked.first(where: \.isBestShot) else { continue }
            let aiScore: Double?
            if assets.count >= 2 {
                aiScore = await classifier.similarityScore(lhs: assets.first!, rhs: assets.last!)
            } else {
                aiScore = nil
            }

            let reason: PhotoGroup.SimilarityReason
            if let aiScore, aiScore >= 0.8 {
                reason = .nearDuplicate
            } else {
                reason = assets.first?.burstIdentifier != nil ? .burstShot : .visuallySimilar
            }

            let confidence: SimilarGroupConfidence
            if let aiScore, aiScore >= 0.9 {
                confidence = .high
            } else if let aiScore, aiScore >= 0.75 {
                confidence = .medium
            } else {
                confidence = reason.defaultConfidence(for: 0.08, photoCount: assets.count)
            }

            var reasons = bestCandidate.bestShotReasons
            if classifier.isAvailable, aiScore != nil {
                reasons.insert("CoreML similarity signal", at: 0)
            }

            result.append(
                PhotoGroup(
                    assets: assets,
                    similarity: 0.08,
                    reason: reason,
                    groupType: reason.defaultGroupType,
                    groupConfidence: confidence,
                    reviewState: .unreviewed,
                    recommendedAction: confidence.defaultRecommendedAction,
                    keeperAssetID: bestCandidate.photoId,
                    deleteCandidateIDs: ranked.map(\.photoId).filter { $0 != bestCandidate.photoId },
                    bestShotPhotoId: bestCandidate.photoId,
                    groupReasonsSummary: reasons,
                    candidates: ranked
                )
            )
        }
        return result.sorted {
            ($0.captureDateRange?.start ?? .distantPast) < ($1.captureDateRange?.start ?? .distantPast)
        }
    }
}
