import Foundation
import SQLite3

// MARK: - PhotoMLStore
// SQLite-backed feature store for ML training data.
// Stores Vision embeddings, feedback events, and pre-built training rows.
// Designed for on-device collection + Mac-side export for CreateML training.

actor PhotoMLStore {
    static let shared = PhotoMLStore()

    static let schemaVersion = 1
    static let embeddingDimension = 128 // VNFeaturePrintObservation float count (Vision v1 = 128, v2 = 2048)

    private var db: OpaquePointer?
    private let dbPath: String
    private var isOpen = false

    init(directoryURL: URL? = nil) {
        let baseURL = directoryURL
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = baseURL.appendingPathComponent("PhotoDuck/ml", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        dbPath = directory.appendingPathComponent("photoduck-ml.sqlite").path
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Open / Migrate

    func open() throws {
        guard !isOpen else { return }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(dbPath, &handle, flags, nil) == SQLITE_OK else {
            throw MLStoreError.cannotOpen(String(cString: sqlite3_errmsg(handle)))
        }
        db = handle
        isOpen = true

        // WAL mode for concurrent reads during scan
        exec("PRAGMA journal_mode = WAL")
        exec("PRAGMA synchronous = NORMAL")
        exec("PRAGMA foreign_keys = ON")

        try createTables()
    }

    private func createTables() throws {
        // Feature embeddings per photo asset
        try execOrThrow("""
            CREATE TABLE IF NOT EXISTS photo_features (
                asset_id TEXT PRIMARY KEY,
                embedding BLOB,
                embedding_version INT NOT NULL DEFAULT 1,
                pixel_width INT NOT NULL,
                pixel_height INT NOT NULL,
                creation_date REAL,
                is_favorite INT NOT NULL DEFAULT 0,
                is_edited INT NOT NULL DEFAULT 0,
                is_screenshot INT NOT NULL DEFAULT 0,
                is_live_photo INT NOT NULL DEFAULT 0,
                is_hdr INT NOT NULL DEFAULT 0,
                burst_identifier TEXT,
                aspect_ratio REAL NOT NULL DEFAULT 1.0,
                file_size_bytes INT NOT NULL DEFAULT 0,
                updated_at REAL NOT NULL
            )
        """)

        // Pairwise similarity cache
        try execOrThrow("""
            CREATE TABLE IF NOT EXISTS pairwise_similarity (
                lhs_asset_id TEXT NOT NULL,
                rhs_asset_id TEXT NOT NULL,
                feature_distance REAL NOT NULL,
                time_delta_seconds REAL,
                is_burst_pair INT NOT NULL DEFAULT 0,
                bucket TEXT NOT NULL,
                similarity_score REAL NOT NULL,
                computed_at REAL NOT NULL,
                PRIMARY KEY (lhs_asset_id, rhs_asset_id)
            )
        """)

        // Feedback events (mirrors PhotoReviewFeedbackEvent)
        try execOrThrow("""
            CREATE TABLE IF NOT EXISTS feedback_events (
                id TEXT PRIMARY KEY,
                timestamp REAL NOT NULL,
                source TEXT NOT NULL,
                kind TEXT NOT NULL,
                stage TEXT NOT NULL,
                dedupe_key TEXT NOT NULL,
                group_id TEXT,
                group_type TEXT,
                bucket TEXT,
                confidence TEXT,
                suggested_action TEXT,
                suggested_keeper_id TEXT,
                final_keeper_id TEXT,
                deleted_ids TEXT,
                kept_ids TEXT,
                skipped INT NOT NULL DEFAULT 0,
                recommendation_accepted INT,
                policy_version INT NOT NULL DEFAULT 1,
                model_version INT NOT NULL DEFAULT 1,
                feature_schema_version INT NOT NULL DEFAULT 1,
                note TEXT
            )
        """)

        // Per-asset feedback snapshot (one row per asset per event)
        try execOrThrow("""
            CREATE TABLE IF NOT EXISTS feedback_assets (
                event_id TEXT NOT NULL,
                asset_id TEXT NOT NULL,
                role TEXT NOT NULL,
                pixel_width INT NOT NULL DEFAULT 1,
                pixel_height INT NOT NULL DEFAULT 1,
                is_favorite INT,
                is_edited INT,
                is_screenshot INT,
                burst_identifier TEXT,
                similarity_to_keeper REAL,
                ranking_score REAL,
                flags TEXT,
                PRIMARY KEY (event_id, asset_id),
                FOREIGN KEY (event_id) REFERENCES feedback_events(id) ON DELETE CASCADE
            )
        """)

        // Pre-built training rows for export
        try execOrThrow("""
            CREATE TABLE IF NOT EXISTS training_rows (
                id TEXT PRIMARY KEY,
                event_id TEXT NOT NULL,
                kind TEXT NOT NULL,
                timestamp REAL NOT NULL,
                stage TEXT NOT NULL,
                group_id TEXT,
                asset_id TEXT,
                asset_role TEXT NOT NULL,
                outcome_label TEXT NOT NULL,
                bucket TEXT,
                group_type TEXT,
                confidence TEXT,
                suggested_action TEXT,
                recommendation_accepted INT,
                keeper_asset_id TEXT,
                ranking_score REAL,
                similarity_to_keeper REAL,
                policy_version INT NOT NULL,
                model_version INT NOT NULL,
                feature_schema_version INT NOT NULL,
                feature_pixel_width INT,
                feature_pixel_height INT,
                feature_is_favorite INT,
                feature_is_edited INT,
                feature_is_screenshot INT NOT NULL DEFAULT 0,
                feature_burst_present INT NOT NULL DEFAULT 0,
                feature_ranking_score REAL,
                feature_similarity_to_keeper REAL,
                FOREIGN KEY (event_id) REFERENCES feedback_events(id) ON DELETE CASCADE
            )
        """)

        // Schema version tracking
        try execOrThrow("""
            CREATE TABLE IF NOT EXISTS schema_meta (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            )
        """)

        exec("INSERT OR IGNORE INTO schema_meta (key, value) VALUES ('version', '\(Self.schemaVersion)')")

        // Indexes for common queries
        exec("CREATE INDEX IF NOT EXISTS idx_feedback_timestamp ON feedback_events(timestamp)")
        exec("CREATE INDEX IF NOT EXISTS idx_feedback_kind ON feedback_events(kind)")
        exec("CREATE INDEX IF NOT EXISTS idx_feedback_dedupe ON feedback_events(dedupe_key)")
        exec("CREATE INDEX IF NOT EXISTS idx_training_kind ON training_rows(kind)")
        exec("CREATE INDEX IF NOT EXISTS idx_training_outcome ON training_rows(outcome_label)")
        exec("CREATE INDEX IF NOT EXISTS idx_pairwise_bucket ON pairwise_similarity(bucket)")
        exec("CREATE INDEX IF NOT EXISTS idx_features_screenshot ON photo_features(is_screenshot)")
    }

    // MARK: - Photo Features

    func upsertFeature(_ feature: PhotoFeatureRecord) throws {
        try ensureOpen()
        let sql = """
            INSERT INTO photo_features
                (asset_id, embedding, embedding_version, pixel_width, pixel_height,
                 creation_date, is_favorite, is_edited, is_screenshot, is_live_photo,
                 is_hdr, burst_identifier, aspect_ratio, file_size_bytes, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(asset_id) DO UPDATE SET
                embedding = excluded.embedding,
                embedding_version = excluded.embedding_version,
                pixel_width = excluded.pixel_width,
                pixel_height = excluded.pixel_height,
                creation_date = excluded.creation_date,
                is_favorite = excluded.is_favorite,
                is_edited = excluded.is_edited,
                is_screenshot = excluded.is_screenshot,
                is_live_photo = excluded.is_live_photo,
                is_hdr = excluded.is_hdr,
                burst_identifier = excluded.burst_identifier,
                aspect_ratio = excluded.aspect_ratio,
                file_size_bytes = excluded.file_size_bytes,
                updated_at = excluded.updated_at
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw sqlError()
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, feature.assetID, -1, SQLITE_TRANSIENT_PTR)
        if let embedding = feature.embedding {
            embedding.withUnsafeBytes { ptr in
                sqlite3_bind_blob(stmt, 2, ptr.baseAddress, Int32(ptr.count), SQLITE_TRANSIENT_PTR)
            }
        } else {
            sqlite3_bind_null(stmt, 2)
        }
        sqlite3_bind_int(stmt, 3, Int32(feature.embeddingVersion))
        sqlite3_bind_int(stmt, 4, Int32(feature.pixelWidth))
        sqlite3_bind_int(stmt, 5, Int32(feature.pixelHeight))
        if let date = feature.creationDate {
            sqlite3_bind_double(stmt, 6, date.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, 6)
        }
        sqlite3_bind_int(stmt, 7, feature.isFavorite ? 1 : 0)
        sqlite3_bind_int(stmt, 8, feature.isEdited ? 1 : 0)
        sqlite3_bind_int(stmt, 9, feature.isScreenshot ? 1 : 0)
        sqlite3_bind_int(stmt, 10, feature.isLivePhoto ? 1 : 0)
        sqlite3_bind_int(stmt, 11, feature.isHDR ? 1 : 0)
        bindOptionalText(stmt, 12, feature.burstIdentifier)
        sqlite3_bind_double(stmt, 13, feature.aspectRatio)
        sqlite3_bind_int64(stmt, 14, feature.fileSizeBytes)
        sqlite3_bind_double(stmt, 15, Date().timeIntervalSince1970)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw sqlError()
        }
    }

    func upsertFeatures(_ features: [PhotoFeatureRecord]) throws {
        try ensureOpen()
        exec("BEGIN TRANSACTION")
        do {
            for feature in features {
                try upsertFeature(feature)
            }
            exec("COMMIT")
        } catch {
            exec("ROLLBACK")
            throw error
        }
    }

    func featureCount() throws -> Int {
        try ensureOpen()
        return try queryInt("SELECT COUNT(*) FROM photo_features")
    }

    func loadEmbedding(for assetID: String) throws -> Data? {
        try ensureOpen()
        let sql = "SELECT embedding FROM photo_features WHERE asset_id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw sqlError()
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, assetID, -1, SQLITE_TRANSIENT_PTR)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, 0))
        guard count > 0, let ptr = sqlite3_column_blob(stmt, 0) else { return nil }
        return Data(bytes: ptr, count: count)
    }

    func loadAllEmbeddings() throws -> [String: Data] {
        try ensureOpen()
        let sql = "SELECT asset_id, embedding FROM photo_features WHERE embedding IS NOT NULL"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw sqlError()
        }
        defer { sqlite3_finalize(stmt) }
        var result: [String: Data] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idPtr = sqlite3_column_text(stmt, 0) else { continue }
            let id = String(cString: idPtr)
            let count = Int(sqlite3_column_bytes(stmt, 1))
            guard count > 0, let ptr = sqlite3_column_blob(stmt, 1) else { continue }
            result[id] = Data(bytes: ptr, count: count)
        }
        return result
    }

    // MARK: - Pairwise Similarity Cache

    func upsertPairSimilarity(_ pair: PairSimilarityRecord) throws {
        try ensureOpen()
        let sql = """
            INSERT INTO pairwise_similarity
                (lhs_asset_id, rhs_asset_id, feature_distance, time_delta_seconds,
                 is_burst_pair, bucket, similarity_score, computed_at)
            VALUES (?,?,?,?,?,?,?,?)
            ON CONFLICT(lhs_asset_id, rhs_asset_id) DO UPDATE SET
                feature_distance = excluded.feature_distance,
                time_delta_seconds = excluded.time_delta_seconds,
                is_burst_pair = excluded.is_burst_pair,
                bucket = excluded.bucket,
                similarity_score = excluded.similarity_score,
                computed_at = excluded.computed_at
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw sqlError()
        }
        defer { sqlite3_finalize(stmt) }

        let (lhs, rhs) = pair.lhsAssetID <= pair.rhsAssetID
            ? (pair.lhsAssetID, pair.rhsAssetID)
            : (pair.rhsAssetID, pair.lhsAssetID)

        sqlite3_bind_text(stmt, 1, lhs, -1, SQLITE_TRANSIENT_PTR)
        sqlite3_bind_text(stmt, 2, rhs, -1, SQLITE_TRANSIENT_PTR)
        sqlite3_bind_double(stmt, 3, pair.featureDistance)
        if let delta = pair.timeDeltaSeconds {
            sqlite3_bind_double(stmt, 4, delta)
        } else {
            sqlite3_bind_null(stmt, 4)
        }
        sqlite3_bind_int(stmt, 5, pair.isBurstPair ? 1 : 0)
        sqlite3_bind_text(stmt, 6, pair.bucket, -1, SQLITE_TRANSIENT_PTR)
        sqlite3_bind_double(stmt, 7, pair.similarityScore)
        sqlite3_bind_double(stmt, 8, Date().timeIntervalSince1970)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw sqlError()
        }
    }

    func pairSimilarityCount() throws -> Int {
        try ensureOpen()
        return try queryInt("SELECT COUNT(*) FROM pairwise_similarity")
    }

    // MARK: - Feedback Events

    func insertFeedbackEvent(_ event: FeedbackEventRecord) throws {
        try ensureOpen()
        let sql = """
            INSERT OR IGNORE INTO feedback_events
                (id, timestamp, source, kind, stage, dedupe_key, group_id, group_type,
                 bucket, confidence, suggested_action, suggested_keeper_id, final_keeper_id,
                 deleted_ids, kept_ids, skipped, recommendation_accepted,
                 policy_version, model_version, feature_schema_version, note)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw sqlError()
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, event.id, -1, SQLITE_TRANSIENT_PTR)
        sqlite3_bind_double(stmt, 2, event.timestamp)
        sqlite3_bind_text(stmt, 3, event.source, -1, SQLITE_TRANSIENT_PTR)
        sqlite3_bind_text(stmt, 4, event.kind, -1, SQLITE_TRANSIENT_PTR)
        sqlite3_bind_text(stmt, 5, event.stage, -1, SQLITE_TRANSIENT_PTR)
        sqlite3_bind_text(stmt, 6, event.dedupeKey, -1, SQLITE_TRANSIENT_PTR)
        bindOptionalText(stmt, 7, event.groupID)
        bindOptionalText(stmt, 8, event.groupType)
        bindOptionalText(stmt, 9, event.bucket)
        bindOptionalText(stmt, 10, event.confidence)
        bindOptionalText(stmt, 11, event.suggestedAction)
        bindOptionalText(stmt, 12, event.suggestedKeeperID)
        bindOptionalText(stmt, 13, event.finalKeeperID)
        sqlite3_bind_text(stmt, 14, event.deletedIDs, -1, SQLITE_TRANSIENT_PTR)
        sqlite3_bind_text(stmt, 15, event.keptIDs, -1, SQLITE_TRANSIENT_PTR)
        sqlite3_bind_int(stmt, 16, event.skipped ? 1 : 0)
        if let accepted = event.recommendationAccepted {
            sqlite3_bind_int(stmt, 17, accepted ? 1 : 0)
        } else {
            sqlite3_bind_null(stmt, 17)
        }
        sqlite3_bind_int(stmt, 18, Int32(event.policyVersion))
        sqlite3_bind_int(stmt, 19, Int32(event.modelVersion))
        sqlite3_bind_int(stmt, 20, Int32(event.featureSchemaVersion))
        bindOptionalText(stmt, 21, event.note)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw sqlError()
        }
    }

    func feedbackEventCount() throws -> Int {
        try ensureOpen()
        return try queryInt("SELECT COUNT(*) FROM feedback_events")
    }

    // MARK: - Training Rows

    func insertTrainingRow(_ row: TrainingRowRecord) throws {
        try ensureOpen()
        let sql = """
            INSERT OR IGNORE INTO training_rows
                (id, event_id, kind, timestamp, stage, group_id, asset_id, asset_role,
                 outcome_label, bucket, group_type, confidence, suggested_action,
                 recommendation_accepted, keeper_asset_id, ranking_score, similarity_to_keeper,
                 policy_version, model_version, feature_schema_version,
                 feature_pixel_width, feature_pixel_height, feature_is_favorite,
                 feature_is_edited, feature_is_screenshot, feature_burst_present,
                 feature_ranking_score, feature_similarity_to_keeper)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw sqlError()
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, row.id, -1, SQLITE_TRANSIENT_PTR)
        sqlite3_bind_text(stmt, 2, row.eventID, -1, SQLITE_TRANSIENT_PTR)
        sqlite3_bind_text(stmt, 3, row.kind, -1, SQLITE_TRANSIENT_PTR)
        sqlite3_bind_double(stmt, 4, row.timestamp)
        sqlite3_bind_text(stmt, 5, row.stage, -1, SQLITE_TRANSIENT_PTR)
        bindOptionalText(stmt, 6, row.groupID)
        bindOptionalText(stmt, 7, row.assetID)
        sqlite3_bind_text(stmt, 8, row.assetRole, -1, SQLITE_TRANSIENT_PTR)
        sqlite3_bind_text(stmt, 9, row.outcomeLabel, -1, SQLITE_TRANSIENT_PTR)
        bindOptionalText(stmt, 10, row.bucket)
        bindOptionalText(stmt, 11, row.groupType)
        bindOptionalText(stmt, 12, row.confidence)
        bindOptionalText(stmt, 13, row.suggestedAction)
        if let accepted = row.recommendationAccepted {
            sqlite3_bind_int(stmt, 14, accepted ? 1 : 0)
        } else {
            sqlite3_bind_null(stmt, 14)
        }
        bindOptionalText(stmt, 15, row.keeperAssetID)
        bindOptionalDouble(stmt, 16, row.rankingScore)
        bindOptionalDouble(stmt, 17, row.similarityToKeeper)
        sqlite3_bind_int(stmt, 18, Int32(row.policyVersion))
        sqlite3_bind_int(stmt, 19, Int32(row.modelVersion))
        sqlite3_bind_int(stmt, 20, Int32(row.featureSchemaVersion))
        bindOptionalInt(stmt, 21, row.featurePixelWidth)
        bindOptionalInt(stmt, 22, row.featurePixelHeight)
        bindOptionalBool(stmt, 23, row.featureIsFavorite)
        bindOptionalBool(stmt, 24, row.featureIsEdited)
        sqlite3_bind_int(stmt, 25, row.featureIsScreenshot ? 1 : 0)
        sqlite3_bind_int(stmt, 26, row.featureBurstPresent ? 1 : 0)
        bindOptionalDouble(stmt, 27, row.featureRankingScore)
        bindOptionalDouble(stmt, 28, row.featureSimilarityToKeeper)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw sqlError()
        }
    }

    func insertTrainingRows(_ rows: [TrainingRowRecord]) throws {
        try ensureOpen()
        exec("BEGIN TRANSACTION")
        do {
            for row in rows {
                try insertTrainingRow(row)
            }
            exec("COMMIT")
        } catch {
            exec("ROLLBACK")
            throw error
        }
    }

    func trainingRowCount() throws -> Int {
        try ensureOpen()
        return try queryInt("SELECT COUNT(*) FROM training_rows")
    }

    func trainingRowCount(kind: String) throws -> Int {
        try ensureOpen()
        let sql = "SELECT COUNT(*) FROM training_rows WHERE kind = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw sqlError()
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, kind, -1, SQLITE_TRANSIENT_PTR)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    // MARK: - Export for CreateML

    func exportKeeperTrainingCSV() throws -> String {
        try ensureOpen()
        let sql = """
            SELECT
                tr.outcome_label,
                tr.bucket,
                tr.group_type,
                tr.confidence,
                tr.suggested_action,
                COALESCE(tr.recommendation_accepted, -1),
                tr.feature_pixel_width,
                tr.feature_pixel_height,
                tr.feature_is_favorite,
                tr.feature_is_edited,
                tr.feature_is_screenshot,
                tr.feature_burst_present,
                tr.feature_ranking_score,
                tr.feature_similarity_to_keeper,
                pf.aspect_ratio,
                pf.file_size_bytes
            FROM training_rows tr
            LEFT JOIN photo_features pf ON tr.asset_id = pf.asset_id
            WHERE tr.kind = 'keeperRanking' AND tr.stage = 'committed'
            ORDER BY tr.timestamp
        """
        return try exportCSV(sql: sql, headers: [
            "outcome_label", "bucket", "group_type", "confidence", "suggested_action",
            "recommendation_accepted", "pixel_width", "pixel_height", "is_favorite",
            "is_edited", "is_screenshot", "burst_present", "ranking_score",
            "similarity_to_keeper", "aspect_ratio", "file_size_bytes"
        ])
    }

    func exportGroupOutcomeCSV() throws -> String {
        try ensureOpen()
        let sql = """
            SELECT
                tr.outcome_label,
                tr.bucket,
                tr.group_type,
                tr.confidence,
                tr.suggested_action,
                COALESCE(tr.recommendation_accepted, -1),
                (SELECT COUNT(*) FROM feedback_assets fa WHERE fa.event_id = tr.event_id) as asset_count,
                (SELECT AVG(fa.ranking_score) FROM feedback_assets fa WHERE fa.event_id = tr.event_id) as avg_ranking,
                (SELECT COUNT(CASE WHEN fa.is_screenshot = 1 THEN 1 END) FROM feedback_assets fa WHERE fa.event_id = tr.event_id) as screenshot_count,
                (SELECT COUNT(CASE WHEN fa.is_favorite = 1 THEN 1 END) FROM feedback_assets fa WHERE fa.event_id = tr.event_id) as favorite_count,
                (SELECT COUNT(CASE WHEN fa.is_edited = 1 THEN 1 END) FROM feedback_assets fa WHERE fa.event_id = tr.event_id) as edited_count
            FROM training_rows tr
            WHERE tr.kind = 'groupOutcome' AND tr.stage = 'committed'
            ORDER BY tr.timestamp
        """
        return try exportCSV(sql: sql, headers: [
            "outcome_label", "bucket", "group_type", "confidence", "suggested_action",
            "recommendation_accepted", "asset_count", "avg_ranking", "screenshot_count",
            "favorite_count", "edited_count"
        ])
    }

    // MARK: - Stats

    func databaseSizeBytes() throws -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: dbPath)
        return (attrs?[.size] as? Int64) ?? 0
    }

    func stats() throws -> MLStoreStats {
        try ensureOpen()
        return MLStoreStats(
            featureCount: try featureCount(),
            embeddingCount: try queryInt("SELECT COUNT(*) FROM photo_features WHERE embedding IS NOT NULL"),
            pairCount: try pairSimilarityCount(),
            feedbackEventCount: try feedbackEventCount(),
            trainingRowCount: try trainingRowCount(),
            keeperRowCount: try trainingRowCount(kind: "keeperRanking"),
            groupOutcomeRowCount: try trainingRowCount(kind: "groupOutcome"),
            databaseSizeBytes: try databaseSizeBytes()
        )
    }

    // MARK: - Maintenance

    func vacuum() throws {
        try ensureOpen()
        exec("VACUUM")
    }

    func deleteOldFeatures(olderThan date: Date) throws -> Int {
        try ensureOpen()
        let sql = "DELETE FROM photo_features WHERE updated_at < ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw sqlError()
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, date.timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw sqlError() }
        return Int(sqlite3_changes(db))
    }

    func deleteAllData() throws {
        try ensureOpen()
        exec("DELETE FROM training_rows")
        exec("DELETE FROM feedback_assets")
        exec("DELETE FROM feedback_events")
        exec("DELETE FROM pairwise_similarity")
        exec("DELETE FROM photo_features")
    }

    // MARK: - Helpers

    private func ensureOpen() throws {
        if !isOpen { try open() }
    }

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func execOrThrow(_ sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errMsg) == SQLITE_OK else {
            let msg = errMsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errMsg)
            throw MLStoreError.sqlError(msg)
        }
    }

    private func queryInt(_ sql: String) throws -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw sqlError()
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    private func exportCSV(sql: String, headers: [String]) throws -> String {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw sqlError()
        }
        defer { sqlite3_finalize(stmt) }

        var lines: [String] = [headers.joined(separator: ",")]
        let columnCount = Int(sqlite3_column_count(stmt))

        while sqlite3_step(stmt) == SQLITE_ROW {
            var values: [String] = []
            for col in 0..<columnCount {
                let type = sqlite3_column_type(stmt, Int32(col))
                switch type {
                case SQLITE_NULL:
                    values.append("")
                case SQLITE_INTEGER:
                    values.append(String(sqlite3_column_int64(stmt, Int32(col))))
                case SQLITE_FLOAT:
                    values.append(String(sqlite3_column_double(stmt, Int32(col))))
                default:
                    if let text = sqlite3_column_text(stmt, Int32(col)) {
                        let str = String(cString: text)
                        if str.contains(",") || str.contains("\"") {
                            values.append("\"\(str.replacingOccurrences(of: "\"", with: "\"\""))\"")
                        } else {
                            values.append(str)
                        }
                    } else {
                        values.append("")
                    }
                }
            }
            lines.append(values.joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    private func sqlError() -> MLStoreError {
        let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "db not open"
        return .sqlError(msg)
    }

    private func bindOptionalText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT_PTR)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func bindOptionalDouble(_ stmt: OpaquePointer?, _ index: Int32, _ value: Double?) {
        if let value {
            sqlite3_bind_double(stmt, index, value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func bindOptionalInt(_ stmt: OpaquePointer?, _ index: Int32, _ value: Int?) {
        if let value {
            sqlite3_bind_int(stmt, index, Int32(value))
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func bindOptionalBool(_ stmt: OpaquePointer?, _ index: Int32, _ value: Bool?) {
        if let value {
            sqlite3_bind_int(stmt, index, value ? 1 : 0)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }
}

// MARK: - SQLITE_TRANSIENT workaround for Swift

private let SQLITE_TRANSIENT_PTR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Record Types

struct PhotoFeatureRecord: Sendable {
    let assetID: String
    let embedding: Data?
    let embeddingVersion: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let creationDate: Date?
    let isFavorite: Bool
    let isEdited: Bool
    let isScreenshot: Bool
    let isLivePhoto: Bool
    let isHDR: Bool
    let burstIdentifier: String?
    let aspectRatio: Double
    let fileSizeBytes: Int64
}

struct PairSimilarityRecord: Sendable {
    let lhsAssetID: String
    let rhsAssetID: String
    let featureDistance: Double
    let timeDeltaSeconds: Double?
    let isBurstPair: Bool
    let bucket: String
    let similarityScore: Double
}

struct FeedbackEventRecord: Sendable {
    let id: String
    let timestamp: Double
    let source: String
    let kind: String
    let stage: String
    let dedupeKey: String
    let groupID: String?
    let groupType: String?
    let bucket: String?
    let confidence: String?
    let suggestedAction: String?
    let suggestedKeeperID: String?
    let finalKeeperID: String?
    let deletedIDs: String // comma-separated
    let keptIDs: String    // comma-separated
    let skipped: Bool
    let recommendationAccepted: Bool?
    let policyVersion: Int
    let modelVersion: Int
    let featureSchemaVersion: Int
    let note: String?
}

struct TrainingRowRecord: Sendable {
    let id: String
    let eventID: String
    let kind: String
    let timestamp: Double
    let stage: String
    let groupID: String?
    let assetID: String?
    let assetRole: String
    let outcomeLabel: String
    let bucket: String?
    let groupType: String?
    let confidence: String?
    let suggestedAction: String?
    let recommendationAccepted: Bool?
    let keeperAssetID: String?
    let rankingScore: Double?
    let similarityToKeeper: Double?
    let policyVersion: Int
    let modelVersion: Int
    let featureSchemaVersion: Int
    let featurePixelWidth: Int?
    let featurePixelHeight: Int?
    let featureIsFavorite: Bool?
    let featureIsEdited: Bool?
    let featureIsScreenshot: Bool
    let featureBurstPresent: Bool
    let featureRankingScore: Double?
    let featureSimilarityToKeeper: Double?
}

struct MLStoreStats: Sendable {
    let featureCount: Int
    let embeddingCount: Int
    let pairCount: Int
    let feedbackEventCount: Int
    let trainingRowCount: Int
    let keeperRowCount: Int
    let groupOutcomeRowCount: Int
    let databaseSizeBytes: Int64

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: databaseSizeBytes, countStyle: .file)
    }
}

enum MLStoreError: Error, LocalizedError {
    case cannotOpen(String)
    case sqlError(String)

    var errorDescription: String? {
        switch self {
        case .cannotOpen(let msg): return "Cannot open ML store: \(msg)"
        case .sqlError(let msg): return "ML store SQL error: \(msg)"
        }
    }
}
