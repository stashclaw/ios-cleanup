import Foundation

struct PreferenceAdjustedRecommendationInput: Sendable {
    let bucket: SimilarityBucket
    let groupType: SimilarGroupType
    let confidence: SimilarGroupConfidence
    let suggestedAction: SimilarRecommendedAction
    let keeperRankingResult: KeeperRankingResult
    let preferenceProfile: PhotoPreferenceProfile
    let containsScreenshot: Bool
    let containsBurst: Bool
    let containsEdited: Bool
    let containsFavorite: Bool
    let assetCount: Int
}

struct PreferenceAdjustedRecommendationResult: Sendable, Hashable {
    let adjustedConfidence: SimilarGroupConfidence
    let adjustedSuggestedAction: SimilarRecommendedAction
    let queuePriorityBoost: Double?
    let queuePrioritySuppression: Double?
    let reasons: [String]

    var queuePriorityDelta: Double {
        (queuePriorityBoost ?? 0) - (queuePrioritySuppression ?? 0)
    }
}

struct PreferenceAdjustedRecommendationService: Sendable {
    func adjust(_ input: PreferenceAdjustedRecommendationInput) -> PreferenceAdjustedRecommendationResult {
        let matchingAggregate = input.preferenceProfile.aggregate(forBucket: input.bucket)
            ?? input.preferenceProfile.aggregate(forGroupType: input.groupType)

        let screenshots = input.preferenceProfile.screenshots
        let bursts = input.preferenceProfile.bursts
        let edited = input.preferenceProfile.edited
        let favorites = input.preferenceProfile.favorites
        let lowConfidence = input.preferenceProfile.lowConfidence

        var reasons: [String] = []
        var adjustedConfidence = input.confidence
        var adjustedAction = input.suggestedAction
        var queuePriorityDelta = 0.0

        let keeperMargin = keeperScoreMargin(in: input.keeperRankingResult)
        if keeperMargin > 0 {
            reasons.append(String(format: "Keeper margin %.2f", keeperMargin))
        }

        if input.bucket == .visuallySimilar {
            adjustedAction = .reviewManually
            if adjustedConfidence == .high {
                adjustedConfidence = .medium
            }
            reasons.append("Visually similar groups stay review-oriented")
        }

        if input.bucket == .notSimilar {
            adjustedAction = .keepAll
            adjustedConfidence = .low
            reasons.append("Not-similar groups are never destructive")
        }

        if input.containsScreenshot {
            let deleteRate = screenshots.deleteRate
            if deleteRate >= 0.55 {
                queuePriorityDelta += 0.30
                reasons.append("User often deletes screenshots")
            } else if screenshots.overrideRate >= 0.30 {
                queuePriorityDelta += 0.12
                reasons.append("Screenshots are frequently overridden")
            }
        }

        if input.containsBurst {
            let deleteRate = bursts.deleteRate
            if deleteRate >= 0.50 {
                queuePriorityDelta += 0.18
                reasons.append("Burst groups have a deletion tendency")
            }
        }

        if input.containsEdited {
            let keepRate = keepRate(for: edited)
            if keepRate >= 0.60 {
                queuePriorityDelta -= 0.22
                reasons.append("User often keeps edited photos")
                if adjustedAction == .keepBestTrashRest {
                    adjustedAction = .reviewManually
                    adjustedConfidence = downgrade(adjustedConfidence)
                    reasons.append("Aggressive delete was downgraded for edited content")
                }
            }
        }

        if input.containsFavorite {
            let keepRate = keepRate(for: favorites)
            if keepRate >= 0.60 {
                queuePriorityDelta -= 0.18
                reasons.append("User often keeps favorited photos")
                if adjustedAction == .keepBestTrashRest {
                    adjustedAction = .reviewManually
                    adjustedConfidence = downgrade(adjustedConfidence)
                    reasons.append("Aggressive delete was downgraded for favorited content")
                }
            }
        }

        if let matchingAggregate {
            let keepRate = keepRate(for: matchingAggregate)
            let deleteRate = matchingAggregate.deleteRate
            let overrideRate = matchingAggregate.overrideRate
            let acceptanceRate = matchingAggregate.keeperAcceptanceRate

            if overrideRate >= 0.30 {
                queuePriorityDelta -= 0.10
                reasons.append("This group type is frequently overridden")
            }

            if keepRate >= 0.60 {
                queuePriorityDelta -= 0.08
            }

            if deleteRate >= 0.60 && input.suggestedAction == .keepBestTrashRest {
                queuePriorityDelta += 0.10
            }

            if acceptanceRate < 0.45 && adjustedAction == .keepBestTrashRest {
                adjustedAction = .reviewManually
                adjustedConfidence = downgrade(adjustedConfidence)
                reasons.append("Keeper acceptance is low for this group type")
            }
        }

        if lowConfidence.overrideRate >= 0.35 {
            queuePriorityDelta -= 0.08
            reasons.append("Low-confidence groups are often overridden")
        }

        if keeperMargin < 0.08 && adjustedAction == .keepBestTrashRest {
            adjustedAction = .reviewManually
            adjustedConfidence = downgrade(adjustedConfidence)
            reasons.append("Keeper ranking margin is narrow")
        }

        if adjustedAction != .keepBestTrashRest {
            queuePriorityDelta = min(queuePriorityDelta, 0.12)
        }

        let queuePriorityBoost: Double?
        let queuePrioritySuppression: Double?
        if queuePriorityDelta > 0 {
            queuePriorityBoost = min(queuePriorityDelta, 0.35)
            queuePrioritySuppression = nil
        } else if queuePriorityDelta < 0 {
            queuePriorityBoost = nil
            queuePrioritySuppression = min(abs(queuePriorityDelta), 0.35)
        } else {
            queuePriorityBoost = nil
            queuePrioritySuppression = nil
        }

        return PreferenceAdjustedRecommendationResult(
            adjustedConfidence: adjustedConfidence,
            adjustedSuggestedAction: adjustedAction,
            queuePriorityBoost: queuePriorityBoost,
            queuePrioritySuppression: queuePrioritySuppression,
            reasons: uniqueStrings(reasons)
        )
    }

    private func downgrade(_ confidence: SimilarGroupConfidence) -> SimilarGroupConfidence {
        switch confidence {
        case .high:
            return .medium
        case .medium, .low:
            return .low
        }
    }

    private func keepRate(for aggregate: PhotoDecisionAggregate) -> Double {
        let total = aggregate.reviewedCount
        guard total > 0 else { return 0 }
        return Double(aggregate.keptCount) / Double(total)
    }

    private func keeperScoreMargin(in result: KeeperRankingResult) -> Double {
        let ranked = result.scoreByAssetID.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key < rhs.key
        }
        guard ranked.count >= 2 else { return 0 }
        return max(ranked[0].value - ranked[1].value, 0)
    }
}

private func uniqueStrings(_ strings: [String]) -> [String] {
    var seen = Set<String>()
    return strings.filter { seen.insert($0).inserted }
}
