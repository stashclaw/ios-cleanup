import Foundation
import OSLog
import Photos
@preconcurrency import Vision

struct MLPersistenceHealth: Sendable, Equatable {
    let isHealthy: Bool
    let lastErrorDescription: String?
    let hasUnconsumedFailureNotice: Bool
}

// MARK: - PhotoMLBridge
// Bridges existing domain types to/from PhotoMLStore records.
// Handles embedding extraction and persistence during scan.

actor PhotoMLBridge {
    static let shared = PhotoMLBridge()
    static let pinnedFeaturePrintRevision = VNGenerateImageFeaturePrintRequestRevision1
    static let analyzerVersion = 1

    private static let logger = Logger(
        subsystem: "com.photoduck.iOSCleanup",
        category: "MLPersistence"
    )
    private let store: PhotoMLStore
    private var persistenceHealthy = true
    private var lastPersistenceError: String?
    private var hasUnconsumedFailureNotice = false
    private var bufferedFeatureRecords: [PhotoFeatureRecord] = []
    private var bufferedPairRecords: [PairSimilarityRecord] = []
    private var bufferedAssetAnalysisRecords: [PhotoAssetAnalysisCacheRecord] = []
    private var bufferFlushTask: Task<Void, Never>?

    private enum WriteBufferTuning {
        static let featureFlushCount = 96
        static let pairFlushCount = 384
        static let maximumFlushLatencyNanoseconds: UInt64 = 1_500_000_000
    }

    init(store: PhotoMLStore = .shared) {
        self.store = store
    }

    nonisolated static func makePinnedFeaturePrintRequest() -> VNGenerateImageFeaturePrintRequest {
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = pinnedFeaturePrintRevision
        return request
    }

    nonisolated func makeFeatureRecords(
        for assets: [PHAsset],
        embeddings: [String: Data]
    ) -> [PhotoFeatureRecord] {
        assets.map { asset in
            PhotoFeatureRecord(
                assetID: asset.localIdentifier,
                embedding: embeddings[asset.localIdentifier],
                embeddingVersion: PhotoEmbeddingContract.embeddingVersion,
                pixelWidth: asset.pixelWidth,
                pixelHeight: asset.pixelHeight,
                creationDate: asset.creationDate,
                isFavorite: asset.isFavorite,
                isEdited: asset.isEdited,
                isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot),
                isLivePhoto: asset.mediaSubtypes.contains(.photoLive),
                isHDR: asset.mediaSubtypes.contains(.photoHDR),
                burstIdentifier: asset.burstIdentifier,
                aspectRatio: Double(asset.pixelWidth) / Double(max(asset.pixelHeight, 1)),
                fileSizeBytes: asset.estimatedFileSize
            )
        }
    }

    // MARK: - Persist features during scan

    func persistFeatureRecords(_ records: [PhotoFeatureRecord]) async {
        guard !records.isEmpty else { return }
        do {
            try await store.open()
            try await store.upsertFeatures(records)
            recordPersistenceSuccess()
        } catch {
            recordPersistenceFailure(error, operation: "persist features")
        }
    }

    func persistPairSimilarities(_ records: [PairSimilarityRecord]) async {
        guard !records.isEmpty else { return }
        do {
            try await store.open()
            try await store.upsertPairSimilarities(records)
            recordPersistenceSuccess()
        } catch {
            recordPersistenceFailure(error, operation: "persist pair similarities")
        }
    }

    func bufferFeatureRecords(_ records: [PhotoFeatureRecord]) async {
        guard !records.isEmpty else { return }
        bufferedFeatureRecords.append(contentsOf: records)
        if bufferedFeatureRecords.count >= WriteBufferTuning.featureFlushCount {
            await flushBufferedWrites()
        } else {
            scheduleBufferedFlushIfNeeded()
        }
    }

    func bufferPairSimilarities(_ records: [PairSimilarityRecord]) async {
        guard !records.isEmpty else { return }
        bufferedPairRecords.append(contentsOf: records)
        if bufferedPairRecords.count >= WriteBufferTuning.pairFlushCount {
            await flushBufferedWrites()
        } else {
            scheduleBufferedFlushIfNeeded()
        }
    }

    func bufferAssetAnalyses(
        _ records: [PhotoAssetAnalysisCacheRecord]
    ) async {
        guard !records.isEmpty else { return }
        bufferedAssetAnalysisRecords.append(contentsOf: records)
        if bufferedAssetAnalysisRecords.count
            >= WriteBufferTuning.featureFlushCount {
            await flushBufferedWrites()
        } else {
            scheduleBufferedFlushIfNeeded()
        }
    }

    func flushBufferedWrites() async {
        bufferFlushTask?.cancel()
        bufferFlushTask = nil
        let features = bufferedFeatureRecords
        let pairs = bufferedPairRecords
        let assetAnalyses = bufferedAssetAnalysisRecords
        bufferedFeatureRecords.removeAll(keepingCapacity: true)
        bufferedPairRecords.removeAll(keepingCapacity: true)
        bufferedAssetAnalysisRecords.removeAll(keepingCapacity: true)
        await persistFeatureRecords(features)
        await persistPairSimilarities(pairs)
        await persistAssetAnalyses(assetAnalyses)
    }

    func cachedAssetAnalyses(
        for assets: [PHAsset]
    ) async -> [String: PhotoScanAssetAnalysis] {
        guard !assets.isEmpty else { return [:] }
        let lookups = assets.map {
            PhotoAssetAnalysisCacheLookup(
                assetID: $0.localIdentifier,
                modificationDate: $0.modificationDate,
                pixelWidth: $0.pixelWidth,
                pixelHeight: $0.pixelHeight,
                mediaSubtypesRawValue: UInt64($0.mediaSubtypes.rawValue),
                analyzerVersion: Self.analyzerVersion,
                embeddingVersion: PhotoEmbeddingContract.embeddingVersion
            )
        }
        do {
            try await store.open()
            let records = try await store.loadValidAssetAnalyses(for: lookups)
            var result: [String: PhotoScanAssetAnalysis] = [:]
            result.reserveCapacity(records.count)
            for (id, record) in records {
                let keeperSignals = record.keeperSignalsJSON.flatMap {
                    try? JSONDecoder().decode(KeeperSignals.self, from: $0)
                }
                result[id] = PhotoScanAssetAnalysis(
                    observation: nil,
                    embedding: record.embedding,
                    perceptualHash: record.perceptualHash,
                    keeperSignals: keeperSignals
                )
            }
            recordPersistenceSuccess()
            return result
        } catch {
            recordPersistenceFailure(error, operation: "read asset analysis cache")
            return [:]
        }
    }

    nonisolated func makeAssetAnalysisRecord(
        asset: PHAsset,
        analysis: PhotoScanAssetAnalysis
    ) -> PhotoAssetAnalysisCacheRecord {
        PhotoAssetAnalysisCacheRecord(
            assetID: asset.localIdentifier,
            modificationDate: asset.modificationDate,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            mediaSubtypesRawValue: UInt64(asset.mediaSubtypes.rawValue),
            analyzerVersion: Self.analyzerVersion,
            embeddingVersion: PhotoEmbeddingContract.embeddingVersion,
            embedding: analysis.embedding,
            perceptualHash: analysis.perceptualHash,
            keeperSignalsJSON: analysis.keeperSignals.flatMap {
                try? JSONEncoder().encode($0)
            }
        )
    }

    private func persistAssetAnalyses(
        _ records: [PhotoAssetAnalysisCacheRecord]
    ) async {
        guard !records.isEmpty else { return }
        do {
            try await store.open()
            try await store.upsertAssetAnalyses(records)
            recordPersistenceSuccess()
        } catch {
            recordPersistenceFailure(error, operation: "persist asset analyses")
        }
    }

    private func scheduleBufferedFlushIfNeeded() {
        guard bufferFlushTask == nil else { return }
        bufferFlushTask = Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: WriteBufferTuning.maximumFlushLatencyNanoseconds
            )
            guard !Task.isCancelled else { return }
            await self?.flushBufferedWrites()
        }
    }

    func cachedPairSimilarities(
        for keys: [SimilarityPairKey],
        embeddingVersion: Int = PhotoEmbeddingContract.embeddingVersion
    ) async -> [SimilarityPairKey: PairSimilarityRecord] {
        guard !keys.isEmpty else { return [:] }
        do {
            try await store.open()
            let records = try await store.loadPairSimilarities(
                for: keys,
                embeddingVersion: embeddingVersion
            )
            recordPersistenceSuccess()
            return records
        } catch {
            recordPersistenceFailure(error, operation: "read pair similarity cache")
            return [:]
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
            recordPersistenceSuccess()
        } catch {
            recordPersistenceFailure(error, operation: "persist feedback")
        }
    }

    func persistFeedbackEvents(_ events: [PhotoReviewFeedbackEvent]) async {
        for event in events {
            await persistFeedbackEvent(event)
        }
    }

    // MARK: - Training Export

    func exportKeeperTrainingCSV() async throws -> String {
        do {
            try await store.open()
            let csv = try await store.exportKeeperTrainingCSV()
            recordPersistenceSuccess()
            return csv
        } catch {
            recordPersistenceFailure(error, operation: "export keeper CSV")
            throw error
        }
    }

    func exportGroupOutcomeCSV() async throws -> String {
        do {
            try await store.open()
            let csv = try await store.exportGroupOutcomeCSV()
            recordPersistenceSuccess()
            return csv
        } catch {
            recordPersistenceFailure(error, operation: "export group-outcome CSV")
            throw error
        }
    }

    /// Export both CSVs to files in the Documents directory for AirDrop / Finder access.
    func exportTrainingDataToDocuments() async throws -> [URL] {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let mlExportDir = documentsURL.appendingPathComponent("PhotoDuck-ML-Export", isDirectory: true)
        try FileManager.default.createDirectory(at: mlExportDir, withIntermediateDirectories: true)

        let keeperURL = mlExportDir.appendingPathComponent("keeper_ranking_training.csv")
        let groupURL = mlExportDir.appendingPathComponent("group_outcome_training.csv")
        let statsURL = mlExportDir.appendingPathComponent("training_stats.json")

        do {
            try await store.open()
            _ = try await store.performRetention()
            try await store.exportKeeperTrainingCSV(to: keeperURL)
            try await store.exportGroupOutcomeCSV(to: groupURL)
            let stats = try await store.stats()
            let statsData = try JSONEncoder.mlExportEncoder.encode(
                MLExportStats(stats: stats)
            )
            try statsData.write(to: statsURL, options: .atomic)
            recordPersistenceSuccess()
            return [keeperURL, groupURL, statsURL]
        } catch {
            recordPersistenceFailure(error, operation: "export training data")
            throw error
        }
    }

    /// Export the raw SQLite database for Mac-side training.
    func exportDatabaseToDocuments() async throws -> URL {
        try await store.open()
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let exportDir = documentsURL.appendingPathComponent("PhotoDuck-ML-Export", isDirectory: true)
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        let destURL = exportDir.appendingPathComponent("photoduck-ml.sqlite")

        do {
            try await store.open()
            _ = try await store.performRetention()
            // Store serialization prevents writes between the checkpoint and copy.
            try await store.exportDatabase(to: destURL)
            recordPersistenceSuccess()
            return destURL
        } catch {
            recordPersistenceFailure(error, operation: "export SQLite database")
            throw error
        }
    }

    // MARK: - Stats

    func stats() async throws -> MLStoreStats {
        do {
            try await store.open()
            let value = try await store.stats()
            recordPersistenceSuccess()
            return value
        } catch {
            recordPersistenceFailure(error, operation: "read ML store stats")
            throw error
        }
    }

    @discardableResult
    func performRetention(
        activeAssetIDs: Set<String>? = nil,
        vacuumAfterward: Bool = false
    ) async throws -> MLStoreRetentionResult {
        do {
            try await store.open()
            let result = try await store.performRetention(
                activeAssetIDs: activeAssetIDs,
                vacuumAfterward: vacuumAfterward
            )
            recordPersistenceSuccess()
            return result
        } catch {
            recordPersistenceFailure(error, operation: "perform ML store retention")
            throw error
        }
    }

    func persistenceHealth() -> MLPersistenceHealth {
        MLPersistenceHealth(
            isHealthy: persistenceHealthy,
            lastErrorDescription: lastPersistenceError,
            hasUnconsumedFailureNotice: hasUnconsumedFailureNotice
        )
    }

    func consumePersistenceFailureNotice() -> String? {
        guard hasUnconsumedFailureNotice else { return nil }
        hasUnconsumedFailureNotice = false
        return lastPersistenceError
    }

    // MARK: - Helpers

    private func recordPersistenceSuccess() {
        persistenceHealthy = true
    }

    private func recordPersistenceFailure(_ error: Error, operation: String) {
        let description = "\(operation): \(error.localizedDescription)"
        persistenceHealthy = false
        lastPersistenceError = description
        hasUnconsumedFailureNotice = true
        Self.logger.error("\(description, privacy: .public)")
    }

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
            activeChoice: row.activeChoice,
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

private struct MLExportStats: Codable {
    let exportDate: Date
    let featureCount: Int
    let embeddingCount: Int
    let pairCount: Int
    let feedbackEventCount: Int
    let trainingRowCount: Int
    let keeperRowCount: Int
    let groupOutcomeRowCount: Int
    let databaseSizeBytes: Int64

    init(stats: MLStoreStats) {
        exportDate = Date()
        featureCount = stats.featureCount
        embeddingCount = stats.embeddingCount
        pairCount = stats.pairCount
        feedbackEventCount = stats.feedbackEventCount
        trainingRowCount = stats.trainingRowCount
        keeperRowCount = stats.keeperRowCount
        groupOutcomeRowCount = stats.groupOutcomeRowCount
        databaseSizeBytes = stats.databaseSizeBytes
    }
}

private extension JSONEncoder {
    static var mlExportEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
