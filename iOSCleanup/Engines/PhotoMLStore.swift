import Foundation
import SQLite3

enum PhotoEmbeddingContract {
    // This is an app-owned storage/metric version, not the Vision request
    // revision. Version 1 incorrectly assumed 128 elements and stored raw
    // distances. Version 2 uses Vision revision 1's actual 2,048 elements and
    // normalized RMS distances, so old pair rows cannot cross the scale change.
    static let pinnedVisionRevision = 1
    static let legacyEmbeddingVersion = 1
    static let embeddingVersion = 2
    static let legacyElementCount = 128
    static let elementCount = 2_048
    static let byteCount = elementCount * MemoryLayout<Float>.size

    static func expectedByteCount(for version: Int) -> Int? {
        switch version {
        case legacyEmbeddingVersion:
            return legacyElementCount * MemoryLayout<Float>.size
        case embeddingVersion:
            return byteCount
        default:
            return nil
        }
    }

    static func isCompatibleObservation(
        elementCount: Int,
        byteCount: Int
    ) -> Bool {
        elementCount == Self.elementCount && byteCount == Self.byteCount
    }
}

enum MLStoreRetentionPolicy {
    static let maximumTrainingRows = 50_000
    static let maximumPairRows = 250_000
}

struct MLStoreRetentionResult: Sendable, Equatable {
    let deletedTrainingRows: Int
    let deletedPairRows: Int
    let deletedFeatureRows: Int
}

private final class SQLiteConnection: @unchecked Sendable {
    var handle: OpaquePointer?

    deinit {
        if let handle {
            sqlite3_close(handle)
        }
    }
}

// MARK: - PhotoMLStore
// SQLite-backed feature store for ML training data.
// Stores Vision embeddings, feedback events, and pre-built training rows.
// Designed for on-device collection + Mac-side export for CreateML training.

actor PhotoMLStore {
    static let shared = PhotoMLStore()

    // Schema history (the marker in `schema_meta` is authoritative and is read
    // on every open):
    // - v4: versioned `pairwise_similarity` primary key and
    //   `training_rows.active_choice`.
    // - v5: `photo_asset_analysis` stopped storing its own copy of the 8 KB
    //   embedding blob; the warm-scan cache joins `photo_features` instead.
    static let schemaVersion = 5

    // Files already stamped at or above this version have the rebuilt pairwise
    // table and the `active_choice` column, so the expensive column-sniffing
    // migrations can be skipped entirely on open.
    private static let columnSniffedMigrationVersion = 4

    static let embeddingDimension = PhotoEmbeddingContract.elementCount
    static let keeperTrainingCSVHeaders = KeeperFeatureSchema.exportHeaders
    static let groupOutcomeCSVHeaders = GroupActionFeatureSchema.exportHeaders

    private let connection = SQLiteConnection()
    private let dbDirectoryURL: URL
    private let dbPath: String
    private var isOpen = false

    private var db: OpaquePointer? {
        connection.handle
    }

    init(directoryURL: URL? = nil) {
        let baseURL = directoryURL
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = baseURL.appendingPathComponent("PhotoDuck/ml", isDirectory: true)
        dbDirectoryURL = directory
        dbPath = directory.appendingPathComponent("photoduck-ml.sqlite").path
    }

    // MARK: - Open / Migrate

    func open() throws {
        guard !isOpen else { return }
        try FileManager.default.createDirectory(
            at: dbDirectoryURL,
            withIntermediateDirectories: true
        )

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(dbPath, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) }
                ?? "SQLite did not return a database handle"
            if let handle {
                sqlite3_close(handle)
            }
            throw MLStoreError.cannotOpen(message)
        }
        connection.handle = handle
        isOpen = true

        do {
            // WAL mode allows scan writes and cache reads without blocking each other.
            try execOrThrow("PRAGMA journal_mode = WAL")
            try execOrThrow("PRAGMA synchronous = NORMAL")
            try execOrThrow("PRAGMA foreign_keys = ON")
            try migrateSchema()
        } catch {
            sqlite3_close(handle)
            connection.handle = nil
            isOpen = false
            throw error
        }
    }

    /// Reads the persisted schema marker and uses it to decide what work this
    /// open has to do. The marker is the only signal that can tell us a file was
    /// written by a *newer* build, which column sniffing can never detect.
    private func migrateSchema() throws {
        try execOrThrow("""
            CREATE TABLE IF NOT EXISTS schema_meta (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            )
        """)

        let storedVersion = try loadSchemaVersion()
        if let storedVersion, storedVersion > Self.schemaVersion {
            // A newer build owns this file and may have rewritten tables this
            // build cannot read. Refuse to open rather than running older
            // migrations over it, and leave the marker alone so the newer build
            // still recognizes its own schema.
            throw MLStoreError.schemaVersionTooNew(
                found: storedVersion,
                supported: Self.schemaVersion
            )
        }

        try createTables()
        if storedVersion != Self.schemaVersion {
            try runMigrations(fromStoredVersion: storedVersion)
            try writeSchemaVersion(Self.schemaVersion)
        }
        try createIndexes()
    }

    private func runMigrations(fromStoredVersion storedVersion: Int?) throws {
        if (storedVersion ?? 0) < Self.columnSniffedMigrationVersion {
            try migratePairwiseSimilarityTableIfNeeded()
            try migrateTrainingRowsTableIfNeeded()
        }
        // Column sniffed rather than version gated: files written before the
        // marker was trusted can still carry the duplicated blob column.
        try dropDuplicatedAnalysisEmbeddingsIfNeeded()
    }

    private func loadSchemaVersion() throws -> Int? {
        var stmt: OpaquePointer?
        let sql = "SELECT value FROM schema_meta WHERE key = 'version'"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw sqlError()
        }
        defer { sqlite3_finalize(stmt) }
        let stepResult = sqlite3_step(stmt)
        if stepResult == SQLITE_DONE { return nil }
        guard stepResult == SQLITE_ROW else { throw sqlError() }
        guard let value = sqlite3_column_text(stmt, 0) else { return nil }
        return Int(String(cString: value))
    }

    /// The schema version this database file is stamped with, or `nil` for a
    /// file that predates the marker.
    func storedSchemaVersion() throws -> Int? {
        try ensureOpen()
        return try loadSchemaVersion()
    }

    private func writeSchemaVersion(_ version: Int) throws {
        try execOrThrow("""
            INSERT INTO schema_meta (key, value) VALUES ('version', '\(version)')
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
        """)
    }

    /// v4 and earlier stored a second copy of every 8 KB embedding in
    /// `photo_asset_analysis`. The column is dropped from the write path; null
    /// out anything already written so the space returns to the free list (and
    /// to the file on the next `VACUUM`). The column itself is left in place:
    /// `ALTER TABLE ... DROP COLUMN` is not available on every deployed SQLite
    /// build, and an unreferenced nulled column is inert.
    private func dropDuplicatedAnalysisEmbeddingsIfNeeded() throws {
        let columns = try tableColumnInfo("photo_asset_analysis")
        guard columns.contains(where: { $0.name == "embedding" }) else { return }
        try execOrThrow(
            "UPDATE photo_asset_analysis SET embedding = NULL WHERE embedding IS NOT NULL"
        )
    }

    private func createTables() throws {
        // Feature embeddings per photo asset
        try execOrThrow("""
            CREATE TABLE IF NOT EXISTS photo_features (
                asset_id TEXT PRIMARY KEY,
                embedding BLOB,
                embedding_version INT NOT NULL DEFAULT \(PhotoEmbeddingContract.embeddingVersion),
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

        // Versioned scan evidence used only to avoid re-decoding unchanged
        // bounded context assets during incremental/resumed scans.
        //
        // Deliberately holds no embedding blob of its own (schema v5). Storing
        // one here duplicated the 8 KB `photo_features.embedding` per asset and
        // doubled the documented storage budget. Joining `photo_features` was
        // chosen over capping this table's row count because it is the safer
        // option for the warm-scan cache path: a cache hit is only useful if
        // the derived pair rows can also be persisted, and
        // `validatePairEmbeddingVersions` requires a matching
        // `photo_features.embedding`. Joining makes the cache-hit condition and
        // the pair-write precondition identical, so this cache can never hand
        // back an embedding whose pair batch would then abort with
        // `missingEmbedding`. A row-count cap would have left both the
        // duplicate blob and that divergence in place.
        try execOrThrow("""
            CREATE TABLE IF NOT EXISTS photo_asset_analysis (
                asset_id TEXT PRIMARY KEY,
                modification_date REAL,
                modification_date_is_null INT NOT NULL DEFAULT 0,
                pixel_width INT NOT NULL,
                pixel_height INT NOT NULL,
                media_subtypes_raw INT NOT NULL,
                analyzer_version INT NOT NULL,
                embedding_version INT NOT NULL,
                perceptual_hash_hex TEXT,
                keeper_signals_json BLOB,
                updated_at REAL NOT NULL
            )
        """)

        // Pairwise similarity cache
        try execOrThrow("""
            CREATE TABLE IF NOT EXISTS pairwise_similarity (
                lhs_asset_id TEXT NOT NULL,
                rhs_asset_id TEXT NOT NULL,
                embedding_version INT NOT NULL,
                feature_distance REAL NOT NULL,
                time_delta_seconds REAL,
                is_burst_pair INT NOT NULL DEFAULT 0,
                bucket TEXT NOT NULL,
                similarity_score REAL NOT NULL,
                computed_at REAL NOT NULL,
                PRIMARY KEY (lhs_asset_id, rhs_asset_id, embedding_version)
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
                active_choice INT NOT NULL DEFAULT 0,
                FOREIGN KEY (event_id) REFERENCES feedback_events(id) ON DELETE CASCADE
            )
        """)
    }

    private func createIndexes() throws {
        // Indexes for common queries
        try execOrThrow("CREATE INDEX IF NOT EXISTS idx_feedback_timestamp ON feedback_events(timestamp)")
        try execOrThrow("CREATE INDEX IF NOT EXISTS idx_feedback_kind ON feedback_events(kind)")
        try execOrThrow("CREATE INDEX IF NOT EXISTS idx_feedback_dedupe ON feedback_events(dedupe_key)")
        try execOrThrow("CREATE INDEX IF NOT EXISTS idx_training_kind ON training_rows(kind)")
        try execOrThrow("CREATE INDEX IF NOT EXISTS idx_training_outcome ON training_rows(outcome_label)")
        try execOrThrow("CREATE INDEX IF NOT EXISTS idx_pairwise_bucket ON pairwise_similarity(bucket)")
        try execOrThrow("CREATE INDEX IF NOT EXISTS idx_pairwise_computed ON pairwise_similarity(computed_at)")
        try execOrThrow("CREATE INDEX IF NOT EXISTS idx_features_screenshot ON photo_features(is_screenshot)")
        try execOrThrow(
            "CREATE INDEX IF NOT EXISTS idx_asset_analysis_updated ON photo_asset_analysis(updated_at)"
        )
    }

    // MARK: - Photo Features

    func upsertFeature(_ feature: PhotoFeatureRecord) throws {
        // Single-record callers still get a hard error for a malformed
        // embedding; only batch writes degrade to skip-and-count.
        try validateEmbedding(feature.embedding, version: feature.embeddingVersion)
        try upsertFeatures([feature])
    }

    /// Upserts a batch and returns how many records were skipped because their
    /// embedding failed the version/byte-count contract. Validation runs before
    /// `BEGIN`, so one malformed record can never roll back the (up to 95)
    /// valid rows sharing its flush batch.
    @discardableResult
    func upsertFeatures(_ features: [PhotoFeatureRecord]) throws -> Int {
        try ensureOpen()
        guard !features.isEmpty else { return 0 }
        var validFeatures: [PhotoFeatureRecord] = []
        validFeatures.reserveCapacity(features.count)
        var skippedCount = 0
        for feature in features {
            do {
                try validateEmbedding(
                    feature.embedding,
                    version: feature.embeddingVersion
                )
                validFeatures.append(feature)
            } catch {
                skippedCount += 1
            }
        }
        guard !validFeatures.isEmpty else { return skippedCount }

        let sql = """
            INSERT INTO photo_features
                (asset_id, embedding, embedding_version, pixel_width, pixel_height,
                 creation_date, is_favorite, is_edited, is_screenshot, is_live_photo,
                 is_hdr, burst_identifier, aspect_ratio, file_size_bytes, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(asset_id) DO UPDATE SET
                embedding = COALESCE(excluded.embedding, photo_features.embedding),
                embedding_version = CASE
                    WHEN excluded.embedding IS NULL THEN photo_features.embedding_version
                    ELSE excluded.embedding_version
                END,
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
        try execOrThrow("BEGIN TRANSACTION")
        do {
            for feature in validFeatures {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                sqlite3_bind_text(stmt, 1, feature.assetID, -1, SQLITE_TRANSIENT_PTR)
                if let embedding = feature.embedding {
                    _ = embedding.withUnsafeBytes { ptr in
                        sqlite3_bind_blob(
                            stmt,
                            2,
                            ptr.baseAddress,
                            Int32(ptr.count),
                            SQLITE_TRANSIENT_PTR
                        )
                    }
                } else {
                    sqlite3_bind_null(stmt, 2)
                }
                sqlite3_bind_int(stmt, 3, Int32(feature.embeddingVersion))
                sqlite3_bind_int(stmt, 4, Int32(feature.pixelWidth))
                sqlite3_bind_int(stmt, 5, Int32(feature.pixelHeight))
                bindOptionalDouble(
                    stmt,
                    6,
                    feature.creationDate?.timeIntervalSince1970
                )
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
            try execOrThrow("COMMIT")
        } catch {
            rollbackIgnoringSecondaryFailure()
            throw error
        }
        return skippedCount
    }

    func featureCount() throws -> Int {
        try ensureOpen()
        return try queryInt("SELECT COUNT(*) FROM photo_features")
    }

    func loadEmbedding(for assetID: String) throws -> Data? {
        try ensureOpen()
        let sql = """
            SELECT embedding, embedding_version
            FROM photo_features
            WHERE asset_id = ?
        """
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
        let data = Data(bytes: ptr, count: count)
        let version = Int(sqlite3_column_int(stmt, 1))
        try validateEmbedding(data, version: version)
        return data
    }

    func loadAllEmbeddings(
        embeddingVersion: Int = PhotoEmbeddingContract.embeddingVersion
    ) throws -> [String: Data] {
        try ensureOpen()
        guard PhotoEmbeddingContract.expectedByteCount(for: embeddingVersion) != nil else {
            throw MLStoreError.unsupportedEmbeddingVersion(embeddingVersion)
        }
        let sql = """
            SELECT asset_id, embedding
            FROM photo_features
            WHERE embedding IS NOT NULL AND embedding_version = ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw sqlError()
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(embeddingVersion))
        var result: [String: Data] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idPtr = sqlite3_column_text(stmt, 0) else { continue }
            let id = String(cString: idPtr)
            let count = Int(sqlite3_column_bytes(stmt, 1))
            guard count > 0, let ptr = sqlite3_column_blob(stmt, 1) else { continue }
            let data = Data(bytes: ptr, count: count)
            try validateEmbedding(data, version: embeddingVersion)
            result[id] = data
        }
        return result
    }

    // MARK: - Versioned asset analysis cache

    /// Upserts warm-scan cache rows and returns how many were skipped because
    /// the analyzed embedding failed its version/byte-count contract. The
    /// embedding blob itself is not stored here; reads join `photo_features`.
    /// Validation runs before `BEGIN` so one malformed record cannot roll back
    /// the valid rows sharing its flush batch.
    @discardableResult
    func upsertAssetAnalyses(
        _ records: [PhotoAssetAnalysisCacheRecord]
    ) throws -> Int {
        try ensureOpen()
        guard !records.isEmpty else { return 0 }
        var validRecords: [PhotoAssetAnalysisCacheRecord] = []
        validRecords.reserveCapacity(records.count)
        var skippedCount = 0
        for record in records {
            do {
                try validateEmbedding(
                    record.embedding,
                    version: record.embeddingVersion
                )
                validRecords.append(record)
            } catch {
                skippedCount += 1
            }
        }
        guard !validRecords.isEmpty else { return skippedCount }

        let sql = """
            INSERT INTO photo_asset_analysis
                (asset_id, modification_date, modification_date_is_null,
                 pixel_width, pixel_height, media_subtypes_raw,
                 analyzer_version, embedding_version,
                 perceptual_hash_hex, keeper_signals_json, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(asset_id) DO UPDATE SET
                modification_date = excluded.modification_date,
                modification_date_is_null = excluded.modification_date_is_null,
                pixel_width = excluded.pixel_width,
                pixel_height = excluded.pixel_height,
                media_subtypes_raw = excluded.media_subtypes_raw,
                analyzer_version = excluded.analyzer_version,
                embedding_version = excluded.embedding_version,
                perceptual_hash_hex = excluded.perceptual_hash_hex,
                keeper_signals_json = excluded.keeper_signals_json,
                updated_at = excluded.updated_at
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw sqlError()
        }
        defer { sqlite3_finalize(statement) }

        try execOrThrow("BEGIN TRANSACTION")
        do {
            for record in validRecords {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                sqlite3_bind_text(
                    statement,
                    1,
                    record.assetID,
                    -1,
                    SQLITE_TRANSIENT_PTR
                )
                bindOptionalDouble(
                    statement,
                    2,
                    record.modificationDate?.timeIntervalSince1970
                )
                sqlite3_bind_int(
                    statement,
                    3,
                    record.modificationDate == nil ? 1 : 0
                )
                sqlite3_bind_int(statement, 4, Int32(record.pixelWidth))
                sqlite3_bind_int(statement, 5, Int32(record.pixelHeight))
                sqlite3_bind_int64(
                    statement,
                    6,
                    Int64(bitPattern: record.mediaSubtypesRawValue)
                )
                sqlite3_bind_int(statement, 7, Int32(record.analyzerVersion))
                sqlite3_bind_int(statement, 8, Int32(record.embeddingVersion))
                bindOptionalText(
                    statement,
                    9,
                    record.perceptualHash.map {
                        String($0, radix: 16, uppercase: false)
                    }
                )
                if let keeperSignalsJSON = record.keeperSignalsJSON {
                    _ = keeperSignalsJSON.withUnsafeBytes { bytes in
                        sqlite3_bind_blob(
                            statement,
                            10,
                            bytes.baseAddress,
                            Int32(bytes.count),
                            SQLITE_TRANSIENT_PTR
                        )
                    }
                } else {
                    sqlite3_bind_null(statement, 10)
                }
                sqlite3_bind_double(
                    statement,
                    11,
                    Date().timeIntervalSince1970
                )
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw sqlError()
                }
            }
            try execOrThrow("COMMIT")
        } catch {
            rollbackIgnoringSecondaryFailure()
            throw error
        }
        return skippedCount
    }

    func loadValidAssetAnalyses(
        for lookups: [PhotoAssetAnalysisCacheLookup]
    ) throws -> [String: PhotoAssetAnalysisCacheRecord] {
        try ensureOpen()
        guard !lookups.isEmpty else { return [:] }
        // The embedding comes from photo_features rather than a duplicated blob
        // in photo_asset_analysis (schema v5). The join conditions are exactly
        // the precondition validatePairEmbeddingVersions enforces on write, so a
        // cache hit always implies the pairs derived from it are persistable.
        let sql = """
            SELECT analysis.modification_date, analysis.modification_date_is_null,
                   analysis.pixel_width, analysis.pixel_height,
                   analysis.media_subtypes_raw, analysis.analyzer_version,
                   analysis.embedding_version, features.embedding,
                   analysis.perceptual_hash_hex, analysis.keeper_signals_json
            FROM photo_asset_analysis analysis
            JOIN photo_features features
                ON features.asset_id = analysis.asset_id
            WHERE analysis.asset_id = ?
              AND features.embedding IS NOT NULL
              AND features.embedding_version = analysis.embedding_version
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw sqlError()
        }
        defer { sqlite3_finalize(statement) }

        var result: [String: PhotoAssetAnalysisCacheRecord] = [:]
        result.reserveCapacity(lookups.count)
        for lookup in lookups {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_text(
                statement,
                1,
                lookup.assetID,
                -1,
                SQLITE_TRANSIENT_PTR
            )
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE { continue }
            guard stepResult == SQLITE_ROW else { throw sqlError() }

            let storedDateIsNil = sqlite3_column_int(statement, 1) != 0
            let storedDate = storedDateIsNil
                ? nil
                : Date(
                    timeIntervalSince1970: sqlite3_column_double(statement, 0)
                )
            guard storedDate == lookup.modificationDate,
                  Int(sqlite3_column_int(statement, 2)) == lookup.pixelWidth,
                  Int(sqlite3_column_int(statement, 3)) == lookup.pixelHeight,
                  UInt64(bitPattern: sqlite3_column_int64(statement, 4))
                    == lookup.mediaSubtypesRawValue,
                  Int(sqlite3_column_int(statement, 5)) == lookup.analyzerVersion,
                  Int(sqlite3_column_int(statement, 6)) == lookup.embeddingVersion,
                  sqlite3_column_type(statement, 7) != SQLITE_NULL,
                  let embeddingPointer = sqlite3_column_blob(statement, 7) else {
                continue
            }
            let embeddingByteCount = Int(sqlite3_column_bytes(statement, 7))
            let embedding = Data(
                bytes: embeddingPointer,
                count: embeddingByteCount
            )
            // A single unreadable blob must not abort the whole lookup loop:
            // throwing here made the caller discard every other context asset
            // and flag persistence unhealthy. Skip the row exactly like the
            // metadata mismatches above so it is simply re-analyzed.
            do {
                try validateEmbedding(
                    embedding,
                    version: lookup.embeddingVersion
                )
            } catch {
                continue
            }

            let hash: UInt64? = sqlite3_column_text(statement, 8)
                .flatMap { UInt64(String(cString: $0), radix: 16) }
            let keeperSignalsJSON: Data?
            if sqlite3_column_type(statement, 9) != SQLITE_NULL,
               let pointer = sqlite3_column_blob(statement, 9) {
                keeperSignalsJSON = Data(
                    bytes: pointer,
                    count: Int(sqlite3_column_bytes(statement, 9))
                )
            } else {
                keeperSignalsJSON = nil
            }
            result[lookup.assetID] = PhotoAssetAnalysisCacheRecord(
                assetID: lookup.assetID,
                modificationDate: storedDate,
                pixelWidth: lookup.pixelWidth,
                pixelHeight: lookup.pixelHeight,
                mediaSubtypesRawValue: lookup.mediaSubtypesRawValue,
                analyzerVersion: lookup.analyzerVersion,
                embeddingVersion: lookup.embeddingVersion,
                embedding: embedding,
                perceptualHash: hash,
                keeperSignalsJSON: keeperSignalsJSON
            )
        }
        return result
    }

    // MARK: - Pairwise Similarity Cache

    func upsertPairSimilarity(_ pair: PairSimilarityRecord) throws {
        try ensureOpen()
        // Single-pair callers still get a hard error; only batch writes degrade
        // to skip-and-count.
        try validatePairEmbeddingVersions(pair)
        try upsertPairSimilarities([pair])
    }

    /// Upserts a batch and returns how many pairs were skipped because their
    /// backing embeddings were missing or version-mismatched. Validation runs
    /// before `BEGIN`, so one bad pair cannot roll back the (up to 383) valid
    /// rows sharing its flush batch.
    @discardableResult
    func upsertPairSimilarities(_ pairs: [PairSimilarityRecord]) throws -> Int {
        try ensureOpen()
        guard !pairs.isEmpty else { return 0 }
        var validPairs: [PairSimilarityRecord] = []
        validPairs.reserveCapacity(pairs.count)
        var skippedCount = 0
        for pair in pairs {
            do {
                try validatePairEmbeddingVersions(pair)
                validPairs.append(pair)
            } catch {
                skippedCount += 1
            }
        }
        guard !validPairs.isEmpty else { return skippedCount }

        let sql = """
            INSERT INTO pairwise_similarity
                (lhs_asset_id, rhs_asset_id, embedding_version, feature_distance, time_delta_seconds,
                 is_burst_pair, bucket, similarity_score, computed_at)
            VALUES (?,?,?,?,?,?,?,?,?)
            ON CONFLICT(lhs_asset_id, rhs_asset_id, embedding_version) DO UPDATE SET
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
        try execOrThrow("BEGIN TRANSACTION")
        do {
            for pair in validPairs {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                let (lhs, rhs) = pair.lhsAssetID <= pair.rhsAssetID
                    ? (pair.lhsAssetID, pair.rhsAssetID)
                    : (pair.rhsAssetID, pair.lhsAssetID)
                sqlite3_bind_text(stmt, 1, lhs, -1, SQLITE_TRANSIENT_PTR)
                sqlite3_bind_text(stmt, 2, rhs, -1, SQLITE_TRANSIENT_PTR)
                sqlite3_bind_int(stmt, 3, Int32(pair.embeddingVersion))
                sqlite3_bind_double(stmt, 4, pair.featureDistance)
                bindOptionalDouble(stmt, 5, pair.timeDeltaSeconds)
                sqlite3_bind_int(stmt, 6, pair.isBurstPair ? 1 : 0)
                sqlite3_bind_text(stmt, 7, pair.bucket, -1, SQLITE_TRANSIENT_PTR)
                sqlite3_bind_double(stmt, 8, pair.similarityScore)
                sqlite3_bind_double(stmt, 9, Date().timeIntervalSince1970)
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw sqlError()
                }
            }
            try execOrThrow("COMMIT")
        } catch {
            rollbackIgnoringSecondaryFailure()
            throw error
        }
        return skippedCount
    }

    func loadPairSimilarity(
        lhsAssetID: String,
        rhsAssetID: String,
        embeddingVersion: Int = PhotoEmbeddingContract.embeddingVersion
    ) throws -> PairSimilarityRecord? {
        let key = SimilarityPairKey(lhsAssetID, rhsAssetID)
        return try loadPairSimilarities(
            for: [key],
            embeddingVersion: embeddingVersion
        )[key]
    }

    func loadPairSimilarities(
        for keys: [SimilarityPairKey],
        embeddingVersion: Int = PhotoEmbeddingContract.embeddingVersion
    ) throws -> [SimilarityPairKey: PairSimilarityRecord] {
        try ensureOpen()
        guard PhotoEmbeddingContract.expectedByteCount(for: embeddingVersion) != nil else {
            throw MLStoreError.unsupportedEmbeddingVersion(embeddingVersion)
        }
        let sql = """
            SELECT
                cached_pair.feature_distance,
                cached_pair.time_delta_seconds,
                cached_pair.is_burst_pair,
                cached_pair.bucket,
                cached_pair.similarity_score
            FROM pairwise_similarity cached_pair
            JOIN photo_features lhs ON lhs.asset_id = cached_pair.lhs_asset_id
            JOIN photo_features rhs ON rhs.asset_id = cached_pair.rhs_asset_id
            WHERE cached_pair.lhs_asset_id = ?
              AND cached_pair.rhs_asset_id = ?
              AND cached_pair.embedding_version = ?
              AND lhs.embedding_version = cached_pair.embedding_version
              AND rhs.embedding_version = cached_pair.embedding_version
              AND lhs.embedding IS NOT NULL
              AND rhs.embedding IS NOT NULL
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw sqlError()
        }
        defer { sqlite3_finalize(stmt) }

        var result: [SimilarityPairKey: PairSimilarityRecord] = [:]
        result.reserveCapacity(keys.count)
        for key in Set(keys) {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            sqlite3_bind_text(stmt, 1, key.lhsID, -1, SQLITE_TRANSIENT_PTR)
            sqlite3_bind_text(stmt, 2, key.rhsID, -1, SQLITE_TRANSIENT_PTR)
            sqlite3_bind_int(stmt, 3, Int32(embeddingVersion))

            let stepResult = sqlite3_step(stmt)
            if stepResult == SQLITE_DONE {
                continue
            }
            guard stepResult == SQLITE_ROW else { throw sqlError() }
            let timeDelta: Double? = sqlite3_column_type(stmt, 1) == SQLITE_NULL
                ? nil
                : sqlite3_column_double(stmt, 1)
            let bucket = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            result[key] = PairSimilarityRecord(
                lhsAssetID: key.lhsID,
                rhsAssetID: key.rhsID,
                embeddingVersion: embeddingVersion,
                featureDistance: sqlite3_column_double(stmt, 0),
                timeDeltaSeconds: timeDelta,
                isBurstPair: sqlite3_column_int(stmt, 2) != 0,
                bucket: bucket,
                similarityScore: sqlite3_column_double(stmt, 4)
            )
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw sqlError() }
        }
        return result
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
                 feature_ranking_score, feature_similarity_to_keeper, active_choice)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
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
        sqlite3_bind_int(stmt, 29, row.activeChoice ? 1 : 0)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw sqlError()
        }
    }

    func insertTrainingRows(_ rows: [TrainingRowRecord]) throws {
        try ensureOpen()
        try execOrThrow("BEGIN TRANSACTION")
        do {
            for row in rows {
                try insertTrainingRow(row)
            }
            try execOrThrow("COMMIT")
        } catch {
            rollbackIgnoringSecondaryFailure()
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

    private static let keeperTrainingSQL = """
        SELECT
            tr.outcome_label,
            tr.event_id,
            tr.group_id,
            tr.feature_schema_version,
            tr.active_choice,
            tr.bucket,
            tr.group_type,
            tr.confidence,
            tr.suggested_action,
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

    private static let groupOutcomeSQL = """
        SELECT
            tr.outcome_label,
            tr.event_id,
            tr.group_id,
            tr.feature_schema_version,
            tr.bucket,
            tr.group_type,
            tr.confidence,
            tr.suggested_action,
            (SELECT COUNT(*) FROM feedback_assets fa WHERE fa.event_id = tr.event_id) as asset_count,
            (SELECT AVG(fa.ranking_score) FROM feedback_assets fa WHERE fa.event_id = tr.event_id) as avg_ranking,
            (SELECT COUNT(CASE WHEN fa.is_screenshot = 1 THEN 1 END) FROM feedback_assets fa WHERE fa.event_id = tr.event_id) as screenshot_count,
            (SELECT COUNT(CASE WHEN fa.is_favorite = 1 THEN 1 END) FROM feedback_assets fa WHERE fa.event_id = tr.event_id) as favorite_count,
            (SELECT COUNT(CASE WHEN fa.is_edited = 1 THEN 1 END) FROM feedback_assets fa WHERE fa.event_id = tr.event_id) as edited_count
        FROM training_rows tr
        WHERE tr.kind = 'groupOutcome' AND tr.stage = 'committed'
        ORDER BY tr.timestamp
    """

    func exportKeeperTrainingCSV() throws -> String {
        try ensureOpen()
        return try exportCSVToString(
            sql: Self.keeperTrainingSQL,
            headers: Self.keeperTrainingCSVHeaders
        )
    }

    func exportGroupOutcomeCSV() throws -> String {
        try ensureOpen()
        return try exportCSVToString(
            sql: Self.groupOutcomeSQL,
            headers: Self.groupOutcomeCSVHeaders
        )
    }

    func exportKeeperTrainingCSV(to destinationURL: URL) throws {
        try ensureOpen()
        try exportCSV(
            sql: Self.keeperTrainingSQL,
            headers: Self.keeperTrainingCSVHeaders,
            to: destinationURL
        )
    }

    func exportGroupOutcomeCSV(to destinationURL: URL) throws {
        try ensureOpen()
        try exportCSV(
            sql: Self.groupOutcomeSQL,
            headers: Self.groupOutcomeCSVHeaders,
            to: destinationURL
        )
    }

    // MARK: - Stats

    func databaseSizeBytes() throws -> Int64 {
        guard FileManager.default.fileExists(atPath: dbPath) else { return 0 }
        let attrs = try FileManager.default.attributesOfItem(atPath: dbPath)
        return (attrs[.size] as? NSNumber)?.int64Value ?? 0
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

    func checkpointWAL() throws {
        try ensureOpen()
        let sql = "PRAGMA wal_checkpoint(TRUNCATE)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw sqlError()
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw sqlError()
        }
        let busyConnections = Int(sqlite3_column_int(stmt, 0))
        guard busyConnections == 0 else {
            throw MLStoreError.walCheckpointBusy(busyConnections)
        }
    }

    func exportDatabase(to destinationURL: URL) throws {
        try ensureOpen()
        try checkpointWAL()
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let temporaryURL = destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: dbPath),
            to: temporaryURL
        )
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
    }

    @discardableResult
    func performRetention(
        activeAssetIDs: Set<String>? = nil,
        maximumTrainingRows: Int = MLStoreRetentionPolicy.maximumTrainingRows,
        maximumPairRows: Int = MLStoreRetentionPolicy.maximumPairRows,
        allowEmptyActiveLibrary: Bool = false,
        vacuumAfterward: Bool = false
    ) throws -> MLStoreRetentionResult {
        try ensureOpen()
        let deletedTrainingRows = try deleteRowsBeyondLimit(
            table: "training_rows",
            orderColumn: "timestamp",
            keepingNewest: maximumTrainingRows
        )
        let deletedPairRowsForLimit = try deleteRowsBeyondLimit(
            table: "pairwise_similarity",
            orderColumn: "computed_at",
            keepingNewest: maximumPairRows
        )

        var deletedFeatureRows = 0
        var deletedInactivePairRows = 0
        if let activeAssetIDs,
           !activeAssetIDs.isEmpty || allowEmptyActiveLibrary {
            let result = try deleteRecordsForInactiveAssets(activeAssetIDs)
            deletedFeatureRows = result.features
            deletedInactivePairRows = result.pairs
        }

        if vacuumAfterward {
            try vacuum()
        }
        return MLStoreRetentionResult(
            deletedTrainingRows: deletedTrainingRows,
            deletedPairRows: deletedPairRowsForLimit + deletedInactivePairRows,
            deletedFeatureRows: deletedFeatureRows
        )
    }

    func vacuum() throws {
        try ensureOpen()
        try execOrThrow("VACUUM")
    }

    /// Deletes aged feature rows and the warm-scan cache rows that depend on
    /// them, returning the number of deleted `photo_features` rows.
    ///
    /// The two tables must stay consistent: an orphaned `photo_asset_analysis`
    /// row keeps serving cache hits for an asset that no longer has an
    /// embedding, and every pair derived from it then fails
    /// `validatePairEmbeddingVersions` with `missingEmbedding` and rolls back
    /// its batch.
    @discardableResult
    func deleteOldFeatures(olderThan date: Date) throws -> Int {
        try ensureOpen()
        let sql = "DELETE FROM photo_features WHERE updated_at < ?"
        // Aged-out cache rows plus any orphan left behind by an earlier build.
        let analysisSQL = """
            DELETE FROM photo_asset_analysis
            WHERE updated_at < ?
               OR asset_id NOT IN (SELECT asset_id FROM photo_features)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw sqlError()
        }
        defer { sqlite3_finalize(stmt) }
        var analysisStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, analysisSQL, -1, &analysisStatement, nil) == SQLITE_OK else {
            throw sqlError()
        }
        defer { sqlite3_finalize(analysisStatement) }

        try execOrThrow("BEGIN TRANSACTION")
        do {
            sqlite3_bind_double(stmt, 1, date.timeIntervalSince1970)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw sqlError() }
            let deletedFeatureRows = Int(sqlite3_changes(db))

            sqlite3_bind_double(analysisStatement, 1, date.timeIntervalSince1970)
            guard sqlite3_step(analysisStatement) == SQLITE_DONE else { throw sqlError() }

            try execOrThrow("COMMIT")
            return deletedFeatureRows
        } catch {
            rollbackIgnoringSecondaryFailure()
            throw error
        }
    }

    func deleteAllData() throws {
        try ensureOpen()
        try execOrThrow("BEGIN TRANSACTION")
        do {
            try execOrThrow("DELETE FROM training_rows")
            try execOrThrow("DELETE FROM feedback_assets")
            try execOrThrow("DELETE FROM feedback_events")
            try execOrThrow("DELETE FROM pairwise_similarity")
            try execOrThrow("DELETE FROM photo_asset_analysis")
            try execOrThrow("DELETE FROM photo_features")
            try execOrThrow("COMMIT")
        } catch {
            rollbackIgnoringSecondaryFailure()
            throw error
        }
    }

    // MARK: - Helpers

    private func ensureOpen() throws {
        if !isOpen { try open() }
    }

    private func migratePairwiseSimilarityTableIfNeeded() throws {
        let columns = try tableColumnInfo("pairwise_similarity")
        let hasVersionedPrimaryKey = columns.contains {
            $0.name == "embedding_version" && $0.primaryKeyPosition > 0
        }
        guard !hasVersionedPrimaryKey else { return }

        let legacyHasVersion = columns.contains { $0.name == "embedding_version" }
        try execOrThrow("BEGIN IMMEDIATE TRANSACTION")
        do {
            try execOrThrow(
                "ALTER TABLE pairwise_similarity RENAME TO pairwise_similarity_legacy"
            )
            try execOrThrow("""
                CREATE TABLE pairwise_similarity (
                    lhs_asset_id TEXT NOT NULL,
                    rhs_asset_id TEXT NOT NULL,
                    embedding_version INT NOT NULL,
                    feature_distance REAL NOT NULL,
                    time_delta_seconds REAL,
                    is_burst_pair INT NOT NULL DEFAULT 0,
                    bucket TEXT NOT NULL,
                    similarity_score REAL NOT NULL,
                    computed_at REAL NOT NULL,
                    PRIMARY KEY (lhs_asset_id, rhs_asset_id, embedding_version)
                )
            """)
            let versionExpression = legacyHasVersion
                ? "embedding_version"
                : "\(PhotoEmbeddingContract.legacyEmbeddingVersion)"
            try execOrThrow("""
                INSERT INTO pairwise_similarity (
                    lhs_asset_id, rhs_asset_id, embedding_version, feature_distance,
                    time_delta_seconds, is_burst_pair, bucket, similarity_score, computed_at
                )
                SELECT
                    lhs_asset_id, rhs_asset_id, \(versionExpression), feature_distance,
                    time_delta_seconds, is_burst_pair, bucket, similarity_score, computed_at
                FROM pairwise_similarity_legacy
            """)
            try execOrThrow("DROP TABLE pairwise_similarity_legacy")
            try execOrThrow("COMMIT")
        } catch {
            rollbackIgnoringSecondaryFailure()
            throw error
        }
    }

    private func migrateTrainingRowsTableIfNeeded() throws {
        let columns = try tableColumnInfo("training_rows")
        guard !columns.contains(where: { $0.name == "active_choice" }) else {
            return
        }

        // Existing keeper rows predate an explicit human-choice signal. Default
        // them to inactive so legacy accepted defaults cannot train the model.
        try execOrThrow(
            "ALTER TABLE training_rows ADD COLUMN active_choice INT NOT NULL DEFAULT 0"
        )
    }

    private func tableColumnInfo(_ table: String) throws -> [SQLiteColumnInfo] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK else {
            throw sqlError()
        }
        defer { sqlite3_finalize(stmt) }

        var columns: [SQLiteColumnInfo] = []
        var stepResult = sqlite3_step(stmt)
        while stepResult == SQLITE_ROW {
            if let namePointer = sqlite3_column_text(stmt, 1) {
                columns.append(
                    SQLiteColumnInfo(
                        name: String(cString: namePointer),
                        primaryKeyPosition: Int(sqlite3_column_int(stmt, 5))
                    )
                )
            }
            stepResult = sqlite3_step(stmt)
        }
        guard stepResult == SQLITE_DONE else { throw sqlError() }
        return columns
    }

    private func validateEmbedding(_ embedding: Data?, version: Int) throws {
        guard let embedding else { return }
        guard let expectedByteCount = PhotoEmbeddingContract.expectedByteCount(for: version) else {
            throw MLStoreError.unsupportedEmbeddingVersion(version)
        }
        guard embedding.count == expectedByteCount else {
            throw MLStoreError.invalidEmbeddingByteCount(
                version: version,
                expected: expectedByteCount,
                actual: embedding.count
            )
        }
    }

    private func validatePairEmbeddingVersions(_ pair: PairSimilarityRecord) throws {
        guard pair.lhsAssetID != pair.rhsAssetID else {
            throw MLStoreError.invalidPair("Pair assets must be distinct")
        }
        guard PhotoEmbeddingContract.expectedByteCount(for: pair.embeddingVersion) != nil else {
            throw MLStoreError.unsupportedEmbeddingVersion(pair.embeddingVersion)
        }

        let sql = """
            SELECT asset_id, embedding, embedding_version
            FROM photo_features
            WHERE asset_id IN (?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw sqlError()
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, pair.lhsAssetID, -1, SQLITE_TRANSIENT_PTR)
        sqlite3_bind_text(stmt, 2, pair.rhsAssetID, -1, SQLITE_TRANSIENT_PTR)

        var validatedIDs = Set<String>()
        var stepResult = sqlite3_step(stmt)
        while stepResult == SQLITE_ROW {
            guard let idPointer = sqlite3_column_text(stmt, 0) else {
                throw MLStoreError.invalidPair("Stored feature row has no asset ID")
            }
            let assetID = String(cString: idPointer)
            let version = Int(sqlite3_column_int(stmt, 2))
            guard version == pair.embeddingVersion else {
                throw MLStoreError.pairEmbeddingVersionMismatch(
                    assetID: assetID,
                    expected: pair.embeddingVersion,
                    actual: version
                )
            }
            guard sqlite3_column_type(stmt, 1) != SQLITE_NULL else {
                throw MLStoreError.missingEmbedding(assetID)
            }
            let byteCount = Int(sqlite3_column_bytes(stmt, 1))
            guard let expectedByteCount = PhotoEmbeddingContract.expectedByteCount(for: version) else {
                throw MLStoreError.unsupportedEmbeddingVersion(version)
            }
            guard byteCount == expectedByteCount else {
                throw MLStoreError.invalidEmbeddingByteCount(
                    version: version,
                    expected: expectedByteCount,
                    actual: byteCount
                )
            }
            validatedIDs.insert(assetID)
            stepResult = sqlite3_step(stmt)
        }
        guard stepResult == SQLITE_DONE else { throw sqlError() }
        let expectedIDs = Set([pair.lhsAssetID, pair.rhsAssetID])
        guard validatedIDs == expectedIDs else {
            let missingID = expectedIDs.subtracting(validatedIDs).sorted().first ?? "unknown"
            throw MLStoreError.missingEmbedding(missingID)
        }
    }

    private func deleteRowsBeyondLimit(
        table: String,
        orderColumn: String,
        keepingNewest limit: Int
    ) throws -> Int {
        let allowedTargets: Set<String> = [
            "training_rows.timestamp",
            "pairwise_similarity.computed_at"
        ]
        guard allowedTargets.contains("\(table).\(orderColumn)") else {
            throw MLStoreError.invalidMaintenanceTarget("\(table).\(orderColumn)")
        }

        let sql = """
            DELETE FROM \(table)
            WHERE rowid IN (
                SELECT rowid FROM \(table)
                ORDER BY \(orderColumn) DESC, rowid DESC
                LIMIT -1 OFFSET ?
            )
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw sqlError()
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, sqlite3_int64(max(limit, 0)))
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw sqlError() }
        return Int(sqlite3_changes(db))
    }

    private func deleteRecordsForInactiveAssets(
        _ activeAssetIDs: Set<String>
    ) throws -> (features: Int, pairs: Int) {
        try execOrThrow("DROP TABLE IF EXISTS temp.active_photo_asset_ids")
        try execOrThrow(
            "CREATE TEMP TABLE active_photo_asset_ids (asset_id TEXT PRIMARY KEY)"
        )
        try execOrThrow("BEGIN TRANSACTION")
        do {
            let insertSQL = "INSERT OR IGNORE INTO active_photo_asset_ids (asset_id) VALUES (?)"
            var insertStatement: OpaquePointer?
            guard sqlite3_prepare_v2(db, insertSQL, -1, &insertStatement, nil) == SQLITE_OK else {
                throw sqlError()
            }
            defer {
                if insertStatement != nil {
                    sqlite3_finalize(insertStatement)
                }
            }

            for assetID in activeAssetIDs {
                sqlite3_reset(insertStatement)
                sqlite3_clear_bindings(insertStatement)
                sqlite3_bind_text(insertStatement, 1, assetID, -1, SQLITE_TRANSIENT_PTR)
                guard sqlite3_step(insertStatement) == SQLITE_DONE else {
                    throw sqlError()
                }
            }
            sqlite3_finalize(insertStatement)
            insertStatement = nil

            try execOrThrow("""
                DELETE FROM pairwise_similarity
                WHERE lhs_asset_id NOT IN (SELECT asset_id FROM active_photo_asset_ids)
                   OR rhs_asset_id NOT IN (SELECT asset_id FROM active_photo_asset_ids)
            """)
            let deletedPairs = Int(sqlite3_changes(db))
            try execOrThrow("""
                DELETE FROM photo_asset_analysis
                WHERE asset_id NOT IN (SELECT asset_id FROM active_photo_asset_ids)
            """)
            try execOrThrow("""
                DELETE FROM photo_features
                WHERE asset_id NOT IN (SELECT asset_id FROM active_photo_asset_ids)
            """)
            let deletedFeatures = Int(sqlite3_changes(db))
            try execOrThrow("COMMIT")
            try execOrThrow("DROP TABLE active_photo_asset_ids")
            return (deletedFeatures, deletedPairs)
        } catch {
            rollbackIgnoringSecondaryFailure()
            try? execOrThrow("DROP TABLE IF EXISTS active_photo_asset_ids")
            throw error
        }
    }

    private func rollbackIgnoringSecondaryFailure() {
        var errorMessage: UnsafeMutablePointer<CChar>?
        sqlite3_exec(db, "ROLLBACK", nil, nil, &errorMessage)
        if let errorMessage {
            sqlite3_free(errorMessage)
        }
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

    private func exportCSVToString(sql: String, headers: [String]) throws -> String {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("photoduck-export-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try exportCSV(sql: sql, headers: headers, to: temporaryURL)
        return try String(contentsOf: temporaryURL, encoding: .utf8)
    }

    private func exportCSV(sql: String, headers: [String], to destinationURL: URL) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw sqlError()
        }
        defer { sqlite3_finalize(stmt) }

        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temporaryURL = destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw MLStoreError.cannotCreateExport(temporaryURL.path)
        }
        let handle = try FileHandle(forWritingTo: temporaryURL)
        var shouldDeleteTemporaryFile = true
        var handleIsOpen = true
        defer {
            if handleIsOpen {
                try? handle.close()
            }
            if shouldDeleteTemporaryFile {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
        }

        try writeCSVLine(headers, to: handle, prependNewline: false)
        let columnCount = Int(sqlite3_column_count(stmt))
        var stepResult = sqlite3_step(stmt)
        while stepResult == SQLITE_ROW {
            var values: [String] = []
            values.reserveCapacity(columnCount)
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
                        values.append(csvEscaped(String(cString: text)))
                    } else {
                        values.append("")
                    }
                }
            }
            try writeCSVLine(values, to: handle, prependNewline: true)
            stepResult = sqlite3_step(stmt)
        }
        guard stepResult == SQLITE_DONE else { throw sqlError() }
        try handle.synchronize()
        try handle.close()
        handleIsOpen = false

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
        shouldDeleteTemporaryFile = false
    }

    private func writeCSVLine(
        _ values: [String],
        to handle: FileHandle,
        prependNewline: Bool
    ) throws {
        let prefix = prependNewline ? "\n" : ""
        guard let data = "\(prefix)\(values.joined(separator: ","))".data(using: .utf8) else {
            throw MLStoreError.cannotEncodeCSV
        }
        try handle.write(contentsOf: data)
    }

    private func csvEscaped(_ value: String) -> String {
        guard value.contains(",")
                || value.contains("\"")
                || value.contains("\n")
                || value.contains("\r") else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
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

private struct SQLiteColumnInfo {
    let name: String
    let primaryKeyPosition: Int
}

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

struct PhotoAssetAnalysisCacheLookup: Sendable {
    let assetID: String
    let modificationDate: Date?
    let pixelWidth: Int
    let pixelHeight: Int
    let mediaSubtypesRawValue: UInt64
    let analyzerVersion: Int
    let embeddingVersion: Int
}

struct PhotoAssetAnalysisCacheRecord: Sendable {
    let assetID: String
    let modificationDate: Date?
    let pixelWidth: Int
    let pixelHeight: Int
    let mediaSubtypesRawValue: UInt64
    let analyzerVersion: Int
    let embeddingVersion: Int
    let embedding: Data?
    let perceptualHash: UInt64?
    let keeperSignalsJSON: Data?
}

struct PairSimilarityRecord: Sendable {
    let lhsAssetID: String
    let rhsAssetID: String
    let embeddingVersion: Int
    let featureDistance: Double
    let timeDeltaSeconds: Double?
    let isBurstPair: Bool
    let bucket: String
    let similarityScore: Double

    init(
        lhsAssetID: String,
        rhsAssetID: String,
        embeddingVersion: Int = PhotoEmbeddingContract.embeddingVersion,
        featureDistance: Double,
        timeDeltaSeconds: Double?,
        isBurstPair: Bool,
        bucket: String,
        similarityScore: Double
    ) {
        self.lhsAssetID = lhsAssetID
        self.rhsAssetID = rhsAssetID
        self.embeddingVersion = embeddingVersion
        self.featureDistance = featureDistance
        self.timeDeltaSeconds = timeDeltaSeconds
        self.isBurstPair = isBurstPair
        self.bucket = bucket
        self.similarityScore = similarityScore
    }
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
    let activeChoice: Bool
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
    case schemaVersionTooNew(found: Int, supported: Int)
    case unsupportedEmbeddingVersion(Int)
    case invalidEmbeddingByteCount(version: Int, expected: Int, actual: Int)
    case missingEmbedding(String)
    case pairEmbeddingVersionMismatch(assetID: String, expected: Int, actual: Int)
    case invalidPair(String)
    case walCheckpointBusy(Int)
    case invalidMaintenanceTarget(String)
    case cannotCreateExport(String)
    case cannotEncodeCSV

    var errorDescription: String? {
        switch self {
        case .cannotOpen(let msg): return "Cannot open ML store: \(msg)"
        case .sqlError(let msg): return "ML store SQL error: \(msg)"
        case .schemaVersionTooNew(let found, let supported):
            return "ML store file uses schema v\(found); this build supports v\(supported)"
        case .unsupportedEmbeddingVersion(let version):
            return "Unsupported embedding version: \(version)"
        case .invalidEmbeddingByteCount(let version, let expected, let actual):
            return "Embedding v\(version) expected \(expected) bytes, received \(actual)"
        case .missingEmbedding(let assetID):
            return "Missing embedding for pair asset \(assetID)"
        case .pairEmbeddingVersionMismatch(let assetID, let expected, let actual):
            return "Pair asset \(assetID) has embedding v\(actual), expected v\(expected)"
        case .invalidPair(let message):
            return "Invalid pair cache record: \(message)"
        case .walCheckpointBusy(let connections):
            return "WAL checkpoint could not complete; \(connections) connection(s) are busy"
        case .invalidMaintenanceTarget(let target):
            return "Invalid ML store maintenance target: \(target)"
        case .cannotCreateExport(let path):
            return "Cannot create ML export at \(path)"
        case .cannotEncodeCSV:
            return "Cannot encode ML export as UTF-8"
        }
    }
}
