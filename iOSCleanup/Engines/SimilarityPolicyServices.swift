import Foundation

protocol PairSimilarityClassifying: Sendable {
    func classifyPair(
        lhs: SimilarityAssetDescriptor,
        rhs: SimilarityAssetDescriptor,
        signals: SimilaritySignals
    ) -> PairEligibilityResult
}

protocol KeeperRankingService: Sendable {
    func rankKeeper(in input: SimilarityClusterInput) -> KeeperRankingResult
}

protocol SimilarityClusterClassifying: Sendable {
    func classifyCluster(_ input: SimilarityClusterInput) -> SimilarityGroupResult
}

struct ConservativePairSimilarityClassifier: PairSimilarityClassifying {
    func classifyPair(
        lhs: SimilarityAssetDescriptor,
        rhs: SimilarityAssetDescriptor,
        signals: SimilaritySignals
    ) -> PairEligibilityResult {
        var hardBlockers: [BlockerFlag] = []
        var softBlockers: [BlockerFlag] = []
        var reasons: [String] = []

        if signals.screenshotMixedWithCamera {
            hardBlockers.append(.screenshotMixedWithCamera)
            reasons.append("Screenshot mixed with camera photo")
            return PairEligibilityResult(
                eligible: false,
                provisionalBucket: .notSimilar,
                hardBlockers: hardBlockers,
                softBlockers: softBlockers,
                similarityScore: 0,
                reasonStrings: reasons
            )
        }

        let timeDelta = signals.captureTimeDeltaSeconds ?? .greatestFiniteMagnitude
        let featureDistance = signals.featureDistance ?? Double.greatestFiniteMagnitude
        let visualEvidenceAvailable = signals.featureDistance != nil

        if !visualEvidenceAvailable && !signals.isBurstPair {
            softBlockers.append(.lowVisualEvidence)
            reasons.append("No visual evidence available")
            return PairEligibilityResult(
                eligible: false,
                provisionalBucket: .notSimilar,
                hardBlockers: hardBlockers,
                softBlockers: softBlockers,
                similarityScore: 0,
                reasonStrings: reasons
            )
        }

        if signals.aspectRatioMismatch {
            softBlockers.append(.aspectRatioMismatch)
            reasons.append("Aspect ratio mismatch")
        }

        if signals.dimensionMismatch {
            softBlockers.append(.dimensionMismatch)
            reasons.append("Dimension mismatch")
        }

        if signals.editedStateDivergence {
            softBlockers.append(.editedStateDivergence)
            reasons.append("Edited state differs")
        }

        switch signals.variantRelationship {
        case .none:
            break
        case .livePhotoToStill:
            softBlockers.append(.livePhotoVariant)
            reasons.append("Live Photo variant")
        case .editedToOriginal:
            softBlockers.append(.originalVsEditedVariant)
            reasons.append("Original and edited variant")
        case .hdrVariant:
            reasons.append("HDR variant")
        case .portraitDepthVariant:
            reasons.append("Portrait/depth variant")
        case .screenshotToSavedImage:
            hardBlockers.append(.screenshotMixedWithCamera)
            reasons.append("Screenshot and saved image should not be mixed")
        }

        if timeDelta > SimilarityThresholds.largeTimeGapPenaltyAfterSeconds {
            softBlockers.append(.largeTimeGap)
            reasons.append("Large time gap")
        }

        let visualScore = visualScore(for: featureDistance)
        let timeScore = timeScore(for: timeDelta)
        let burstScore = signals.isBurstPair ? SimilarityThresholds.burstConfidenceBonus : 0
        let variantScore = variantScore(for: signals.variantRelationship)
        let aspectPenalty = signals.aspectRatioMismatch ? SimilarityThresholds.aspectRatioMismatchPenalty : 0
        let dimensionPenalty = signals.dimensionMismatch ? SimilarityThresholds.dimensionMismatchPenalty : 0
        let lowEvidencePenalty = signals.featureDistance == nil ? 0.20 : 0

        let similarityScore = clamp(
            visualScore * 0.55
                + timeScore
                + burstScore
                + variantScore
                - aspectPenalty
                - dimensionPenalty
                - lowEvidencePenalty,
            lower: 0,
            upper: 1
        )

        var provisionalBucket: SimilarityBucket = .notSimilar
        var eligible = false

        let burstEligible = signals.isBurstPair
            && timeDelta <= SimilarityThresholds.burstWindowSeconds
            && (visualEvidenceAvailable ? similarityScore >= 0.35 : true)

        let nearDuplicateEligible = visualEvidenceAvailable
            && featureDistance <= SimilarityThresholds.maxNearDuplicateFeatureDistance
            && timeDelta <= SimilarityThresholds.nearDuplicateWindowSeconds
            && !signals.aspectRatioMismatch
            && !signals.dimensionMismatch

        let visualEligible = visualEvidenceAvailable
            && featureDistance <= SimilarityThresholds.maxVisualSimilarFeatureDistance
            && timeDelta <= SimilarityThresholds.visualSessionWindowSeconds

        if burstEligible {
            provisionalBucket = .burstShot
            eligible = true
        } else if nearDuplicateEligible {
            provisionalBucket = .nearDuplicate
            eligible = true
        } else if visualEligible {
            provisionalBucket = .visuallySimilar
            eligible = true
        }

        if provisionalBucket == .nearDuplicate {
            if signals.editedStateDivergence {
                provisionalBucket = .visuallySimilar
                reasons.append("Downgraded due to edited state divergence")
            }
            if timeDelta > SimilarityThresholds.nearDuplicateWindowSeconds || signals.aspectRatioMismatch || signals.dimensionMismatch {
                provisionalBucket = .visuallySimilar
                reasons.append("Downgraded from near-duplicate")
            }
            if featureDistance > SimilarityThresholds.nearDuplicateDowngradeDistanceFloor {
                provisionalBucket = .visuallySimilar
                reasons.append("Borderline visual distance")
            }
        }

        if provisionalBucket == .visuallySimilar
            && timeDelta > SimilarityThresholds.visualSessionWindowSeconds
            && similarityScore < 0.45
        {
            eligible = false
            provisionalBucket = .notSimilar
            softBlockers.append(.largeTimeGap)
            reasons.append("Downgraded out of similar range")
        }

        if provisionalBucket == .burstShot
            && (signals.featureDistance ?? Double.greatestFiniteMagnitude) > SimilarityThresholds.maxBurstFeatureDistance
        {
            softBlockers.append(.burstContentDivergence)
            reasons.append("Burst content diverges")
        }

        if !eligible {
            provisionalBucket = .notSimilar
            if similarityScore < 0.25 {
                reasons.append("Low visual evidence")
            }
            if hardBlockers.isEmpty {
                softBlockers.append(.contentDivergence)
            }
        }

        return PairEligibilityResult(
            eligible: eligible && hardBlockers.isEmpty,
            provisionalBucket: provisionalBucket,
            hardBlockers: hardBlockers,
            softBlockers: softBlockers,
            similarityScore: similarityScore,
            reasonStrings: uniqueStrings(reasons)
        )
    }

    private func visualScore(for featureDistance: Double) -> Double {
        guard featureDistance.isFinite else { return 0 }
        let band = max(SimilarityThresholds.maxVisualSimilarFeatureDistance * 2.0, 0.001)
        let normalized = max(0, 1 - min(featureDistance / band, 1))
        return normalized
    }

    private func timeScore(for delta: Double) -> Double {
        if delta <= SimilarityThresholds.burstWindowSeconds { return 0.18 }
        if delta <= SimilarityThresholds.nearDuplicateWindowSeconds { return 0.15 }
        if delta <= SimilarityThresholds.visualSessionWindowSeconds { return 0.08 }
        if delta <= SimilarityThresholds.extendedSessionWindowSeconds { return 0.03 }
        return 0
    }

    private func variantScore(for variant: VariantRelationship) -> Double {
        switch variant {
        case .none:
            return 0
        case .livePhotoToStill, .editedToOriginal, .hdrVariant, .portraitDepthVariant, .screenshotToSavedImage:
            return 0.05
        }
    }
}

struct ConservativeKeeperRankingService: KeeperRankingService {
    func rankKeeper(in input: SimilarityClusterInput) -> KeeperRankingResult {
        var scoresByID: [String: Double] = [:]
        var reasonsByID: [String: [String]] = [:]
        var signalsByID: [String: KeeperSignals] = [:]

        for asset in input.assets {
            let signals = input.keeperSignalsByAssetID[asset.id] ?? KeeperSignals.conservativeFallback(for: asset)
            signalsByID[asset.id] = signals

            var score = 0.0
            var reasons: [String] = []

            score += signals.sharpness * 0.36
            if signals.sharpness > 0.82 { reasons.append("Sharper") }

            score -= signals.blurPenalty * 0.28
            if signals.blurPenalty < 0.25 { reasons.append("Less blur") }

            score -= signals.motionBlurPenalty * 0.16
            if signals.motionBlurPenalty < 0.20 { reasons.append("Less motion blur") }

            if let eyesOpenScore = signals.eyesOpenScore {
                score += eyesOpenScore * 0.08
                if eyesOpenScore > 0.8 { reasons.append("Eyes open") }
            }

            if let expressionScore = signals.expressionScore {
                score += expressionScore * 0.08
                if expressionScore > 0.8 { reasons.append("Better expression") }
            }

            score += signals.exposureScore * 0.12
            if signals.exposureScore > 0.78 { reasons.append("Better exposure") }

            score += signals.favoriteBonus
            if signals.favoriteBonus > 0 {
                reasons.append("Favorited")
            }

            score += signals.editedBonusOrPenalty
            if signals.editedBonusOrPenalty > 0 {
                reasons.append("Preferred edit")
            }

            score += signals.framingScore * 0.14
            if signals.framingScore > 0.8 { reasons.append("Better framing") }

            score += signals.resolutionTiebreaker * 0.03
            if signals.resolutionTiebreaker > 0.12 { reasons.append("Higher resolution") }

            scoresByID[asset.id] = score
            reasonsByID[asset.id] = uniqueStrings(reasons)
        }

        let ranked = scoresByID.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key < rhs.key
        }

        return KeeperRankingResult(
            keeperAssetID: ranked.first?.key,
            rankedAssetIDs: ranked.map(\.key),
            scoreByAssetID: scoresByID,
            reasonsByAssetID: reasonsByID,
            scoreBreakdownByAssetID: signalsByID
        )
    }
}

struct ConservativeSimilarityClusterClassifier: SimilarityClusterClassifying {
    let pairClassifier: ConservativePairSimilarityClassifier
    let keeperRankingService: ConservativeKeeperRankingService

    init(
        pairClassifier: ConservativePairSimilarityClassifier = ConservativePairSimilarityClassifier(),
        keeperRankingService: ConservativeKeeperRankingService = ConservativeKeeperRankingService()
    ) {
        self.pairClassifier = pairClassifier
        self.keeperRankingService = keeperRankingService
    }

    func classifyCluster(_ input: SimilarityClusterInput) -> SimilarityGroupResult {
        let assetCount = input.assets.count
        guard assetCount >= 2 else {
            return SimilarityGroupResult(
                bucket: .notSimilar,
                confidence: .low,
                action: .doNotSuggestDeletion,
                keeperAssetID: nil,
                deleteCandidateIDs: [],
                reasons: ["Not enough assets to form a group"],
                blockerFlags: [.lowVisualEvidence],
                scoreBreakdown: ScoreBreakdown(
                    similarityScore: 0,
                    timeScore: 0,
                    burstScore: 0,
                    variantScore: 0,
                    screenshotPenalty: 0,
                    aspectPenalty: 0,
                    dimensionPenalty: 0,
                    keeperScore: nil,
                    confidenceScore: 0
                )
            )
        }

        var pairResults: [SimilarityPairKey: PairEligibilityResult] = [:]
        var hardBlockers = Set<BlockerFlag>()
        var softBlockers = Set<BlockerFlag>()
        var reasons: [String] = []

        for lhsIndex in input.assets.indices {
            for rhsIndex in input.assets.indices where rhsIndex > lhsIndex {
                let lhs = input.assets[lhsIndex]
                let rhs = input.assets[rhsIndex]
                let key = SimilarityPairKey(lhs.id, rhs.id)
                let signals = input.pairwiseSignals[key] ?? SimilaritySignals.make(lhs: lhs, rhs: rhs, featureDistance: nil)
                let result = pairClassifier.classifyPair(lhs: lhs, rhs: rhs, signals: signals)
                pairResults[key] = result
                hardBlockers.formUnion(result.hardBlockers)
                softBlockers.formUnion(result.softBlockers)
                reasons.append(contentsOf: result.reasonStrings)
            }
        }

        if hardBlockers.contains(.screenshotMixedWithCamera) {
            let keeperResult = keeperRankingService.rankKeeper(in: input)
            return makeResult(
                bucket: .notSimilar,
                confidence: .low,
                action: .doNotSuggestDeletion,
                keeperResult: keeperResult,
                input: input,
                pairResults: pairResults,
                hardBlockers: hardBlockers,
                softBlockers: softBlockers,
                reasons: uniqueStrings(reasons + ["Screenshots should not mix with camera photos"])
            )
        }

        let allPairScores = pairResults.values.map(\.similarityScore)
        let eligiblePairScores = pairResults.values.filter(\.eligible).map(\.similarityScore)
        let minPairScore = allPairScores.min() ?? 0
        let minEligibleScore = eligiblePairScores.min() ?? 0
        let averagePairScore = allPairScores.isEmpty ? 0 : allPairScores.reduce(0, +) / Double(allPairScores.count)
        let maxTimeSpan = maxTimeSpan(in: input.assets)
        let burstCoverage = input.assets.filter { $0.burstIdentifier != nil }.count
        let sameBurst = burstCoverage == input.assets.count && input.assets.map(\.burstIdentifier).allSatisfy { $0 == input.assets.first?.burstIdentifier }

        if assetCount > 2 && minPairScore < SimilarityThresholds.splitConsistencyFloor && !sameBurst {
            let keeperResult = keeperRankingService.rankKeeper(in: input)
            return makeResult(
                bucket: .notSimilar,
                confidence: .low,
                action: .doNotSuggestDeletion,
                keeperResult: keeperResult,
                input: input,
                pairResults: pairResults,
                hardBlockers: hardBlockers,
                softBlockers: softBlockers,
                reasons: uniqueStrings(reasons + ["Cluster is not stable enough to trust"])
            )
        }

        let burstPairs = pairResults.values.filter { $0.provisionalBucket == .burstShot && $0.eligible }
        let hasBurstSupport = sameBurst || !burstPairs.isEmpty
        let burstDivergence = pairResults.values.contains { $0.provisionalBucket == .burstShot && $0.softBlockers.contains(.burstContentDivergence) }

        var bucket: SimilarityBucket = .notSimilar
        var confidence: GroupConfidence = .low
        var action: SuggestedAction = .doNotSuggestDeletion

        if hasBurstSupport && maxTimeSpan <= SimilarityThresholds.burstWindowSeconds {
            bucket = .burstShot
            if minEligibleScore >= 0.55 && !burstDivergence {
                confidence = .high
                action = .suggestDeleteOthers
            } else if minEligibleScore >= SimilarityThresholds.visualClusterFloor {
                confidence = .medium
                action = .reviewTogetherOnly
            } else {
                confidence = .low
                action = .reviewTogetherOnly
            }
            reasons.append("Burst sequence detected")
        } else if minEligibleScore >= SimilarityThresholds.nearDuplicateClusterFloor
            && maxTimeSpan <= SimilarityThresholds.nearDuplicateWindowSeconds
        {
            bucket = .nearDuplicate
            if minEligibleScore >= 0.60 && softBlockers.isEmpty {
                confidence = .high
                action = .suggestDeleteOthers
            } else if minEligibleScore >= 0.45 {
                confidence = softBlockers.isEmpty ? .medium : .low
                action = .reviewTogetherOnly
            } else {
                confidence = .low
                action = .reviewTogetherOnly
            }
            reasons.append("Near-duplicate match")
        } else if averagePairScore >= SimilarityThresholds.visualClusterFloor
            && maxTimeSpan <= SimilarityThresholds.visualSessionWindowSeconds
        {
            bucket = .visuallySimilar
            confidence = averagePairScore >= 0.25 ? .medium : .low
            action = .reviewTogetherOnly
            reasons.append("Review together, but do not auto-delete")
        } else if hasBurstSupport {
            bucket = .burstShot
            confidence = .low
            action = .reviewTogetherOnly
            reasons.append("Burst is present, but the content diverges too much")
        } else {
            bucket = .notSimilar
            confidence = .low
            action = .doNotSuggestDeletion
            reasons.append("Cluster is too weak to trust")
        }

        if bucket == .nearDuplicate
            && (maxTimeSpan > SimilarityThresholds.nearDuplicateWindowSeconds
                || hardBlockers.contains(.majorCompositionChange)
                || hardBlockers.contains(.differentIntent))
        {
            bucket = .visuallySimilar
            confidence = .medium
            action = .reviewTogetherOnly
            reasons.append("Downgraded from near-duplicate")
        }

        if bucket == .visuallySimilar
            && (hardBlockers.contains(.contentDivergence) || softBlockers.contains(.contentDivergence))
        {
            bucket = .notSimilar
            confidence = .low
            action = .doNotSuggestDeletion
            reasons.append("Downgraded out of similar range")
        }

        let keeperResult = keeperRankingService.rankKeeper(in: input)
        return makeResult(
            bucket: bucket,
            confidence: confidence,
            action: action,
            keeperResult: keeperResult,
            input: input,
            pairResults: pairResults,
            hardBlockers: hardBlockers,
            softBlockers: softBlockers,
            reasons: uniqueStrings(reasons + clusterSummaryReasons(
                bucket: bucket,
                confidence: confidence,
                timeSpan: maxTimeSpan,
                minPairScore: minPairScore,
                averagePairScore: averagePairScore
            ))
        )
    }

    private func makeResult(
        bucket: SimilarityBucket,
        confidence: GroupConfidence,
        action: SuggestedAction,
        keeperResult: KeeperRankingResult,
        input: SimilarityClusterInput,
        pairResults: [SimilarityPairKey: PairEligibilityResult],
        hardBlockers: Set<BlockerFlag>,
        softBlockers: Set<BlockerFlag>,
        reasons: [String]
    ) -> SimilarityGroupResult {
        let keeperScore = keeperResult.keeperAssetID.flatMap { keeperResult.scoreByAssetID[$0] }
        let similarityScore = pairResults.values.isEmpty ? 0 : pairResults.values.map(\.similarityScore).reduce(0, +) / Double(pairResults.values.count)
        let timeScore = self.timeScore(for: maxTimeSpan(in: input.assets))
        let burstScore = input.assets.allSatisfy { $0.burstIdentifier == input.assets.first?.burstIdentifier && $0.burstIdentifier != nil } ? SimilarityThresholds.burstConfidenceBonus : 0
        let variantScore = averageVariantScore(in: input, pairResults: pairResults)
        let aspectPenalty = pairResults.values.contains { $0.softBlockers.contains(.aspectRatioMismatch) } ? SimilarityThresholds.aspectRatioMismatchPenalty : 0
        let dimensionPenalty = pairResults.values.contains { $0.softBlockers.contains(.dimensionMismatch) } ? SimilarityThresholds.dimensionMismatchPenalty : 0
        let screenshotPenalty = pairResults.values.contains { $0.hardBlockers.contains(.screenshotMixedWithCamera) } ? SimilarityThresholds.screenshotPenalty : 0

        let confidenceScore: Double = {
            switch confidence {
            case .high: return 1.0
            case .medium: return 0.65
            case .low: return 0.30
            }
        }()

        let deleteCandidateIDs: [String]
        if action == .suggestDeleteOthers, let keeperAssetID = keeperResult.keeperAssetID {
            deleteCandidateIDs = input.assets.map(\.id).filter { $0 != keeperAssetID }
        } else {
            deleteCandidateIDs = []
        }

        return SimilarityGroupResult(
            bucket: bucket,
            confidence: confidence,
            action: action,
            keeperAssetID: bucket == .notSimilar ? nil : keeperResult.keeperAssetID,
            deleteCandidateIDs: deleteCandidateIDs,
            reasons: reasons,
            blockerFlags: Array(hardBlockers.union(softBlockers)).sorted { $0.rawValue < $1.rawValue },
            scoreBreakdown: ScoreBreakdown(
                similarityScore: similarityScore,
                timeScore: timeScore,
                burstScore: burstScore,
                variantScore: variantScore,
                screenshotPenalty: screenshotPenalty,
                aspectPenalty: aspectPenalty,
                dimensionPenalty: dimensionPenalty,
                keeperScore: keeperScore,
                confidenceScore: confidenceScore
            )
        )
    }

    private func clusterSummaryReasons(
        bucket: SimilarityBucket,
        confidence: GroupConfidence,
        timeSpan: Double,
        minPairScore: Double,
        averagePairScore: Double
    ) -> [String] {
        var reasons: [String] = []
        if bucket == .burstShot {
            reasons.append("Burst confidence: \(confidence.rawValue)")
        }
        if bucket == .nearDuplicate {
            reasons.append("Minimum pair score \(String(format: "%.2f", minPairScore))")
        }
        if bucket == .visuallySimilar {
            reasons.append("Average pair score \(String(format: "%.2f", averagePairScore))")
        }
        if timeSpan > 0 {
            reasons.append("Span \(Int(timeSpan.rounded()))s")
        }
        return reasons
    }

    private func averageVariantScore(
        in input: SimilarityClusterInput,
        pairResults: [SimilarityPairKey: PairEligibilityResult]
    ) -> Double {
        guard !pairResults.isEmpty else { return 0 }
        let descriptorByID = Dictionary(uniqueKeysWithValues: input.assets.map { ($0.id, $0) })
        let variantScores = pairResults.compactMap { key, result -> Double? in
            guard let lhs = descriptorByID[key.lhsID], let rhs = descriptorByID[key.rhsID] else { return nil }
            if lhs.variantRelationshipHint != .none {
                return 0.05
            }
            if rhs.variantRelationshipHint != .none {
                return 0.05
            }
            return result.reasonStrings.contains(where: { $0.contains("variant") }) ? 0.05 : 0
        }
        return variantScores.isEmpty ? 0 : variantScores.reduce(0, +) / Double(variantScores.count)
    }

    private func timeScore(for span: Double) -> Double {
        if span <= SimilarityThresholds.burstWindowSeconds { return 0.18 }
        if span <= SimilarityThresholds.nearDuplicateWindowSeconds { return 0.15 }
        if span <= SimilarityThresholds.visualSessionWindowSeconds { return 0.08 }
        if span <= SimilarityThresholds.extendedSessionWindowSeconds { return 0.03 }
        return 0
    }

    private func maxTimeSpan(in assets: [SimilarityAssetDescriptor]) -> Double {
        let timestamps = assets.compactMap(\.captureTimestamp).sorted()
        guard let first = timestamps.first, let last = timestamps.last else { return 0 }
        return abs(last.timeIntervalSince(first))
    }
}

struct ConservativeSimilarityPolicyEngine: Sendable {
    let pairClassifier: ConservativePairSimilarityClassifier
    let keeperRankingService: ConservativeKeeperRankingService
    let clusterClassifier: ConservativeSimilarityClusterClassifier

    init(
        pairClassifier: ConservativePairSimilarityClassifier = ConservativePairSimilarityClassifier(),
        keeperRankingService: ConservativeKeeperRankingService = ConservativeKeeperRankingService()
    ) {
        self.pairClassifier = pairClassifier
        self.keeperRankingService = keeperRankingService
        self.clusterClassifier = ConservativeSimilarityClusterClassifier(
            pairClassifier: pairClassifier,
            keeperRankingService: keeperRankingService
        )
    }

    func classifyCluster(_ input: SimilarityClusterInput) -> SimilarityGroupResult {
        clusterClassifier.classifyCluster(input)
    }

    func classifyGroup(_ group: PhotoGroup) -> SimilarityGroupResult {
        classifyCluster(group.similarityClusterInput(baseFeatureDistance: Double(group.similarity)))
    }
}

extension KeeperSignals {
    static func conservativeFallback(for descriptor: SimilarityAssetDescriptor) -> KeeperSignals {
        let pixels = Double(max(descriptor.pixelWidth * descriptor.pixelHeight, 1))
        let resolutionScore = min(log10(pixels) / 8.0, 1.0)
        let aspectDistance = min(abs(descriptor.aspectRatio - 1.0), abs(descriptor.aspectRatio - 4.0 / 3.0), abs(descriptor.aspectRatio - 3.0 / 4.0))
        let framingScore = max(0.0, 1.0 - min(aspectDistance, 1.0))

        return KeeperSignals(
            sharpness: resolutionScore,
            blurPenalty: max(0.0, 1.0 - resolutionScore) * 0.65,
            motionBlurPenalty: 0.0,
            eyesOpenScore: nil,
            expressionScore: nil,
            exposureScore: descriptor.isScreenshot ? 0.90 : 0.72,
            favoriteBonus: descriptor.isFavorite ? 0.08 : 0.0,
            editedBonusOrPenalty: descriptor.isEdited ? -0.02 : 0.0,
            framingScore: framingScore,
            resolutionTiebreaker: resolutionScore * 0.2
        )
    }
}

private func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
    min(max(value, lower), upper)
}

private func uniqueStrings(_ strings: [String]) -> [String] {
    var seen = Set<String>()
    return strings.filter { seen.insert($0).inserted }
}
