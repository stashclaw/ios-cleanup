import Foundation
import Photos

// MARK: - MLEnhancedKeeperRankingService
// Wraps the existing heuristic keeper ranking with ML model predictions.
// Falls back to heuristics when the model is unavailable or low-confidence.

struct MLEnhancedKeeperRankingService: KeeperRankingService {
    private let heuristicService = ConservativeKeeperRankingService()
    private let mlKeeperService = MLKeeperRankingService.shared
    private let mlGroupActionService = MLGroupActionService.shared

    /// Minimum ML confidence to override heuristics.
    private let keeperConfidenceThreshold = 0.55
    /// Minimum ML confidence for group action predictions.
    private let groupActionConfidenceThreshold = 0.50

    // MARK: - Keeper Ranking (conforms to KeeperRankingService)

    func rankKeeper(in input: SimilarityClusterInput) -> KeeperRankingResult {
        // Always run heuristics first — they're the safety net
        let heuristicResult = heuristicService.rankKeeper(in: input)

        guard mlKeeperService.isAvailable else {
            return heuristicResult
        }

        // ML enhancement is async, but KeeperRankingService is sync.
        // We use a blocking semaphore here since this runs on a utility thread
        // during scan, not on the main thread.
        var mlScoresByID: [String: Double] = [:]
        let semaphore = DispatchSemaphore(value: 0)

        Task.detached(priority: .utility) { [mlKeeperService, keeperConfidenceThreshold] in
            defer { semaphore.signal() }

            for asset in input.assets {
                let prediction = await mlKeeperService.predictKeeper(
                    features: KeeperPredictionInput(
                        bucket: "",
                        groupType: "",
                        confidence: "",
                        suggestedAction: "",
                        pixelWidth: asset.pixelWidth,
                        pixelHeight: asset.pixelHeight,
                        isFavorite: asset.isFavorite,
                        isEdited: asset.isEdited,
                        isScreenshot: asset.isScreenshot,
                        burstPresent: asset.burstIdentifier != nil,
                        rankingScore: heuristicResult.scoreByAssetID[asset.id] ?? 0.5,
                        similarityToKeeper: 0,
                        aspectRatio: asset.aspectRatio,
                        fileSizeBytes: Int64(asset.pixelWidth * asset.pixelHeight)
                    )
                )

                if let prediction, prediction.keeperProbability > keeperConfidenceThreshold {
                    mlScoresByID[asset.id] = prediction.keeperProbability
                }
            }
        }

        // Wait with a 500ms timeout — don't block scan if ML is slow
        let waitResult = semaphore.wait(timeout: .now() + .milliseconds(500))
        guard waitResult == .success, !mlScoresByID.isEmpty else {
            return heuristicResult
        }

        // Blend: heuristic 60% + ML 40% (conservative — ML earns more weight with more data)
        let heuristicWeight = 0.60
        let mlWeight = 0.40

        var blendedScores: [String: Double] = [:]
        for asset in input.assets {
            let hScore = heuristicResult.scoreByAssetID[asset.id] ?? 0
            let mlScore = mlScoresByID[asset.id] ?? hScore
            blendedScores[asset.id] = hScore * heuristicWeight + mlScore * mlWeight
        }

        let ranked = blendedScores.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key < rhs.key
        }

        let newKeeperID = ranked.first?.key
        var reasonsByID = heuristicResult.reasonsByAssetID

        // If ML changed the keeper, annotate
        if let newKeeperID, newKeeperID != heuristicResult.keeperAssetID {
            let mlConfidence = mlScoresByID[newKeeperID] ?? 0
            reasonsByID[newKeeperID, default: []].insert(
                String(format: "ML keeper prediction (%.0f%% confidence)", mlConfidence * 100),
                at: 0
            )
        }

        return KeeperRankingResult(
            keeperAssetID: newKeeperID,
            rankedAssetIDs: ranked.map(\.key),
            scoreByAssetID: blendedScores,
            reasonsByAssetID: reasonsByID,
            scoreBreakdownByAssetID: heuristicResult.scoreBreakdownByAssetID
        )
    }

    // MARK: - Group Action Prediction

    func predictGroupAction(for group: PhotoGroup) async -> MLGroupActionRecommendation? {
        guard mlGroupActionService.isAvailable else { return nil }

        let input = GroupActionPredictionInput(group: group)
        guard let output = await mlGroupActionService.predictAction(features: input) else {
            return nil
        }

        let maxProb = output.labelProbabilities.values.max() ?? 0
        guard maxProb >= groupActionConfidenceThreshold else { return nil }

        return MLGroupActionRecommendation(
            predictedAction: mapLabelToAction(output.predictedLabel),
            confidence: maxProb,
            rawLabel: output.predictedLabel,
            allProbabilities: output.labelProbabilities
        )
    }

    private func mapLabelToAction(_ label: String) -> SimilarRecommendedAction {
        switch label {
        case "keep_best_keeper", "keep_best_candidate":
            return .keepBestTrashRest
        case "deleted", "swipe_delete":
            return .keepBestTrashRest
        case "skipped", "restored":
            return .keepAll
        default:
            return .reviewManually
        }
    }
}

struct MLGroupActionRecommendation: Sendable {
    let predictedAction: SimilarRecommendedAction
    let confidence: Double
    let rawLabel: String
    let allProbabilities: [String: Double]
}
