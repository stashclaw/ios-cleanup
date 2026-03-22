import XCTest
@testable import iOSCleanup

final class PhotoFeedbackLearningTests: XCTestCase {
    func testRecommendationAcceptedHelper() {
        XCTAssertEqual(
            PhotoFeedbackStore.recommendationAccepted(
                kind: .keepBest,
                suggestedKeeperID: "keeper",
                finalKeeperID: "keeper",
                suggestedDeleteAssetIDs: ["a", "b"],
                deletedAssetIDs: []
            ),
            true
        )

        XCTAssertEqual(
            PhotoFeedbackStore.recommendationAccepted(
                kind: .keepBest,
                suggestedKeeperID: "keeper",
                finalKeeperID: "other",
                suggestedDeleteAssetIDs: ["a", "b"],
                deletedAssetIDs: []
            ),
            false
        )

        XCTAssertEqual(
            PhotoFeedbackStore.recommendationAccepted(
                kind: .deleteSelected,
                suggestedKeeperID: "keeper",
                finalKeeperID: "keeper",
                suggestedDeleteAssetIDs: ["a", "b"],
                deletedAssetIDs: ["a"]
            ),
            true
        )

        XCTAssertEqual(
            PhotoFeedbackStore.recommendationAccepted(
                kind: .deleteSelected,
                suggestedKeeperID: "keeper",
                finalKeeperID: "keeper",
                suggestedDeleteAssetIDs: ["a", "b"],
                deletedAssetIDs: ["a", "c"]
            ),
            false
        )

        XCTAssertNil(
            PhotoFeedbackStore.recommendationAccepted(
                kind: .skipGroup,
                suggestedKeeperID: nil,
                finalKeeperID: nil,
                suggestedDeleteAssetIDs: [],
                deletedAssetIDs: []
            )
        )
    }

    func testDuplicateEventReplayDoesNotDoubleCountAggregates() async throws {
        let (_, profileStore, directoryURL) = makeStores(uniqueDirectorySuffix: "duplicate-replay")
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let first = makeEvent(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID(),
            kind: .keepBest,
            stage: .committed,
            source: .similarGroupReview,
            recommendationAccepted: true
        )
        let second = makeEvent(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002") ?? UUID(),
            kind: .keepBest,
            stage: .committed,
            source: .similarGroupReview,
            recommendationAccepted: true
        )

        let duplicateKey = first.dedupeKey
        let replayedFirst = PhotoReviewFeedbackEvent(
            id: first.id,
            timestamp: first.timestamp,
            source: first.source,
            kind: first.kind,
            stage: first.stage,
            dedupeKey: duplicateKey,
            groupID: first.groupID,
            groupType: first.groupType,
            bucket: first.bucket,
            confidence: first.confidence,
            suggestedAction: first.suggestedAction,
            suggestedKeeperAssetID: first.suggestedKeeperAssetID,
            finalKeeperAssetID: first.finalKeeperAssetID,
            deletedAssetIDs: first.deletedAssetIDs,
            keptAssetIDs: first.keptAssetIDs,
            skipped: first.skipped,
            recommendationAccepted: first.recommendationAccepted,
            policyVersion: first.policyVersion,
            modelVersion: first.modelVersion,
            featureSchemaVersion: first.featureSchemaVersion,
            assets: first.assets,
            note: first.note
        )

        await profileStore.rebuild(from: [replayedFirst, second, replayedFirst])
        let profile = await profileStore.snapshot()

        XCTAssertEqual(profile.totalRawEvents, 2)
        XCTAssertEqual(profile.totalCommittedEvents, 2)
        XCTAssertEqual(profile.overall.keptCount, 2)
        XCTAssertEqual(profile.overall.acceptedRecommendationCount, 2)
    }

    func testProvisionalAndCommittedFlowDoesNotCorruptTrainingData() async throws {
        let (_, profileStore, directoryURL) = makeStores(uniqueDirectorySuffix: "provisional-committed")
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let provisional = makeEvent(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000001001") ?? UUID(),
            kind: .keepBest,
            stage: .provisional,
            source: .similarGroupReview,
            confidence: .low,
            recommendationAccepted: nil
        )
        let committed = makeEvent(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000001002") ?? UUID(),
            kind: .keepBest,
            stage: .committed,
            source: .similarGroupReview,
            confidence: .high,
            recommendationAccepted: true
        )

        await profileStore.rebuild(from: [provisional, committed])
        let profile = await profileStore.snapshot()

        XCTAssertEqual(profile.totalRawEvents, 2)
        XCTAssertEqual(profile.totalCommittedEvents, 1)
        XCTAssertEqual(profile.overall.keptCount, 1)
        XCTAssertEqual(profile.overall.acceptedRecommendationCount, 1)
        XCTAssertEqual(profile.lowConfidence.reviewedCount, 0)
    }

    func testEventsPersistAndReloadWithoutImagePayloads() async throws {
        let (feedbackStore, profileStore, directoryURL) = makeStores()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let event = makeEvent(
            kind: .keepBest,
            stage: .committed,
            source: .similarGroupReview,
            deletedAssetIDs: ["delete-1", "delete-2"],
            keptAssetIDs: ["keep-1"],
            recommendationAccepted: true
        )

        let appended = await feedbackStore.append(event)
        XCTAssertTrue(appended)

        let loaded = await feedbackStore.loadAllEvents()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, event.id)
        XCTAssertEqual(loaded.first?.finalKeeperAssetID, "keep-1")
        XCTAssertEqual(loaded.first?.deletedAssetIDs, ["delete-1", "delete-2"])
        XCTAssertEqual(loaded.first?.keptAssetIDs, ["keep-1"])
        XCTAssertEqual(loaded.first?.groupID, event.groupID)

        let data = try JSONEncoder().encode(event)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("UIImage"))
        XCTAssertFalse(json.contains("thumbnail"))
        XCTAssertLessThan(data.count, 4096)

        let profile = await profileStore.snapshot()
        XCTAssertEqual(profile.totalRawEvents, 1)
        XCTAssertEqual(profile.totalCommittedEvents, 1)
    }

    func testRebuildMatchesIncrementalAggregateState() async throws {
        let (feedbackStore, profileStore, directoryURL) = makeStores(uniqueDirectorySuffix: "rebuild-match")
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let events = [
            makeEvent(
                kind: .keepBest,
                stage: .committed,
                source: .similarGroupReview,
                bucket: .nearDuplicate,
                groupType: .nearDuplicate,
                confidence: .high,
                deletedAssetIDs: ["trash-1"],
                keptAssetIDs: ["keeper-1"],
                recommendationAccepted: true,
                assets: [
                    makeAsset("keeper-1", role: .finalKeeper, isFavorite: true, isEdited: false, isScreenshot: false, burstIdentifier: nil, rankingScore: 0.99),
                    makeAsset("trash-1", role: .deleted, isFavorite: false, isEdited: false, isScreenshot: false, burstIdentifier: nil, rankingScore: 0.10)
                ]
            ),
            makeEvent(
                kind: .skipGroup,
                stage: .committed,
                source: .similarGroupReview,
                bucket: .visuallySimilar,
                groupType: .sameMoment,
                confidence: .low,
                skipped: true,
                recommendationAccepted: nil,
                assets: [
                    makeAsset("shot-1", role: .skipped, isFavorite: false, isEdited: true, isScreenshot: true, burstIdentifier: nil, rankingScore: 0.20)
                ]
            )
        ]

        await feedbackStore.append(events)
        let incremental = await profileStore.snapshot()

        let (_, rebuildProfileStore, rebuildDirectoryURL) = makeStores(uniqueDirectorySuffix: "rebuild-match-2")
        defer { try? FileManager.default.removeItem(at: rebuildDirectoryURL) }
        await rebuildProfileStore.rebuild(from: events)
        let rebuilt = await rebuildProfileStore.snapshot()

        XCTAssertEqual(incremental.totalRawEvents, rebuilt.totalRawEvents)
        XCTAssertEqual(incremental.totalCommittedEvents, rebuilt.totalCommittedEvents)
        XCTAssertEqual(incremental.overall, rebuilt.overall)
        XCTAssertEqual(incremental.byGroupType, rebuilt.byGroupType)
        XCTAssertEqual(incremental.byBucket, rebuilt.byBucket)
        XCTAssertEqual(incremental.screenshots, rebuilt.screenshots)
        XCTAssertEqual(incremental.favorites, rebuilt.favorites)
    }

    func testRawEventRetentionPrunesOldEvents() async throws {
        let (feedbackStore, _, directoryURL) = makeStores(uniqueDirectorySuffix: "retention")
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let total = PhotoFeedbackStore.maxStoredRawEvents + 6
        var events: [PhotoReviewFeedbackEvent] = []
        events.reserveCapacity(total)
        for index in 0..<total {
            events.append(
                makeEvent(
                    id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1)) ?? UUID(),
                    timestamp: Date(timeIntervalSinceReferenceDate: TimeInterval(index)),
                    kind: .skipGroup,
                    stage: .committed,
                    source: .photoResults,
                    skipped: true,
                    recommendationAccepted: nil
                )
            )
        }

        await feedbackStore.append(events)
        let loaded = await feedbackStore.loadAllEvents()

        XCTAssertEqual(loaded.count, PhotoFeedbackStore.maxStoredRawEvents)
        XCTAssertEqual(loaded.first?.timestamp, events.dropFirst(6).first?.timestamp)
        XCTAssertEqual(loaded.last?.timestamp, events.last?.timestamp)
    }

    func testAggregateProfileUpdatesFromCommittedEvents() async throws {
        let (feedbackStore, profileStore, directoryURL) = makeStores(uniqueDirectorySuffix: "profile")
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let keeperEvent = makeEvent(
            kind: .keepBest,
            stage: .committed,
            source: .similarGroupReview,
            bucket: .nearDuplicate,
            groupType: .nearDuplicate,
            confidence: .high,
            deletedAssetIDs: ["trash-1"],
            keptAssetIDs: ["keeper-1"],
            recommendationAccepted: true,
            assets: [
                makeAsset("keeper-1", role: .finalKeeper, isFavorite: true, isEdited: false, isScreenshot: false, burstIdentifier: nil, rankingScore: 0.95),
                makeAsset("trash-1", role: .deleted, isFavorite: false, isEdited: false, isScreenshot: false, burstIdentifier: nil, rankingScore: 0.40)
            ]
        )
        let skipEvent = makeEvent(
            kind: .skipGroup,
            stage: .committed,
            source: .similarGroupReview,
            bucket: .visuallySimilar,
            groupType: .sameMoment,
            confidence: .low,
            skipped: true,
            recommendationAccepted: nil,
            assets: [
                makeAsset("shot-1", role: .skipped, isFavorite: false, isEdited: true, isScreenshot: true, burstIdentifier: nil, rankingScore: 0.35)
            ]
        )

        let keeperAppended = await feedbackStore.append(keeperEvent)
        let skipAppended = await feedbackStore.append(skipEvent)
        XCTAssertTrue(keeperAppended)
        XCTAssertTrue(skipAppended)

        let profile = await profileStore.snapshot()
        XCTAssertEqual(profile.totalRawEvents, 2)
        XCTAssertEqual(profile.totalCommittedEvents, 2)
        XCTAssertEqual(profile.overall.reviewedCount, 2)
        XCTAssertEqual(profile.overall.keptCount, 1)
        XCTAssertEqual(profile.overall.skippedCount, 1)
        XCTAssertEqual(profile.overall.acceptedRecommendationCount, 1)
        XCTAssertEqual(profile.screenshots.reviewedCount, 1)
        XCTAssertEqual(profile.edited.reviewedCount, 1)
        XCTAssertEqual(profile.favorites.reviewedCount, 1)
        XCTAssertEqual(profile.lowConfidence.reviewedCount, 1)
    }

    func testExportRowsAreStableAndMetadataOnly() async throws {
        let event = makeEvent(
            kind: .keeperOverride,
            stage: .committed,
            source: .swipeMode,
            bucket: .burstShot,
            groupType: .burst,
            confidence: .medium,
            suggestedKeeperAssetID: "keeper-2",
            finalKeeperAssetID: "keeper-1",
            deletedAssetIDs: ["delete-2", "delete-1"],
            keptAssetIDs: ["keeper-1"],
            recommendationAccepted: false,
            assets: [
                makeAsset("b-asset", role: .deleted, isFavorite: false, isEdited: false, isScreenshot: false, burstIdentifier: "burst-1", similarityToKeeper: 0.22, rankingScore: 0.30),
                makeAsset("a-asset", role: .finalKeeper, isFavorite: true, isEdited: true, isScreenshot: false, burstIdentifier: "burst-1", similarityToKeeper: 0.98, rankingScore: 0.98)
            ]
        )

        let rows = PhotoTrainingExampleBuilder.makeRows(from: event)

        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(rows[0].kind, PhotoTrainingRowKind.assetPreference)
        XCTAssertEqual(rows[0].assetID, "a-asset")
        XCTAssertEqual(rows[1].assetID, "b-asset")
        XCTAssertEqual(rows[2].kind, PhotoTrainingRowKind.groupOutcome)
        XCTAssertEqual(rows[2].stage, .committed)
        XCTAssertNil(rows[2].featureVector)
        XCTAssertEqual(rows[3].kind, PhotoTrainingRowKind.keeperRanking)
        XCTAssertEqual(rows[3].assetID, "a-asset")
        XCTAssertEqual(rows[4].assetID, "b-asset")
        XCTAssertEqual(rows[3].keeperAssetID, "keeper-1")
        XCTAssertEqual(rows[0].featureVector?.pixelWidth, 3000)
        XCTAssertTrue(rows[0].featureVector?.isScreenshot == false)
        XCTAssertEqual(rows[0].recommendationAccepted, false)
    }

    func testNoOrderingBasedAssumptionsInExportBuilder() {
        let event = makeEvent(
            kind: .deleteSelected,
            stage: .committed,
            source: .photoResults,
            deletedAssetIDs: ["z-asset", "a-asset"],
            keptAssetIDs: ["m-asset"],
            recommendationAccepted: true,
            assets: [
                makeAsset("z-asset", role: .deleted, rankingScore: 0.12),
                makeAsset("a-asset", role: .deleted, rankingScore: 0.08),
                makeAsset("m-asset", role: .finalKeeper, rankingScore: 0.97)
            ]
        )

        let rows = PhotoTrainingExampleBuilder.makeRows(from: event)
        let assetRows = rows.filter { $0.kind == .assetPreference }

        XCTAssertEqual(assetRows.map(\.assetID), ["a-asset", "m-asset", "z-asset"])
        XCTAssertEqual(assetRows.last?.assetRole, .deleted)
        XCTAssertEqual(rows.first?.id, "\(event.id.uuidString):assetPreference:a-asset")
    }

    func testDeleteAndKeeperIdentifiersAreCaptured() {
        let event = makeEvent(
            kind: .deleteSelected,
            stage: .committed,
            source: .similarGroupReview,
            suggestedKeeperAssetID: "keeper-1",
            finalKeeperAssetID: "keeper-1",
            deletedAssetIDs: ["trash-1", "trash-2"],
            keptAssetIDs: ["keeper-1"],
            recommendationAccepted: true
        )

        XCTAssertEqual(event.suggestedKeeperAssetID, "keeper-1")
        XCTAssertEqual(event.finalKeeperAssetID, "keeper-1")
        XCTAssertEqual(event.deletedAssetIDs, ["trash-1", "trash-2"])
        XCTAssertEqual(event.keptAssetIDs, ["keeper-1"])
    }

    private func makeStores(uniqueDirectorySuffix: String = UUID().uuidString) -> (PhotoFeedbackStore, PhotoPreferenceProfileStore, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoFeedbackLearningTests-\(uniqueDirectorySuffix)-\(UUID().uuidString)", isDirectory: true)
        let profileStore = PhotoPreferenceProfileStore(directoryURL: base)
        let feedbackStore = PhotoFeedbackStore(directoryURL: base, profileStore: profileStore)
        return (feedbackStore, profileStore, base)
    }

    private func makeEvent(
        id: UUID = UUID(),
        timestamp: Date = Date(timeIntervalSinceReferenceDate: 1_000),
        kind: PhotoReviewDecisionKind,
        stage: PhotoReviewDecisionStage,
        source: PhotoReviewFeedbackSource,
        groupID: UUID? = UUID(),
        bucket: SimilarityBucket? = nil,
        groupType: SimilarGroupType? = nil,
        confidence: GroupConfidence? = nil,
        suggestedAction: SuggestedAction? = nil,
        suggestedKeeperAssetID: String? = "keeper-1",
        finalKeeperAssetID: String? = nil,
        deletedAssetIDs: [String] = [],
        keptAssetIDs: [String] = [],
        skipped: Bool = false,
        recommendationAccepted: Bool?,
        policyVersion: Int = PhotoReviewFeedbackVersions.policyVersion,
        modelVersion: Int = PhotoReviewFeedbackVersions.modelVersion,
        featureSchemaVersion: Int = PhotoReviewFeedbackVersions.featureSchemaVersion,
        assets: [PhotoReviewFeedbackAsset] = []
    ) -> PhotoReviewFeedbackEvent {
        PhotoReviewFeedbackEvent(
            id: id,
            timestamp: timestamp,
            source: source,
            kind: kind,
            stage: stage,
            dedupeKey: "\(source.rawValue)|\(kind.rawValue)|\(stage.rawValue)|\(groupID?.uuidString ?? "none")|\(finalKeeperAssetID ?? "none")",
            groupID: groupID,
            groupType: groupType,
            bucket: bucket,
            confidence: confidence,
            suggestedAction: suggestedAction,
            suggestedKeeperAssetID: suggestedKeeperAssetID,
            finalKeeperAssetID: finalKeeperAssetID ?? suggestedKeeperAssetID,
            deletedAssetIDs: deletedAssetIDs,
            keptAssetIDs: keptAssetIDs,
            skipped: skipped,
            recommendationAccepted: recommendationAccepted,
            policyVersion: policyVersion,
            modelVersion: modelVersion,
            featureSchemaVersion: featureSchemaVersion,
            assets: assets.isEmpty ? [makeAsset("keeper-1", role: .finalKeeper)] : assets,
            note: "test"
        )
    }

    private func makeAsset(
        _ id: String,
        role: PhotoReviewAssetRole = .candidate,
        isFavorite: Bool? = false,
        isEdited: Bool? = false,
        isScreenshot: Bool? = false,
        burstIdentifier: String? = nil,
        similarityToKeeper: Double? = nil,
        rankingScore: Double? = nil
    ) -> PhotoReviewFeedbackAsset {
        PhotoReviewFeedbackAsset(
            localIdentifier: id,
            creationDate: Date(timeIntervalSinceReferenceDate: 1_000),
            pixelWidth: 3_000,
            pixelHeight: 2_000,
            isFavorite: isFavorite,
            isEdited: isEdited,
            isScreenshot: isScreenshot,
            burstIdentifier: burstIdentifier,
            role: role,
            similarityToKeeper: similarityToKeeper,
            rankingScore: rankingScore,
            flags: role == .deleted ? ["deleteCandidate"] : []
        )
    }
}
