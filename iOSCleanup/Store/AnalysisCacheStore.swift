import Foundation
import SQLite3

// MARK: - Cached analysis result

struct CachedAnalysis: Sendable {
    let localIdentifier: String
    let modificationDate: Date
    let dhash: UInt64?
    let isBlurry: Bool?
    let qualityScore: Float?
    let semanticCategory: String?
}

// MARK: - SQLite-backed per-asset analysis cache

/// Persists per-asset analysis results (dHash, blur, quality, semantic) so engines
/// skip already-analyzed assets on relaunch. Layered alongside the existing JSON
/// grouping cache — this store handles individual asset signals, not group decisions.
actor AnalysisCacheStore {

    static let shared = AnalysisCacheStore()

    private var db: OpaquePointer?

    // Prepared statements (lazily compiled, reused across calls)
    private var insertStmt: OpaquePointer?
    private var selectStmt: OpaquePointer?
    private var deleteStmt: OpaquePointer?
    private var allBlurryStmt: OpaquePointer?
    private var allDHashStmt: OpaquePointer?
    private var allSemanticStmt: OpaquePointer?
    private var allQualityStmt: OpaquePointer?

    // MARK: - Lifecycle

    private init() {
        openDatabase()
        createTablesIfNeeded()
        prepareStatements()
    }

    deinit {
        sqlite3_finalize(insertStmt)
        sqlite3_finalize(selectStmt)
        sqlite3_finalize(deleteStmt)
        sqlite3_finalize(allBlurryStmt)
        sqlite3_finalize(allDHashStmt)
        sqlite3_finalize(allSemanticStmt)
        sqlite3_finalize(allQualityStmt)
        sqlite3_close(db)
    }

    // MARK: - Database setup

    private func openDatabase() {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("photoduck_analysis.sqlite")
        guard sqlite3_open_v2(
            dbURL.path,
            &db,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK else { return }
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")
    }

    private func createTablesIfNeeded() {
        exec("""
            CREATE TABLE IF NOT EXISTS asset_analysis (
                local_identifier  TEXT PRIMARY KEY,
                modification_date REAL NOT NULL,
                dhash             INTEGER,
                is_blurry         INTEGER,
                quality_score     REAL,
                semantic_category TEXT
            )
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_dhash ON asset_analysis(dhash) WHERE dhash IS NOT NULL")
        exec("CREATE INDEX IF NOT EXISTS idx_blurry ON asset_analysis(is_blurry) WHERE is_blurry = 1")
        exec("CREATE INDEX IF NOT EXISTS idx_semantic ON asset_analysis(semantic_category) WHERE semantic_category IS NOT NULL")
    }

    private func prepareStatements() {
        // Upsert (INSERT OR REPLACE) — writes all columns, preserving existing non-NULL values
        // via COALESCE so each engine only needs to supply its own column.
        sqlite3_prepare_v2(db, """
            INSERT INTO asset_analysis (local_identifier, modification_date, dhash, is_blurry, quality_score, semantic_category)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            ON CONFLICT(local_identifier) DO UPDATE SET
                modification_date = ?2,
                dhash             = COALESCE(?3, dhash),
                is_blurry         = COALESCE(?4, is_blurry),
                quality_score     = COALESCE(?5, quality_score),
                semantic_category = COALESCE(?6, semantic_category)
        """, -1, &insertStmt, nil)

        // Select single row by identifier
        sqlite3_prepare_v2(db, """
            SELECT modification_date, dhash, is_blurry, quality_score, semantic_category
            FROM asset_analysis WHERE local_identifier = ?1
        """, -1, &selectStmt, nil)

        // Delete by identifier
        sqlite3_prepare_v2(db, "DELETE FROM asset_analysis WHERE local_identifier = ?1", -1, &deleteStmt, nil)

        // Bulk queries for cold-start
        sqlite3_prepare_v2(db, "SELECT local_identifier FROM asset_analysis WHERE is_blurry = 1", -1, &allBlurryStmt, nil)
        sqlite3_prepare_v2(db, "SELECT local_identifier, dhash FROM asset_analysis WHERE dhash IS NOT NULL", -1, &allDHashStmt, nil)
        sqlite3_prepare_v2(db, "SELECT local_identifier, semantic_category FROM asset_analysis WHERE semantic_category IS NOT NULL", -1, &allSemanticStmt, nil)
        sqlite3_prepare_v2(db, "SELECT local_identifier, quality_score FROM asset_analysis WHERE quality_score IS NOT NULL", -1, &allQualityStmt, nil)
    }

    // MARK: - Batch read

    /// Returns fresh (non-stale) cached analyses for the given identifiers.
    /// An entry is "fresh" if its modification_date matches the current PHAsset date.
    func fetchFreshAnalyses(
        for identifiers: [String],
        currentModDates: [String: Date]
    ) -> [String: CachedAnalysis] {
        guard let stmt = selectStmt else { return [:] }
        var results: [String: CachedAnalysis] = [:]
        results.reserveCapacity(identifiers.count)

        for id in identifiers {
            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)

            guard sqlite3_step(stmt) == SQLITE_ROW else { continue }

            let cachedMod = sqlite3_column_double(stmt, 0)
            let currentMod = currentModDates[id]?.timeIntervalSince1970 ?? 0

            // Stale check: if modification dates differ, skip this cached row
            if abs(cachedMod - currentMod) > 1.0 { continue }

            let dhash: UInt64? = sqlite3_column_type(stmt, 1) != SQLITE_NULL
                ? UInt64(bitPattern: sqlite3_column_int64(stmt, 1))
                : nil
            let isBlurry: Bool? = sqlite3_column_type(stmt, 2) != SQLITE_NULL
                ? sqlite3_column_int(stmt, 2) != 0
                : nil
            let qualityScore: Float? = sqlite3_column_type(stmt, 3) != SQLITE_NULL
                ? Float(sqlite3_column_double(stmt, 3))
                : nil
            let semanticCategory: String? = sqlite3_column_type(stmt, 4) != SQLITE_NULL
                ? String(cString: sqlite3_column_text(stmt, 4))
                : nil

            results[id] = CachedAnalysis(
                localIdentifier: id,
                modificationDate: Date(timeIntervalSince1970: cachedMod),
                dhash: dhash,
                isBlurry: isBlurry,
                qualityScore: qualityScore,
                semanticCategory: semanticCategory
            )
        }
        return results
    }

    // MARK: - Batch writes (per-engine)

    func upsertDHashes(_ entries: [(identifier: String, modDate: Date, dhash: UInt64)]) {
        guard let stmt = insertStmt, !entries.isEmpty else { return }
        exec("BEGIN IMMEDIATE")
        for entry in entries {
            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, (entry.identifier as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 2, entry.modDate.timeIntervalSince1970)
            sqlite3_bind_int64(stmt, 3, Int64(bitPattern: entry.dhash))
            sqlite3_bind_null(stmt, 4)  // is_blurry — don't overwrite
            sqlite3_bind_null(stmt, 5)  // quality_score
            sqlite3_bind_null(stmt, 6)  // semantic_category
            sqlite3_step(stmt)
        }
        exec("COMMIT")
    }

    func upsertBlurResults(_ entries: [(identifier: String, modDate: Date, isBlurry: Bool)]) {
        guard let stmt = insertStmt, !entries.isEmpty else { return }
        exec("BEGIN IMMEDIATE")
        for entry in entries {
            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, (entry.identifier as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 2, entry.modDate.timeIntervalSince1970)
            sqlite3_bind_null(stmt, 3)  // dhash
            sqlite3_bind_int(stmt, 4, entry.isBlurry ? 1 : 0)
            sqlite3_bind_null(stmt, 5)  // quality_score
            sqlite3_bind_null(stmt, 6)  // semantic_category
            sqlite3_step(stmt)
        }
        exec("COMMIT")
    }

    func upsertQualityScores(_ entries: [(identifier: String, modDate: Date, score: Float)]) {
        guard let stmt = insertStmt, !entries.isEmpty else { return }
        exec("BEGIN IMMEDIATE")
        for entry in entries {
            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, (entry.identifier as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 2, entry.modDate.timeIntervalSince1970)
            sqlite3_bind_null(stmt, 3)  // dhash
            sqlite3_bind_null(stmt, 4)  // is_blurry
            sqlite3_bind_double(stmt, 5, Double(entry.score))
            sqlite3_bind_null(stmt, 6)  // semantic_category
            sqlite3_step(stmt)
        }
        exec("COMMIT")
    }

    func upsertSemanticCategories(_ entries: [(identifier: String, modDate: Date, category: String)]) {
        guard let stmt = insertStmt, !entries.isEmpty else { return }
        exec("BEGIN IMMEDIATE")
        for entry in entries {
            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, (entry.identifier as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 2, entry.modDate.timeIntervalSince1970)
            sqlite3_bind_null(stmt, 3)  // dhash
            sqlite3_bind_null(stmt, 4)  // is_blurry
            sqlite3_bind_null(stmt, 5)  // quality_score
            sqlite3_bind_text(stmt, 6, (entry.category as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        exec("COMMIT")
    }

    // MARK: - Cold-start bulk queries

    func allBlurryIdentifiers() -> [String] {
        guard let stmt = allBlurryStmt else { return [] }
        sqlite3_reset(stmt)
        var ids: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            ids.append(String(cString: sqlite3_column_text(stmt, 0)))
        }
        return ids
    }

    func allDHashes() -> [String: UInt64] {
        guard let stmt = allDHashStmt else { return [:] }
        sqlite3_reset(stmt)
        var result: [String: UInt64] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let hash = UInt64(bitPattern: sqlite3_column_int64(stmt, 1))
            result[id] = hash
        }
        return result
    }

    func allSemanticCategories() -> [String: String] {
        guard let stmt = allSemanticStmt else { return [:] }
        sqlite3_reset(stmt)
        var result: [String: String] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let cat = String(cString: sqlite3_column_text(stmt, 1))
            result[id] = cat
        }
        return result
    }

    func allQualityScores() -> [String: Float] {
        guard let stmt = allQualityStmt else { return [:] }
        sqlite3_reset(stmt)
        var result: [String: Float] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let score = Float(sqlite3_column_double(stmt, 1))
            result[id] = score
        }
        return result
    }

    // MARK: - Maintenance

    func deleteIdentifiers(_ ids: [String]) {
        guard let stmt = deleteStmt, !ids.isEmpty else { return }
        exec("BEGIN IMMEDIATE")
        for id in ids {
            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        exec("COMMIT")
    }

    func vacuum() {
        exec("VACUUM")
    }

    // MARK: - Helpers

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }
}
