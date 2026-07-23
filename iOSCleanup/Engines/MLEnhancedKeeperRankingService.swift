import Foundation
import Photos

// MARK: - MLEnhancedKeeperRankingService
// Wraps the existing heuristic keeper ranking with ML model predictions.
// Falls back to heuristics when the model is unavailable or low-confidence.

struct MLEnhancedKeeperRankingService: KeeperRankingService {
    private let heuristicService: any KeeperRankingService
    private let mlKeeperService: any KeeperPredictionService
    private let mlGroupActionService: any GroupActionPredictionService

    /// Minimum ML confidence to override heuristics.
    private let keeperConfidenceThreshold = 0.85
    /// The ML candidate must clearly beat the heuristic keeper before replacing it.
    private let keeperOverrideMargin = 0.15
    /// Minimum ML confidence for group action predictions.
    private let groupActionConfidenceThreshold = 0.50

    init(
        heuristicService: any KeeperRankingService = ConservativeKeeperRankingService(),
        mlKeeperService: any KeeperPredictionService = MLKeeperRankingService.shared,
        mlGroupActionService: any GroupActionPredictionService = MLGroupActionService.shared
    ) {
        self.heuristicService = heuristicService
        self.mlKeeperService = mlKeeperService
        self.mlGroupActionService = mlGroupActionService
    }

    // MARK: - Keeper Ranking (conforms to KeeperRankingService)

    func rankKeeper(in input: SimilarityClusterInput) async -> KeeperRankingResult {
        // Heuristics remain the safety net and always produce a usable result.
        let heuristicResult = await heuristicService.rankKeeper(in: input)

        guard mlKeeperService.isAvailable else {
            return heuristicResult
        }

        let groupContext = KeeperInferenceGroupContext(cluster: input)
        var mlScoresByID: [String: Double] = [:]
        for asset in input.assets {
            guard !Task.isCancelled else { return heuristicResult }
            guard let predictionInput = KeeperPredictionInput(
                asset: asset,
                cluster: input,
                groupContext: groupContext,
                heuristicResult: heuristicResult
            ) else {
                continue
            }
            let prediction = await mlKeeperService.predictKeeper(
                features: predictionInput
            )

            if let prediction {
                mlScoresByID[asset.id] = prediction.keeperProbability
            }
        }

        guard let heuristicKeeperID = heuristicResult.keeperAssetID,
              let heuristicKeeperMLScore = mlScoresByID[heuristicKeeperID],
              let mlWinner = mlScoresByID.max(by: { lhs, rhs in
                  if lhs.value != rhs.value { return lhs.value < rhs.value }
                  return lhs.key > rhs.key
              }),
              mlWinner.key != heuristicKeeperID,
              mlWinner.value >= keeperConfidenceThreshold,
              mlWinner.value - heuristicKeeperMLScore >= keeperOverrideMargin else {
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
        guard newKeeperID == mlWinner.key else {
            return heuristicResult
        }
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

        let mappedAction = mapLabelToAction(output.predictedLabel)
        let safeAction = mappedAction == .keepBestTrashRest && !group.isAutoCleanEligible
            ? SimilarRecommendedAction.reviewManually
            : mappedAction

        return MLGroupActionRecommendation(
            predictedAction: safeAction,
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
