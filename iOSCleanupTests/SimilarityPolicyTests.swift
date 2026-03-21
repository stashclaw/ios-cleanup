import XCTest
@testable import iOSCleanup

final class SimilarityPolicyTests: XCTestCase {
    private let pairClassifier = ConservativePairSimilarityClassifier()
    private let policyEngine = ConservativeSimilarityPolicyEngine()
    private let keeperRanker = ConservativeKeeperRankingService()

    func testExactDuplicatesClassifyAsNearDuplicateHighConfidence() {
        let a = asset("a", seconds: 0)
        let b = asset("b", seconds: 4)
        let signals = pair(a, b, distance: 0.01)

        let result = pairClassifier.classifyPair(lhs: a, rhs: b, signals: signals)
        XCTAssertTrue(result.eligible)
        XCTAssertEqual(result.provisionalBucket, .nearDuplicate)
        XCTAssertTrue(result.softBlockers.isEmpty)

        let cluster = clusterInput(assets: [a, b], pairs: [
            pairKey("a", "b"): signals
        ])
        let group = policyEngine.classifyCluster(cluster)

        XCTAssertEqual(group.bucket, .nearDuplicate)
        XCTAssertEqual(group.confidence, .high)
        XCTAssertEqual(group.action, .suggestDeleteOthers)
        XCTAssertNotNil(group.keeperAssetID)
        XCTAssertFalse(group.deleteCandidateIDs.contains(group.keeperAssetID ?? ""))
    }

    func testBurstSequenceClassifiesAsBurstShot() {
        let a = asset("a", seconds: 0, burst: "burst-1")
        let b = asset("b", seconds: 1, burst: "burst-1")
        let signals = pair(a, b, distance: 0.03)

        let result = pairClassifier.classifyPair(lhs: a, rhs: b, signals: signals)
        XCTAssertTrue(result.eligible)
        XCTAssertEqual(result.provisionalBucket, .burstShot)

        let group = policyEngine.classifyCluster(clusterInput(assets: [a, b], pairs: [
            pairKey("a", "b"): signals
        ]))

        XCTAssertEqual(group.bucket, .burstShot)
        XCTAssertEqual(group.confidence, .high)
        XCTAssertEqual(group.action, .suggestDeleteOthers)
    }

    func testBorderlineNearDuplicatesDowngradeToVisualSimilar() {
        let a = asset("a", seconds: 0, width: 4000, height: 3000)
        let b = asset("b", seconds: 12, width: 3000, height: 3000)
        let signals = pair(a, b, distance: 0.055)

        let result = pairClassifier.classifyPair(lhs: a, rhs: b, signals: signals)
        XCTAssertTrue(result.eligible)
        XCTAssertEqual(result.provisionalBucket, .visuallySimilar)
        XCTAssertTrue(result.softBlockers.contains(.aspectRatioMismatch))

        let group = policyEngine.classifyCluster(clusterInput(assets: [a, b], pairs: [
            pairKey("a", "b"): signals
        ]))

        XCTAssertEqual(group.bucket, .visuallySimilar)
        XCTAssertEqual(group.action, .reviewTogetherOnly)
        XCTAssertEqual(group.confidence, .medium)
    }

    func testScreenshotMixedWithCameraIsBlocked() {
        let screenshot = asset("shot", seconds: 0, screenshot: true)
        let camera = asset("cam", seconds: 1)
        let signals = pair(screenshot, camera, distance: 0.02)

        let result = pairClassifier.classifyPair(lhs: screenshot, rhs: camera, signals: signals)
        XCTAssertFalse(result.eligible)
        XCTAssertTrue(result.hardBlockers.contains(.screenshotMixedWithCamera))
        XCTAssertEqual(result.provisionalBucket, .notSimilar)

        let group = policyEngine.classifyCluster(clusterInput(assets: [screenshot, camera], pairs: [
            pairKey("shot", "cam"): signals
        ]))

        XCTAssertEqual(group.bucket, .notSimilar)
        XCTAssertEqual(group.action, .doNotSuggestDeletion)
        XCTAssertTrue(group.blockerFlags.contains(.screenshotMixedWithCamera))
    }

    func testEditedOriginalPairStaysReviewableButNotAutoDelete() {
        let original = asset("orig", seconds: 0)
        let edited = asset("edit", seconds: 8, edited: true)
        let signals = pair(original, edited, distance: 0.035)

        let result = pairClassifier.classifyPair(lhs: original, rhs: edited, signals: signals)
        XCTAssertTrue(result.eligible)
        XCTAssertEqual(result.provisionalBucket, .visuallySimilar)
        XCTAssertTrue(result.softBlockers.contains(.editedStateDivergence))

        let group = policyEngine.classifyCluster(clusterInput(assets: [original, edited], pairs: [
            pairKey("orig", "edit"): signals
        ]))

        XCTAssertEqual(group.bucket, .visuallySimilar)
        XCTAssertEqual(group.action, .reviewTogetherOnly)
        XCTAssertEqual(group.confidence, .medium)
    }

    func testKeeperSelectionPrefersScoreOverInputOrder() {
        let low = asset("low", seconds: 10, width: 1200, height: 800)
        let high = asset("high", seconds: 0, width: 4032, height: 3024, edited: true)

        let input = SimilarityClusterInput(
            assets: [low, high],
            keeperSignalsByAssetID: [
                "low": KeeperSignals(
                    sharpness: 0.10,
                    blurPenalty: 0.80,
                    motionBlurPenalty: 0.30,
                    eyesOpenScore: nil,
                    expressionScore: nil,
                    exposureScore: 0.40,
                    favoriteBonus: 0,
                    editedBonusOrPenalty: 0,
                    framingScore: 0.20,
                    resolutionTiebreaker: 0.0
                ),
                "high": KeeperSignals(
                    sharpness: 0.98,
                    blurPenalty: 0.02,
                    motionBlurPenalty: 0.00,
                    eyesOpenScore: nil,
                    expressionScore: nil,
                    exposureScore: 0.92,
                    favoriteBonus: 0.08,
                    editedBonusOrPenalty: 0.0,
                    framingScore: 0.95,
                    resolutionTiebreaker: 0.18
                )
            ]
        )

        let result = keeperRanker.rankKeeper(in: input)
        XCTAssertEqual(result.keeperAssetID, "high")
        XCTAssertEqual(result.rankedAssetIDs.first, "high")
        XCTAssertNotEqual(result.rankedAssetIDs.first, "low")
    }

    func testDeleteCandidateIDsNeverIncludeKeeperAssetID() {
        let a = asset("a", seconds: 0)
        let b = asset("b", seconds: 5)
        let result = policyEngine.classifyCluster(clusterInput(assets: [a, b], pairs: [
            pairKey("a", "b"): pair(a, b, distance: 0.02)
        ]))

        XCTAssertEqual(result.bucket, .nearDuplicate)
        XCTAssertEqual(result.action, .suggestDeleteOthers)
        XCTAssertNotNil(result.keeperAssetID)
        XCTAssertFalse(result.deleteCandidateIDs.contains(result.keeperAssetID ?? ""))
        XCTAssertEqual(result.deleteCandidateIDs.count, 1)
    }

    func testVisuallySimilarDefaultsToReviewOnly() {
        let a = asset("a", seconds: 0, width: 4032, height: 3024)
        let b = asset("b", seconds: 120, width: 3000, height: 3000)
        let c = asset("c", seconds: 240, width: 3024, height: 4032)

        let result = policyEngine.classifyCluster(clusterInput(assets: [a, b, c], pairs: [
            pairKey("a", "b"): pair(a, b, distance: 0.09),
            pairKey("a", "c"): pair(a, c, distance: 0.11),
            pairKey("b", "c"): pair(b, c, distance: 0.10)
        ]))

        XCTAssertEqual(result.bucket, .visuallySimilar)
        XCTAssertEqual(result.action, .reviewTogetherOnly)
        XCTAssertNotEqual(result.action, .suggestDeleteOthers)

        let group = PhotoGroup(
            assets: [],
            similarity: 0.09,
            reason: .visuallySimilar,
            groupConfidence: .medium,
            recommendedAction: .reviewManually,
            keeperAssetID: "ga",
            deleteCandidateIDs: [],
            bestShotPhotoId: "ga",
            candidates: [
                SimilarPhotoCandidate(photoId: "ga", assetReference: "ga", captureTimestamp: Date(), isBestShot: true, bestShotScore: 0.9, bestShotReasons: ["Keeper"], issueFlags: [], isProtected: false, isSelectedForTrash: false, isViewed: false, selectionState: .keep, technicalScores: nil),
                SimilarPhotoCandidate(photoId: "gb", assetReference: "gb", captureTimestamp: Date(), isBestShot: false, bestShotScore: 0.4, bestShotReasons: [], issueFlags: [.lowConfidence], isProtected: false, isSelectedForTrash: true, isViewed: false, selectionState: .trash, technicalScores: nil),
                SimilarPhotoCandidate(photoId: "gc", assetReference: "gc", captureTimestamp: Date(), isBestShot: false, bestShotScore: 0.3, bestShotReasons: [], issueFlags: [.lowConfidence], isProtected: false, isSelectedForTrash: true, isViewed: false, selectionState: .trash, technicalScores: nil)
            ]
        )

        XCTAssertTrue(group.deleteCandidateIDs.isEmpty)
        XCTAssertEqual(group.reclaimableBytes, 0)
        XCTAssertTrue(group.deleteCandidateAssets.isEmpty)
        XCTAssertTrue(group.candidates.dropFirst().allSatisfy { $0.selectionState == SimilarSelectionState.undecided })
        XCTAssertTrue(group.candidates.dropFirst().allSatisfy { $0.isSelectedForTrash == false })
    }

    func testVariantPairsStayReviewable() {
        let live = SimilarityAssetDescriptor(
            id: "live",
            captureTimestamp: Date(timeIntervalSinceReferenceDate: 0),
            pixelWidth: 4000,
            pixelHeight: 3000,
            isLivePhoto: true
        )
        let still = SimilarityAssetDescriptor(
            id: "still",
            captureTimestamp: Date(timeIntervalSinceReferenceDate: 2),
            pixelWidth: 4000,
            pixelHeight: 3000,
            isLivePhoto: false
        )

        let signals = SimilaritySignals.make(lhs: live, rhs: still, featureDistance: 0.03)
        let result = pairClassifier.classifyPair(lhs: live, rhs: still, signals: signals)

        XCTAssertTrue(result.eligible)
        XCTAssertEqual(result.provisionalBucket, .visuallySimilar)
        XCTAssertTrue(result.softBlockers.contains(.livePhotoVariant))
    }

    func testCacheRehydrationResolvesByAssetIdentifiers() {
        let cached = CachedPhotoGroup(
            id: UUID(),
            assetIdentifiers: ["a", "b", "c"],
            similarity: 0.01,
            reason: .nearDuplicate,
            groupType: .nearDuplicate,
            groupConfidence: .high,
            reviewState: .unreviewed,
            recommendedAction: .keepBestTrashRest,
            keeperAssetID: "b",
            deleteCandidateIDs: ["a", "c"],
            bestShotPhotoId: "b",
            groupReasonsSummary: ["Test"],
            blockerFlags: [],
            scoreBreakdown: nil,
            captureDateStart: nil,
            captureDateEnd: nil,
            candidates: [],
            reclaimableBytes: 0
        )

        XCTAssertEqual(cached.resolvedAssetIdentifiers(using: ["b", "c", "x"]), ["b", "c"])
        XCTAssertNil(cached.resolvedAssetIdentifiers(using: ["only-one"]))
    }

    func testDeletionGuardrailsRejectKeeperInDeleteList() {
        XCTAssertThrowsError(
            try PhotoDeletionGuardrails.validate(
                keeperAssetID: "keeper",
                deleteCandidateIDs: ["keeper", "other"]
            )
        ) { error in
            XCTAssertEqual(error as? PhotoDeletionGuardrailError, .keeperIncludedInDeleteCandidates)
        }
    }

    func testChainingSplitCaseRejectsNoisyCluster() {
        let a = asset("a", seconds: 0)
        let b = asset("b", seconds: 3)
        let c = asset("c", seconds: 360)

        let ab = pair(a, b, distance: 0.025)
        let bc = pair(b, c, distance: 0.028)
        let ac = pair(a, c, distance: 0.18)

        let group = policyEngine.classifyCluster(clusterInput(assets: [a, b, c], pairs: [
            pairKey("a", "b"): ab,
            pairKey("b", "c"): bc,
            pairKey("a", "c"): ac
        ]))

        XCTAssertEqual(group.bucket, .notSimilar)
        XCTAssertEqual(group.action, .doNotSuggestDeletion)
        XCTAssertTrue(group.blockerFlags.contains(.contentDivergence))
    }

    private func asset(
        _ id: String,
        seconds: TimeInterval,
        width: Int = 4000,
        height: Int = 3000,
        screenshot: Bool = false,
        burst: String? = nil,
        edited: Bool = false
    ) -> SimilarityAssetDescriptor {
        SimilarityAssetDescriptor(
            id: id,
            captureTimestamp: Date(timeIntervalSinceReferenceDate: seconds),
            pixelWidth: width,
            pixelHeight: height,
            isScreenshot: screenshot,
            burstIdentifier: burst,
            isEdited: edited
        )
    }

    private func pair(_ lhs: SimilarityAssetDescriptor, _ rhs: SimilarityAssetDescriptor, distance: Double) -> SimilaritySignals {
        SimilaritySignals.make(lhs: lhs, rhs: rhs, featureDistance: distance)
    }

    private func pairKey(_ a: String, _ b: String) -> SimilarityPairKey {
        SimilarityPairKey(a, b)
    }

    private func clusterInput(
        assets: [SimilarityAssetDescriptor],
        pairs: [SimilarityPairKey: SimilaritySignals]
    ) -> SimilarityClusterInput {
        SimilarityClusterInput(assets: assets, pairwiseSignals: pairs)
    }
}
