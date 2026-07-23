import XCTest
@testable import iOSCleanup

private actor RecordingKeeperPredictionService: KeeperPredictionService {
    nonisolated let isAvailable = true
    private var recordedInputs: [KeeperPredictionInput] = []

    func predictKeeper(features: KeeperPredictionInput) async -> KeeperPredictionOutput? {
        recordedInputs.append(features)
        return KeeperPredictionOutput(
            predictedLabel: "candidate",
            keeperProbability: 0.1,
            candidateProbability: 0.9
        )
    }

    func inputs() -> [KeeperPredictionInput] {
        recordedInputs
    }
}

private actor ConfigurableKeeperPredictionService: KeeperPredictionService {
    nonisolated let isAvailable = true
    private let probabilitiesByPixelWidth: [Int: Double]
    private let delayNanoseconds: UInt64

    init(
        probabilitiesByPixelWidth: [Int: Double],
        delayNanoseconds: UInt64 = 0
    ) {
        self.probabilitiesByPixelWidth = probabilitiesByPixelWidth
        self.delayNanoseconds = delayNanoseconds
    }

    func predictKeeper(features: KeeperPredictionInput) async -> KeeperPredictionOutput? {
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        let keeperProbability = probabilitiesByPixelWidth[features.pixelWidth] ?? 0
        return KeeperPredictionOutput(
            predictedLabel: keeperProbability >= 0.5 ? "keeper" : "candidate",
            keeperProbability: keeperProbability,
            candidateProbability: 1 - keeperProbability
        )
    }
}

private struct FixedKeeperRankingService: KeeperRankingService {
    let result: KeeperRankingResult

    func rankKeeper(in input: SimilarityClusterInput) async -> KeeperRankingResult {
        result
    }
}

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

    private func validEmbedding(byte: UInt8 = 0x42) -> Data {
        Data(repeating: byte, count: PhotoEmbeddingContract.byteCount)
    }

    private func insertPairFeatures(for assetIDs: [String]) async throws {
        let records = assetIDs.enumerated().map { index, assetID in
            PhotoFeatureRecord(
                assetID: assetID,
                embedding: validEmbedding(byte: UInt8((index + 1) % 255)),
                embeddingVersion: PhotoEmbeddingContract.embeddingVersion,
                pixelWidth: 1_000,
                pixelHeight: 1_000,
                creationDate: nil,
                isFavorite: false,
                isEdited: false,
                isScreenshot: false,
                isLivePhoto: false,
                isHDR: false,
                burstIdentifier: nil,
                aspectRatio: 1,
                fileSizeBytes: 1_000
            )
        }
        try await store.upsertFeatures(records)
    }

    // MARK: - Photo Features

    func testUpsertAndCountFeatures() async throws {
        let feature = PhotoFeatureRecord(
            assetID: "test-asset-001",
            embedding: validEmbedding(),
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
            embedding: validEmbedding(byte: 0x01),
            embeddingVersion: PhotoEmbeddingContract.embeddingVersion,
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
            embedding: validEmbedding(byte: 0x02),
            embeddingVersion: PhotoEmbeddingContract.embeddingVersion,
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
        XCTAssertEqual(embedding, validEmbedding(byte: 0x02), "Should have the updated embedding")
    }

    func testMetadataOnlyUpsertPreservesExistingEmbedding() async throws {
        let expectedEmbedding = validEmbedding(byte: 0x01)
        let featureWithEmbedding = PhotoFeatureRecord(
            assetID: "metadata-refresh",
            embedding: expectedEmbedding,
            embeddingVersion: PhotoEmbeddingContract.embeddingVersion,
            pixelWidth: 1000,
            pixelHeight: 1000,
            creationDate: nil,
            isFavorite: false,
            isEdited: false,
            isScreenshot: false,
            isLivePhoto: false,
            isHDR: false,
            burstIdentifier: nil,
            aspectRatio: 1,
            fileSizeBytes: 100
        )
        let metadataOnlyRefresh = PhotoFeatureRecord(
            assetID: "metadata-refresh",
            embedding: nil,
            embeddingVersion: PhotoEmbeddingContract.embeddingVersion,
            pixelWidth: 2000,
            pixelHeight: 1500,
            creationDate: Date(),
            isFavorite: true,
            isEdited: true,
            isScreenshot: false,
            isLivePhoto: false,
            isHDR: false,
            burstIdentifier: nil,
            aspectRatio: 4.0 / 3.0,
            fileSizeBytes: 200
        )

        try await store.upsertFeature(featureWithEmbedding)
        try await store.upsertFeature(metadataOnlyRefresh)

        let storedEmbedding = try await store.loadEmbedding(for: "metadata-refresh")
        XCTAssertEqual(storedEmbedding, expectedEmbedding)
    }

    func testBatchUpsertFeatures() async throws {
        var features: [PhotoFeatureRecord] = []
        for i in 0..<50 {
            let feature = PhotoFeatureRecord(
                assetID: "asset-\(i)",
                embedding: validEmbedding(byte: UInt8(i % 256)),
                embeddingVersion: PhotoEmbeddingContract.embeddingVersion,
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
        let expectedData = validEmbedding(byte: 0x03)
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

    func testRejectsInvalidEmbeddingByteCount() async throws {
        let feature = PhotoFeatureRecord(
            assetID: "invalid-embedding",
            embedding: Data(repeating: 0x01, count: PhotoEmbeddingContract.byteCount - 1),
            embeddingVersion: PhotoEmbeddingContract.embeddingVersion,
            pixelWidth: 100,
            pixelHeight: 100,
            creationDate: nil,
            isFavorite: false,
            isEdited: false,
            isScreenshot: false,
            isLivePhoto: false,
            isHDR: false,
            burstIdentifier: nil,
            aspectRatio: 1,
            fileSizeBytes: 100
        )

        do {
            try await store.upsertFeature(feature)
            XCTFail("Malformed embedding should be rejected")
        } catch MLStoreError.invalidEmbeddingByteCount(let version, let expected, let actual) {
            XCTAssertEqual(version, PhotoEmbeddingContract.embeddingVersion)
            XCTAssertEqual(expected, PhotoEmbeddingContract.byteCount)
            XCTAssertEqual(actual, PhotoEmbeddingContract.byteCount - 1)
        }
    }

    // MARK: - Pairwise Similarity

    func testUpsertPairSimilarity() async throws {
        try await insertPairFeatures(for: ["a", "b"])
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
        try await insertPairFeatures(for: ["z-asset", "a-asset"])
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

    func testBatchUpsertPairSimilaritiesUsesCanonicalPairKeys() async throws {
        try await insertPairFeatures(for: ["a", "b", "c"])
        let pairs = [
            PairSimilarityRecord(
                lhsAssetID: "a",
                rhsAssetID: "b",
                featureDistance: 0.03,
                timeDeltaSeconds: 1,
                isBurstPair: false,
                bucket: "nearDuplicate",
                similarityScore: 0.8
            ),
            PairSimilarityRecord(
                lhsAssetID: "b",
                rhsAssetID: "a",
                featureDistance: 0.02,
                timeDeltaSeconds: 1,
                isBurstPair: false,
                bucket: "nearDuplicate",
                similarityScore: 0.9
            ),
            PairSimilarityRecord(
                lhsAssetID: "b",
                rhsAssetID: "c",
                featureDistance: 0.08,
                timeDeltaSeconds: 3,
                isBurstPair: false,
                bucket: "visuallySimilar",
                similarityScore: 0.5
            )
        ]

        try await store.upsertPairSimilarities(pairs)
        let pairCount = try await store.pairSimilarityCount()

        XCTAssertEqual(pairCount, 2)
    }

    func testPairCacheReadIsCanonicalAndVersionAware() async throws {
        try await insertPairFeatures(for: ["left", "right"])
        let pair = PairSimilarityRecord(
            lhsAssetID: "right",
            rhsAssetID: "left",
            featureDistance: 0.04,
            timeDeltaSeconds: 2,
            isBurstPair: false,
            bucket: "nearDuplicate",
            similarityScore: 0.8
        )
        try await store.upsertPairSimilarity(pair)

        let cached = try await store.loadPairSimilarity(
            lhsAssetID: "left",
            rhsAssetID: "right",
            embeddingVersion: PhotoEmbeddingContract.embeddingVersion
        )
        let otherVersion = try await store.loadPairSimilarity(
            lhsAssetID: "left",
            rhsAssetID: "right",
            embeddingVersion: 2
        )

        XCTAssertEqual(cached?.lhsAssetID, "left")
        XCTAssertEqual(cached?.rhsAssetID, "right")
        XCTAssertEqual(cached?.featureDistance, 0.04)
        XCTAssertEqual(cached?.embeddingVersion, PhotoEmbeddingContract.embeddingVersion)
        XCTAssertNil(otherVersion)
    }

    func testPairCacheRejectsMixedEmbeddingVersions() async throws {
        let versionOne = PhotoFeatureRecord(
            assetID: "v1",
            embedding: validEmbedding(),
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
            aspectRatio: 1,
            fileSizeBytes: 100
        )
        let versionTwo = PhotoFeatureRecord(
            assetID: "v2",
            embedding: Data(repeating: 0x02, count: 2_048 * MemoryLayout<Float>.size),
            embeddingVersion: 2,
            pixelWidth: 100,
            pixelHeight: 100,
            creationDate: nil,
            isFavorite: false,
            isEdited: false,
            isScreenshot: false,
            isLivePhoto: false,
            isHDR: false,
            burstIdentifier: nil,
            aspectRatio: 1,
            fileSizeBytes: 100
        )
        try await store.upsertFeatures([versionOne, versionTwo])

        do {
            try await store.upsertPairSimilarity(
                PairSimilarityRecord(
                    lhsAssetID: "v1",
                    rhsAssetID: "v2",
                    embeddingVersion: 1,
                    featureDistance: 0.04,
                    timeDeltaSeconds: 1,
                    isBurstPair: false,
                    bucket: "nearDuplicate",
                    similarityScore: 0.8
                )
            )
            XCTFail("Mixed embedding versions must never enter the pair cache")
        } catch MLStoreError.pairEmbeddingVersionMismatch(
            let assetID,
            let expected,
            let actual
        ) {
            XCTAssertEqual(assetID, "v2")
            XCTAssertEqual(expected, 1)
            XCTAssertEqual(actual, 2)
        }
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
                activeChoice: i % 2 == 0,
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
                featureSchemaVersion: PhotoTrainingExampleBuilder.featureSchemaVersion,
                activeChoice: true,
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

    func testInferenceSchemasMatchTrainingExportHeaders() {
        let keeperInput = KeeperPredictionInput(
            bucket: "nearDuplicate",
            groupType: "nearDuplicate",
            confidence: "high",
            suggestedAction: "keepBestTrashRest",
            pixelWidth: 4_032,
            pixelHeight: 3_024,
            isFavorite: true,
            isEdited: false,
            isScreenshot: false,
            burstPresent: false,
            rankingScore: 0.9,
            similarityToKeeper: 0.02,
            aspectRatio: 4.0 / 3.0,
            fileSizeBytes: 3_000_000
        )
        let groupInput = GroupActionPredictionInput(
            bucket: "nearDuplicate",
            groupType: "nearDuplicate",
            confidence: "high",
            suggestedAction: "keepBestTrashRest",
            assetCount: 3,
            avgRanking: 0.7,
            screenshotCount: 0,
            favoriteCount: 1,
            editedCount: 0
        )

        XCTAssertEqual(
            KeeperFeatureProvider(input: keeperInput).featureNames,
            Set(KeeperFeatureSchema.modelInputNames)
        )
        XCTAssertEqual(
            GroupActionFeatureProvider(input: groupInput).featureNames,
            Set(GroupActionFeatureSchema.modelInputNames)
        )
        XCTAssertTrue(PhotoMLStore.keeperTrainingCSVHeaders.contains("event_id"))
        XCTAssertTrue(PhotoMLStore.keeperTrainingCSVHeaders.contains("group_id"))
        XCTAssertTrue(PhotoMLStore.keeperTrainingCSVHeaders.contains("feature_schema_version"))
        XCTAssertTrue(PhotoMLStore.keeperTrainingCSVHeaders.contains("active_choice"))
        XCTAssertTrue(PhotoMLStore.groupOutcomeCSVHeaders.contains("event_id"))
        XCTAssertTrue(PhotoMLStore.groupOutcomeCSVHeaders.contains("group_id"))
        XCTAssertFalse(PhotoMLStore.keeperTrainingCSVHeaders.contains("recommendation_accepted"))
        XCTAssertFalse(PhotoMLStore.groupOutcomeCSVHeaders.contains("recommendation_accepted"))
    }

    func testKeeperCSVStreamsAndEscapesCommaQuoteAndNewline() async throws {
        let eventID = UUID().uuidString
        try await store.insertFeedbackEvent(
            FeedbackEventRecord(
                id: eventID,
                timestamp: Date().timeIntervalSince1970,
                source: "test",
                kind: "keepBest",
                stage: "committed",
                dedupeKey: "csv-escaping",
                groupID: nil,
                groupType: nil,
                bucket: nil,
                confidence: nil,
                suggestedAction: nil,
                suggestedKeeperID: nil,
                finalKeeperID: nil,
                deletedIDs: "",
                keptIDs: "",
                skipped: false,
                recommendationAccepted: nil,
                policyVersion: 1,
                modelVersion: 1,
                featureSchemaVersion: 1,
                note: nil
            )
        )
        try await store.insertTrainingRow(
            TrainingRowRecord(
                id: "csv-escaping-row",
                eventID: eventID,
                kind: "keeperRanking",
                timestamp: Date().timeIntervalSince1970,
                stage: "committed",
                groupID: nil,
                assetID: nil,
                assetRole: "candidate",
                outcomeLabel: "candidate",
                bucket: "near,\n\"duplicate\"",
                groupType: "nearDuplicate",
                confidence: "high",
                suggestedAction: "keepBestTrashRest",
                recommendationAccepted: nil,
                keeperAssetID: nil,
                rankingScore: 0.5,
                similarityToKeeper: 0.04,
                policyVersion: 1,
                modelVersion: 1,
                featureSchemaVersion: PhotoTrainingExampleBuilder.featureSchemaVersion,
                activeChoice: true,
                featurePixelWidth: 100,
                featurePixelHeight: 100,
                featureIsFavorite: false,
                featureIsEdited: false,
                featureIsScreenshot: false,
                featureBurstPresent: false,
                featureRankingScore: 0.5,
                featureSimilarityToKeeper: 0.04
            )
        )
        let destinationURL = tempDir.appendingPathComponent("keeper.csv")

        try await store.exportKeeperTrainingCSV(to: destinationURL)
        let csv = try String(contentsOf: destinationURL, encoding: .utf8)

        XCTAssertTrue(csv.contains("\"near,\n\"\"duplicate\"\"\""))
        XCTAssertTrue(csv.hasPrefix(PhotoMLStore.keeperTrainingCSVHeaders.joined(separator: ",")))
        XCTAssertTrue(csv.contains(",\(PhotoTrainingExampleBuilder.featureSchemaVersion),1,"))
    }

    func testPinnedVisionRequestMatchesEmbeddingStorageVersion() {
        let request = PhotoMLBridge.makePinnedFeaturePrintRequest()
        XCTAssertEqual(request.revision, PhotoMLBridge.pinnedFeaturePrintRevision)
        XCTAssertEqual(
            Int(request.revision),
            PhotoEmbeddingContract.embeddingVersion
        )
    }

    func testKeeperInferenceUsesFullClusterContextWithoutPlaceholders() async {
        let first = SimilarityAssetDescriptor(
            id: "a",
            captureTimestamp: Date(),
            pixelWidth: 4_032,
            pixelHeight: 3_024,
            isFavorite: true
        )
        let second = SimilarityAssetDescriptor(
            id: "b",
            captureTimestamp: Date().addingTimeInterval(2),
            pixelWidth: 4_000,
            pixelHeight: 3_000
        )
        let pairKey = SimilarityPairKey(first.id, second.id)
        let cluster = SimilarityClusterInput(
            assets: [first, second],
            pairwiseSignals: [
                pairKey: SimilaritySignals.make(
                    lhs: first,
                    rhs: second,
                    featureDistance: 0.03
                )
            ],
            keeperSignalsByAssetID: [
                first.id: KeeperSignals(
                    sharpness: 0.95,
                    blurPenalty: 0.05,
                    motionBlurPenalty: 0.05,
                    eyesOpenScore: nil,
                    expressionScore: nil,
                    exposureScore: 0.9,
                    favoriteBonus: 0.08,
                    editedBonusOrPenalty: 0,
                    framingScore: 0.9,
                    resolutionTiebreaker: 0.1
                ),
                second.id: KeeperSignals(
                    sharpness: 0.5,
                    blurPenalty: 0.5,
                    motionBlurPenalty: 0.4,
                    eyesOpenScore: nil,
                    expressionScore: nil,
                    exposureScore: 0.5,
                    favoriteBonus: 0,
                    editedBonusOrPenalty: 0,
                    framingScore: 0.5,
                    resolutionTiebreaker: 0
                )
            ]
        )
        let recorder = RecordingKeeperPredictionService()
        let service = MLEnhancedKeeperRankingService(mlKeeperService: recorder)

        _ = await service.rankKeeper(in: cluster)
        let inputs = await recorder.inputs()

        XCTAssertEqual(inputs.count, 2)
        XCTAssertTrue(inputs.allSatisfy { !$0.bucket.isEmpty })
        XCTAssertTrue(inputs.allSatisfy { !$0.groupType.isEmpty })
        XCTAssertTrue(inputs.allSatisfy { !$0.confidence.isEmpty })
        XCTAssertTrue(inputs.allSatisfy { !$0.suggestedAction.isEmpty })
        XCTAssertTrue(inputs.allSatisfy { $0.fileSizeBytes > 0 })
        XCTAssertEqual(Set(inputs.map(\.similarityToKeeper)), [0, 0.03])
        XCTAssertEqual(Set(inputs.map(\.bucket)), ["nearDuplicate"])
        XCTAssertEqual(Set(inputs.map(\.fileSizeBytes)).count, 2)
    }

    func testMLKeeperOverrideRequiresConfidenceAndMarginThenUsesConservativeBlend() async {
        let cluster = makeMLRankingCluster()
        let heuristic = makeFixedHeuristicRanking()
        let predictor = ConfigurableKeeperPredictionService(
            probabilitiesByPixelWidth: [4_000: 0.10, 3_000: 0.95]
        )
        let service = MLEnhancedKeeperRankingService(
            heuristicService: FixedKeeperRankingService(result: heuristic),
            mlKeeperService: predictor
        )

        let result = await service.rankKeeper(in: cluster)

        XCTAssertEqual(result.keeperAssetID, "b")
        XCTAssertEqual(result.rankedAssetIDs.first, "b")
        XCTAssertEqual(result.scoreByAssetID["a"] ?? -1, 0.46, accuracy: 0.0001)
        XCTAssertEqual(result.scoreByAssetID["b"] ?? -1, 0.74, accuracy: 0.0001)
        XCTAssertTrue(
            result.reasonsByAssetID["b"]?.contains {
                $0.contains("ML keeper prediction")
            } == true
        )
    }

    func testMLKeeperOverrideRejectsBorderlineConfidenceOrMargin() async {
        let cluster = makeMLRankingCluster()
        let heuristic = makeFixedHeuristicRanking()

        for probabilities in [
            [4_000: 0.10, 3_000: 0.84],
            [4_000: 0.80, 3_000: 0.90]
        ] {
            let predictor = ConfigurableKeeperPredictionService(
                probabilitiesByPixelWidth: probabilities
            )
            let service = MLEnhancedKeeperRankingService(
                heuristicService: FixedKeeperRankingService(result: heuristic),
                mlKeeperService: predictor
            )

            let result = await service.rankKeeper(in: cluster)

            XCTAssertEqual(result, heuristic)
        }
    }

    func testMLKeeperRankingCancellationFallsBackToAuthoritativeHeuristic() async {
        let cluster = makeMLRankingCluster()
        let heuristic = makeFixedHeuristicRanking()
        let predictor = ConfigurableKeeperPredictionService(
            probabilitiesByPixelWidth: [4_000: 0.10, 3_000: 0.99],
            delayNanoseconds: 5_000_000_000
        )
        let service = MLEnhancedKeeperRankingService(
            heuristicService: FixedKeeperRankingService(result: heuristic),
            mlKeeperService: predictor
        )
        let task = Task {
            await service.rankKeeper(in: cluster)
        }

        try? await Task.sleep(nanoseconds: 10_000_000)
        task.cancel()
        let result = await task.value

        XCTAssertEqual(result, heuristic)
    }

    // MARK: - Stats

    func testStats() async throws {
        let feature = PhotoFeatureRecord(
            assetID: "stats-test",
            embedding: validEmbedding(byte: 0xFF),
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

    func testRetentionBoundsTrainingRowsAndRemovesInactiveAssets() async throws {
        for index in 0..<5 {
            let eventID = "retention-event-\(index)"
            try await store.insertFeedbackEvent(
                FeedbackEventRecord(
                    id: eventID,
                    timestamp: Double(index),
                    source: "test",
                    kind: "keepBest",
                    stage: "committed",
                    dedupeKey: eventID,
                    groupID: nil,
                    groupType: nil,
                    bucket: nil,
                    confidence: nil,
                    suggestedAction: nil,
                    suggestedKeeperID: nil,
                    finalKeeperID: nil,
                    deletedIDs: "",
                    keptIDs: "",
                    skipped: false,
                    recommendationAccepted: nil,
                    policyVersion: 1,
                    modelVersion: 1,
                    featureSchemaVersion: 1,
                    note: nil
                )
            )
            try await store.insertTrainingRow(
                TrainingRowRecord(
                    id: "retention-row-\(index)",
                    eventID: eventID,
                    kind: "keeperRanking",
                    timestamp: Double(index),
                    stage: "committed",
                    groupID: nil,
                    assetID: nil,
                    assetRole: "candidate",
                    outcomeLabel: "candidate",
                    bucket: "nearDuplicate",
                    groupType: "nearDuplicate",
                    confidence: "high",
                    suggestedAction: "keepBestTrashRest",
                    recommendationAccepted: nil,
                    keeperAssetID: nil,
                    rankingScore: 0.5,
                    similarityToKeeper: 0.04,
                    policyVersion: 1,
                    modelVersion: 1,
                    featureSchemaVersion: 1,
                    activeChoice: true,
                    featurePixelWidth: 100,
                    featurePixelHeight: 100,
                    featureIsFavorite: false,
                    featureIsEdited: false,
                    featureIsScreenshot: false,
                    featureBurstPresent: false,
                    featureRankingScore: 0.5,
                    featureSimilarityToKeeper: 0.04
                )
            )
        }
        try await insertPairFeatures(for: ["active-a", "active-b", "inactive"])
        try await store.upsertPairSimilarity(
            PairSimilarityRecord(
                lhsAssetID: "active-a",
                rhsAssetID: "inactive",
                featureDistance: 0.04,
                timeDeltaSeconds: 1,
                isBurstPair: false,
                bucket: "nearDuplicate",
                similarityScore: 0.8
            )
        )

        let result = try await store.performRetention(
            activeAssetIDs: ["active-a", "active-b"],
            maximumTrainingRows: 2,
            maximumPairRows: 10
        )
        let retainedTrainingRowCount = try await store.trainingRowCount()
        let retainedFeatureCount = try await store.featureCount()
        let retainedPairCount = try await store.pairSimilarityCount()

        XCTAssertEqual(result.deletedTrainingRows, 3)
        XCTAssertEqual(result.deletedFeatureRows, 1)
        XCTAssertEqual(result.deletedPairRows, 1)
        XCTAssertEqual(retainedTrainingRowCount, 2)
        XCTAssertEqual(retainedFeatureCount, 2)
        XCTAssertEqual(retainedPairCount, 0)
    }

    func testDatabaseExportIncludesWALBackedWrites() async throws {
        let feature = PhotoFeatureRecord(
            assetID: "wal-export",
            embedding: validEmbedding(),
            embeddingVersion: PhotoEmbeddingContract.embeddingVersion,
            pixelWidth: 100,
            pixelHeight: 100,
            creationDate: nil,
            isFavorite: false,
            isEdited: false,
            isScreenshot: false,
            isLivePhoto: false,
            isHDR: false,
            burstIdentifier: nil,
            aspectRatio: 1,
            fileSizeBytes: 100
        )
        try await store.upsertFeature(feature)

        let exportRoot = tempDir.appendingPathComponent("export-root", isDirectory: true)
        let destinationURL = exportRoot
            .appendingPathComponent("PhotoDuck/ml", isDirectory: true)
            .appendingPathComponent("photoduck-ml.sqlite")
        try await store.exportDatabase(to: destinationURL)

        let exportedStore = PhotoMLStore(directoryURL: exportRoot)
        try await exportedStore.open()
        let exportedFeatureCount = try await exportedStore.featureCount()
        let exportedEmbedding = try await exportedStore.loadEmbedding(for: "wal-export")
        XCTAssertEqual(exportedFeatureCount, 1)
        XCTAssertEqual(exportedEmbedding, validEmbedding())
    }

    func testDeleteAllData() async throws {
        let feature = PhotoFeatureRecord(
            assetID: "delete-all-test",
            embedding: validEmbedding(byte: 0x01),
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

    private func makeMLRankingCluster() -> SimilarityClusterInput {
        let first = SimilarityAssetDescriptor(
            id: "a",
            captureTimestamp: Date(),
            pixelWidth: 4_000,
            pixelHeight: 3_000
        )
        let second = SimilarityAssetDescriptor(
            id: "b",
            captureTimestamp: Date().addingTimeInterval(1),
            pixelWidth: 3_000,
            pixelHeight: 2_250
        )
        let signals = SimilaritySignals.make(
            lhs: first,
            rhs: second,
            featureDistance: 0.03
        )
        let keeperSignals = KeeperSignals(
            sharpness: 0.8,
            blurPenalty: 0.2,
            motionBlurPenalty: 0.1,
            eyesOpenScore: nil,
            expressionScore: nil,
            exposureScore: 0.8,
            favoriteBonus: 0,
            editedBonusOrPenalty: 0,
            framingScore: 0.8,
            resolutionTiebreaker: 0.1
        )
        return SimilarityClusterInput(
            assets: [first, second],
            pairwiseSignals: [
                SimilarityPairKey(first.id, second.id): signals
            ],
            keeperSignalsByAssetID: [
                first.id: keeperSignals,
                second.id: keeperSignals
            ]
        )
    }

    private func makeFixedHeuristicRanking() -> KeeperRankingResult {
        let signals = KeeperSignals(
            sharpness: 0.8,
            blurPenalty: 0.2,
            motionBlurPenalty: 0.1,
            eyesOpenScore: nil,
            expressionScore: nil,
            exposureScore: 0.8,
            favoriteBonus: 0,
            editedBonusOrPenalty: 0,
            framingScore: 0.8,
            resolutionTiebreaker: 0.1
        )
        return KeeperRankingResult(
            keeperAssetID: "a",
            rankedAssetIDs: ["a", "b"],
            scoreByAssetID: ["a": 0.70, "b": 0.60],
            reasonsByAssetID: ["a": ["Sharper frame"], "b": []],
            scoreBreakdownByAssetID: ["a": signals, "b": signals]
        )
    }
}
