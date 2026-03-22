import XCTest
@testable import iOSCleanup

final class PreferenceAdjustedRecommendationTests: XCTestCase {
    private let service = PreferenceAdjustedRecommendationService()

    func testEditedPhotosDowngradeAggressiveDeleteWhenUserOftenKeepsThem() {
        let input = makeInput(
            bucket: .nearDuplicate,
            groupType: .nearDuplicate,
            confidence: .high,
            action: .keepBestTrashRest,
            profile: makeProfile(
                edited: aggregate(reviewed: 10, kept: 8, deleted: 2),
                byBucket: ["nearDuplicate": aggregate(reviewed: 12, kept: 9, deleted: 3)]
            ),
            containsEdited: true
        )

        let result = service.adjust(input)

        XCTAssertEqual(result.adjustedSuggestedAction, .reviewManually)
        XCTAssertEqual(result.adjustedConfidence, .medium)
        XCTAssertLessThan(result.queuePriorityDelta, 0)
        XCTAssertTrue(result.reasons.contains("User often keeps edited photos"))
        XCTAssertTrue(result.reasons.contains("Aggressive delete was downgraded for edited content"))
    }

    func testScreenshotsArePrioritizedIfUserOftenDeletesThem() {
        let input = makeInput(
            bucket: .burstShot,
            groupType: .burst,
            confidence: .high,
            action: .keepBestTrashRest,
            profile: makeProfile(
                screenshots: aggregate(reviewed: 10, deleted: 8, accepted: 7, rejected: 1),
                byGroupType: ["burst": aggregate(reviewed: 8, deleted: 6, accepted: 6, rejected: 1)]
            ),
            containsScreenshot: true,
            containsBurst: true
        )

        let result = service.adjust(input)

        XCTAssertEqual(result.adjustedSuggestedAction, .keepBestTrashRest)
        XCTAssertGreaterThan(result.queuePriorityDelta, 0)
        XCTAssertTrue(result.reasons.contains("User often deletes screenshots"))
    }

    func testVisualSimilarGroupsStayReviewOnly() {
        let input = makeInput(
            bucket: .visuallySimilar,
            groupType: .sameMoment,
            confidence: .high,
            action: .reviewManually,
            profile: makeProfile(
                byBucket: ["visuallySimilar": aggregate(reviewed: 12, kept: 3, deleted: 4)]
            )
        )

        let result = service.adjust(input)

        XCTAssertEqual(result.adjustedSuggestedAction, .reviewManually)
        XCTAssertNotEqual(result.adjustedSuggestedAction, .keepBestTrashRest)
    }

    func testPreferenceAdjustmentDoesNotBypassKeeperSafety() {
        let group = PhotoGroup(
            assets: [],
            similarity: 0.02,
            reason: .nearDuplicate,
            groupType: .nearDuplicate,
            groupConfidence: .high,
            recommendedAction: .reviewManually,
            keeperAssetID: "keeper",
            deleteCandidateIDs: ["delete-a", "delete-b"],
            bestShotPhotoId: "keeper"
        )

        XCTAssertEqual(group.recommendedAction, .reviewManually)
        XCTAssertTrue(group.deleteCandidateIDs.isEmpty)
        XCTAssertEqual(group.reclaimableBytes, 0)
    }

    func testNoActionDependsOnArrayOrdering() {
        let baseProfile = makeProfile(
            screenshots: aggregate(reviewed: 10, deleted: 8),
                byBucket: ["nearDuplicate": aggregate(reviewed: 12, kept: 10, deleted: 2)]
        )

        let orderedScores: [String: Double] = [
            "keeper": 0.93,
            "other": 0.54
        ]

        let inputA = makeInput(
            bucket: .nearDuplicate,
            groupType: .nearDuplicate,
            confidence: .high,
            action: .keepBestTrashRest,
            keeperRankingResult: KeeperRankingResult(
                keeperAssetID: "keeper",
                rankedAssetIDs: ["keeper", "other"],
                scoreByAssetID: orderedScores,
                reasonsByAssetID: [
                    "keeper": ["Sharper"],
                    "other": ["Blurrier"]
                ],
                scoreBreakdownByAssetID: [:]
            ),
            profile: baseProfile
        )

        let inputB = makeInput(
            bucket: .nearDuplicate,
            groupType: .nearDuplicate,
            confidence: .high,
            action: .keepBestTrashRest,
            keeperRankingResult: KeeperRankingResult(
                keeperAssetID: "keeper",
                rankedAssetIDs: ["other", "keeper"],
                scoreByAssetID: orderedScores,
                reasonsByAssetID: [
                    "keeper": ["Sharper"],
                    "other": ["Blurrier"]
                ],
                scoreBreakdownByAssetID: [:]
            ),
            profile: baseProfile
        )

        XCTAssertEqual(service.adjust(inputA), service.adjust(inputB))
    }

    func testPreferentialQueueBoostDoesNotCreateDeleteCandidatesForReviewOnlyGroups() {
        let group = PhotoGroup(
            assets: [],
            similarity: 0.08,
            reason: .visuallySimilar,
            groupType: .sameMoment,
            groupConfidence: .medium,
            recommendedAction: .reviewManually,
            keeperAssetID: "keeper",
            deleteCandidateIDs: ["a", "b", "keeper"],
            bestShotPhotoId: "keeper",
            preferenceQueuePriority: 0.25,
            preferenceAdjustmentReasons: ["Queued earlier"]
        )

        XCTAssertEqual(group.deleteCandidateIDs, [])
        XCTAssertEqual(group.reclaimableBytes, 0)
        XCTAssertEqual(group.preferenceQueuePriority, 0.25)
        XCTAssertEqual(group.preferenceAdjustmentReasons, ["Queued earlier"])
    }

    private func makeInput(
        bucket: SimilarityBucket = .nearDuplicate,
        groupType: SimilarGroupType = .nearDuplicate,
        confidence: SimilarGroupConfidence = .high,
        action: SimilarRecommendedAction = .keepBestTrashRest,
        keeperRankingResult: KeeperRankingResult = KeeperRankingResult(
            keeperAssetID: "keeper",
            rankedAssetIDs: ["keeper", "other"],
            scoreByAssetID: [
                "keeper": 0.95,
                "other": 0.52
            ],
            reasonsByAssetID: [
                "keeper": ["Sharper"],
                "other": ["Blurrier"]
            ],
            scoreBreakdownByAssetID: [:]
        ),
        profile: PhotoPreferenceProfile = PhotoPreferenceProfile(),
        containsScreenshot: Bool = false,
        containsBurst: Bool = false,
        containsEdited: Bool = false,
        containsFavorite: Bool = false,
        assetCount: Int = 2
    ) -> PreferenceAdjustedRecommendationInput {
        PreferenceAdjustedRecommendationInput(
            bucket: bucket,
            groupType: groupType,
            confidence: confidence,
            suggestedAction: action,
            keeperRankingResult: keeperRankingResult,
            preferenceProfile: profile,
            containsScreenshot: containsScreenshot,
            containsBurst: containsBurst,
            containsEdited: containsEdited,
            containsFavorite: containsFavorite,
            assetCount: assetCount
        )
    }

    private func makeProfile(
        screenshots: PhotoDecisionAggregate = .init(),
        bursts: PhotoDecisionAggregate = .init(),
        edited: PhotoDecisionAggregate = .init(),
        favorites: PhotoDecisionAggregate = .init(),
        lowConfidence: PhotoDecisionAggregate = .init(),
        byBucket: [String: PhotoDecisionAggregate] = [:],
        byGroupType: [String: PhotoDecisionAggregate] = [:]
    ) -> PhotoPreferenceProfile {
        var profile = PhotoPreferenceProfile()
        profile.screenshots = screenshots
        profile.bursts = bursts
        profile.edited = edited
        profile.favorites = favorites
        profile.lowConfidence = lowConfidence
        profile.byBucket = byBucket
        profile.byGroupType = byGroupType
        return profile
    }

    private func aggregate(
        reviewed: Int = 0,
        kept: Int = 0,
        deleted: Int = 0,
        skipped: Int = 0,
        overrides: Int = 0,
        accepted: Int = 0,
        rejected: Int = 0
    ) -> PhotoDecisionAggregate {
        PhotoDecisionAggregate(
            reviewedCount: reviewed,
            keptCount: kept,
            deletedCount: deleted,
            skippedCount: skipped,
            overrideCount: overrides,
            acceptedRecommendationCount: accepted,
            rejectedRecommendationCount: rejected
        )
    }
}
