import XCTest
import Photos
@testable import iOSCleanup

final class SimilarityPolicyTests: XCTestCase {
    private let pairClassifier = ConservativePairSimilarityClassifier()
    private let policyEngine = ConservativeSimilarityPolicyEngine()
    private let keeperRanker = ConservativeKeeperRankingService()

    func testExactDuplicatesClassifyAsNearDuplicateHighConfidence() async {
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
        let group = await policyEngine.classifyCluster(cluster)

        XCTAssertEqual(group.bucket, .nearDuplicate)
        XCTAssertEqual(group.confidence, .high)
        XCTAssertEqual(group.action, .suggestDeleteOthers)
        XCTAssertNotNil(group.keeperAssetID)
        XCTAssertFalse(group.deleteCandidateIDs.contains(group.keeperAssetID ?? ""))
    }

    func testBurstSequenceClassifiesAsBurstShot() async {
        let a = asset("a", seconds: 0, burst: "burst-1")
        let b = asset("b", seconds: 1, burst: "burst-1")
        let signals = pair(a, b, distance: 0.03)

        let result = pairClassifier.classifyPair(lhs: a, rhs: b, signals: signals)
        XCTAssertTrue(result.eligible)
        XCTAssertEqual(result.provisionalBucket, .burstShot)

        let group = await policyEngine.classifyCluster(clusterInput(assets: [a, b], pairs: [
            pairKey("a", "b"): signals
        ]))

        XCTAssertEqual(group.bucket, .burstShot)
        XCTAssertEqual(group.confidence, .high)
        XCTAssertEqual(group.action, .suggestDeleteOthers)
    }

    func testBorderlineNearDuplicatesDowngradeToVisualSimilar() async {
        let a = asset("a", seconds: 0, width: 4000, height: 3000)
        let b = asset("b", seconds: 12, width: 3000, height: 3000)
        let signals = pair(a, b, distance: 0.055)

        let result = pairClassifier.classifyPair(lhs: a, rhs: b, signals: signals)
        XCTAssertTrue(result.eligible)
        XCTAssertEqual(result.provisionalBucket, .visuallySimilar)
        XCTAssertTrue(result.softBlockers.contains(.aspectRatioMismatch))

        let group = await policyEngine.classifyCluster(clusterInput(assets: [a, b], pairs: [
            pairKey("a", "b"): signals
        ]))

        XCTAssertEqual(group.bucket, .visuallySimilar)
        XCTAssertEqual(group.action, .reviewTogetherOnly)
        XCTAssertEqual(group.confidence, .medium)
    }

    func testExpandedSessionBandCreatesReviewOnlyGroup() async {
        let a = asset("a", seconds: 0)
        let b = asset("b", seconds: 10 * 60)
        let signals = pair(a, b, distance: 0.16)

        let pairResult = pairClassifier.classifyPair(
            lhs: a,
            rhs: b,
            signals: signals
        )
        let group = await policyEngine.classifyCluster(
            clusterInput(
                assets: [a, b],
                pairs: [pairKey("a", "b"): signals]
            )
        )

        XCTAssertTrue(pairResult.eligible)
        XCTAssertEqual(pairResult.provisionalBucket, .visuallySimilar)
        XCTAssertEqual(group.bucket, .visuallySimilar)
        XCTAssertEqual(group.action, .reviewTogetherOnly)
        XCTAssertTrue(group.deleteCandidateIDs.isEmpty)
    }

    func testExpandedReviewBoundaryStaysLowConfidenceAndNonDestructive() async {
        let a = asset("a", seconds: 0)
        let b = asset("b", seconds: 5 * 60)
        let signals = pair(
            a,
            b,
            distance: SimilarityThresholds.maxVisualSimilarFeatureDistance
        )

        let group = await policyEngine.classifyCluster(
            clusterInput(
                assets: [a, b],
                pairs: [pairKey("a", "b"): signals]
            )
        )

        XCTAssertEqual(group.bucket, .visuallySimilar)
        XCTAssertEqual(group.confidence, .low)
        XCTAssertEqual(group.action, .reviewTogetherOnly)
        XCTAssertTrue(group.deleteCandidateIDs.isEmpty)
    }

    func testStrongExtendedSessionMatchCreatesReviewOnlyGroup() async {
        let a = asset("a", seconds: 0)
        let b = asset("b", seconds: 45 * 60)
        let signals = pair(
            a,
            b,
            distance: SimilarityThresholds.maxExtendedVisualFeatureDistance
        )

        let pairResult = pairClassifier.classifyPair(
            lhs: a,
            rhs: b,
            signals: signals
        )
        let group = await policyEngine.classifyCluster(
            clusterInput(
                assets: [a, b],
                pairs: [pairKey("a", "b"): signals]
            )
        )

        XCTAssertTrue(pairResult.eligible)
        XCTAssertEqual(pairResult.provisionalBucket, .visuallySimilar)
        XCTAssertTrue(pairResult.softBlockers.contains(.largeTimeGap))
        XCTAssertEqual(group.bucket, .visuallySimilar)
        XCTAssertEqual(group.confidence, .low)
        XCTAssertEqual(group.action, .reviewTogetherOnly)
        XCTAssertTrue(group.deleteCandidateIDs.isEmpty)
    }

    func testExtendedSessionRejectsMerelyModerateVisualMatch() async {
        let a = asset("a", seconds: 0)
        let b = asset("b", seconds: 45 * 60)
        let signals = pair(
            a,
            b,
            distance: SimilarityThresholds.maxExtendedVisualFeatureDistance + 0.01
        )

        let pairResult = pairClassifier.classifyPair(
            lhs: a,
            rhs: b,
            signals: signals
        )
        let group = await policyEngine.classifyCluster(
            clusterInput(
                assets: [a, b],
                pairs: [pairKey("a", "b"): signals]
            )
        )

        XCTAssertFalse(pairResult.eligible)
        XCTAssertEqual(pairResult.provisionalBucket, .notSimilar)
        XCTAssertEqual(group.bucket, .notSimilar)
        XCTAssertEqual(group.action, .doNotSuggestDeletion)
    }

    func testNearDuplicateBoundaryDoesNotGainDeleteRecommendation() async {
        let a = asset("a", seconds: 0)
        let b = asset("b", seconds: 10)
        let signals = pair(
            a,
            b,
            distance: SimilarityThresholds.maxNearDuplicateFeatureDistance
        )

        let group = await policyEngine.classifyCluster(
            clusterInput(
                assets: [a, b],
                pairs: [pairKey("a", "b"): signals]
            )
        )

        XCTAssertEqual(group.bucket, .nearDuplicate)
        XCTAssertEqual(group.action, .reviewTogetherOnly)
        XCTAssertTrue(group.deleteCandidateIDs.isEmpty)
    }

    func testScreenshotMixedWithCameraIsBlocked() async {
        let screenshot = asset("shot", seconds: 0, screenshot: true)
        let camera = asset("cam", seconds: 1)
        let signals = pair(screenshot, camera, distance: 0.02)

        let result = pairClassifier.classifyPair(lhs: screenshot, rhs: camera, signals: signals)
        XCTAssertFalse(result.eligible)
        XCTAssertTrue(result.hardBlockers.contains(.screenshotMixedWithCamera))
        XCTAssertEqual(result.provisionalBucket, .notSimilar)

        let group = await policyEngine.classifyCluster(clusterInput(assets: [screenshot, camera], pairs: [
            pairKey("shot", "cam"): signals
        ]))

        XCTAssertEqual(group.bucket, .notSimilar)
        XCTAssertEqual(group.action, .doNotSuggestDeletion)
        XCTAssertTrue(group.blockerFlags.contains(.screenshotMixedWithCamera))
    }

    func testMajorCompositionChangeIsHardBlocked() {
        let landscape = asset("landscape", seconds: 0, width: 4_000, height: 3_000)
        let portraitCrop = asset("portrait", seconds: 1, width: 1_000, height: 3_000)
        let signals = pair(landscape, portraitCrop, distance: 0.001)

        let result = pairClassifier.classifyPair(
            lhs: landscape,
            rhs: portraitCrop,
            signals: signals
        )

        XCTAssertFalse(result.eligible)
        XCTAssertEqual(result.provisionalBucket, .notSimilar)
        XCTAssertTrue(result.hardBlockers.contains(.majorCompositionChange))
    }

    func testEditedOriginalPairStaysReviewableButNotAutoDelete() async {
        let original = asset("orig", seconds: 0)
        let edited = asset("edit", seconds: 8, edited: true)
        let signals = pair(original, edited, distance: 0.035)

        let result = pairClassifier.classifyPair(lhs: original, rhs: edited, signals: signals)
        XCTAssertTrue(result.eligible)
        XCTAssertEqual(result.provisionalBucket, .visuallySimilar)
        XCTAssertTrue(result.softBlockers.contains(.editedStateDivergence))

        let group = await policyEngine.classifyCluster(clusterInput(assets: [original, edited], pairs: [
            pairKey("orig", "edit"): signals
        ]))

        XCTAssertEqual(group.bucket, .visuallySimilar)
        XCTAssertEqual(group.action, .reviewTogetherOnly)
        XCTAssertEqual(group.confidence, .medium)
    }

    func testKeeperSelectionPrefersScoreOverInputOrder() async {
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

        let result = await keeperRanker.rankKeeper(in: input)
        XCTAssertEqual(result.keeperAssetID, "high")
        XCTAssertEqual(result.rankedAssetIDs.first, "high")
        XCTAssertNotEqual(result.rankedAssetIDs.first, "low")
    }

    func testDeleteCandidateIDsNeverIncludeKeeperAssetID() async {
        let a = asset("a", seconds: 0)
        let b = asset("b", seconds: 5)
        let result = await policyEngine.classifyCluster(clusterInput(assets: [a, b], pairs: [
            pairKey("a", "b"): pair(a, b, distance: 0.02)
        ]))

        XCTAssertEqual(result.bucket, .nearDuplicate)
        XCTAssertEqual(result.action, .suggestDeleteOthers)
        XCTAssertNotNil(result.keeperAssetID)
        XCTAssertFalse(result.deleteCandidateIDs.contains(result.keeperAssetID ?? ""))
        XCTAssertEqual(result.deleteCandidateIDs.count, 1)
    }

    @MainActor
    func testHighConfidenceNearDuplicateSelectsNonKeepersWhenPlanIsMissing() {
        let keeper = TestPhotoAsset(localIdentifier: "keeper")
        let other = TestPhotoAsset(localIdentifier: "other")
        let group = PhotoGroup(
            assets: [keeper, other],
            similarity: 0.98,
            reason: .nearDuplicate,
            groupConfidence: .high,
            recommendedAction: .keepBestTrashRest,
            keeperAssetID: "keeper",
            deleteCandidateIDs: [],
            candidates: [
                candidate("keeper", isBestShot: true),
                candidate("other", isBestShot: false)
            ]
        )

        XCTAssertEqual(group.recommendedAction, .keepBestTrashRest)
        XCTAssertEqual(group.deleteCandidateIDs, ["other"])
        XCTAssertTrue(group.isAutoCleanEligible)
        XCTAssertEqual(
            group.candidates.first { $0.photoId == "other" }?.selectionState,
            .trash
        )
        XCTAssertTrue(
            group.candidates.first { $0.photoId == "other" }?
                .isSelectedForTrash == true
        )
    }

    func testMalformedDeletePlanDowngradesInsteadOfSilentlyFiltering() {
        let group = PhotoGroup(
            assets: [],
            similarity: 0.98,
            reason: .nearDuplicate,
            groupConfidence: .high,
            recommendedAction: .keepBestTrashRest,
            keeperAssetID: "keeper",
            deleteCandidateIDs: ["other", "outside"],
            candidates: [
                candidate("keeper", isBestShot: true),
                candidate("other", isBestShot: false)
            ]
        )

        XCTAssertEqual(group.recommendedAction, .reviewManually)
        XCTAssertTrue(group.deleteCandidateIDs.isEmpty)
        XCTAssertFalse(group.isAutoCleanEligible)
    }

    func testVisuallySimilarDefaultsToReviewOnly() async {
        let a = asset("a", seconds: 0, width: 4032, height: 3024)
        let b = asset("b", seconds: 120, width: 4032, height: 3024)
        let c = asset("c", seconds: 240, width: 4032, height: 3024)

        let result = await policyEngine.classifyCluster(clusterInput(assets: [a, b, c], pairs: [
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

    func testChainingSplitCaseRejectsNoisyCluster() async {
        let a = asset("a", seconds: 0)
        let b = asset("b", seconds: 3)
        let c = asset("c", seconds: 360)

        let ab = pair(a, b, distance: 0.025)
        let bc = pair(b, c, distance: 0.028)
        let ac = pair(a, c, distance: 0.18)

        let group = await policyEngine.classifyCluster(clusterInput(assets: [a, b, c], pairs: [
            pairKey("a", "b"): ab,
            pairKey("b", "c"): bc,
            pairKey("a", "c"): ac
        ]))

        XCTAssertEqual(group.bucket, .notSimilar)
        XCTAssertEqual(group.action, .doNotSuggestDeletion)
        XCTAssertTrue(group.blockerFlags.contains(.contentDivergence))
    }

    func testHDRVariantStaysReviewOnly() async {
        let standard = SimilarityAssetDescriptor(
            id: "standard",
            captureTimestamp: Date(timeIntervalSinceReferenceDate: 0),
            pixelWidth: 4_000,
            pixelHeight: 3_000
        )
        let hdr = SimilarityAssetDescriptor(
            id: "hdr",
            captureTimestamp: Date(timeIntervalSinceReferenceDate: 1),
            pixelWidth: 4_000,
            pixelHeight: 3_000,
            isHDR: true
        )
        let signals = pair(standard, hdr, distance: 0.02)

        let pairResult = pairClassifier.classifyPair(
            lhs: standard,
            rhs: hdr,
            signals: signals
        )
        let group = await policyEngine.classifyCluster(
            clusterInput(
                assets: [standard, hdr],
                pairs: [pairKey("standard", "hdr"): signals]
            )
        )

        XCTAssertEqual(pairResult.provisionalBucket, .visuallySimilar)
        XCTAssertTrue(pairResult.softBlockers.contains(.hdrVariant))
        XCTAssertEqual(group.bucket, .visuallySimilar)
        XCTAssertEqual(group.action, .reviewTogetherOnly)
        XCTAssertTrue(group.deleteCandidateIDs.isEmpty)
    }

    @MainActor
    func testDuckModeUndoLastSwipeRestoresPendingDecision() async throws {
        let deleteCandidate = TestPhotoAsset(localIdentifier: "delete-candidate")
        let keeper = TestPhotoAsset(localIdentifier: "keeper")
        let group = PhotoGroup(
            assets: [deleteCandidate, keeper],
            similarity: 0.98,
            reason: .nearDuplicate,
            groupConfidence: .high,
            recommendedAction: .keepBestTrashRest,
            keeperAssetID: keeper.localIdentifier,
            deleteCandidateIDs: [deleteCandidate.localIdentifier]
        )
        XCTAssertTrue(group.isAutoCleanEligible)

        let viewModel = SwipeModeViewModel(groups: [group])
        XCTAssertEqual(viewModel.current?.id, deleteCandidate.localIdentifier)

        viewModel.delete()
        try await Task.sleep(nanoseconds: 350_000_000)

        XCTAssertTrue(viewModel.isComplete)
        XCTAssertTrue(viewModel.hasPendingDeletes)
        XCTAssertTrue(viewModel.canUndoLastSwipe)

        viewModel.undoLastSwipe()

        XCTAssertFalse(viewModel.isComplete)
        XCTAssertFalse(viewModel.hasPendingDeletes)
        XCTAssertFalse(viewModel.canUndoLastSwipe)
        XCTAssertEqual(viewModel.current?.id, deleteCandidate.localIdentifier)
    }

    func testDuplicateScreenshotsCanGroupWithoutCameraAssets() async {
        let first = asset("first", seconds: 0, screenshot: true)
        let second = asset("second", seconds: 86_400, screenshot: true)
        let signals = pair(first, second, distance: 0.005)
        let pairResult = pairClassifier.classifyPair(
            lhs: first,
            rhs: second,
            signals: signals
        )
        let group = await policyEngine.classifyCluster(
            clusterInput(
                assets: [first, second],
                pairs: [pairKey("first", "second"): signals]
            )
        )

        XCTAssertTrue(pairResult.eligible)
        XCTAssertEqual(pairResult.provisionalBucket, .nearDuplicate)
        XCTAssertFalse(pairResult.softBlockers.contains(.largeTimeGap))
        XCTAssertEqual(group.bucket, .nearDuplicate)
        XCTAssertEqual(group.action, .suggestDeleteOthers)
    }

    func testStrongCameraMatchOnDifferentDayDoesNotGroup() async {
        let first = asset("first", seconds: 0)
        let second = asset("second", seconds: 86_400)
        let signals = pair(first, second, distance: 0.005)
        let pairResult = pairClassifier.classifyPair(
            lhs: first,
            rhs: second,
            signals: signals
        )
        let group = await policyEngine.classifyCluster(
            clusterInput(
                assets: [first, second],
                pairs: [pairKey("first", "second"): signals]
            )
        )

        XCTAssertFalse(pairResult.eligible)
        XCTAssertEqual(pairResult.provisionalBucket, .notSimilar)
        XCTAssertEqual(group.bucket, .notSimilar)
        XCTAssertEqual(group.action, .doNotSuggestDeletion)
    }

    func testDeletionGuardrailsRejectStaleKeeperAndForeignDeleteID() {
        XCTAssertThrowsError(
            try PhotoDeletionGuardrails.validate(
                keeperAssetID: "stale",
                deleteCandidateIDs: ["b"],
                assetIDs: ["a", "b"],
                recommendedAction: .keepBestTrashRest,
                reason: .nearDuplicate,
                confidence: .high,
                blockerFlags: []
            )
        ) { error in
            XCTAssertEqual(error as? PhotoDeletionGuardrailError, .keeperNotInGroup)
        }

        XCTAssertThrowsError(
            try PhotoDeletionGuardrails.validate(
                keeperAssetID: "a",
                deleteCandidateIDs: ["outside"],
                assetIDs: ["a", "b"],
                recommendedAction: .keepBestTrashRest,
                reason: .nearDuplicate,
                confidence: .high,
                blockerFlags: []
            )
        ) { error in
            XCTAssertEqual(error as? PhotoDeletionGuardrailError, .deleteCandidateNotInGroup)
        }
    }

    func testDeletionGuardrailsKeepVisualGroupsReviewOnly() {
        XCTAssertThrowsError(
            try PhotoDeletionGuardrails.validate(
                keeperAssetID: "a",
                deleteCandidateIDs: ["b"],
                assetIDs: ["a", "b"],
                recommendedAction: .keepBestTrashRest,
                reason: .visuallySimilar,
                confidence: .high,
                blockerFlags: []
            )
        ) { error in
            XCTAssertEqual(error as? PhotoDeletionGuardrailError, .visuallySimilarReviewOnly)
        }
    }

    func testDeletionGuardrailsRejectMissingKeeperEvidence() {
        XCTAssertThrowsError(
            try PhotoDeletionGuardrails.validate(
                keeperAssetID: "a",
                deleteCandidateIDs: ["b"],
                assetIDs: ["a", "b"],
                recommendedAction: .keepBestTrashRest,
                reason: .nearDuplicate,
                confidence: .high,
                blockerFlags: [.lowKeeperEvidence]
            )
        ) { error in
            XCTAssertEqual(error as? PhotoDeletionGuardrailError, .blockerFlagsPresent)
        }
    }

    func testDeletionGuardrailsRejectEntireGroupSelection() {
        XCTAssertThrowsError(
            try PhotoDeletionGuardrails.validateManualSelection(
                assetIDs: ["a", "b"],
                groupAssetIDs: ["a", "b"]
            )
        ) { error in
            XCTAssertEqual(error as? PhotoDeletionGuardrailError, .invalidManualSelection)
        }
    }

    func testDeletionGuardrailsRejectCrossGroupKeeperConflict() {
        XCTAssertThrowsError(
            try PhotoDeletionGuardrails.validateCrossGroup(
                keeperAssetIDs: ["keeper-a", "keeper-b"],
                deleteCandidateIDsByGroup: [
                    ["trash-a"],
                    ["keeper-a"]
                ]
            )
        ) { error in
            XCTAssertEqual(error as? PhotoDeletionGuardrailError, .crossGroupKeeperConflict)
        }
    }

    func testDeletionGuardrailsRejectDuplicateDeleteAcrossGroups() {
        XCTAssertThrowsError(
            try PhotoDeletionGuardrails.validateCrossGroup(
                keeperAssetIDs: ["keeper-a", "keeper-b"],
                deleteCandidateIDsByGroup: [
                    ["shared-trash"],
                    ["shared-trash"]
                ]
            )
        ) { error in
            XCTAssertEqual(error as? PhotoDeletionGuardrailError, .duplicateDeleteAcrossGroups)
        }
    }

    @MainActor
    func testAutoCleanPlannerSkipsConflictsAndKeepsSafeGroups() {
        let keeperA = TestPhotoAsset(localIdentifier: "keeper-a")
        let sharedTrash = TestPhotoAsset(localIdentifier: "shared-trash")
        let keeperB = TestPhotoAsset(localIdentifier: "keeper-b")
        let keeperC = TestPhotoAsset(localIdentifier: "keeper-c")
        let trashC = TestPhotoAsset(localIdentifier: "trash-c")

        let first = PhotoGroup(
            assets: [keeperA, sharedTrash],
            similarity: 0.99,
            reason: .nearDuplicate,
            groupConfidence: .high,
            recommendedAction: .keepBestTrashRest,
            keeperAssetID: keeperA.localIdentifier,
            deleteCandidateIDs: [sharedTrash.localIdentifier]
        )
        let conflicting = PhotoGroup(
            assets: [keeperB, sharedTrash],
            similarity: 0.99,
            reason: .nearDuplicate,
            groupConfidence: .high,
            recommendedAction: .keepBestTrashRest,
            keeperAssetID: keeperB.localIdentifier,
            deleteCandidateIDs: [sharedTrash.localIdentifier]
        )
        let safe = PhotoGroup(
            assets: [keeperC, trashC],
            similarity: 0.99,
            reason: .nearDuplicate,
            groupConfidence: .high,
            recommendedAction: .keepBestTrashRest,
            keeperAssetID: keeperC.localIdentifier,
            deleteCandidateIDs: [trashC.localIdentifier]
        )

        let planned = PhotoDeletionGuardrails.compatibleAutoCleanGroups(
            from: [first, conflicting, safe]
        )

        XCTAssertEqual(planned.map(\.id), [first.id, safe.id])
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

    private func candidate(_ id: String, isBestShot: Bool) -> SimilarPhotoCandidate {
        SimilarPhotoCandidate(
            photoId: id,
            assetReference: id,
            captureTimestamp: nil,
            isBestShot: isBestShot,
            bestShotScore: isBestShot ? 0.9 : 0.4,
            bestShotReasons: [],
            issueFlags: [],
            isProtected: false,
            isSelectedForTrash: !isBestShot,
            isViewed: false,
            selectionState: isBestShot ? .keep : .trash,
            technicalScores: nil
        )
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

private final class TestPhotoAsset: PHAsset, @unchecked Sendable {
    private let testLocalIdentifier: String

    init(localIdentifier: String) {
        testLocalIdentifier = localIdentifier
        super.init()
    }

    override var localIdentifier: String {
        testLocalIdentifier
    }
}
