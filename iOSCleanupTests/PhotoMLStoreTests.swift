import XCTest
@testable import iOSCleanup

final class PhotoMLStoreTests: XCTestCase {

    private var store: PhotoMLStore!
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoMLStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = PhotoMLStore(directoryURL: tempDir)
        try await store.open()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Photo Features

    func testUpsertAndCountFeatures() async throws {
        let feature = PhotoFeatureRecord(
            assetID: "test-asset-001",
            embedding: Data(repeating: 0x42, count: 512),
            embeddingVersion: 1,
            pixelWidth: 4032,
            pixelHeight: 3024,
            creationDate: Date(),
            isFavorite: true,
            isEdited: false,
            isScreenshot: false,
            isLivePhoto: false,
            isHDR: false,
            burstIdentifier: nil,
            aspectRatio: 4032.0 / 3024.0,
            fileSizeBytes: 3_500_000
        )

        try await store.upsertFeature(feature)
        let count = try await store.featureCount()
        XCTAssertEqual(count, 1)
    }

    func testUpsertOverwritesExisting() async throws {
        let feature1 = PhotoFeatureRecord(
            assetID: "same-id",
            embedding: Data(repeating: 0x01, count: 128),
            embeddingVersion: 1,
            pixelWidth: 1000,
            pixelHeight: 1000,
            creationDate: nil,
            isFavorite: false,
            isEdited: false,
            isScreenshot: false,
            isLivePhoto: false,
            isHDR: false,
            burstIdentifier: nil,
            aspectRatio: 1.0,
            fileSizeBytes: 100
        )

        let feature2 = PhotoFeatureRecord(
            assetID: "same-id",
            embedding: Data(repeating: 0x02, count: 256),
            embeddingVersion: 2,
            pixelWidth: 2000,
            pixelHeight: 2000,
            creationDate: Date(),
            isFavorite: true,
            isEdited: true,
            isScreenshot: false,
            isLivePhoto: false,
            isHDR: false,
            burstIdentifier: "burst-1",
            aspectRatio: 1.0,
            fileSizeBytes: 200
        )

        try await store.upsertFeature(feature1)
        try await store.upsertFeature(feature2)

        let count = try await store.featureCount()
        XCTAssertEqual(count, 1, "Upsert should not create duplicates")

        let embedding = try await store.loadEmbedding(for: "same-id")
        XCTAssertEqual(embedding?.count, 256, "Should have the updated embedding")
    }

    func testBatchUpsertFeatures() async throws {
        var features: [PhotoFeatureRecord] = []
        for i in 0..<50 {
            let feature = PhotoFeatureRecord(
                assetID: "asset-\(i)",
                embedding: Data(repeating: UInt8(i % 256), count: 128),
                embeddingVersion: 1,
                pixelWidth: 3000 + i,
                pixelHeight: 2000 + i,
                creationDate: Date(),
                isFavorite: i % 3 == 0,
                isEdited: i % 5 == 0,
                isScreenshot: i % 10 == 0,
                isLivePhoto: false,
                isHDR: false,
                burstIdentifier: i % 7 == 0 ? "burst-\(i / 7)" : nil,
                aspectRatio: Double(3000 + i) / Double(2000 + i),
                fileSizeBytes: Int64(1_000_000 + i * 1000)
            )
            features.append(feature)
        }

        try await store.upsertFeatures(features)
        let count = try await store.featureCount()
        XCTAssertEqual(count, 50)
    }

    func testLoadEmbedding() async throws {
        let expectedData = Data([0x01, 0x02, 0x03, 0x04])
        let feature = PhotoFeatureRecord(
            assetID: "embed-test",
            embedding: expectedData,
            embeddingVersion: 1,
            pixelWidth: 100,
            pixelHeight: 100,
            creationDate: nil,
            isFavorite: false,
            isEdited: false,
            isScreenshot: false,
            isLivePhoto: false,
            isHDR: false,
            burstIdentifier: nil,
            aspectRatio: 1.0,
            fileSizeBytes: 0
        )

        try await store.upsertFeature(feature)
        let loaded = try await store.loadEmbedding(for: "embed-test")
        XCTAssertEqual(loaded, expectedData)
    }

    func testLoadEmbeddingMissing() async throws {
        let loaded = try await store.loadEmbedding(for: "nonexistent")
        XCTAssertNil(loaded)
    }

    // MARK: - Pairwise Similarity

    func testUpsertPairSimilarity() async throws {
        let pair = PairSimilarityRecord(
            lhsAssetID: "a",
            rhsAssetID: "b",
            featureDistance: 0.03,
            timeDeltaSeconds: 2.5,
            isBurstPair: false,
            bucket: "nearDuplicate",
            similarityScore: 0.85
        )

        try await store.upsertPairSimilarity(pair)
        let count = try await store.pairSimilarityCount()
        XCTAssertEqual(count, 1)
    }

    func testPairKeyOrdering() async throws {
        // Inserting (b, a) should be stored as (a, b) and not create a duplicate
        let pair1 = PairSimilarityRecord(
            lhsAssetID: "z-asset",
            rhsAssetID: "a-asset",
            featureDistance: 0.05,
            timeDeltaSeconds: nil,
            isBurstPair: false,
            bucket: "visuallySimilar",
            similarityScore: 0.6
        )

        let pair2 = PairSimilarityRecord(
            lhsAssetID: "a-asset",
            rhsAssetID: "z-asset",
            featureDistance: 0.04,
            timeDeltaSeconds: 1.0,
            isBurstPair: true,
            bucket: "burstShot",
            similarityScore: 0.7
        )

        try await store.upsertPairSimilarity(pair1)
        try await store.upsertPairSimilarity(pair2)
        let count = try await store.pairSimilarityCount()
        XCTAssertEqual(count, 1, "Reversed pair should upsert, not duplicate")
    }

    // MARK: - Feedback Events

    func testInsertFeedbackEvent() async throws {
        let event = FeedbackEventRecord(
            id: UUID().uuidString,
            timestamp: Date().timeIntervalSince1970,
            source: "similarGroupReview",
            kind: "keepBest",
            stage: "committed",
            dedupeKey: "test-key",
            groupID: UUID().uuidString,
            groupType: "nearDuplicate",
            bucket: "nearDuplicate",
            confidence: "high",
            suggestedAction: "suggestDeleteOthers",
            suggestedKeeperID: "asset-1",
            finalKeeperID: "asset-1",
            deletedIDs: "asset-2,asset-3",
            keptIDs: "asset-1",
            skipped: false,
            recommendationAccepted: true,
            policyVersion: 1,
            modelVersion: 1,
            featureSchemaVersion: 1,
            note: nil
        )

        try await store.insertFeedbackEvent(event)
        let count = try await store.feedbackEventCount()
        XCTAssertEqual(count, 1)
    }

    func testDuplicateFeedbackIgnored() async throws {
        let id = UUID().uuidString
        let event = FeedbackEventRecord(
            id: id,
            timestamp: Date().timeIntervalSince1970,
            source: "swipeMode",
            kind: "swipeKeep",
            stage: "committed",
            dedupeKey: "swipe-1",
            groupID: nil,
            groupType: nil,
            bucket: nil,
            confidence: nil,
            suggestedAction: nil,
            suggestedKeeperID: nil,
            finalKeeperID: nil,
            deletedIDs: "",
            keptIDs: "asset-1",
            skipped: false,
            recommendationAccepted: nil,
            policyVersion: 1,
            modelVersion: 1,
            featureSchemaVersion: 1,
            note: nil
        )

        try await store.insertFeedbackEvent(event)
        try await store.insertFeedbackEvent(event) // duplicate
        let count = try await store.feedbackEventCount()
        XCTAssertEqual(count, 1, "Duplicate event should be ignored")
    }

    // MARK: - Training Rows

    func testInsertTrainingRows() async throws {
        // Insert parent feedback events first (foreign key constraint)
        var eventIDs: [String] = []
        for i in 0..<10 {
            let eid = UUID().uuidString
            eventIDs.append(eid)
            let event = FeedbackEventRecord(
                id: eid, timestamp: Date().timeIntervalSince1970,
                source: "test", kind: "keepBest", stage: "committed",
                dedupeKey: "dk-\(i)", groupID: nil, groupType: nil,
                bucket: nil, confidence: nil, suggestedAction: nil,
                suggestedKeeperID: nil, finalKeeperID: nil,
                deletedIDs: "", keptIDs: "", skipped: false,
                recommendationAccepted: nil, policyVersion: 1,
                modelVersion: 1, featureSchemaVersion: 1, note: nil
            )
            try await store.insertFeedbackEvent(event)
        }

        var rows: [TrainingRowRecord] = []
        for i in 0..<10 {
            let row = TrainingRowRecord(
                id: "row-\(i)",
                eventID: eventIDs[i],
                kind: i % 2 == 0 ? "keeperRanking" : "groupOutcome",
                timestamp: Date().timeIntervalSince1970,
                stage: "committed",
                groupID: UUID().uuidString,
                assetID: "asset-\(i)",
                assetRole: "candidate",
                outcomeLabel: i % 2 == 0 ? "keeper" : "deleted",
                bucket: "nearDuplicate",
                groupType: "nearDuplicate",
                confidence: "high",
                suggestedAction: "suggestDeleteOthers",
                recommendationAccepted: true,
                keeperAssetID: "asset-0",
                rankingScore: 0.85,
                similarityToKeeper: 0.03,
                policyVersion: 1,
                modelVersion: 1,
                featureSchemaVersion: 1,
                featurePixelWidth: 4032,
                featurePixelHeight: 3024,
                featureIsFavorite: false,
                featureIsEdited: false,
                featureIsScreenshot: false,
                featureBurstPresent: false,
                featureRankingScore: 0.85,
                featureSimilarityToKeeper: 0.03
            )
            rows.append(row)
        }

        try await store.insertTrainingRows(rows)
        let total = try await store.trainingRowCount()
        XCTAssertEqual(total, 10)

        let keeperCount = try await store.trainingRowCount(kind: "keeperRanking")
        XCTAssertEqual(keeperCount, 5)

        let groupCount = try await store.trainingRowCount(kind: "groupOutcome")
        XCTAssertEqual(groupCount, 5)
    }

    // MARK: - CSV Export

    func testExportKeeperCSV() async throws {
        // Insert parent feedback events first (foreign key constraint)
        var eventIDs: [String] = []
        for i in 0..<5 {
            let eid = UUID().uuidString
            eventIDs.append(eid)
            let event = FeedbackEventRecord(
                id: eid, timestamp: Date().timeIntervalSince1970,
                source: "test", kind: "keepBest", stage: "committed",
                dedupeKey: "csv-dk-\(i)", groupID: nil, groupType: nil,
                bucket: nil, confidence: nil, suggestedAction: nil,
                suggestedKeeperID: nil, finalKeeperID: nil,
                deletedIDs: "", keptIDs: "", skipped: false,
                recommendationAccepted: nil, policyVersion: 1,
                modelVersion: 1, featureSchemaVersion: 1, note: nil
            )
            try await store.insertFeedbackEvent(event)
        }

        var rows: [TrainingRowRecord] = []
        for i in 0..<5 {
            let row = TrainingRowRecord(
                id: "export-\(i)",
                eventID: eventIDs[i],
                kind: "keeperRanking",
                timestamp: Date().timeIntervalSince1970,
                stage: "committed",
                groupID: UUID().uuidString,
                assetID: "asset-\(i)",
                assetRole: i == 0 ? "finalKeeper" : "candidate",
                outcomeLabel: i == 0 ? "keeper" : "candidate",
                bucket: "nearDuplicate",
                groupType: "nearDuplicate",
                confidence: "high",
                suggestedAction: "suggestDeleteOthers",
                recommendationAccepted: true,
                keeperAssetID: "asset-0",
                rankingScore: Double(10 - i) / 10.0,
                similarityToKeeper: 0.03,
                policyVersion: 1,
                modelVersion: 1,
                featureSchemaVersion: 1,
                featurePixelWidth: 4032,
                featurePixelHeight: 3024,
                featureIsFavorite: i == 0,
                featureIsEdited: false,
                featureIsScreenshot: false,
                featureBurstPresent: false,
                featureRankingScore: Double(10 - i) / 10.0,
                featureSimilarityToKeeper: 0.03
            )
            rows.append(row)
        }
        try await store.insertTrainingRows(rows)

        let csv = try await store.exportKeeperTrainingCSV()
        let lines = csv.components(separatedBy: "\n")

        XCTAssertTrue(lines.count >= 2, "Should have header + at least 1 data row")
        XCTAssertTrue(lines[0].contains("outcome_label"), "Header should contain outcome_label")
        XCTAssertEqual(lines.count, 6, "1 header + 5 data rows")
    }

    // MARK: - Stats

    func testStats() async throws {
        let feature = PhotoFeatureRecord(
            assetID: "stats-test",
            embedding: Data(repeating: 0xFF, count: 64),
            embeddingVersion: 1,
            pixelWidth: 100,
            pixelHeight: 100,
            creationDate: nil,
            isFavorite: false,
            isEdited: false,
            isScreenshot: false,
            isLivePhoto: false,
            isHDR: false,
            burstIdentifier: nil,
            aspectRatio: 1.0,
            fileSizeBytes: 0
        )
        try await store.upsertFeature(feature)

        let stats = try await store.stats()
        XCTAssertEqual(stats.featureCount, 1)
        XCTAssertEqual(stats.embeddingCount, 1)
        XCTAssertTrue(stats.databaseSizeBytes > 0)
    }

    // MARK: - Maintenance

    func testDeleteOldFeatures() async throws {
        let oldFeature = PhotoFeatureRecord(
            assetID: "old-asset",
            embedding: nil,
            embeddingVersion: 1,
            pixelWidth: 100,
            pixelHeight: 100,
            creationDate: nil,
            isFavorite: false,
            isEdited: false,
            isScreenshot: false,
            isLivePhoto: false,
            isHDR: false,
            burstIdentifier: nil,
            aspectRatio: 1.0,
            fileSizeBytes: 0
        )
        try await store.upsertFeature(oldFeature)

        let deleted = try await store.deleteOldFeatures(olderThan: Date().addingTimeInterval(10))
        XCTAssertEqual(deleted, 1)

        let count = try await store.featureCount()
        XCTAssertEqual(count, 0)
    }

    func testDeleteAllData() async throws {
        let feature = PhotoFeatureRecord(
            assetID: "delete-all-test",
            embedding: Data([0x01]),
            embeddingVersion: 1,
            pixelWidth: 100,
            pixelHeight: 100,
            creationDate: nil,
            isFavorite: false,
            isEdited: false,
            isScreenshot: false,
            isLivePhoto: false,
            isHDR: false,
            burstIdentifier: nil,
            aspectRatio: 1.0,
            fileSizeBytes: 0
        )
        try await store.upsertFeature(feature)

        try await store.deleteAllData()
        let count = try await store.featureCount()
        XCTAssertEqual(count, 0)
    }
}
