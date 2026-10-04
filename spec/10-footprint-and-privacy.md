# Chapter 10 — Own footprint, persistence health and privacy

> **Milestone(s):** M3 · **Workstreams:** WS-46 – WS-48 · Read `spec/README.md` first: operating rules, invariants, build/test commands and the decision log apply to every workstream here.

## Chapter overview

A storage cleaner that keeps about 0.6 GB of its own data loses trust at once. It also fails on the nearly full phones it is meant to help. WS-46 turns the SQLite ML store into a bounded, disposable warm cache in `Library/Caches`. That cache holds the 10,000 newest embeddings, has no pair-distance cache, uses incremental vacuum, and deletes the legacy Application Support file at launch. It also makes every scan write authoritative, so the cache can never serve stale evidence. WS-47 makes persistence failures honest and actionable. SQL text and "Personalization" never reach the user, and a disk-full warning sends the user to Large Videos. The ML cache repairs itself when its file is corrupt, from a newer build, or the disk is full. The DEBUG export goes to a share sheet instead of an invisible Documents folder. WS-48 gives every user, purchasers included, a Help & Privacy menu (policy, terms, restore, support, Storage & Data, diagnostics, reset kept photos). It also rewrites the policy to match actual data handling and fixes the permission wording that App Review rejects. The key risks: WS-46 rewrites the store and scan-loop code that WS-20/23/24/37 just stabilized, and WS-48's "Clear" must race cleanly with an in-flight scan without ever touching the photo library, the entitlement or lifetime stats.

---

## WS-46 — ML store as a bounded disposable cache

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M3 | L | WS-20, WS-23, WS-34, WS-37 | no | `ws/46-ml-bounded-cache` |

**Primary files:** `iOSCleanup/Engines/PhotoMLStore.swift`, `iOSCleanup/Engines/PhotoMLBridge.swift`, `iOSCleanup/Engines/PhotoScanEngine.swift`, `iOSCleanup/iOSCleanupApp.swift`, `iOSCleanup/Engines/PhotoScanCacheWrite.swift` (*new*), `iOSCleanup/Engines/PhotoEmbeddingCachePolicy.swift` (*new*), `iOSCleanupTests/PhotoMLStoreTests.swift`, `iOSCleanupTests/PhotoScanEngineTests.swift`, `iOSCleanupTests/PhotoEmbeddingCachePolicyTests.swift` (*new*), `iOSCleanup.xcodeproj/project.pbxproj`, `CLAUDE.md`
**Findings covered:** ML-02 (P1, confirmed), ML-05 (P2, confirmed), ML-06 (P2, confirmed), ML-12 (P3, partially)
**Decisions applied:**
- **D-ML:** no training collection in Release. The warm cache holds the 10,000 newest embeddings in `Caches/PhotoDuck/ml`, the pair cache goes, and the legacy `Application Support/PhotoDuck/ml` is deleted on upgrade.
- **D-LIMITED-ACCESS:** retention keeps WS-20's `allowsInactiveAssetPruning`. A nil active set applies row caps only and never prunes inactive assets.
- **D-BACKUP:** the new directory is still passed through WS-34's `PhotoDuckStorage` helper, so it is backup-excluded and protected.
- **D-REANALYSIS:** no `analyzerVersion` or `embeddingVersion` bump here. `PhotoEmbeddingContract` is unchanged, and the new file starts empty. WS-37 already bumped `PhotoMLBridge.analyzerVersion` to 2, and retention purges `photo_asset_analysis` rows whose `analyzer_version` differs from the current one (WS-46.4). Those rows could never produce a cache hit, so this only reclaims space.

### Goal
After a full scan of a 50k library, the ML cache stays at or below about 100 MB. PhotoDuck's whole own footprint (this cache, both snapshot JSON copies and the file-size cache) must fit the M3 budget of **≤ 160 MB** (README §9, contract 5), measured in WS-54's Device QA. It sits in a backup-excluded Caches directory and shrinks after pruning. The legacy 0.5+ GB Application Support file is gone after the first launch. The scan loop does no SQLite I/O per compared pair. A photo whose latest analysis failed, or whose content changed, can never yield a cached embedding or distance.

### Current behavior (verified)
Baseline tree, 2026-09-27. WS-20/23/24/33/34/37 will have moved code, so re-find everything by symbol.
- **Store location and filename.** `iOSCleanup/Engines/PhotoMLStore.swift:90-97`: `init(directoryURL:)` defaults to `.applicationSupportDirectory` and uses `PhotoDuck/ml/photoduck-ml.sqlite`.
- **Open pragmas.** `PhotoMLStore.swift:101-133`: `open()` sets `journal_mode = WAL`, `synchronous = NORMAL` and `foreign_keys = ON`. There is no `auto_vacuum`. `journal_size_limit` is added by WS-34 (ML-07). Line 109 opens with `SQLITE_OPEN_FULLMUTEX`.
- **Blob placement.** `PhotoMLStore.swift:220-238`: `photo_features` stores `embedding BLOB` as column 2, before `embedding_version` and the metadata. Every read of a later column walks the 8 KB overflow chain.
- **Uncapped embeddings.** `PhotoMLStore.swift:35-38`: `MLStoreRetentionPolicy` caps only `maximumTrainingRows = 50_000` and `maximumPairRows = 250_000`. `photo_features` has no cap.
- **Retention never compacts.** `PhotoMLStore.swift:1237-1274`: `performRetention(activeAssetIDs:…, vacuumAfterward: false)`. Grep shows no caller passes `vacuumAfterward: true`, and nothing calls `vacuum()`, `deleteOldFeatures` or `deleteAllData` outside tests.
- **Pair cache on the scan path.** `PhotoMLStore.swift:271-285` creates `pairwise_similarity` with `PRIMARY KEY (lhs_asset_id, rhs_asset_id, embedding_version)` and no content stamp. `:875-938` `loadPairSimilarities` runs one JOIN per key against `photo_features` twice. `:800-861` `upsertPairSimilarities` calls `validatePairEmbeddingVersions` per pair (`:1449-1508`). Each call prepares a statement and reads both 8 KB blobs.
- **Pair cache in the engine.** `iOSCleanup/Engines/PhotoScanEngine.swift:730-732` awaits `mlBridge.cachedPairSimilarities(for: candidateKeys)` once per analyzed asset. `:743-760` prefers `PhotoScanPairDistanceResolver.cachedResolution` over the freshly computed distance. `:804-818` writes a `PairSimilarityRecord` only when `!evidence.wasCacheHit`, so cached rows are never rewritten. `:899` calls `bufferPairSimilarities`.
- **Stale pair rows after an edit.** `PhotoMLStore.swift:891-899`: the read JOIN only checks that both embeddings exist with a matching version. After an edit, the old (A,B) distance is still served (ML-06 path 1).
- **Failed re-analysis keeps the old embedding (ML-06 path 2).**
  - `PhotoScanEngine.swift:1080-1087`: on a Vision failure `analyzeAsset` returns `embedding: nil`. `PhotoScanAssetAnalysis.unavailable` (`:88-93`) is all-nil.
  - `:886-900`: every batch writes feature records for the whole `batch` (nil embeddings included) and an analysis record for every analysis, failures included.
  - `PhotoMLStore.swift:425-430`: `embedding = COALESCE(excluded.embedding, photo_features.embedding)` keeps the pre-edit blob.
  - `:585-603`: `upsertAssetAnalyses` stamps the row with the new modification date and dimensions.
  - `:687-699`: `loadValidAssetAnalyses` joins on `features.embedding IS NOT NULL AND features.embedding_version = analysis.embedding_version`. A later incremental scan therefore gets a cache hit with the pre-edit embedding.
- **The only production reader.** `PhotoScanEngine.swift:459-482`: the only reader of stored embeddings is `mlBridge.cachedAssetAnalyses(for: contextAssets)`, reached only when `requiredAssetIDs != nil`. Full scans read nothing.
- **Distance metrics.** `PhotoScanEngine.swift:1698-1739`: `PhotoEmbeddingValueDistance.normalizedDistance` computes RMS, `sqrt(Σd²/n)`. `PhotoFeatureDistanceNormalizer` (`~:1820-1832`) divides the Vision L2 distance by `sqrt(n)`, so both produce the same metric. The pair cache only saved recomputing a value that is already cheap.
- **Bridge buffers.** `iOSCleanup/Engines/PhotoMLBridge.swift:26-38, 104-149`: separate feature, pair and analysis buffers are flushed as three transactions. `:239-256` is `cachedPairSimilarities`.
- **ML-12 residue.**
  - `PhotoMLStore.swift:1176-1180`: `databaseSizeBytes` reads only the main file.
  - `:1614-1622`: `queryInt` returns 0 when the step is not `SQLITE_ROW`.
  - `:1001-1071`: `insertTrainingRows` calls `insertTrainingRow`, which prepares and finalizes once per row.
- **Dead APIs.** `loadAllEmbeddings` (`:525-554`, about 400 MB at 50k) and `deleteOldFeatures` (`:1290-1325`) have no production callers.
- **Tests that encode the old behavior.** `iOSCleanupTests/PhotoMLStoreTests.swift`:
  - The `databasePath` helper (`~:141-146`) hard-codes `PhotoDuck/ml/photoduck-ml.sqlite`.
  - Seven pair tests (`:721-970`).
  - `testMetadataOnlyUpsertPreservesExistingEmbedding` (`:289`), which encodes the COALESCE behavior this workstream removes.
  - `testDeleteOldFeatures*` (`:1467`, `:1493`).
  - Two legacy-migration tests (`:1555`, `:1569`).
  - `iOSCleanupTests/PhotoScanEngineTests.swift:154-199` tests `PhotoScanPairDistanceResolver`.
  - `testWarmIncrementalScanReusesUnchangedContextAnalysis` (`:635-706`) must keep passing.

### Implementation plan

**WS-46.1 — New schema-v6 cache file in Caches**
- **Why:** The store lives in backed-up Application Support. It never compacts, and it stores the blob before the metadata.
- **Change** (`PhotoMLStore.swift`):
  1. Add `static let databaseFileName = "photoduck-scan-cache.sqlite"`. A new name means the legacy file is never opened or migrated.
  2. Add `nonisolated static func defaultBaseURL(fileManager: FileManager = .default) -> URL`. It returns `.cachesDirectory`, falling back to `temporaryDirectory`.
  3. `init(directoryURL: URL? = nil, collectsTrainingData: Bool = PhotoDuckBuildFlags.collectsMLTrainingData)`. Keep today's convention: the argument is a *base* URL, and the store appends `PhotoDuck/ml/`. Store `nonisolated let collectsTrainingData`. This reuses WS-33's single gate (README §9, contract 23): the compile flag `PhotoDuckBuildFlags.collectsMLTrainingData` plus the runtime value. WS-33's `PhotoMLBridge.init(store:collectsTrainingData:)` keeps its parameter, and it must equal the store's. Production passes the same default to both, and tests pass the same explicit value to both. Add `assert(collectsTrainingData == store.collectsTrainingData)` in the bridge's `init`.
  4. Add `nonisolated let databaseURL: URL` for tests and diagnostics.
  5. `static let schemaVersion = 6`.
  6. `open()` pragma order is load-bearing. `PRAGMA auto_vacuum = INCREMENTAL` must run **before any CREATE, including `schema_meta`**, because SQLite can only enable auto-vacuum on a database with no tables:
     ```swift
     func open() throws {
         guard !isOpen else { return }
         try PhotoDuckStorage.prepareDirectory(at: dbDirectoryURL)   // WS-34.1 helper: backup-excluded + file protection
         var handle: OpaquePointer?
         let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
         guard sqlite3_open_v2(dbPath, &handle, flags, nil) == SQLITE_OK else { … unchanged … }
         connection.handle = handle; isOpen = true
         do {
             try execOrThrow("PRAGMA auto_vacuum = INCREMENTAL")        // first; no-op on existing v6 files
             try execOrThrow("PRAGMA journal_mode = WAL")
             try execOrThrow("PRAGMA journal_size_limit = 8388608")      // keep WS-34's line if present
             try execOrThrow("PRAGMA synchronous = NORMAL")
             try execOrThrow("PRAGMA foreign_keys = ON")
             try migrateSchema()
         } catch { sqlite3_close(handle); connection.handle = nil; isOpen = false; throw error }
     }
     ```
  7. `migrateSchema()`. Delete `runMigrations`, `migratePairwiseSimilarityTableIfNeeded`, `migrateTrainingRowsTableIfNeeded`, `dropDuplicatedAnalysisEmbeddingsIfNeeded` and `columnSniffedMigrationVersion`; the new file has no legacy content.
     - Stored version `nil`: create the tables and stamp 6.
     - Stored version `6`: create tables `IF NOT EXISTS`, then indexes.
     - Any other stored version: throw `MLStoreError.schemaVersionTooNew(found:supported:)` (reuse the case even for lower versions) and leave the marker untouched. WS-47 turns this into a reset.
  8. `createTables()`:
     ```sql
     CREATE TABLE IF NOT EXISTS photo_embeddings (
         asset_id TEXT PRIMARY KEY,
         creation_date REAL,
         embedding_version INT NOT NULL,
         updated_at REAL NOT NULL,
         embedding BLOB NOT NULL            -- LAST: metadata/ORDER BY reads never touch overflow pages
     );
     -- photo_asset_analysis: identical columns to v5 (no blob).
     ```
     - When `collectsTrainingData` is true, also create:
       - `photo_features` as a **metadata-only** table: v5's columns minus `embedding` and `embedding_version`, keyed by `asset_id`. The DEBUG keeper CSV's `LEFT JOIN photo_features pf` keeps working.
       - The training tables exactly as WS-33 left them: `feedback_events`, `feedback_assets` and `training_rows`.
     - Never create `pairwise_similarity`.
     - This supersedes WS-33.4's "keep `CREATE TABLE` for these tables unchanged". With the flag off, the v6 file has no training tables. So `feedbackEventCount()`, `trainingRowCount()` and WS-33's `purgeTrainingCollection()` return 0, or return early, when `!collectsTrainingData`, without touching SQLite. `PhotoMLBridge.performRetention` no longer calls `purgeTrainingCollection()`. WS-33's `testCollectionDisabledWritesNoTrainingRows` must stay green: construct its store with `collectsTrainingData: false` too.
  9. `createIndexes()`:
     - Always: `idx_embeddings_creation ON photo_embeddings(creation_date)` and the existing `idx_asset_analysis_updated`.
     - Under the flag only: the feedback and training indexes.
     - Drop both `idx_pairwise_*` and `idx_features_screenshot`.
- **Edge cases:**
  - `sqlite3_exec` on `PRAGMA journal_mode = WAL` returns a row. The existing `execOrThrow` already tolerates that.
  - With the flag off (Release), no statement may reference a training table. See WS-46.7 for `stats()`.

**WS-46.2 — Authoritative scan-cache writes (ML-06 path 2)**
- **Why:** A failed re-analysis must never leave a row that later yields the pre-edit embedding.
- **Change:**
  1. New file `iOSCleanup/Engines/PhotoScanCacheWrite.swift`:
     ```swift
     struct PhotoEmbeddingRecord: Sendable, Equatable {
         let assetID: String
         let creationDate: Date?
         let embeddingVersion: Int
         let embedding: Data
     }

     /// Exactly one authoritative write per analyzed asset (WS-46).
     enum PhotoScanCacheWrite: Sendable {
         /// Successful analysis inside the cache window: replaces any prior embedding + analysis row.
         case store(PhotoEmbeddingRecord, PhotoAssetAnalysisCacheRecord)
         /// Failed analysis, or an asset outside the cache window: it must never produce a warm-cache hit.
         case invalidate(assetID: String)

         var assetID: String {
             switch self {
             case .store(let embedding, _): return embedding.assetID
             case .invalidate(let assetID): return assetID
             }
         }
     }
     ```
  2. `PhotoMLStore`:
     - Add `@discardableResult func applyScanCacheWrites(_ writes: [PhotoScanCacheWrite]) throws -> Int`.
     - Validate each `.store` embedding with `validateEmbedding(_:version:)` **before** `BEGIN`. A `.store` that fails validation becomes `.invalidate` for that asset and counts as skipped. Return the skipped count.
     - Prepare four statements once per call (upsert embedding, upsert analysis, delete embedding, delete analysis), with `sqlite3_reset` and `sqlite3_clear_bindings` per row, all inside one `BEGIN … COMMIT`. Roll back on the first error.
     - The embedding upsert is authoritative: `ON CONFLICT(asset_id) DO UPDATE SET embedding = excluded.embedding, embedding_version = excluded.embedding_version, creation_date = excluded.creation_date, updated_at = excluded.updated_at`. Never `COALESCE`.
     - The analysis upsert keeps today's column list. The record's own `embedding` field is ignored because the blob lives in `photo_embeddings`.
     - `.invalidate` runs `DELETE FROM photo_embeddings WHERE asset_id = ?` and `DELETE FROM photo_asset_analysis WHERE asset_id = ?`.
  3. `loadValidAssetAnalyses(for:)`: change the JOIN to `JOIN photo_embeddings emb ON emb.asset_id = analysis.asset_id WHERE analysis.asset_id = ? AND emb.embedding_version = analysis.embedding_version`. Everything else stays: metadata equality checks, skip-on-invalid-blob, and prepare-once.
  4. Delete `upsertFeature`, the old `upsertFeatures`, `upsertAssetAnalyses` (replaced), `loadAllEmbeddings` and `deleteOldFeatures`. Keep `loadEmbedding(for:)`, now reading `photo_embeddings`; it is bounded and used by tests.
  5. Rename the metadata writer to `upsertTrainingFeatureMetadata(_ records: [PhotoFeatureRecord]) throws`. It is valid only when `collectsTrainingData` and returns early otherwise. Remove `embedding` and `embeddingVersion` from `PhotoFeatureRecord`, and change `PhotoMLBridge.makeFeatureRecords(for:embeddings:)` to `makeFeatureRecords(for:)`. If `HomeViewModel.saveAnalysisSnapshot` still calls `makeFeatureRecords`/`persistFeatureRecords` (WS-34's ML-07 should have deleted that block), delete the block now.
  6. `PhotoMLBridge`:
     - Replace `bufferedFeatureRecords` and `bufferedAssetAnalysisRecords` with `bufferedScanCacheWrites: [PhotoScanCacheWrite]`.
     - WS-33 left the scan-path `photo_features` writes ungated, because they carried the embedding. Keep a metadata buffer for `upsertTrainingFeatureMetadata`, and fill and flush it only when `collectsTrainingData`. In Release nothing is buffered.
     - Add `func bufferScanCacheWrites(_:) async`, flushing at `featureFlushCount` (96) or after `maximumFlushLatencyNanoseconds`.
     - `flushBufferedWrites()` issues one `applyScanCacheWrites` call.
     - Add:
       ```swift
       nonisolated func makeScanCacheWrite(
           asset: PHAsset,
           analysis: PhotoScanAssetAnalysis,
           isInsideCacheWindow: Bool
       ) -> PhotoScanCacheWrite {
           guard isInsideCacheWindow, let embedding = analysis.embedding else {
               return .invalidate(assetID: asset.localIdentifier)
           }
           return .store(
               PhotoEmbeddingRecord(assetID: asset.localIdentifier, creationDate: asset.creationDate,
                                    embeddingVersion: PhotoEmbeddingContract.embeddingVersion, embedding: embedding),
               makeAssetAnalysisRecord(asset: asset, analysis: analysis))
       }
       ```
     - Add a DEBUG-only counter `private(set) var debugStoredEmbeddingWriteCount` that counts `.store` writes committed. Tests use it to prove the write-side guard.
- **Edge cases:**
  - `.invalidate` for an asset with no row is a primary-key miss: cheap and correct.
  - Invalidating assets outside the window (WS-46.5) also deletes rows left from when the asset *was* inside it. Because an edited asset's old row is deleted, it can't linger.
  - Ordering inside one batch doesn't matter: each asset appears once per batch.

**WS-46.3 — Remove the pair-distance cache end to end (ML-05, ML-06 path 1)**
- **Why:** The pair cache adds up to 120 point lookups per asset, a statement prepared per pair, about 100 MB on disk, and serves stale distances after edits.
- **Change:**
  1. `PhotoScanEngine`:
     - In the per-asset block (as restructured by WS-23/24), delete `cachedPairRecords` and the `mlBridge.cachedPairSimilarities` await.
     - Compute every distance as `featureDistance(lhs:rhs:) ?? PhotoEmbeddingValueDistance.normalizedDistance(lhs:rhs:)`.
     - Delete `PhotoScanPairDistanceResolution`, `PhotoScanPairDistanceResolver` and `CandidatePairEvidence.wasCacheHit`.
     - Delete `newPairRecords` and its construction, the `bufferPairSimilarities` call, and `pairCacheHitCount`/`pairCacheMissCount`.
     - Change the DEBUG completion log to `"scan completed context_cache_hits=\(cachedContextAssets.count) reanalyzed=\(processedCount)"`.
  2. `PhotoMLBridge`: delete `bufferedPairRecords`, `pairFlushCount`, `persistPairSimilarities`, `bufferPairSimilarities` and `cachedPairSimilarities`.
  3. `PhotoMLStore`: delete the following. Keep `SimilarityPairKey`; the engine uses it.
     - `upsertPairSimilarity(ies)`, `loadPairSimilarit(y|ies)`, `pairSimilarityCount` and `validatePairEmbeddingVersions`.
     - The pairwise target in `deleteRowsBeyondLimit`'s allowlist and the pair delete in `deleteRecordsForInactiveAssets`.
     - `MLStoreRetentionPolicy.maximumPairRows`, `PairSimilarityRecord`, and `MLStoreError.missingEmbedding`, `.pairEmbeddingVersionMismatch` and `.invalidPair`.
  4. DEBUG `MLExportStats` (`PhotoMLBridge.swift:490-512`): drop `pairCount`. If WS-07 has not deleted `HomeViewModel.learningDebugSummary`, delete it now; it has no callers.
- **Edge cases:**
  - Clustering evidence doesn't change: distances come from the same pinned-revision prints or embeddings under the same RMS contract.
  - Do **not** port `PhotoEmbeddingValueDistance` to vDSP. It runs at most 120 comparisons × 2,048 floats per asset (well under a millisecond). A Float-accumulating vDSP path could flip a threshold-boundary pair, which invariant 22 forbids.

**WS-46.4 — Bounded retention: newest-N cap, orphan cleanup, incremental vacuum**
- **Why:** Retention must bound the table by row count, not only by library membership, and must give pages back to the filesystem.
- **Change:**
  1. `MLStoreRetentionPolicy`: add `static let maximumEmbeddingRows = PhotoEmbeddingCachePolicy.capacity` and delete `maximumPairRows`.
  2. `MLStoreRetentionResult` becomes `{ deletedInactiveAssetRows: Int; deletedStaleAnalyzerRows: Int; deletedEmbeddingRowsBeyondCap: Int; deletedTrainingRows: Int }`.
  3. Rewrite `performRetention`, dropping the `vacuumAfterward` parameter:
     ```swift
     @discardableResult
     func performRetention(
         activeAssetIDs: Set<String>? = nil,                 // nil ⇒ Limited access / caller opt-out (WS-20): caps only
         currentAnalyzerVersion: Int = PhotoMLBridge.analyzerVersion,   // WS-37 bumped it to 2
         maximumEmbeddingRows: Int = MLStoreRetentionPolicy.maximumEmbeddingRows,
         maximumTrainingRows: Int = MLStoreRetentionPolicy.maximumTrainingRows,
         allowEmptyActiveLibrary: Bool = false
     ) throws -> MLStoreRetentionResult {
         try ensureOpen()
         var deletedInactive = 0
         if let activeAssetIDs, !activeAssetIDs.isEmpty || allowEmptyActiveLibrary {   // invariant 14: never on an empty set
             deletedInactive = try deleteRecordsForInactiveAssets(activeAssetIDs)       // embeddings, analysis, metadata (if table exists)
         }
         // Stale analyzer rows can never be a cache hit (loadValidAssetAnalyses matches analyzer_version); purge them
         // and their embeddings (ch08 WS-37 → WS-46 hand-off). Size-independent, so it also runs under Limited access.
         let deletedStale = try deleteAnalysesWithAnalyzerVersion(notEqualTo: currentAnalyzerVersion)
         try execOrThrow("DELETE FROM photo_embeddings WHERE asset_id NOT IN (SELECT asset_id FROM photo_asset_analysis)")
         let deletedBeyondCap = try deleteEmbeddingsBeyondNewest(maximumEmbeddingRows)
         try execOrThrow("DELETE FROM photo_asset_analysis WHERE asset_id NOT IN (SELECT asset_id FROM photo_embeddings)")
         let deletedTraining = collectsTrainingData
             ? try deleteRowsBeyondLimit(table: "training_rows", orderColumn: "timestamp", keepingNewest: maximumTrainingRows)
             : 0
         try execOrThrow("PRAGMA incremental_vacuum")      // returns freelist pages to the file
         try? checkpointWAL()                              // TRUNCATE; busy is not an error here
         return MLStoreRetentionResult(deletedInactiveAssetRows: deletedInactive,
                                       deletedStaleAnalyzerRows: deletedStale,
                                       deletedEmbeddingRowsBeyondCap: deletedBeyondCap,
                                       deletedTrainingRows: deletedTraining)
     }
     ```
     `deleteAnalysesWithAnalyzerVersion(notEqualTo:)` runs `DELETE FROM photo_asset_analysis WHERE analyzer_version <> ?` and returns `sqlite3_changes`. `deleteEmbeddingsBeyondNewest(_:)` runs `DELETE FROM photo_embeddings WHERE rowid IN (SELECT rowid FROM photo_embeddings ORDER BY creation_date DESC, rowid DESC LIMIT -1 OFFSET ?)` and returns `sqlite3_changes`.
  4. `deleteRecordsForInactiveAssets` keeps its temp-table approach. It deletes from `photo_embeddings`, `photo_asset_analysis` and, when `collectsTrainingData`, the metadata `photo_features`, and returns the deleted embedding count.
  5. `PhotoMLBridge.performRetention(activeAssetIDs:maximumEmbeddingRows:)` forwards both values plus `currentAnalyzerVersion: Self.analyzerVersion`, and drops `vacuumAfterward` and WS-33's `purgeTrainingCollection()` call (WS-46.1). Keep WS-20's two engine call sites, which pass `nil` when `allowsInactiveAssetPruning` is false, and pass the engine's capacity through (WS-46.5).
  6. Delete `vacuum()`; nothing calls it after this change.
- **Edge cases:**
  - In `ORDER BY … DESC`, SQLite sorts NULL `creation_date` rows last, so undated rows are pruned first.
  - The cap is size-based. Under Limited access it can only delete rows older than the newest 10,000, which full access would delete too, so D-LIMITED-ACCESS holds.
  - In WAL mode, the main file only shrinks after the checkpoint.

**WS-46.5 — Write-side cache window in the engine**
- **Why:** Without a write-side window, a full 50k scan writes about 400 MB (plus WAL) just to prune it right away.
- **Change:**
  1. New file `iOSCleanup/Engines/PhotoEmbeddingCachePolicy.swift`:
     ```swift
     enum PhotoEmbeddingCachePolicy {
         /// D-ML: the warm cache keeps the newest N embeddings (~8.7 KB each ⇒ ~90 MB).
         static let capacity = 10_000

         /// nil ⇒ everything fits (store all). Otherwise the creationDate of the capacity-th newest dated asset.
         static func cutoffDate(creationDates: [Date?], capacity: Int = capacity) -> Date? {
             guard creationDates.count > capacity else { return nil }
             let dated = creationDates.compactMap { $0 }
             guard dated.count > capacity else { return nil }
             return dated.sorted(by: >)[capacity - 1]
         }

         static func isInsideWindow(creationDate: Date?, cutoff: Date?) -> Bool {
             guard let cutoff else { return true }
             guard let creationDate else { return false }
             return creationDate >= cutoff
         }
     }
     ```
  2. `PhotoScanEngine.init` gains `embeddingCacheCapacity: Int = PhotoEmbeddingCachePolicy.capacity`, stored as a `let`.
  3. In `performScan`, right after `allAssets` is final (after WS-18's inventory hand-off and the truncated-fetch retry), compute `let embeddingCacheCutoff = PhotoEmbeddingCachePolicy.cutoffDate(creationDates: allAssets.map(\.creationDate), capacity: embeddingCacheCapacity)`. This is one O(n log n) sort of at most 60k dates, a few milliseconds.
  4. Replace the per-batch `makeFeatureRecords`/`makeAssetAnalysisRecord` buffering (baseline `:882-900`) with:
     ```swift
     let cacheWrites = analyses.compactMap { analysis -> PhotoScanCacheWrite? in
         guard let asset = targetAssetsByID[analysis.assetID] else { return nil }
         return mlBridge.makeScanCacheWrite(
             asset: asset, analysis: analysis.featureValue,
             isInsideCacheWindow: PhotoEmbeddingCachePolicy.isInsideWindow(
                 creationDate: asset.creationDate, cutoff: embeddingCacheCutoff))
     }
     await mlBridge.bufferScanCacheWrites(cacheWrites)
     // Training metadata: keep exactly WS-33's gating (collectsMLTrainingData); records no longer carry embeddings.
     ```
  5. Pass `maximumEmbeddingRows: embeddingCacheCapacity` to both retention calls.
- **Edge cases:**
  - Incremental scans compute the window from the full `allAssets`, not from the target set.
  - Under Limited access `allAssets` is the selection, so the cutoff is usually nil. That is fine; see WS-46.4.
  - Cached context assets are not rewritten; they were not re-analyzed.

**WS-46.6 — Delete the legacy store at launch**
- **Why:** Existing installs keep 0.5–0.7 GB in `Application Support/PhotoDuck/ml` forever otherwise.
- **Change:**
  1. In `PhotoMLStore`:
     ```swift
     @discardableResult
     nonisolated static func removeLegacyStore(applicationSupportURL: URL? = nil,
                                               fileManager: FileManager = .default) -> Bool {
         guard let base = applicationSupportURL
                 ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return false }
         let legacy = base.appendingPathComponent("PhotoDuck/ml", isDirectory: true)
         guard fileManager.fileExists(atPath: legacy.path) else { return false }
         return (try? fileManager.removeItem(at: legacy)) != nil
     }
     ```
  2. Call it from the existing startup `.task` in `iOSCleanupApp.swift` (or WS-03's `AppEntry` host, wherever the WS-34 `PhotoDuckStorage` launch call lives) as `Task.detached(priority: .utility) { PhotoMLStore.removeLegacyStore() }`.
- **Edge cases:**
  - No ordering constraint with scans: the new store never touches that path.
  - On developer devices this also deletes DEBUG-collected training rows (`feedback_events`, `training_rows`) in the legacy file, which D-ML accepts. Put a warning at the top of the PR description: "Before installing this build on a device whose training data you want to keep, export it with the previous build (Similar › gear › Export ML Training Data)." The owner must see it before running WS-46 on such a device.
  - Leave the sibling files in `Application Support/PhotoDuck` alone (snapshots, learning, Diagnostics).

**WS-46.7 — Remaining SQLite hygiene (the parts of ML-12 not covered by other tasks)**
- **Change:**
  1. `databaseSizeBytes()` sums the allocated or logical sizes of `dbPath`, `dbPath + "-wal"` and `dbPath + "-shm"`, counting a missing file as 0.
  2. `queryInt` throws `sqlError()` when `sqlite3_step` is not `SQLITE_ROW`.
  3. Training-row insertion prepares the INSERT once per batch:
     - Move the bindings of `insertTrainingRow` into `private func bindTrainingRow(_ row: TrainingRowRecord, to stmt: OpaquePointer?)`.
     - `insertTrainingRows`, or WS-34's `insertFeedbackEventWithTrainingRows` if it exists, prepares once and runs `reset`/`clear_bindings` per row.
     - Keep the single transaction WS-34 introduced.
  4. `MLStoreStats` becomes `{ embeddingCount, analysisCount, feedbackEventCount, trainingRowCount, keeperRowCount, groupOutcomeRowCount, databaseSizeBytes }`. The training counts are `0` without querying when `collectsTrainingData == false`; the tables don't exist.
  5. Add `#if DEBUG func debugQueryInt(_ sql: String) throws -> Int { try queryInt(sql) }` for the test in the Tests section.
- **Out of scope:** `SQLITE_OPEN_NOMUTEX`, a dedicated serial executor, and feedback-table pruning (DEBUG-only data). Record them in `spec/BACKLOG.md`.

**WS-46.8 — Docs**
- Update `CLAUDE.md`:
  - Architecture table, `PhotoScanEngine` row: "cached pinned-revision Vision distances" becomes "pinned-revision Vision distances computed in memory".
  - Architecture table, `PhotoMLStore` row: the Caches path, filename, schema v6 tables, newest-10k cap and incremental vacuum, and "corrupt/newer files are discarded" (added by WS-47).
  - Architecture table, `PhotoMLBridge` row: no pair cache.
  - "Storage budget" section, replaced with:
    - Scan cache: at most `PhotoEmbeddingCachePolicy.capacity` (10,000) newest photos × about 8.7 KB ≈ 90–95 MB, backup-excluded and disposable.
    - Analysis snapshot JSON: two copies in Application Support (see WS-54).
    - The legacy Application Support `ml` directory is deleted at launch.
    - The whole own footprint budget is ≤ 160 MB after a 50k scan (README §9, contract 5).
  - The "On-device data collection" path.
  - WS-34's Key constraints bullet "Every PhotoDuck store lives under `Application Support/PhotoDuck`": add "except the disposable ML scan cache, which lives in `Library/Caches/PhotoDuck/ml` (also prepared through `PhotoDuckStorage.prepareDirectory(at:)`)".

### Tests
All run in the simulator. Use a temp base URL per test (the WS-03 helper), never the default store.
- **`PhotoMLStoreTests`**
  - Update `databasePath` to `PhotoDuck/ml/photoduck-scan-cache.sqlite` and construct stores with an explicit `collectsTrainingData:`. Use `true` in suites that exercise feedback/training/export, `false` elsewhere.
  - `testDefaultBaseURLIsCachesDirectory`: `PhotoMLStore.defaultBaseURL()` equals `FileManager.default.urls(for: .cachesDirectory, …).first`. It does not open the store.
  - `testStoreDirectoryIsExcludedFromBackup`: open with a temp base and assert `isExcludedFromBackup == true` on `databaseURL.deletingLastPathComponent()`.
  - `testNewFileUsesIncrementalAutoVacuum`: raw `PRAGMA auto_vacuum` returns 2.
  - `testJournalSizeLimitApplied`: `debugQueryInt("PRAGMA journal_size_limit") == 8_388_608`. Keep WS-34's test if it already covers this.
  - `testSchemaHasNoPairTableAndEmbeddingBlobIsLastColumn`:
    - `sqlite_master` has no `pairwise_similarity`.
    - The last row of `PRAGMA table_info(photo_embeddings)` is `embedding`.
  - `testTrainingTablesExistOnlyWhenCollectionEnabled`: with `false`, `training_rows`, `feedback_events`, `feedback_assets` and `photo_features` are absent and `stats()` succeeds with zero training counts. With `true`, they are present.
  - `testStoreWriteRoundTripsThroughValidAnalysisLookup`: `.store` then `loadValidAssetAnalyses` returns the embedding and hash. Replaces the old round-trip tests; port `testAssetAnalysisCacheRequiresExactVersionedMetadataContract` and `testAssetAnalysisCacheRoundTripsNilModificationDate` to the new writer unchanged in intent.
  - `testStoreWriteReplacesPriorEmbedding`: store E1, then store E2 for the same asset, and `loadEmbedding` returns E2. This replaces `testMetadataOnlyUpsertPreservesExistingEmbedding`, which is deleted with a PR note.
  - `testFailedReanalysisInvalidatesWarmCacheHit` (ML-06):
    1. Store E1 with metadata M1.
    2. Apply `.invalidate(assetID)`, the write for a nil-embedding re-analysis.
    3. `loadValidAssetAnalyses` for M1 and for M2 are both empty, and `loadEmbedding` is nil.
  - `testInvalidStoreWriteInvalidatesInsteadOfAbortingBatch`: a batch with one wrong-byte-count embedding among valid ones. The valid rows commit, the bad asset has no row, and the skipped count is 1.
  - `testEmbeddingRetentionKeepsNewestNRows`:
    - Seed 30 `.store` writes with ascending `creationDate`, then `performRetention(activeAssetIDs: nil, maximumEmbeddingRows: 10)`.
    - Exactly the 10 newest IDs remain, and each still produces a cache hit.
    - `photo_asset_analysis` has 10 rows (orphans deleted).
  - `testRetentionPrunesUndatedRowsFirst`: undated rows go before dated ones.
  - `testRetentionWithNilActiveSetAppliesOnlyRowCaps` (WS-20 semantics): no inactive pruning, but the cap still applies.
  - `testRetentionNeverPrunesForEmptyActiveSet`: `activeAssetIDs: []` leaves every row.
  - `testRetentionRemovesInactiveAssets`: port from `testRetentionBoundsTrainingRowsAndRemovesInactiveAssets`, covering both training rows (flag on) and embeddings.
  - `testRetentionPurgesStaleAnalyzerVersionRows`: store 3 assets with `analyzerVersion: 1` and 3 with `2`, then `performRetention(activeAssetIDs: nil, currentAnalyzerVersion: 2)`. Exactly the 3 version-2 assets keep an analysis row and an embedding row, and `deletedStaleAnalyzerRows == 3`.
  - `testTrainingCountsAreZeroWithoutTablesWhenCollectionDisabled`: with `collectsTrainingData: false`, `feedbackEventCount()`, `trainingRowCount()` and `purgeTrainingCollection()` succeed without error and return 0 (WS-33 APIs).
  - `testIncrementalVacuumShrinksFileAfterRetention`:
    1. Store 500 embeddings and `checkpointWAL()`. Record the main file size S1.
    2. Retain 50.
    3. Assert main file size < S1 / 2.
  - `testDatabaseSizeIncludesWALAndSHM`: after a write without checkpoint, `databaseSizeBytes()` > the main file's size.
  - `testQueryIntThrowsWhenNoRow`: `debugQueryInt("SELECT 1 WHERE 0")` throws.
  - `testRemoveLegacyStoreDeletesOnlyTheLegacyMLDirectory`:
    - Temp base containing `PhotoDuck/ml/photoduck-ml.sqlite`, `-wal`, `-shm`, plus `PhotoDuck/photo-analysis-cache.json`.
    - After the call, `ml/` is gone and the JSON survives. A second call returns false.
  - Delete: the 7 pair tests, `testDeleteOldFeatures`, `testDeleteOldFeaturesAlsoDropsDependentAnalysisRows`, `testStaleSchemaMarkerRunsMigrationsAndIsRestamped`, `testLegacyDuplicatedAnalysisEmbeddingIsPurgedOnMigration`, and the `insertPairFeatures` helper. Keep `testOpeningNewerSchemaFileIsRefusedWithoutDowngradingTheMarker` (WS-47 replaces it).
- **`PhotoEmbeddingCachePolicyTests`** (new)
  - `testNoCutoffWhenLibraryFits`.
  - `testCutoffIsCapacityThNewestDate`: 12 dates, capacity 5, returns the 5th newest.
  - `testUndatedAssetsAreOutsideWindowWhenCutoffExists`.
  - `testTiesAtCutoffAreInside`.
- **`PhotoScanEngineTests`**
  - Delete `testPairDistanceResolverReportsCacheHit` and `testPairDistanceResolverRejectsLegacyRawDistanceVersion`.
  - `testWarmIncrementalScanReusesUnchangedContextAnalysis` must pass unchanged.
  - `testFullScanStoresOnlyNewestAssetsInsideCacheWindow`:
    - 12 assets with distinct dates, a deterministic analyzer returning valid 2,048-float embeddings, a bridge on a temp store, and `embeddingCacheCapacity: 5`.
    - After the scan, `bridge.debugStoredEmbeddingWriteCount == 5`, which proves the write-side guard rather than retention.
    - `store.stats().embeddingCount == 5`, and the remaining IDs are the 5 newest.
  - `testScanLeavesNoPairTableAndGroupsAreStableAcrossWarmScan`:
    - Use WS-08's end-to-end fixture: a scan, then an incremental scan adding one far-away asset.
    - Groups compared as `(sorted member IDs, reason, keeperAssetID, Set(deleteCandidateIDs))` are identical.
    - Raw `sqlite_master` at `store.databaseURL` has no `pairwise_similarity`.
  - `testEditedAssetWithFailedReanalysisIsNotServedAsContext`. This needs WS-08's `ConfigurablePhotoScanTestAsset` with a settable `modificationDate`; if that is missing, rely on the store-level test above and note it in the PR.
    1. Scan 1: A analyzes fine.
    2. Scan 2: A is modified and the analyzer returns `.unavailable`.
    3. Scan 3 adds B next to A: the analyzer is invoked for A, a context cache miss.
- WS-08's golden end-to-end tests must pass without edits (evidence that classification is unchanged).

### Acceptance criteria
- [ ] The default store path is `Library/Caches/PhotoDuck/ml/photoduck-scan-cache.sqlite`, the directory is backup-excluded, `PRAGMA auto_vacuum` = 2, and `journal_size_limit` = 8 MB.
- [ ] `grep -rn "pairwise_similarity\|PairSimilarityRecord\|cachedPairSimilarities\|PhotoScanPairDistanceResolver\|loadAllEmbeddings\|deleteOldFeatures\|COALESCE(excluded.embedding" iOSCleanup iOSCleanupTests` returns nothing.
- [ ] There is no SQLite access inside the per-asset comparison loop. The only ML awaits in `performScan` are `cachedAssetAnalyses` (before the loop), `bufferScanCacheWrites` (once per batch), flush and retention.
- [ ] A full scan writes `.store` rows only for assets inside the newest-10k window (`testFullScanStoresOnlyNewestAssetsInsideCacheWindow`), and retention caps the table at `PhotoEmbeddingCachePolicy.capacity`.
- [ ] Retention purges `photo_asset_analysis` rows whose `analyzer_version` differs from `PhotoMLBridge.analyzerVersion` (2 after WS-37), plus their embeddings (`testRetentionPurgesStaleAnalyzerVersionRows`).
- [ ] **Footprint budget (README §9, contract 5).** `PhotoEmbeddingCachePolicy.capacity` is the single tuning constant, default 10,000. The M3 target for PhotoDuck's whole own footprint is ≤ 160 MB after a full scan of a 50k library (this cache plus the snapshot copies and the file-size cache), measured in WS-54's Device QA, not 120 MB. This workstream records the cache's own size (Device QA 3). If WS-54's measurement exceeds 160 MB, lower `capacity` in steps of 2,500 (minimum 5,000), re-measure, and record each result in `docs/DEVICE_QA.md`.
- [ ] A failed or partial analysis deletes the asset's embedding and analysis rows (`testFailedReanalysisInvalidatesWarmCacheHit`).
- [ ] The legacy `Application Support/PhotoDuck/ml` is removed at launch, and nothing else in `Application Support/PhotoDuck` is touched.
- [ ] WS-20's `allowsInactiveAssetPruning` semantics and the "never prune on an empty active set" guard are preserved (tests above).
- [ ] The full suite is green, WS-08's end-to-end fixtures are unchanged, and there are no new warnings. `CLAUDE.md` is updated as in WS-46.8.

### Device QA
Add to `docs/DEVICE_QA.md`:
1. Install the pre-WS-46 build on a device with 20k or more photos. Complete a scan and record Settings › General › iPhone Storage › PhotoDuck › Documents & Data.
2. Install the WS-46 build over it and launch. Wait 10 s, then use Xcode › Devices › Download Container:
   - `Library/Application Support/PhotoDuck/ml` is absent.
   - `Library/Caches/PhotoDuck/ml/photoduck-scan-cache.sqlite` exists.
3. Run a full scan to completion (the gear's confirmed "Scan Again", WS-26's `rescanEntireLibrary()`). In the container, `photoduck-scan-cache.sqlite` + `-wal` total ≤ 100 MB. Record Documents & Data. The whole-footprint check against the ≤ 160 MB M3 budget happens in WS-54's Device QA, after WS-48's Storage & Data sheet exists (contract 5).
4. Take 10 new photos and reopen the app. The incremental scan finishes. In a DEBUG build, the log shows `context_cache_hits` > 0.
5. Record the time per 1k assets of a full scan against the WS-09 baseline. It must be equal or better.

### Pitfalls and out of scope
- **`auto_vacuum` ordering.** It must precede every CREATE, including `schema_meta`. Otherwise the pragma is silently ignored and the file never shrinks; `testNewFileUsesIncrementalAutoVacuum` guards this.
- **Build flags.** Release builds (`collectsTrainingData == false`) must never reference training tables. `stats()`, retention and `deleteRecordsForInactiveAssets` need explicit flag checks.
- **Isolation.** Do not remove `PhotoEmbeddingContract` validation, the pinned revision or RMS normalization. Do not open the default store in tests.
- **Loop ownership.** WS-23/24 own the per-asset loop structure. Change only the distance source and the per-batch buffering, and keep the per-asset block self-contained for WS-53.
- **Cap interactions.** Resolved by README §9, contract 13. WS-63 (chapter 13) builds **no** engine `regroup(thresholds:)` over cached analyses, so the 10k cap never limits it. A post-release threshold change takes effect on the next user-initiated full re-analysis, like WS-37's `analyzerVersion` rollout. The only production reader stays the incremental `cachedAssetAnalyses(for: contextAssets)`.
- **Other workstreams.** The ML self-heal and disk-full breaker are WS-47. The Storage & Data UI and the clear action are WS-48. Snapshot JSON size is WS-54 (chapter 11).
- **Footprint budget (contract 5).** The M3 budget is ≤ 160 MB for the whole own footprint after a 50k scan, measured in WS-54's Device QA. The earlier 120 MB figure is retired. About 93 MB of cache (up to about 100 MB with WAL), plus two snapshot copies (about 13–15 MB each after WS-54), plus up to about 15 MB of file sizes, fits with margin. Keep `capacity` a single tuning constant. If WS-54 measures more than 160 MB, lower it in steps of 2,500 (minimum 5,000) and record the result. The privacy policy (WS-48.1) interpolates `capacity`, so its text follows automatically.
- **Reconciliation:**
  - L5: the budget is 160 MB, with the capacity-lowering rule, in the Goal and Acceptance.
  - L13: no WS-63 regroup.
  - L23: one `collectsTrainingData` gate shared by store and bridge. WS-33's `GroupActionFeatureSchema` and the group-outcome export stay (DEBUG-only), and the training tables are `feedback_events`, `feedback_assets` and `training_rows`.
  - WS-34's helper is `PhotoDuckStorage.prepareDirectory(at:)`.
  - The ch08 hand-off: purge `analyzer_version != current` rows.
  - The ch10 issue: warn the owner about DEBUG training rows in the legacy directory.

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| ML-02 | confirmed | All cited lines match. Size math: an 8 KB blob plus about 60 bytes of payload is 489 local bytes + 2 overflow pages, about 8.7 KB/row, so 10k rows ≈ 87 MB + analysis rows ≈ 93 MB. The plan follows the fix. Test (a) is changed to check `defaultBaseURL()` plus exclusion on a temp store instead of opening the real default store (WS-03 forbids that). Metadata moves to a DEBUG-only metadata table rather than staying beside the blob. |
| ML-05 | confirmed | The per-asset await, per-pair validation and version-only keys match the code. The pair cache is removed entirely. The optional vDSP port is **not** done: the scalar path costs under 1 ms per asset, and Float accumulation could change boundary classifications (invariant 22). |
| ML-06 | confirmed | Path 1 (pair rows without a content stamp, cache preferred, hits never rewritten) and path 2 (`COALESCE` blob plus a re-stamped analysis row) are both real. A failed asset is usually retried as *required* (commit 8e7e5c3), but it is still served when it is *context*. Removing the pair cache fixes path 1. Path 2 uses a typed `.invalidate` write rather than the `replaceEmbedding:` flag, and the COALESCE path is deleted outright. |
| ML-12 | partially | Real, but mostly subsumed: blob order, auto_vacuum, journal limit and WAL size are handled by WS-46.1/.4 and WS-34. Per the workstream notes, only WAL/SHM size, a throwing `queryInt` and statement reuse are implemented here. NOMUTEX, the serial executor and feedback pruning go to the backlog. |

---

## WS-47 — Persistence health and DEBUG ML export

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M3 | M | WS-46 | no | `ws/47-persistence-health` |

**Primary files:**
- Existing: `iOSCleanup/Engines/PhotoMLStore.swift`, `iOSCleanup/Engines/PhotoMLBridge.swift`, `iOSCleanup/Engines/PhotoAnalysisCache.swift`, `iOSCleanup/Engines/PhotoFeedbackStore.swift`, `iOSCleanup/Views/HomeViewModel.swift` (facade only), `iOSCleanup/Views/HomeView.swift`, `iOSCleanup/Views/PhotoDuckShellView.swift`, `iOSCleanup/Utilities/SharedHelpers.swift` (event factories only), `MLTraining/TrainKeeperModel.swift`, `MLTraining/README.md`, `CLAUDE.md`.
- *New* code: `iOSCleanup/Engines/PersistenceHealth.swift`, `iOSCleanup/Views/Home/PersistenceHealthMonitor.swift`, `iOSCleanup/Views/Home/PersistenceWarningCopy.swift`, `iOSCleanup/Views/Home/PersistenceWarningBanner.swift`, `iOSCleanup/Views/Components/TemporaryFileShareSheet.swift`, `iOSCleanup/Engines/PhotoMLDebugExport.swift`.
- *New* tests: `iOSCleanupTests/PhotoMLBridgeTests.swift`, `iOSCleanupTests/PersistenceHealthTests.swift`, `iOSCleanupTests/MLTrainingScriptSchemaTests.swift`.

**Findings covered:** ML-09 (P2, confirmed), FSA-13 (P2, confirmed), ML-13 (P3, confirmed; merged: BUILD-18 confirmed; STORE-14's DEBUG wrapping)
**Decisions applied:**
- **D-ML:** the ML store is a disposable cache. Its failures are diagnostics, never user warnings, and the training export exists only in DEBUG.
- **D-BACKUP:** nothing is written to Documents. The export goes to `tmp` and is shared, then deleted.
- **D-DIAG-UPTIME / invariant 26:** new diagnostic events are typed, with no paths, IDs or localized text.

### Goal
Users see a persistence warning only when a store they depend on (the scan snapshot or their review history) cannot be written. The copy says what happened and what to do. Disk-full offers a jump to Large Videos, and an oversized snapshot gets its own accurate message. The ML cache recreates itself when it is corrupt or from another schema, and it stops retrying writes when the disk is full. Developers can AirDrop the DEBUG export to a Mac. The training script refuses to train when feature columns are missing, and a test pins the script's column lists to the app's schemas.

### Current behavior (verified)
- **Raw ML error text in the warning.** `iOSCleanup/Views/HomeViewModel.swift:2299-2313`: `refreshPersistenceHealth()` shows `"Personalization data could not be saved (\(mlFailure)). Free a little storage and try again."`. `mlFailure` comes from `PhotoMLBridge.swift:447-453` as `"\(operation): \(error.localizedDescription)"`, which is raw SQLite text. `MLStoreError.missingEmbedding` (`PhotoMLStore.swift:1936-1937`) interpolates an asset ID; WS-46 deletes that case.
- **The warning is refreshed only in two places.** `refreshPersistenceHealth()` is called only from the bootstrap Task (`HomeViewModel.swift:324-330`; WS-31 moves it earlier in bootstrap) and from `saveAnalysisSnapshot` (`:2003-2017`), whose only caller is reconcile (`:1917`). None of these durable saves refresh it:
  - worker completion (`:1181`)
  - periodic `scheduleSnapshot` (`:1187`)
  - pause (`:902-915`)
  - background (`:1562-1568`)
  - cancellation (`:1244-1265`)
- **Snapshot health is a bare Bool.** `iOSCleanup/Engines/PhotoAnalysisCache.swift:494`: `persistenceHealthy` is a `Bool`. Write failures keep only `errorDescription: String` (`:700-712`). `snapshotTooLarge` (`:679`, limit `maximumCacheBytes = 64 MB` at `:491`) can't be told apart from ENOSPC. The error type is `private` (`:798-806`).
- **The ML store never self-heals.** `PhotoMLStore.open()` throws `schemaVersionTooNew` on every attempt (`:147-156`) and never recreates the file. `sqlError()` (`:1721-1724`) and `execOrThrow` (`:1605-1612`) discard the result code, so `SQLITE_FULL`, `SQLITE_CORRUPT` and `SQLITE_NOTADB` are indistinguishable. Every batch retries a failing write.
- **Feedback write failures are silent.** `iOSCleanup/Engines/PhotoFeedbackStore.swift:370-389`: `appendDurably` returns `false` when both the journal (`:515-541`) and the archive (`:496-509`) fail. There is no health flag, and `append` also returns `false` for duplicates. Callers discard the result (`Views/Photos/PhotoGroupDetailView.swift:219`, `:257`).
- **The DEBUG export writes to Documents and can't be retrieved.**
  - `PhotoMLBridge.swift:331-378` writes CSVs, stats and a raw DB copy to `Documents/PhotoDuck-ML-Export/` using `.first!`. The functions are not `#if DEBUG`.
  - `Views/PhotoDuckShellView.swift:398-411`: `exportMLTrainingData()` and its `@State` (`:105-106`) are not `#if DEBUG` either; only the menu button is (`:254-260`).
  - The alert (`:406-407`) promises "Files > On My iPhone > PhotoDuck". `Info.plist` has neither `UIFileSharingEnabled` nor `LSSupportsOpeningDocumentsInPlace`, so that folder is invisible, never deleted, and backed up.
- **Dead helpers.** `PhotoFeedbackStore.recentEvents`, `exportRows` and `approximateDiskFootprintBytes` (`:288-304`) and `PhotoPreferenceProfileStore.approximateDiskFootprintBytes` (`:49-53`) have no callers. WS-46 already deleted `loadAllEmbeddings` and `deleteOldFeatures`.
- **The training script tolerates missing columns.** `MLTraining/TrainKeeperModel.swift:138-151` and `:225-236` hard-code `featureColumns`, then `validFeatures = featureColumns.filter { existingColumns.contains($0) }`, so a missing column trains silently on fewer inputs. The app's sources of truth are `KeeperFeatureSchema.modelInputNames` and `GroupActionFeatureSchema.modelInputNames` (`Engines/SimilarityCoreMLClassifier.swift:36-80`). WS-33 keeps `GroupActionFeatureSchema` and the group-outcome export, now DEBUG-only (README §9, contract 23), so both lists exist.
- **The share-sheet pattern already exists.** `HomeView.swift:10-64` has a `private struct DiagnosticActivityView` that deletes its file on completion or dismantle.

### Implementation plan

**WS-47.1 — Typed ML store errors and self-heal on open**
- **Why:** A corrupt file or one from another build disables the cache forever and surfaces SQL text.
- **Change** (`PhotoMLStore.swift`):
  1. Reshape `MLStoreError`. Drop the `LocalizedError` conformance, because nothing user-facing reads it after WS-47.2:
     ```swift
     enum MLStoreError: Error, Equatable {
         case cannotOpen(code: Int32)
         case sqlite(code: Int32)                 // primary result code (rc & 0xFF); no message text
         case diskFull                            // SQLITE_FULL
         case corrupt                             // SQLITE_CORRUPT or SQLITE_NOTADB
         case schemaVersionTooNew(found: Int, supported: Int)
         case unsupportedEmbeddingVersion(Int)
         case invalidEmbeddingByteCount(version: Int, expected: Int, actual: Int)
         case walCheckpointBusy(Int)
         case invalidMaintenanceTarget
         case cannotCreateExport
         case cannotEncodeCSV
         var requiresStoreReset: Bool {
             switch self {
             case .corrupt, .schemaVersionTooNew: return true
             default: return false
             }
         }
     }
     private func storeError(forResultCode rc: Int32) -> MLStoreError {
         switch rc & 0xFF {
         case SQLITE_FULL: return .diskFull
         case SQLITE_CORRUPT, SQLITE_NOTADB: return .corrupt
         default: return .sqlite(code: rc & 0xFF)
         }
     }
     ```
  2. Route `sqlError()` through `sqlite3_extended_errcode(db)`. `execOrThrow` keeps the `rc` returned by `sqlite3_exec`. Log the SQLite message only in DEBUG, through `Logger` with `privacy: .private`.
  3. Self-heal in `open()`. Split the current body into `private func openConnectionAndMigrate() throws`, then:
     ```swift
     func open() throws {
         guard !isOpen else { return }
         do { try openConnectionAndMigrate() }
         catch let error as MLStoreError where error.requiresStoreReset {
             closeConnection()
             removeDatabaseFiles()                                  // sqlite, -wal, -shm; ignore missing
             pendingResetReason = (error == .corrupt) ? .corrupt : .schemaMismatch
             try openConnectionAndMigrate()                         // a second failure propagates
         }
     }
     func resetStore(reason: MLStoreResetReason) { closeConnection(); removeDatabaseFiles(); pendingResetReason = reason }
     func consumeResetReason() -> MLStoreResetReason? { defer { pendingResetReason = nil }; return pendingResetReason }
     ```
     Add `enum MLStoreResetReason: String, Sendable { case corrupt, schemaMismatch, corruptAtRuntime }` next to the store.
  4. Add `#if DEBUG func debugLimitPageCount(_ pages: Int) throws { try execOrThrow("PRAGMA max_page_count = \(pages)") }` so tests can produce a real `SQLITE_FULL`, and `#if DEBUG private(set) var debugScanCacheWriteAttempts = 0`, incremented at the top of `applyScanCacheWrites`.
- **Edge cases:**
  - `sqlite3_open_v2` succeeds on a garbage file. `SQLITE_NOTADB` appears on the first pragma, which is inside `openConnectionAndMigrate`, so it is caught.
  - A newer or older marker is now recreated (the file is regenerable). This replaces the WS-46 refusal.

**WS-47.2 — Bridge: failures become diagnostics, a disk-full circuit breaker, runtime corruption reset**
- **Why:** ML failures must never reach users, and doomed 800 KB writes must stop.
- **Change** (`PhotoMLBridge.swift`):
  1. Delete `lastPersistenceError`, `hasUnconsumedFailureNotice`, `consumePersistenceFailureNotice()` and the string-based `MLPersistenceHealth`. Replace them with:
     ```swift
     enum MLCacheFailureKind: String, Sendable { case diskFull, corrupt, schemaMismatch, other }
     enum MLCacheOperation: String, Sendable { case write, read, retention, stats }
     struct MLCacheHealth: Sendable, Equatable { var lastFailure: MLCacheFailureKind?; var writesSuspended: Bool }
     ```
  2. `init(store:collectsTrainingData:diagnostics:)`, where `diagnostics: @escaping @Sendable (PhotoDuckDiagnosticEvent) async -> Void = { await PhotoDuckDiagnosticLog.shared.record($0) }`. Keep WS-33's `collectsTrainingData` parameter and WS-46's equality assert with `store.collectsTrainingData` (contract 23).
  3. After every `try await store.open()`, call `if let reason = await store.consumeResetReason() { await diagnostics(.mlStoreReset(reason: reason.rawValue)) }`.
  4. Add a central failure handler:
     ```swift
     private func recordFailure(_ error: Error, operation: MLCacheOperation) async {
         let kind: MLCacheFailureKind
         switch error as? MLStoreError {
         case .diskFull?: kind = .diskFull; consecutiveDiskFullFailures += 1
         case .corrupt?:  kind = .corrupt; await store.resetStore(reason: .corruptAtRuntime)
                          await diagnostics(.mlStoreReset(reason: MLStoreResetReason.corruptAtRuntime.rawValue))
         default:         kind = .other
         }
         if kind != .diskFull { consecutiveDiskFullFailures = 0 }
         if health.lastFailure != kind { await diagnostics(.mlCacheFailure(operation: operation.rawValue, kind: kind.rawValue)) }
         health.lastFailure = kind
         Self.logger.error("\(operation.rawValue, privacy: .public) failed: \(kind.rawValue, privacy: .public)")
         if consecutiveDiskFullFailures >= 2, !health.writesSuspended {
             health.writesSuspended = true
             bufferedScanCacheWrites.removeAll(); bufferFlushTask?.cancel(); bufferFlushTask = nil
             await diagnostics(.mlCacheWritesSuspended(reason: "disk_full"))
         }
     }
     ```
     - On success, set `health.lastFailure = nil` and `consecutiveDiskFullFailures = 0`.
     - While `health.writesSuspended`, `bufferScanCacheWrites`, the flush and `performRetention` return immediately without touching the store; retention writes need WAL space too. Reads (`cachedAssetAnalyses`) continue.
     - Suspension lasts for the process lifetime.
  5. Add `func cacheHealth() -> MLCacheHealth` for tests and diagnostics.
  6. In the PhotoDuckDiagnosticEvent file (`SharedHelpers.swift`, next to the existing factories; the `private init` forces this), add only these three factories, with category `ml_cache` and string enum fields, no free text:
     - `static func mlStoreReset(reason: String)`
     - `static func mlCacheFailure(operation: String, kind: String)`
     - `static func mlCacheWritesSuspended(reason: String)`
- **Edge cases:**
  - Failure diagnostics are recorded only on transitions, so the 600-event ring isn't flooded.
  - A runtime `.corrupt` resets the file under the actor. The next call reopens a fresh store, and callers see a cache miss, which is harmless.

**WS-47.3 — Typed snapshot write failures in PhotoAnalysisCache**
- **Why:** Copy must differ for disk full, oversized snapshot and other failures. Health must be observable after every durable boundary without scattering refresh calls through code that WS-49 will move.
- **Change:**
  1. New file `iOSCleanup/Engines/PersistenceHealth.swift`:
     ```swift
     enum PersistenceWriteFailureKind: String, Sendable, Equatable {
         case diskFull, snapshotTooLarge, other
         static func classify(_ error: any Error) -> PersistenceWriteFailureKind {
             var current: NSError? = error as NSError
             for _ in 0..<4 {
                 guard let ns = current else { break }
                 if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteOutOfSpaceError { return .diskFull }
                 if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOSPC) { return .diskFull }
                 current = ns.userInfo[NSUnderlyingErrorKey] as? NSError
             }
             return .other
         }
     }
     /// Monotonic sequence so MainActor consumers can drop out-of-order hops.
     struct PersistenceHealthEvent: Sendable, Equatable { let sequence: UInt64; let failure: PersistenceWriteFailureKind? }
     typealias PersistenceHealthObserver = @Sendable (PersistenceHealthEvent) -> Void
     #if DEBUG
     enum PersistenceHealthDebug {
         /// `-PhotoDuckSimulateSnapshotWriteFailure diskFull|snapshotTooLarge|other` (simulator QA of the banner).
         static let forcedSnapshotFailure: PersistenceWriteFailureKind? = {
             let args = ProcessInfo.processInfo.arguments
             guard let i = args.firstIndex(of: "-PhotoDuckSimulateSnapshotWriteFailure"), i + 1 < args.count else { return nil }
             return PersistenceWriteFailureKind(rawValue: args[i + 1])
         }()
     }
     #endif
     ```
  2. `PhotoAnalysisCache`:
     - **Health state.** Replace `private(set) var persistenceHealthy = true` with `private(set) var lastWriteFailure: PersistenceWriteFailureKind?` and `var persistenceHealthy: Bool { lastWriteFailure == nil }`. `makeDiagnosticReport` and existing callers keep working.
     - **Write outcome.** Replace `PhotoAnalysisSnapshotWriteOutcome.errorDescription` with `failure: PersistenceWriteFailureKind?`, computed inside the detached task: `snapshotTooLarge` → `.snapshotTooLarge`, otherwise `classify(error)`. In DEBUG, apply `PersistenceHealthDebug.forcedSnapshotFailure` by skipping the write and returning that failure.
     - **Observer.** Add `private var healthObserver: PersistenceHealthObserver?`, `private var healthSequence: UInt64 = 0` and `func setHealthObserver(_ observer: PersistenceHealthObserver?)`.
     - **Publishing.** After each write outcome, call `publishHealth(outcome.failure)`. It updates `lastWriteFailure`, and if the value changed it increments `healthSequence` and calls the observer.
     - **Init.** A failing directory preparation in `init` sets `lastWriteFailure = .classify(error)`.
     - **Test seams.** Extend WS-15's `init(directoryURL: URL? = nil)` to `init(directoryURL: URL? = nil, maximumCacheBytes: Int = 64 * 1024 * 1024)`. WS-54 later adds `fileOperations:` after it.
  3. Keep generation ordering, newest-only pending writes, the backup rule and flush-waiter semantics exactly (invariant 14). Only the outcome type and the publishing are new.
- **Edge cases:**
  - WS-19 already stopped marking inconsistency as unhealthy; keep that. `lastWriteFailure` describes **writes** only.
  - WS-54 (chapter 11) later rewrites this write path: per-slot state inside the actor, with no sidecar (contract 21), plus rename rotation. It must keep this workstream's `failure` classification and `publishHealth` on every outcome, including the fallback paths, and WS-48's `removeAllSnapshots()` (idle waiters, dropped pending write, resumed flush waiters).

**WS-47.4 — Feedback store write health**
- **Change** (`PhotoFeedbackStore.swift`):
  1. Add `private(set) var lastWriteFailure: PersistenceWriteFailureKind?`, the same observer, sequence and `setHealthObserver` as WS-47.3.
  2. `appendToJournal` and `save()` capture the thrown error. Make them return `PersistenceWriteFailureKind?` (nil means success), or keep `Bool` and store the last error kind.
  3. When `appendDurably` or `appendBatchDurably` fails because **both** writes failed (the rollback branches), publish that kind. On any successful durable append or compaction, publish `nil`.
  4. Duplicates are not failures: `isDuplicate` early returns publish nothing.
  5. Keep WS-34's FSB-04 behavior (incremental prune, compaction, fire-and-forget SQLite) untouched.
- **Edge cases:** A failed debounced `performFlush` compaction alone is not a user-facing failure, because the journal still holds the events. Publish only when an event was actually rejected.

**WS-47.5 — HomeViewModel: one monitor, pure copy, an actionable banner**
- **Why:** Warnings must appear in the same session after any failing durable write, with accurate copy.
- **Change:**
  1. New file `iOSCleanup/Views/Home/PersistenceWarningCopy.swift` (pure):
     ```swift
     struct PersistenceWarning: Equatable, Sendable {
         enum Action: Equatable, Sendable { case openLargeVideos }
         let title: String; let message: String; let action: Action?
     }
     enum PersistenceWarningCopy {
         static func make(snapshotFailure: PersistenceWriteFailureKind?,
                          feedbackFailure: PersistenceWriteFailureKind?) -> PersistenceWarning? {
             if snapshotFailure == .diskFull || feedbackFailure == .diskFull {
                 return .init(title: "iPhone storage is full",
                              message: "PhotoDuck can't save your scan progress until there's more free space. Delete a few large videos, then try again.",
                              action: .openLargeVideos)
             }
             switch snapshotFailure {
             case .snapshotTooLarge?:
                 return .init(title: "Scan progress isn't being saved",
                              message: "Your library is too large for PhotoDuck to save scan progress yet. Your results stay here until you close PhotoDuck; after that it will need to scan again.",
                              action: nil)
             case .other?:
                 return .init(title: "Scan progress isn't being saved",
                              message: "PhotoDuck couldn't save your scan progress. Your results are still here, but PhotoDuck may need to scan again after you close it.",
                              action: nil)
             default: break
             }
             if feedbackFailure != nil {
                 return .init(title: "Review choices weren't saved",
                              message: "PhotoDuck couldn't save your latest review choices, so future suggestions may not reflect them.",
                              action: nil)
             }
             return nil
         }
     }
     ```
  2. New file `iOSCleanup/Views/Home/PersistenceHealthMonitor.swift`:
     ```swift
     @MainActor
     final class PersistenceHealthMonitor {
         private(set) var snapshotFailure: PersistenceWriteFailureKind?
         private(set) var feedbackFailure: PersistenceWriteFailureKind?
         private var lastSnapshotSequence: UInt64 = 0, lastFeedbackSequence: UInt64 = 0
         private var dismissedWarning: PersistenceWarning?
         var onWarningChange: ((PersistenceWarning?) -> Void)?

         func attach(analysisCache: PhotoAnalysisCache, feedbackStore: PhotoFeedbackStore) async {
             await analysisCache.setHealthObserver { [weak self] event in Task { @MainActor in self?.applySnapshot(event) } }
             await feedbackStore.setHealthObserver { [weak self] event in Task { @MainActor in self?.applyFeedback(event) } }
             snapshotFailure = await analysisCache.lastWriteFailure
             feedbackFailure = await feedbackStore.lastWriteFailure
             publish()
         }
         func dismiss() { dismissedWarning = currentWarning; onWarningChange?(nil) }
         // applySnapshot/applyFeedback: ignore events whose sequence <= last seen; update; publish().
         // publish(): let w = currentWarning; if w == nil { dismissedWarning = nil }; onWarningChange?(w == dismissedWarning ? nil : w)
         private var currentWarning: PersistenceWarning? {
             PersistenceWarningCopy.make(snapshotFailure: snapshotFailure, feedbackFailure: feedbackFailure)
         }
     }
     ```
     A dismissed warning stays hidden until the state recovers (nil) and fails again, or changes to a different warning.
  3. `HomeViewModel` (facade only, about 20 lines):
     - Delete `persistenceWarningMessage`, `refreshPersistenceHealth()` and every call to it, including the one WS-31 placed in bootstrap, and the ML-feature write that WS-34 already removed.
     - Add `@Published private(set) var persistenceWarning: PersistenceWarning?` and keep `func dismissPersistenceWarning()` (it forwards to `monitor.dismiss()`).
     - In `init`, set `monitor.onWarningChange = { [weak self] in self?.persistenceWarning = $0 }` and start `Task { await monitor.attach(analysisCache: dependencies.analysisCache, feedbackStore: dependencies.feedbackStore) }`.
     - Add `var feedbackStore: PhotoFeedbackStore = .shared` to WS-07's `HomeViewModelDependencies`, using WS-07's defaulted-field pattern (contract 16), so `.live`, `.debugFixture()` and existing tests compile unchanged. In the same PR, give `makeIsolatedDependencies` a temp-root `PhotoFeedbackStore` (WS-07's rule for fields that own on-disk state). `debugFixture()` may point it at the fixture root.
  4. New file `iOSCleanup/Views/Home/PersistenceWarningBanner.swift`: a `DuckCard` with a warning icon, title (`.duckBody.weight(.semibold)`), message (`.duckCaption`), an optional "Review Large Videos" button (`Color.accentPrimary`) and "Dismiss".
  5. `HomeView`:
     - Replace the `persistenceWarning(_:)` helper (baseline `:509-526`) and its call (`:98-100`) with `PersistenceWarningBanner(warning:onAction:onDismiss:)`.
     - Add `var onOpenLargeVideos: () -> Void = {}` to `HomeView`. `PhotoDuckShellView` passes `{ selectedTab = .files }`.
- **Edge cases:**
  - Out-of-order MainActor hops are dropped by sequence.
  - The ML bridge is not an input: the copy function has no ML parameter, by construction.
  - The copy contains no "SQL", "Personalization", "bounded" or error text.

**WS-47.6 — DEBUG export: tmp directory, share sheet, cleanup, DEBUG-only code**
- **Change:**
  1. New file `iOSCleanup/Engines/PhotoMLDebugExport.swift`, **entirely** `#if DEBUG`:
     - `enum PhotoMLDebugExport { static func export(bridge: PhotoMLBridge, temporaryDirectory: URL = FileManager.default.temporaryDirectory, now: Date = Date()) async throws -> PhotoMLDebugExportResult }`.
     - It creates `temporaryDirectory/PhotoDuck-ML-Export-yyyyMMdd-HHmmss/`, using a `DateFormatter` with `en_US_POSIX`.
     - It writes `keeper_ranking_training.csv`, `group_outcome_training.csv` (WS-33 keeps the group export, DEBUG-only; contract 23), `training_stats.json` and `photoduck-scan-cache.sqlite` through the bridge/store export functions.
     - It returns `PhotoMLDebugExportResult { let directoryURL: URL; let fileURLs: [URL] }`.
     - On any error it removes the directory and rethrows.
     - It uses no force unwraps.
  2. Move `exportTrainingDataToDocuments` and `exportDatabaseToDocuments` out of `PhotoMLBridge` into this helper, as bridge methods `exportTrainingData(to directory: URL)` and `exportDatabase(to url: URL)` wrapped in `#if DEBUG`. Also wrap the store's `exportKeeperTrainingCSV*`, `exportGroupOutcomeCSV*`, `exportDatabase(to:)`, `exportCSV*` and `writeCSVLine`/`csvEscaped` in `#if DEBUG`. The CSV tests run in Debug, so they still compile.
  3. Add `nonisolated static func removeStaleDebugExports(temporaryDirectory: URL, documentsDirectory: URL?, fileManager: FileManager = .default)`, in a non-DEBUG extension of `PhotoMLBridge` in the same file. It deletes every `PhotoDuck-ML-Export-*` directory in tmp and a legacy `Documents/PhotoDuck-ML-Export` if present. It uses no timestamp APIs, so it adds nothing to the privacy manifest. Call it from the same startup task as `removeLegacyStore()`.
  4. New file `iOSCleanup/Views/Components/TemporaryFileShareSheet.swift`: a generalization of HomeView's `DiagnosticActivityView`, `struct TemporaryFileShareSheet: UIViewControllerRepresentable { let items: [URL]; let cleanupURL: URL }`. It removes `cleanupURL` once, via a lock-guarded coordinator, in `completionWithItemsHandler` and `dismantleUIViewController`. Replace `DiagnosticActivityView` in `HomeView.swift` with `TemporaryFileShareSheet(items: [fileURL], cleanupURL: fileURL)` and delete the private type. This is a behavior-neutral move.
  5. In `PhotoDuckShellView.swift`'s `SimilarPhotosDashboardView`, wrap `isExportingMLData`, `mlExportMessage`, the alert and `exportMLTrainingData()` in `#if DEBUG`:
     - On success, set `@State var mlExportShare: MLExportShareItem?` (Identifiable wrapper) and present `.sheet(item:) { TemporaryFileShareSheet(items: $0.fileURLs, cleanupURL: $0.directoryURL) }`.
     - On failure, the alert says `"Export failed."`.
     - Delete the "Files > On My iPhone" text.
  6. Delete the dead helpers: `PhotoFeedbackStore.recentEvents`, `exportRows`, `approximateDiskFootprintBytes` and `PhotoPreferenceProfileStore.approximateDiskFootprintBytes`. `feedbackSummaryLines` and `debugSummaryLines` should be deleted if no caller remains after WS-07; otherwise wrap them in `#if DEBUG`.
  7. Do **not** add `UIFileSharingEnabled` or `LSSupportsOpeningDocumentsInPlace`.
- **Edge cases:** The DB copy runs `checkpointWAL()` first (existing `exportDatabase`), so the copy includes WAL-backed writes. Keep `testDatabaseExportIncludesWALBackedWrites`.

**WS-47.7 — Training-script schema check, lint test, docs**
- **Change:**
  1. `MLTraining/TrainKeeperModel.swift`: in each trainer, replace the `validFeatures` filter with:
     ```swift
     let missing = featureColumns.filter { !existingColumns.contains($0) }
     guard missing.isEmpty else { throw TrainingError.missingFeatureColumns(missing) }
     ```
     Add the case to the script's error enum, with a description that lists the columns. Pass `featureColumns` to the model.
  2. New file `iOSCleanupTests/MLTrainingScriptSchemaTests.swift` using the `#filePath` pattern from `DesignLintTests`:
     - It reads `MLTraining/TrainKeeperModel.swift`, finds each `let featureColumns = [` literal up to the matching `]`, and extracts `"([a-z_]+)"` tokens.
     - The first list must equal `KeeperFeatureSchema.modelInputNames`.
     - The second list must equal `GroupActionFeatureSchema.modelInputNames`. WS-33 keeps that type (contract 23), so assert that exactly two lists exist.
     - `XCTSkip` if the file is absent.
  3. `.gitignore`: make sure `MLTraining/trained-models/` and `**/PhotoDuck-ML-Export/` are present. WS-01 may already have added them; add them only if missing.
  4. `MLTraining/README.md`:
     - Step 2 becomes: DEBUG build › Similar tab gear › Export ML Training Data opens a share sheet, AirDrop to the Mac, and the files are deleted from the device afterwards.
     - Update the tree to `photoduck-scan-cache.sqlite`.
     - Replace the storage-budget section with WS-46's numbers and "collection is DEBUG/PHOTODUCK_ML_COLLECTION only".
  5. `CLAUDE.md`:
     - The "Export from device" section should say "shared via share sheet from a temporary folder".
     - The `PhotoMLBridge` row should say "exports (DEBUG only) via share sheet".
     - Add one line under Key constraints: "ML cache failures are diagnostics only; user warnings come from the snapshot and feedback stores (PersistenceWarningCopy)".

### Tests
All run in the simulator.
- **`PhotoMLStoreTests`**
  - `testNewerSchemaCacheIsRecreatedNotRefused`: replaces `testOpeningNewerSchemaFileIsRefusedWithoutDowngradingTheMarker`.
    1. Stamp `version = 99` through raw SQL on a store file holding one embedding.
    2. A new `PhotoMLStore` on the same base opens without throwing.
    3. `storedSchemaVersion() == 6`, `embeddingCount == 0`, and `consumeResetReason() == .schemaMismatch`.
  - `testOlderSchemaMarkerIsRecreated`: stamp `5`, same assertions.
  - `testCorruptFileIsRecreated`: write 8,192 bytes of `0x41` to `databaseURL`, then open. The open succeeds, the file is a valid v6 database, and the reset reason is `.corrupt`.
  - `testResetStoreRemovesFilesAndReopensEmpty`.
  - `testSQLiteFullMapsToDiskFull`: `debugLimitPageCount(current + 2)`, then apply 50 `.store` writes. The thrown error is `MLStoreError.diskFull`.
- **`PhotoMLBridgeTests`** (new)
  - Use a `DiagnosticsRecorder` actor that collects events, with names exposed through a DEBUG accessor on `PhotoDuckDiagnosticEvent` or recorded as `(category, name)` strings.
  - `testDiskFullTwiceSuspendsCacheWritesForSession`:
    1. Page-limit the store, then buffer and flush a batch twice (both fail).
    2. `cacheHealth().writesSuspended == true`.
    3. A third flush leaves `store.debugScanCacheWriteAttempts` unchanged.
    4. The recorder contains exactly one `ml_cache_writes_suspended`.
  - `testSuccessfulWriteClearsConsecutiveDiskFullCount`: fail, succeed (raise the limit), fail again. Writes are not suspended.
  - `testResetOnOpenIsRecordedAsDiagnostic`: stamp 99, call `bridge.cachedAssetAnalyses(for: [])` with any non-empty input (a `TestPhotoAsset` from WS-03). The recorder has `ml_store_reset` with reason `schema_mismatch`.
  - `testCachedReadsContinueWhileWritesSuspended`.
- **`PersistenceHealthTests`** (new)
  - Classifier: `testClassifiesCocoaOutOfSpace`, `testClassifiesPOSIXENOSPC`, `testClassifiesUnderlyingENOSPC`, `testClassifiesOtherErrors`.
  - `PersistenceWarningCopy`:
    - `testHealthyStateHasNoWarning`.
    - `testDiskFullOffersLargeVideosAction`, for a snapshot or a feedback disk-full.
    - `testSnapshotTooLargeHasItsOwnMessage`.
    - `testFeedbackOnlyFailureMessage`.
    - `testCopyNeverContainsRawOrInternalWords`: none of "SQL", "Personalization", "bounded", "error", "(" in any title or message.
  - `PersistenceHealthMonitor`:
    - `testDismissedWarningStaysHiddenUntilRecoveryThenReappears`.
    - `testOutOfOrderEventsAreIgnored`.
- **`PhotoAnalysisCacheTests`** (extends WS-17's file)
  - `testOversizedSnapshotReportsSnapshotTooLarge`: `maximumCacheBytes: 1_024`, save a normal snapshot. `lastWriteFailure == .snapshotTooLarge`, and the observer received one event.
  - `testBlockedDirectoryReportsOtherFailureThenRecovers`:
    1. Create a regular **file** at `<temp>/PhotoDuck` so writes fail. The result is `.other`.
    2. Remove it and create the directory, then save again. The observer receives `nil`, and `persistenceHealthy == true`.
  - Keep every existing generation, backup and coalescing test green.
- **`PhotoFeedbackLearningTests`**
  - `testRejectedAppendPublishesWriteFailure`: the directory base has a regular file at `PhotoDuck/learning`. `append` returns false, `lastWriteFailure == .other`, and the observer fired.
  - `testDuplicateAppendIsNotAFailure`.
  - `testSuccessfulAppendClearsWriteFailure`.
- **`HomeViewModelTests`** (WS-07 harness: temp defaults, temp caches, fixture analyzer via `makePhotoScanEngine`)
  - `testMLCacheFailureNeverProducesPersistenceWarning`: the bridge's store is page-limited, and a full fixture scan runs. `persistenceWarning == nil` throughout, observed via a `$persistenceWarning` sink.
  - `testSnapshotWriteFailureAtCompletionShowsWarningInSameSession`: the injected `PhotoAnalysisCache` uses the blocked-directory trick, and a fixture scan runs. Await an expectation fulfilled by the sink: `persistenceWarning?.title == "Scan progress isn't being saved"`.
- **`PhotoMLDebugExportTests`** (DEBUG, new or inside `PhotoMLStoreTests`)
  - `testExportWritesUnderTemporaryDirectoryNotDocuments`: temp root as `temporaryDirectory`. The files exist under `PhotoDuck-ML-Export-*`, and `Documents/PhotoDuck-ML-Export` does not exist.
  - `testRemoveStaleDebugExportsDeletesTmpAndLegacyDocumentsFolders`.
- **`MLTrainingScriptSchemaTests.testScriptFeatureColumnsMatchAppSchemas`.**

### Acceptance criteria
- [ ] `grep -rn "Personalization\|consumePersistenceFailureNotice\|persistenceWarningMessage" iOSCleanup` returns nothing. No user-visible string includes SQLite text, asset IDs or paths.
- [ ] A corrupt, newer-schema or older-schema cache file is recreated transparently and recorded as `ml_store_reset`. Scans proceed.
- [ ] After two consecutive disk-full ML write failures, no further ML writes are attempted in that session (`testDiskFullTwiceSuspendsCacheWritesForSession`).
- [ ] A snapshot write failure at completion, pause, background or cancel produces the correct warning in the same session, with no manual refresh call. Disk full shows "Review Large Videos", which switches to the Files tab.
- [ ] The oversized-snapshot message is distinct from disk full and generic failure.
- [ ] Feedback journal and archive failures produce the review-choices warning. Duplicates don't.
- [ ] No PhotoDuck code writes to `Documents`. The DEBUG export opens a share sheet and its tmp folder is deleted afterwards and at launch.
- [ ] `nm`/`strings` on a Release build has no `exportTrainingData` or `PhotoMLDebugExport` symbols. Use `grep -n "#if DEBUG"` evidence if symbol inspection is impractical.
- [ ] `TrainKeeperModel.swift` fails with the list of missing columns, and `MLTrainingScriptSchemaTests` passes.
- [ ] The full suite is green with no new warnings. `CLAUDE.md` and `MLTraining/README.md` are updated.

### Device QA
Add to `docs/DEVICE_QA.md`:
1. Banner copy in the simulator or on a device:
   - Run a DEBUG build with `-PhotoDuckSimulateSnapshotWriteFailure diskFull`, then start a scan. When the first checkpoint is saved, Home shows "iPhone storage is full". "Review Large Videos" opens the Files tab. Dismiss hides it.
   - Repeat with `snapshotTooLarge` and `other`, and check the copy.
2. On a DEBUG device build, use Similar › gear › Export ML Training Data:
   - A share sheet appears. AirDrop to a Mac and open both CSVs.
   - After dismissing, Download Container shows no `tmp/PhotoDuck-ML-Export-*` and no `Documents/PhotoDuck-ML-Export`.
3. Corrupt-cache recovery: use Xcode › Devices › Replace Container with a container whose `Library/Caches/PhotoDuck/ml/photoduck-scan-cache.sqlite` holds garbage bytes. Launch and scan: no warning banner, the scan completes, and the diagnostics log contains `ml_store_reset`.
4. Optional: a nearly full device (under 200 MB free, filled with a large video), then a full scan. Either no banner (ML-only failures) or the disk-full banner. Never SQL text.

### Pitfalls and out of scope
- **Keep the durability boundaries.** Do not reintroduce `refreshPersistenceHealth()` calls at those boundaries. The observer design is what keeps this robust through WS-49's coordinator extraction.
- **Invariant 14.** `PhotoAnalysisCache` is still the single writer. Do not change generation, backup or waiter logic here, and do not add a second writer.
- **`PhotoDuckDiagnosticEvent`.** Its `init` is `private` (`SharedHelpers.swift:~668-686`). Add only the three factories and nothing else to that file (engineering rule: do not grow `SharedHelpers.swift`).
- **Ordering with WS-48 and WS-54.** WS-47 lands **before** WS-48: both edit `PhotoAnalysisCache` (typed failures and the observer here, `removeAllSnapshots` there) and `HomeView.swift` (the banner here; the top bar and labels there). WS-48 lists WS-47 as a dependency. WS-54 (chapter 11) rewrites the snapshot write path later, and must keep this workstream's failure classification and `publishHealth` and WS-48's `removeAllSnapshots`.
- **Snapshot size limit.** The oversized-snapshot *limit* and its removal belong to WS-54 (chapter 11). Only the message lives here.
- **Other workstreams.** Storage & Data and the clear action are WS-48. The Share Diagnostics flow is unchanged (WS-02/WS-15).
- **Reconciliation:**
  - Ordering and WS-54: WS-47 → WS-48 → WS-54 ordering notes and preservation duties (ch10 cross-issue). WS-54's rewrite has no sidecar (contract 21).
  - Dependencies: `feedbackStore` joins `HomeViewModelDependencies` as a defaulted field with an isolated temp-root instance (contract 16).
  - Training schema: `GroupActionFeatureSchema` and the group-outcome CSV are definite (contract 23).
  - `refreshPersistenceHealth()` is deleted here, including WS-31's bootstrap call, so no later chapter may treat it as a durable API.
  - `PhotoAnalysisCacheTests` extends WS-17's file, and the `maximumCacheBytes:` seam extends WS-15's init.

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| ML-09 | confirmed | The warning copy, raw error strings, permanent `schemaVersionTooNew` and indistinguishable result codes all match. The plan follows the fix. It skips `PRAGMA quick_check` at open, because that is O(file) on every launch; it relies on NOTADB/CORRUPT from the first statement plus runtime reset. The disk-full test uses `max_page_count` on a real store instead of a stub, because PhotoMLBridge takes a concrete store. |
| FSA-13 | confirmed | Only the bootstrap and reconcile refreshes exist, and the feedback store has no health flag. The plan uses an observer on each store (the finding's alternative) rather than adding refresh calls at five lifecycle sites that WS-28/49 are moving. It adds a typed failure kind so disk-full, oversized and other failures get distinct copy. The Large Videos action switches to the Files tab. |
| ML-13 | confirmed | The Documents export, `.first!`, the misleading alert and the missing DEBUG wrapping all match. `loadAllEmbeddings` and `deleteOldFeatures` were already deleted in WS-46 (the schema changed under them), and `learningDebugSummary` in WS-07. The remaining dead helpers are deleted here. |
| BUILD-18 (merged into ML-13) | confirmed | `validFeatures` silently drops missing columns (`TrainKeeperModel.swift:148-149`, `:233-234`). The plan adds a hard failure plus a `#filePath` lint. `.gitignore` entries only if WS-01 did not add them. |

---

## WS-48 — Privacy, settings and data controls

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M3 | L | WS-27, WS-33, WS-34, WS-46, WS-47 | no | `ws/48-privacy-settings` |

**Primary files:**
- *New* code: `iOSCleanup/Views/PrivacyPolicyView.swift`, `iOSCleanup/Utilities/PhotoDuckLinks.swift`, `iOSCleanup/Views/Home/HelpAndPrivacyMenu.swift`, `iOSCleanup/Views/Settings/StorageAndDataView.swift`, `iOSCleanup/Utilities/PhotoDuckStorageFootprint.swift`, `iOSCleanup/Engines/PhotoDuckLocalDataReset.swift`, `docs/privacy-policy.md`.
- Existing: `iOSCleanup/Views/HomeView.swift`, `iOSCleanup/Views/HomeViewModel.swift` (facade only), `iOSCleanup/Views/Home/HomeViewModelDependencies.swift` (WS-07; one defaulted field), `iOSCleanup/Views/Home/LargeVideoScanController.swift` (one reset method), `iOSCleanup/Views/PhotoDuckShellView.swift`, `iOSCleanup/Views/PaywallView.swift`, `iOSCleanup/Views/OnboardingView.swift`, `iOSCleanup/Info.plist`, `iOSCleanup/Engines/PhotoAnalysisCache.swift`, `iOSCleanup/Engines/FileScanEngine.swift` (`LargeVideoResultCache`), `iOSCleanup/Utilities/PHAsset+FileSize.swift` (`AssetFileSizeRepository`), `iOSCleanup/Engines/PhotoMLBridge.swift`, `CLAUDE.md`.
- Tests: `iOSCleanupTests/DesignLintTests.swift`, `iOSCleanupTests/AppConfigurationTests.swift` (WS-02's file; **extend**, do not create). *New*: `iOSCleanupTests/PrivacySurfaceTests.swift`, `iOSCleanupTests/PhotoDuckLocalDataResetTests.swift`.

**Findings covered:** STORE-03 (P1, confirmed; merged: UI-23 confirmed), ML-11 (P2, confirmed), STORE-05 (P1, confirmed), STORE-11 (P2, confirmed; the automatic-alert behavior is device-only)
**Decisions applied:**
- **D-PRIVACY-URL:** `PhotoDuckLinks` holds reserved-TLD placeholders until the owner supplies the GitHub Pages domain and support mailbox. A skipped release-gate test enforces this.
- **D-ML:** the policy says learning is automatic, local-only and clearable. It never says "optional".
- **D-BACKUP:** the policy says PhotoDuck data is excluded from backups, and UserDefaults settings are backed up.
- **D-LIMITED-ACCESS:** the policy says limited sessions stay in memory and don't replace saved results.
- **D-UNDO:** the policy and copy say deletions go through Apple's confirmation to Recently Deleted.

### Goal
Every user, including purchasers, can open a Help & Privacy menu from Home. It holds Privacy Policy, Terms of Use, Restore Purchase, Contact Support, Storage & Data, Share Diagnostics and Reset Kept Photos. The policy text matches what the app actually stores and does, and the same text is published at a hosted URL. Storage & Data shows PhotoDuck's own footprint and clears every derived store in two taps. Clearing never touches the photo library, the entitlement, lifetime stats or kept-photo choices. No custom control before a system permission prompt says "Allow". The photo purpose string describes video, deletion, compression and copying, and iOS's automatic limited-access alert is suppressed.

### Current behavior (verified)
- **The policy is reachable only from the paywall.** `iOSCleanup/Views/PaywallView.swift:195-237`: `private struct PhotoDuckPrivacyPolicyView`, reached only via `NavigationLink("Privacy Policy")` at `:161-164`. Every path to the paywall is guarded by `!purchaseManager.isPurchased`: `HomeView.swift:276` (Unlock), `PhotoResultsView.swift:111`, `FileResultsView.swift:769` and `PhotoGroupDetailView.swift:107` (paywall closure). Purchasers can never reach the policy.
- **The policy text is wrong and out of date.** `PaywallView.swift:211-214` says "optional learning data remain in the app container". It does not mention diagnostics, notifications, the Live Activity, Export to Files, compression, backups or Limited access. It reads "Last updated July 23, 2026". Terms is a private constant (`:7`).
- **Home's menu holds only diagnostics.** `iOSCleanup/Views/HomeView.swift:229-254`: the top-bar `Menu` contains only "Share Diagnostics…" (36×36 label, `accessibilityLabel("Support and diagnostics")`). There is no `mailto` or support URL anywhere (grep).
- **Reset APIs exist but are unused.** `PhotoMLStore.deleteAllData` (`:1327-1342`), `PhotoFeedbackStore.clear()` (`:319-330`, which also rebuilds the profile from `[]`) and `PhotoPreferenceProfileStore.reset()` (`:60-64`) have zero production callers. Nothing shows PhotoDuck's own footprint.
- **The other stores have no clear API.** `LargeVideoResultCache` (`FileScanEngine.swift:294-…`) has only `save` and `remove(assetIdentifier:)`; at baseline `save` suspends on a detached write, which is actor-reentrant. **After WS-27.1/WS-42** writes are synchronous `commit`s behind a `revision` guard with a single-flight `load()`, and removal is `remove(assetIdentifiers:)`. `AssetFileSizeRepository` (`PHAsset+FileSize.swift:325-…`) has no clear. `PhotoAnalysisCache` has no delete; WS-17 added its read memo and `purgeMemo()`.
- **Every scan task is private.** `scanTask`, `supportingScansTask`, `activePhotoScanEngine` and `activeScanID` are `private` in `HomeViewModel` (`:266-270`). The cancellation branch (`:1244-1265`) saves a checkpoint only if `activeScanID == scanID`, so fencing lets a clear suppress it. At baseline the video scan is `scanFiles(force:)` (`:1371`), called from untracked Tasks such as `PhotoDuckShellView.swift:82`, and it saves `largeVideoResultCache` at `:1412`. **After WS-27:** `scanFiles(trigger:)` runs `LargeVideoScanController.run(budget:)`, which is single-flight through `currentPassTask` and fenced by `passGeneration`. `invalidateAndCancelCurrentPass()` bumps the generation, cancels the pass and awaits it (contract 24). WS-27.6 also adds a private `userScanTask` (videos-first pre-pass, then `scanPhotos`), and WS-28 renames the run lock `isPhotoRunActive`.
- **"Allow" labels appear before system prompts.**
  - `OnboardingView.swift:100`: `DuckPrimaryButton(title: "Allow Photos Access")` precedes `PHPhotoLibrary.requestAuthorization`.
  - `OnboardingView.swift:86`: body text starts "Allow access so PhotoDuck…".
  - `HomeView.swift:498`: `Button("Allow")` precedes `requestPhotoAccess()`.
  - `HomeView.swift:167`: `Button("Allow Completion Alerts")` precedes `UNUserNotificationCenter.requestAuthorization`.
  - `HomeViewModel.swift:654` returns "Allow access" as a hero *metric value*, not a button; its CTA opens Settings (`HomeView.swift:428-429`).
- **The purpose string understates use.** `iOSCleanup/Info.plist:27-28` reads "PhotoDuck needs photo access to find similar images and let you review cleanup choices on your device." There is no `PHPhotoLibraryPreventAutomaticLimitedAccessAlert`, although Home's Limited banner offers "Manage", which calls `presentLimitedLibraryPicker` (`HomeView.swift:470-473`, `HomeViewModel.swift:~1632-1643`).
- **Restore reports through published strings.** `PurchaseManager.restore()` (`Store/PurchaseManager.swift:206-222`) publishes `statusMessage` or `errorMessage` and `isLoading`.

### Implementation plan

**WS-48.1 — Links, an internal PrivacyPolicyView, accurate content, hosted copy**
- **Why:** App Review 5.1.1(i) requires the policy to be easy to reach, and App Store Connect needs a URL. Today's text is inaccurate.
- **Change:**
  1. New file `iOSCleanup/Utilities/PhotoDuckLinks.swift`:
     ```swift
     enum PhotoDuckLinks {
         // D-PRIVACY-URL: reserved .example placeholders until the owner supplies the GitHub Pages
         // domain and support mailbox. PrivacySurfaceTests.testLinksAreOwnerSupplied skips while these
         // are placeholders; WS-58's submission gate requires it to run and pass.
         static let privacyPolicy = URL(string: "https://photoduck.example/privacy")!
         static let supportPage = URL(string: "https://photoduck.example/support")!
         static let supportEmailAddress = "support@photoduck.example"
         static var supportEmail: URL { URL(string: "mailto:\(supportEmailAddress)")! }
         static let termsOfUse = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
         static var hasOwnerSuppliedValues: Bool {
             !(privacyPolicy.host ?? "").hasSuffix(".example") && !supportEmailAddress.hasSuffix(".example")
         }
     }
     ```
  2. New file `iOSCleanup/Views/PrivacyPolicyView.swift` containing:
     - `struct PrivacyPolicySection: Identifiable, Equatable { let title: String; let body: String; var id: String { title } }`.
     - `enum PrivacyPolicyContent { static let lastUpdated: String; static var sections: [PrivacyPolicySection] }`. Set `lastUpdated` to the merge date, e.g. "Last updated October 2026".
     - Internal `struct PrivacyPolicyView: View`. It renders `sections` with today's styling (`policySection` helper, duck fonts, `Color.surface`), then the date, then `Link("Read this policy online", destination: PhotoDuckLinks.privacyPolicy)` and the selectable text `PhotoDuckLinks.supportEmailAddress`.
  3. Delete `PhotoDuckPrivacyPolicyView` from `PaywallView.swift`. The paywall's `NavigationLink` pushes `PrivacyPolicyView()`, and `termsURL` becomes `PhotoDuckLinks.termsOfUse`. There is no visual change to the paywall.
  4. Use this content in `sections`, verbatim apart from interpolation. `N` is `PhotoEmbeddingCachePolicy.capacity` formatted with `.number.locale(Locale(identifier: "en_US"))`, and `EMAIL` is `PhotoDuckLinks.supportEmailAddress`.

     | Title | Body |
     |---|---|
     | The short version | PhotoDuck works entirely on your iPhone. It has no account, no servers, and no advertising or analytics code. Your photos, videos and the results of analyzing them never leave your iPhone unless you choose to share or export something. |
     | Photos and videos | PhotoDuck uses photo library access to find duplicate, similar, blurry and screenshot photos and large videos. It deletes, compresses or copies only the items you choose. Every deletion shows Apple's confirmation, and deleted items stay in Recently Deleted for 30 days. Compress & Replace saves a smaller copy and removes the original only after you confirm. If you share only some photos with PhotoDuck (Limited access), results cover just those photos, are kept in memory until you close the app, and never replace results saved with full access. |
     | What PhotoDuck keeps on your iPhone | Saved scan results (groups, categories and the photo list with dates and sizes), a scan cache of image features for up to your N most recent photos (numbers that describe how a photo looks, not copies of your photos), your review choices and the preferences learned from them (used only to order suggestions), the photos you chose to keep, and file-size measurements. This data is excluded from iCloud and computer backups, is deleted when you delete PhotoDuck, and can be cleared at any time in Help & Privacy › Storage & Data. Kept-photo choices are reset separately with Reset Kept Photos. App settings, such as onboarding progress, your purchase status and your lifetime cleanup totals, are stored in the app's settings and are included in your backups. |
     | Diagnostics | PhotoDuck keeps a small log of scan events (states, counts, timings and error codes) on your iPhone for up to 7 days. It never includes photos, videos, filenames, photo identifiers or locations. It is sent to no one unless you choose Share Diagnostics and pick where to send it. |
     | Notifications and Live Activities | If you allow notifications, PhotoDuck schedules local alerts when a scan finishes. Export progress can appear as a Live Activity on your Lock Screen. Both are created on your iPhone; PhotoDuck does not use push servers. |
     | Export to Files | Export copies original files to a folder you choose. If that folder is in iCloud Drive or another cloud service, that service syncs the copies under its own terms. PhotoDuck offers to delete originals only after it has verified the copies. |
     | Purchases | Apple processes purchases. PhotoDuck only learns whether the unlock is active and keeps that status on your iPhone so paid features work offline. PhotoDuck never sees your payment details. |
     | Changes and contact | If this policy changes, the new version appears in the app and online with a new date. Questions? Email EMAIL. |

  5. New file `docs/privacy-policy.md`: a GitHub Pages-ready page with `# PhotoDuck Privacy Policy`, the date, then `## <title>` and the body for every section, verbatim with interpolations resolved. Add a comment at the top: "Source of truth is PrivacyPolicyContent; PrivacySurfaceTests fails if this file diverges."
- **Edge cases:**
  - When the owner supplies real values, they update `PhotoDuckLinks` **and** the markdown together; the sync test forces that.
  - Don't claim the features are irreversible. The table deliberately says "not copies of your photos" only.

**WS-48.2 — Help & Privacy menu on Home**
- **Change:**
  1. New file `iOSCleanup/Views/Home/HelpAndPrivacyMenu.swift`:
     ```swift
     struct HelpAndPrivacyMenu: View {
         @ObservedObject var viewModel: HomeViewModel
         @EnvironmentObject private var purchaseManager: PurchaseManager
         let isPreparingDiagnostics: Bool
         let onShareDiagnostics: () -> Void           // HomeView keeps its disclosure dialog + share flow
         @State private var sheet: HelpSheet?
         @State private var restoreMessage: String?
         enum HelpSheet: String, Identifiable { case privacy, storage; var id: String { rawValue } }

         var body: some View {
             Menu {
                 Button { sheet = .privacy } label: { Label("Privacy Policy", systemImage: "hand.raised") }
                 Link(destination: PhotoDuckLinks.termsOfUse) { Label("Terms of Use", systemImage: "doc.text") }
                 Button { Task { await restore() } } label: { Label("Restore Purchase", systemImage: "arrow.clockwise") }
                     .disabled(purchaseManager.isLoading)
                 Link(destination: PhotoDuckLinks.supportEmail) { Label("Contact Support", systemImage: "envelope") }
                 Divider()
                 Button { sheet = .storage } label: { Label("Storage & Data", systemImage: "internaldrive") }
                 Button(action: onShareDiagnostics) { Label("Share Diagnostics…", systemImage: "square.and.arrow.up") }
                 // WS-12's "Reset Kept Photos…" item + its confirmation move here unchanged.
             } label: { /* questionmark.circle, 44×44 frame, Color.surface circle; ProgressView while isPreparingDiagnostics */ }
             .accessibilityLabel("Help and privacy")
             .accessibilityHint("Privacy policy, restore purchase, support, storage and diagnostics")
             .sheet(item: $sheet) { item in /* .privacy: NavigationStack { PrivacyPolicyView() } + Done; .storage: StorageAndDataView(viewModel:) */ }
             .alert("Restore Purchase", isPresented: Binding(get: { restoreMessage != nil }, set: { if !$0 { restoreMessage = nil } })) {
                 Button("OK", role: .cancel) { restoreMessage = nil }
             } message: { Text(restoreMessage ?? "") }
         }
         private func restore() async {
             await purchaseManager.restore()
             restoreMessage = purchaseManager.errorMessage ?? purchaseManager.statusMessage
                 ?? (purchaseManager.isPurchased ? "Your PhotoDuck unlock is active on this iPhone." : "No PhotoDuck purchase was found for this Apple Account.")
         }
     }
     ```
  2. `HomeView.topBar`: replace the inline `Menu { … }` (`:229-250` and its modifiers) with `HelpAndPrivacyMenu(viewModel: viewModel, isPreparingDiagnostics: isPreparingDiagnostics, onShareDiagnostics: { showDiagnosticsDisclosure = true })`. Keep the diagnostics disclosure dialog, `prepareDiagnosticReport()` and the share sheet where they are.
  3. Move WS-12's temporary "Reset Kept Photos (n)" item. Per README §9 contract 22 and WS-26.4, it sits in the gear/overflow `Menu` in `PhotoDuckShellView.swift`, directly below "Scan Again". Move it with its confirmation ("Reset kept photos?", `keepDecisions.reset()`) and its own `@State` flag into this menu, keeping its disabled-when-`n == 0` rule. Confirm the location first with `grep -rn "Reset Kept\|Reset kept" iOSCleanup/Views`. Afterwards that grep matches only `HelpAndPrivacyMenu.swift`. Leave the gear menu otherwise unchanged, including "Scan Again" and its rescan confirmation.
- **Edge cases:**
  - `Menu` items can't host sheets that outlive the menu, so the sheets attach to the `Menu` view itself, as sketched.
  - The `mailto:` `Link` does nothing visible when Mail is unavailable; the policy's contact section shows the address as selectable text.
  - Restore works for purchasers too. The existing `restore()` semantics (a definitive "no purchase" may downgrade) are unchanged (invariant 23).

**WS-48.3 — Footprint measurement**
- **Change:** New file `iOSCleanup/Utilities/PhotoDuckStorageFootprint.swift`:
  ```swift
  enum PhotoDuckStorageFootprint {
      struct Measurement: Equatable, Sendable {
          let scanCacheBytes: Int64          // Library/Caches/PhotoDuck
          let savedDataBytes: Int64          // Library/Application Support/PhotoDuck
          var totalBytes: Int64 { scanCacheBytes + savedDataBytes }
      }
      static func allocatedBytes(under root: URL, fileManager: FileManager = .default) -> Int64 {
          let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
          guard let e = fileManager.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [],
                                               errorHandler: { _, _ in true }) else { return 0 }
          var total: Int64 = 0
          for case let url as URL in e {
              guard let v = try? url.resourceValues(forKeys: keys), v.isRegularFile == true else { continue }
              total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
          }
          return total
      }
      static func measure(applicationSupportRoot: URL, cachesRoot: URL, fileManager: FileManager = .default) -> Measurement
      static func measureDefault() async -> Measurement      // Task.detached(priority: .utility) over the two PhotoDuck roots
  }
  ```
  Do not skip hidden files; atomic-write temporaries start with ".". Do not use volume-capacity keys, which are required-reason APIs; allocated size is not.
- **Edge cases:** A missing root counts as 0. `tmp` is not counted: it holds in-flight compression and export files owned by their engines. The sheet footnote says so.

**WS-48.4 — Clear local data (stores, facade, UI)**
- **Why:** Users must be able to see and remove what PhotoDuck keeps without deleting the app (ML-11). The policy promises it.
- **Change:**
  1. Add a clear method to each store. Each is small and lives in its own type's file:
     - `PhotoMLBridge.clearScanCache() async throws`:
       - Cancel `bufferFlushTask` and empty `bufferedScanCacheWrites` (and any metadata buffer).
       - Then `try await store.open(); try await store.deleteAllData(); try await store.compact()`.
       - `deleteAllData` (updated in WS-46) deletes from `photo_embeddings` and `photo_asset_analysis`, plus the training tables when present.
       - Add `PhotoMLStore.compact()` = `PRAGMA incremental_vacuum` + `PRAGMA wal_checkpoint(TRUNCATE)`, ignoring busy. The file shrinks because WS-46 created it with incremental auto-vacuum. Do not depend on WS-47's `resetStore`.
     - `PhotoAnalysisCache.removeAllSnapshots() async`:
       - Set `pendingSnapshot = nil`.
       - If `isWriting`, await an idle signal. Add `private var idleWaiters: [CheckedContinuation<Void, Never>]`, resumed where `isWriting = false`.
       - Resume every `flushWaiter` whose generation was never committed with `false`.
       - Delete the primary and backup files, call WS-17's `purgeMemo()`, and set `hasHydratedDiskOrdering = true`.
       - Keep `latestGeneration`; generations stay monotonic in memory.
       - Keep WS-47's health publishing: a successful removal publishes nothing new, and a later write publishes as usual.
     - `LargeVideoResultCache.removeAll()` (synchronous on the actor, like WS-27.1's `commit`):
       - WS-27.1 made writes synchronous `commit`s on the actor, so there is no in-flight write to await. Do not add an `inFlightWrite` task.
       - Bump `revision`, set `cachedSnapshot = nil` and `hasLoaded = true`, and remove the file. The revision bump makes any pending single-flight `load()` discard its decoded result, following WS-27.1's `revision == pending.startRevision` rule.
     - `AssetFileSizeRepository.removeAll() async`: `await loadIfNeeded()`, `entries.removeAll()`, await `writeTask`, then remove the file. WS-54 (chapter 11) later adds a delayed write and extends this method to cancel it.
     - `PhotoFeedbackStore.clear()` already exists; it also rebuilds the profile from `[]`. `PhotoPreferenceProfileStore.reset()` already exists; call it anyway so the profile file is rewritten empty even if the feedback store's profile reference differs.
  2. New file `iOSCleanup/Engines/PhotoDuckLocalDataReset.swift`:
     ```swift
     protocol LocalDataClearing: Sendable {
         nonisolated var localDataClearingName: String { get }
         func clearLocalData() async throws
     }
     struct PhotoDuckLocalDataReset: Sendable {
         struct Outcome: Equatable, Sendable { let failedTargets: [String]; var succeeded: Bool { failedTargets.isEmpty } }
         let targets: [any LocalDataClearing]          // order: ML cache, snapshot, videos, sizes, feedback, profile
         func clearAll() async -> Outcome {
             var failed: [String] = []
             for target in targets {
                 do { try await target.clearLocalData() } catch { failed.append(target.localDataClearingName) }
             }
             return Outcome(failedTargets: failed)
         }
     }
     extension PhotoMLBridge: LocalDataClearing { nonisolated var localDataClearingName: String { "scan_cache" }
                                                  func clearLocalData() async throws { try await clearScanCache() } }
     // …same one-liners for PhotoAnalysisCache ("scan_results"), LargeVideoResultCache ("large_videos"),
     // AssetFileSizeRepository ("file_sizes"), PhotoFeedbackStore ("review_history"), PhotoPreferenceProfileStore ("preferences").
     ```
     This file must not import Photos or reference `PHPhotoLibrary`, `PHAssetChangeRequest`, `PurchaseManager`, `DeletionManager`, `UserKeepDecisionStore`, `PhotoDuckDiagnosticLog` or `UserDefaults`. A lint test enforces this.
  3. `HomeViewModel` facade: about 40 lines. Put it in `HomeViewModel.swift` only because the scan tasks are private; put any logic that doesn't need private state in the new files.
     - **Dependencies.** WS-07's `HomeViewModelDependencies` already defines `fileSizeRepository: AssetFileSizeRepository`; reuse it and do not add a second field. WS-47 (a dependency of this workstream) already added `feedbackStore`. Add only `var preferenceProfileStore: PhotoPreferenceProfileStore = .shared`, using WS-07's defaulted-field pattern (contract 16). In the same PR, give `makeIsolatedDependencies` a temp-root `PhotoPreferenceProfileStore`.
     - Then add:
     ```swift
     /// Storage & Data › Clear. Never touches the photo library, entitlement, lifetime stats,
     /// kept-photo choices, export album or diagnostics.
     func clearLocalData() async -> PhotoDuckLocalDataReset.Outcome {
         await stopAllRunsForLocalDataClear()
         let outcome = await PhotoDuckLocalDataReset(targets: [
             dependencies.mlBridge, dependencies.analysisCache, dependencies.largeVideoCache,
             dependencies.fileSizeRepository, dependencies.feedbackStore, dependencies.preferenceProfileStore
         ]).clearAll()
         resetResultsAfterLocalDataClear()     // collections via WS-16's PhotoResultsStore/AnalysisCheckpointState,
                                               // largeVideoScanController.resetAfterLocalDataClear() (retainedVideos, WS-42's
                                               // inventory, WS-27's lastScannedAt/hasCompletedVideoScan/deferred flag),
                                               // counts; scanState/fileScanState = .idle;
                                               // CleanupStateReconciler's scalar reset (WS-15) with NO "couldn't be restored" message
         persistCleanupState()                 // WS-15's CleanupStateStore now holds the idle state
         recordDiagnostic(.localDataCleared(failedTargetCount: outcome.failedTargets.count))
         return outcome
     }
     private func stopAllRunsForLocalDataClear() async {
         let engine = activePhotoScanEngine
         activeScanID = nil                    // fencing (invariant 13): worker hops and the cancel-path checkpoint now no-op
         libraryChangedDuringRun = false       // WS-21 flag: the end of the cancelled video pass (WS-27 R4) must not
                                               // run runPostRunFollowUpIfNeeded() and auto-start a scan after the clear
         userScanTask?.cancel()                // WS-27.6 videos-first sequence: must not go on to scanPhotos
         await largeVideoScanController.invalidateAndCancelCurrentPass()   // WS-27 passGeneration fence (contract 24)
         await engine?.pause()                 // WS-27: pause(reason: .user, quiesceTimeout: nil); flushes buffered ML writes
         let tasks = [userScanTask, scanTask, supportingScansTask].compactMap { $0 }
         tasks.forEach { $0.cancel() }
         for task in tasks { await task.value }
         userScanTask = nil; scanTask = nil; supportingScansTask = nil; activePhotoScanEngine = nil
         isVideoPrePassRunning = false
         isPhotoRunActive = false              // WS-28's name for the run lock (was isFinalizingPhotoScan)
     }
     ```
     - **Video scan.** Use WS-27's fence, `largeVideoScanController.invalidateAndCancelCurrentPass()`. It bumps `passGeneration`, cancels `currentPassTask` and awaits it, and every cache write and published result in `run` is fenced by the generation. A pass that started before the clear can never write `large-video-results.json` or publish results after it. Do **not** add a separate `videoScanGeneration`.
     - **Pre-pass sequence.** WS-27.6's `userScanTask` runs the video pre-pass and then `scanPhotos`, and does not check cancellation. Add `guard !Task.isCancelled else { self.isVideoPrePassRunning = false; self.userScanTask = nil; return }` immediately before its `scanPhotos` call, so a clear during the pre-pass cannot start a photo scan afterwards.
     - **Controller reset.** Add `LargeVideoScanController.resetAfterLocalDataClear()`. It clears `retainedVideos` (WS-42; `largeFiles`, `screenRecordings` and `videoInventory` re-derive), `lastScannedAt`, `hasCompletedVideoScan`, `scannedTotalVideoCount`, `restoredMissingResultCount` and the deferred flag (WS-27), and sets `fileScanState = .idle`. It never starts a scan (WS-16 invariant).
     - **Diagnostic.** Add the `localDataCleared(failedTargetCount:)` factory next to the other diagnostic factories.
     - **Auto-start.** After clearing, Home shows the idle state (`.idlePrompt`; after WS-45.3 the metric reads "Not scanned yet" and the CTA "Start scan"). Do **not** auto-start a scan, and do not set WS-26's `pendingFirstScan` flag.
  4. New file `iOSCleanup/Views/Settings/StorageAndDataView.swift`, a `NavigationStack` sheet titled "Storage & Data" with a Done button. Use `DuckCard`, `duck*` fonts, `.textPrimary/.textSecondary/.danger` and `DuckRadius`.
     - **Headline:** "PhotoDuck is using X on this iPhone", with WS-31's `ByteText.stat(_:)` (decimal, the Settings style), not an ad-hoc `ByteCountFormatter`. Show a `ProgressView` while measuring. `.task { footprint = await PhotoDuckStorageFootprint.measureDefault() }`.
     - **Rows:** "Scan cache" (`scanCacheBytes`) and "Scan results & preferences" (`savedDataBytes`).
     - **Explanation:** "These files are created by PhotoDuck, stay on this iPhone and aren't included in backups. Your photos and videos aren't stored here."
     - **Destructive button:** "Clear Scan Data & Learned Preferences" opens `.confirmationDialog`:
       - Title: "Clear PhotoDuck's data?"
       - Message: "This removes saved scan results, the scan cache, file-size measurements and learned preferences. Your photos, your purchase, your cleanup totals and the photos you chose to keep aren't affected. You'll need to scan again." If `viewModel.scanState == .scanning || .paused`, append " The current scan will stop."
       - Buttons: "Clear Data" (destructive) and Cancel.
     - **While clearing:** disable the button and show progress. Afterwards, re-measure and show "Cleared." or "Some data couldn't be cleared. Try again." when the outcome failed.
     - **Footnote:** "The diagnostic log (under 1 MB, kept for 7 days) and temporary files from exports or compression in progress aren't included."
     - Leave a `// WS-63: "Similar photo matching" section goes here` marker between the usage card and the Clear card.
- **Edge cases:**
  - **Scan races.** A cancelled engine may still flush one ML batch after `clearAll`. The prior `pause()` flush makes that empty in practice, and the rows would be valid analyses anyway. The snapshot and large-video files, however, must never reappear, and fencing plus the awaits guarantee that.
  - **Export and compression.** Exports and compression in flight are unaffected; their files are not in the cleared stores.
  - **Deletion in flight.** A deletion in flight is unaffected. Lifetime stats are recorded by `DeletionManager` into UserDefaults, which the clear never touches.
  - **Fresh launch after a clear.** WS-15's reconciler must not show "Your previous results couldn't be restored" on the next launch, because the scalars were reset to idle.

**WS-48.5 — Permission primer labels (STORE-05)**
- **Change:**
  - `OnboardingView.swift`:
    - Line 100: `"Allow Photos Access"` becomes `"Continue"`. The behavior and WS-26's `pendingFirstScan` flag are unchanged.
    - Line 86: the text becomes "PhotoDuck compares photos on your iPhone to prepare review groups. You can share all your photos or just some."
    - "Skip for now" stays.
  - `HomeView.swift`:
    - Line 498: `Button("Allow")` becomes `Button("Continue")`.
    - Line 167: `"Allow Completion Alerts"` becomes `"Continue"`. "Not Now" stays.
  - No visual changes (design handoff pending).
- **Edge cases:** `HomeViewModel`'s "Allow access" hero metric is not a control and leads to Settings, not a system prompt, so leave it to WS-31's copy work. The lint only targets controls.

**WS-48.6 — Purpose string and limited-access alert (STORE-11)**
- **Change:** `Info.plist`:
  - `NSPhotoLibraryUsageDescription` becomes "PhotoDuck analyzes your photos and videos on this iPhone to find duplicates, similar shots and large files. It deletes, compresses or copies only the items you choose, and iOS asks you to confirm every deletion."
  - Add `<key>PHPhotoLibraryPreventAutomaticLimitedAccessAlert</key><true/>`. This completes UI-17 from WS-20.
  - Keep `NSPhotoLibraryAddUsageDescription`.

**WS-48.7 — Docs and owner steps**
- `CLAUDE.md`:
  - Line 67: the paywall "includes an in-app privacy policy" becomes: Home › Help & Privacy (all users) and the paywall open `PrivacyPolicyView`. `PrivacyPolicyContent` is the source for `docs/privacy-policy.md`, which is published at `PhotoDuckLinks.privacyPolicy` (placeholder until the owner supplies it, D-PRIVACY-URL).
  - Add a Key constraints bullet: "Storage & Data › Clear removes only derived stores (ML cache, snapshots, large-video results, file sizes, feedback, preferences) and never the photo library, entitlement, lifetime stats, kept photos, export album or diagnostics."
- In the PR summary, list the owner steps:
  1. Publish `docs/privacy-policy.md` on GitHub Pages.
  2. Replace the placeholders in `PhotoDuckLinks` and the markdown.
  3. Enter the Privacy Policy URL and Support URL in App Store Connect.
  4. Answer App Privacy with "Data Not Collected".

### Tests
All run in the simulator unless noted.
- **`PrivacySurfaceTests`** (new; source-scanning tests use the `#filePath` pattern and `XCTSkip` when sources are absent)
  - `testLinksAreWellFormed`: `privacyPolicy.scheme == "https"`, `supportEmail.scheme == "mailto"`, `termsOfUse.host == "www.apple.com"`.
  - `testLinksAreOwnerSupplied`: `try XCTSkipUnless(PhotoDuckLinks.hasOwnerSuppliedValues, "Owner must supply the hosted domain and support email (D-PRIVACY-URL)")`. This is the WS-58 gate.
  - `testPolicyNeverCallsLearningOptional`: the joined section text has no "optional" (case-insensitive).
  - `testPolicyCoversRequiredTopics`. The joined text contains:
    - "excluded from iCloud and computer backups"
    - "Limited access"
    - "7 days"
    - "Share Diagnostics"
    - "Live Activity"
    - "Export"
    - "Recently Deleted"
    - "Storage & Data"
    - `PhotoDuckLinks.supportEmailAddress`
    - the formatted `PhotoEmbeddingCachePolicy.capacity`
  - `testHostedPolicyMarkdownMatchesInAppSections`: read `docs/privacy-policy.md` and assert it contains `"## \(title)"` and `body` verbatim for every section, plus `lastUpdated`.
  - `testPrivacyPolicyReachableOutsidePaywall`: `PrivacyPolicyView(` appears in `Views/Home/HelpAndPrivacyMenu.swift`, and `PhotoDuckPrivacyPolicyView` appears nowhere.
- **`PhotoDuckStorageFootprintTests`** (inside `PrivacySurfaceTests` or its own file)
  - `testMeasuresAllocatedBytesAcrossRoots`:
    - Temp roots with files of 10,000 and 100,000 bytes, plus a hidden `.tmp` file of 5,000 bytes.
    - The result is ≥ 115,000 and ≤ 115,000 + 64 KiB.
    - `scanCacheBytes` and `savedDataBytes` are attributed to the right roots.
  - `testMissingRootCountsAsZero`.
- **`PhotoDuckLocalDataResetTests`** (new)
  - Fixtures:
    - Temp stores: `PhotoMLStore(directoryURL:collectsTrainingData: true)` + bridge, `PhotoAnalysisCache(directoryURL:)`, `LargeVideoResultCache(directoryURL:)`, `AssetFileSizeRepository(fileURL:)`, and `PhotoPreferenceProfileStore(directoryURL:)` + `PhotoFeedbackStore(directoryURL:profileStore:persistence:)`.
    - Seed each with data.
    - A `UserDefaults(suiteName:)` holding the lifetime-stat keys `DeletionManager` uses, `isPurchased`, `hasOnboarded` and an export-album key.
  - `testClearAllEmptiesEveryDerivedStore`. After `clearAll()`:
    - `stats()` counts are 0.
    - `loadSnapshot() == nil`, and both snapshot files are absent.
    - `LargeVideoResultCache.load() == nil`.
    - The size repository's `debugEntryCount() == 0`.
    - `loadAllEvents()` is empty, and the profile totals are 0.
    - `outcome.succeeded`.
  - `testClearAllLeavesUserDefaultsUntouched`: every seeded defaults key is unchanged.
  - `testClearAllContinuesAfterOneTargetFails`: a stub target that throws is in the middle, the later targets are still cleared, and `failedTargets == ["stub"]`.
  - `testResetSourceHasNoPhotoLibraryOrEntitlementReferences`: a source lint over `Engines/PhotoDuckLocalDataReset.swift` for the forbidden symbols listed in WS-48.4.
  - `testRemoveAllSnapshotsDropsPendingWriteAndResumesWaiters`: `scheduleSnapshot(gen N)` then `removeAllSnapshots()`. No file, and a subsequent `saveSnapshot` works and loads.
  - `testLargeVideoRemoveAllWinsOverPendingLoadAndPriorSave`: `save(...)` then `removeAll()` leaves no file, and `load()` returns nil. With a file present, `async let l = cache.load()` followed by `await cache.removeAll()` gives `await l == nil` and no file, per WS-27.1's revision rule.
  - `testSQLiteFileShrinksAfterClearScanCache`: 500 embeddings, then clear. `databaseSizeBytes` is below 10% of before.
- **`HomeViewModelTests`** (WS-07 harness)
  - `testClearLocalDataStopsScanAndReturnsToIdle`:
    1. A fixture analyzer gated by an `AsyncGate` (no sleeps) holds the scan mid-batch.
    2. Call `await vm.clearLocalData()`, then open the gate.
    3. `scanState == .idle` and `photoGroups.isEmpty`.
    4. The injected snapshot files are absent **after** the worker has finished.
    5. The lifetime-stat and entitlement keys in the temp defaults are unchanged, and the persisted cleanup state is idle.
  - `testClearLocalDataNeverCallsPhotoLibraryDeleter`: WS-03's `PhotoLibraryDeleting` spy records zero calls.
  - `testClearLocalDataFencesInFlightVideoPass` (contract 24): park the video resolver mid-pass (WS-27's harness stub), call `await vm.clearLocalData()`, then release the resolver. The large-video results file is absent, `retainedVideos` is empty, and `fileScanState == .idle`.
  - `testClearLocalDataDuringVideoPrePassStartsNoPhotoScan`: start `startPhotoScan(from: .homePrimaryCTA)` with no video cache, and park the pre-pass. Clear, then release. The `makePhotoScanEngine` factory is never called, and `isVideoPrePassRunning == false`.
- **`DesignLintTests`**
  - `testNoPermissionPrimerControlSaysAllow`: `scanViews` with the regex `(Button|DuckPrimaryButton|DuckSecondaryButton|Label)\((title: )?"Allow` has no offenders, and there is no allowlist.
- **`AppConfigurationTests`** (extends WS-02's existing file, which is hosted and reads `Bundle.main`. WS-58 extends it later. Add these two source-parsing tests beside WS-02's; they read `iOSCleanup/Info.plist` via `#filePath` with `PropertyListSerialization`)
  - `testPhotoPurposeStringDescribesVideosAndDeletion`: `NSPhotoLibraryUsageDescription`, lowercased, contains "video", "delet" and "compress".
  - `testAutomaticLimitedAccessAlertIsSuppressed`: `PHPhotoLibraryPreventAutomaticLimitedAccessAlert == true`.
- **Device-only:** suppression of the automatic limited-access alert, the Mail compose from Contact Support, and the Restore flow against the sandbox (see Device QA).

### Acceptance criteria
- [ ] With `isPurchased == true`, Home › Help & Privacy opens each of: Privacy Policy, Terms, Restore, Contact Support, Storage & Data, Share Diagnostics and Reset Kept Photos. The paywall still links the same `PrivacyPolicyView`.
- [ ] The policy text matches the table in WS-48.1, `docs/privacy-policy.md` matches it (test), and the word "optional" is gone.
- [ ] `PhotoDuckLinks` is the only place URLs and the support address are defined (`grep -rn "stdeula\|mailto:" iOSCleanup` shows only that file). `testLinksAreOwnerSupplied` is skipped until the owner supplies values, and WS-58 must see it run.
- [ ] Storage & Data shows a total that matches the sum of `Library/Caches/PhotoDuck` and `Library/Application Support/PhotoDuck` allocated sizes.
- [ ] Clear empties every derived store. It leaves the photo library, entitlement, lifetime stats, kept photos, export album, onboarding and diagnostics untouched. It stops any scan, including a videos-first pre-pass or an in-flight video pass (fenced by WS-27's `invalidateAndCancelCurrentPass()`), and no snapshot or large-video file reappears (tests above). `grep -rn "videoScanGeneration" iOSCleanup` finds nothing.
- [ ] "Reset Kept Photos" appears only in Help & Privacy (`grep -rn "Reset Kept\|Reset kept" iOSCleanup/Views` matches only `HelpAndPrivacyMenu.swift`). The gear menu keeps "Scan Again".
- [ ] `HomeViewModelDependencies` gains only `preferenceProfileStore`, and still has exactly one `fileSizeRepository` field.
- [ ] No control under `Views/` whose label starts with "Allow" (lint).
- [ ] `Info.plist` has the new purpose string and `PHPhotoLibraryPreventAutomaticLimitedAccessAlert = true` (test).
- [ ] The full suite is green with no new warnings. `CLAUDE.md` is updated, and the owner steps are listed in the PR.

### Device QA
Add to `docs/DEVICE_QA.md`:
1. **App Review path.** Sandbox-purchase the unlock, then open Home › Help & Privacy › Privacy Policy. The policy opens. Restore Purchase shows "Your PhotoDuck unlock is active on this iPhone."
2. **Contact Support.** With Mail configured, a compose sheet opens to the support address. Without Mail, nothing crashes and the address is visible in the policy.
3. **Storage & Data** after a full scan:
   - The total is within 5% of the container's `Library/Caches/PhotoDuck` + `Library/Application Support/PhotoDuck` sizes (Download Container). After a 50k scan, record it against the M3 budget of **≤ 160 MB** (README §9, contract 5). The authoritative measurement is WS-54's Device QA. If it is over budget, WS-46's capacity-lowering rule applies (steps of 2,500, minimum 5,000).
4. **Clear during a running scan:**
   1. Note the Photos app item count.
   2. Tap Clear › Clear Data.
   3. The scan stops and Home shows the idle state ("Not scanned yet" / "Start scan", after WS-45.3).
   4. The Photos count is unchanged, the Unlock state is unchanged, and the lifetime "Freed" totals are unchanged.
   5. Relaunch: no "couldn't be restored" message.
5. **Limited access:**
   1. Settings › Privacy › Photos › PhotoDuck › Limited.
   2. Relaunch PhotoDuck twice.
   3. iOS's automatic "Select More Photos / Keep Current Selection" alert does **not** appear.
   4. Home's Limited banner "Manage" opens the picker.
6. **Onboarding on a fresh install:**
   - The photo step's button reads "Continue", and the system prompt appears after tapping it.
   - The notification pre-prompt button reads "Continue".
   - The system photo prompt shows the new purpose string.
7. **Accessibility:** VoiceOver reads the Home menu as "Help and privacy" and every item is reachable. At the largest accessibility text size, Storage & Data scrolls and the Clear button is reachable.

### Pitfalls and out of scope
- **Clearing can race an active scan.** Always fence (`activeScanID = nil`) before cancelling, and await the tasks before clearing stores. Otherwise the cancellation branch or the completion path rewrites a snapshot after the clear. Never loosen the run-lock or completion-barrier rules (invariant 13).
- **`PhotoAnalysisCache.removeAllSnapshots` must keep invariant 14.** It must not reset `latestGeneration` or write anything, and it must resume every waiter so no `saveSnapshot` hangs.
- **Don't clear keep decisions or diagnostics.** Kept-photo choices are safety data for automation (invariant 7) and have their own reset. Diagnostics are the support channel.
- **Don't move or redesign the Paywall or Onboarding** beyond the link and label changes (invariant 29). Hit-target sizing for paywall links is WS-56 (chapter 12).
- **Keep `HomeView.swift` and `HomeViewModel.swift` edits minimal:** a top-bar swap, two label changes, a facade method and a stop helper. WS-49 (chapter 11) lands later and moves `activeScanID`, the scan tasks and the run lock into `PhotoScanCoordinator`. Keep `stopAllRunsForLocalDataClear` one self-contained private method, so WS-49 can move it verbatim; `clearLocalData()` itself stays in `HomeViewModel` (WS-49's table keeps Storage & data in the facade).
- **Later workstreams must keep this working:**
  - WS-54 (chapter 11) must keep `PhotoAnalysisCache.removeAllSnapshots()` and extends `AssetFileSizeRepository.removeAll()` to cancel its delayed write.
  - WS-62 (chapter 13) adds `VideoInventoryCache` to the `PhotoDuckLocalDataReset` targets in `clearLocalData()`, and makes sure `PhotoDuckStorageFootprint` counts it (contract 18).
  - WS-63 fills the `StorageAndDataView` marker.
- **Out of scope here:**
  - "Similar photo matching" presets belong to WS-63 (chapter 13) and live in `StorageAndDataView`.
  - App Review notes and the final submission gate belong to WS-58 (chapter 12).
  - The hero "Allow access" metric copy belongs to WS-31 (chapter 07).
  - A toggle to disable learning isn't planned. D-ML and D-PREFS make it local, priority-only and clearable, which the policy states.
- **Reconciliation:**
  - L17: `AppConfigurationTests.swift` is WS-02's file; this workstream extends it.
  - L22: "Reset Kept Photos" moves from the gear menu, below "Scan Again", into Help & Privacy.
  - L24 and the ch06 names: the Clear uses WS-27's `LargeVideoScanController.invalidateAndCancelCurrentPass()`/`passGeneration` fence instead of a new `videoScanGeneration`. It also cancels WS-27.6's `userScanTask`, guarded so it cannot start `scanPhotos`, and clears `isPhotoRunActive` (WS-28's name).
  - `LargeVideoResultCache.removeAll()` follows WS-27.1's synchronous-commit and revision rules.
  - L16 and the lead: `fileSizeRepository` already exists in WS-07's `HomeViewModelDependencies` and is reused. Only `preferenceProfileStore` is added, as a defaulted field. `feedbackStore` comes from WS-47, which is now a dependency and lands first.
  - L5: Device QA uses the 160 MB budget.
  - L18: WS-62 adds its `VideoInventoryCache` target.

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| STORE-03 | confirmed | The private policy view is reachable only inside the paywall, every paywall entry is guarded by `!isPurchased`, there's no support contact, and the "optional"/July 2026 text is stale. The plan follows the fix. The hosted-URL test uses the `hasOwnerSuppliedValues` skip gate instead of a failing assertion, so CI stays green until the owner acts (D-PRIVACY-URL). A markdown sync test prevents the drift between in-app and hosted copy. |
| UI-23 (merged into STORE-03) | confirmed | Same facts (the menu holds only diagnostics, `PaywallView:213` says "optional"). Its "Delete learning data" item is delivered as Storage & Data › Clear. |
| ML-11 | confirmed | `deleteAllData`, `clear` and `reset` have no callers, and there's no footprint surface. The finding suggested the Similar-tab gear menu; the workstream notes put it in Home's Help & Privacy menu instead, which is reachable for everyone. Beyond the finding, the clear also covers snapshots, large-video results and file sizes. It resets WS-15's state store, fences running scans, and deliberately does **not** reset kept photos or diagnostics. |
| STORE-05 | confirmed | Three "Allow" controls precede system prompts (`OnboardingView:100`, `HomeView:498`, `HomeView:167`). The labels become "Continue" and the onboarding body copy stops implying full access is required. The lint also covers `Label(` and `DuckSecondaryButton`. |
| STORE-11 | confirmed | The purpose string omits video, deletion and compression, and the plist key is absent. Suppression of the automatic alert is iOS behavior, so it gets a Device QA step. The plist test parses the source Info.plist instead of reading `Bundle.main`, so it doesn't depend on the test host. |
