import XCTest
@testable import iOSCleanup

private actor NoopFeedbackPersistence: PhotoFeedbackPersisting {
    func persistFeedbackEvents(_ events: [PhotoReviewFeedbackEvent]) async {}
}

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

    func testBatchDedupePersistsOnlySurvivorToSQLite() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PhotoFeedbackLearningTests-batch-sqlite-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: base) }

        let mlStore = PhotoMLStore(directoryURL: base)
        try await mlStore.open()
        let profileStore = PhotoPreferenceProfileStore(directoryURL: base)
        let feedbackStore = PhotoFeedbackStore(
            directoryURL: base,
            profileStore: profileStore,
            persistence: PhotoMLBridge(store: mlStore)
        )
        let groupID = UUID()
        let first = makeEvent(
            id: UUID(),
            kind: .keepBest,
            stage: .committed,
            source: .similarGroupReview,
            groupID: groupID,
            recommendationAccepted: true
        )
        let duplicate = makeEvent(
            id: UUID(),
            kind: .keepBest,
            stage: .committed,
            source: .similarGroupReview,
            groupID: groupID,
            recommendationAccepted: true
        )

        XCTAssertNotEqual(first.id, duplicate.id)
        XCTAssertEqual(first.dedupeKey, duplicate.dedupeKey)

        await feedbackStore.append([first, duplicate])

        let rawEvents = await feedbackStore.loadAllEvents()
        let sqliteEventCount = try await mlStore.feedbackEventCount()
        XCTAssertEqual(rawEvents.count, 1)
        XCTAssertEqual(sqliteEventCount, 1)
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

    func testProvisionalKeeperSelectionDoesNotInferDeletionOutcome() async throws {
        let (feedbackStore, _, directoryURL) = makeStores(uniqueDirectorySuffix: "provisional-no-delete")
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let group = PhotoGroup(
            assets: [],
            similarity: 0.95,
            reason: .nearDuplicate,
            groupConfidence: .high,
            recommendedAction: .keepBestTrashRest,
            keeperAssetID: "keeper",
            deleteCandidateIDs: ["delete"],
            candidates: [
                makeCandidate("keeper", isBestShot: true),
                makeCandidate("delete", isBestShot: false)
            ]
        )

        let recorded = await feedbackStore.recordSimilarGroupDecision(
            group: group,
            kind: .keepBest,
            stage: .provisional,
            selectedKeeperID: "keeper",
            keptAssetIDs: ["keeper"]
        )
        let events = await feedbackStore.loadAllEvents()

        XCTAssertTrue(recorded)
        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(events[0].deletedAssetIDs.isEmpty)
        XCTAssertEqual(events[0].keptAssetIDs, ["keeper"])
        XCTAssertEqual(events[0].featureSchemaVersion, PhotoFeedbackStore.featureSchemaVersion)
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

        await feedbackStore.flushPendingWrites()
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
        await feedbackStore.flushPendingWrites()
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

        await feedbackStore.flushPendingWrites()
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

    func testJournalRecoversEventBeforeDelayedArchiveFlush() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PhotoFeedbackLearningTests-journal-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: base) }

        let persistence = NoopFeedbackPersistence()
        let firstProfileStore = PhotoPreferenceProfileStore(directoryURL: base)
        let firstStore = PhotoFeedbackStore(
            directoryURL: base,
            profileStore: firstProfileStore,
            persistence: persistence,
            flushDelayNanoseconds: 60_000_000_000
        )
        let event = makeEvent(
            kind: .swipeDelete,
            stage: .committed,
            source: .swipeMode,
            deletedAssetIDs: ["asset"],
            recommendationAccepted: nil
        )

        let appended = await firstStore.append(event)
        XCTAssertTrue(appended)

        let learningDirectory = base.appendingPathComponent("PhotoDuck/learning", isDirectory: true)
        let archiveURL = learningDirectory.appendingPathComponent("photo-feedback-events.json")
        let journalURL = learningDirectory.appendingPathComponent("photo-feedback-events.journal")
        XCTAssertFalse(FileManager.default.fileExists(atPath: archiveURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))

        let recoveredStore = PhotoFeedbackStore(
            directoryURL: base,
            profileStore: PhotoPreferenceProfileStore(directoryURL: base),
            persistence: persistence,
            flushDelayNanoseconds: 60_000_000_000
        )
        let recoveredEvents = await recoveredStore.loadAllEvents()

        XCTAssertEqual(recoveredEvents.map(\.id), [event.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveURL.path))
        await firstStore.flushPendingWrites()
    }

    func testDeleteUndoDeleteDecisionCyclesAreNotDeduped() async {
        let (feedbackStore, _, directoryURL) = makeStores(uniqueDirectorySuffix: "delete-undo-delete")
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let group = PhotoGroup(
            assets: [],
            similarity: 0.99,
            reason: .nearDuplicate,
            groupConfidence: .high,
            recommendedAction: .keepBestTrashRest,
            keeperAssetID: "keeper",
            deleteCandidateIDs: ["asset"],
            candidates: []
        )

        let firstDelete = await feedbackStore.recordSimilarGroupDecision(
            group: group,
            kind: .deleteSelected,
            selectedKeeperID: "keeper",
            deletedAssetIDs: ["asset"],
            keptAssetIDs: ["keeper"]
        )
        let undo = await feedbackStore.recordUndoRestore(assetIDs: ["asset"])
        let secondDelete = await feedbackStore.recordSimilarGroupDecision(
            group: group,
            kind: .deleteSelected,
            selectedKeeperID: "keeper",
            deletedAssetIDs: ["asset"],
            keptAssetIDs: ["keeper"]
        )

        let events = await feedbackStore.loadAllEvents()
        XCTAssertTrue(firstDelete)
        XCTAssertTrue(undo)
        XCTAssertTrue(secondDelete)
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events.map(\.kind), [.deleteSelected, .restoreUndo, .deleteSelected])
        XCTAssertNotEqual(events[0].dedupeKey, events[2].dedupeKey)
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
        XCTAssertEqual(rows[0].featureSchemaVersion, PhotoTrainingExampleBuilder.featureSchemaVersion)
        XCTAssertNil(rows[2].recommendationAccepted)
    }

    func testAcceptedDefaultDoesNotCreateKeeperTrainingRows() {
        let acceptedDefault = makeEvent(
            kind: .keepBest,
            stage: .committed,
            source: .similarGroupReview,
            suggestedKeeperAssetID: "keeper",
            finalKeeperAssetID: "keeper",
            recommendationAccepted: true,
            assets: [
                makeAsset("keeper", role: .finalKeeper, rankingScore: 0.95),
                makeAsset("candidate", role: .candidate, rankingScore: 0.40)
            ]
        )
        let override = makeEvent(
            kind: .keeperOverride,
            stage: .committed,
            source: .similarGroupReview,
            suggestedKeeperAssetID: "suggested",
            finalKeeperAssetID: "chosen",
            recommendationAccepted: false,
            assets: [
                makeAsset("suggested", role: .suggestedKeeper, rankingScore: 0.95),
                makeAsset("chosen", role: .finalKeeper, rankingScore: 0.80)
            ]
        )

        let acceptedRows = PhotoTrainingExampleBuilder.makeRows(from: acceptedDefault)
        let overrideRows = PhotoTrainingExampleBuilder.makeRows(from: override)

        XCTAssertFalse(PhotoTrainingExampleBuilder.isActiveChoice(acceptedDefault))
        XCTAssertTrue(PhotoTrainingExampleBuilder.isActiveChoice(override))
        XCTAssertTrue(acceptedRows.filter { $0.kind == .keeperRanking }.isEmpty)
        XCTAssertEqual(overrideRows.filter { $0.kind == .keeperRanking }.count, 2)
    }

    func testActualFinalKeeperRoleWinsAcrossDecisionKinds() {
        for kind in PhotoReviewDecisionKind.allCases {
            XCTAssertEqual(
                PhotoFeedbackStore.assetRole(
                    assetID: "actual",
                    kind: kind,
                    suggestedKeeperID: "suggested",
                    finalKeeperID: "actual",
                    deletedAssetIDs: [],
                    keptAssetIDs: ["actual"],
                    skipped: false
                ),
                .finalKeeper,
                "\(kind) must label only the actual final keeper as finalKeeper"
            )
            XCTAssertEqual(
                PhotoFeedbackStore.assetRole(
                    assetID: "suggested",
                    kind: kind,
                    suggestedKeeperID: "suggested",
                    finalKeeperID: "actual",
                    deletedAssetIDs: [],
                    keptAssetIDs: [],
                    skipped: false
                ),
                .suggestedKeeper,
                "\(kind) must not promote the system suggestion to finalKeeper"
            )
        }
    }

    func testRoleAssignmentUsesOutcomeSetsWithoutArrayOrdering() {
        XCTAssertEqual(
            PhotoFeedbackStore.assetRole(
                assetID: "deleted",
                kind: .deleteSelected,
                suggestedKeeperID: "suggested",
                finalKeeperID: "actual",
                deletedAssetIDs: ["deleted"],
                keptAssetIDs: [],
                skipped: false
            ),
            .deleted
        )
        XCTAssertEqual(
            PhotoFeedbackStore.assetRole(
                assetID: "kept",
                kind: .deleteSelected,
                suggestedKeeperID: "suggested",
                finalKeeperID: "actual",
                deletedAssetIDs: [],
                keptAssetIDs: ["kept"],
                skipped: false
            ),
            .kept
        )
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

    func testConcurrentInitialLoadAndAppendPreservesEveryUniqueEvent() async throws {
        let (feedbackStore, _, baseURL) = makeStores(
            uniqueDirectorySuffix: "concurrent-load-append"
        )
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let events = (0..<40).map { index in
            makeEvent(
                id: UUID(),
                timestamp: Date(
                    timeIntervalSinceReferenceDate: TimeInterval(index)
                ),
                kind: .swipeKeep,
                stage: .committed,
                source: .swipeMode,
                groupID: nil,
                suggestedKeeperAssetID: nil,
                finalKeeperAssetID: "asset-\(index)",
                keptAssetIDs: ["asset-\(index)"],
                recommendationAccepted: nil,
                dedupeKey: "concurrent-\(index)"
            )
        }

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = await feedbackStore.loadAllEvents()
            }
            for event in events {
                group.addTask {
                    _ = await feedbackStore.append(event)
                }
            }
        }
        await feedbackStore.flushPendingWrites()

        let loaded = await feedbackStore.loadAllEvents()
        XCTAssertEqual(Set(loaded.map(\.id)), Set(events.map(\.id)))
        XCTAssertEqual(Set(loaded.map(\.dedupeKey)).count, events.count)
    }

    private func makeStores(uniqueDirectorySuffix: String = UUID().uuidString) -> (PhotoFeedbackStore, PhotoPreferenceProfileStore, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoFeedbackLearningTests-\(uniqueDirectorySuffix)-\(UUID().uuidString)", isDirectory: true)
        let profileStore = PhotoPreferenceProfileStore(directoryURL: base)
        let feedbackStore = PhotoFeedbackStore(
            directoryURL: base,
            profileStore: profileStore,
            persistence: NoopFeedbackPersistence()
        )
        return (feedbackStore, profileStore, base)
    }

    private func makeCandidate(_ id: String, isBestShot: Bool) -> SimilarPhotoCandidate {
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
        assets: [PhotoReviewFeedbackAsset] = [],
        dedupeKey: String? = nil
    ) -> PhotoReviewFeedbackEvent {
        let resolvedFinalKeeperAssetID = finalKeeperAssetID
            ?? (keptAssetIDs.count == 1 ? keptAssetIDs[0] : suggestedKeeperAssetID)
        return PhotoReviewFeedbackEvent(
            id: id,
            timestamp: timestamp,
            source: source,
            kind: kind,
            stage: stage,
            dedupeKey: dedupeKey
                ?? "\(source.rawValue)|\(kind.rawValue)|\(stage.rawValue)|\(groupID?.uuidString ?? "none")|\(resolvedFinalKeeperAssetID ?? "none")",
            groupID: groupID,
            groupType: groupType,
            bucket: bucket,
            confidence: confidence,
            suggestedAction: suggestedAction,
            suggestedKeeperAssetID: suggestedKeeperAssetID,
            finalKeeperAssetID: resolvedFinalKeeperAssetID,
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
