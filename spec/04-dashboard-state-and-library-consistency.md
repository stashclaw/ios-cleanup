# Chapter 04 — Dashboard state: HomeViewModel decomposition, launch restore and library consistency

> **Milestone(s):** M1 · **Workstreams:** WS-15 – WS-21 · Read `spec/README.md` first: operating rules, invariants, build/test commands and the decision log apply to every workstream here.

## Chapter overview

`HomeViewModel` (2,640 lines) owns every piece of dashboard state: the UserDefaults scalars, the JSON analysis snapshot, the library inventory, checkpoints, result collections, the large-video pass, notifications and diagnostics. Every state bug in this chapter lives in that one file: a quadratic, multi-decode launch restore whose loading window offers a destructive "Scan again"; scalars that contradict the snapshot; whole-library enumeration on every foreground; mid-scan additions that poison completed snapshots; Limited access that wipes the full-library analysis; permission states that stick; and a non-reentrant reconcile that marks every deletion "stale". So WS-15 and WS-16 first extract small, testable types without changing behavior (D-HVM-DECOMP), and WS-17 through WS-21 fix the bugs on top of them. When the chapter is done, a 60k-photo user gets saved results at launch with no phantom rescan and no enumeration of an unchanged library, a snapshot that stays consistent through library changes and Limited access, and deletions that disappear from every surface at once. The key risk is silently changing snapshot semantics (completion consistency, generation ordering, the recorded inventory, run fencing). Every workstream here must preserve README invariants 13, 14, 15 and 18 verbatim and prove it with the golden builder test and the existing cache fixtures in `PhotoScanEngineTests`.

---

## WS-15 — HomeViewModel extraction I and restore consistency

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M1 | L | WS-07, WS-12 | no | `ws/15-hvm-extraction-restore-consistency` |

**Primary files:** `iOSCleanup/Views/HomeViewModel.swift`, `iOSCleanup/Utilities/ScanDiagnosticsRecorder.swift` (*new*), `iOSCleanup/Views/Home/CompletionNotificationService.swift` (*new*), `iOSCleanup/Views/Home/CleanupStateStore.swift` (*new*), `iOSCleanup/Views/Home/CleanupStateReconciler.swift` (*new*), `iOSCleanup/Views/Home/HeroStateResolver.swift` (*new*), `iOSCleanup/Views/HomeView.swift` (or the WS-10 file that now holds `ctaTitle`/`handleCTAAction`), `iOSCleanup/Utilities/SharedHelpers.swift` (one diagnostic factory only), `iOSCleanupTests/ScanDiagnosticsRecorderTests.swift` (*new*), `iOSCleanupTests/CompletionNotificationServiceTests.swift` (*new*), `iOSCleanupTests/CleanupStateStoreTests.swift` (*new*), `iOSCleanupTests/CleanupStateReconcilerTests.swift` (*new*), `iOSCleanupTests/HeroStateResolverTests.swift` (*new*), `iOSCleanupTests/HomeViewModelTests.swift`, `iOSCleanup.xcodeproj/project.pbxproj`

**Findings covered:** STATE-09 (P2, confirmed)

**Decisions applied:**
- D-HVM-DECOMP: this PR delivers extraction phases 2 (diagnostics), 3 (notifications) and 4 (persisted scalars), then the STATE-09 fix. It is one commit per phase with the suite green after each. `HomeViewModel` stays the facade, and the view API does not change in commits 1–3. The only view change is the new `HeroState.restoringResults` case in the final commit.

### Goal
Diagnostics bookkeeping, completion notifications and the UserDefaults scalar store live in three small, tested types. The persisted scalars carry a schema version, and decode failures are recorded instead of silently swallowed. After cache loss (a device restore without Application Support, or a corrupt, oversize or wrong-schema snapshot), Home shows "Your previous results couldn't be restored on this iPhone. Run a new scan." instead of "Cleanup complete · 42 groups" over empty lists. While saved results are loading, the hero is in a dedicated `restoringResults` state instead of showing UserDefaults counts as findings.

### Current behavior (verified)
- `iOSCleanup/Views/HomeViewModel.swift:175-200`: `private struct PersistedCleanupState: Codable` holds 24 scalars and has no version field. The key is `"photoduck.cleanup-state.v2"` (`:202-204`).
- `:2485-2491`: `loadPersistedCleanupState()` does `guard … let snapshot = try? JSONDecoder().decode(PersistedCleanupState.self, from: data) else { return }`, so a decode failure is silent. `:2518-2522` maps a persisted `.scanning` to `.paused` plus `.lastKnown`.
- `:2336-2374`: `persistCleanupState()` maps `isFinalizingPhotoScan && scanState == .completed` to `.scanning` (the durable-state mapping; invariant 13) and writes with `try?`.
- `:2182-2184`: `performCachedAnalysisRestore()` does `guard photoGroups.isEmpty else { return }`, then `guard let snapshot = await analysisCache.loadSnapshot() else { return }`. The nil path never touches the scalars restored from UserDefaults in `init`.
- `:2221-2227`: `lastCompletedAt = snapshot.savedAt`, `lastCompletedMode` and all `lastCompleted*` are copied even when `snapshotIsComplete` (`:2197-2198`, `isComplete && hasConsistentCompletionState`) is false.
- `iOSCleanup/Engines/PhotoAnalysisCache.swift:569-603`: `loadSnapshot(from:)` returns nil for a missing file, a file over 64 MB, a schema mismatch or a decode error.
- `:640-652`: `heroPrimaryMetricValue` shows `"\(lastCompletedGroupsCount) groups"` for `.completedResultsAvailable` whatever `photoGroups` holds, and `:709-711` shows "Checked on <date>".
- Diagnostics: `recordDiagnostic` (`:405-411`) chains `diagnosticWriteTask`. The photo and video progress-bucket logic is at `:413-486`. The background path (`:1557-1573`) captures `diagnosticWriteTask` before its Task and re-reads it at the end. `makeDiagnosticReport()` (`:2376-2446`) captures an uptime cutoff before awaiting pending writes.
- Notifications: completion copy at `:1209-1226`, `requestCompletionNotifications()` at `:1649-1670`, `maybeScheduleNotification`/`refreshNotificationAuthorization`/`notificationKey` at `:2315-2332`, and `CleanupReviewTarget` plus `CleanupNotificationScheduler` at `:2591-2623`. The routing key `"cleanupTarget"` is read in `iOSCleanup/iOSCleanupApp.swift:67`. `notificationEligible` is read by `HomeView.swift:841-856`.
- `PhotoDuckDiagnosticEvent` (`iOSCleanup/Utilities/SharedHelpers.swift:668`) has a `private init`, so factories must be declared in that file. The sanitizer allowlists values per key (`:1411-1453`).
- `HeroState` (`HomeViewModel.swift:164-173`) is switched exhaustively at `HomeViewModel.swift:617, 641, 663, 682, 719, 740, 767` and `HomeView.swift:344, 427`. `HomeView.swift:318, 331, 371` have `default:` branches.
- STATE-09's scenario (b) is narrower than the finding says. `drainPendingSnapshots` refuses to write more than 64 MB (`PhotoAnalysisCache.swift:678-680`), so the previous file survives. The phantom appears when the on-disk file itself is unreadable, oversize or from another schema, or when Application Support is gone (a device restore once WS-34 excludes it from backup). Scenarios (a) and (c) are confirmed.

### Implementation plan

**WS-15.1 — Phase 2: `ScanDiagnosticsRecorder`**
- **Why:** Write chaining and progress buckets are interleaved with scan logic and cannot be tested. This removes about 120 lines from `HomeViewModel`.
- **Change:** New `iOSCleanup/Utilities/ScanDiagnosticsRecorder.swift`:
  ```swift
  @MainActor
  final class ScanDiagnosticsRecorder {
      typealias Sink = @Sendable (PhotoDuckDiagnosticEvent) async -> Void
      private let sink: Sink
      private(set) var pendingWrite: Task<Void, Never>?
      private var lastPhotoProgressBucket = -1
      private var lastVideoProgressBucket = -1

      init(sink: @escaping Sink = { await PhotoDuckDiagnosticLog.shared.record($0) })

      /// Body of HomeViewModel.recordDiagnostic, verbatim: chain on the previous task, Task.detached(.utility).
      func record(_ event: PhotoDuckDiagnosticEvent)
      func resetPhotoProgress()               // was `lastPhotoDiagnosticProgressBucket = -1` (:936)
      func resetVideoProgress()               // was `lastVideoDiagnosticProgressBucket = -1` (:1390)
      /// Body of recordPhotoProgressIfNeeded (:413-448) with the counters passed in.
      func recordPhotoProgress(processed: Int, target: Int, analyzed: Int,
                               unanalyzed: Int, groups: Int, isCompleteUpdate: Bool)
      /// Body of recordVideoProgressIfNeeded (:450-486); `fallbackQualifyingCount` replaces `largeFiles.count`.
      func recordVideoProgress(_ update: FileScanUpdate, fallbackQualifyingCount: Int)
      /// Awaits the task that is current *at call time* (re-reads pendingWrite).
      func awaitPendingWrites() async
      /// :2439-2445 verbatim: uptime cutoff first, then await pending writes, then export.
      func exportReport(_ snapshot: PhotoDuckDiagnosticReportSnapshot) async throws -> URL
  }
  ```
  - `HomeViewModel` gets `private let diagnostics: ScanDiagnosticsRecorder`. Build it in `init` from WS-07's `dependencies.diagnosticLog` (sink `{ await log.record($0) }`), so fixture mode and the test harness keep their isolated log. For tests that need a collector, add `var diagnosticsSink: ScanDiagnosticsRecorder.Sink? = nil` to `HomeViewModelDependencies` (WS-07's grow-with-defaults pattern; nil means the log). Keep a private one-line `recordDiagnostic(_:)` that forwards to `diagnostics.record`, so the ~30 call sites stay unchanged.
  - Background path (`:1557-1573`): capture `let pendingDiagnosticWrite = diagnostics.pendingWrite` before creating the Task. Inside the Task, await it first (as today), and at the end call `await diagnostics.awaitPendingWrites()`. That second call re-reads the latest task, which keeps "include events emitted while the checkpoint work ran".
  - `makeDiagnosticReport()` still builds `PhotoDuckDiagnosticReportSnapshot` from facade state and calls `diagnostics.exportReport(snapshot)`.
- **Edge cases:** Event order must stay FIFO: each write awaits the previous one. Nothing in the sink may touch main-actor state.

**WS-15.2 — Phase 3: `CompletionNotificationService`**
- **Why:** Notification eligibility, the per-run key and the completion copy are scattered across five places. WS-31 later changes their content and routing, so they need one home.
- **Change:** New `iOSCleanup/Views/Home/CompletionNotificationService.swift`. Move `CleanupReviewTarget` and `CleanupNotificationScheduler` (`:2591-2623`) into it unchanged.
  ```swift
  protocol CompletionNotificationCenter: Sendable {
      func authorizationStatus() async -> UNAuthorizationStatus
      func requestAuthorization() async throws -> Bool
      @MainActor func schedule(title: String, body: String, target: CleanupReviewTarget)
  }
  struct SystemCompletionNotificationCenter: CompletionNotificationCenter { /* UNUserNotificationCenter + CleanupNotificationScheduler.shared */ }

  @MainActor
  final class CompletionNotificationService {
      private(set) var isEligible = false
      var lastNotificationKey: String?                      // persisted through PersistedCleanupState
      init(center: any CompletionNotificationCenter = SystemCompletionNotificationCenter())
      func refreshAuthorization() async -> Bool             // body of refreshNotificationAuthorization
      func requestAuthorization() async -> Bool             // body of requestCompletionNotifications
      /// Key "\(mode.rawValue)-complete"; title/body moved VERBATIM from :1209-1226; guards from
      /// maybeScheduleNotification (eligible, key != lastNotificationKey). Returns true when scheduled.
      func notifyRunCompleted(mode: CleanupMode, groupsFound: Int, reviewCategoryCount: Int,
                              unanalyzedCount: Int, reclaimableBytes: Int64) -> Bool
      func resetForNewRun()                                 // lastNotificationKey = nil (was :1080)
  }
  ```
  - `HomeViewModel` keeps `@Published var notificationEligible` because the view reads it. Assign it from `await notifications.refreshAuthorization()` and `requestAuthorization()`. `requestCompletionNotifications()` keeps its signature.
  - In the completion block (`:1209`), call `if notifications.notifyRunCompleted(...) { persistCleanupState() }`, keeping today's order: the key is persisted before scheduling, and the block still ends with the completion barrier (`isFinalizingPhotoScan = false`, then `persistCleanupState()`).
  - `lastNotificationKey` moves into the service. `makePersistedState()` reads it and `apply(persisted:)` writes it.
- **Edge cases:** Do not change any copy or routing; WS-31 owns that (STATE-13). The notification delegate installation in `App.init` is untouched (invariant 26).

**WS-15.3 — Phase 4: `CleanupStateStore` with a schema version**
- **Why:** Decoding with `try?` silently resets state on any incompatible change, and there is no version to migrate from.
- **Change:** New `iOSCleanup/Views/Home/CleanupStateStore.swift`:
  ```swift
  struct PersistedCleanupState: Codable, Equatable, Sendable {
      static let currentSchemaVersion = 2
      var schemaVersion: Int?                      // absent in legacy JSON ⇒ 2
      // …all 24 existing fields, same names and types (scanState: HomeViewModel.ScanState, …)…
      var resultsUnavailableNotice: Bool?          // WS-15.4; optional so legacy JSON decodes
      // WS-28 adds `pauseReason` as another optional field. Additive optionals never bump the version.
      var effectiveSchemaVersion: Int { schemaVersion ?? 2 }
  }

  enum CleanupStateLoadResult: Equatable {
      case missing, loaded(PersistedCleanupState), decodeFailed, unsupportedVersion(Int)
  }

  struct CleanupStateStore {
      static let defaultsKey = "photoduck.cleanup-state.v2"
      private let defaults: UserDefaults
      init(defaults: UserDefaults = .standard)
      func load() -> CleanupStateLoadResult        // > currentSchemaVersion ⇒ .unsupportedVersion
      @discardableResult
      func save(_ state: PersistedCleanupState) -> Bool   // stamps schemaVersion = currentSchemaVersion
  }
  ```
  - Using optionals keeps synthesized `Codable`. Do not hand-write `init(from:)` for 25 fields.
  - `HomeViewModel`:
    - Add `private func currentScalarState() -> PersistedCleanupState`, the field list from `:2345-2370` with the **raw** `scanState`.
    - `persistCleanupState()` takes `currentScalarState()`, overrides `scanState` with `Self.durableScanState(scanState:isFinalizingPhotoScan:)` (a new `nonisolated static` pure function holding the `:2341-2344` expression verbatim), and calls `store.save`.
    - `loadPersistedCleanupState()` does `switch store.load()`:
      - `.loaded(s)`: `apply(persisted:)`, which is the `:2493-2522` body verbatim, including scanning→paused.
      - `.decodeFailed` and `.unsupportedVersion`: `recordDiagnostic(.cleanupStateRestore(outcome: …))`, then keep the defaults.
      - `.missing`: nothing.
  - Build the store from WS-07's `dependencies.defaults`: `CleanupStateStore(defaults: dependencies.defaults)`. No new dependency field is needed, and tests reuse the harness's temp `UserDefaults` suite.
  - `SharedHelpers.swift`, next to `restoredState` (`:726`): add `enum PhotoDuckDiagnosticStateRestoreOutcome: String, Sendable { case decodeFailed = "decode_failed", unsupportedVersion = "unsupported_version", resultsUnavailable = "results_unavailable" }` and `static func cleanupStateRestore(outcome:at:)` (category `"photo_scan"`, name `"cleanup_state_restore"`, field `"restore_outcome"`). Add `"restore_outcome"` to the `sanitizedFieldValue` allowlist with those three values. Also add an internal read-only `var debugName: String { "\(category).\(name)" }` so tests can identify events. This is the only SharedHelpers change allowed here, because the factory needs the `private init`.
- **Edge cases:**
  - The decode-failure diagnostic is recorded from `init`, so construct `diagnostics` before calling `loadPersistedCleanupState()`.
  - Keep `recordDiagnostic(.restoredState…)` in `init` (`:301-308`).

**WS-15.4 — STATE-09: reconcile the scalars with the snapshot, and add `restoringResults`**
- **Why:** Cache loss leaves "Cleanup complete · 42 groups · Checked on …" over empty tiles, `scanNewPhotosIfNeeded` does nothing, and "Continue" on a persisted `.paused 18,000/50,000` restarts at 0. Incomplete checkpoints also overwrite the last real completion date and counts.
- **Change:**
  1. `PhotoAnalysisCache.init(directoryURL: URL? = nil)`, mirroring `LargeVideoResultCache.init(directoryURL:)`. WS-07 probably added it for its temp caches; add it only if it is missing.
  2. New `iOSCleanup/Views/Home/CleanupStateReconciler.swift` (pure):
     ```swift
     enum CleanupStateReconciler {
         struct SnapshotFacts: Equatable, Sendable {
             let completedAt: Date              // snapshot.savedAt (WS-21 switches this to completedAt ?? savedAt)
             let cleanupMode: CleanupMode
             let isCompleteAndConsistent: Bool  // snapshot.isComplete && snapshot.hasConsistentCompletionState
             let libraryTotalCount: Int
             let scanTargetCount: Int
             let restoredGroupCount: Int
             let restoredReviewableCount: Int
             let restoredReclaimableBytes: Int64
         }
         struct Outcome: Equatable { var state: PersistedCleanupState; var resultsUnavailable: Bool }
         static func reconcile(persisted: PersistedCleanupState, snapshot: SnapshotFacts?) -> Outcome
         /// Scan scalars at idle defaults; keeps cleanupMode and lastNotificationKey. Notice NOT set.
         /// (WS-48's "Clear local data" reuses this.)
         static func idleState(from persisted: PersistedCleanupState) -> PersistedCleanupState
     }
     ```
     Rules:
     - `snapshot == nil`:
       - `claimsResults = persisted.scanState ∈ {.completed, .paused} || persisted.lastCompletedGroupsCount > 0 || persisted.lastCompletedAt != nil`.
       - If `claimsResults` and `scanState != .permissionRequired`, the state becomes `idleState(from:)` with `resultsUnavailableNotice = true`, and `resultsUnavailable = true`. `idleState` sets:
         - `scanState .idle`, `isPaused false`, `isBackgroundExecutionState false`.
         - Every count 0 and `progressFraction 0`.
         - `hasPartialResults` and `isReadyForReview` false.
         - `lastCompletedAt` and `lastCompletedMode` nil, and every `lastCompleted*` count 0.
         - `resultsFreshnessState .live`.
       - Otherwise the state is unchanged. A `.permissionRequired` state is never touched here; WS-20 reconciles it with authorization.
     - `snapshot != nil`: set `resultsUnavailableNotice = false`.
       - If `isCompleteAndConsistent`, adopt `lastCompletedAt = completedAt`, `lastCompletedMode = cleanupMode`, `lastCompletedLibraryTotalCount`, `lastCompletedScanTargetCount`, and the three restored counts.
       - Otherwise keep the persisted `lastCompleted*` values.
  3. `performCachedAnalysisRestore()`:
     - **Nil path:** `let outcome = CleanupStateReconciler.reconcile(persisted: currentScalarState(), snapshot: nil)`. Then assign every scalar from `outcome.state` through a new `applyReconciled(_:)`, a straight copy with no scanning→paused mapping. Then `publishProgressSnapshot()`, `persistCleanupState()`, and, if `outcome.resultsUnavailable`, `recordDiagnostic(.cleanupStateRestore(outcome: .resultsUnavailable))`.
     - **Snapshot path:** keep `:2186-2220` and `:2228-2261`. Replace `:2221-2227` with: build `SnapshotFacts` from the snapshot and the restored counts, reconcile, and copy only `lastCompleted*` and the notice from the outcome.
     - `hasHydratedAnalysisCache` is still set by the hydration task after this returns.
  4. `@Published private(set) var resultsUnavailableNotice = false`, loaded from and saved in `PersistedCleanupState`. `heroDetailText` for `.idlePrompt` returns "Your previous results couldn't be restored on this iPhone. Run a new scan." when it is set. `scanPhotos` clears it (set false, then persist) where it sets `.scanning` (the `:1072-1080` block).
  5. `restoringResults`:
     - Add `case restoringResults` to `HeroState`, and `@Published private(set) var isRestoringSavedResults = false`.
     - Set it `true` in `bootstrapLibraryStateIfNeeded()` right after `hasBootstrappedLibraryState = true` (before the Task), and in `restoreCachedAnalysisIfNeeded()` when it creates the hydration task.
     - Set it `false` inside the hydration task immediately after `self.hasHydratedAnalysisCache = true`.
     - Use a published flag, not the private `hasHydratedAnalysisCache`, because the nil-snapshot path publishes nothing and the hero would never re-render.
  6. New `iOSCleanup/Views/Home/HeroStateResolver.swift`: `struct HeroStateInputs: Equatable` has `scanState`, `isRestoringSavedResults`, `cleanupMode`, `hasPartialResults`, `isReadyForReview`, `hasCompletionDate` and `scanErrorMessage`. `enum HeroStateResolver { static func resolve(_:) -> HomeViewModel.HeroState }` is the `:584-614` logic verbatim, with one insertion right after the `.permissionRequired` check: `if inputs.isRestoringSavedResults { return .restoringResults }`. `heroState` becomes `HeroStateResolver.resolve(heroStateInputs)`.
  7. Copy for the new case:

     | Property | Copy |
     |---|---|
     | `heroStatusLabel` | "Loading saved results" |
     | `heroPrimaryMetricValue` | "Loading…" |
     | `heroPrimaryMetricTitle` | "Saved results" |
     | `heroDetailText` | "Loading your last scan results…" |

     WS-07.4 (chapter 02) deleted `heroSecondaryText` and `heroNextActionLabel`. Do not re-add them for this case. Only the live hero properties above get new copy.

     In HomeView:
     - `ctaTitle`: "Loading saved results…"; `ctaSubtitle`: "This only takes a moment".
     - `handleCTAAction`: `case .restoringResults: break`.
     - `ctaButton`: `.disabled(viewModel.isCompletingActiveScan || viewModel.heroState == .restoringResults)`.

     WS-17 adds the ProgressView and the tile states.
- **Edge cases:**
  - A restore triggered from `scanPhotos` runs while `isFinalizingPhotoScan == true`. That is why the reconciler takes the raw `currentScalarState()`, not the durable-mapped state.
  - After WS-48's "Clear local data", the scalars are already idle with no completion. The reconciler must then produce no notice (`claimsResults` is false), and a test covers this.
  - Never change the durable mapping or the completion-barrier order.

### Tests
All tests in this section run in the simulator.
- `iOSCleanupTests/ScanDiagnosticsRecorderTests.swift` (sink = collector actor):
  - `testRecordPreservesEventOrder`
  - `testPhotoProgressRecordsOncePerTenPercentBucket`: 0%, 5% and 10% produce 2 events.
  - `testCompleteUpdateAlwaysRecords`
  - `testResetPhotoProgressAllowsSameBucketAgain`
  - `testAwaitPendingWritesWaitsForEventsRecordedAfterCapture`
- `iOSCleanupTests/CompletionNotificationServiceTests.swift` (fake center that records `schedule` calls and has a scripted status):
  - `testIneligibleServiceNeverSchedules`
  - `testSchedulesOncePerRunKey`
  - `testResetForNewRunAllowsNextNotification`
  - `testCompletionCopyMatchesLegacyStrings`: four cases (clean library, only unanalyzed, only review categories, groups with bytes) against the literal strings from `:1214-1225`.
  - `testRequestAuthorizationPromptsOnlyWhenNotDetermined`
- `iOSCleanupTests/CleanupStateStoreTests.swift` uses `UserDefaults(suiteName: "CleanupStateStoreTests.\(UUID())")!` and `removePersistentDomain` in tearDown:
  - `testRoundTripPreservesEveryField`
  - `testLegacyJSONWithoutSchemaVersionDecodesAsVersion2`: encode a state, strip `schemaVersion` and `resultsUnavailableNotice` with `JSONSerialization`, then decode.
  - `testGarbageDataReportsDecodeFailed`
  - `testNewerSchemaIsReportedUnsupported` (99)
  - `testMissingKeyReportsMissing`
  - `testSaveStampsCurrentSchemaVersion`
  - `testDurableScanStateMapsFinalizingCompletedToScanning` (pure static)
- `iOSCleanupTests/CleanupStateReconcilerTests.swift`:
  - `testNilSnapshotResetsCompletedStateAndRaisesNotice`
  - `testNilSnapshotResetsPausedProgressToZero`
  - `testNilSnapshotKeepsModeAndNotificationKey`
  - `testNilSnapshotLeavesIdleStateWithoutResultsUntouched`: this is also the post-WS-48-clear case.
  - `testNilSnapshotLeavesPermissionRequiredUntouched`
  - `testIncompleteSnapshotKeepsPersistedCompletionDate`
  - `testInconsistentCompleteSnapshotKeepsPersistedCompletion`
  - `testCompleteSnapshotAdoptsDateModeAndCounts`
  - `testSnapshotClearsNotice`
- `iOSCleanupTests/HeroStateResolverTests.swift`:
  - `testRestoringResultsWinsOverPersistedCompletion`
  - `testPermissionRequiredWinsOverRestoring`
  - `testLegacyOrderingUnchanged`: table of the existing branches.
- `iOSCleanupTests/HomeViewModelTests.swift` (WS-07 seam: temp suite, `PhotoAnalysisCache(directoryURL: emptyTempDir)`, `observesPhotoLibrary: false`):
  - `testMissingSnapshotShowsRunNewScanInsteadOfPhantomGroups`:
    - Seed the store with `.completed`, `lastCompletedGroupsCount 42` and `lastCompletedAt`.
    - `await vm.restoreCachedAnalysisIfNeeded()` (make it `internal`; with no snapshot it never touches PhotoKit).
    - Assert `scanState == .idle`, `heroState == .idlePrompt`, `heroDetailText` equals the notice, and `heroPrimaryMetricValue` is not `"42 groups"`.
    - Reloading the store shows `.idle` and `resultsUnavailableNotice == true`.
  - `testDecodeFailureRecordsDiagnostic`: seed garbage bytes; with an injected collector sink, one event has `debugName == "photo_scan.cleanup_state_restore"`.

### Acceptance criteria
- [ ] Four commits (`WS-15.1` … `WS-15.4`), each building with zero warnings and passing the full suite.
- [ ] Commits 1–3 change no view file: `git diff --stat` for those commits touches only `HomeViewModel.swift`, the new files, SharedHelpers (commit 3), tests and the pbxproj.
- [ ] `HomeViewModel.swift` shrinks. `recordPhotoProgressIfNeeded`, `recordVideoProgressIfNeeded`, `maybeScheduleNotification`, `refreshNotificationAuthorization`, `PersistedCleanupState` and `CleanupNotificationScheduler` no longer live in it.
- [ ] Legacy UserDefaults JSON decodes, and a decode failure records a `cleanup_state_restore` event with `decode_failed`.
- [ ] With a completed state in UserDefaults and no snapshot file, Home shows the idle hero with "Your previous results couldn't be restored on this iPhone. Run a new scan." and never "N groups" over empty tiles (unit test, plus the simulator check below).
- [ ] An incomplete checkpoint never overwrites `lastCompletedAt` or `lastCompleted*` (reconciler test).
- [ ] While saved results load, the hero is `.restoringResults` and the CTA is disabled.
- [ ] `ios-cleanup/CLAUDE.md` "ViewModel layer" says that persisted scalars live in `CleanupStateStore` (versioned) and are reconciled with the snapshot at restore, and lists `ScanDiagnosticsRecorder` and `CompletionNotificationService`.

### Device QA
- **Cache loss.** With completed results, use Xcode ▸ Devices ▸ the app ▸ Download Container, delete `Library/Application Support/PhotoDuck`, then Replace Container and relaunch.
  - Expect the idle hero with "Your previous results couldn't be restored on this iPhone. Run a new scan."
  - Duplicates/Similar show "Waiting for scan".
  - Tapping Start scan clears the notice.
- **Loading state.** On a 30k+ library cold launch, the hero shows "Loading saved results" and the CTA is disabled until results appear.

### Pitfalls and out of scope
- **Invariant 13:** keep the durable mapping and the completion barrier (published last) byte-for-byte. Keep every `activeScanID` guard. Do not move scan lifecycle code in this PR.
- Do not change notification copy, routing or the bootstrap order. That is WS-31 (chapter 07).
- Do not reconcile `.permissionRequired` or touch authorization. That is WS-20.
- Do not shrink `PersistedCleanupState` to UI facts. STATE-09 fix item 5 is future work; WS-28 (chapter 06) adds `pauseReason`.
- The ProgressView, tile "Loading…" states and the Home primary-CTA phantom-rescan guard are WS-17.
- Backup exclusion of Application Support is WS-34 (chapter 07). It makes scenario (a) common, so WS-15 must ship in the same release or earlier.
- **Reconciliation (lead L29):** `makeDiagnosticReport()` keeps every `PhotoDuckDiagnosticReportSnapshot` JSON key, including `isFinalizingPhotoScan` and `isFinishingSupportingScans`. After WS-27/WS-28 (chapter 06) those keys are fed from `isPhotoRunActive` and `isVideoPassRunning`. Never rename the keys.
- **Reconciliation (lead L14):** WS-37 (chapter 08) later adds `CachedPhotoAnalysisSnapshot.analyzerVersion` (`decodeIfPresent`). `SnapshotFacts` does not read it, and no test here may assert a snapshot's full key set.
- **Reconciliation:** a first scan killed before its first 20 s checkpoint leaves no snapshot, so the nil-snapshot rule resets it to idle and it does not auto-resume. WS-28 (chapter 06) documents and accepts this edge. Do not special-case it here.
- **Reconciliation (lead L16):** the recorder and the store are built from WS-07's existing `diagnosticLog` and `defaults` dependencies. The only new dependency field is the optional `diagnosticsSink`.
- **Reconciliation:** WS-07.4 (chapter 02) deletes `heroSecondaryText` and `heroNextActionLabel`. The `restoringResults` copy table no longer lists them, and this PR must not re-add them.

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| STATE-09 | confirmed | Scenarios (a) and (c) and the incomplete-checkpoint overwrite are exactly as described. Scenario (b) is narrower: an oversize *write* is refused, so the old file survives, and the phantom needs an unreadable, oversize or wrong-schema file on disk. The plan follows fix items 1–4. `schemaVersion` is an optional field (legacy ⇒ 2) instead of a hand-written decoder. `HeroState.restoringResults` is driven by a published `isRestoringSavedResults` flag, because `hasHydratedAnalysisCache` is not published and the nil path would not re-render. `.permissionRequired` is excluded from the reset and left to WS-20. The notice is persisted so it survives relaunch until the next scan. Item 5 (shrinking the scalars) is out of scope. |

---

## WS-16 — HomeViewModel extraction II and off-main snapshot build

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M1 | L | WS-15 | no | `ws/16-hvm-extraction-snapshot-offmain` |

**Primary files:** `iOSCleanup/Views/HomeViewModel.swift`, `iOSCleanup/Views/Home/AnalysisCheckpointState.swift` (*new*), `iOSCleanup/Views/Home/AnalysisSnapshotBuilder.swift` (*new*), `iOSCleanup/Views/Home/LargeVideoScanController.swift` (*new*), `iOSCleanup/Views/Home/PhotoResultsStore.swift` (*new*), `iOSCleanup/Engines/PhotoAnalysisCache.swift` (capture-sequence ordering only), `iOSCleanupTests/AnalysisSnapshotBuilderTests.swift` (*new*), `iOSCleanupTests/PhotoResultsStoreTests.swift` (*new*), `iOSCleanupTests/LargeVideoScanControllerTests.swift` (*new*), `iOSCleanupTests/PhotoScanEngineTests.swift` (one cache-ordering test), `iOSCleanupTests/ScalePerformanceTests.swift` (one measure test), `iOSCleanup.xcodeproj/project.pbxproj`

**Findings covered:** FSA-12 (P2, confirmed; merged: SCAN-M03)

**Decisions applied:**
- D-HVM-DECOMP: this PR delivers phases 5 (checkpoint state and snapshot builder), 7 (large-video controller) and 8 (results store), each behavior-preserving and each proven by a test. The golden builder test must be byte-identical before and after the move.

### Goal
Checkpoint bookkeeping, snapshot construction, the large-video pass and the result collections live in focused types that later workstreams edit instead of `HomeViewModel`. The full-library snapshot (five sorts over up to 60k IDs plus a map of every group) is built off the main actor for periodic checkpoints, pause, background and reconcile, with its contents byte-identical to today. The view API is unchanged.

### Current behavior (verified)
- `iOSCleanup/Views/HomeViewModel.swift:1154`: `let worker = Task(priority: .utility) { [weak self] in … }` is created inside the `@MainActor` method `scanPhotos`, so **the worker inherits main-actor isolation**. The `await MainActor.run { … }` calls at `:1164, 1192, 1245, 1267, 1304` are same-actor hops. FSA-12's premise that the worker is "already off-main" is false, so "build in the worker" would still run on main.
- `:1763-1776`: `apply(update:)` returns `makeAnalysisSnapshot(isComplete:)` every 20 s (`ScanPersistenceTuning.periodicCheckpointInterval`, `:9-13`), on completion, and whenever `isPaused`.
- `:2019-2112`: `makeAnalysisSnapshot` sorts `checkpointEvaluatedAssetIDs`, `checkpointTargetAssetIDs`, `checkpointUnanalyzedAssetIDs` and `knownLibraryAssetIdentifiers`, sorts `knownLibraryAssetMetadata.values`, and maps every group and candidate into `CachedPhotoGroup`. All of it runs on main.
- The other main-actor builds are:
  - pause, `:902-915` (both branches)
  - background, `:1553-1556`
  - the reconcile scanning branch, `:1846-1848`
  - `saveAnalysisSnapshot`, `:2003-2017`
  - the cancel path, `:1261`
- Checkpoint fields are at `:280-287`. They are:
  - folded at `:1693-1706`
  - prepared at `:1134-1146`
  - restored at `:2204` and `:2234-2250`
  - pruned in `refreshLibraryMetadata` at `:1599-1606`
- Result collections (`:208-222`) have `didSet { rebuildCollectionSummary() }`, so a restore rebuilds the summary three times (`:2193-2195`). The merge is at `:1708-1740`, and the signature helpers are at `:2551-2589`.
- The large-video state is:
  - storage: `:217-219, 224-225`
  - `scanFiles`: `:1371-1480`
  - `publishFileScanUpdate`: `:1482-1488`
  - `removeLargeFileFromResults`: `:1490-1526`
  - restore: `:2133-2180`
- `CachedPhotoAnalysisSnapshot` is not `Equatable`, so the golden comparison uses JSON with `.sortedKeys`.
- `PhotoAnalysisCache.enqueue` assigns the generation at enqueue time (`iOSCleanup/Engines/PhotoAnalysisCache.swift:621-650`). If two detached builds finish out of order, the *older* state would get the *higher* generation. Moving builds off-main creates this ordering hazard; today's synchronous main-actor builds mostly hide it.
- No view writes `photoGroups`, `screenshotAssets`, `blurryAssets`, `largeFiles`, `fileScanState` or `fileScanProgress` (grep). SwiftUI reads them through `HomeViewModel`.

### Implementation plan

**WS-16.1 — Golden capture before anything moves**
- **Why:** D-HVM-DECOMP requires proving that the move changes nothing.
- **Change:**
  - New `iOSCleanup/Views/Home/AnalysisSnapshotBuilder.swift` containing only `struct AnalysisSnapshotInputs: @unchecked Sendable` (`PhotoGroup` and `PHAsset` arrays are immutable values). It holds:
    - `captureSequence: UInt64`, `savedAt: Date`
    - every scalar `makeAnalysisSnapshot` reads (`libraryTotalCount`, `scanTargetCount`, `processedPhotoCount`, `analyzedPhotoCount`, `unanalyzedPhotoCount`, `progressFraction`, `scanState`, `groupsFoundCount`, `reviewablePhotosCount`, `reclaimableBytesFoundSoFar`, `cleanupMode`)
    - the six checkpoint fields
    - `photoGroups`, `screenshotAssets`, `blurryAssets`, `knownLibraryAssetIdentifiers`, `knownLibraryAssetMetadata`
  - In `HomeViewModel`:
    - `private func captureSnapshotInputs() -> AnalysisSnapshotInputs` is O(1): copy-on-write captures only, `savedAt = Date()`, and `captureSequence` from `private var snapshotCaptureSequence: UInt64` incremented per call.
    - `nonisolated static func buildAnalysisSnapshot(_ inputs:, isComplete:) -> CachedPhotoAnalysisSnapshot` is the `:2022-2111` body verbatim, with `self.x` replaced by `inputs.x`, and it passes `savedAt: inputs.savedAt` to the snapshot init.
    - `makeAnalysisSnapshot(isComplete:)` becomes `Self.buildAnalysisSnapshot(captureSnapshotInputs(), isComplete:)`.
  - Add `AnalysisSnapshotBuilderTests.testGoldenCompleteSnapshot`, `testGoldenCheckpointSnapshot` and `testGoldenEmptyLibrarySnapshot`. Each has fixed inputs:
    - `savedAt = Date(timeIntervalSinceReferenceDate: 700_000_000)`
    - five library IDs with metadata
    - two groups built through `PhotoGroup.init` with explicit `id:`, `candidates:` and `reclaimableBytes:`, using WS-03's shared `PHAsset` double so `init` never touches PhotoKit
    - one screenshot and one blurry asset
    - non-empty checkpoint sets
  - Encode with `JSONEncoder` and `outputFormatting = [.sortedKeys]`. Paste the output once as a raw string literal (`#"""…"""#`) and compare strings. Review the parameterized body against the original with `git diff -w`; only `inputs.` prefixes and the explicit `savedAt` may differ.
  - **Additive fields (lead L14).** Later workstreams add optional snapshot fields:
    - WS-18.6: `libraryChangeTokenData`
    - WS-21: `completedAt`
    - WS-37 (chapter 08): `analyzerVersion`
    - WS-63 (chapter 13): `CachedPhotoGroup.pairEvidence`

    The goldens must tolerate these additions:
    - Each new field is an optional encoded with synthesized `encodeIfPresent`, so nil is omitted.
    - The golden fixtures leave every new field nil, so the literals stay byte-identical.
    - Each new field gets its own round-trip test instead of a golden edit.
    - A literal changes only when a PR deliberately changes recorded values or writes a non-nil new key for these fixtures (WS-19's recorded inventory, WS-21's `completedAt` on complete snapshots, WS-54's encoding). That PR explains every changed key.
- **Edge cases:** `savedAt` used to be set at build time. It is now set at capture time, a sub-millisecond difference with no semantic effect.

**WS-16.2 — Phase 5: `AnalysisCheckpointState` and `AnalysisSnapshotBuilder`**
- **Change:**
  - New `iOSCleanup/Views/Home/AnalysisCheckpointState.swift`:
    ```swift
    struct AnalysisCheckpointState: Equatable, Sendable {
        var evaluatedAssetIDs = Set<String>()
        var targetAssetIDs = Set<String>()
        var unanalyzedAssetIDs = Set<String>()
        var processedPhotoCount = 0
        var analyzedPhotoCount = 0
        var unanalyzedPhotoCount = 0
        struct Offsets: Equatable, Sendable { let processed: Int; let analyzed: Int; let unanalyzed: Int }

        /// :1693-1706 verbatim (subtract evaluated THEN union unanalyzed). Returns the published unanalyzed count.
        mutating func fold(update: PhotoScanUpdate, offsets: Offsets) -> Int
        /// :1134-1146.
        static func preparingRun(snapshot: CachedPhotoAnalysisSnapshot?, isIncrementalPass: Bool,
                                 carriesUnanalyzed: Bool, preparedTargetAssetIDs: Set<String>,
                                 offsets: Offsets) -> AnalysisCheckpointState
        /// :2204 and :2234-2250.
        static func restored(from snapshot: CachedPhotoAnalysisSnapshot, snapshotIsComplete: Bool) -> AnalysisCheckpointState
        /// :1600-1605; returns true when anything was removed.
        mutating func pruneUnanalyzed(keepingExisting ids: Set<String>) -> Bool
    }
    ```
    If WS-08 introduced a `ScanProgressMath` helper for committed-count arithmetic, `fold` calls it. Otherwise the arithmetic stays verbatim.
  - Move `buildAnalysisSnapshot` into `enum AnalysisSnapshotBuilder { static func build(inputs:isComplete:) -> CachedPhotoAnalysisSnapshot }`, with the checkpoint fields read from `inputs.checkpoint: AnalysisCheckpointState`. `hasCompletedTarget` and `snapshotIsComplete` stay inside `build`.
  - `HomeViewModel` replaces the six fields with `private var checkpoint = AnalysisCheckpointState()`.
  - The golden tests now call `AnalysisSnapshotBuilder.build` and **the literals do not change**.

**WS-16.3 — FSA-12: build off the main actor, with capture ordering**
- **Why:** Five sorts over ~60k strings plus the group mapping run on main every 20 s and on pause, background and reconcile, causing roughly 100–250 ms hitches while the user reviews partial results.
- **Change:**
  - `AnalysisSnapshotBuilder.buildOffMain(_ inputs:, isComplete:) async -> CachedPhotoAnalysisSnapshot` wraps `Task.detached(priority: .utility) { build(...) }.value`. Use `Task.detached` explicitly, because a nonisolated async function's executor depends on language-mode flags.
  - `apply(update:…)` returns `PendingCheckpoint? = (inputs: AnalysisSnapshotInputs, isComplete: Bool)` instead of a snapshot, keeping the same cadence conditions.
  - Worker (`:1164-1189`): after the `MainActor.run` returns a pending checkpoint, `let snapshot = await AnalysisSnapshotBuilder.buildOffMain(...)`. Then:
    - complete: `await analysisCache.saveSnapshot(snapshot, captureSequence:)`
    - otherwise: flush ML, then `scheduleSnapshot(snapshot, captureSequence:)`
    Completion stays "save durable, then run the completion MainActor block", as today.
  - Cancel path (`:1245-1265`): the MainActor block returns inputs, then build detached, then `saveSnapshot`.
  - `pauseDeepClean` (`:902-915`): capture inputs on main (after `engine.pause()` in the engine branch, synchronously in the other), then build detached, then save.
  - `updateScenePhase(.background)` (`:1553-1556`): capture inputs **synchronously** at backgrounding time. Build inside the lease Task before `flushBufferedWrites` and `saveSnapshot`. The lease covers the build.
  - Reconcile scanning branch and `saveAnalysisSnapshot`: capture, build detached, then schedule or save.
  - `PhotoAnalysisCache`: add `captureSequence: UInt64? = nil` to `scheduleSnapshot` and `saveSnapshot`, and a `private var lastAcceptedCaptureSequence: UInt64 = 0`. In `enqueue`, after computing `highestKnownGeneration`:
    ```swift
    if let captureSequence {
        guard captureSequence > lastAcceptedCaptureSequence else { return highestKnownGeneration }
        lastAcceptedCaptureSequence = captureSequence
    }
    ```
    A stale capture is dropped, and `saveSnapshot` then waits for the newer generation, exactly like the existing stale-explicit-generation path. That keeps the durability boundary (invariant 18). Callers that pass `nil` (tests, repairs) are unaffected.
- **Edge cases:**
  - Keep every `activeScanID` guard inside the `MainActor.run` blocks. Do not "simplify" them away just because the worker is already on main; the fencing lives there.
  - Keep the 20 s cadence and the "UserDefaults every 3 s" cadence.

**WS-16.4 — Phase 7: `LargeVideoScanController`**
- **Change:** New `iOSCleanup/Views/Home/LargeVideoScanController.swift`:
  ```swift
  @MainActor
  final class LargeVideoScanController: ObservableObject {
      @Published private(set) var largeFiles: [LargeFile] = []
      @Published private(set) var fileScanState: HomeViewModel.ScanState = .idle
      @Published private(set) var fileScanProgress = FileScanProgress.idle
      var onLargeFilesChanged: (([LargeFile]) -> Void)?          // facade feeds PhotoResultsStore's summary
      enum Outcome: Equatable { case completed, permissionRequired(message: String), cancelled, failed }

      init(makeEngine: @escaping @MainActor () -> FileScanEngine = { FileScanEngine() },
           resultCache: LargeVideoResultCache = .shared,
           diagnostics: ScanDiagnosticsRecorder)
      func restoreIfNeeded(authorization: PHAuthorizationStatus) async   // :2133-2180 incl. hydration single-flight
      func runScan(force: Bool) async -> Outcome                         // :1390-1479 (after the guards)
      @discardableResult func removeFile(assetID: String) -> Bool        // :1491-1519 + the cache-remove Task
      func pruneFiles(keeping validIDs: Set<String>)                     // reconcile's :1884, verbatim semantics
  }
  ```
  - `HomeViewModel.scanFiles(force:)` keeps the guards at `:1372-1389` verbatim, including the photo/video serialization (`!isFinalizingPhotoScan, scanState != .scanning`, invariant 16), reading the controller's state. It then calls `runScan`. On `.permissionRequired(message)` it sets `scanErrorMessage` and `photoAuthorizationStatus` exactly as `:1426-1427` do.
  - `removeLargeFileFromResults` calls `removeFile` and, if something was removed, does `_storageInfo = nil`, `publishProgressSnapshot()` and `persistCleanupState()`.
  - Pass-throughs: `var largeFiles`, `var fileScanState` and `var fileScanProgress` are get-only computed properties on `HomeViewModel`. Forward `objectWillChange` with Combine: `controller.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }`, stored in `cancellables`.

**WS-16.5 — Phase 8: `PhotoResultsStore`**
- **Change:** New `iOSCleanup/Views/Home/PhotoResultsStore.swift`. Move `DashboardCollectionSummary`, `PhotoGroupContentSignature`, `contentSignature` and `identifierSignature` into it unchanged.
  ```swift
  struct PreservedResults { let groups: [PhotoGroup]; let screenshots: [PHAsset]; let blurry: [PHAsset]; static let none = … }

  @MainActor
  final class PhotoResultsStore: ObservableObject {
      @Published private(set) var photoGroups: [PhotoGroup] = []
      @Published private(set) var screenshotAssets: [PHAsset] = []
      @Published private(set) var blurryAssets: [PHAsset] = []
      private(set) var summary = DashboardCollectionSummary.empty
      private(set) var duplicatePhotoGroups: [PhotoGroup] = []
      private(set) var visuallySimilarPhotoGroups: [PhotoGroup] = []
      #if DEBUG
      private(set) var summaryRebuildCount = 0
      #endif

      /// One batch ⇒ at most one summary rebuild; a collection whose signature is unchanged is not reassigned.
      func replace(groups: [PhotoGroup]? = nil, screenshots: [PHAsset]? = nil, blurry: [PHAsset]? = nil)
      /// :1708-1733 verbatim (unaffected preserved groups + update groups, unique screenshots/blurry).
      func mergeScanUpdate(_ update: PhotoScanUpdate, preserving: PreservedResults)
      func setLargeFiles(_ files: [LargeFile])     // summary input only
      func removeAll()
  }
  ```
  - **WS-12 hook:** every write path of `photoGroups` (`replace`, `mergeScanUpdate`) runs through WS-12's user-kept filter (grep `applyingUserKeptIDs` or the equivalent WS-12 helper), exactly as `HomeViewModel` applied it after WS-12.
  - Every group rebuild still goes through `PhotoGroup.init` (invariant 1). The store never rebuilds groups itself in this PR.
  - `HomeViewModel` gets get-only pass-throughs: `photoGroups`, `screenshotAssets`, `blurryAssets`, `dashboardSummary`, `duplicatePhotoGroups` and `visuallySimilarPhotoGroups`. It forwards `objectWillChange`. Restore (`:2193-2195`) becomes one `replace(...)` call (one rebuild). Reconcile's prune (`:1859-1886`) computes the same pruned arrays and calls `replace`. Keep an `internal let resultsStore` for tests.
  - `apply(update:)` calls `resultsStore.mergeScanUpdate(update, preserving:)`. `groupsFoundCount`, `reviewablePhotosCount` and `reclaimableBytesFoundSoFar` stay facade scalars, computed from the store.
  - Wire `largeVideoController.onLargeFilesChanged = { [weak resultsStore] in resultsStore?.setLargeFiles($0) }`.

### Tests
All tests run in the simulator except the Time Profiler check.
- `iOSCleanupTests/AnalysisSnapshotBuilderTests.swift`:
  - the three golden tests (WS-16.1)
  - `testFoldSubtractsEvaluatedBeforeUnioningUnanalyzed`
  - `testFoldAppliesCommittedCountOffsets`
  - `testRestoredCheckpointForCompleteSnapshotHasNoTargets`
  - `testRestoredCheckpointDropsSetsOfInconsistentIncompleteSnapshot` (mirrors `:2236-2247`)
  - `testPruneUnanalyzedKeepsOnlyExisting`
- `iOSCleanupTests/PhotoScanEngineTests.swift` (existing `withIsolatedAnalysisCacheFile`): `testOlderCaptureSequenceCannotReplaceNewerSnapshot` does `scheduleSnapshot(newer, captureSequence: 2)` and then `saveSnapshot(older, captureSequence: 1)`. The save returns, and `loadSnapshot()` returns the newer snapshot's counts.
- `iOSCleanupTests/PhotoResultsStoreTests.swift`:
  - `testReplaceRebuildsSummaryOnce`
  - `testUnchangedSignatureDoesNotPublish` (count `objectWillChange` emissions)
  - `testMergeKeepsUnaffectedPreservedGroupsAndReplacesTouchedOnes`
  - `testLargeFileBytesFeedSummary`
  - `testUserKeptHookAppliedOnMerge` (with WS-12's store double)
- `iOSCleanupTests/LargeVideoScanControllerTests.swift`, using `FileScanEngine(authorizationProvider:assetProvider:representativeResolver:)` stubs (see `FileScanEngineTests`) and `LargeVideoResultCache(directoryURL: temp)`:
  - `testDeniedAuthorizationYieldsPermissionRequiredOutcome`
  - `testCompletedScanPublishesFilesAndSavesCache`
  - `testRemoveFileAdjustsCompletedCounts`
  - `testRestoreIfNeededRestoresSeededCacheOnce`
- `iOSCleanupTests/ScalePerformanceTests.swift` (Performance plan): `testAnalysisSnapshotBuildScalesTo60kIdentifiers` runs `measure { _ = AnalysisSnapshotBuilder.build(...) }` with 60k synthetic IDs and 3k groups.

### Acceptance criteria
- [ ] Five commits (`WS-16.1` … `WS-16.5`), each warning-free with the suite green.
- [ ] The golden literals from WS-16.1 are unchanged in every later commit (byte-identical JSON).
- [ ] No view file changes: `git diff main --stat -- iOSCleanup/Views` lists only `HomeViewModel.swift` and new `Views/Home/*` files.
- [ ] `grep -n "makeAnalysisSnapshot\|\.sorted()" iOSCleanup/Views/HomeViewModel.swift` shows no snapshot construction on the main actor. Every build goes through `buildOffMain`.
- [ ] `CleanupStateStore` (WS-15), `PhotoResultsStore` and `LargeVideoScanController` have unit tests (M1 exit criterion).
- [ ] `ios-cleanup/CLAUDE.md` "ViewModel layer" lists the new types and says that snapshots are built off-main with capture-sequence ordering.

### Device QA
- **Main-thread snapshot builds.** On a 50k+ library, record a Deep Clean with the Time Profiler for 2 minutes while scrolling "Review partial results".
  - No `AnalysisSnapshotBuilder.build`, `makeAnalysisSnapshot` or `Array.sorted` frames appear on the main thread.
  - There are no hitches over 16 ms at the 20 s checkpoints.

### Pitfalls and out of scope
- **Invariant 13:** preserve the `activeScanID` fencing, the run lock (`isFinalizingPhotoScan`) and the photo/video serialization verbatim. `LargeVideoScanController` must never start a scan by itself; serialization stays in the facade.
- **Invariant 18:** pause, background and completion still await a durable save. The detached build happens *before* that await, never instead of it.
- Do not change `hasCompletedTarget`, `snapshotIsComplete`, the checkpoint cadence, or which fields are recorded. WS-19 changes the recorded inventory, and WS-21 adds `completedAt`; each of those PRs updates the golden literals with an explanation.
- **Hazard:** WS-17..WS-21, WS-23 and WS-27 edit these new types. Do not start any of them until this PR has merged.
- Out of scope: Time Profiler proof of photo throughput (WS-24), the 4 Hz render throttle (WS-50), and snapshot write cost (WS-54).
- **Reconciliation (lead L14):** WS-37 (chapter 08) later threads a run-scoped `analyzerVersion` stamp through `AnalysisSnapshotInputs`. The stamp is carried, never defaulted, and stays nil in these golden fixtures. WS-16.1's additive-field rule keeps the literals byte-identical.
- **Reconciliation (lead L15):** WS-53 (chapter 11) renames `PhotoScanUpdate.evaluatedAssetIDs`, `unanalyzedAssetIDs` and `unanalyzedFailures` to their `newly…` delta names and rewrites `fold(update:offsets:)`. It updates the fold tests in `AnalysisSnapshotBuilderTests` and the merge tests in `PhotoResultsStoreTests` that build updates with the old names.

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| FSA-12 | confirmed | Every snapshot build runs on the main actor. Fix step 2's premise is wrong: the worker `Task` inherits `@MainActor` from `scanPhotos`, so the plan builds in an explicit `Task.detached`. Moving builds off-main lets builds finish out of order, and `enqueue` assigns generations at arrival. The plan therefore adds a main-actor capture sequence and a stale-capture drop in `PhotoAnalysisCache.enqueue` (not in the finding). The 100–250 ms magnitude is an estimate; device QA measures it. |
| SCAN-M03 (merged) | confirmed | Same code path. The plan follows FSA-12's pure-builder variant, not "encode unsorted Sets", which would change the JSON and break the golden test. |

---

## WS-17 — Launch restore: linear rehydrate, one decode, no phantom rescan

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M1 | M | WS-08, WS-16 | no | `ws/17-launch-restore` |

**Primary files:** `iOSCleanup/Engines/PhotoAnalysisCache.swift`, `iOSCleanup/Engines/RestoredAnalysisState.swift` (*new*), `iOSCleanup/Views/HomeViewModel.swift`, `iOSCleanup/Views/HomeView.swift` (CTA and tiles; or the WS-10 split files), `iOSCleanup/Views/Home/PhotoResultsStore.swift`, `iOSCleanup/Views/Home/RestartScanPolicy.swift` (*new*), `iOSCleanupTests/PhotoAnalysisCacheTests.swift` (*new* unless it exists), `iOSCleanupTests/PhotoScanEngineTests.swift`, `iOSCleanupTests/ScalePerformanceTests.swift`, `iOSCleanupTests/RestartScanPolicyTests.swift` (*new*), `iOSCleanup.xcodeproj/project.pbxproj`

**Findings covered:** PERF-01 (P1, confirmed), PERF-04 (P2, confirmed; merged: STATE-10 — partially)

**Decisions applied:**
- D-HVM-DECOMP: the restore lands in `PhotoResultsStore` as one batch, and planning statics move out of the facade.
- No other decision applies. The snapshot-persistence invariant (14) constrains the memo.

### Goal
A cold launch shows saved results fast. `rehydrateGroups` is linear in group members, the snapshot is JSON-decoded at most once, and planning and consistency checks never run over library-sized sets on the main thread. While results load, the CTA reads "Loading saved results…" with a spinner and taps do nothing. The Home primary CTA can never start a forced full rescan over restored results. The gear "Scan Again" still rebuilds the library; WS-26 adds its confirmation.

### Current behavior (verified)
- `iOSCleanup/Engines/PhotoAnalysisCache.swift:403-404`: `makeGroup(using assetsByID:)` starts with `resolvedAssetIdentifiers(using: Set(assetsByID.keys))`, building a set of **all** grouped IDs per group (O(groups × members)). `rehydrateGroups` (`:768-779`) fetches every member and calls `makeGroup` per group.
- `:411-450`: the missing-member downgrade is:
  - `allMembersResolved` false ⇒ `.reviewManually`
  - empty `deleteCandidateIDs`
  - `reclaimableBytes 0`
  - "Group changed since its last scan; review manually." appended
- `:527-533` and `:544-546`: `loadSnapshot()` always decodes **both** `photo-analysis-cache.json` and `.backup.json`. `:589` evaluates `hasConsistentCompletionState` (`:61-93`, three library-sized hash passes) on each decode, and callers evaluate it again.
- `iOSCleanup/Views/HomeViewModel.swift` calls `loadSnapshot()` from:
  - `performCachedAnalysisRestore` (`:2184`)
  - `scanNewPhotosIfNeeded` (`:1929`)
  - `scanPhotos` (`:956`)
  - `restartPhotoScan` (`:843`)
  - `retryIncludingICloudPhotos` (`:1356`)
  - reconcile (`:1913`)
  - `makeDiagnosticReport` (`:2377`)
  A launch with new photos therefore decodes 6 times.
- The bootstrap `Task(priority: .utility)` (`:324-330`) inherits `@MainActor`. As a result, these run on main:
  - `Set`/`Dictionary` building in restore (`:2228-2250`)
  - `assetIDsRequiringAnalysis` (`:1948-1966`)
  - `PhotoScanResumePlanner.requiredAssetIDs` (`:984-993`)
- `init` → `bootstrapLibraryStateIfNeeded` → `startPhotoLibraryObservationIfDetermined()` (`:323`) registers the PhotoKit observer synchronously, before the first frame.
- **Phantom rescan.**
  - During restore, the UserDefaults scalars say `.completed` with `lastCompletedGroupsCount > 0` while `photoGroups` is empty.
  - `HomeView.swift:343-366` `ctaTitle` falls through to "Scan again", and `handleCTAAction` (`:426-448`) calls `restartPhotoScan()`.
  - `restartPhotoScan` (`HomeViewModel.swift:837-853`) loads a complete snapshot and calls `scanPhotos(forceFullRescan: true)`, which clears the preserved results (`:1062-1064`).
  - The completion sheet's "Scan Again" (`HomeView.swift:1062-1066`) takes the same path.
- `iOSCleanupTests/PhotoScanEngineTests.swift:822-990` holds cache tests that must keep passing:
  - `testCacheLoadChoosesNewerBackupGeneration` writes a primary at generation 5 and a *newer* backup at generation 6 and expects 6.
  - `testSavePreservesNewerBackupBeforeReplacingPrimary`
  - `testCorruptCurrentCheckpointFallsBackToPriorValidGeneration`

### Implementation plan

**WS-17.1 — PERF-01: linear `makeGroup`, deduplicated rehydrate**
- **Why:** At 6,000 groups and 15,000 members, the per-group `Set(assetsByID.keys)` costs about 90M hash inserts, several seconds on A12–A15.
- **Change:**
  - In `CachedPhotoGroup.makeGroup(using:)`, replace the first line with:
    ```swift
    let resolvedIdentifiers = assetIdentifiers.filter { assetsByID[$0] != nil }
    guard resolvedIdentifiers.count >= 2 else { return nil }
    ```
    Everything below stays identical (`resolvedIDSet`, `allMembersResolved`, downgrade). Keep `resolvedAssetIdentifiers(using:)` for other callers.
  - In `rehydrateGroups`: `let identifiers = PhotoAssetIdentity.uniqueIdentifiers(snapshot.groups.flatMap(\.assetIdentifiers))`, then `assetsByID.reserveCapacity(identifiers.count)`.
  - Keep WS-09's `restore.rehydrate` interval around the new fetch and map. It uses `PhotoDuckSignposts.interval("restore.rehydrate") { … }`, WS-09's single `.pointsOfInterest` signposter in `iOSCleanup/Utilities/PhotoDuckSignposts.swift`. Do not add a second signposter or a separate "Launch" category.
  - Remove the PERF-01 `XCTExpectFailure` wrapper from WS-08's benchmark in `ScalePerformanceTests.swift`.
- **Edge cases:** Duplicate IDs inside one group's `assetIdentifiers` behave exactly as before (the filter preserves them).

**WS-17.2 — Restore-window CTA and the primary-CTA rescan guard**
- **Why:** Tapping the big button during the restore window starts a 30–90 minute forced rescan and discards the results.
- **Change:**
  - HomeView CTA: when `viewModel.heroState == .restoringResults` (from WS-15), put `ProgressView().tint(.white)` next to the title in the existing `ctaButton` HStack. The title, no-op tap and disabled state already come from WS-15.
  - Tiles: `categoryStatus(for:)` and `categoryNote(for:)` (`HomeView.swift:864, 916`), plus the Screenshots and Blurry notes, return "Loading…" while `viewModel.isRestoringSavedResults`.
  - New `iOSCleanup/Views/Home/RestartScanPolicy.swift`:
    ```swift
    enum RestartScanAction: Equatable { case none, resume, incremental(CleanupMode), forcedFullRescan(CleanupMode) }
    enum RestartScanPolicy {
        /// Called only after restore has completed. `hasRestoredGroups` is passed as true only
        /// for the Home primary CTA (the phantom "Scan again" path).
        static func action(scanState: HomeViewModel.ScanState, hasRestoredGroups: Bool,
                           snapshotIsIncomplete: Bool?, snapshotMode: CleanupMode?,
                           lastCompletedMode: CleanupMode?) -> RestartScanAction
    }
    ```
    The rules are:
    1. `hasRestoredGroups` ⇒ `.none`, because saved results exist and the CTA is "Review".
    2. Else `.paused` ⇒ `.resume`.
    3. Else an incomplete snapshot ⇒ `.incremental(snapshotMode)`.
    4. Else ⇒ `.forcedFullRescan(lastCompletedMode ?? .deepClean)`.
  - `restartPhotoScan(fromPrimaryCTA: Bool = false)`:
    - Keep the synchronous `.paused` shortcut.
    - In the Task, first `await restoreCachedAnalysisIfNeeded()`, then `loadSnapshot()` (a memo hit).
    - Then switch on `RestartScanPolicy.action(…, hasRestoredGroups: fromPrimaryCTA && !photoGroups.isEmpty, …)`.
  - HomeView's `handleCTAAction` branch that calls `restartPhotoScan()` passes `fromPrimaryCTA: true`.
  - The other callers keep the default `false`: the gear "Scan Again", the completion sheet's "Scan Again" and the Similar `.freshScan`. Rule 1 never applies to them, so they keep today's behavior: an incomplete snapshot ⇒ incremental, otherwise `scanPhotos(forceFullRescan: true)`. Their only change is the restore await, so they never plan from an unhydrated window. Do **not** add an unconditional restored-groups early return: that would turn the gear "Scan Again" into a no-op.
- **Edge cases:**
  - Only the Home primary CTA can reach rule 1.
  - WS-26 (chapter 06) deletes `restartPhotoScan` and splits it into `refreshPhotoScan()` (incremental) and the confirmed `rescanEntireLibrary()` (forced, no early return). It routes the CTA through `startPhotoScan(from: .homePrimaryCTA)`, which is incremental by construction. `RestartScanPolicy` then has no caller, and WS-26 deletes it with `RestartScanPolicyTests` (chapter 06, WS-26.4).
  - Asking the user before a forced rescan is WS-26 (UI-19); do not add a dialog here.

**WS-17.3 — PERF-04 and STATE-10: one decode, memoized**
- **Why:** At about 20 MB per file, every `loadSnapshot()` costs 0.8–2 s of CPU and two decoded copies in memory.
- **Change** in `PhotoAnalysisCache`:
  ```swift
  private var memoizedSnapshot: CachedPhotoAnalysisSnapshot?
  #if DEBUG
  private(set) var debugDiskDecodeCount = 0          // read-path JSON decodes only (the writer still decodes until WS-54)
  #endif

  func loadSnapshot() -> CachedPhotoAnalysisSnapshot? {
      if let memoizedSnapshot { return memoizedSnapshot }
      let newest = loadNewestFromDisk()               // inside WS-09's "restore.decode" interval (PhotoDuckSignposts)
      hasHydratedDiskOrdering = true
      if let newest { recordPersistenceOrdering(from: newest); memoizedSnapshot = newest }
      return newest
  }

  /// Decode the primary. Decode the backup only when the primary is missing, fails to decode, is oversize,
  /// has the wrong schema, is inconsistent, OR the backup file's modificationDate is >= the primary's
  /// (the writer always writes the backup BEFORE the primary, so a later backup mtime means a recovery
  /// state where the backup can be the newer generation). Selection stays `newestSnapshot(in:)`.
  private func loadNewestFromDisk() -> CachedPhotoAnalysisSnapshot?

  func purgeMemo() { memoizedSnapshot = nil }        // ordering (latestGeneration) is kept
  ```
  - `hydrateDiskOrderingIfNeeded()` uses `loadNewestFromDisk()` and also sets the memo.
  - In `drainPendingSnapshots`, on a successful write set `memoizedSnapshot = snapshot` (the ordered snapshot just written) when its generation is at least the memo's. On a failed write, keep the previous memo; the disk still holds it.
  - In `init`, register for `UIApplication.didReceiveMemoryWarningNotification` with the same pattern as `PhotoImageRepository.init` (`SharedHelpers.swift:283-291`): `Task { await self?.purgeMemo() }`. WS-25 also calls `purgeMemo()` under memory pressure.
  - Add `PhotoAnalysisCache.init(directoryURL:)` if WS-07 or WS-15 have not.
- **Edge cases:**
  - Generation ordering and "never overwrite a newer backup" are unchanged. Do **not** touch the write path's `photoAnalysisCacheCandidate` decodes (WS-54).
  - The memo only ever holds a snapshot that is on disk.
  - After `purgeMemo()` the next load decodes again.
  - WS-48 calls `purgeMemo()` when clearing data.

**WS-17.4 — O(1) consistency flag, off-main planning, one-batch restore**
- **Change:**
  - `CachedPhotoAnalysisSnapshot`: move the `:61-93` body into `static func computeConsistentCompletionState(isComplete:libraryTotalCount:libraryAssetIdentifiers:libraryAssets:evaluatedAssetIdentifiers:scanTargetCount:processedPhotoCount:progressFraction:cleanupMode:) -> Bool`, verbatim.
    - Add `let hasConsistentCompletionState: Bool`, assigned at the end of `init(savedAt:…)` and `init(from:)`. It is not in `CodingKeys`, so it is never encoded.
    - `withPersistenceGeneration` copies the flag through a private initializer overload instead of recomputing it, so `enqueue` stays O(1).
    - **Never loosen the rule.**
  - `PhotoScanResumePlanner`: add `static func assetIDsRequiringAnalysis(snapshot:currentAssetIDs:currentMetadata:) -> Set<String>` (the `HomeViewModel.swift:1948-1966` body). Callers in `HomeViewModel` run it and `requiredAssetIDs(...)` inside `await Task.detached(priority: .utility) { … }.value` with Sendable copies. After the planner await in `scanPhotos`, add `guard activeScanID == scanID else { return }`, mirroring the guard at `:983`.
  - New `iOSCleanup/Engines/RestoredAnalysisState.swift`:
    ```swift
    struct RestoredAnalysisState: @unchecked Sendable {
        let snapshot: CachedPhotoAnalysisSnapshot
        let snapshotIsComplete: Bool                         // isComplete && hasConsistentCompletionState
        let groups: [PhotoGroup]
        let screenshots: [PHAsset]
        let blurry: [PHAsset]
        let libraryIdentifiers: Set<String>
        let libraryMetadata: [String: CachedPhotoAssetMetadata]
        let checkpoint: AnalysisCheckpointState              // .restored(from:snapshotIsComplete:)
        let reviewableCount: Int
        let reclaimableBytes: Int64
    }
    extension PhotoAnalysisCache {
        func restoreState() -> RestoredAnalysisState?        // loadSnapshot + rehydrate + sets, all on the actor
    }
    ```
  - `performCachedAnalysisRestore()` becomes: `guard let restored = await analysisCache.restoreState()` (nil ⇒ WS-15's nil path), then assign the scalars and one `resultsStore.replace(groups:screenshots:blurry:)`, which is one summary rebuild. `checkpoint = restored.checkpoint` and `knownLibrary* = restored.library*` are O(1) assignments. Then run WS-15's reconciler.
  - Move `startPhotoLibraryObservationIfDetermined()` out of the synchronous part of `bootstrapLibraryStateIfNeeded()` into the bootstrap Task as its first step, after `await Task.yield()`. It stays idempotent and is still called from `refreshLibraryMetadata()`. WS-18 later moves it into `PhotoLibraryInventory`.
- **Edge cases:**
  - Constructing a `CachedPhotoAnalysisSnapshot` now costs O(N). Never construct one on the main actor in a hot path. The builder (WS-16) is already detached. The one-shot repair paths (`repairPrematureCompletion`, and WS-19's repair) may stay where they are.
  - `hasCompleteAnalysisCoverage` still reads the stored flag.

### Tests
All tests run in the simulator. `ScalePerformanceTests` belong to the Performance plan.
- `iOSCleanupTests/PhotoScanEngineTests.swift`:
  - `testMakeGroupDowngradesWhenMemberMissing`: one of three members is absent from `assetsByID`. Assert `.reviewManually`, empty `deleteCandidateIDs` and `reclaimableBytes == 0`.
  - `testMakeGroupKeepsPlanWhenAllMembersResolve`
  - `testConsistencyFlagIsNotEncoded`: the JSON has no `hasConsistentCompletionState` key, and decoding reproduces the same flag.
  - The existing consistency fixtures (`:1076-1316`) must pass unchanged.
- `iOSCleanupTests/PhotoAnalysisCacheTests.swift` (temp directory per test via `PhotoAnalysisCache(directoryURL:)`):
  - `testRepeatedLoadsDecodeOnce`: three loads give `debugDiskDecodeCount == 1`.
  - `testLoadAfterSaveUsesMemoWithoutDecode`
  - `testPrimaryOnlyWhenBackupIsOlder`: both files present, the backup's mtime set earlier via `FileManager.setAttributes`, and the decode count is 1.
  - `testNewerBackupByModificationDateIsDecodedAndChosen`
  - `testCorruptPrimaryFallsBackToBackup`
  - `testPurgeMemoForcesRedecode`
  - `testFailedWriteKeepsPreviousMemo`: write into a read-only directory, or inject an oversize snapshot.
- `iOSCleanupTests/RestartScanPolicyTests.swift`:
  - `testRestoredGroupsNeverRescan`
  - `testPausedResumes`
  - `testIncompleteSnapshotRunsIncremental`
  - `testCompleteSnapshotWithoutGroupsForcesFullRescan`
- `iOSCleanupTests/ScalePerformanceTests.swift`:
  - WS-08's PERF-01 benchmark passes without `XCTExpectFailure`.
  - `testMakeGroupRestoreIsLinearInMembers`: 1,000 vs 4,000 groups of 3; assert `time(4k) < 6 × time(1k)`.
  - `testRequiredAssetIDsAt60kIsFast`: `measure`, budget 200 ms in the simulator.

### Acceptance criteria
- [ ] The launch path performs at most one analysis-snapshot JSON decode (`debugDiskDecodeCount`, unit test, and a DEBUG launch log on device).
- [ ] The existing cache tests (`testCacheLoadChoosesNewerBackupGeneration`, `testSavePreservesNewerBackupBeforeReplacingPrimary`, `testCorruptCurrentCheckpointFallsBackToPriorValidGeneration`, `testFirstSaveHydratesExistingDiskGenerationBeforeEnqueue`, `testExplicitStaleGenerationCannotReplaceNewerSnapshot`) pass unmodified.
- [ ] The CTA never shows "Scan again" while saved results load, and the Home primary CTA (`restartPhotoScan(fromPrimaryCTA: true)`) never reaches `scanPhotos(forceFullRescan: true)` when restored groups exist (policy tests).
- [ ] With the default `fromPrimaryCTA: false`, `restartPhotoScan` has no restored-groups early return, so the gear "Scan Again" still rebuilds the library when groups exist (code review plus Device QA).
- [ ] WS-08's PERF-01 benchmark is green with no `XCTExpectFailure`.
- [ ] Restoring 5,000 groups / 15,000 members takes under 300 ms on an iPhone 12 (`restore.rehydrate` signpost; device).
- [ ] Time Profiler attributes no main-thread slice over 16 ms to restore or planning on a 60k launch (device).
- [ ] `ios-cleanup/CLAUDE.md` `PhotoAnalysisCache` row mentions the read memo, the primary-first decode rule and `purgeMemo`.

### Device QA
- **Restore signposts.** On a 50k library with 3,000+ groups, cold launch with Instruments (os_signpost and Time Profiler). Record the `restore.decode` and `restore.rehydrate` durations in `docs/DEVICE_QA.md`.
  - The hero shows "Loading saved results" with a spinner, and tapping the CTA does nothing.
  - The CTA then becomes "Review N groups ready".
  - Similar tab › gear › "Scan Again" with restored groups starts a full rescan. It is not a no-op.
- **Memory warning.** With the app open, trigger a memory warning (Xcode ▸ Debug ▸ Simulate Memory Warning on device builds), then start a scan. The logs show one re-decode, and the scan plans normally.

### Pitfalls and out of scope
- **Invariant 14:** the memo must never hold a snapshot that is not on disk, never be set from a failed write, and never change generation ordering or backup protection.
- The write path still decodes both files. That is WS-54 (chapter 11).
- Do not change the incremental planner's semantics. Only its thread moves.
- The Scan Again confirmation (UI-19) is WS-26 (chapter 06). Thermal and memory policy beyond `purgeMemo` is WS-25 (chapter 05). The library inventory is WS-18.
- **Reconciliation (lead L1):** this PR guards only the Home primary CTA's phantom-rescan path, through `restartPhotoScan(fromPrimaryCTA: true)`. Other callers keep today's behavior, so the gear "Scan Again" is never a no-op. WS-26 replaces `restartPhotoScan` with `refreshPhotoScan()`/`rescanEntireLibrary()` and deletes the then-uncalled `RestartScanPolicy`.
- **Reconciliation (lead L21):** WS-54 keeps per-slot state inside the `PhotoAnalysisCache` actor and relies on this PR's primary-first mtime read rule; there is no sidecar. Rotation by rename keeps the older mtime on the backup, so `loadNewestFromDisk()` stays correct.
- **Reconciliation (lead L14):** WS-37 (chapter 08) adds `CachedPhotoAnalysisSnapshot.analyzerVersion` later. The private initializer overload used by `withPersistenceGeneration` must copy it (carried, never defaulted), and WS-37 extends that overload. The existing cache tests and `testConsistencyFlagIsNotEncoded` must not assert the snapshot's full key set.
- **Reconciliation:** signposts use WS-09's `PhotoDuckSignposts` intervals (`restore.decode`, `restore.rehydrate`) on its single `.pointsOfInterest` signposter, not a new "Launch" signposter.

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| PERF-01 | confirmed | The quadratic `Set(assetsByID.keys)` and the phantom "Scan again" → `forceFullRescan` path are exactly as described. The time estimates are unverified, so a device signpost acceptance was added. The plan uses WS-15's `restoringResults` hero state instead of a separate flag for the CTA, and a pure `RestartScanPolicy` instead of inline logic, so the "no forced rescan" rule is unit-tested without PhotoKit. The policy guards only the Home primary CTA; the gear "Scan Again" is not turned into a no-op (lead L1), and WS-26 replaces `restartPhotoScan`. |
| PERF-04 | confirmed | 6 decodes per launch with new photos, O(N) consistency on every access, main-actor planning, and synchronous observer registration in `init` are all confirmed. The plan follows fix items 1, 3, 4 and 5. Item 2 (sidecar) is not built: WS-54 keeps per-slot state in the actor and relies on this PR's mtime rule (lead L21). |
| STATE-10 (merged) | partially | Decoding both files per call is real. The proposed rule ("backup only when the primary is missing, corrupt, wrong-schema or inconsistent") would break `testCacheLoadChoosesNewerBackupGeneration`, where the backup is legitimately a newer generation. The plan adds one cheap condition: also decode the backup when its modification date is at least the primary's. The writer always writes the backup first, so in steady state only the primary is decoded. |

---

## WS-18 — Photo library inventory: single-flight, incremental, shared with the engine

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M1 | L | WS-17 | yes | `ws/18-library-inventory` |

**Primary files:** `iOSCleanup/Engines/PhotoLibraryInventory.swift` (*new*), `iOSCleanup/Engines/PhotoLibraryFetch.swift` (*new*), `iOSCleanup/Views/HomeViewModel.swift`, `iOSCleanup/Engines/PhotoScanEngine.swift`, `iOSCleanup/Engines/PhotoAnalysisCache.swift`, `iOSCleanup/ContentView.swift` (only if scene-phase plumbing needs it), `iOSCleanup/Utilities/SharedHelpers.swift` (diagnostic factories only), `iOSCleanupTests/PhotoLibraryInventoryTests.swift` (*new*), `iOSCleanupTests/PhotoScanEngineTests.swift`, `iOSCleanup.xcodeproj/project.pbxproj`

**Findings covered:** PERF-05 (P2, confirmed; merged: STATE-11)

**Decisions applied:**
- D-INVENTORY: one single-flight `PhotoLibraryInventory` with persistent-change-token deltas and a full-enumeration fallback. It refreshes on activation only when returning from the background, and only if the library is dirty or 30 s have passed. The engine consumes the inventory's ordered fetch, and missing required IDs are dropped, with a throw only on an empty or <90% fetch.
- D-HVM-DECOMP: this PR is phase 6 (the inventory leaves `HomeViewModel`).
- D-LIMITED-ACCESS: under `.limited` the token path is never used, and no token is persisted (only full enumeration of the small selection).

### Goal
The library is enumerated once where it used to be four or five times:
- A cold launch with an unchanged library does no full enumeration.
- Control Center, notification-shade and app-switcher peeks never enumerate.
- A scan start enumerates exactly once, shared by planning and the engine. Planning and the engine therefore see identical asset sets.
- Overlapping refreshes can't apply out of order.
- A photo deleted between planning and fetch is dropped and reported instead of failing the scan.

### Current behavior (verified)
- `iOSCleanup/Views/HomeViewModel.swift:2528-2548`: `currentLibraryPhotoMetadata()` runs `PHAsset.fetchAssets(with: .image, options: nil)` and reads five properties per asset. WS-07 moved it verbatim to `HomeViewModelDependencies.systemLibraryPhotoMetadata()`, reached through the `fetchLibraryPhotoMetadata` closure. Authorization reads go through WS-07's `dependencies.authorizationStatus()`.
- `refreshLibraryMetadata()` (`:1586-1625`) assigns `knownLibraryAssetMetadata` and `knownLibraryAssetIdentifiers` in completion order, with no single-flight or generation. It is called from:
  - every `.active` (`:1575-1577`; ContentView forwards every phase, `ContentView.swift:22-24`, so `.inactive → .active` from Control Center counts)
  - `requestPhotoAccess` (`:552`)
  - `scanNewPhotosIfNeeded` (`:1932`/`:1937`)
  - `scanPhotos` (`:954`)
  - reconcile (`:1903`)
- `iOSCleanup/Engines/PhotoScanEngine.swift:61-80`: `SystemPhotoScanAssetProvider` requests authorization, fetches sorted by `creationDate`, and materializes every `PHAsset`.
- `:419-434` re-fetches once only when the first fetch was short. "Skip the second fetch unless the first was short" is already today's behavior.
- `:438-451`: any planned required ID missing from the engine's fetch throws `photoLibraryTemporarilyUnavailable`.
- The engine re-sorts an already-sorted array:
  - `:1550` (Deep Clean)
  - `:1560` (incremental)
  - `:1493` (Speed Clean)
  - `SharedHelpers.swift:506-512`
  Swift's sort is near-linear on sorted input, so the "~2M `creationDate` calls" estimate is overstated. It is still about 2 bridged `creationDate` reads per element per sort.
- `repairPrematureCompletion` (`:2272-2280`) enumerates and sorts again.
- `PHPersistentChangeToken` and `fetchPersistentChanges(since:)` (iOS 16+) are unused, and no `PHFetchResult` is retained.
- `PhotoLibraryChangeObserverProxy` (`:36-52`) discards the `PHChange`.
- The notDetermined rule is at `:312-346` and `:1588-1590`. WS-07 adds `observesPhotoLibrary` to `HomeViewModelDependencies`.
- The engine calls ML retention with `Set(allAssets…)` (`:534-536`, `:970-973`). A silently truncated shared fetch would therefore prune ML rows, so the cross-check against an independent count must survive.

### Implementation plan

**WS-18.0 — Verify first (device; no code merged)**
- On the WS-09 baseline device, use a throwaway DEBUG action or a unit test run on device to check three things:
  1. Under **Full** access, `PHPhotoLibrary.shared().currentChangeToken`, then add, edit and delete one photo each, then `fetchPersistentChanges(since:)`: `changeDetails(for: .asset)` should list the inserted, updated and deleted identifiers.
  2. The same under **Limited**. Record whether it throws, or reports only selected assets.
  3. Enumeration time for `PHAsset.fetchAssets(with:.image)` plus five property reads at the baseline library size.
- Record all three in `docs/DEVICE_QA.md`.
- If step 1 fails, implement WS-18.1–18.5 and skip WS-18.6: the full-enumeration fallback still removes the redundant enumerations. Step 2 does not change the design, because Limited never uses tokens.

**WS-18.1 — `PhotoLibraryFetch`: shared options, sorted-input fast path, prefetched provider**
- **Change:** New `iOSCleanup/Engines/PhotoLibraryFetch.swift`:
  ```swift
  enum PhotoLibraryFetch {
      /// The single definition of "the image library". includeAllBurstAssets stays false until WS-40;
      /// includeHiddenAssets false (PhotoKit default). Used by the inventory, the engine provider and repair.
      static func imageOptions(sortedByCreationDate: Bool = true) -> PHFetchOptions
      static func videoOptions() -> PHFetchOptions
  }
  extension Array where Element == PHAsset {
      var isSortedByCreationDate: Bool              // same nil→.distantPast mapping as sortedByCreationDate
      func sortedByCreationDateIfNeeded() -> [PHAsset] { isSortedByCreationDate ? self : sortedByCreationDate() }
  }
  final class PrefetchedPhotoScanAssetProvider: PhotoScanAssetProviding, @unchecked Sendable {
      /// First call returns the prefetched array; any later call (the engine's short-fetch retry) does a fresh
      /// sorted system fetch via `refetch`. Keeps the authorization check (status must be .authorized/.limited,
      /// read without prompting; throws ScanError.permissionDenied otherwise).
      init(assets: [PHAsset],
           authorizationStatus: @escaping @Sendable () -> PHAuthorizationStatus,
           refetch: @escaping @Sendable () async -> [PHAsset])
  }
  ```
  - `SystemPhotoScanAssetProvider` uses `PhotoLibraryFetch.imageOptions()`.
  - In the engine, `prioritizedAssets(.deepClean)` (`:1550`) and `incrementalAssets` (`:1560`) call `sortedByCreationDateIfNeeded()`. Leave the Speed Clean path and `:482` alone: those sort derived subsets.
- **Edge cases:** Swift's `sort` is stable in practice, so skipping it on sorted input returns the identical array, including for equal dates. A test pins this.

**WS-18.2 — `PhotoLibraryInventory` core (single-flight, generations, dirty flag, observer)**
- **Change:** New `iOSCleanup/Engines/PhotoLibraryInventory.swift`:
  ```swift
  protocol PhotoLibrarySource: Sendable {
      func authorizationStatus() -> PHAuthorizationStatus
      func requestAuthorization() async -> PHAuthorizationStatus
      func currentChangeTokenData() -> Data?                        // archived PHPersistentChangeToken
      func enumerateImages(includeAssets: Bool) async -> ImageEnumeration
      func imageCount() -> Int                                      // PHAsset.fetchAssets(...).count, cheap
      func changes(sinceTokenData: Data) async throws -> PersistentLibraryChanges
      func metadata(forImageIdentifiers ids: [String]) async -> [String: CachedPhotoAssetMetadata]
      func videoFetch() async -> RetainedFetch?                     // PhotoLibraryFetch.videoOptions(); fetch only, no enumeration
  }
  struct RetainedFetch: @unchecked Sendable { let result: PHFetchResult<PHAsset> }
  struct ImageEnumeration: @unchecked Sendable {
      let tokenDataBeforeRead: Data?          // captured BEFORE enumerating: never misses a change
      let metadataByID: [String: CachedPhotoAssetMetadata]
      let orderedAssets: [PHAsset]?           // creation-date order, when includeAssets
      let fetchResult: PHFetchResult<PHAsset>?
  }
  struct PersistentLibraryChanges: Sendable { let inserted, updated, deleted: Set<String>; let tokenData: Data? }

  enum InventoryRefreshReason: String, Sendable { case launch, activation, scanStart, libraryChange, authorizationChange, manual }

  @MainActor
  final class PhotoLibraryInventory {
      private(set) var metadataByID: [String: CachedPhotoAssetMetadata] = [:]
      private(set) var identifiers: Set<String> = []
      private(set) var changeTokenData: Data?
      private(set) var isDirty = true
      private(set) var lastRefreshAt: Date?
      private(set) var analyzedInventory: [String: CachedPhotoAssetMetadata] = [:]   // last snapshot's libraryAssets
      private(set) var retainedImageFetchResult: PHFetchResult<PHAsset>?            // WS-21 applies changeDetails
      private(set) var retainedVideoFetchResult: PHFetchResult<PHAsset>?            // WS-27 consumes
      private(set) var videoCount: Int?                                              // retained video fetch count; WS-27's videoCountProvider
      var onVideosInserted: (@MainActor (Int) -> Void)?                              // inserted-video count; fired here (WS-18.2), set by WS-27
      func applyVideoChange(_ delta: VideoChangeDelta)                              // internal; the observer and tests call it
      #if DEBUG
      private(set) var debugFullEnumerationCount = 0
      private(set) var debugDeltaRefreshCount = 0
      #endif
      var onLibraryChange: (@MainActor () -> Void)?                                  // → schedulePhotoLibraryRefresh

      init(source: any PhotoLibrarySource = SystemPhotoLibrarySource(), observesPhotoLibrary: Bool = true,
           now: @escaping @Sendable () -> Date = { Date() })
      func authorizationStatus() -> PHAuthorizationStatus
      func startObservingIfDetermined()                 // owns PhotoLibraryChangeObserverProxy (moved from HomeViewModel)
      func seed(fromSnapshotLibrary: [CachedPhotoAssetMetadata], changeTokenData: Data?)   // restore; sets analyzed + live base
      func setAnalyzedInventory(_ metadata: [CachedPhotoAssetMetadata])                     // after a completed snapshot is built
      func refresh(reason: InventoryRefreshReason) async
      func prepareScanFetch() async -> PhotoScanFetch
      func pendingAnalysisIDs() async -> Set<String>    // detached PhotoScanResumePlanner.assetIDsRequiringAnalysis(live vs analyzed)
  }
  struct PhotoScanFetch: @unchecked Sendable { let orderedAssets: [PHAsset]; let independentCount: Int; let generation: UInt64 }
  struct VideoChangeDelta: @unchecked Sendable {
      let insertedCount: Int?                       // changeDetails.insertedObjects.count; nil when details are unavailable
      let resultAfterChanges: PHFetchResult<PHAsset>?   // nil in tests
      let countAfter: Int
  }
  ```
  - `SystemPhotoLibrarySource` (in `PhotoLibraryFetch.swift`) runs every PhotoKit read in `Task.detached(priority: .utility)`. Its `enumerateImages` is WS-07's `HomeViewModelDependencies.systemLibraryPhotoMetadata()` body (formerly `currentLibraryPhotoMetadata`), using `PhotoLibraryFetch.imageOptions()`, optionally collecting the ordered array and the fetch result in the same pass. Keep WS-09's `inventory.enumerate` signpost around it.
  - **Single-flight:**
    ```swift
    private var inFlight: Task<Void, Never>?
    func refresh(reason: InventoryRefreshReason) async {
        if let inFlight { await inFlight.value; return }        // concurrent callers share the flight
        let task = Task { @MainActor in
            var followUpsLeft = 1
            repeat {
                isDirty = false                                // a change during the flight sets it again
                await performRefresh(reason: reason, generation: nextGeneration())
            } while isDirty && followUpsLeft-- > 0             // exactly one follow-up
        }
        inFlight = task; await task.value; inFlight = nil
    }
    ```
  - **Generations:** `performRefresh` and `prepareScanFetch` stamp a monotonic generation when they *start* and apply their result only if it is greater than `appliedGeneration`. `prepareScanFetch` awaits any in-flight refresh first, then runs its own enumeration, which also refreshes metadata.
  - The observer proxy's `photoLibraryDidChange` sets `isDirty = true` (hopping to main) and calls `onLibraryChange`. WS-21 extends it to pass the `PHChange`.
  - **Video signals (lead L3).** WS-27 (chapter 06) consumes these with exactly these names:
    - `videoCount` is the retained video fetch result's `count`. It is nil until the first refresh or scan start creates the retained result (WS-18.4), and while `.notDetermined`.
    - `onVideosInserted(n)` fires when `n` new video assets were inserted.
    - In `photoLibraryDidChange`, the proxy computes `change.changeDetails(for: retainedVideoFetchResult)` for the retained video result only. With details, it builds `VideoChangeDelta(insertedCount: details.insertedObjects.count, resultAfterChanges: details.fetchResultAfterChanges, countAfter: details.fetchResultAfterChanges.count)`. Without details, it re-fetches through `source.videoFetch()` and passes `insertedCount: nil`.
    - It then hops to main and calls `applyVideoChange(_:)`. That stores the new result and `videoCount`, then calls `onVideosInserted?(n)` with `n = insertedCount ?? max(0, countAfter - (old videoCount ?? countAfter))`, only when `n > 0`. Removals and updates never fire it.
    - Nothing here reads video metadata. The images path is unchanged until WS-21.3.
  - **notDetermined:** every inventory method except `authorizationStatus()` and `requestAuthorization()` returns immediately without touching PhotoKit while the status is `.notDetermined` (invariant 20). `observesPhotoLibrary == false` (tests) never registers the proxy.
  - **`HomeViewModel`:**
    - Add `private let inventory: PhotoLibraryInventory`. Build it from WS-07's `observesPhotoLibrary` and a new `HomeViewModelDependencies.librarySource: any PhotoLibrarySource` field with the production default `SystemPhotoLibrarySource()` (WS-07's grow-with-defaults pattern).
    - `librarySource` replaces WS-07's `authorizationStatus` and `fetchLibraryPhotoMetadata` closures; WS-07 names WS-18 as their replacement:
      - Delete both fields.
      - Move `systemLibraryPhotoMetadata()` into `SystemPhotoLibrarySource`.
      - Update `.live`, `.debugFixture()` and WS-07's `makeIsolatedDependencies(assets:analyzer:authorization:)` to supply a source. The harness uses a `FakePhotoLibrarySource` built from its assets and authorization status.
    - `knownLibraryAssetIdentifiers` and `knownLibraryAssetMetadata` become computed reads of the inventory.
    - `refreshLibraryMetadata(reason:)` wraps `await inventory.refresh(reason:)`, then does today's VM-side work from `:1599-1625` (unanalyzed prune through `checkpoint.pruneUnanalyzed`, `libraryTotalCount`, freshness, persist). WS-21 replaces the freshness part.
    - Every authorization read in `HomeViewModel` (WS-07's `dependencies.authorizationStatus()` calls) goes through `inventory.authorizationStatus()`, so authorization stays injectable (WS-20 relies on this).
    - Restore (WS-17's `performCachedAnalysisRestore`) calls `inventory.seed(fromSnapshotLibrary: restored.snapshot.libraryAssets, changeTokenData: restored.snapshot.libraryChangeTokenData)`.
    - After a **complete** snapshot is built (the worker's completion path), call `inventory.setAnalyzedInventory(snapshot.libraryAssets)`.
  - `assetIDsRequiringAnalysis` callers use `await inventory.pendingAnalysisIDs()`.
- **Edge cases:**
  - `seed` only replaces the live base if nothing has been applied yet in this process (`appliedGeneration == 0`), and it marks the inventory dirty.
  - An authorization change (WS-20) calls `inventory.resetForAuthorizationChange()`, which drops the token, the base and the retained results, and marks the inventory dirty. Add it now as a small method.

**WS-18.3 — Activation rule**
- **Change:**
  - New pure `enum InventoryActivationPolicy { static func shouldRefresh(returningFromBackground: Bool, isDirty: Bool, lastRefreshAt: Date?, now: Date, minimumInterval: TimeInterval = 30) -> Bool }` (in `PhotoLibraryInventory.swift`). It returns `returningFromBackground && (isDirty || lastRefreshAt == nil || now − lastRefreshAt > minimumInterval)`.
  - In `updateScenePhase`:
    - add `private var wasInBackground = false`
    - `.background`: `wasInBackground = true`
    - `.active`: `let returning = wasInBackground; wasInBackground = false`, then refresh only if the policy says so.
  - iOS delivers `.background → .inactive → .active` on return, which is why this is a flag rather than a comparison with the previous phase. Control Center and app-switcher peeks never reach `.background`.
- **Edge cases:** Keep `isBackgroundExecutionState = false` and `persistCleanupState()` on every `.active`. Reading the authorization status on every `.active` is WS-20.

**WS-18.4 — Scan start: one shared fetch**
- **Change** in `scanPhotos`:
  1. If `inventory.authorizationStatus() == .notDetermined`: `_ = await inventory.requestAuthorization()`. This is the in-context prompt of a user-initiated scan (runtime RT-4). Then update `photoAuthorizationStatus` and call `bootstrapLibraryStateIfNeeded()`, as `requestPhotoAccess` does. Do **not** call WS-20's transition handler from here.
  2. Replace `await refreshLibraryMetadata()` (`:954`) with `let fetch = await inventory.prepareScanFetch()` plus the VM-side scalar updates.
  3. `repairPrematureCompletion` takes `fetch.orderedAssets.map(\.localIdentifier)` instead of enumerating (`:2272-2280` removed).
  4. Engine creation (`:1151`) passes the new provider:
     ```swift
     PhotoScanEngine(assetProvider: PrefetchedPhotoScanAssetProvider(
         assets: fetch.orderedAssets, authorizationStatus: { … }, refetch: { … }))
     ```
     Also pass `expectedLibraryPhotoCount: fetch.independentCount`.
  - `prepareScanFetch` takes `independentCount = source.imageCount()` right after its enumeration. The engine's existing short-fetch retry (`:420-434`) therefore still compares two independent PhotoKit reads, which protects ML retention from a truncated fetch.
  - Retain the video fetch result: `prepareScanFetch` and `refresh` set `retainedVideoFetchResult` from `source.videoFetch()` whenever it is nil. That is a fetch without enumeration, and it never runs while `.notDetermined`. They set `videoCount` to its `count`. WS-27 uses `videoCount` and `onVideosInserted` (WS-18.2), and needs no inventory patch.

**WS-18.5 — Engine: soft-fail on missing required IDs**
- **Change** in `PhotoScanEngine.performScan` (`:438-451`):
  ```swift
  if let requested = requiredAssetIDs {
      let fetchedIDs = Set(allAssets.lazy.map(\.localIdentifier))
      if allAssets.isEmpty && !requested.isEmpty { throw ScanError.photoLibraryTemporarilyUnavailable(...) }
      if let expected = expectedLibraryPhotoCount, expected > 0,
         Double(allAssets.count) < 0.9 * Double(expected) { throw ScanError.photoLibraryTemporarilyUnavailable(...) }
      requiredAssetIDs = requested.intersection(fetchedIDs)
      droppedRequiredCount = requested.count - requiredAssetIDs!.count
  }
  ```
  - Make `requiredAssetIDs` a `var`.
  - Add `var droppedRequiredAssetCount = 0` to `PhotoScanUpdate`, set on the first yielded update.
  - `HomeViewModel.apply` records the new diagnostic `photoScanRequiredDropped(count:)` once, when the count is non-zero.
- **Edge cases:**
  - When the intersection is empty but the fetch is not, the run completes with no targets through the existing `guard !targetAssets.isEmpty` path, so ML retention runs against the real, non-empty `allAssets`.
  - Never let retention run against an empty active set (invariant 14; `performRetention`'s own guard already enforces this).

**WS-18.6 — Persistent change tokens (may be a follow-up PR in the same slot if the diff exceeds about 1,500 lines)**
- **Change:**
  - `CachedPhotoAnalysisSnapshot` gets `let libraryChangeTokenData: Data?`: add it to `CodingKeys`, decode with `decodeIfPresent`, default `nil` in `init`, and copy it in `withPersistenceGeneration` and `repairingPrematureCompletion`. `schemaVersion` stays 7.
  - `AnalysisSnapshotInputs` gets `libraryChangeTokenData` (the inventory's current `changeTokenData`, captured together with `metadataByID`). The builder writes it.
    - **Rule:** the token stored in a snapshot must describe exactly that snapshot's `libraryAssets`.
    - Before WS-19, the builder records the live inventory, so this holds.
    - WS-19 adds the "drop the token when the recorded inventory differs from the live one" rule.
    - Update the WS-16 golden literals (the new key appears only when non-nil; keep the goldens' token nil so they stay byte-identical).
  - `performRefresh`:
    - If the status is `.authorized`, a base exists (from `seed` or an earlier full enumeration) and `changeTokenData != nil`: `changes(since:)`. Fetch metadata for `inserted ∪ updated` through `metadata(forImageIdentifiers:)`, which uses `PhotoLibraryFetch.imageOptions()` plus a `mediaType == .image` predicate. Upsert what comes back, remove `updated` IDs that came back empty (now hidden or not an image), and remove `deleted`. Store the new token.
    - On **any** error (`PHPhotosError.persistentChangeTokenExpired`, `.persistentChangeDetailsUnavailable`, an archive or unarchive failure): full enumeration.
    - Under `.limited`: always full enumeration, and never store a token for persistence.
  - `SystemPhotoLibrarySource.changes(since:)`:
    - unarchive with `NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self, from:)`
    - call `PHPhotoLibrary.shared().fetchPersistentChanges(since:)`
    - iterate the changes, union `try change.changeDetails(for: .asset)`'s `insertedLocalIdentifiers`, `updatedLocalIdentifiers` and `deletedLocalIdentifiers`, and keep the last change's `changeToken`
    - archive with `NSKeyedArchiver.archivedData(withRootObject:requiringSecureCoding: true)`
    - Confirm the exact SDK spellings when implementing.
  - **Token bootstrap:** the first launch after this ships has no token, so a snapshot write would be needed to persist one. Add `PhotoAnalysisCache.persistChangeToken(_ tokenData: Data, ifGeneration: UInt64)`. It builds `memoizedSnapshot` with the token set and `persistenceGeneration = 0`, keeps `savedAt`, and enqueues. Call it after a full-enumeration refresh when the snapshot on disk has no token, `metadataByID == analyzedInventory` exactly, and WS-20's gate allows writes (before WS-20: status `.authorized`). This writes the snapshot once, and the completion date does not move.
- **Edge cases:**
  - Capture the token **before** reading. Changes that race the read are re-applied next time, which is idempotent.
  - An authorization change drops the token (WS-18.2).
  - The analyzed inventory is never modified by deltas. Only snapshots set it.

**WS-18.7 — Diagnostics**
- In SharedHelpers, add the factories `libraryInventoryRefreshed(reason:path:assetCount:elapsedMilliseconds:)` and `photoScanRequiredDropped(count:)`.
  - Allowlist `reason` (`launch`, `activation`, `scan_start`, `library_change`, `authorization_change`, `manual`) and `path` (`full`, `delta`, `skipped`).
  - Only counts and elapsed time are recorded (invariant 26).

### Tests
- `iOSCleanupTests/PhotoLibraryInventoryTests.swift` uses a `FakePhotoLibrarySource` with scripted results, per-method call counters and an optional suspension point (a continuation the test resumes; no sleeps). All run in the simulator.
  - `testConcurrentRefreshesEnumerateOnce`: 3 concurrent `refresh` calls give 1 `enumerateImages`.
  - `testChangeDuringFlightRunsExactlyOneFollowUp`
  - `testOlderGenerationCannotOverwriteNewer`: `prepareScanFetch` starts, a refresh completes, and the older result is ignored. Drive this through the fake's suspension.
  - `testActivationPolicyTable`: inactive→active never; background→active dirty yes; not dirty within 30 s no; after 30 s yes.
  - `testNotDeterminedNeverTouchesSource`: every counter except `authorizationStatus` is 0.
  - `testValidTokenAppliesDeltasWithoutFullEnumeration`: insert, update, hidden-update removal and delete, with 0 full enumerations.
  - `testExpiredTokenFallsBackToOneFullEnumeration`
  - `testLimitedNeverUsesTokenPath`
  - `testPendingAnalysisIDsComparesLiveWithAnalyzed`
  - `testTokenRoundTripsThroughSnapshotAndLegacyDecodesNil`
  - Video signals (lead L3), driven through `applyVideoChange(_:)` with `resultAfterChanges: nil`:
    - `testVideoInsertDetailsFireOnVideosInsertedWithInsertedCount`: from `videoCount` 10, `insertedCount: 2, countAfter: 12` calls the hook once with 2, and `videoCount == 12`.
    - `testVideoRemovalNeverFiresOnVideosInserted`: `insertedCount: 0, countAfter: 9` makes no call, and `videoCount == 9`.
    - `testVideoCountIncreaseWithoutDetailsFiresDifference`: from 10, `insertedCount: nil, countAfter: 13` calls the hook with 3.
    - `testVideoCountIsNilWhileNotDetermined`: `videoCount == nil`, and the fake's `videoFetch` counter is 0.
- `iOSCleanupTests/PhotoScanEngineTests.swift` (existing `StubPhotoScanAssetProvider` and `PhotoScanTestAsset`):
  - `testSortedInputIsReturnedUnchanged`: `sortedByCreationDateIfNeeded` on sorted input returns an identical array (equal dates included); unsorted input is sorted.
  - `testMissingRequiredIDIsDroppedAndReported`: `requiredAssetIDs = {a, b, missing}`; the scan completes and the first update has `droppedRequiredAssetCount == 1`.
  - `testEmptyFetchWithRequiredIDsThrows`
  - `testFetchBelowNinetyPercentOfExpectedThrows`
  - `testPrefetchedProviderRefetchesOnSecondCall`
  - `testPrefetchedProviderRejectsDeniedAuthorization`

### Acceptance criteria
- [ ] Verify-first observations (WS-18.0) are recorded in `docs/DEVICE_QA.md`.
- [ ] A DEBUG cold launch with an unchanged library, after one launch that persisted a token, shows `debugFullEnumerationCount == 0`. Pulling Control Center or the notification shade 5 times adds 0 enumerations of either kind.
- [ ] A scan start performs exactly one full enumeration in total (inventory, engine and repair combined), against the WS-09 baseline of 3–5.
- [ ] A required photo deleted between planning and fetch no longer fails the scan (unit test, plus device QA).
- [ ] No PhotoKit call happens while `.notDetermined` (unit test).
- [ ] `PhotoLibraryChangeObserverProxy` no longer lives in `HomeViewModel.swift`, and `systemLibraryPhotoMetadata()` no longer lives in `HomeViewModelDependencies.swift`. `HomeViewModelDependencies` has `librarySource` and no longer has `authorizationStatus` or `fetchLibraryPhotoMetadata`.
- [ ] `ios-cleanup/CLAUDE.md` gets a `PhotoLibraryInventory` row: single-flight, token deltas, activation rule, and the shared scan fetch.

### Device QA
- **Enumeration counts.** Using the WS-09 baseline library, with DEBUG counters logged:
  - Cold launch twice with no library change; the second launch shows 0 full enumerations.
  - Pull Control Center 5 times: 0.
  - Switch to Camera, take a photo and return: 1 delta refresh, and the new photo is scanned.
- **Mid-plan deletion.** Start a Deep Clean. While "Preparing the first photo batch…" shows, delete a photo from the Photos app. The scan completes, and the diagnostics include `required_dropped`.

### Pitfalls and out of scope
- **Invariant 20:** no PhotoKit while `.notDetermined`. The scan-start prompt is user-initiated only. Onboarding auto-start is WS-26.
- **Invariant 14:** the stored token must describe exactly the stored `libraryAssets`. WS-19 finishes this rule. Getting it wrong silently hides photos from analysis forever.
- Keep the fetch semantics: hidden assets and non-representative burst frames are excluded. Changing `includeAllBurstAssets` is WS-40 (chapter 08), and it must reset tokens, since the inventory definition changes.
- The inventory updates its live metadata mid-scan. WS-19's recorded inventory makes that harmless; until WS-19 lands, keep today's behavior (the `.active` refresh also updated mid-scan).
- Applying `PHChange.changeDetails` (FSA-04 item 3) and reconcile changes are WS-21. Consuming the video fetch result is WS-27 (chapter 06).
- **Reconciliation (lead L3):** WS-18 defines the video signals WS-27 (chapter 06) consumes, with exactly these names:
  - `videoCount` is the retained video fetch count.
  - `onVideosInserted: (@MainActor (Int) -> Void)?` fires from the video `changeDetails.insertedObjects`, or from a count increase when details are unavailable, through `applyVideoChange(_:)`.
  - Both are covered by unit tests. `retainedVideoFetchResult` is created lazily on refresh and scan start. WS-21.3 only moves the call into its serial change consumer, and WS-27 does not patch the inventory.
- **Reconciliation (lead L16):** `librarySource` is a new `HomeViewModelDependencies` field with a production default. It subsumes WS-07's `authorizationStatus` and `fetchLibraryPhotoMetadata` closures, which WS-07 marks as replaced by WS-18.
- **Reconciliation:** WS-40 (chapter 08) flips `includeAllBurstAssets` in `imageOptions()` and adds `PhotoLibraryFetch.identifierOptions()` for every `fetchAssets(withLocalIdentifiers:)`. That covers `metadata(forImageIdentifiers:)` here and WS-21's `existingIdentifiers(among:)`. Inventory counts (`imageCount()`, `independentCount`, `libraryTotalCount`) then include hidden burst frames and can exceed the Photos app's visible count; WS-31/WS-45 copy must allow for that. WS-40's `PhotoFetchLintTests` forbids `options: nil` on any `PHAsset.fetchAssets` call, so every fetch added here goes through `PhotoLibraryFetch`.
- **Reconciliation:** keep WS-09's `inventory.enumerate` signpost on the enumeration that moves into `SystemPhotoLibrarySource`. Signpost interval names are a contract.

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| PERF-05 | confirmed | Enumeration on every `.active`, at launch and at scan start, redundant sorts, repair re-enumeration and unused tokens are all confirmed. Sort cost is overstated: Swift's sort is near-linear on sorted input. Fix item 4 is already current behavior. The plan follows D-INVENTORY: a `@MainActor` inventory, not the proposed `actor`, with off-main PhotoKit reads. It adds an independent count so the shared fetch keeps today's truncation cross-check, and a one-time `persistChangeToken` write. Without that write, a user whose library never changes would never persist a token and would enumerate on every launch. |
| STATE-11 (merged) | confirmed | Out-of-order refresh application and the hard failure on missing required IDs (`PhotoScanEngine.swift:438-451`) are confirmed. The activation rule follows the dup note: refresh only when returning from background, and only when dirty or after 30 s. It is implemented with a `wasInBackground` flag because iOS returns via `.inactive`. |

---

## WS-19 — Scan snapshot integrity under library changes

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M1 | M | WS-18 | no | `ws/19-snapshot-integrity` |

**Primary files:** `iOSCleanup/Views/Home/AnalysisSnapshotBuilder.swift`, `iOSCleanup/Views/HomeViewModel.swift`, `iOSCleanup/Engines/PhotoAnalysisCache.swift`, `iOSCleanup/Views/Home/PostRunFollowUpPolicy.swift` (*new*), `iOSCleanupTests/AnalysisSnapshotBuilderTests.swift`, `iOSCleanupTests/PhotoScanEngineTests.swift`, `iOSCleanupTests/PostRunFollowUpPolicyTests.swift` (*new*), `iOSCleanup.xcodeproj/project.pbxproj`

**Findings covered:** STATE-01 (P1, confirmed)

**Decisions applied:**
- D-INVENTORY: the plan-time inventory comes from WS-18's shared scan fetch, so plan and engine sets are identical. That is the basis of the recorded inventory.
- D-HVM-DECOMP: the new logic lives in `AnalysisSnapshotBuilder` and a new pure policy file.

### Goal
A snapshot records only what its run covered:
- A photo added or edited while a scan runs never makes the completed snapshot inconsistent, never produces a false "Deep Clean paused" or storage warning, and never causes a discarded cache.
- The next launch analyzes exactly the added or edited photo.
- Snapshots already poisoned on users' devices are repaired without a full rescan.
- `persistenceHealthy` means "writes are failing" and nothing else.

### Current behavior (verified)
- `iOSCleanup/Views/HomeViewModel.swift:1575-1577`: every `.active` refreshes the inventory with no scan-state guard. After WS-18 this is "returning from background, when dirty or after 30 s", still mid-scan. Refresh overwrites the live inventory (`:1592-1594`, now the inventory's `metadataByID`).
- `:2107-2110` (now `AnalysisSnapshotBuilder.build`): the snapshot records the **live** inventory as `libraryAssetIdentifiers` and `libraryAssets`.
- `iOSCleanup/Engines/PhotoAnalysisCache.swift:81-92`: a complete Deep Clean is consistent only if `scanTargetCount >= knownLibraryCount && knownLibraryIDs.isSubset(of: evaluatedIDs)`. One extra live ID makes it inconsistent.
- `:589-594`: an inconsistent load sets `persistenceHealthy = false`. `HomeViewModel.refreshPersistenceHealth` (`:2299-2313`) then shows "PhotoDuck could not save scan progress. Free a little storage…".
- Restore (`:2197-2199`) chooses `.paused` for inconsistent snapshots, and `scanNewPhotosIfNeeded` requires `.completed`/`.idle` (`:1926`).
- On Continue, `scanPhotos` (`:973-982`) calls `repairPrematureCompletion`:
  - Its guard (`:2281-2285`) needs an unchanged inventory, otherwise the result is `.discarded` and a full rescan follows.
  - The chronological-prefix assumption (`:2288-2292`) marks an older-dated addition as evaluated and a real photo as unevaluated.
- For comparison, `testAnalysisCacheSurfacesPrematureCompleteSnapshotForRepair` (`iOSCleanupTests/PhotoScanEngineTests.swift:1073-1098`) currently asserts `persistenceHealthy == false` after loading an inconsistent snapshot.
- Speed Clean (`PhotoScanResumePlanner`, `PhotoAnalysisCache.swift:315-328`) relies on the snapshot recording the whole plan-time library, even though it evaluates only about 500 photos. A naive "record only evaluated IDs" rule would turn the next Speed Clean launch into a scan of about 59,500 "new" photos. Speed Clean is not reachable from current UI (no `startSpeedClean` callers), but legacy snapshots and `lastCompletedMode` can still be `.speedClean`.

### Implementation plan

**WS-19.1 — Recorded inventory in the builder**
- **Why:** The snapshot must describe the run's coverage, not the live library.
- **Change:**
  - In `AnalysisSnapshotBuilder`:
    ```swift
    static func recordedInventory(liveMetadata: [String: CachedPhotoAssetMetadata],
                                  planMetadata: [String: CachedPhotoAssetMetadata],
                                  evaluatedIDs: Set<String>, pendingTargetIDs: Set<String>,
                                  isComplete: Bool, mode: CleanupMode) -> [CachedPhotoAssetMetadata] {
        let covered: Set<String>
        switch mode {
        case .deepClean:  covered = isComplete ? evaluatedIDs : evaluatedIDs.union(pendingTargetIDs)
        case .speedClean: covered = planMetadata.isEmpty ? Set(liveMetadata.keys) : Set(planMetadata.keys)
        }
        return Set(liveMetadata.keys).intersection(covered)
            .map { planMetadata[$0] ?? liveMetadata[$0]! }
            .sorted { $0.localIdentifier < $1.localIdentifier }
    }
    ```
  - `AnalysisSnapshotInputs` gets `runPlanMetadata: [String: CachedPhotoAssetMetadata]` (empty when no run is active). `build` derives `libraryAssets` from `recordedInventory(... mode: inputs.cleanupMode)` and sets `libraryAssetIdentifiers = libraryAssets.map(\.localIdentifier)`. `pendingTargetIDs` is `checkpoint.targetAssetIDs`.
  - **Token exactness rule (finishes WS-18.6):** `libraryChangeTokenData = (recorded == live metadata, IDs and values) ? inputs.libraryChangeTokenData : nil`. A nil token makes the next launch do one full enumeration, which re-surfaces every uncovered or edited photo.
  - In `HomeViewModel`, add `private var runPlanMetadata: [String: CachedPhotoAssetMetadata] = [:]`:
    - Set it to `inventory.metadataByID` in `scanPhotos` right after the planner call.
    - Clear it in **every** terminal branch, always *after* that branch's final inputs capture:
      - the no-work return (`:1030-1059`)
      - both `guard activeScanID == scanID else { return }` exits
      - the completion block
      - the cancel path
      - both error paths
    - Pause keeps it.
- **Edge cases:**
  - With no run (reconcile or restore-time writes), `planMetadata` is empty and a Deep Clean records `live ∩ evaluated`.
  - First Deep Clean checkpoint: pending targets are the whole plan, so everything is recorded.
  - Incremental resume: evaluated (carried) plus targets covers the library.
  - A mid-run addition X is excluded, so the planner's `currentAssetIDs.subtracting(snapshot.libraryAssetIdentifiers)` picks it up.
  - A mid-run edit after analysis is recorded with plan metadata, so it shows up as modified.
  - The goldens change (the recorded inventory now depends on the checkpoint sets and mode). Update the literals **in this PR** and explain every changed key in the PR summary.

**WS-19.2 — Repair poisoned snapshots without a full rescan**
- **Change:**
  - `CachedPhotoAnalysisSnapshot.droppingUncoveredInventory() -> CachedPhotoAnalysisSnapshot` (in `PhotoAnalysisCache.swift`, next to `repairingPrematureCompletion`):
    - Keep only the `libraryAssets` and `libraryAssetIdentifiers` that are in `evaluatedAssetIdentifiers`.
    - Set `libraryTotalCount = min(libraryTotalCount, keptCount)`.
    - Set `libraryChangeTokenData = nil`.
    - Keep `savedAt`, so the completion date doesn't move.
    - Set **`persistenceGeneration = 0`**, so `enqueue` assigns the next generation. Keeping the old generation would make `enqueue` reject the write as stale.
  - In `PhotoAnalysisCache.restoreState()` (WS-17): if `snapshot.isComplete && !snapshot.hasConsistentCompletionState`, try `droppingUncoveredInventory()`. If the result is consistent, use it and return it as `RestoredAnalysisState.repairedSnapshot`. The facade then calls `analysisCache.scheduleSnapshot(repaired)` when the write gate allows it (WS-20; before WS-20, status `.authorized`).
  - In `scanPhotos`, before the `repairPrematureCompletion` branch (`:973`): apply the same repair and `saveSnapshot` the result. Fall back to `repairPrematureCompletion` only if the repair is still inconsistent.
- **Edge cases:** This only ever removes inventory entries that were never evaluated. Evaluated, target and unanalyzed sets are untouched, and so is `hasConsistentCompletionState`'s definition.

**WS-19.3 — `persistenceHealthy` means "writes failing"**
- **Change:**
  - In `PhotoAnalysisCache.loadSnapshot(from:)` (`:589-594`), stop setting `persistenceHealthy = false` for inconsistency. Instead set `private(set) var lastLoadWasInconsistent = true` (false on a consistent load) and keep the log line. Oversize and decode errors keep their current behavior; WS-47 reworks them.
  - `makeDiagnosticReport` can report `lastLoadWasInconsistent`. If a `checkpoint.isConsistent` field already exists, it covers this, and nothing is added.
  - Update `testAnalysisCacheSurfacesPrematureCompleteSnapshotForRepair` to assert `persistenceHealthy == true` and `lastLoadWasInconsistent == true`, with a comment explaining the semantic change.

**WS-19.4 — One post-run follow-up**
- **Why:** The uncovered addition must be analyzed without waiting for the next launch.
- **Change:** New `iOSCleanup/Views/Home/PostRunFollowUpPolicy.swift`:
  ```swift
  enum PostRunFollowUp: Equatable { case none, incrementalScan, reconcile }
  enum PostRunFollowUpPolicy {
      /// WS-21 adds `libraryChangedDuringRun` → .reconcile (which itself scans when analysis is pending).
      static func action(runSucceeded: Bool, pendingAnalysisCount: Int) -> PostRunFollowUp
  }
  ```
  - `HomeViewModel.runPostRunFollowUpIfNeeded(runSucceeded: Bool)` runs exactly once per run, at the moment the whole run is over:
    - at the end of the supporting-scan task (after `isFinishingSupportingScans = false`, `:1807`), or
    - right after the worker ends when supporting scans did not start (`:1331-1345`).
  - WS-21.5 also calls it at the end of every video pass, with `runSucceeded: false` (lead L4). WS-27 (chapter 06, rule R4) keeps that call for the videos-first pre-pass, explicit refreshes and insertion rescans.
  - It computes `pending = await inventory.pendingAnalysisIDs().count` and, for `.incrementalScan`, calls `await scanNewPhotosIfNeeded()`.
- **Edge cases:**
  - Never call it while the supporting video pass runs: `scanPhotos` cancels `supportingScansTask` (`:949`).
  - A run that was fenced off (activeScanID changed) does not trigger it.
  - The follow-up is an automatic scan. WS-26 classifies it (no completion sheet).

### Tests
All tests run in the simulator.
- `iOSCleanupTests/AnalysisSnapshotBuilderTests.swift`, finding cases (a)–(e):
  - `testCompleteDeepCleanExcludesMidRunAdditionAndStaysConsistent` (a): live N+1, evaluated N, complete. The built snapshot has `hasConsistentCompletionState == true`, and `PhotoScanResumePlanner.requiredAssetIDs(snapshot:currentAssetIDs: N+1…) == [X]`.
  - `testMidRunEditIsRecordedWithPlanMetadataAndPlannedAsModified` (b)
  - `testCheckpointRetainsPendingTargets` (e)
  - `testSpeedCleanRecordsPlanInventory`
  - `testTokenDroppedWhenRecordedDiffersFromLive`
  - `testTokenKeptWhenRecordedEqualsLive`
- `iOSCleanupTests/PhotoScanEngineTests.swift`:
  - `testDroppingUncoveredInventoryRepairsPoisonedSnapshot` (c): complete, inventory N+1, evaluated N. The result is consistent, with generation 0, the same `savedAt` and a nil token.
  - `testInconsistentLoadLeavesPersistenceHealthy` (d): the updated existing test.
  - `testRepairedSnapshotIsWrittenWithNewGeneration`: save through the cache, and the loaded generation is greater than the original.
- `iOSCleanupTests/PostRunFollowUpPolicyTests.swift`:
  - `testSucceededRunWithPendingSchedulesIncrementalScan`
  - `testNoPendingDoesNothing`
  - `testFailedRunNeverScans`
- `iOSCleanupTests/HomeViewModelTests.swift` (if WS-07's seam can inject an engine factory and `FakePhotoLibrarySource`): `testRunPlanMetadataClearedOnEveryTerminalBranch` covers completion, cancel and error via stub engines.

### Acceptance criteria
- [ ] Unit tests (a)–(e) pass, and the golden literal updates are explained in the PR.
- [ ] Adding a photo during a Deep Clean leaves a consistent completed snapshot. The relaunch shows the completed state with no storage warning, and the follow-up (or next launch) analyzes exactly that photo (device QA).
- [ ] Existing poisoned snapshots are repaired at restore, with no full rescan and no "paused" state.
- [ ] `persistenceHealthy` is false only for write failures, oversize or decode errors. Inconsistency never shows the storage warning.
- [ ] `hasConsistentCompletionState` is unchanged (diff shows no edit to `computeConsistentCompletionState`).
- [ ] `ios-cleanup/CLAUDE.md` `PhotoAnalysisCache` row states that a snapshot records only the inventory its run covered.

### Device QA
- **Mid-scan addition.** On a 5k+ library, start a Deep Clean. Switch to Camera, take a photo, return, and let the scan complete.
  - The relaunch shows "Cleanup complete" with no storage banner.
  - The follow-up scan processes exactly 1 photo (the diagnostics `photo_scan.planned` shows `required=1`).
- **Mid-scan edit.** As above, but crop a photo that was already scanned. The next run re-analyzes it.
- **Poisoned repair.** Install the WS-09 baseline build, reproduce the poisoned snapshot (mid-scan add), then install this build and launch. Home shows completed results with no paused state and no warning.

### Pitfalls and out of scope
- **Invariant 14:** never loosen `hasConsistentCompletionState`. The planner must still return nil on inconsistency. The recorded inventory must never include an ID the run did not cover (Deep Clean), and a token must never outlive an inexact inventory.
- Do not tombstone or prune results here. That is WS-21.
- `persistenceHealthy`'s copy and actionability are WS-47 (chapter 10), which relies on this semantic.
- Coordinating the post-run follow-up with `libraryChangedDuringRun` is WS-21. Do not add a second follow-up there.
- **Reconciliation (lead L14):** WS-37 (chapter 08) later adds `CachedPhotoAnalysisSnapshot.analyzerVersion`. `droppingUncoveredInventory()` must carry it unchanged (carried, never defaulted), and WS-37 extends this helper. The golden and repair tests here follow WS-16.1's additive-field rule: new optional fields stay nil in fixtures, so they do not change the literals.
- **Reconciliation (lead L4):** the single follow-up also runs at the end of every video pass (WS-21.5, then WS-27's R4), because WS-27 defers automatic photo scans during any video pass.

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| STATE-01 | confirmed | Every step in the chain was traced: `.active` refresh → live inventory recorded → subset check fails → `persistenceHealthy=false` → `.paused` → prefix repair or discard. The plan implements fix items 1–6 with four changes. (1) `recordedInventory` takes `mode`: Speed Clean keeps recording the plan-time inventory, because the literal formula would turn the next Speed Clean into a ~59,500-photo "incremental" scan. (2) The repaired snapshot is re-generated (`persistenceGeneration = 0`), otherwise `enqueue` rejects it as stale. (3) A token-exactness rule ties WS-18's change token to the recorded inventory, so an excluded or plan-dated entry is never hidden from future deltas. (4) The follow-up runs after the supporting video pass, because `scanPhotos` cancels it. |

---

## WS-20 — Permission states and Limited access

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M1 | M | WS-19 | no | `ws/20-permissions-limited-access` |

**Primary files:** `iOSCleanup/Views/HomeViewModel.swift`, `iOSCleanup/Views/Home/LibraryPersistenceGate.swift` (*new*), `iOSCleanup/Views/Home/PermissionStateReconciler.swift` (*new*), `iOSCleanup/Views/Home/HeroStateResolver.swift`, `iOSCleanup/Engines/PhotoLibraryInventory.swift`, `iOSCleanup/Engines/PhotoScanEngine.swift`, `iOSCleanup/Engines/PhotoMLStore.swift` (read-only check; no change expected), `iOSCleanup/Views/Home/LargeVideoScanController.swift`, `iOSCleanup/Views/HomeView.swift` (CTA fallback and limited banner copy), `iOSCleanupTests/PhotoScanEngineTests.swift`, `iOSCleanupTests/LibraryPersistenceGateTests.swift` (*new*), `iOSCleanupTests/PermissionStateReconcilerTests.swift` (*new*), `iOSCleanupTests/HeroStateResolverTests.swift`, `iOSCleanupTests/HomeViewModelTests.swift`, `iOSCleanup.xcodeproj/project.pbxproj`

**Findings covered:** STATE-02 (P1, confirmed), FSA-06 (P1, confirmed; merged: UI-17 — partially)

**Decisions applied:**
- D-LIMITED-ACCESS: under `.limited`:
  - nothing library-derived is persisted: no analysis snapshot, no large-video cache, and no inactive-asset ML pruning
  - the full-access snapshot is restored read-only
  - Limited → Full rehydrates, then runs an incremental pass
  - Home says "Results cover the N photos you shared with PhotoDuck."
- D-INVENTORY: authorization is read through the inventory's source, which makes it injectable.

### Goal
Trying Limited access never costs the user their full-library analysis, previous findings, large-video results or ML cache. A Full → Limited → Full round trip leaves `photo-analysis-cache.json`, `large-video-results.json` and the `photo_features` row count unchanged, and the next Full launch is incremental. Granting access after a denial un-sticks Home and goes straight to a scan. Revoking access shows "Photo access required", never "Cleanup complete".

### Current behavior (verified)
- `iOSCleanup/Engines/PhotoScanEngine.swift:61-66`: the provider accepts `.limited`. `:534-536` and `:970-973` call `performMLRetentionAfterSuccessfulScan(activeAssetIDs: Set(allAssets…))`.
- `iOSCleanup/Engines/PhotoMLStore.swift:1259-1263`: a non-nil, non-empty active set runs `deleteRecordsForInactiveAssets` (`:1541-1586`), which deletes `pairwise_similarity`, `photo_asset_analysis` and `photo_features` rows `NOT IN` the active set. A nil set applies only the row caps (`:1245-1255`).
- `iOSCleanup/Views/HomeViewModel.swift` treats Limited like Full:
  - `scanNewPhotosIfNeeded` allows `.limited` (`:1927-1928`).
  - Refresh replaces the inventory with the visible subset (now the inventory).
  - Reconcile prunes to the visible IDs and saves `isComplete: true` (`:1853-1917`).
  - `scanFiles` saves the limited video list (`:1410-1415`).
  - `performCachedLargeVideoRestore` **re-saves** when `missingResultCount > 0` (`:2173-2178`). Under Limited every unselected video counts as "missing", so a restore alone truncates `large-video-results.json`. The finding did not list this.
- `:1274-1279` and `:1416-1427`: permission failures set `.permissionRequired`, and nothing resets them. `heroState` derives `.permissionRequired` only from `scanState` (`:585-587`). The `scanFiles` guard (`:1383-1388`) excludes `.permissionRequired`.
- The scalars are persisted and restored (`:2494`).
- `HomeView.swift:426-429` opens Settings for `.permissionRequired` unconditionally.
- Restore under `.denied` rehydrates zero groups and still marks hydration done (`:2126`), so re-granting access never rehydrates.
- UI-17's plist key (`PHPhotoLibraryPreventAutomaticLimitedAccessAlert`) ships in WS-48. The "alert on every launch" claim is iOS behavior and was not verified statically.

### Implementation plan

**WS-20.1 — Engine: `allowsInactiveAssetPruning`**
- **Change:**
  - `PhotoScanEngine.scan(mode:allowNetworkAccess:requiredAssetIDs:expectedLibraryPhotoCount:allowsInactiveAssetPruning: Bool = true)`, threaded into `performScan`.
  - Both retention call sites pass `activeAssetIDs: allowsInactiveAssetPruning ? Set(allAssets.map(\.localIdentifier)) : nil`. `PhotoMLBridge.performRetention(activeAssetIDs: nil)` keeps applying the caps (no change needed).
- **Edge cases:** The default stays `true` so other callers are unchanged. WS-46 must keep this flag when it moves retention (chapter 10 already says so).

**WS-20.2 — One persistence gate for every library-derived write**
- **Change:** New `iOSCleanup/Views/Home/LibraryPersistenceGate.swift`:
  ```swift
  struct LibraryPersistenceGate: Equatable, Sendable {
      /// D-LIMITED-ACCESS: only full access may write library-derived state.
      static func persistsLibraryDerivedState(_ status: PHAuthorizationStatus) -> Bool { status == .authorized }

      var authorization: PHAuthorizationStatus
      var collectionsFromLimitedSession: Bool       // in-memory results were produced or restored under .limited
      var writesSuspendedForTransition: Bool        // between an authorization change and its completed re-restore

      /// Analysis snapshot, large-video cache, change token, repairs.
      var allowsLibraryWrites: Bool {
          Self.persistsLibraryDerivedState(authorization) && !collectionsFromLimitedSession && !writesSuspendedForTransition
      }
      /// Writes owned by a run also require that the run itself started under full access.
      func allowsRunWrite(runStartedUnder status: PHAuthorizationStatus) -> Bool {
          allowsLibraryWrites && Self.persistsLibraryDerivedState(status)
      }
      /// UserDefaults scalars: blocked only for limited-session results and during a transition
      /// (a .permissionRequired intent under .denied must still persist).
      var allowsScalarWrites: Bool { !collectionsFromLimitedSession && !writesSuspendedForTransition }
  }
  ```
  - `HomeViewModel` gets `private var persistenceGate` and a `nonisolated static func persistsLibraryDerivedState(_:)` that forwards to the gate (the name used in tests and the finding). It also gets `private var activeRunAuthorization: PHAuthorizationStatus?`, set at the start of `scanPhotos` and cleared with `runPlanMetadata`.
  - Gate every write site:
    - worker periodic and completion writes, and the cancel checkpoint: `allowsRunWrite`
    - pause (both branches) and the background checkpoint: `allowsRunWrite` if a run is active, otherwise `allowsLibraryWrites`
    - reconcile writes and `saveAnalysisSnapshot` (including its ML `persistFeatureRecords`): `allowsLibraryWrites`
    - the `scanPhotos` repairs (`repairPrematureCompletion`, WS-19's repair) and the restore-time repair: `allowsLibraryWrites`
    - WS-18's `persistChangeToken`: `allowsLibraryWrites`
    - `LargeVideoScanController`: inject `canPersist: @MainActor () -> Bool`, checked before `resultCache.save` in `runScan`, before `remove` in `removeFile`, and before the **restore re-save** on missing results
    - `persistCleanupState()`: `allowsScalarWrites`
  - Engine: `allowsInactiveAssetPruning: LibraryPersistenceGate.persistsLibraryDerivedState(runStatus)`.
  - At `init`, set `collectionsFromLimitedSession = (status == .limited)`.
- **Edge cases:**
  - A user who has only ever used Limited has no full snapshot. Everything stays in memory, and each launch starts idle (selections are small).
  - Under `.denied` the engine throws `permissionDenied` before retention.
  - Under Limited, `large-video-results.json` is never written. After WS-27 (chapter 06), `LargeVideoFreshnessPolicy` therefore finds no restored results and reports `.neverScanned` at every launch, which runs one cheap in-memory video pass per launch. That is intended under D-LIMITED-ACCESS: nothing is persisted, and the selection is small. Do not add a limited-only video cache to avoid it.

**WS-20.3 — Authorization transitions**
- **Change:** `HomeViewModel.handleAuthorizationChange(from old: PHAuthorizationStatus, to new: PHAuthorizationStatus) async`.
  - It is called when `inventory.authorizationStatus()` differs from `photoAuthorizationStatus`, checked in:
    - `updateScenePhase(.active)`, on every `.active`: a cheap status read, independent of WS-18's refresh throttle
    - `requestPhotoAccess()`
    - bootstrap
  - **`old == .notDetermined`:** this is the first answer, not a scope change. Only `bootstrapLibraryStateIfNeeded()` runs (WS-26 owns onboarding auto-start).
  - **Otherwise:**
    1. `photoAuthorizationStatus = new; persistenceGate.authorization = new; persistenceGate.writesSuspendedForTransition = true`
    2. `let hadBlockedIntent = (scanState == .permissionRequired)`
    3. `await stopActiveRunsWithoutCheckpoint()`:
       ```swift
       private func stopActiveRunsWithoutCheckpoint() async {
           let engine = activePhotoScanEngine
           activeScanID = nil                       // fences every worker hop and the cancel-path checkpoint (invariant 13)
           await engine?.pause()
           let tasks = [scanTask, supportingScansTask].compactMap { $0 }
           tasks.forEach { $0.cancel() }
           for task in tasks { await task.value }
           scanTask = nil; supportingScansTask = nil; activePhotoScanEngine = nil
           isFinalizingPhotoScan = false; isFinishingSupportingScans = false    // the abandoned run never finishes
           if scanState == .scanning || scanState == .paused { scanState = .idle; isPaused = false }
       }
       ```
       WS-48 needs the same shape (`stopAllRunsForLocalDataClear`). Name it once here and let WS-48 reuse it.
    4. Clear in-memory derived state:
       - `resultsStore.removeAll()`
       - `largeVideoController.resetForAuthorizationChange()` (clears files and hydration)
       - `checkpoint = AnalysisCheckpointState()`
       - `hasHydratedAnalysisCache = false`, `analysisCacheHydrationTask = nil`, `hasBootstrappedLibraryState = false`
       - `inventory.resetForAuthorizationChange()`
    5. If `new ∈ {.authorized, .limited}`:
       - `persistenceGate.collectionsFromLimitedSession = (new == .limited)`
       - `await runBootstrapSequence()` (the bootstrap Task body, extracted so it can be awaited): large-video restore, analysis restore (read-only under Limited), then the inventory refresh
       - `persistenceGate.writesSuspendedForTransition = false`
       - if `hadBlockedIntent && resultsStore.photoGroups.isEmpty && lastCompletedAt == nil`, call `startDeepClean()`; otherwise `await scanNewPhotosIfNeeded()` (incremental; under Limited it stays in memory)
    6. If `new ∈ {.denied, .restricted}`: `writesSuspendedForTransition = false`. The results stay cleared, and the hero is permission-first (WS-20.4).
- **Edge cases:**
  - iOS may terminate the app when the permission changes in Settings (unverified; see Device QA). In that case the relaunch path covers everything: the gate is computed at `init`, bootstrap restores, and the permission reconciler runs.
  - The cancelled run's checkpoint is intentionally dropped. Losing up to 20 s of progress is acceptable; writing half-cleared state is not.

**WS-20.4 — FSA-06 and UI-17: unstick permission states**
- **Change:** New `iOSCleanup/Views/Home/PermissionStateReconciler.swift`:
  ```swift
  enum PermissionStateReconciler {
      struct Outcome: Equatable { let scanState: HomeViewModel.ScanState; let fileScanState: HomeViewModel.ScanState; let changed: Bool }
      static func reconcile(scanState: HomeViewModel.ScanState, fileScanState: HomeViewModel.ScanState,
                            authorization: PHAuthorizationStatus, hasCompletedScan: Bool) -> Outcome
  }
  ```
  The rules are:
  - For `.authorized` and `.limited`:
    - photo `.permissionRequired` → `hasCompletedScan ? .completed : .idle`
    - file `.permissionRequired` → `.idle`
  - For `.denied`, `.restricted` and `.notDetermined`: unchanged, and scanning or paused states are never touched.

  It is called:
  - in `handleAuthorizationChange` (before step 3, so `hadBlockedIntent` is read first)
  - in `runBootstrapSequence()`, for a stale persisted state: a relaunch after granting access in Settings, where `hadBlockedIntent` also drives the auto-start after restore
  - in `requestPhotoAccess()`

  When `changed`: `scanErrorMessage = nil`, `largeVideoController.resetProgress()` (`fileScanProgress = .idle`), and `persistCleanupState()`.
  - `scanFiles` guard (`:1383-1388`): also allow `fileScanState == .permissionRequired && !photoAccessNeedsSettings`.
  - `HeroStateResolver`: add `photoAccessNeedsSettings` to `HeroStateInputs`, and return `.permissionRequired` **first** when it is true.
  - HomeView `handleCTAAction` `.permissionRequired`:
    ```swift
    if viewModel.photoAccessNeedsSettings { viewModel.openPhotoAccessSettings() }
    else if viewModel.photoAccessNotYetRequested { viewModel.requestPhotoAccess() }
    else { viewModel.startDeepClean() }
    ```
- **Edge cases:**
  - After a denial the collections are empty. The hero's permission-first rule hides the stale "Cleanup complete".
  - The persisted `.permissionRequired` intent survives relaunch, because scalar writes are allowed under `.denied`. That is what lets "grant in Settings → relaunch" go straight to a scan.

**WS-20.5 — Limited-access copy**
- **Change:** `var limitedAccessSummary: String` on `HomeViewModel` returns "Results cover the \(n.formatted()) photos you shared with PhotoDuck." (singular: "…the 1 photo you shared…"), where `n = libraryTotalCount`. It replaces the limited body text in `photoAccessBanner` (`HomeView.swift:461-463`). The "Manage" button and layout are unchanged.

### Tests
All tests run in the simulator.
- `iOSCleanupTests/PhotoScanEngineTests.swift`, with `PhotoMLBridge(store: PhotoMLStore(directoryURL: temp))` seeded with 10 `photo_features` rows through `upsertFeatures`, `StubPhotoScanAssetProvider` returning 3 of the 10 assets, and an analyzer stub returning `.unavailable`:
  - `testLimitedScanDoesNotPruneInactiveMLRows`: pruning off leaves 10 rows (at least the 7 others remain).
  - `testFullScanPrunesInactiveMLRows`: pruning on removes the other 7.
- `iOSCleanupTests/LibraryPersistenceGateTests.swift`:
  - `testOnlyAuthorizedPersistsLibraryDerivedState`: all 5 statuses.
  - `testLimitedSessionBlocksWritesAfterUpgradeUntilRestore`
  - `testRunStartedUnderLimitedNeverWrites`
  - `testScalarWritesAllowedUnderDenied`
- `iOSCleanupTests/PermissionStateReconcilerTests.swift`: `testReconcileTable` iterates every `ScanState` × `ScanState` × 5 statuses × `hasCompletedScan`. Include `testScanningAndPausedAreNeverTouched`.
- `iOSCleanupTests/HeroStateResolverTests.swift`: `testDeniedWithCompletedResultsShowsPermissionRequired`.
- `iOSCleanupTests/HomeViewModelTests.swift` (WS-07 seam with `FakePhotoLibrarySource` from WS-18, temp `PhotoAnalysisCache` and `LargeVideoResultCache` directories, and a stub engine factory):
  - `testLimitedCompletedScanWritesNoSnapshotOrVideoCache`: the files are absent after the run, and the UserDefaults suite is unchanged.
  - `testLimitedRestoreDoesNotResaveLargeVideoCache`: seed a video cache with 5 entries, 2 resolvable; the file is unchanged.
  - `testLimitedToAuthorizedRehydratesAndReenablesWrites`
  - `testDeniedToAuthorizedWithBlockedIntentStartsScan`: the engine factory is invoked once.
  - `testStalePermissionRequiredIsReconciledAtBootstrap`

### Acceptance criteria
- [ ] Under `.limited`, no code path writes `photo-analysis-cache.json`, `large-video-results.json`, the change token or cleanup scalars, and ML retention runs with `activeAssetIDs == nil` (tests).
- [ ] A Full → Limited → Full round trip leaves `photo-analysis-cache.json` (generation, groups, inventory), `large-video-results.json` and the ML `photo_features` row count unchanged, and the next Full launch runs an incremental pass, not a full one (device QA).
- [ ] Deny → grant in Settings → return (or relaunch): Home shows "Start scan" or prior results, and a scan starts without another tap when the user had tried to scan. The Files tab rescans on its next activation.
- [ ] Revoking access shows "Photo access required", never "Cleanup complete". Re-granting restores cached results without a rescan.
- [ ] Under Limited, Home shows "Results cover the N photos you shared with PhotoDuck."
- [ ] `ios-cleanup/CLAUDE.md` gets a "Limited access" constraint line summarizing D-LIMITED-ACCESS.

### Device QA
- **Limited round trip.** Complete a Deep Clean with Full access. Download the container and record the snapshot generation, the group count and the `photo_features` count (`sqlite3 … "select count(*) from photo_features"`).
  - Switch to Limited with 30 photos, open PhotoDuck, scan and use Manage.
  - Switch back to Full and relaunch. The container values are unchanged, and the scan is incremental.
  - Note whether iOS terminated the app at each Settings change.
- **Deny, then grant.** Deny access at the first Start scan, grant it in Settings and return. The scan starts automatically.
- **Revoke.** With results, revoke access and relaunch. The hero reads "Photo access required".

### Pitfalls and out of scope
- **Invariant 15:** every write site must go through the gate. Grep for `saveSnapshot(`, `scheduleSnapshot(`, `largeVideoResultCache`/`resultCache.save`, `.remove(assetIdentifier` and `persistCleanupState(` after the change, and list them in the PR.
- **Invariant 13:** `stopActiveRunsWithoutCheckpoint` fences with `activeScanID = nil` *before* cancelling. Never reorder those steps.
- **Invariant 20:** `.notDetermined → X` is the onboarding path and must not run the transition sequence.
- Out of scope:
  - the plist key (WS-48, chapter 10)
  - onboarding auto-start (WS-26, chapter 06)
  - ML retention redesign (WS-46; keep the flag)
  - privacy-policy copy about Limited (WS-48)
- **Reconciliation:** the Limited-access video behavior after WS-27 (no cache write, so `.neverScanned` and one cheap pass per launch) is accepted as D-LIMITED-ACCESS intent, as chapter 06 proposed. See the edge case in WS-20.2.
- **Reconciliation:** the gate's API for later chapters:
  - Status-only decisions, such as engine or size-cache pruning (chapters 07 and 13), use the static `persistsLibraryDerivedState(_:)`.
  - Snapshot and cache writes from the facade, such as WS-28's background checkpoint, use `persistenceGate.allowsRunWrite(runStartedUnder:)` or `allowsLibraryWrites`, because those also honor the limited-session and transition flags.
  - There is no instance property named `persistsLibraryDerivedState`.

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| STATE-02 | confirmed | Every step is real: the engine accepts `.limited`, retention deletes rows `NOT IN` the selection, and reconcile and `scanFiles` persist limited results. The large-video restore re-save (`:2173-2178`), which truncates the cache on a mere restore, is an extra path not in the finding. The plan follows fix items 1–4. It adds a single `LibraryPersistenceGate` with a per-run authorization, a "limited session" flag and a transition suspension, because a status check at write time alone would let a limited run's cancel checkpoint, or its in-memory results, be written right after access is upgraded to Full. UserDefaults scalars are gated too: persisting limited-session counts would recreate STATE-09's phantom state after relaunch. |
| FSA-06 | confirmed | Nothing clears `.permissionRequired`, the hero derives purely from `scanState`, and the Files guard excludes the state. The plan follows items 1–5. On a transition after a blocked intent, the grant also auto-starts the scan (M1: "granting permission after denial goes straight to a scan"). |
| UI-17 (merged) | partially | The permission-first hero and rehydrate-on-transition parts are confirmed and implemented here. The plist key ships in WS-48. The "alert on every launch" claim depends on iOS behavior and was not verified statically. |

---

## WS-21 — Library change reconciliation

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M1 | L | WS-11, WS-18, WS-20 | no | `ws/21-library-reconciliation` |

**Primary files:** `iOSCleanup/Views/HomeViewModel.swift`, `iOSCleanup/Views/Home/PhotoResultPruner.swift` (*new*), `iOSCleanup/Views/Home/PhotoResultsStore.swift`, `iOSCleanup/Views/Home/ResultsFreshnessPolicy.swift` (*new*), `iOSCleanup/Views/Home/PostRunFollowUpPolicy.swift`, `iOSCleanup/Views/Home/LargeVideoScanController.swift`, `iOSCleanup/Engines/PhotoLibraryInventory.swift`, `iOSCleanup/Engines/PhotoAnalysisCache.swift` (`completedAt`), `iOSCleanup/Views/Home/AnalysisSnapshotBuilder.swift`, `iOSCleanup/Engines/DeletionManager.swift` (confirmed-deletion publisher, if WS-11 lacks one), `iOSCleanup/ContentView.swift`, `iOSCleanup/Views/Photos/SwipeModeViewModel.swift`, `iOSCleanup/Views/Photos/SwipeModeView.swift`, `iOSCleanup/Views/PhotoDuckShellView.swift` (one call site), `iOSCleanup/Views/HomeView.swift`, `iOSCleanupTests/PhotoResultPrunerTests.swift` (*new*), `iOSCleanupTests/ResultsFreshnessPolicyTests.swift` (*new*), `iOSCleanupTests/PhotoLibraryInventoryTests.swift`, `iOSCleanupTests/HomeViewModelTests.swift`, `iOSCleanup.xcodeproj/project.pbxproj`

**Findings covered:** FSA-04 (P1, confirmed; merged: UI-08), STATE-05 (P2, confirmed), STATE-06 (P2, partially)

**Decisions applied:**
- D-RESULTS-FRESHNESS: results are "stale" only when unanalyzed additions or modifications are pending. In-app deletions never make results stale.
- D-INVENTORY: incremental `PHChange` details are applied through WS-18's retained fetch results, with token deltas or a full enumeration only as fallback.
- D-LIMITED-ACCESS: the coalesced reconcile snapshot goes through WS-20's gate.

### Goal
A confirmed deletion (Keep Best, Duck Mode, a large video, Export & Delete, or a deletion in the Photos app) removes the asset from every surface at once, even during an active or paused scan, and scan updates never bring it back. Reconciliation removes only IDs that PhotoKit reported missing, never alters a run that started while it was waiting, and schedules exactly one reconcile when a run ends. Deletions alone never mark results stale. Reconcile writes are coalesced and keep the real completion date. The storage card refreshes on return to the app.

### Current behavior (verified)
- `iOSCleanup/Views/HomeViewModel.swift:1838-1851`: reconcile returns early while `.scanning`/`.paused` (no pruning).
- `:1062-1064` and `:1708-1727` (now `PhotoResultsStore.mergeScanUpdate`): `preservedGroups`, captured at scan start, are filtered only by `update.evaluatedAssetIDs`, and the engine re-emits groups built from its own `assetsByID`. Deleted assets therefore come back on every update.
- `iOSCleanup/Views/Photos/PhotoResultsView.swift:9` hides cleaned groups only in local `@State`. `SwipeModeView(groups: viewModel.photoGroups)` (`PhotoDuckShellView.swift:279`) and `SwipeModeViewModel.init(groups:)` (`SwipeModeViewModel.swift:63-66`) read the view model.
- `:36-52`: the observer proxy discards the `PHChange`. Every change runs `existingAssetIdentifiers` (`:1968-1978`), a full refresh (`:1903`) and `saveAnalysisSnapshot(isComplete: true)` (`:1917`), which re-stamps `savedAt`. Restore then shows that timestamp as `lastCompletedAt`.
- **STATE-05:**
  - `schedulePhotoLibraryRefresh` (`:1821-1828`) checks `Task.isCancelled` once, after its 250 ms sleep. `reconcilePhotoLibraryChange` never re-checks it after its own awaits, and it checks the run state only on entry (`:1831-1851`).
  - After `await existingAssetIdentifiers(...)`, `:1859-1886` filters the **current** collections by `validIDs`, which contains only IDs captured *before* the await. Anything published during the await, such as video-pass files from `publishFileScanUpdate` (`:1482-1488`) or a new run's groups, is removed as if deleted.
  - It then unconditionally overwrites `lastCompleted*` and freshness (`:1895-1900`).
  - The guard does not check `isFinishingSupportingScans`.
- **STATE-06:**
  - `:1900` sets `.stale` unconditionally.
  - `:1612-1614` sets `.stale` whenever `lastCompletedLibraryTotalCount != currentCount`, and reconcile never updates that count.
  - "Every launch" is overstated. The reconcile-written snapshot carries the post-deletion `libraryTotalCount`, and restore resets `lastCompletedLibraryTotalCount` and freshness (`:2223, :2251`). So "stale" persists for the rest of the session, on every foreground, not across relaunch.
- `iOSCleanup/Models/PhotoGroup.swift:75-89`: when `deleteCandidateIDs` is empty for a high-confidence, unblocked `.nearDuplicate` with a keeper, `init` **infers** every unprotected non-keeper as a delete candidate. Today's prune filters `deleteCandidateIDs` to survivors and passes the old `recommendedAction`. A group {K, A, B} with delete plan [A] therefore becomes {K, B} with plan [B] once A is deleted, even though the classifier never selected B.
- `_storageInfo` (`:565-574`) is reset only in reconcile and `removeLargeFileFromResults`.
- `DeletionManager` is `@MainActor` (`iOSCleanup/Engines/DeletionManager.swift:64-65`). WS-11 replaces its API with typed results and receipts.

### Implementation plan

**WS-21.1 — `PhotoResultPruner` (one pruner for every path)**
- **Change:** New `iOSCleanup/Views/Home/PhotoResultPruner.swift`:
  ```swift
  enum PhotoResultPruner {
      struct Result { let groups: [PhotoGroup]; let screenshots: [PHAsset]; let blurry: [PHAsset]; let files: [LargeFile]; let changed: Bool }
      static func removing(_ missingIDs: Set<String>, groups: [PhotoGroup], screenshots: [PHAsset],
                           blurry: [PHAsset], files: [LargeFile]) -> Result
      /// nil when fewer than 2 members survive; the SAME value when no member is missing.
      static func prunedGroup(_ group: PhotoGroup, removing missingIDs: Set<String>) -> PhotoGroup?
  }
  ```
  `prunedGroup` rules. Every rebuild goes through `PhotoGroup.init` (invariant 1):
  1. `survivors = group.assets.filter { !missing.contains($0.localIdentifier) }`, in order. If `survivors.count < 2`, return nil.
  2. `keeperSurvives = group.keeperAssetID.map { !missing.contains($0) } ?? false`, and `survivingDeleteIDs = group.deleteCandidateIDs.filter { !missing.contains($0) }`.
  3. `keepsPlan = keeperSurvives && !survivingDeleteIDs.isEmpty && group.recommendedAction == .keepBestTrashRest`.
  4. Call `PhotoGroup(id: group.id, assets: survivors, …same fields…, recommendedAction: keepsPlan ? .keepBestTrashRest : .reviewManually, keeperAssetID: keeperSurvives ? group.keeperAssetID : nil, deleteCandidateIDs: keepsPlan ? survivingDeleteIDs : [], bestShotPhotoId: keeperSurvives ? group.bestShotPhotoId : nil, captureDateRange: nil, candidates: group.candidates.filter { !missing.contains($0.photoId) }, reclaimableBytes: nil)`.
  - Passing `.reviewManually` whenever the surviving plan is empty prevents `PhotoGroup.init`'s delete-candidate inference. That inference would otherwise promote a member the classifier never selected.
- **Store integration** (`PhotoResultsStore`):
  - `private(set) var excludedAssetIDs: Set<String>`, the tombstones.
  - `func excludeAndPrune(_ ids: Set<String>) -> Bool` adds the tombstones and prunes the current collections.
  - `func clearExclusions()`.
  - `mergeScanUpdate` runs `PhotoResultPruner.removing(excludedAssetIDs, …)` over both the preserved results and the update before assigning.
  - WS-12's user-kept hook still runs last on every write.
- `LargeVideoScanController` gets `excludeAndRemoveFiles(_ ids: Set<String>) -> Bool` and filters `update.largeFiles` in its publish path by its own `excludedAssetIDs`. Replace `pruneFiles(keeping:)` (WS-16) with it.

**WS-21.2 — Confirmed-deletion tombstones**
- **Change:**
  - `DeletionManager`: WS-11 publishes only `lastReceipt`. Add `let confirmedDeletions = PassthroughSubject<Set<String>, Never>()` and send it in `commit` right after `lastReceipt = receipt`. That makes it **exactly once per PhotoKit-confirmed commit**, with the receipt's asset IDs (WS-11's `DeletionReceipt.assetIDs`), on every path: Keep Best, delete, Duck Mode, the large-video delete and the export delete. Never send it for a declined, failed or guardrail-rejected commit.
  - Later per-commit hooks extend `applyConfirmedDeletion(assetIDs:)` rather than adding another subscriber: WS-32's "DeletionReceipt hook" (session deletion count, storage refresh) and chapter 13's forwards. `assetIDs.count` equals the receipt's `itemCount`.
  - `ContentView`: `.onReceive(deletionManager.confirmedDeletions) { dashboardModel.applyConfirmedDeletion(assetIDs: $0) }`. `onReceive` delivers every value, whereas `onChange` can coalesce two commits in one render and lose one of them.
  - `HomeViewModel.applyConfirmedDeletion(assetIDs:)` runs in every scan state:
    - `resultsStore.excludeAndPrune`
    - `largeVideoController.excludeAndRemoveFiles`
    - recompute `groupsFoundCount`, `reviewablePhotosCount` and `reclaimableBytesFoundSoFar`
    - `_storageInfo = nil`, `publishProgressSnapshot()`, `persistCleanupState()`
    - It never touches the inventory, checkpoints, freshness or the snapshot.
  - Duck Mode: add `excludedAssetIDs: Set<String> = []` to WS-12's initializer, giving `SwipeModeViewModel.init(groups:keepStore:excludedAssetIDs:transitionDelayNanoseconds:)`. `buildQueue` skips excluded IDs, so WS-12's `resetQueue()` rebuild does too. (WS-12 does not persist pending decisions.) `SwipeModeView(groups:keepStore:excludedAssetIDs:)` defaults it to `[]`, and `PhotoDuckShellView.swift:279` passes `viewModel.excludedAssetIDs`, a pass-through to the store.
  - Clear tombstones only when no run is active: no photo run, no supporting or video pass, not paused. Do it at the end of `runPostRunFollowUpIfNeeded()`, after its reconcile (if any) has pruned. Do **not** clear at full-rescan start: that run's prefetched array (WS-18) may predate the deletion.
- **Edge cases:**
  - Compression's replace still deletes the original directly until WS-43. It leaves results through the `PHChange` path (WS-21.3/21.4), not tombstones.
  - Tombstones are in-memory only. After a relaunch, rehydration drops deleted members (WS-17).

**WS-21.3 — Incremental `PHChange` details in the inventory**
- **Change:**
  - `PhotoLibraryChangeObserverProxy` (now in `PhotoLibraryInventory.swift`) yields `struct PhotoChangeBox: @unchecked Sendable { let change: PHChange }` into an `AsyncStream` (`.bufferingNewest(64)`).
  - One consumer Task in the inventory processes changes **serially**. For each change:
    - It computes `change.changeDetails(for: retainedImageFetchResult)` and the same for the video result, in `Task.detached`.
    - If the details are non-nil and `hasIncrementalChanges`, it applies `removedObjects`, `insertedObjects` and `changedObjects` to `metadataByID` and stores `fetchResultAfterChanges`.
    - Otherwise it marks the inventory dirty and sets `isIncremental = false`.
    - **Video inserts (lead L3).** WS-18.2 already turns the video `changeDetails` into a `VideoChangeDelta` and calls `applyVideoChange(_:)`, which updates `videoCount` and fires `onVideosInserted`. Move that step into this serial consumer unchanged, so image and video details for one `PHChange` are processed together. Add the video result's `removedObjects` IDs to the event's `removedIDs`. Keep WS-18's video-signal tests green. WS-27 sets the hook; nothing in this PR does.
  - It emits:
    ```swift
    struct LibraryChangeEvent: Sendable {
        let removedIDs: Set<String>                 // images + videos removed from the retained fetches
        let isIncremental: Bool                     // false ⇒ reconcile must verify existence itself
    }
    ```
    through `onLibraryChange: (@MainActor (LibraryChangeEvent) -> Void)`, which replaces WS-18's `() -> Void`.
  - Extract a pure reducer for tests: `static func applying(removed: Set<String>, upserted: [String: CachedPhotoAssetMetadata], to: [String: CachedPhotoAssetMetadata]) -> [String: CachedPhotoAssetMetadata]`.
  - `schedulePhotoLibraryRefresh(event:)` keeps the 250 ms debounce but **merges** `removedIDs` from coalesced events. An `isIncremental == false` event makes the merged event non-incremental.
- **Edge cases:**
  - Without retained fetch results (a launch that used token deltas), events are non-incremental. The reconcile then verifies existence and refreshes through tokens, which is still not a full enumeration.
  - `removedObjects` also covers assets that became hidden. Treating them as missing is correct: they can't be reviewed.

**WS-21.4 — Reentrancy-safe reconcile**
- **Change:** Rewrite `reconcilePhotoLibraryChange(_ event: LibraryChangeEvent?)`:
  ```swift
  private var isRunActive: Bool {
      isFinalizingPhotoScan || scanState == .scanning || scanState == .paused
          || isFinishingSupportingScans || fileScanState == .scanning      // any video pass counts (lead L4)
  }
  private func reconcilePhotoLibraryChange(_ event: LibraryChangeEvent?) async {
      guard !Task.isCancelled else { return }
      // 1. Only IDs PhotoKit reported missing — never a keep-list captured before an await.
      let missing: Set<String>
      if let event, event.isIncremental {
          missing = event.removedIDs
      } else {
          let checked = currentResultAssetIDs()                            // photos + files, captured now
          let existing = await inventory.existingIdentifiers(among: checked)
          guard !Task.isCancelled else { return }
          missing = checked.subtracting(existing)                          // later additions are untouched
      }
      // 2. Prune in every state, and tombstone so a running scan cannot re-add them.
      if !missing.isEmpty { applyMissingAssets(missing) }                  // same body as applyConfirmedDeletion
      // 3. A run owns inventory, freshness, counts and the snapshot.
      if isRunActive { libraryChangedDuringRun = true; scheduleMidRunCheckpointIfAllowed(); return }
      if event?.isIncremental != true { await refreshLibraryMetadata(reason: .libraryChange) }
      guard !Task.isCancelled else { return }
      if isRunActive { libraryChangedDuringRun = true; return }
      updateCompletedScalarsFromResults()                                  // lastCompleted* = current counts
      guard hasHydratedAnalysisCache else { persistCleanupState(); return } // invariant 14
      let pending = await inventory.pendingAnalysisIDs()
      guard !Task.isCancelled else { return }
      if isRunActive { libraryChangedDuringRun = true; return }
      applyFreshness(pendingCount: pending.count)                          // WS-21.6
      persistCleanupState()
      if !pending.isEmpty { await scanPhotos(mode: lastCompletedMode ?? cleanupMode) }
      else { scheduleCoalescedReconcileSnapshot() }                        // WS-21.7
  }
  ```
  - `inventory.existingIdentifiers(among:)` moves today's `existingAssetIdentifiers` into `PhotoLibrarySource` (add `func existingIdentifiers(among ids: Set<String>) async -> Set<String>`) so tests can inject a slow checker.
  - `scheduleMidRunCheckpointIfAllowed()` keeps today's mid-run `scheduleSnapshot(...)` (`:1844-1848`) behind the WS-20 gate and WS-16's off-main build.

**WS-21.5 — Exactly one follow-up when a run ends**
- **Change:**
  - `PostRunFollowUpPolicy.action(runSucceeded:libraryChangedDuringRun:pendingAnalysisCount:)` returns:
    - `.reconcile` if the library changed during the run (the reconcile scans itself when analysis is pending)
    - otherwise `.incrementalScan` if the run succeeded and `pending > 0`
    - otherwise `.none`
  - `runPostRunFollowUpIfNeeded(runSucceeded:)` (from WS-19) captures and clears `libraryChangedDuringRun`, runs the one action, then clears the tombstones.
  - Cancelled and failed runs also call it with `runSucceeded: false`, so a change during a failed run is still reconciled.
  - A paused run has not ended, so the flag stays set until the run ends.
  - **End of every video pass (lead L4).** The follow-up also runs when a video pass ends, not only a photo run:
    - In this PR the video passes are the supporting pass (already covered by WS-19's call site) and `scanFiles(force:)` runs. After `largeVideoController.runScan` returns, `scanFiles` calls `runPostRunFollowUpIfNeeded(runSucceeded: false)`, which only replays a deferred `libraryChangedDuringRun` reconcile.
    - WS-27 (chapter 06) routes every video pass (the pre-pass, explicit refresh, insertion rescan and supporting pass) through `runVideoPass`, whose last step (R4) makes this same call.
  - The follow-up returns immediately while `isRunActive` is still true, leaving the flag and the tombstones in place. An example is a video pass that ends while a photo run is paused. Whichever run ends last performs the single follow-up.

**WS-21.6 — `ResultsFreshnessPolicy` (D-RESULTS-FRESHNESS)**
- **Change:** New `iOSCleanup/Views/Home/ResultsFreshnessPolicy.swift`:
  ```swift
  enum ResultsFreshnessPolicy {
      static func resolve(hasCompletedScan: Bool, pendingAnalysisCount: Int, isScanning: Bool) -> CleanupResultsFreshnessState {
          if isScanning || !hasCompletedScan { return .live }
          return pendingAnalysisCount > 0 ? .stale : .lastKnown
      }
  }
  ```
  - `applyFreshness(pendingCount:)` sets `resultsFreshnessState` from the policy (with `hasCompletedScan = lastCompletedAt != nil`, `isScanning = scanState == .scanning`). When `pendingCount == 0 && hasCompletedScan`, it also sets `lastCompletedLibraryTotalCount = libraryTotalCount`.
  - In `refreshLibraryMetadata(reason:)`, replace `:1612-1622` with: when `scanState` is `.idle`/`.completed` and hydrated, `applyFreshness(pendingCount: await inventory.pendingAnalysisIDs().count)`. Delete the count-comparison rule entirely.
  - The no-work path in `scanPhotos` (`:1036-1040`) keeps setting `.live`.
- **Edge cases:**
  - A launch that detects deletions only (through token deltas) reaches the same code, so freshness stays `.lastKnown`.
  - The same launch also calls `scheduleCoalescedReconcileSnapshot()`, which persists the new token and inventory.

**WS-21.7 — Coalesced reconcile snapshot that keeps the completion date**
- **Change:**
  - `CachedPhotoAnalysisSnapshot` gets `let completedAt: Date?`:
    - add it to `CodingKeys` with `decodeIfPresent`; `init` defaults it to nil
    - copy it in `withPersistenceGeneration`, `droppingUncoveredInventory` and `repairingPrematureCompletion` (nil there, since that snapshot is incomplete)
  - `AnalysisSnapshotInputs` gets `preservedCompletedAt: Date?`. `build` sets `completedAt = snapshotIsComplete ? (inputs.preservedCompletedAt ?? inputs.savedAt) : nil`.
  - WS-15's `SnapshotFacts.completedAt` becomes `snapshot.completedAt ?? snapshot.savedAt`, so "Checked on" shows the real completion date.
  - `scheduleCoalescedReconcileSnapshot()`:
    - Cancel the previous `reconcileSnapshotTask` and sleep 5 s (`Task.sleep`, cancellable). Tests inject a zero delay through a new `HomeViewModelDependencies` field, `reconcileSnapshotDelay: Duration = .seconds(5)` (WS-07's grow-with-defaults pattern).
    - Then `guard !isRunActive, hasHydratedAnalysisCache, persistenceGate.allowsLibraryWrites`.
    - Capture inputs with `preservedCompletedAt: lastCompletedAt`, build off-main, and `analysisCache.scheduleSnapshot(snapshot, captureSequence:)`.
    - Then run the ML `persistFeatureRecords` for group assets, exactly as `saveAnalysisSnapshot` did, followed by `refreshPersistenceHealth()`. Both are transitional: WS-34 (chapter 07) deletes this ML feature-record block, and WS-47 (chapter 10) deletes `refreshPersistenceHealth()` and every call to it in favor of its health observer. Build nothing new on either.
  - Delete `saveAnalysisSnapshot(isComplete:)`; its only caller was reconcile (`:1917`).
  - Update the golden literals: the complete golden gains `completedAt`. Explain this in the PR.

**WS-21.8 — Storage card refresh**
- **Change:** `updateScenePhase(.active)`: `_storageInfo = nil`. The `.active` branch already assigns the published `isBackgroundExecutionState`, which triggers a re-render. `applyConfirmedDeletion` also resets it. WS-32 replaces the storage model later.

### Tests
All tests run in the simulator.
- `iOSCleanupTests/PhotoResultPrunerTests.swift` (WS-03 `PHAsset` double; groups built through `PhotoGroup.init` with explicit keeper, delete IDs and `.keepBestTrashRest`):
  - `testRemovingDeleteCandidateShrinksGroupAndKeepsPlan`: {K,A,B} with plan [A,B]; remove A gives {K,B} with plan [B].
  - `testRemovingLastPlannedCandidateDowngradesInsteadOfInferring`: {K,A,B} with plan [A]; remove A gives `.reviewManually` and an empty plan. **B is never selected.**
  - `testRemovingKeeperMakesGroupReviewOnly`
  - `testGroupBelowTwoMembersIsDropped`
  - `testUntouchedGroupIsReturnedUnchanged`: same `id`, same plan.
  - `testVisuallySimilarStaysReviewOnly`
  - `testScreenshotsBlurryAndFilesArePruned`
  - `testItemsNotInMissingSetSurvive`: STATE-05, items added after the capture.
- `iOSCleanupTests/ResultsFreshnessPolicyTests.swift`:
  - `testDeletionsOnlyStayLastKnown`
  - `testPendingAdditionsAreStale`
  - `testScanningIsLive`
  - `testNoCompletedScanIsLive`
- `iOSCleanupTests/PhotoLibraryInventoryTests.swift`:
  - `testChangeReducerAppliesRemovedInsertedChanged`
  - `testNonIncrementalChangeMarksDirty`
  - `testDebouncedEventsMergeRemovedIDs`
- `iOSCleanupTests/PostRunFollowUpPolicyTests.swift`:
  - `testLibraryChangeDuringRunReconcilesOnce`
  - `testFailedRunWithChangeStillReconciles`
  - `testVideoPassEndOnlyReplaysDeferredChange`: `runSucceeded: false` with no change and 5 pending gives `.none`; with `libraryChangedDuringRun` it gives `.reconcile`.
- `iOSCleanupTests/HomeViewModelTests.swift` (WS-07 seam, `FakePhotoLibrarySource` with a suspendable `existingIdentifiers`, stub engine factory, temp caches, zero reconcile delay):
  - `testConfirmedDeletionDuringScanIsNotReaddedByNextUpdate` (UI-08): seed a scanning state with a group (keeper plus 2 candidates), apply the deletion, then feed a `PhotoScanUpdate` containing the same group. It stays excluded.
  - `testReconcileKeepsFilesPublishedDuringAwait` (STATE-05): suspend the existence check, publish 8 more large files, resume. All files survive.
  - `testReconcileDoesNotTouchRunStartedDuringAwait`: start a run during the suspension. Freshness and counts are untouched, and `libraryChangedDuringRun` is true.
  - `testInAppDeletionNeverMarksStale` (STATE-06)
  - `testReconcileSnapshotPreservesCompletionDate`: `completedAt` equals the previous `lastCompletedAt`.
  - `testLimitedSessionReconcileWritesNothing`
  - `testLibraryChangeDuringVideoPassReconcilesWhenPassEnds` (lead L4):
    - Suspend a `scanFiles(force: true)` pass with a `FileScanEngine` stub whose asset provider awaits a test continuation.
    - Deliver a non-incremental library change. `libraryChangedDuringRun` is true, and the engine factory is not called.
    - Resume the pass. Exactly one reconcile runs, and the flag is cleared.
- `iOSCleanupTests/SwipeModeViewModelTests.swift` (create if absent): `testExcludedAssetsNeverQueued`.

### Acceptance criteria
- [ ] Deleting via Keep Best during an active or paused scan removes the group from Home tiles, the Similar tab, reopened results, Duck Mode and Auto-clean plans within one update, and later scan updates never re-add it (tests plus device QA).
- [ ] Nothing published during a reconcile is removed unless PhotoKit reported it missing, and a reconcile never changes the freshness or counts of a run that started after it (tests).
- [ ] After Keep Best, Duck Mode or a large-video deletion, Home never says "library changed since the last scan". Adding a new photo still triggers the incremental scan.
- [ ] A `PHChange` burst during iCloud sync performs no full enumeration when incremental details exist (DEBUG counters, device QA).
- [ ] Reconcile snapshot writes are coalesced (at most one per 5 s), gated, and never re-stamp the completion date.
- [ ] Returning to the app after emptying Recently Deleted updates the storage card.
- [ ] No pruning path can promote a non-planned member to a delete candidate (the pruner test named above).
- [ ] `ios-cleanup/CLAUDE.md`: in the `HomeViewModel` line, "Tracks freshness…" is updated to D-RESULTS-FRESHNESS ("stale only when unanalyzed additions/modifications are pending"), and confirmed deletions are described as tombstoned across all surfaces.

### Device QA
- **Deletion mid-scan.** On a 20k+ library, during a Deep Clean, open "Review partial results" and Keep Best 3 groups.
  - Within one update they are gone from the Similar tab, the Duplicates tile and Duck Mode.
  - They do not return before or after the scan completes.
- **iCloud sync burst.** Enable iCloud Photos sync from another device adding 50 photos while PhotoDuck is open.
  - The DEBUG log shows incremental events with no full enumeration, and at most one snapshot write per 5 s after the scan.
- **No stale banner.** Complete a scan, Keep Best 5 groups, background and foreground the app 3 times. Home never shows "library changed since the last scan".
- **Storage card.** Empty Recently Deleted in Photos and return. The storage card's free space increases.

### Pitfalls and out of scope
- **Invariant 1:** every pruned group goes through `PhotoGroup.init`, and an empty surviving plan is always `.reviewManually`. See the inference trap under *Current behavior*.
- **Invariant 13:** re-check `isRunActive` after every await, and never mutate a run's inventory, checkpoints or snapshot from reconcile. WS-28 (chapter 06) renames the stored run lock `isFinalizingPhotoScan` to `isPhotoRunActive` and leaves a narrower computed `isFinalizingPhotoScan` (only while `.completed`). `isRunActive` must then read `isPhotoRunActive`. After WS-27 its last two terms are `isVideoPassRunning`.
- **Invariant 14:** never write before hydration. The coalesced write is the only reconcile write.
- **Invariant 15:** the coalesced write and the mid-run checkpoint go through the WS-20 gate.
- **Invariant 9:** do not record stats or feedback in `applyConfirmedDeletion`; `DeletionManager` already did.
- Out of scope:
  - the storage model and "freed" accounting (WS-32, chapter 07)
  - video freshness and consuming `retainedVideoFetchResult` (WS-27)
  - compression's direct delete (WS-43)
  - automatic-scan UX for the reconcile-triggered incremental scan (WS-26)
  - the completion sheet (WS-31)
- **Reconciliation (lead L4):** the single follow-up fires at the end of every photo run and at the end of every video pass. `isRunActive` counts any video pass (`fileScanState == .scanning`), so a change during a Files-tab or explicit pass is deferred and then replayed exactly once. WS-27's R4 keeps this for its pre-pass, explicit refresh and insertion rescans.
- **Reconciliation (lead L3):** WS-18 defines and fires `videoCount`/`onVideosInserted` (through `applyVideoChange(_:)`). WS-21.3 only moves that call into its serial consumer unchanged. WS-27 only subscribes.
- **Reconciliation:** `SwipeModeViewModel`'s initializer extends WS-12's signature (`groups:keepStore:excludedAssetIDs:transitionDelayNanoseconds:`). The reference to "WS-12's restored pending decisions" is dropped, because WS-12 does not persist pending marks (BACKLOG).
- **Reconciliation:** WS-40 (chapter 08) routes `existingIdentifiers(among:)` and every other identifier fetch through `PhotoLibraryFetch.identifierOptions()`. Never use `options: nil`; WS-40's lint forbids it.
- **Reconciliation (lead L25):** WS-42 (chapter 09) renames `FileScanUpdate.largeFiles` to `retainedVideos`. WS-42 updates this PR's `LargeVideoScanController` publish-path filter and WS-15's `ScanDiagnosticsRecorder.recordVideoProgress`.
- **Reconciliation:** later stored `PhotoGroup` fields must survive `PhotoResultPruner.prunedGroup`: WS-40's `autoCleanPolicy` (chapter 08) and WS-63's `pairEvidence` (chapter 13). Those workstreams add the field to this `PhotoGroup(...)` call.
- **Reconciliation:** `confirmedDeletions` is added here, because WS-11 publishes only `lastReceipt`, and it carries `Set<String>`. Consumers that need per-commit numbers (WS-32) extend `applyConfirmedDeletion(assetIDs:)`.

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| FSA-04 | confirmed | The mid-scan early return, the re-add through preserved groups and engine re-emission, the discarded `PHChange`, the full rewrite with a new `savedAt`, and the process-lifetime `_storageInfo` are all real. The plan follows items 1–4, with three differences. (1) Tombstones are cleared only when no run is active, not at full-rescan start, because WS-18's prefetched array can predate the deletion. (2) The completion date survives through a new optional `completedAt` field instead of re-using `savedAt`. (3) Tombstones also cover IDs that PhotoKit reports missing, not only in-app receipts, since preserved groups would re-add those too. |
| UI-08 (merged) | confirmed | Reproduced by reading `mergeScanUpdate`, `SwipeModeViewModel.init` and `PhotoResultsView`'s local `hiddenGroupIDs`. The publisher is a `PassthroughSubject` observed with `.onReceive` instead of an `onChange` on an ID, which can coalesce two commits. Duck Mode exclusion is kept as a belt-and-braces measure, and so that WS-12's `resetQueue()` rebuild skips tombstoned IDs. |
| STATE-05 | confirmed | The stale keep-list prune and the entry-only run check are real. The cancellation claim is imprecise: the scheduling closure checks `Task.isCancelled` once, after the sleep, but reconcile never re-checks after its own awaits. The plan follows fix items 1–3, and it also adds `isFinishingSupportingScans` to the run check. The finding's scenario depends on it. |
| STATE-06 | partially | The unconditional `.stale` and the count comparison are real. The staleness lasts the rest of the session (every foreground), not every launch: the reconcile-saved snapshot carries the new library count, and restore resets freshness. The plan follows the fix, with pending analysis coming from WS-18's inventory diff instead of a JSON reload. |
