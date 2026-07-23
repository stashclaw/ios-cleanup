import Foundation

protocol PairSimilarityClassifying: Sendable {
    func classifyPair(
        lhs: SimilarityAssetDescriptor,
        rhs: SimilarityAssetDescriptor,
        signals: SimilaritySignals
    ) -> PairEligibilityResult
}

protocol KeeperRankingService: Sendable {
    func rankKeeper(in input: SimilarityClusterInput) async -> KeeperRankingResult
}

protocol SimilarityClusterClassifying: Sendable {
    func classifyCluster(
        _ input: SimilarityClusterInput,
        keeperResult: KeeperRankingResult
    ) -> SimilarityGroupResult
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

        if abs(lhs.aspectRatio - rhs.aspectRatio)
            > SimilarityThresholds.majorAspectRatioMismatch
        {
            hardBlockers.append(.majorCompositionChange)
            reasons.append("Major composition change")
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
        let validFeatureDistance = signals.featureDistance.flatMap {
            $0.isFinite && $0 >= 0 ? $0 : nil
        }
        let featureDistance = validFeatureDistance ?? Double.greatestFiniteMagnitude
        let visualEvidenceAvailable = validFeatureDistance != nil

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
            softBlockers.append(.hdrVariant)
            reasons.append("HDR variant")
        case .portraitDepthVariant:
            softBlockers.append(.portraitDepthVariant)
            reasons.append("Portrait/depth variant")
        case .screenshotToSavedImage:
            hardBlockers.append(.screenshotMixedWithCamera)
            reasons.append("Screenshot and saved image should not be mixed")
        }

        let isExtremeScreenshotMatch = signals.bothScreenshots
            && featureDistance <= SimilarityThresholds.maxScreenshotDuplicateFeatureDistance
        if timeDelta > SimilarityThresholds.largeTimeGapPenaltyAfterSeconds
            && !isExtremeScreenshotMatch
        {
            softBlockers.append(.largeTimeGap)
            reasons.append("Large time gap")
        }

        let visualScore = visualScore(for: featureDistance)
        let timeScore = timeScore(for: timeDelta)
        let burstScore = signals.isBurstPair ? SimilarityThresholds.burstConfidenceBonus : 0
        let variantScore = variantScore(for: signals.variantRelationship)
        let aspectPenalty = signals.aspectRatioMismatch ? SimilarityThresholds.aspectRatioMismatchPenalty : 0
        let dimensionPenalty = signals.dimensionMismatch ? SimilarityThresholds.dimensionMismatchPenalty : 0
        let lowEvidencePenalty = visualEvidenceAvailable
            ? 0
            : SimilarityThresholds.missingVisualEvidencePenalty

        let similarityScore = clamp(
            visualScore * SimilarityThresholds.featureScoreWeight
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
            && (visualEvidenceAvailable
                ? similarityScore >= SimilarityThresholds.burstPairEligibilityScoreFloor
                : true)

        let nearDuplicateEligible = visualEvidenceAvailable
            && featureDistance <= SimilarityThresholds.maxNearDuplicateFeatureDistance
            && timeDelta <= SimilarityThresholds.nearDuplicateWindowSeconds
            && !signals.aspectRatioMismatch
            && !signals.dimensionMismatch

        let visualEligible = visualEvidenceAvailable
            && featureDistance <= SimilarityThresholds.maxVisualSimilarFeatureDistance
            && timeDelta <= SimilarityThresholds.visualSessionWindowSeconds

        let screenshotDuplicateEligible = signals.bothScreenshots
            && visualEvidenceAvailable
            && featureDistance <= SimilarityThresholds.maxScreenshotDuplicateFeatureDistance

        if burstEligible {
            provisionalBucket = .burstShot
            eligible = true
        } else if screenshotDuplicateEligible {
            provisionalBucket = .nearDuplicate
            eligible = true
        } else if nearDuplicateEligible {
            provisionalBucket = .nearDuplicate
            eligible = true
        } else if visualEligible {
            provisionalBucket = .visuallySimilar
            eligible = true
        }

        if provisionalBucket == .nearDuplicate {
            if signals.variantRelationship != .none && !signals.bothScreenshots {
                provisionalBucket = .visuallySimilar
                reasons.append("Variant pair stays review-only")
            }
            if !isExtremeScreenshotMatch
                && (timeDelta > SimilarityThresholds.nearDuplicateWindowSeconds
                    || signals.aspectRatioMismatch
                    || signals.dimensionMismatch)
            {
                provisionalBucket = .visuallySimilar
                reasons.append("Downgraded from near-duplicate")
            }
        }

        if provisionalBucket == .visuallySimilar
            && timeDelta > SimilarityThresholds.visualSessionWindowSeconds
            && similarityScore < SimilarityThresholds.timeGapVisualScoreFloor
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
            if similarityScore < SimilarityThresholds.visualClusterFloor {
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
            reasonStrings: reasons.uniquePreservingOrder()
        )
    }

    private func visualScore(for featureDistance: Double) -> Double {
        guard featureDistance.isFinite else { return 0 }
        let band = max(SimilarityThresholds.maxVisualSimilarFeatureDistance * 2.0, 0.001)
        let normalized = max(0, 1 - min(featureDistance / band, 1))
        return normalized
    }

    private func timeScore(for delta: Double) -> Double {
        sharedTimeScore(for: delta)
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
    func rankKeeper(in input: SimilarityClusterInput) async -> KeeperRankingResult {
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
            reasonsByID[asset.id] = reasons.uniquePreservingOrder()
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

    init(pairClassifier: ConservativePairSimilarityClassifier = ConservativePairSimilarityClassifier()) {
        self.pairClassifier = pairClassifier
    }

    func classifyCluster(
        _ input: SimilarityClusterInput,
        keeperResult: KeeperRankingResult
    ) -> SimilarityGroupResult {
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
            return makeResult(
                bucket: .notSimilar,
                confidence: .low,
                action: .doNotSuggestDeletion,
                keeperResult: keeperResult,
                input: input,
                pairResults: pairResults,
                hardBlockers: hardBlockers,
                softBlockers: softBlockers,
                reasons: (reasons + ["Screenshots should not mix with camera photos"]).uniquePreservingOrder()
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
        let exactScreenshotGroup = input.assets.allSatisfy(\.isScreenshot)
            && pairResults.values.allSatisfy {
                $0.eligible && $0.provisionalBucket == .nearDuplicate
            }

        if assetCount > 2 && minPairScore < SimilarityThresholds.splitConsistencyFloor && !sameBurst {
            return makeResult(
                bucket: .notSimilar,
                confidence: .low,
                action: .doNotSuggestDeletion,
                keeperResult: keeperResult,
                input: input,
                pairResults: pairResults,
                hardBlockers: hardBlockers,
                softBlockers: softBlockers,
                reasons: (reasons + ["Cluster is not stable enough to trust"]).uniquePreservingOrder()
            )
        }

        let burstPairs = pairResults.values.filter { $0.provisionalBucket == .burstShot && $0.eligible }
        let hasBurstSupport = sameBurst || !burstPairs.isEmpty
        let burstDivergence = pairResults.values.contains { $0.provisionalBucket == .burstShot && $0.softBlockers.contains(.burstContentDivergence) }

        var bucket: SimilarityBucket = .notSimilar
        var confidence: GroupConfidence = .low
        var action: SuggestedAction = .doNotSuggestDeletion

        if exactScreenshotGroup {
            bucket = .nearDuplicate
            if minEligibleScore >= SimilarityThresholds.screenshotAutoDeleteScoreFloor
                && softBlockers.isEmpty
            {
                confidence = .high
                action = .suggestDeleteOthers
            } else {
                confidence = .medium
                action = .reviewTogetherOnly
            }
            reasons.append("Duplicate screenshots of the same content")
        } else if hasBurstSupport && maxTimeSpan <= SimilarityThresholds.burstWindowSeconds {
            bucket = .burstShot
            if minEligibleScore >= SimilarityThresholds.burstAutoDeleteScoreFloor
                && !burstDivergence
                && softBlockers.isEmpty
                && pairResults.values.allSatisfy(\.eligible)
            {
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
        } else if pairResults.values.allSatisfy({
            $0.eligible && $0.provisionalBucket == .nearDuplicate
        })
            && minEligibleScore >= SimilarityThresholds.nearDuplicateClusterFloor
            && maxTimeSpan <= SimilarityThresholds.nearDuplicateWindowSeconds
        {
            bucket = .nearDuplicate
            if minEligibleScore >= SimilarityThresholds.nearDuplicateAutoDeleteScoreFloor
                && softBlockers.isEmpty
            {
                confidence = .high
                action = .suggestDeleteOthers
            } else if minEligibleScore >= SimilarityThresholds.nearDuplicateClusterFloor {
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
            confidence = averagePairScore >= SimilarityThresholds.visualClusterFloor
                ? .medium
                : .low
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
            && !exactScreenshotGroup
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

        return makeResult(
            bucket: bucket,
            confidence: confidence,
            action: action,
            keeperResult: keeperResult,
            input: input,
            pairResults: pairResults,
            hardBlockers: hardBlockers,
            softBlockers: softBlockers,
            reasons: (reasons + clusterSummaryReasons(
                bucket: bucket,
                confidence: confidence,
                timeSpan: maxTimeSpan,
                minPairScore: minPairScore,
                averagePairScore: averagePairScore
            )).uniquePreservingOrder()
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
        sharedTimeScore(for: span)
    }

    private func maxTimeSpan(in assets: [SimilarityAssetDescriptor]) -> Double {
        let timestamps = assets.compactMap(\.captureTimestamp).sorted()
        guard let first = timestamps.first, let last = timestamps.last else { return 0 }
        return abs(last.timeIntervalSince(first))
    }
}

struct ConservativeSimilarityPolicyEngine: Sendable {
    let pairClassifier: ConservativePairSimilarityClassifier
    let keeperRankingService: any KeeperRankingService
    let clusterClassifier: ConservativeSimilarityClusterClassifier

    init(
        pairClassifier: ConservativePairSimilarityClassifier = ConservativePairSimilarityClassifier(),
        keeperRankingService: any KeeperRankingService = ConservativeKeeperRankingService()
    ) {
        self.pairClassifier = pairClassifier
        self.keeperRankingService = keeperRankingService
        self.clusterClassifier = ConservativeSimilarityClusterClassifier(pairClassifier: pairClassifier)
    }

    func evaluateCluster(_ input: SimilarityClusterInput) async -> SimilarityEvaluation {
        let keeperResult = await keeperRankingService.rankKeeper(in: input)
        let groupResult = clusterClassifier.classifyCluster(input, keeperResult: keeperResult)
        return SimilarityEvaluation(
            groupResult: groupResult,
            keeperRankingResult: keeperResult
        )
    }

    func classifyCluster(_ input: SimilarityClusterInput) async -> SimilarityGroupResult {
        (await evaluateCluster(input)).groupResult
    }
}

struct SimilarityCandidateGraph: Sendable {
    func formClusters(
        descriptors: [SimilarityAssetDescriptor],
        pairResults: [SimilarityPairKey: PairEligibilityResult]
    ) -> [[String]] {
        let descriptorsByID = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id, $0) })
        var assignedIDs = Set<String>()
        var clusters: [[String]] = []

        // Photos explicitly marked as one burst remain a burst review unit even
        // when visual evidence diverges. Divergence affects action/confidence later.
        let burstBuckets = Dictionary(
            grouping: descriptors.filter { $0.burstIdentifier != nil },
            by: { $0.burstIdentifier ?? "" }
        )
        for burst in burstBuckets.values.sorted(by: burstSort) {
            let ordered = burst.sorted(by: descriptorSort)
            guard ordered.count >= 2 else { continue }

            for range in SimilarityBurstChunker.ranges(
                assetCount: ordered.count,
                maximumChunkSize: SimilarityThresholds.maxBurstAssetsPerCluster
            ) {
                let ids = ordered[range].map(\.id)
                clusters.append(ids)
                assignedIDs.formUnion(ids)
            }
        }

        let eligibleEdges = pairResults
            .filter { key, result in
                result.eligible
                    && result.provisionalBucket != .burstShot
                    && descriptorsByID[key.lhsID] != nil
                    && descriptorsByID[key.rhsID] != nil
                    && !assignedIDs.contains(key.lhsID)
                    && !assignedIDs.contains(key.rhsID)
            }
            .sorted { lhs, rhs in
                if lhs.value.similarityScore != rhs.value.similarityScore {
                    return lhs.value.similarityScore > rhs.value.similarityScore
                }
                if lhs.key.lhsID != rhs.key.lhsID {
                    return lhs.key.lhsID < rhs.key.lhsID
                }
                return lhs.key.rhsID < rhs.key.rhsID
            }

        var strongAdjacency: [String: Set<String>] = [:]
        for (key, result) in eligibleEdges
            where result.similarityScore >= SimilarityThresholds.splitConsistencyFloor
        {
            strongAdjacency[key.lhsID, default: []].insert(key.rhsID)
            strongAdjacency[key.rhsID, default: []].insert(key.lhsID)
        }

        for (seedKey, _) in eligibleEdges {
            guard !assignedIDs.contains(seedKey.lhsID),
                  !assignedIDs.contains(seedKey.rhsID) else {
                continue
            }

            var cluster = [seedKey.lhsID, seedKey.rhsID]
            var completeLinkCandidates = strongAdjacency[seedKey.lhsID, default: []]
                .intersection(strongAdjacency[seedKey.rhsID, default: []])
                .subtracting(assignedIDs)
                .subtracting(cluster)

            while let nextID = bestCompleteLinkCandidate(
                for: cluster,
                candidates: completeLinkCandidates,
                pairResults: pairResults
            ) {
                cluster.append(nextID)
                completeLinkCandidates.formIntersection(
                    strongAdjacency[nextID, default: []]
                )
                completeLinkCandidates.subtract(assignedIDs)
                completeLinkCandidates.subtract(cluster)
            }

            let orderedCluster = cluster.sorted { lhs, rhs in
                guard let lhsDescriptor = descriptorsByID[lhs],
                      let rhsDescriptor = descriptorsByID[rhs] else {
                    return lhs < rhs
                }
                return descriptorSort(lhsDescriptor, rhsDescriptor)
            }
            clusters.append(orderedCluster)
            assignedIDs.formUnion(orderedCluster)
        }

        return clusters
    }

    private func bestCompleteLinkCandidate(
        for cluster: [String],
        candidates: Set<String>,
        pairResults: [SimilarityPairKey: PairEligibilityResult]
    ) -> String? {
        let scored = candidates.compactMap { candidateID -> (String, Double)? in
            let links = cluster.compactMap {
                pairResults[SimilarityPairKey(candidateID, $0)]
            }
            guard links.count == cluster.count,
                  links.allSatisfy({
                      $0.eligible
                          && $0.similarityScore >= SimilarityThresholds.splitConsistencyFloor
                  }) else {
                return nil
            }
            let averageScore = links.map(\.similarityScore).reduce(0, +) / Double(links.count)
            return (candidateID, averageScore)
        }

        return scored.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0 < rhs.0
        }.first?.0
    }

    private func burstSort(
        _ lhs: [SimilarityAssetDescriptor],
        _ rhs: [SimilarityAssetDescriptor]
    ) -> Bool {
        let lhsDate = lhs.compactMap(\.captureTimestamp).min() ?? .distantPast
        let rhsDate = rhs.compactMap(\.captureTimestamp).min() ?? .distantPast
        if lhsDate != rhsDate { return lhsDate < rhsDate }
        return (lhs.first?.burstIdentifier ?? "") < (rhs.first?.burstIdentifier ?? "")
    }

    private func descriptorSort(
        _ lhs: SimilarityAssetDescriptor,
        _ rhs: SimilarityAssetDescriptor
    ) -> Bool {
        let lhsDate = lhs.captureTimestamp ?? .distantPast
        let rhsDate = rhs.captureTimestamp ?? .distantPast
        if lhsDate != rhsDate { return lhsDate < rhsDate }
        return lhs.id < rhs.id
    }
}

enum SimilarityBurstChunker {
    static func ranges(
        assetCount: Int,
        maximumChunkSize: Int
    ) -> [Range<Int>] {
        guard assetCount >= 2, maximumChunkSize >= 2 else { return [] }

        var chunkSizes = Array(
            repeating: maximumChunkSize,
            count: assetCount / maximumChunkSize
        )
        let remainder = assetCount % maximumChunkSize

        if remainder == 1, let lastIndex = chunkSizes.indices.last {
            // A one-photo review group is not useful. Borrow one asset from the
            // preceding chunk so every burst asset remains reviewable.
            chunkSizes[lastIndex] -= 1
            chunkSizes.append(2)
        } else if remainder > 0 {
            chunkSizes.append(remainder)
        }

        var start = 0
        return chunkSizes.map { size in
            defer { start += size }
            return start..<(start + size)
        }
    }
}

extension KeeperSignals {
    static func conservativeFallback(for descriptor: SimilarityAssetDescriptor) -> KeeperSignals {
        let pixels = Double(max(descriptor.pixelWidth, 1))
            * Double(max(descriptor.pixelHeight, 1))
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
            editedBonusOrPenalty: descriptor.isEdited ? 0.04 : 0.0,
            framingScore: framingScore,
            resolutionTiebreaker: resolutionScore * 0.2
        )
    }
}

// MARK: - Shared Helpers

/// Shared time-proximity score used by both pair and cluster classifiers.
private func sharedTimeScore(for delta: Double) -> Double {
    if delta <= SimilarityThresholds.burstWindowSeconds { return 0.18 }
    if delta <= SimilarityThresholds.nearDuplicateWindowSeconds { return 0.15 }
    if delta <= SimilarityThresholds.visualSessionWindowSeconds { return 0.08 }
    return 0
}

// clamp() and uniqueStrings() consolidated into SharedHelpers.swift
