import Foundation
import Photos
@preconcurrency import Vision

// MARK: - PhotoMLBridge
// Bridges existing domain types to/from PhotoMLStore records.
// Handles embedding extraction and persistence during scan.

actor PhotoMLBridge {
    static let shared = PhotoMLBridge()

    private let store: PhotoMLStore

    init(store: PhotoMLStore = .shared) {
        self.store = store
    }

    // MARK: - Embedding Extraction

    /// Extract VNFeaturePrintObservation and return as raw Data (Float array).
    nonisolated func extractEmbedding(from observation: VNFeaturePrintObservation) -> Data? {
        // VNFeaturePrintObservation stores floats internally.
        // We use computeDistance to verify dimensions, then extract via Mirror or direct copy.
        let elementCount = observation.elementCount
        guard elementCount > 0 else { return nil }

        // VNFeaturePrintObservation.data contains the raw float buffer
        let data = observation.data
        guard data.count == elementCount * MemoryLayout<Float>.size else { return nil }
        return data
    }

    // MARK: - Persist features during scan

    /// Called during PhotoScanEngine scan to persist features + embeddings.
    func persistFeatures(
        for assets: [PHAsset],
        prints: [String: VNFeaturePrintObservation]
    ) async {
        var records: [PhotoFeatureRecord] = []

        for asset in assets {
            let embedding: Data?
            if let observation = prints[asset.localIdentifier] {
                embedding = extractEmbedding(from: observation)
            } else {
                embedding = nil
            }

            let isEdited: Bool
            if let creationDate = asset.creationDate, let modificationDate = asset.modificationDate {
                isEdited = abs(modificationDate.timeIntervalSince(creationDate)) > 1
            } else {
                isEdited = false
            }

            records.append(PhotoFeatureRecord(
                assetID: asset.localIdentifier,
                embedding: embedding,
                embeddingVersion: 1,
                pixelWidth: asset.pixelWidth,
                pixelHeight: asset.pixelHeight,
                creationDate: asset.creationDate,
                isFavorite: asset.isFavorite,
                isEdited: isEdited,
                isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot),
                isLivePhoto: asset.mediaSubtypes.contains(.photoLive),
                isHDR: asset.mediaSubtypes.contains(.photoHDR),
                burstIdentifier: asset.burstIdentifier,
                aspectRatio: Double(asset.pixelWidth) / Double(max(asset.pixelHeight, 1)),
                fileSizeBytes: asset.estimatedFileSize
            ))
        }

        do {
            try await store.open()
            try await store.upsertFeatures(records)
        } catch {
            // Non-fatal: ML store write failure should not block scan
            #if DEBUG
            print("[PhotoMLBridge] Failed to persist features: \(error)")
            #endif
        }
    }

    /// Persist pairwise similarity results during scan.
    func persistPairSimilarity(
        lhsID: String,
        rhsID: String,
        distance: Float,
        timeDelta: Double?,
        isBurstPair: Bool,
        bucket: SimilarityBucket,
        similarityScore: Double
    ) async {
        let record = PairSimilarityRecord(
            lhsAssetID: lhsID,
            rhsAssetID: rhsID,
            featureDistance: Double(distance),
            timeDeltaSeconds: timeDelta,
            isBurstPair: isBurstPair,
            bucket: bucket.rawValue,
            similarityScore: similarityScore
        )

        do {
            try await store.open()
            try await store.upsertPairSimilarity(record)
        } catch {
            #if DEBUG
            print("[PhotoMLBridge] Failed to persist pair similarity: \(error)")
            #endif
        }
    }

    // MARK: - Persist feedback events

    func persistFeedbackEvent(_ event: PhotoReviewFeedbackEvent) async {
        let eventRecord = FeedbackEventRecord(
            id: event.id.uuidString,
            timestamp: event.timestamp.timeIntervalSince1970,
            source: event.source.rawValue,
            kind: event.kind.rawValue,
            stage: event.stage.rawValue,
            dedupeKey: event.dedupeKey,
            groupID: event.groupID?.uuidString,
            groupType: event.groupType?.rawValue,
            bucket: event.bucket?.rawValue,
            confidence: event.confidence?.rawValue,
            suggestedAction: event.suggestedAction?.rawValue,
            suggestedKeeperID: event.suggestedKeeperAssetID,
            finalKeeperID: event.finalKeeperAssetID,
            deletedIDs: event.deletedAssetIDs.joined(separator: ","),
            keptIDs: event.keptAssetIDs.joined(separator: ","),
            skipped: event.skipped,
            recommendationAccepted: event.recommendationAccepted,
            policyVersion: event.policyVersion,
            modelVersion: event.modelVersion,
            featureSchemaVersion: event.featureSchemaVersion,
            note: event.note
        )

        do {
            try await store.open()
            try await store.insertFeedbackEvent(eventRecord)

            // Also generate and persist training rows
            let trainingRows = PhotoTrainingExampleBuilder.makeRows(from: event)
            let rowRecords = trainingRows.map { makeTrainingRowRecord(from: $0) }
            try await store.insertTrainingRows(rowRecords)
        } catch {
            #if DEBUG
            print("[PhotoMLBridge] Failed to persist feedback: \(error)")
            #endif
        }
    }

    func persistFeedbackEvents(_ events: [PhotoReviewFeedbackEvent]) async {
        for event in events {
            await persistFeedbackEvent(event)
        }
    }

    // MARK: - Training Export

    func exportKeeperTrainingCSV() async throws -> String {
        try await store.open()
        return try await store.exportKeeperTrainingCSV()
    }

    func exportGroupOutcomeCSV() async throws -> String {
        try await store.open()
        return try await store.exportGroupOutcomeCSV()
    }

    /// Export both CSVs to files in the Documents directory for AirDrop / Finder access.
    func exportTrainingDataToDocuments() async throws -> [URL] {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let mlExportDir = documentsURL.appendingPathComponent("PhotoDuck-ML-Export", isDirectory: true)
        try FileManager.default.createDirectory(at: mlExportDir, withIntermediateDirectories: true)

        let keeperCSV = try await exportKeeperTrainingCSV()
        let groupCSV = try await exportGroupOutcomeCSV()
        let stats = try await store.stats()

        let keeperURL = mlExportDir.appendingPathComponent("keeper_ranking_training.csv")
        let groupURL = mlExportDir.appendingPathComponent("group_outcome_training.csv")
        let statsURL = mlExportDir.appendingPathComponent("training_stats.json")

        try keeperCSV.write(to: keeperURL, atomically: true, encoding: .utf8)
        try groupCSV.write(to: groupURL, atomically: true, encoding: .utf8)

        let statsJSON = """
        {
            "exportDate": "\(ISO8601DateFormatter().string(from: Date()))",
            "featureCount": \(stats.featureCount),
            "embeddingCount": \(stats.embeddingCount),
            "pairCount": \(stats.pairCount),
            "feedbackEventCount": \(stats.feedbackEventCount),
            "trainingRowCount": \(stats.trainingRowCount),
            "keeperRowCount": \(stats.keeperRowCount),
            "groupOutcomeRowCount": \(stats.groupOutcomeRowCount),
            "databaseSizeBytes": \(stats.databaseSizeBytes)
        }
        """
        try statsJSON.write(to: statsURL, atomically: true, encoding: .utf8)

        return [keeperURL, groupURL, statsURL]
    }

    /// Export the raw SQLite database for Mac-side training.
    func exportDatabaseToDocuments() async throws -> URL {
        try await store.open()
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let exportDir = documentsURL.appendingPathComponent("PhotoDuck-ML-Export", isDirectory: true)
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        let destURL = exportDir.appendingPathComponent("photoduck-ml.sqlite")

        // Copy the database file
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let srcURL = baseURL.appendingPathComponent("PhotoDuck/ml/photoduck-ml.sqlite")

        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }
        try FileManager.default.copyItem(at: srcURL, to: destURL)
        return destURL
    }

    // MARK: - Stats

    func stats() async throws -> MLStoreStats {
        try await store.open()
        return try await store.stats()
    }

    // MARK: - Helpers

    private func makeTrainingRowRecord(from row: PhotoTrainingExportRow) -> TrainingRowRecord {
        TrainingRowRecord(
            id: row.id,
            eventID: row.eventID.uuidString,
            kind: row.kind.rawValue,
            timestamp: row.timestamp.timeIntervalSince1970,
            stage: row.stage.rawValue,
            groupID: row.groupID?.uuidString,
            assetID: row.assetID,
            assetRole: row.assetRole.rawValue,
            outcomeLabel: row.outcomeLabel,
            bucket: row.bucket?.rawValue,
            groupType: row.groupType?.rawValue,
            confidence: row.confidence?.rawValue,
            suggestedAction: row.suggestedAction?.rawValue,
            recommendationAccepted: row.recommendationAccepted,
            keeperAssetID: row.keeperAssetID,
            rankingScore: row.rankingScore,
            similarityToKeeper: row.similarityToKeeper,
            policyVersion: row.policyVersion,
            modelVersion: row.modelVersion,
            featureSchemaVersion: row.featureSchemaVersion,
            featurePixelWidth: row.featureVector?.pixelWidth,
            featurePixelHeight: row.featureVector?.pixelHeight,
            featureIsFavorite: row.featureVector?.isFavorite,
            featureIsEdited: row.featureVector?.isEdited,
            featureIsScreenshot: row.featureVector?.isScreenshot ?? false,
            featureBurstPresent: row.featureVector?.burstIdentifierPresent ?? false,
            featureRankingScore: row.featureVector?.rankingScore,
            featureSimilarityToKeeper: row.featureVector?.similarityToKeeper
        )
    }
}
