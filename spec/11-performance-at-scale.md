# Chapter 11 — Performance at 10k–60k assets

> **Milestone(s):** M3 · **Workstreams:** WS-49 – WS-54 · Read `spec/README.md` first: operating rules, invariants, build/test commands and the decision log apply to every workstream here.

## Chapter overview

These six workstreams keep PhotoDuck smooth, cool and alive while it scans and reviews a 50–60k-item iCloud library on a 3–4 GB iPhone. WS-49 finishes the `HomeViewModel` decomposition by moving the scan lifecycle into a tested `PhotoScanCoordinator`; it can be cut. WS-50 isolates rendering. Progress ticks re-render only small leaf views, at most four times a second, and the results screens compute their derived state once per change. WS-51 and WS-52 bound image memory and latency: no full-original decodes, review and fullscreen images kept out of the shared thumbnail LRU, Duck Mode prefetch, a UI request lane that never rejects, shared size buckets and PhotoKit caching. WS-53 bounds engine memory and keeps partial results streaming. WS-54 cuts checkpoint and file-size-cache writes by an order of magnitude.

When the chapter is done, a 60k first scan finishes without jetsam or visible jank, groups keep appearing every ~15 s, the review screens stay fluid, and the scan writes under 1 GB instead of 5–7 GB. **The key risk** is that all of this is behavior-preserving work on code that about 40 earlier workstreams reshaped. Each workstream therefore starts with a golden, transcript or reference-equivalence test that proves it did not change classification, keeper choice, deletion semantics or run fencing (invariants 13, 17, 22).

**Conventions used in this chapter**
- **"The apply site"** means `apply(update:…)`, `publishProgressSnapshot`, the worker loop and the checkpoint cadence code. These live in `iOSCleanup/Views/Home/PhotoScanCoordinator.swift` if WS-49 landed, and in `iOSCleanup/Views/HomeViewModel.swift` otherwise. Find it with `grep -rn "func apply(update" iOSCleanup/Views`.
- Line numbers are from the 2026-09-27 baseline. WS-07…WS-48 moved most of this code, so re-find everything by symbol.
- **Cut lines.** WS-49 and WS-52 may be cut (README §2). If WS-52 is cut, WS-54 lands WS-52.1 (`LRUCache`) as its first commit.

---

## WS-49 — HomeViewModel extraction III: PhotoScanCoordinator

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M3 | L | WS-21, WS-27, WS-28, WS-29 | no | `ws/49-photo-scan-coordinator` |

**Primary files:** `iOSCleanup/Views/HomeViewModel.swift`, `iOSCleanup/Views/Home/PhotoScanCoordinator.swift` (*new*), `iOSCleanup/Views/Home/PhotoScanCoordinatorHost.swift` (*new*), `iOSCleanupTests/ScanLifecycleTranscriptTests.swift` (*new*), `iOSCleanupTests/PhotoScanCoordinatorTests.swift` (*new*), `iOSCleanupTests/Support/HomeViewModelTestHarness.swift` (WS-07), `iOSCleanup.xcodeproj/project.pbxproj`, `CLAUDE.md`
**Findings covered:** STATE-12 (P2, confirmed; phases 0–8 were delivered by WS-07, WS-15, WS-16, WS-18 and WS-31, so this is phase 9)
**Decisions applied:**
- **D-HVM-DECOMP:** phase 9, last and riskiest. It is a verbatim, behavior-preserving move behind the unchanged view API. It can be cut: if it is, record that in the release notes, and the M3 exit criterion "HomeViewModel ≈ 700 lines" is waived.
- **D-SCAN-CONTINUITY / D-BACKGROUND:** WS-28's and WS-29's pause, background and auto-resume logic moves unchanged. No behavior is redesigned here.

### Goal
The photo-scan lifecycle lives in one `@MainActor` type that can be unit-tested with an injected engine factory. That covers the engine, `activeScanID`, the run lock, pause/resume/restart/retry, supporting-scan sequencing, scene phase, the background lease and continuation, and relaunch auto-resume. `HomeViewModel` becomes a facade of about 700 lines of composition and forwarding. No view file changes. Every existing test, WS-07's simulator fixture smoke test, and a new lifecycle transcript golden pass unchanged.

### Current behavior (verified)
- `iOSCleanup/Views/HomeViewModel.swift` is 2,640 lines, with one `@MainActor final class HomeViewModel: ObservableObject` (`:148`). At baseline it owns about ten responsibilities, as STATE-12 lists. WS-15, WS-16, WS-18 and WS-31 extract diagnostics, notifications, persistence scalars, checkpoint state and the snapshot builder, the large-video controller, the result store, the inventory and the presentation. What remains after WS-29 is mostly the photo-scan lifecycle.
- **Lifecycle members at baseline:**
  - `startDeepClean` `:830`
  - `restartPhotoScan` `:837-853` (deleted by WS-26, which adds `startPhotoScan(from: PhotoScanEntryPoint)`, the internal `refreshPhotoScan(requestsBackgroundContinuation:)` and the private `rescanEntireLibrary()`)
  - `resumeDeepClean` `:855-880`
  - `pauseDeepClean` `:882-916`
  - `scanPhotos(mode:…)` `:922-1346`. The engine is created at `:1151`. The worker `Task` starts at `:1154` and inherits `@MainActor` (WS-16 verified this).
  - `retryIncludingICloudPhotos` `:1348`
  - `updateScenePhase` `:1530-1584`
  - `apply(update:…)` `:1674-1779`
  - supporting scans `:1781-1819`
  - `scanNewPhotosIfNeeded` `:1921-1946`
  - `updateScanRate` `:1980`
  - `persistCleanupState` `:2336-2374`
  - `loadPersistedCleanupState` `:2485-2526`
- **Run state:** `scanTask` `:266`, `supportingScansTask` `:267`, `activePhotoScanEngine` `:269` and `activeScanID` `:270`. The run lock `isFinalizingPhotoScan` is at `:238`; WS-28 renames it `isPhotoRunActive`.
- **Fencing.** Every hop from the worker checks `guard self.activeScanID == scanID` (`:1165`, `:1193`, `:1246`, `:1268`, `:1305`), and the planner checks it at `:983`.
- **Durable-state mapping.** `:2341-2344` persists `.scanning` while `isFinalizingPhotoScan && scanState == .completed`.
- **Completion barrier.** The completion block ends with `isFinalizingPhotoScan = false` and then `persistCleanupState()` (`:1241`).
- **What earlier workstreams add to this cluster** (re-inventory it; do not trust the baseline lines):
  - WS-26: `ScanOrigin`, user vs automatic entry points, the confirmed full rescan.
  - WS-24/WS-27: the reason-set `ScanPauseGate` (`ScanPauseReason`: `.user`, `.thermal`, `.videoPass`, `.background`), the engine's `drainPoint()`, `inFlightAnalysisCount` and `isInAnalysisLoop`, and WS-27's `pause(reason:quiesceTimeout:) -> PhotoScanPauseAck` (with its `quiesceSleep` init seam).
  - WS-27: videos first, `isVideoPassRunning`, `scanFiles(trigger:)` sequencing, photo/video serialization, `LargeVideoScanController.run(budget:)`, `passGeneration`/`invalidateAndCancelCurrentPass()`, and `runPostRunFollowUpIfNeeded()`.
  - WS-28: `isPhotoRunActive`, `pauseReason`, `suspendActiveRun`, `CommittedProgressWaiter`, `ScenePhaseScanPolicy`, `ScanAutoResumePolicy`, `BackgroundTaskLease` (`iOSCleanup/Utilities/BackgroundTaskLease.swift`).
  - WS-29: `IdleTimerCoordinator.shared.acquire(reason:)`/`release(_:)` wiring, and the `ScanBackgroundContinuing` continuation (`ScanBackgroundContinuation.swift`).
  - WS-21: reconcile supersession and the post-run follow-up (run through WS-27's `runPostRunFollowUpIfNeeded()`).
  - WS-22: the retry entry points.
  - WS-25: resource-policy hooks.
  - WS-20: `activeRunAuthorization` and `stopActiveRunsWithoutCheckpoint()`; WS-48 reuses that shape as `stopAllRunsForLocalDataClear()`.
  - WS-30: `ReclaimMeasurementController.cancel()` when a photo run or video pass starts and on `.background`, and `refresh(…)` after the completion barrier.
  - WS-37: the run-scoped `runAnalyzerStamp` and the `AnalyzerUpgradePolicy` term at the planner call.

### Implementation plan

**WS-49.1 — Member map and lifecycle transcript golden (tests only, commit 1)**
- **Why:** D-HVM-DECOMP requires proof that the move changes nothing. The riskiest properties are fencing, the run lock, the durable-state mapping and the completion barrier. They are observable only as sequences of state over time, so capture them as a transcript *before* anything moves.
- **Change:**
  1. Write a member map into the PR description. List every stored property and method left in `HomeViewModel.swift` and mark each **C** (moves to the coordinator), **F** (stays in the facade) or **X** (already an extracted collaborator). Apply these rules:
     - A stored property moves if any moved method writes it. If the facade also writes it (for example reconcile or restore), the coordinator exposes **one** narrow method for that write, such as `applyRestoredRun(_:)` or `setResultsFreshness(_:)`.
     - Everything in the table below moves.

     | Moves to `PhotoScanCoordinator` (C) | Stays in `HomeViewModel` (F) |
     |---|---|
     | `activeScanID`, `activePhotoScanEngine`, `scanTask`, `supportingScansTask`, `startedSupportingScansForActiveScan` | Composition in `init`, bootstrap order, `objectWillChange` forwarding |
     | Published run state: `cleanupMode`, `scanState`, `isPaused`, `pauseReason`, `isPhotoRunActive`, `isFinishingSupportingScans`, `hasPartialResults`, `lastCompleted*` | Get-only pass-throughs with today's names and types (the view API) |
     | Progress counters, `progressSnapshot` and `publishProgressSnapshot`, `AnalysisCheckpointState`, `lastPersistTime`, `lastCheckpointTime`, rate sampling, `CommittedProgressWaiter` | Permission flows and `photoAuthorizationStatus` (WS-20) |
     | `scanPhotos(…)`, `startDeepClean`, WS-26's `startPhotoScan(from:)` with `refreshPhotoScan(requestsBackgroundContinuation:)`/`rescanEntireLibrary()`, `resumeDeepClean`/`resumeScan(trigger:)`, `pauseDeepClean`/`suspendActiveRun`, the retry entry points (WS-22), `scanNewPhotosIfNeeded`, WS-20's `stopActiveRunsWithoutCheckpoint()` and WS-48's `stopAllRunsForLocalDataClear()` (they write `activeScanID` and the run tasks) | Restore (`performCachedAnalysisRestore`), which ends by calling `coordinator.applyRestoredRun(restored)` |
     | `apply(update:…)`, `updateScanRate`, the completion block, supporting-scan and video-first sequencing (WS-27) | Library-change reconcile (WS-21), which calls coordinator methods for supersession |
     | The scan half of `updateScenePhase`, the background lease, `ScanBackgroundContinuation`, idle-timer policy wiring, launch auto-resume (WS-28.4) | Presentation inputs (WS-31), notification eligibility, the diagnostic report, storage info, persistence warnings (WS-47), Storage & data (WS-48) |
     | `persistCleanupState`, `makePersistedState`, `apply(persisted:)`, with the durable-state mapping verbatim | Ownership of `PhotoResultsStore`, `LargeVideoScanController` and `PhotoLibraryInventory` (passed to the coordinator) |

  2. New `iOSCleanupTests/ScanLifecycleTranscriptTests.swift` (`@MainActor`), using WS-07's `HomeViewModelTestHarness`. There are 24 `ConfigurablePhotoScanTestAsset`s (WS-08), and the analyzer parks on a `TestGate` at asset 12. A `TranscriptRecorder` subscribes to `$scanState`, `$isPaused`, `$isPhotoRunActive` and `$pauseReason` (the facade publishers), de-duplicates consecutive equal values, and appends lines such as `"scanState=paused"`. At named checkpoints it also appends:
     - `"persisted=<scanState>"`, read through WS-15's `CleanupStateStore` from the temp defaults;
     - `"snapshot=<isComplete>/<processed>"`, from the temp `PhotoAnalysisCache.loadSnapshot()`;
     - `"engines=<n>"`, the engine factory's call count.

     Five scenarios:
     - `testTranscriptFullRun`: start, gate open, completion.
     - `testTranscriptPauseResumeComplete`: start, then wait until processed ≥ 8, then `pauseDeepClean()`, open the gate, `resumeDeepClean()`, completion.
     - `testTranscriptBackgroundRoundTrip`: `updateScenePhase(.background)` while scanning, then wait for WS-28's ack checkpoint, then `.active`, then completion.
     - `testTranscriptSupersession`: while run A is parked, supersede it through WS-20's authorization transition. In a `Task`, call `handleAuthorizationChange(from: .authorized, to: .limited)` with the harness's stub authorization. Wait until `isPhotoRunActive == false` (A is fenced by `stopActiveRunsWithoutCheckpoint()`), then open A's gate so the stop's `await task.value` can finish. The transition's follow-up (`scanNewPhotosIfNeeded()` or `startDeepClean()`) starts run B. A's late updates must not change the published counts, and the final counts are B's. Do not use WS-26's `startPhotoScan(from: .gearRescanConfirmed)` here: `rescanEntireLibrary()` returns early while a run is scanning or paused, and the run-lock guard in `scanPhotos` blocks a direct call, so B would never start.
     - `testTranscriptCompletionBarrier`: at the instant a sink observes `scanState == .completed`, append `persisted` and `isPhotoRunActive`. Expect `persisted=scanning` and `isPhotoRunActive=true`. When `isPhotoRunActive` becomes false, the on-disk snapshot is complete.

     Paste each transcript as a string-array literal captured on the **pre-move** code. Record only deterministic observables: no publication counts and no timings.
- **Edge cases:** If a transcript is non-deterministic on the pre-move code, make it deterministic with gates or remove that observable. Never loosen it after a move.

**WS-49.2 — Coordinator skeleton, host protocol and forwarding (commit 2)**
- **Change:** new `iOSCleanup/Views/Home/PhotoScanCoordinatorHost.swift`:
  ```swift
  /// The few facade services the moved lifecycle code needs. Keep this to about 12 requirements or fewer;
  /// if it grows, move more state into the coordinator instead.
  @MainActor
  protocol PhotoScanCoordinatorHost: AnyObject {
      var photoAuthorizationStatus: PHAuthorizationStatus { get }
      var hasHydratedAnalysisCache: Bool { get }
      func ensureAnalysisCacheHydrated() async          // today's restoreCachedAnalysisIfNeeded()
      func scanDidReportError(_ message: String?)        // scanErrorMessage stays facade-owned
      func runDidEnd(_ ending: PhotoScanRunEnding)       // WS-21 follow-up (WS-27's runPostRunFollowUpIfNeeded()), WS-26 completion token, storage invalidation
  }
  enum PhotoScanRunEnding: Equatable { case completed, cancelled, failed, superseded }
  ```
  New `iOSCleanup/Views/Home/PhotoScanCoordinator.swift`:
  ```swift
  @MainActor
  final class PhotoScanCoordinator: ObservableObject {
      struct Collaborators {                 // use the exact type names WS-15…WS-29 created
          let dependencies: HomeViewModelDependencies
          let resultsStore: PhotoResultsStore
          let largeVideoController: LargeVideoScanController
          let inventory: PhotoLibraryInventory
          let diagnostics: ScanDiagnosticsRecorder
          let notifications: CompletionNotificationService
          let stateStore: CleanupStateStore
          let persistenceGate: LibraryPersistenceGate       // WS-20
          let idleTimer: IdleTimerCoordinator               // WS-29 (.shared)
          let backgroundContinuation: any ScanBackgroundContinuing     // WS-29's protocol, from dependencies.makeScanBackgroundContinuation()
          let reclaimMeasurement: ReclaimMeasurementController        // WS-30: cancelled at run start, refreshed after the barrier
          // Add any other WS-30…WS-48 collaborator the moved code calls. Pass it in here rather than growing the host.
      }
      weak var host: PhotoScanCoordinatorHost?
      init(_ collaborators: Collaborators)
      // Commits 3–5 move the published run state and the methods listed in WS-49.1 here, verbatim.
  }
  ```
  - `HomeViewModel` constructs the coordinator after its collaborators, sets `coordinator.host = self` (conforming in an extension in the same file), and forwards changes with `coordinator.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)`. This is WS-16's pattern.
  - Keep the facade property names as get-only pass-throughs: `var scanState: ScanState { coordinator.scanState }`, and so on. No view writes these today (grep confirms), so get-only is safe.
- **Edge cases:** `ScanState` and `HeroState` stay nested in `HomeViewModel`, because views and tests spell `HomeViewModel.ScanState`. The coordinator refers to `HomeViewModel.ScanState`.

**WS-49.3 — Move the run state and scan entry points (commit 3)**
- **Change:** move the C-state and the scan entry points (`scanPhotos(…)` with its planner call, worker, cancel and error paths, the restart/refresh/retry entry points, `scanNewPhotosIfNeeded`) into the coordinator, **verbatim**. The only permitted edits are:
  - `self.x` → `x`;
  - facade services reached through `host?.…`;
  - collaborators reached through stored lets.

  The facade methods become one-line forwards, such as `func startDeepClean() { coordinator.startDeepClean() }`.
- **Edge cases:**
  - Keep every `guard activeScanID == scanID` inside the same `MainActor.run` block and at the same position. The worker still inherits `@MainActor`, so the same-actor hops keep their fencing role.
  - The engine comes from `dependencies.makePhotoScanEngine()` only.
  - Review with `git diff -w --color-moved=dimmed-zebra`; moved blocks must show as moved, not rewritten.

**WS-49.4 — Move pause, resume, scene phase, background and relaunch continuity (commit 4)**
- **Change:** move `pauseDeepClean`/`suspendActiveRun`, the resume paths, the scan branch of `updateScenePhase` (WS-28's `ScenePhaseScanPolicy` switch), the lease, the WS-29 continuation and idle-timer wiring, and the WS-28.4 launch auto-resume, all verbatim. The facade's `updateScenePhase(_:)` keeps its diagnostics line and its `.active` inventory refresh (WS-18), and calls `coordinator.handleScenePhase(phase)` for the scan part.
- **Edge cases:**
  - The background path must still flush ML writes before `saveSnapshot`. WS-08's `onBackgroundCheckpointStep` ordering test pins this.
  - The lease must still end synchronously on expiry (WS-28.2).

**WS-49.5 — Move apply, the completion block and persistence (commit 5)**
- **Change:** move `apply(update:…)`, `updateScanRate`, the completion block, supporting-scan and video-first sequencing, and `persistCleanupState`/`makePersistedState`/`apply(persisted:)`, verbatim. `loadPersistedCleanupState` runs from the coordinator's `init` (it was called from the facade `init`, and the order relative to `publishProgressSnapshot()` is unchanged).
- **Edge cases:**
  - The completion barrier order stays exactly: durable `saveSnapshot`, then the completion `MainActor.run` block, then `isPhotoRunActive = false`, then `persistCleanupState()` **last**.
  - Photo and video scans still never load PhotoKit concurrently (invariant 16). The `scanFiles` guards read the coordinator's run state.

**WS-49.6 — Coordinator tests, cleanup and docs (commit 6)**
- **Change:**
  - Delete facade members that became unused.
  - `wc -l iOSCleanup/Views/HomeViewModel.swift` must be ≤ 800 (target ~700). If it is higher, list in the PR what remains and why.
  - In the `CLAUDE.md` "ViewModel layer", add a `PhotoScanCoordinator` row: the owner of the scan lifecycle and fencing, and `HomeViewModel` as the facade.

### Tests
All run in the simulator.
- **`ScanLifecycleTranscriptTests`** (WS-49.1): the five transcripts must be byte-identical after commits 2–6.
- **`iOSCleanupTests/PhotoScanCoordinatorTests.swift`** (*new*, `@MainActor`). Add a harness helper `makeIsolatedCoordinator(assets:analyzer:)`. It builds the collaborators exactly as the facade does, over WS-07's isolated dependencies, plus a `RecordingCoordinatorHost` (authorization `.authorized`, hydrated true, and it records `runDidEnd` and `scanDidReportError`).
  - `testDeepCleanCompletesAndPersistsCompletedAfterBarrier`: the final persisted state is `.completed`; `runDidEnd == [.completed]`; the engine factory was called once.
  - `testPauseThenResumeKeepsRunLockUntilDurable`: after resume, `isPhotoRunActive` is true until the snapshot on disk is complete (WS-28 STATE-03, now at coordinator level).
  - `testBackgroundRoundTripPausesWithExactCheckpointAndResumes`: the checkpoint's processed count equals the engine ack's committed count (WS-28.3), and the run resumes on `.active`.
  - `testSupersededRunCannotPublish`: run A is gated. In a `Task`, call `coordinator.stopActiveRunsWithoutCheckpoint()` (WS-20's fence, now a coordinator method), release A, then start run B with `startDeepClean()`. A's updates change nothing; `runDidEnd` contains `.superseded` for A.
  - `testUserPauseIsStickyAcrossCoordinatorRecreation`: pause, then build a second coordinator over the same defaults. It is `.paused` with `pauseReason == .user` and does not auto-resume (invariant 19).
  - `testPhotoAndVideoScansNeverOverlap`: the video engine factory's stub asset provider records whether the photo engine is inside `fetchImageAssets` or analysis. Assert there is never an overlap across a user-initiated videos-first scan.
- **The existing suite**, including WS-08, WS-26, WS-27 and WS-28's `HomeViewModelTests`, passes unmodified through the facade.

### Acceptance criteria
- [ ] Six commits, each warning-free with the full suite green. The transcript literals never change after commit 1.
- [ ] `git diff main --stat -- iOSCleanup/Views` lists only `HomeViewModel.swift` and new files in `Views/Home/`. No view file changes.
- [ ] `grep -n "activeScanID\|makePhotoScanEngine\|func apply(update" iOSCleanup/Views/HomeViewModel.swift` returns nothing.
- [ ] `HomeViewModel.swift` is ≤ 800 lines (target ~700), and `PhotoScanCoordinatorHost` has ≤ 12 requirements.
- [ ] `PhotoScanCoordinatorTests` pass. WS-07's `scripts/sim-fixtures.sh` still reaches groups, Keep Best and Duck Mode (attach the screenshots).
- [ ] `CLAUDE.md` is updated.

### Device QA
- Re-run the existing `docs/DEVICE_QA.md` sections for WS-28 (pause/background/relaunch) and WS-29 (lock screen, continuation) on this build. Record "unchanged vs baseline" in the file.

### Pitfalls and out of scope
- **Invariant 13** is the whole point: fencing on every hop, the run lock held from start until the completion snapshot is durable (including after resume), the durable-state mapping, and the completion barrier published last. Moving code between types must not add or remove a suspension point between a fencing check and the writes it guards.
- Do not "clean up" same-actor `MainActor.run` hops. They carry the fencing.
- Invariant 28: the view API stays identical. Forwarding is the only facade change.
- **Reconciliation:** WS-26 deleted `restartPhotoScan`. The moved entry points are `startPhotoScan(from:)`, the internal `refreshPhotoScan(requestsBackgroundContinuation:)` and the private `rescanEntireLibrary()` (README §9 contract 1). The member map uses the final chapter 05/06 names: `ScanPauseGate`/`ScanPauseReason`, the engine's `drainPoint()`, `inFlightAnalysisCount` and `isInAnalysisLoop`, `pause(reason:quiesceTimeout:) -> PhotoScanPauseAck`, `LargeVideoScanController.run(budget:)`, `passGeneration`/`invalidateAndCancelCurrentPass()`, `runPostRunFollowUpIfNeeded()`, `BackgroundTaskLease` and `IdleTimerCoordinator.shared`. WS-26–WS-29 kept their new logic in small policy files so this move stays mechanical. The supersession tests fence run A through WS-20's `stopActiveRunsWithoutCheckpoint()`, because after WS-26/WS-28 no user entry point can supersede a running or paused run. WS-29's continuation protocol is `ScanBackgroundContinuing`. The collaborators also carry WS-30's `ReclaimMeasurementController`, and the member map covers WS-20, WS-30, WS-37 and WS-48 lifecycle code, since all of them land before this workstream.
- **Out of scope:**
  - Progress throttling and `ScanProgressStore`: WS-50. If WS-49 lands first, WS-50 edits the coordinator.
  - Delta updates: WS-53.
  - Checkpoint cadence: WS-54.

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| STATE-12 | confirmed | Every cited fact holds at baseline: 2,640 lines; `.shared` singletons at `:288-290`; inline `PhotoScanEngine()` at `:1151` and `FileScanEngine()` at `:1405`; `@StateObject` in `ContentView.swift:5`; HomeView observes the model (`HomeView.swift:67`) and reacts to `activeScanRunIsComplete` (`:213`). Phases 0–8 and the dead-member deletion belong to WS-07/15/16/18/31, and the `ScanProgressModel` idea is WS-50's `ScanProgressStore`. This workstream is phase 9 only. The plan adds a lifecycle transcript golden (the counterpart of WS-16's builder golden) and a narrow host protocol, instead of moving code and relying on the existing tests alone. |

---

## WS-50 — Render isolation: progress store, 4 Hz throttle, derived-state memos

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M3 | L | WS-16, WS-41, WS-45 | no | `ws/50-render-isolation` |

**Primary files:**
- **New:** `iOSCleanup/Views/Home/ScanProgressStore.swift`, `iOSCleanup/Views/Home/ProgressPublicationThrottle.swift`, `iOSCleanup/Views/Home/ScanProgressLeaves.swift`, `iOSCleanup/Views/Files/FilesTabRoot.swift`, `iOSCleanup/Views/Components/LazyDestination.swift`, `iOSCleanup/Views/Photos/PhotoResultsPresentation.swift`, `iOSCleanup/Views/Export/ExportAlbumDerivedState.swift`.
- **Edited views:** the apply site (`HomeViewModel.swift` or `PhotoScanCoordinator.swift`), `iOSCleanup/Views/Home/HomeViewModelDependencies.swift`, `iOSCleanup/Views/Home/LargeVideoScanController.swift`, `iOSCleanup/Views/Home/PhotoResultsStore.swift`, `iOSCleanup/Views/PhotoDuckShellView.swift`, `iOSCleanup/Views/HomeView.swift`, `iOSCleanup/ContentView.swift`.
- **Edited Files, components and engine:** `iOSCleanup/Views/Files/FileResultsView.swift` and `FileResultsView+Banners.swift` (WS-10), `iOSCleanup/Views/Components/DuckComponents.swift`, `iOSCleanup/Views/Photos/PhotoResultsView.swift`, `iOSCleanup/Views/Export/ExportAlbumView.swift`, `iOSCleanup/Engines/FileScanEngine.swift`.
- **Tests:** `iOSCleanupTests/ProgressPublicationThrottleTests.swift` (*new*), `iOSCleanupTests/ProgressIsolationLintTests.swift` (*new*), `iOSCleanupTests/PhotoResultsPresentationTests.swift` (*new*), `iOSCleanupTests/ExportAlbumDerivedStateTests.swift` (*new*), `iOSCleanupTests/PhotoResultsStoreTests.swift`, `iOSCleanupTests/LargeVideoScanControllerTests.swift`, `iOSCleanupTests/FileScanEngineTests.swift`, `iOSCleanupTests/HomeViewModelTests.swift`, `iOSCleanupTests/ScalePerformanceTests.swift`.
- **Project and docs:** `iOSCleanup.xcodeproj/project.pbxproj`, `CLAUDE.md`.

**Findings covered:** PERF-03 (P2, confirmed; merged: FSB-03), PERF-11 (P2, confirmed)
**Decisions applied:**
- **D-SCAN-RESOURCES:** progress publications are capped at 4 Hz (0.25 s) and forced on state, group-set, pause, completion and failure changes.
- **D-HVM-DECOMP:** the progress store is an additive observation handle on the facade. The existing view API keeps its names.

### Goal
- A progress tick re-renders only small leaf views, at most four times a second.
- `PhotoDuckShellView`, the Files tab and the Similar dashboard do not re-evaluate on progress-only ticks.
- The video pass never waits on the UI.
- `PhotoResultsView` computes its derived collections once per input change (under 2 ms of body time at 5,000 groups).
- `ExportAlbumView` builds its sets once per body.
- No visual change.

### Current behavior (verified)
- **Progress publication.** `HomeViewModel.swift:254` has `@Published private(set) var progressSnapshot`. `publishProgressSnapshot()` (`:386-403`) publishes whenever the value differs, and `apply(update:)` calls it on every update (`:1760`), so every 8-photo batch fires `objectWillChange` on the whole facade.
- **Per-tick plain properties.** The properties at `:243-253` (`processedPhotoCount`, `analyzedPhotoCount`, `unanalyzedPhotoCount`, `progressFraction`, `scanRatePhotosPerMinute`, `scanActivityMessage`, `groupsFoundCount`, `reviewablePhotosCount`, `reclaimableBytesFoundSoFar`) are **not** `@Published`. Views read them, and they refresh only because `progressSnapshot` fires:
  - `HomeView.swift:104, 333, 362-377, 380, 443, 534, 582, 591, 710, 719, 810, 820, 902-919`.
  - `PhotoDuckShellView.swift:62, 120-163, 332, 389`.
  - The facade computed labels `scanProgressLabel`, `scanRateLabel`, `progressPercentLabel` and `findingsSoFarLabel`, which WS-31 moves into `HomeDashboardPresentation`, are derived from them.
- **The shell observes everything.** `PhotoDuckShellView.swift:27` has `@ObservedObject var dashboardModel`. Its body builds `FileResultsView(files:scanState:scanProgress:onRefresh:onAssetDeleted:)` with two fresh closures (`:59-71`), and `SimilarPhotosDashboardView` also observes the model (`:100`).
- **Eager Files destination.** `HomeView.swift:701-731` builds `FileResultsView(…)` eagerly as the Large Videos tile destination on every Home body. `FileResultsView`'s `@State` initial values (`FileResultsView.swift:249-266`: `LargeVideoReviewSectionMemo()`, `ExternalPhotoExportProgressStore()`, `ExportLiveActivityController()`) are evaluated on every init.
- **The video engine waits on the UI.** `FileScanEngine.swift:212-242` `await`s `onUpdate` per batch. WS-24 keeps it awaited, with progress every 8 videos and results every 32.
- **Video updates hit the whole summary.** `HomeViewModel.swift:1482-1488` sets `fileScanProgress` on every update. The `largeFiles` `didSet` (`:217-219`) rebuilds the whole summary (`:371-384`); after WS-16 that is `PhotoResultsStore.setLargeFiles`, which rebuilds the full photo summary.
- **Brand images.** `DuckComponents.swift:15-23`: `PhotoDuckAssetImage.body` calls `UIImage(named:)` for each name on every evaluation.
- **Results screen recomputation.** `PhotoResultsView.swift:29-35`: `visibleGroups` filters all groups and builds a `Set` and a `Dictionary`. One body evaluates it about 14 times (empty checks, the hero card, four `count(for:)` pills at `:327-334`, three metric values, and `groupList`'s index dictionary at `:362-367`). `.onChange(of: groups.map(\.id))` (`:162`) allocates an ID array per body.
- **Export Album.** `ExportAlbumView` (baseline `HomeView.swift:1397-1428`, and `Views/Export/ExportAlbumView.swift` after WS-10): `unavailableAssetIDs`, `albumAssets`, `availableAssetIDs`, `selectedAssets`, `selectedBytes` and `allAvailableAssetsAreSelected` each rebuild a `Set` or filter on every access.
- **Already delivered.** `PhotoCategoryReviewView`'s per-tap `Set` work (baseline `HomeView.swift:1105-1117`) was replaced by WS-41's `CategorySelectionModel`, which keeps a running byte total. Verify only.
- **Pattern to copy.** `ExternalPhotoExportProgressEmitter` (`ExternalPhotoExportService.swift:1365-1410`) already caps export UI updates at 0.25 s.

### Implementation plan

**WS-50.1 — `ProgressPublicationThrottle` and a trailing-edge publisher**
- **Why:** a pure gate is testable, and a trailing publication guarantees that the last tick before a lull (for example a slow iCloud asset) is never lost.
- **Change:** new `iOSCleanup/Views/Home/ProgressPublicationThrottle.swift`:
  ```swift
  /// D-SCAN-RESOURCES: at most one non-forced publication per 0.25 s. Times are monotonic seconds.
  struct ProgressPublicationThrottle: Equatable {
      static let minimumInterval: TimeInterval = 0.25
      private(set) var lastPublishedAt: TimeInterval?
      enum Decision: Equatable { case publishNow, publishAt(TimeInterval) }
      mutating func decide(now: TimeInterval, force: Bool) -> Decision {
          if force || lastPublishedAt.map({ now - $0 >= Self.minimumInterval }) ?? true {
              lastPublishedAt = now; return .publishNow
          }
          return .publishAt(lastPublishedAt! + Self.minimumInterval)
      }
      mutating func didPublish(at now: TimeInterval) { lastPublishedAt = now }
  }

  @MainActor
  final class ThrottledPublisher<Value: Equatable> {
      typealias Clock = @Sendable () -> TimeInterval
      typealias Sleep = @Sendable (TimeInterval) async -> Void      // returns early when cancelled
      init(now: @escaping Clock, sleep: @escaping Sleep, publish: @escaping (Value) -> Void)
      /// publishNow → cancels any trailing task and publishes. publishAt → keeps `value` as the latest and makes
      /// sure exactly one trailing task exists; after `sleep(deadline - now())` it publishes the latest value.
      func submit(_ value: Value, force: Bool)
      func cancel()
  }
  ```
- **Change:** add these fields to `HomeViewModelDependencies` (WS-07):
  - `var progressClock: @Sendable () -> TimeInterval`, `.live` = `{ ProcessInfo.processInfo.systemUptime }`;
  - `var progressSleep: @Sendable (TimeInterval) async -> Void`, `.live` = `{ try? await Task.sleep(nanoseconds: UInt64(max($0, 0) * 1_000_000_000)) }`.

  Update WS-07's test harness to inject a `ManualProgressClock` and a gate-based sleep.
- **Edge cases:** a forced publication cancels a pending trailing task, so the store never goes backwards to an older value.

**WS-50.2 — `ScanProgressStore` and `VideoScanProgressStore`**
- **Why:** per-tick values must be observable separately from the facade (FSB-03 item 1). Photo and video progress are separate objects, so the Files tab never observes photo ticks.
- **Change:** new `iOSCleanup/Views/Home/ScanProgressStore.swift`:
  ```swift
  @MainActor final class ScanProgressStore: ObservableObject {
      @Published private(set) var snapshot = ScanProgressSnapshot.empty
      func publish(_ next: ScanProgressSnapshot) { if next != snapshot { snapshot = next } }
  }
  @MainActor final class VideoScanProgressStore: ObservableObject {
      @Published private(set) var progress = FileScanProgress.idle
      func publish(_ next: FileScanProgress) { if next != progress { progress = next } }
  }
  ```
- **Change at the apply site:**
  - Add `let progressStore = ScanProgressStore()`, created by the facade. If WS-49 landed, it is passed into the coordinator.
  - Add a `ThrottledPublisher<ScanProgressSnapshot>` that publishes into the store.
  - `publishProgressSnapshot(force: Bool = false)` builds the snapshot exactly as today and calls `submit(next, force:)`.
  - Delete `@Published` from `progressSnapshot`. It becomes a get-only `var progressSnapshot: ScanProgressSnapshot { progressStore.snapshot }` on the facade. Internal code keeps reading the plain fields, never the store.
  - **Forced publications:** every call site outside `apply` is a state transition (scan start and prepare, pause, resume, cancel, failure, restore, reconcile), so all of them pass `force: true`. Inside `apply`, force when any of these holds:
    - the photo-group set was actually reassigned (a signature change, not merely a flag);
    - `scanState` changed;
    - `isPaused` changed;
    - `update.isComplete` is true.
  - Per-update work that is **not** throttled stays per update: counters, `CommittedProgressWaiter.didApply` (WS-28), diagnostics buckets (WS-15), and the persistence and checkpoint cadence.
- **Change in `LargeVideoScanController`** (WS-16/27):
  - Add `let progressStore = VideoScanProgressStore()` and its own `ThrottledPublisher<FileScanProgress>` (clock and sleep injectable through the controller's init, defaulting to live).
  - `fileScanProgress` becomes `private(set) var`, not `@Published`. It is still set on every update for internal readers.
  - Publish with `force: true` on scan start, completion, `isComplete`, cancel, failure and permission errors. WS-42's `retainedVideos` (and the derived `largeFiles`, `screenRecordings` and `videoInventory`) stay published only on engine result batches (already the case).
  - The facade exposes `var videoProgressStore: VideoScanProgressStore { largeVideoController.progressStore }`, and `fileScanProgress` stays a get-only pass-through for non-view readers.

**WS-50.3 — Leaf views read per-tick values; everything else stops**
- **Why:** once the facade stops publishing per tick, any view that still reads a per-tick value directly goes stale (FSB-03 item 2).
- **Change:** new `iOSCleanup/Views/Home/ScanProgressLeaves.swift` holds small structs. Each has `@ObservedObject var viewModel: HomeViewModel` **and** `@ObservedObject var progress: ScanProgressStore`; a leaf must observe both, or it goes stale on model changes because SwiftUI can skip a child whose stored references are unchanged. Every expression that reads a per-tick value moves into one of them:
  - the Home hero metric and detail, and the CTA title/subtitle (everything read from `viewModel.dashboardPresentation`, WS-31);
  - the scan footer (baseline `HomeView.swift:806-831`);
  - the stats row (`:582`, `:591`);
  - the unanalyzed banner (`:104`, `:534`);
  - the Similar dashboard status block (`PhotoDuckShellView.swift:117-163`, `:332`, `:389`).

  `HomeViewModel.dashboardPresentation` (WS-31) reads `progressStore.snapshot` values through the facade's plain fields, so evaluating it inside a leaf is correct. Leaves reuse the exact existing subviews and tokens (no visual change).

  The hero/CTA leaf also takes `@ObservedObject var videoProgress: VideoScanProgressStore`. WS-27's video pre-pass and post-photo pass copy ("Checking large videos… x/y", `videoPassProgressLabel`, which WS-31/WS-45 carry into the presentation) reads `fileScanProgress`, which stops publishing on the facade in WS-50.2.
- **Change:** in WS-45's `tile(for spec:)`, which is keyed by `CleanupOpportunity.Kind`, the per-tick note of the `.largeVideos` and `.screenRecordings` tiles (baseline `HomeView.swift:704-712`) moves into a leaf that observes `videoProgressStore`. Tile bytes and badges stay on `HomeTileSpec.sizing` and `HomeTileLayout.reclaimableTotal`, which returns a `ReclaimSizing`. They are not per-tick. In `FileResultsView+Banners.swift` (WS-10), the scanning banner becomes `LargeVideoScanBanner: View { @ObservedObject var progress: VideoScanProgressStore; let scanState: HomeViewModel.ScanState; … }`. `FileResultsView` takes `progress: VideoScanProgressStore` instead of `scanProgress: FileScanProgress`, and reads it only in leaves. There are two baseline reads: `FileResultsView.swift:778` (the banner) and `:546` (inside the review section). Move the second into a small leaf declared in `FileResultsView+Banners.swift` too, so the lint allow-list stays at one Files file.
- **Change:** new `iOSCleanupTests/ProgressIsolationLintTests.swift` (DesignLintTests-style `#filePath` walk over `iOSCleanup/Views/`). It fails if any of these tokens appears outside the allow-list:
  - **Tokens:** `.processedPhotoCount`, `.analyzedPhotoCount`, `.unanalyzedPhotoCount`, `.progressFraction`, `.scanActivityMessage`, `.reviewablePhotosCount`, `.groupsFoundCount`, `.reclaimableBytesFoundSoFar`, `.scanRatePhotosPerMinute`, `.scanProgressLabel`, `.scanRateLabel`, `.progressPercentLabel`, `.findingsSoFarLabel`, `.progressSnapshot`, `.fileScanProgress`, `.videoPassProgressLabel` (WS-27), `.dashboardPresentation`.
  - **Allow-list:** `ScanProgressLeaves.swift`, `FileResultsView+Banners.swift`, `HomeViewModel.swift`, `PhotoScanCoordinator.swift`, `HomeDashboardPresentation.swift`, `ScanOutcomeSummary.swift`, `LargeVideoScanController.swift`, `ScanProgressStore.swift`.

  Before finalizing, grep the facade and `HomeDashboardPresentation` for every other computed property derived from these fields, and add those names to the token list.

**WS-50.4 — Unobserved shell, Files tab root and lazy destinations**
- **Why:** FSB-03 item 3 and PERF-03 items 3–4. The shell should re-evaluate only when its own inputs change.
- **Change:**
  - **`PhotoDuckShellView`:** `@ObservedObject var dashboardModel` becomes `let dashboardModel: HomeViewModel`. The Home tab keeps `HomeView(viewModel: dashboardModel, …)` (HomeView observes on its own) and the Similar tab keeps `SimilarPhotosDashboardView(viewModel:)`.
  - **Files tab:** new `iOSCleanup/Views/Files/FilesTabRoot.swift`:
    ```swift
    struct LargeVideoActions: Equatable {              // stable identity: equal while the model is the same
        private let id: ObjectIdentifier
        private weak var model: HomeViewModel?
        init(model: HomeViewModel) { id = ObjectIdentifier(model); self.model = model }
        @MainActor func refresh() async { await model?.scanFiles(trigger: .userExplicit) }                  // WS-27.5
        @MainActor func assetsDeleted(_ ids: Set<String>) { model?.removeLargeFilesFromResults(assetIDs: ids) } // WS-42.4
        @MainActor func setMinimumBytes(_ bytes: Int64) { model?.largeVideoMinimumBytes = bytes }           // WS-42.4
        static func == (l: Self, r: Self) -> Bool { l.id == r.id }
    }
    struct FilesTabRoot: View {
        @ObservedObject var videos: LargeVideoScanController   // video state only, never photo ticks
        let progress: VideoScanProgressStore
        let actions: LargeVideoActions
        var body: some View { FileResultsView(/* today's inputs, read from `videos` */, progress: progress, actions: actions) }
    }
    ```
    `FileResultsView` replaces its closures (`onRefresh`, and WS-42's `onAssetsDeleted` and `onMinimumBytesChange`) with `actions: LargeVideoActions`. Keep every other WS-27/WS-42 input it has (`files` fed from `retainedVideos`, `minimumBytes`, `inventory`, `initialKindFilter`), all read from the controller. `LargeVideoActions` is distinct from WS-10's per-row `LargeVideoRowActions`. The facade exposes `var largeVideoStore: LargeVideoScanController { largeVideoController }` as a read-only observation handle.
  - **`ContentView`:** if its body reads no `@Published` property of `dashboardModel` (check), change `@ObservedObject var dashboardModel` (WS-07) to `let dashboardModel`.
  - **Lazy destinations:** new `iOSCleanup/Views/Components/LazyDestination.swift`: `struct LazyDestination<Content: View>: View { let build: () -> Content; var body: some View { build() } }`. Wrap every eager `HomeCategoryTile` destination (Large Videos, Export Album, category review) in it. If WS-31/WS-45 already moved Home navigation to `HomeRoute` values with `.navigationDestination`, no change is needed; record which case applied.
- **Edge cases:**
  - `FilesTabRoot` still runs the tab's `onChange(of: selectedTab)` video pass trigger through the shell (unchanged).
  - `@EnvironmentObject`s stay injected exactly as today.

**WS-50.5 — The video pass never waits on the UI**
- **Why:** each awaited `onUpdate` forces the engine to wait for a main-actor render (PERF-03).
- **Change** in `FileScanEngine.swift`:
  - `onUpdate` becomes a synchronous sink: `typealias FileScanUpdateSink = @Sendable (FileScanUpdate) -> Void`. Update WS-42's `scan(remeasureEstimates:onUpdate:)`, which returns `FileScanResult`; `FileScanOptions` no longer exists after WS-42. Call it without `await` at WS-24's publication points (every 8 progress, 32 results).
  - Add:
    ```swift
    extension FileScanUpdate {
        /// Newest progress wins; a dropped result list (and its inventory) survives a later progress-only update.
        func merging(droppedPredecessor old: FileScanUpdate) -> FileScanUpdate {
            FileScanUpdate(progress: progress, retainedVideos: retainedVideos ?? old.retainedVideos,   // WS-42 names
                           inventory: inventory ?? old.inventory)
        }
    }
    enum FileScanUpdateChannel {
        static func make() -> (stream: AsyncStream<FileScanUpdate>, sink: FileScanUpdateSink, finish: @Sendable () -> Void) {
            let (stream, continuation) = AsyncStream.makeStream(of: FileScanUpdate.self, bufferingPolicy: .bufferingNewest(1))
            let sink: FileScanUpdateSink = { update in
                if case .dropped(let old) = continuation.yield(update) {
                    _ = continuation.yield(update.merging(droppedPredecessor: old))   // replaces `update`, keeps old's files
                }
            }
            return (stream, sink, { continuation.finish() })
        }
    }
    ```
  - `LargeVideoScanController.run(budget:)` (WS-27's replacement for WS-16's `runScan(force:)`):
    1. Create a channel and start a consumer `Task { @MainActor in for await u in stream { publishFileScanUpdate(u) } }`. The consumer applies WS-27's generation fence: `publishFileScanUpdate` drops the update unless the pass's captured `generation == passGeneration`.
    2. Call `engine.scan(remeasureEstimates: …, onUpdate: sink)` (WS-42's signature; the controller passes `true` only for the user-initiated refresh).
    3. On **every** exit path, call `finish()` and `await consumer.value` **before** the final assignment of `retainedVideos`/`fileScanState` (from the returned `FileScanResult`), so a stale buffered update can never overwrite the completed state.
- **Edge cases:**
  - WS-27's `LargeVideoResultCache` single-flight, revision and serialized-write guarantees are untouched.
  - WS-27's `passGeneration` fence (README §9 contract 24) still guards every cache write and every published assignment, including those made by the consumer. `invalidateAndCancelCurrentPass()` (WS-48's Clear) cancels the pass, and the exit path's `finish()` plus `await consumer.value` then drain the channel without publishing anything.
  - WS-27's `run(budget:)` pre-pass budget race is unchanged. A budget expiry is an exit path too, so it also runs `finish()` and `await consumer.value`.
  - The publication stride is unchanged.
  - Cancellation still propagates through the scan `Task`.

**WS-50.6 — Split the collection summary**
- **Change** in `PhotoResultsStore` (WS-16):
  - Split `DashboardCollectionSummary.make` into `PhotoCollectionSummary.make(groups:screenshotAssets:blurryAssets:)`, covering every field WS-30 and WS-42 derive from photos, plus `largeFileBytes`. Keep the video-derived fields next to it.
  - Store `private(set) var photoSummary` and `private(set) var largeFileBytes: Int64`, and make `summary` a computed combination, so the facade's `dashboardSummary` API is unchanged.
  - `setLargeFiles(_:)` updates only `largeFileBytes` (O(files)).
  - Keep `DashboardCollectionSummary.make(groups:screenshotAssets:blurryAssets:largeFiles:)` as a convenience for existing tests.
  - The DEBUG `summaryRebuildCount` now counts photo-summary rebuilds.

**WS-50.7 — `PhotoDuckAssetImage` resolves availability once**
- **Change** in `DuckComponents.swift`:
  ```swift
  @MainActor enum BrandAssetAvailability {
      private static var cache: [String: Bool] = [:]
      static func firstAvailable(in names: [String]) -> String? {
          names.first { name in
              if let known = cache[name] { return known }
              let exists = UIImage(named: name) != nil; cache[name] = exists; return exists
          }
      }
  }
  ```
  `PhotoDuckAssetImage.body` uses `BrandAssetAvailability.firstAvailable(in: assetNames)`. The rendering is unchanged.

**WS-50.8 — `PhotoResultsPresentation` and its memo (PERF-11)**
- **Change:** new `iOSCleanup/Views/Photos/PhotoResultsPresentation.swift`. Move `FilterPill` out of the view as `enum PhotoResultsFilterPill`, and keep `typealias FilterPill = PhotoResultsFilterPill` inside `PhotoResultsView` so the call sites don't change.
  ```swift
  struct PhotoResultsPresentation {
      let visible: [PhotoGroup]                 // PhotoResultsOrdering.visibleGroups(…) from WS-45: the ONLY ordering entry point
      let filtered: [PhotoGroup]
      let countByFilter: [PhotoResultsFilterPill: Int]
      let reclaimSizing: ReclaimSizing          // Σ group.reclaimSizing over `visible` (WS-30); .totalBytes == today's reclaimableBytes
      let totalPhotoCount: Int                  // over all groups (today's)
      let currentReviewCount: Int               // photos in `filtered`
      let currentDeletableCount: Int            // unique delete IDs in `filtered`
      let indexByID: [UUID: Int]                // position in `filtered` (today's groupList dictionary)
      let groupIDsSignature: Int                // ordered hash of all group IDs, for .onChange
      static func make(groups: [PhotoGroup], hiddenIDs: Set<UUID>, deferredIDs: [UUID],
                       filter: PhotoResultsFilterPill, sort: GroupSortOrder) -> PhotoResultsPresentation   // one O(G) pass after ordering
  }
  @MainActor final class PhotoResultsPresentationMemo {
      private(set) var recomputationCount = 0
      /// Key: groups.count, a Hasher over every field `make` reads per group (id, reason, assets.count,
      /// deleteCandidateIDs.count, keeperAssetID, WS-30's reclaimSizing (every field), isAutoCleanEligible,
      /// captureDateRange start), hiddenIDs, deferredIDs, filter, sort.
      func presentation(groups: [PhotoGroup], hiddenIDs: Set<UUID>, deferredIDs: [UUID],
                        filter: PhotoResultsFilterPill, sort: GroupSortOrder) -> PhotoResultsPresentation
  }
  ```
  - `PhotoResultsView` holds `@State private var presentationMemo = PhotoResultsPresentationMemo()`.
  - Its body starts with `let p = presentationMemo.presentation(…)`.
  - `heroCard`, `filterPills`, `metricRow`, `groupList` and the two empty-state checks become functions taking `p`.
  - `.onChange(of: groups.map(\.id))` becomes `.onChange(of: p.groupIDsSignature)`, and the closure computes `Set(groups.map(\.id))` only when it fires.
  - `autoCleanEligibleGroups` stays inside the button action.
- **Edge cases:**
  - Groups are pairwise disjoint (WS-23), so the unique-delete count equals the sum over groups. Still compute it with a `Set`, matching today's semantics exactly.
  - A group edited in place (WS-21 prune, WS-30 sizing) changes the content hash, so the memo never serves stale counts.

**WS-50.9 — `ExportAlbumDerivedState`**
- **Change:** new `iOSCleanup/Views/Export/ExportAlbumDerivedState.swift`:
  ```swift
  struct ExportAlbumDerivedState {
      let albumAssets: [PHAsset]            // PhotoAssetIdentity.unique(assets)
      let availableAssetIDs: Set<String>
      let unavailableAssetIDs: Set<String>  // Set(assetIDs) − available
      init(assetIDs: [String], assets: [PHAsset])
      func selectedAssets(_ selected: Set<String>) -> [PHAsset]   // ExportAlbumSelection.selectedAssets, unchanged
      func selectedBytes(_ selected: Set<String>) -> Int64
      func allSelected(_ selected: Set<String>) -> Bool
  }
  ```
  `ExportAlbumView.body` computes `let derived = ExportAlbumDerivedState(assetIDs: exportAlbum.assetIDs, assets: exportAlbum.assets)` once, then passes it and `derived.selectedBytes(selectedAssetIDs)` to the subviews and action handlers. Delete the six computed properties.

**WS-50.10 — Benchmark (4) and docs**
- **Change:**
  - Add benchmark (4) to `ScalePerformanceTests` (WS-08): `testResultsPresentationScales`, 1,250 → 5,000 groups (3 `TestPhotoAsset`s each, mixed reasons, 5% hidden, 5% deferred), with `ScaleBenchmark.growthRatio` < 6 and `measure` at 5,000 (advisory target < 5 ms in the simulator).
  - In `CLAUDE.md`: "Per-tick scan progress is published only through `ScanProgressStore`/`VideoScanProgressStore` at ≤ 4 Hz; views read per-tick values only in leaf views (lint-enforced)."

### Tests
All run in the simulator.
- **`ProgressPublicationThrottleTests`** (pure, plus the publisher with a manual clock and a gate-based sleep):
  - `testFirstSubmitPublishesImmediately`.
  - `testTwentyNonForcedSubmitsInOneSecondPublishAtMostFourPlusTrailing`: submits at t = 0, 0.05, …, 0.95. Publications happen at 0, 0.25, 0.5 and 0.75, plus one trailing publication carrying the t = 0.95 value when the sleep is released.
  - `testForcedSubmitAlwaysPublishesAndCancelsTrailing`.
  - `testTrailingPublicationCarriesNewestValue`.
- **`HomeViewModelTests`** (WS-07 harness with an injected frozen `progressClock` and gated `progressSleep`):
  - `testProgressOnlyUpdatesDoNotInvalidateFacade`. Setup: 64 assets with distinct embeddings (no groups) and an analyzer gated per 8-asset slice. After the first update is applied, count `objectWillChange` emissions on the facade and emissions of `progressStore.$snapshot`. Release 7 slices.
    - The facade delta is 0.
    - The store delta is 0, because the clock is frozen and the trailing publication is pending.
    - Advance the clock and release the sleep: exactly 1 publication, carrying the newest processed count.
    - Complete: a forced publication with `processedPhotoCount == 64`.
  - Update WS-08's `testProgressSnapshotNeverRegressesAcrossPauseAndResume` to sink on `progressStore.$snapshot`. It must still be monotonic and end at 24, because completion is forced.
- **`LargeVideoScanControllerTests`:**
  - `testVideoProgressIsThrottledAndCompletionForced` (manual clock).
  - `testFinalStateIsNotOverwrittenByBufferedUpdate`: the consumer is gated. The final `fileScanState == .completed`, and `retainedVideos` equals the returned `FileScanResult.retainedVideos`.
  - `testInvalidatedPassPublishesNothingThroughChannel`: gate the consumer, call `invalidateAndCancelCurrentPass()`, then release. No buffered update reaches `retainedVideos` or `fileScanProgress`. WS-27's `testInvalidatedPassNeverWritesResults` still passes.
- **`FileScanEngineTests`:**
  - `testSlowConsumerDoesNotBlockVideoScan`: 400 stub videos with an instant resolver. The consumer parks on a gate before handling its first element. `engine.scan` returns all retained videos while the gate is closed. After opening it, the consumer receives at most 2 elements, and the last has `isComplete == true`.
  - `testDroppedResultListSurvivesProgressOnlyUpdate`: `sink(A with retainedVideos and inventory)`, then `sink(B with nil)`, then finish. Iterating yields one element whose `retainedVideos` and `inventory` are A's.
- **`PhotoResultsStoreTests`:**
  - `testSetLargeFilesDoesNotRebuildPhotoSummary` (`summaryRebuildCount` unchanged; `summary.largeFileBytes` is updated).
  - `testCombinedSummaryEqualsLegacyMake` (the fixture used by WS-16's tests).
- **`PhotoResultsPresentationTests`:**
  - `testMatchesLegacyDerivationAcrossFiltersSortsHiddenAndDeferred`: copy today's `visibleGroups`/`filteredGroups`/`count(for:)`/`reclaimableBytes`/`currentReviewCount`/`currentDeletableCount` into the test as `LegacyResultsDerivation`, with ordering through `PhotoResultsOrdering`. Over 200 seeded fixtures (up to 300 groups, random hidden/deferred subsets), every field of `make` equals the legacy value for every filter and sort (`reclaimSizing.totalBytes` against the legacy `reclaimableBytes`, and `reclaimSizing` against the sum of the visible groups' WS-30 `reclaimSizing`). Deferred groups come last, in deferral order.
  - `testMemoRecomputesOnlyWhenKeyChanges`: the same inputs twice give `recomputationCount == 1`. Changing only one group's `reclaimSizing` (through WS-30's `replacingReclaimSizing`) recomputes.
  - `testGroupIDsSignatureChangesOnlyWithIDs`.
- **`ExportAlbumDerivedStateTests`:** unavailable = IDs − assets; duplicates removed; `selectedBytes` equals the sum of `estimatedFileSize`; `allSelected`.
- **`ProgressIsolationLintTests`:** `testPerTickValuesAreReadOnlyInLeaves`.
- **`ScalePerformanceTests`** (Performance plan): benchmark (4).

### Acceptance criteria
- [ ] `progressSnapshot` and `fileScanProgress` are no longer `@Published`. Progress reaches views only through `ScanProgressStore`/`VideoScanProgressStore`, at ≤ 4 Hz except for forced publications. The throttle and facade tests pass.
- [ ] `PhotoDuckShellView` has no `@ObservedObject`. `FileResultsView` takes `actions: LargeVideoActions`, with no closures. `ProgressIsolationLintTests` pass.
- [ ] `FileScanEngine` never awaits the UI (`testSlowConsumerDoesNotBlockVideoScan`), and the dropped-result merge test passes.
- [ ] `setLargeFiles` never rebuilds the photo summary.
- [ ] `PhotoResultsView` computes its derived state through `PhotoResultsPresentationMemo`; the legacy-equivalence test passes; benchmark (4) ratio < 6.
- [ ] `ExportAlbumView` has no per-access `Set` construction.
- [ ] No visual change: simulator screenshots of Home (idle, scanning, completed), Similar, Files and the results sheet match `main` (WS-07 fixture harness).
- [ ] Zero warnings, suite green, and `CLAUDE.md` updated.
- [ ] Instruments numbers are in the PR (see Device QA).

### Device QA
Add to `docs/DEVICE_QA.md` under "Rendering (WS-50)":
1. On a 10k+ library, profile a Deep Clean with the Instruments SwiftUI template (View Body) for 60 s while sitting on Home. HomeView bodies are ≤ 5 per second.
2. Switch to the Similar tab and back during the scan. `FileResultsView` and `SimilarPhotosDashboardView` bodies are 0 while another tab is selected and no groups changed. Record the counts.
3. Open "Review" with 3,000+ groups and tap Keep Best on a row. `PhotoResultsView` body time is < 2 ms (Instruments), with no visible hitch at 120 Hz.
4. Warm-cache Large Videos refresh on a 3,000+ video library: record the duration before and after this PR (target ≥ 30% faster).

### Pitfalls and out of scope
- **Stale labels are the main risk.** Every per-tick read must be in a leaf that observes both the model and the store. The lint enforces the token list; audit it for derived properties.
- Do not throttle internal bookkeeping (committed-progress waiter, diagnostics, persistence). Only the publication to views is throttled.
- Invariant 29: no visual change to Files or Duck Mode. Leaves reuse the existing views.
- Invariant 28: the progress stores and `largeVideoStore` are additive, read-only observation handles. No existing facade property changes name or type.
- **Reconciliation:**
  - `FileResultsView`'s init change (`actions: LargeVideoActions`, `progress: VideoScanProgressStore`) is accepted under invariant 28 (README §9 contract 27): the invariant is about behavior, and additive observation handles are allowed.
  - Names follow WS-42 and WS-27: `scan(remeasureEstimates:onUpdate:)` (no `FileScanOptions`), `retainedVideos`, `FileScanResult`, `onAssetsDeleted`/`removeLargeFilesFromResults(assetIDs:)`, `largeVideoMinimumBytes`, `scanFiles(trigger: .userExplicit)` and `LargeVideoScanController.run(budget:)`. The channel consumer keeps WS-27's `passGeneration` fence (contract 24).
  - WS-08's `testProgressSnapshotNeverRegressesAcrossPauseAndResume` moves to `progressStore.$snapshot` (README §9 contract 15).
  - The memoized presentation is `PhotoResultsPresentation`/`PhotoResultsPresentationMemo`. WS-55 and WS-56 (chapter 12) resolve groups and hero counts from it. Its byte total is a `ReclaimSizing` (WS-30), matching WS-45's `HomeTileLayout.reclaimableTotal`, which returns `ReclaimSizing`. Home tiles are keyed by `CleanupOpportunity.Kind`, including `.screenRecordings` (README §9 contract 10).
- **Out of scope:**
  - `PhotoCategoryReviewView` selection: WS-41, already done.
  - Navigation stability of open group details: WS-55 (chapter 12).
  - Thumbnail pipeline: WS-52.
  - Engine-side delta updates: WS-53.

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| PERF-03 | confirmed | The mechanism is verified: the per-batch `@Published` snapshot (`:254`, `:386-403`, `:1760`), the observed shell with fresh closures (`PhotoDuckShellView.swift:27`, `:59-71`), the eager `FileResultsView` destination (`HomeView.swift:701-731`), the awaited `onUpdate` (`FileScanEngine.swift:212-242`), the summary rebuild on `largeFiles` (`:217-219`, `:371-384`), and `UIImage(named:)` per body (`DuckComponents.swift:15-23`). The millisecond costs and the "30% faster" figure are estimates, measured in Device QA. Differences from the proposed fix: two progress stores, so Files never observes photo ticks; `FilesTabRoot` observes `LargeVideoScanController` (read-only), not the facade; a trailing-edge publication, so the last throttled tick is never lost; a caller-owned `bufferingNewest(1)` stream with drop-merge of result lists, so a dropped list can't hide behind a progress-only update; lazy destinations. |
| FSB-03 (merged) | confirmed | The same fan-out. Items 1–4 are implemented here (store, leaves, unobserved shell, throttle). Item 5 is delivered as PERF-11's `PhotoResultsPresentation`. Its HomeViewModel-level test is adopted with an injected clock instead of wall time. |
| PERF-11 | confirmed | About 14 `visibleGroups` evaluations per body (`PhotoResultsView.swift:29-80`, `:303-367`) and the `groups.map(\.id)` onChange (`:162`) are verified, as are the six `ExportAlbumView` derived sets (`HomeView.swift:1397-1428`). Item 2 (`PhotoCategoryReviewView`) is already delivered by WS-41's `CategorySelectionModel`. The presentation must use WS-45's `PhotoResultsOrdering` and include the sort in the key. The memo is keyed by a hash over every field `make` reads, not only IDs, so in-place group edits cannot serve stale counts. |

---

## WS-51 — Review image memory and Duck Mode prefetch

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M3 | M | WS-04, WS-12, WS-14 | no | `ws/51-review-image-memory` |

**Primary files:**
- **New code:** `iOSCleanup/Utilities/ReviewImageSizePolicy.swift`, `iOSCleanup/Views/Components/ReviewImageLayers.swift`, `iOSCleanup/Views/Photos/DuckModeImageCache.swift`.
- **Edited code:** `iOSCleanup/Utilities/SharedHelpers.swift` (`PhotoImageRepository` cache policy only), `iOSCleanup/Views/Components/PhotoThumbnailView.swift` (WS-14), `iOSCleanup/Views/Photos/PhotoGroupDetailView.swift`, `iOSCleanup/Views/Photos/FullscreenGroupCompareView.swift` (WS-12/14 home of `ZoomablePhotoCanvas`), `iOSCleanup/Views/Photos/SwipeModeView.swift`, `iOSCleanup/Views/Photos/SwipeModeViewModel.swift`, `iOSCleanup/Utilities/PhotoDuckSignposts.swift` (WS-09).
- **Tests:** `iOSCleanupTests/ReviewImageSizePolicyTests.swift` (*new*), `iOSCleanupTests/DuckModeImageCacheTests.swift` (*new*), `iOSCleanupTests/SwipeModeViewModelTests.swift`, `iOSCleanupTests/ThumbnailLintTests.swift` (WS-14), and the repository tests (`iOSCleanupTests/FileScanEngineTests.swift`, or wherever WS-03 moved them).
- **Project and docs:** `iOSCleanup.xcodeproj/project.pbxproj`, `CLAUDE.md`.

**Findings covered:** PERF-08 (P2, confirmed; merged: FSB-02), PERF-10 (P2, confirmed)
**Decisions applied:**
- None of the logged decisions applies directly. The WS-14 DECISION stands: Duck Mode's Delete is enabled only when the card's full-quality image is `.loaded`. The local preview added here never enables Delete.
- **New DECISION (owner may override):** Duck Mode prefetch uses the same network flag as the card (`true`). Up to three upcoming iCloud-only photos may therefore download before the user reaches them. The override is to prefetch only locally available photos, which makes those cards non-instant.

### Goal
- Group detail and Compare never decode full originals.
- Review and fullscreen images never evict grid thumbnails.
- Cells release their bitmaps when they scroll away.
- Opening a group on an optimized library downloads nothing until the user asks.
- The next Duck Mode card is usually already painted when the swipe ends, and a local preview always paints first.
- No display path references `PHImageManagerMaximumSize`.

### Current behavior (verified)
- **Compare decodes the original.** `PhotoGroupDetailView.swift:552-603` (`ZoomablePhotoCanvas`) requests `targetSize: PHImageManagerMaximumSize` (`:594`) with `.fullscreen` and network on. `PhotoImageRequestKey.normalizedDimension` maps it to `-1` (`SharedHelpers.swift:241-248`).
  - `FullscreenGroupCompareView` recreates the canvas per thumbnail tap (`.id(selectedAsset.localIdentifier)`, `:507`).
  - WS-12/14 moved these types to `FullscreenGroupCompareView.swift`, and WS-14 gave the canvas a `ThumbnailPhase` with an unavailable state and Retry, keeping the request.
- **The repository caches review and fullscreen.** `PhotoImageRepository.store` (`SharedHelpers.swift:442-461`) caches anything up to the full 96 MB budget. After WS-14, `isCacheable` is false only for analysis intents, so `.review` and `.fullscreen` still enter the LRU.
- **Oversized group-detail cells.** `PhotoGroupAssetCell` (`PhotoGroupDetailView.swift:348-480`) requests `.review` with network on at `displayTargetSize` = width clamped to 1,200–2,048 px (`:465-473`), so a 3:4 photo gives 1200×1600 (≈7.7 MB). The cells live in a `LazyVStack` (`:56-60`) whose rows keep their `@State` image after scrolling away. After WS-14 the cell is a `PhotoThumbnailView(.pixels(displayTargetSize(for:)), .aspectFit, .review, network true, retry)`.
- **Duck Mode renders only the current card.** `SwipeModeView.swift:94-151` renders one `DuckAssetCard` for `viewModel.current`. The card requests `geo.size × displayScale`, `.aspectFill`, `.review`, network on (`:430-490`), after the 250 ms transition (`SwipeModeViewModel.swift:81-100`). Nothing prefetches. WS-04 added `.id(asset.localIdentifier)`. WS-14 moved the card to `PhotoThumbnailView(.pixels(targetSize), .review, true, retry, onPhaseChange)` and gated Delete on `.loaded`.
- **The queue.** `SwipeModeViewModel.swift:10-20`: `QueueEntry.asset(PHAsset, groupID:)` / `.monthHeader`; WS-41 makes `groupID` optional. `queue` and `currentIndex` are `@Published`.
- **Existing test to change.** `testImageRepositorySeparatesThumbnailAndReviewQuality` (`FileScanEngineTests.swift:635-649`) asserts that the `.review` result is cached (`cachedCount == 2`).

### Implementation plan

**WS-51.1 — `ReviewImageSizePolicy` and the maximum-size lint**
- **Change:** new `iOSCleanup/Utilities/ReviewImageSizePolicy.swift`:
  ```swift
  enum ReviewImageSizePolicy {
      enum Intent: Equatable { case cell, fullscreen, fullscreenZoomed }
      static let cellMaximumLongEdge: CGFloat = 1_600
      static let fullscreenHeadroom: CGFloat = 2.5
      static let fullscreenMaximumLongEdge: CGFloat = 4_096
      static let zoomedMaximumLongEdge: CGFloat = 8_192
      static let zoomedMaximumAssetPixels = 24_000_000
      static let previewLongEdge: CGFloat = 512
      /// Always finite, positive and < 100_000 (never PHImageManagerMaximumSize). Aspect = the asset's.
      /// .cell: width = displayPoints.width × scale, height from aspect; scaled down so long edge ≤ 1,600; never above the asset.
      /// .fullscreen: aspect-fit the asset into (displayPoints × scale × 2.5); long edge ≤ 4,096; never above the asset.
      /// .fullscreenZoomed: the asset size with long edge ≤ 8,192.
      static func targetPixelSize(displayPoints: CGSize, scale: CGFloat, assetPixels: CGSize, intent: Intent) -> CGSize
      /// true only when committedScale > 2.5 and assetPixels.width × height ≤ 24 MP.
      static func allowsZoomedRequest(assetPixels: CGSize, committedScale: CGFloat) -> Bool
      /// `full` scaled so its long edge is min(512, full's long edge), aspect preserved.
      static func previewPixelSize(for full: CGSize) -> CGSize
  }
  ```
  - Round results up to whole pixels.
  - If the asset's dimensions are 0, use the display aspect with no asset cap.
  - Degenerate display sizes return at least 1×1.
- **Change:** add `testNoMaximumSizeRequestsInApp` to WS-14's `ThumbnailLintTests`. It fails if `PHImageManagerMaximumSize` appears on any non-comment line under `iOSCleanup/`.

**WS-51.2 — Review and fullscreen stay out of the shared LRU**
- **Change** in `SharedHelpers.swift`:
  - WS-14's `isCacheable` becomes `true` only for `.thumbnail`.
  - Add a single-entry slot to `PhotoImageRepository`: `private var lastFullscreen: (key: PhotoImageRequestKey, image: SendablePhotoImage)?`.
    - `image(for:resultOperation:)` checks the slot first for `.fullscreen` keys.
    - `finishConsumer` stores non-degraded `.fullscreen` results in the slot, replacing the previous entry.
  - `removeAllCachedImages()` (the memory-warning path) also clears the slot.
  - Add DEBUG `debugHasFullscreenSlot(for:) -> Bool`.
  - In-flight coalescing is unchanged for every intent.
- **Edge cases:**
  - The slot is the only place a fullscreen bitmap survives its view, so re-opening the same photo is instant without evicting thumbnails.
  - `.review` results are never retained by the repository. `DuckModeImageCache` (WS-51.6) and the views own them.

**WS-51.3 — `PhotoThumbnailView` additions and `ReviewImageLayers`**
- **Change** in `PhotoThumbnailView` (WS-14):
  - `var prefetchedImage: UIImage? = nil`. When non-nil, the initial phase is `.loaded(prefetchedImage)`, set with `_phase = State(initialValue:)` in `init`. The first task run returns immediately if the phase is already `.loaded` and `attempt == 0`.
  - `var releasesImageOnDisappear = false`. `.onDisappear { if releasesImageOnDisappear { phase = .loading } }`. The `.task(id:)` re-runs on reappearance and reloads, because the phase is no longer `.loaded`.
  - `var showsUnavailableChrome = true`. When false, the unavailable state draws only the placeholder, so the layer below stays visible.
- **Change:** new `iOSCleanup/Views/Components/ReviewImageLayers.swift`:
  ```swift
  /// A fast local preview under the full-quality image (PERF-08/PERF-10 "local derivative first").
  struct ReviewImageLayers<Placeholder: View>: View {
      enum NetworkPolicy: Equatable { case always, onRequest }
      let asset: PHAsset
      let fullPixelSize: CGSize
      let contentMode: PHImageContentMode
      let intent: PhotoImageQualityIntent            // .review or .fullscreen
      var networkPolicy: NetworkPolicy = .always
      var prefetchedImage: UIImage? = nil
      var releasesImageOnDisappear = false
      var onFullPhaseChange: ((ThumbnailPhase.Kind) -> Void)? = nil
      @ViewBuilder var placeholder: () -> Placeholder
      @State private var fullPhase: ThumbnailPhase.Kind = .loading
      @State private var userRequestedNetwork = false
      // body: ZStack {
      //   if prefetchedImage == nil && fullPhase != .loaded {
      //     PhotoThumbnailView(.pixels(previewPixelSize(for: fullPixelSize)), contentMode, .thumbnail, network: false, placeholder) }
      //   PhotoThumbnailView(.pixels(fullPixelSize), contentMode, intent,
      //     network: networkPolicy == .always || userRequestedNetwork, showsRetry: true, prefetchedImage:,
      //     releasesImageOnDisappear:, showsUnavailableChrome: networkPolicy == .always || userRequestedNetwork,
      //     onPhaseChange: { fullPhase = $0; onFullPhaseChange?($0) }) { Color.clear }
      //     .id(userRequestedNetwork)
      //   if networkPolicy == .onRequest && !userRequestedNetwork && fullPhase == .unavailable {
      //     "Load full quality" button (icloud.and.arrow.down, existing DuckTheme tokens; accessibilityLabel "Load full quality") → userRequestedNetwork = true }
      // }
  }
  ```
- **Edge cases:**
  - The preview is a `.thumbnail` with network off, so WS-14's degraded fallback applies and an iCloud-only asset still shows its local derivative.
  - The preview is removed once the full image loads, so both bitmaps are held only briefly.

**WS-51.4 — Group detail cells**
- **Change:** in `PhotoGroupAssetCell`, replace the WS-14 `PhotoThumbnailView` with `ReviewImageLayers(asset:, fullPixelSize: ReviewImageSizePolicy.targetPixelSize(displayPoints: proxy.size, scale: displayScale, assetPixels: CGSize(width: asset.pixelWidth, height: asset.pixelHeight), intent: .cell), contentMode: .aspectFit, intent: .review, networkPolicy: .onRequest, releasesImageOnDisappear: true)`. Delete `displayTargetSize(for:)`. Keep the selection overlays, gestures, accessibility and keeper protection exactly as they are.
- **Edge cases:**
  - `validateManualSelection` and keeper protection are untouched (invariant 3).
  - The "Load full quality" button is per cell and never auto-triggers.

**WS-51.5 — Fullscreen canvas**
- **Change:** in `ZoomablePhotoCanvas`:
  - Replace its request with `ReviewImageLayers(asset:, fullPixelSize: targetPixelSize(displayPoints: proxy.size, scale: displayScale, assetPixels:, intent: .fullscreen), contentMode: .aspectFit, intent: .fullscreen, networkPolicy: .always)`, measured in the existing `GeometryReader`.
  - Add `@State private var zoomedImage: UIImage?`. When a magnification ends with `committedScale > 2.5` and `allowsZoomedRequest` is true, load once through `PhotoImageRepository.shared.image(for:targetSize: targetPixelSize(… .fullscreenZoomed), contentMode: .aspectFit, qualityIntent: .fullscreen, allowNetworkAccess: true)`, in a task cancelled on disappear.
  - While `zoomedImage != nil`, render it **instead of** the layers: an `if`/`else`, so the 4,096 px bitmap is released.
  - The gesture and reset code is unchanged. Double-tap reset keeps `zoomedImage`, because the user may zoom again.
- **Edge cases:**
  - A 48 MP asset never requests the zoomed size. Its fullscreen bitmap is at most 4,096 px on the long edge (≤ ~50 MB).
  - The WS-14 unavailable and Retry state still shows on nil.

**WS-51.6 — `upcomingAssets(limit:)` and `DuckModeImageCache`**
- **Change** in `SwipeModeViewModel` (queue access stays inside it; WS-12/41 rule):
  ```swift
  func upcomingAssets(limit: Int = 3) -> [PHAsset] {
      guard limit > 0 else { return [] }
      var result: [PHAsset] = []; var index = currentIndex + 1
      while index < queue.count, result.count < limit {
          if case .asset(let asset, _) = queue[index] { result.append(asset) }
          index += 1
      }
      return result
  }
  ```
- **Change:** new `iOSCleanup/Views/Photos/DuckModeImageCache.swift`. It is a `@MainActor` class, not an actor, so the card can read it synchronously and paint on the first frame.
  ```swift
  @MainActor
  final class DuckModeImageCache {
      typealias Loader = @Sendable (PHAsset, CGSize) async -> UIImage?
      static let liveLoader: Loader = { asset, size in     // EXACTLY DuckAssetCard's full-quality request
          await PhotoImageRepository.shared.image(for: asset, targetSize: size, contentMode: .aspectFill,
                                                  qualityIntent: .review, allowNetworkAccess: true)
      }
      init(capacity: Int = 4, loader: @escaping Loader = DuckModeImageCache.liveLoader)
      /// Keyed by (localIdentifier, modificationDate, ceil(pixel w), ceil(pixel h)).
      func image(for asset: PHAsset, pixelSize: CGSize) -> UIImage?
      /// Window = [current] + upcoming (≤ capacity). Evicts images and cancels loads outside it. Starts missing
      /// upcoming loads as per-key tasks chained in window order (each awaits the previous key's task first).
      func updateWindow(current: PHAsset?, upcoming: [PHAsset], pixelSize: CGSize)
      func cancelAll()
      #if DEBUG
      var debugCachedCount: Int { get }
      var debugInFlightIDs: [String] { get }
      #endif
  }
  ```
  A result is stored only if its key is still in the window when it arrives.
- **Edge cases:**
  - Cancelling a key that left the window never cancels in-window work.
  - The repository coalesces a prefetch with the card's own identical request, so each asset has one PhotoKit request.

**WS-51.7 — Wire Duck Mode**
- **Change** in `SwipeModeView`:
  - Add `private struct DuckCardPixelSizeKey: PreferenceKey` (default `.zero`, reduce keeps the last). `DuckAssetCard`'s `GeometryReader` sets it to the same `targetSize` its request uses.
  - Add `@State private var duckCache = DuckModeImageCache()` and `@State private var cardPixelSize = CGSize.zero`. Set `cardPixelSize` in `.onPreferenceChange`. If the SDK marks that action `@Sendable`, wrap the assignment in `MainActor.assumeIsolated { … }` to stay warning-free.
  - `refreshPrefetch()` calls `duckCache.updateWindow(current: currentAsset, upcoming: viewModel.upcomingAssets(limit: 3), pixelSize: cardPixelSize)` when `cardPixelSize.width > 0`. Call it from `.onAppear`, `.onChange(of: viewModel.currentIndex)`, `.onChange(of: cardPixelSize)` and `.onChange(of: viewModel.queue.count)`. Call `.onDisappear { duckCache.cancelAll() }`.
  - `DuckAssetCard`'s image becomes `ReviewImageLayers(asset:, fullPixelSize: targetSize, contentMode: .aspectFill, intent: .review, networkPolicy: .always, prefetchedImage: duckCache.image(for: asset, pixelSize: targetSize), onFullPhaseChange: <WS-14's cardPhase reporting>)` with the existing pink placeholder.
  - Keep WS-04's `.id(asset.localIdentifier)` on the card and WS-14's `DuckCardActionPolicy` gating on the **full** phase.
- **Change:** add the interval `duck.nextCard` to `PhotoDuckSignposts` (WS-09). Begin it when a swipe commits (`SwipeModeViewModel.commit`) and end it when the next card's full phase becomes `.loaded`. The message is `"prefetched=1"`/`"prefetched=0"` (numbers only).

**WS-51.8 — Docs**
- **Change:** in `CLAUDE.md` Key constraints:
  - "Review and fullscreen images never enter the shared thumbnail LRU (one fullscreen slot). Display sizes come from `ReviewImageSizePolicy`, and `PHImageManagerMaximumSize` is lint-banned."
  - "Duck Mode prefetches the next 3 cards through `DuckModeImageCache` with the card's exact request key."

### Tests
All run in the simulator unless marked device.
- **`ReviewImageSizePolicyTests`:**
  - `testFullscreen48MPOn393ptCanvasAt3xStaysUnder4096AndKeepsAspect`: an 8064×6048 asset on a 393×852 canvas. Long edge ≤ 4,096, aspect within 0.5%, and ≥ 2.5× the displayed width when the asset allows.
  - `testFullscreenNeverUpscalesSmallAsset`: 640×480 → 640×480.
  - `testCellNeverExceedsAssetOr1600`.
  - `testCellHasNo1200Floor`: a 180 pt cell at 3x on a 4032×3024 asset gives a width of 540.
  - `testZoomAllowedOnlyAbove2_5xAndAtMost24MP`.
  - `testNeverReturnsMaximumSize`: fuzz 1,000 random inputs; every result is finite, > 0 and < 100,000.
  - `testPreviewLongEdgeIsAtMost512`.
- **Repository tests** (operation-based entry point):
  - Change `testImageRepositorySeparatesThumbnailAndReviewQuality` to `cachedCount == 1`. Add the comment "WS-51 / PERF-08: .review is not cached". This is an intended behavior change; list it in the PR.
  - `testReviewAndFullscreenLeaveThumbnailsCached`: store 3 thumbnails, then one `.review` and one `.fullscreen`. `debugCachedImageCount() == 3`.
  - `testFullscreenSlotServesRepeatOpenWithoutOperation`: the second identical `.fullscreen` request does not start the operation.
  - `testSecondFullscreenReplacesSlot`.
  - `testMemoryWarningClearsFullscreenSlot` (call `removeAllCachedImages()`).
  - `testFullscreenStillCoalescesConcurrentRequests`.
- **`SwipeModeViewModelTests`:**
  - `testUpcomingAssetsSkipsMonthHeadersAndRespectsLimit`.
  - `testUpcomingAssetsIsEmptyAtEndOfQueue`.
  - `testUpcomingAssetsExcludesCurrent`.
- **`DuckModeImageCacheTests`** (injected loader that records calls and gates per asset ID):
  - `testWindowChangeEvictsAndLoadsOnlyNewAssets`: `updateWindow(current: a, upcoming: [b,c,d])`, then complete all loads, then `updateWindow(current: c, upcoming: [d,e,f])`. `a` and `b` are evicted; `e` and `f` are requested exactly once; `d` is not re-requested; `debugCachedCount ≤ 4` at every step.
  - `testLeavingWindowCancelsOnlyThatLoad`: `c` is gated. Move the window so `c` leaves it; `c`'s loader observes cancellation; `d`'s load still completes.
  - `testLateResultOutsideWindowIsDiscarded`.
  - `testLoadsStartInWindowOrder`.
- **`ThumbnailLintTests`:** `testNoMaximumSizeRequestsInApp`.
- **Device only:** memory and timing (Device QA).

### Acceptance criteria
- [ ] `grep -rn "PHImageManagerMaximumSize" iOSCleanup` matches only comments, and the lint test passes.
- [ ] `.review` and `.fullscreen` results never enter the shared LRU; the fullscreen slot works; the repository tests pass.
- [ ] Group-detail cells release their bitmaps on disappear, request at most 1,600 px on the long edge, and use no network until "Load full quality" is tapped.
- [ ] Duck Mode prefetches the next 3 assets with the card's exact key, cancels on window change and on disappear, and a prefetched card paints on its first frame. WS-04's `.id` and WS-14's Delete gating are unchanged.
- [ ] Device numbers are in the PR and in `docs/DEVICE_QA.md`: burst group < 120 MB above baseline; Compare on 48 MP < 80 MB peak; next card prefetched on ≥ 95% of local swipes; preview ≤ 100 ms on an optimized library.
- [ ] Zero warnings, suite green, and `CLAUDE.md` updated.

### Device QA
Add to `docs/DEVICE_QA.md` under "Review images (WS-51)":
1. **Instruments Allocations, 40-photo burst group.** Open the group and scroll top to bottom and back. Persistent growth must be < 120 MB above the pre-open baseline.
2. **Compare on a 48 MP (or ProRAW) photo.** Tap through 6 thumbnails in the strip. The peak is < 80 MB above baseline, and the group grid behind does not reload its thumbnails on dismiss.
3. **Duck Mode, local library.** Swipe 50 cards at a steady pace. From the `duck.nextCard` signposts, ≥ 95% show `prefetched=1` or durations under one frame.
4. **Duck Mode, "Optimize iPhone Storage" library.** The local preview appears within 100 ms of each swipe. Delete enables only after the full image loads (WS-14).
5. **Airplane Mode, optimized library.** Open a group. Cells show local previews plus "Load full quality", and nothing downloads. Turn the network on, tap "Load full quality" on one cell, and only that cell loads.

### Pitfalls and out of scope
- **Invariant 21:** images load only through `PhotoImageRepository`. `DuckModeImageCache` holds results but loads through the repository.
- **Invariant 3:** keeper protection and manual-selection validation in group detail are untouched.
- The local preview never counts as "seen" for Delete gating. Keep the WS-14 DECISION.
- Invariant 29: no Duck Mode redesign. The layers and the "Load full quality" button use existing components and tokens.
- **Out of scope:**
  - Grid thumbnails, buckets, the UI lane and PhotoKit caching: WS-52.
  - VoiceOver actions in Duck Mode: WS-55 (chapter 12).
  - Stale-image fixes: WS-04, already done.

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| PERF-08 | confirmed | `PHImageManagerMaximumSize` at `PhotoGroupDetailView.swift:594` with `.fullscreen` and network on; cells requesting 1,200–2,048 px `.review` with network on (`:465-473`); the `LazyVStack` (`:56`); the repository storing up to 96 MB per image (`SharedHelpers.swift:442-446`). The memory figures are estimates, measured on device. Differences from the proposed fix: the fullscreen size uses FSB-02's canvas × scale × 2.5 math (aspect-fit, ≤ 4,096, ≤ asset) instead of 2 × screen; the ≤ 24 MP zoom request replaces the fullscreen bitmap rather than adding to it; the "local derivative first" behavior comes from a `.thumbnail` preview layer instead of a streaming repository API. |
| FSB-02 (merged) | confirmed | The same canvas and cache facts, plus no Duck Mode prefetch (`SwipeModeView.swift:431-489`). Its sizing math and its single-entry fullscreen slot are adopted. Its prefetch half is PERF-10 below; its tests (a)–(d) map to the repository, cache and policy tests above. |
| Reconciliation (WS-14) | n/a | WS-14's DECISION stands unchanged: Duck Mode's Delete is enabled only when the card's **full-quality** phase is `.loaded` (`DuckCardActionPolicy.canDelete`). The local preview layer never enables Delete. A prefetched image does, because it is the result of the card's exact full-quality request. WS-55's VoiceOver Delete action obeys the same rule. On Optimize-Storage libraries Delete therefore still waits for the full image; the owner may revisit this separately. |
| PERF-10 | confirmed | One card only (`SwipeModeView.swift:97-150`); a high-quality request after the 250 ms transition (`SwipeModeViewModel.swift:81-100`); no prefetch. The decode and download latency figures are device-only. Differences from the proposed fix: `DuckModeImageCache` is a `@MainActor` class, not an actor, so the prefetched image paints on the first frame through `PhotoThumbnailView(prefetchedImage:)`; loads are per-key tasks chained in window order instead of one sequential loop, so cancelling a key that left the window never cancels in-window work. |

---

## WS-52 — Thumbnail pipeline: UI lane, size buckets, prefetch, O(1) LRU

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M3 | M | WS-22, WS-51 | no | `ws/52-thumbnail-pipeline` |

**Primary files:**
- **New code:** `iOSCleanup/Utilities/LRUCache.swift`, `iOSCleanup/Utilities/PhotoImageLaunchLane.swift`, `iOSCleanup/Utilities/PhotoThumbnailBucket.swift`, `iOSCleanup/Utilities/PhotoThumbnailPrefetcher.swift`.
- **Edited code:** `iOSCleanup/Utilities/SharedHelpers.swift` (repository LRU only), `iOSCleanup/Utilities/PhotoKitRequestState.swift` (WS-10's file; WS-24.5 moved `PhotoImageRequestState` and its executors into it, README §9 contract 8; confirm with grep `final class RequestExecutor`), `iOSCleanup/Utilities/PHAsset+ImageLoadOutcome.swift` (WS-22), `iOSCleanup/Views/Components/PhotoThumbnailView.swift`.
- **Grid views:** `iOSCleanup/Views/Photos/PhotoCategoryReviewView.swift`, `iOSCleanup/Views/Export/ExportAlbumView.swift`, `iOSCleanup/Views/Photos/PhotoResultsView.swift`.
- **Tests:** `iOSCleanupTests/LRUCacheTests.swift` (*new*), `iOSCleanupTests/PhotoImageLaunchLaneTests.swift` (*new*), `iOSCleanupTests/PhotoThumbnailBucketTests.swift` (*new*), `iOSCleanupTests/PhotoThumbnailPrefetcherTests.swift` (*new*), the repository tests (`FileScanEngineTests.swift` or WS-03's location), `iOSCleanupTests/ScalePerformanceTests.swift`.
- **Project and docs:** `iOSCleanup.xcodeproj/project.pbxproj`, `CLAUDE.md`.

**Findings covered:** PERF-09 (P2, partially)
**Decisions applied:** none directly. The README cut line allows this workstream to slip past v1. If it does, WS-54 still lands WS-52.1.

### Goal
- Grids never show a spinner that is stuck because of request capacity.
- Cancelled cells stop their PhotoKit work.
- Every thumbnail site shares one of three pixel sizes, so the cache is reused across screens, and the tiles are sharp on 3x displays.
- Scrolling a large grid prefetches the next rows through `PHCachingImageManager`.
- Cache eviction is O(1). WS-54 reuses the same LRU.

### Current behavior (verified)
- **One image manager, no prefetch.** `SharedHelpers.swift:553`: `loadImage` always uses `PHImageManager.default()`. No `PHCachingImageManager` or `startCachingImages` exists anywhere (grep).
- **Requests are rejected at capacity.** `RequestExecutor` (`SharedHelpers.swift:26-57`) admits 16 scheduled launches and returns false beyond that. `loadImage` then resolves nil (`:608-610`). After WS-22 the analysis lane has its own executor behind `AsyncSemaphore(value: 16)` permits, but the UI lane still rejects, now reported as `.failed(.capacity)`.
- **Cancels are dropped.** `CancellationExecutor` (`:61-91`) runs 2 workers and **drops** cancels beyond 8 scheduled. The existing test `testImageRequestTimeoutResumesBeforeBlockingPhotoKitCancellation` (`FileScanEngineTests.swift:709+`) requires that a second cancellation can start while the first is blocked inside PhotoKit.
- **O(n) eviction.** `PhotoImageRepository.store` evicts with `cachedImages.min(by:)` (`:455`), a scan of the whole dictionary per eviction.
- **Per-site sizes.** At baseline the call sites hard-code small pixel sizes: 144 (`PhotoResultsView.swift:739`, `PhotoGroupDetailView.swift:642`), 180 (`PhotoResultsView.swift:571`), 176 (`SwipeModeView.swift:405`), 300 (`HomeView.swift:2152`) and 360 (`PhotoDuckShellView.swift:647-656`).
  - After WS-14 every site is a `PhotoThumbnailView(.points(…))` whose pixel size is `ceil(points × displayScale)`: 120×104, 88, 110, 72, 130 and 64 pt. The sizes are no longer too small, but each screen still uses its own cache key.
  - WS-14 also deleted `GroupOverviewCard.loadThumbnails` (all-three-then-assign) and the sequential Similar collage loader.

### Implementation plan

**WS-52.1 — Generic O(1) `LRUCache` (land first; WS-54 depends on it)**
- **Change:** new `iOSCleanup/Utilities/LRUCache.swift`:
  ```swift
  /// O(1) get/insert/evict LRU with optional count and cost limits. Value type; not thread-safe:
  /// use it inside an actor or under a lock.
  struct LRUCache<Key: Hashable, Value> {
      init(countLimit: Int = .max, costLimit: Int = .max)
      private(set) var totalCost: Int
      var count: Int { get }
      mutating func value(forKey key: Key) -> Value?          // marks most recent
      func peek(_ key: Key) -> Value?                          // does not touch
      /// Inserts or replaces, then evicts least-recent entries until both limits hold. Returns the evicted pairs.
      /// A single entry whose cost exceeds costLimit is not stored.
      @discardableResult mutating func insert(_ value: Value, forKey key: Key, cost: Int = 1) -> [(key: Key, value: Value)]
      @discardableResult mutating func removeValue(forKey key: Key) -> Value?
      mutating func removeAll()
      func keysFromLeastRecent() -> [Key]                      // for persistence (WS-54)
  }
  ```
  The implementation is a slot array of nodes with `prev`/`next` indices, a free list and `[Key: Int]`, so there are no per-node class allocations.
- **Change:** `PhotoImageRepository` replaces `cachedImages`, `totalDecodedByteCost`, `accessOrdinal` and the `min(by:)` loop with `LRUCache<PhotoImageRequestKey, CacheEntry>(costLimit: maximumDecodedByteCost)`. `debugCachedImageCount()` returns `cache.count`. `SharedHelpers.swift` must not grow in net lines.

**WS-52.2 — A UI lane that never rejects, and cancels that are never dropped**
- **Change:** new `iOSCleanup/Utilities/PhotoImageLaunchLane.swift`:
  ```swift
  /// FIFO launch admission for one lane. `launch` waits for a permit (cancellation-aware) instead of rejecting.
  /// A permit covers the launch operation only (the requestImage call), like WS-22's analysis lane, so a slow
  /// iCloud review download can never starve thumbnails.
  final class PhotoImageLaunchLane: @unchecked Sendable {
      init(permits: Int, workers: Int)     // OperationQueue maxConcurrent = workers; executor capacity = permits
      /// false only if the task was cancelled while waiting; the operation then never runs.
      func launch(_ operation: @escaping @Sendable () -> Void) async -> Bool
  }
  ```
  - `PhotoImageRequestLane` (WS-22's `enum { case ui, analysis }`) gets `static let uiLane = PhotoImageLaunchLane(permits: 12, workers: 8)`. Leave WS-22's analysis lane as it is: its `analysisLaunchPermits` (WS-22's own `AsyncSemaphore(value: 16)`) and its separate `RequestExecutor` instance. `PhotoImageLaunchLane` is new here and does not reuse `AsyncSemaphore`.
  - `loadImageOutcome(…, lane: .ui)` calls `await uiLane.launch { … }`. If that returns `false`, it resolves `.failed(.cancelled)`. It never returns `.capacity` again.
- **Change:** in `CancellationExecutor`, remove `scheduledCount`/`maximumScheduledCount` (never drop). Keep `maxConcurrentOperationCount = 2`.
- **Edge cases:**
  - Queued launches of cells that scrolled away are cancelled before they run.
  - The existing blocking-cancellation test must still pass, which is why the queue stays two-wide.

**WS-52.3 — `PhotoThumbnailBucket` inside `PhotoThumbnailView`**
- **Change:** new `iOSCleanup/Utilities/PhotoThumbnailBucket.swift`:
  ```swift
  enum PhotoThumbnailBucket: Int, CaseIterable, Comparable {
      case small = 256, medium = 400, large = 640
      var pixelSize: CGSize { CGSize(width: rawValue, height: rawValue) }
      /// Smallest bucket whose side covers max(points.width, points.height) × scale; nil above 640 px.
      static func bucket(forPoints points: CGSize, scale: CGFloat) -> PhotoThumbnailBucket?
      static func < (l: Self, r: Self) -> Bool { l.rawValue < r.rawValue }
  }
  ```
  In `PhotoThumbnailView`, for `.points(p)` with `qualityIntent == .thumbnail` and `contentMode == .aspectFill`, the request pixel size is `bucket.pixelSize`. If `bucket(...)` is nil, fall back to WS-14's `ceil(p × displayScale)`. `.aspectFit`, `.pixels` and non-thumbnail intents are unchanged. Call sites do not change.
- **Edge cases:**
  - Square buckets with `.aspectFill` crop identically to today's per-site requests.
  - WS-14's degraded rule (`acceptsDegradedResult` only below 200 px) now always waits for the final image with the degraded fallback, because every bucket is at least 256 px.

**WS-52.4 — `PHCachingImageManager` and grid prefetch windows**
- **Change:** new `iOSCleanup/Utilities/PhotoThumbnailPrefetcher.swift`:
  ```swift
  protocol ThumbnailCaching: AnyObject, Sendable {
      func startCaching(_ assets: [PHAsset], bucket: PhotoThumbnailBucket)
      func stopCaching(_ assets: [PHAsset], bucket: PhotoThumbnailBucket)
      func stopCachingAll()
  }
  /// The one PHCachingImageManager: thumbnail requests and grid prefetch share it, so prefetched work is hit.
  final class PhotoThumbnailCachingManager: ThumbnailCaching, @unchecked Sendable {
      static let shared = PhotoThumbnailCachingManager()
      let manager = PHCachingImageManager()
      /// EXACTLY loadImage's thumbnail options: .opportunistic, resizeMode .exact, network false, async.
      static func thumbnailRequestOptions() -> PHImageRequestOptions
      // init registers didReceiveMemoryWarning → stopCachingAll()
  }
  enum ThumbnailPrefetchWindow {
      /// Visible lo...hi: prefetch hi+1...hi+lead×cols and lo−lead×cols...lo−1; stop anything cached outside
      /// lo−keep×cols...hi+keep×cols. Clamped to 0..<count.
      static func plan(visible: ClosedRange<Int>, count: Int, columns: Int, leadRows: Int, keepRows: Int)
          -> (start: [Int], keep: ClosedRange<Int>?)
  }
  @MainActor
  final class PhotoThumbnailPrefetcher {
      init(caching: ThumbnailCaching = PhotoThumbnailCachingManager.shared, leadRows: Int = 2, keepRows: Int = 4)
      func cellAppeared(index: Int, in assets: [PHAsset], columns: Int, bucket: PhotoThumbnailBucket)
      func cellDisappeared(index: Int)
      func stop()                          // stopCaching for everything this grid started
  }
  ```
  - `PhotoImageRepository.image(for asset:…)`: for `.thumbnail` with `allowNetworkAccess == false`, pass `manager: PhotoThumbnailCachingManager.shared.manager` to `loadImageOutcome`. Add a `manager: PHImageManager = .default()` parameter and build the options through `thumbnailRequestOptions()` in that case, so they are identical. All other requests keep `.default()`.
  - **Grids:** each grid holds `@State private var prefetcher = PhotoThumbnailPrefetcher()`, and every cell calls `cellAppeared`/`cellDisappeared` from `.onAppear`/`.onDisappear`. The grid calls `.onDisappear { prefetcher.stop() }`. The grid computes its bucket once, from its cell point size and `displayScale`, with the same function `PhotoThumbnailView` uses. The grids are:
    - `PhotoCategoryReviewView`'s grid, over WS-41's display-ordered assets, 3 columns;
    - `ExportAlbumView`'s grid, 3 columns;
    - `PhotoResultsView`'s list, with columns = 1 and the assets flattened to each row's preview assets.
- **Edge cases:**
  - `startCaching` is advisory. Correctness never depends on it.
  - A memory warning stops all caching (WS-25 also purges).
  - Invariant 21 holds, because the caching manager never hands images to views; display still goes through the repository.

**WS-52.5 — Verify WS-14's per-tile loading, benchmark, docs**
- **Change:**
  - `grep -rn "loadThumbnails\|requestThumb" iOSCleanup/Views` must be empty. If WS-14 left either loader, migrate that site per WS-14's table (each tile is its own `PhotoThumbnailView`).
  - Update WS-08's benchmark (5) `testImageRepositoryLRUScales`: keep 2,500 → 10,000 keys at capacity 500, add `XCTAssertEqual(await repository.debugCachedImageCount(), 500)`, and assert that the 500 most recent keys are the survivors.
  - Add `testLRUCacheScales`: 10,000 → 40,000 inserts at `countLimit` 1,000, ratio < 6.
  - `CLAUDE.md`: "Thumbnails use three pixel buckets (256/400/640) chosen in `PhotoThumbnailView`; the UI request lane queues instead of rejecting; one `PHCachingImageManager` serves thumbnails and grid prefetch."

### Tests
All run in the simulator.
- **`LRUCacheTests`:**
  - `testEvictsLeastRecentlyUsedFirst`.
  - `testGetMarksMostRecent`.
  - `testCostLimitEvictsUntilUnderLimit`.
  - `testOversizedEntryIsNotStored`.
  - `testReplaceUpdatesCostAndRecency`.
  - `testKeysFromLeastRecentMatchesInsertionAndAccessOrder`.
  - `testRandomOperationsMatchReferenceModel`: 10,000 seeded operations compared against a naive array-based LRU.
- **`PhotoImageLaunchLaneTests`:**
  - `testSixtyFourLaunchesNeverRejectAndPeakScheduledIsTwelve`. Each operation records entry and exit in a `ConcurrencyProbe` and blocks on a semaphore that the test releases in batches. All 64 return `true`; the peak count of scheduled (permitted) operations is ≤ 12; all 64 run.
  - `testCancelledWaiterNeverRunsItsOperation`.
  - `testFIFOOrderOfAdmission`.
- **Repository and request-state tests:**
  - `testCancellationsAreNeverDropped`: the first canceller blocks; submit 50 more; release; all 51 canceller calls happen.
  - The existing `testImageRequestTimeoutResumesBeforeBlockingPhotoKitCancellation` still passes.
  - `testRepositoryUsesLRUCacheOrder`.
- **`PhotoThumbnailBucketTests`:**
  - `test107ptAt3xIsMedium`.
  - `test72ptAt3xIsSmall`.
  - `test120x104At2xIsSmall`.
  - `test88ptAt3xIsMedium`.
  - `testAbove640IsNil`.
- **`PhotoThumbnailPrefetcherTests`** (a `ThumbnailCaching` double that records calls):
  - `testAppearOfIndexStartsNextTwoRows`: columns 3, `cellAppeared(10)` starts 11…16 (and 4…9).
  - `testScrollingStopsRowsBeyondKeepWindow`: appear 10, then move the visible window to 40…45. Every index outside 28…57 that was started is stopped, and nothing beyond `i + 12` stays cached.
  - `testStopStopsEverythingStarted`.
  - `testWindowPlanClampsToBounds`.
- **`ScalePerformanceTests`** (Performance plan): the updated benchmark (5) and `testLRUCacheScales`.

### Acceptance criteria
- [ ] The UI lane never resolves `.capacity`, and the lane tests pass. `CancellationExecutor` has no drop path.
- [ ] Every `.points` thumbnail with `.aspectFill` requests a bucket size (bucket tests; grep shows no hard-coded thumbnail pixel sizes in `Views/`).
- [ ] `.thumbnail` requests without network go through the shared `PHCachingImageManager` with identical options. The three grids prefetch and stop caching on disappear and on memory warning.
- [ ] `PhotoImageRepository` uses `LRUCache`. Benchmark (5) and `testLRUCacheScales` ratios are < 6.
- [ ] Zero warnings, suite green, and `CLAUDE.md` updated.

### Device QA
Add to `docs/DEVICE_QA.md` under "Thumbnails (WS-52)":
1. During a running Deep Clean, open Screenshots (or Blurry) with 5,000+ items and fling top to bottom three times. No tile stays spinning after scrolling stops. The DEBUG log `debugInFlightRequestCount` returns to at most one screen's worth (about 30) within 2 s of the fling ending.
2. Visit the Similar list, then a category grid showing the same photos. The second screen's thumbnails appear without spinners (shared bucket keys).
3. On a 3x device, compare a category tile with the Photos app at the same size: no visible softness.

### Pitfalls and out of scope
- **Invariant 21:** images load only through `PhotoImageRepository`. The caching manager is a PhotoKit-side warm-up and never a second image source for views. Update the invariant's wording in `CLAUDE.md` accordingly: "(separate analysis and UI lanes after WS-52)".
- Do not change analysis-lane capacity or behavior (WS-22/WS-24). Keep the two lanes as separate instances.
- Options must match exactly, or `PHCachingImageManager` silently misses.
- **Reconciliation:**
  - The request executors are in WS-10's `PhotoKitRequestState.swift`, where WS-24.5 moved `PhotoImageRequestState` (README §9 contract 8). `VideoFileSizeRequestState` no longer exists: WS-10 uses `PhotoKitRequestState<Int64>`.
  - WS-22 does not provide a semaphore for this lane. The UI lane is this workstream's own `PhotoImageLaunchLane`, and WS-22's analysis lane is untouched.
  - If this workstream is cut, WS-54 lands WS-52.1 as its first commit (contract 19); the rest of WS-52 stays unbuilt.
- **Out of scope:**
  - Review and fullscreen sizing: WS-51.
  - `AssetFileSizeCache` adopting `LRUCache`: WS-54.

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| PERF-09 | partially | **Confirmed:** `PHImageManager.default()` only (`SharedHelpers.swift:553`); no caching manager; the 16-slot executor rejects to nil (`:26-57`, `:608-610`); cancels are dropped beyond 8 (`:61-91`); O(n) `min(by:)` eviction (`:455`). **Stale after WS-14:** undersized requests (`PhotoThumbnailView` multiplies points by `displayScale`), `GroupOverviewCard` waiting for all three tiles, and the sequential Similar collage (each tile is its own view). **Still true:** per-screen sizes never share cache keys. **Plan deviations:** the cancellation queue keeps 2 workers but loses its drop cap, because the existing blocking-cancellation test requires a second cancellation to start while the first blocks (the lead's "serial" note would fail it); UI permits cover launches only, matching WS-22's analysis lane, so slow iCloud review loads cannot starve thumbnails; the bucket falls back to exact sizing above 640 px instead of upscaling. |

---

## WS-53 — Engine scale hardening

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M3 | L | WS-24, WS-40, WS-46 | no | `ws/53-engine-scale-hardening` |

**Primary files:**
- **New code:** `iOSCleanup/Engines/CompactPairEdge.swift`, `iOSCleanup/Engines/PhotoScanUpdateDelta.swift`, `iOSCleanup/Views/Home/PhotoScanResultsMergeGate.swift`.
- **Engine:** `iOSCleanup/Engines/PhotoScanEngine.swift`, `iOSCleanup/Engines/PhotoScanWorkingSet.swift` (WS-23), `iOSCleanup/Engines/SimilarityPolicyServices.swift`.
- **Consumer side:** `iOSCleanup/Views/Home/AnalysisCheckpointState.swift` (WS-16), `iOSCleanup/Views/Home/PhotoResultsStore.swift`, `iOSCleanup/Views/Home/PhotoGroupMerge.swift` (WS-23), the apply site, `iOSCleanup/Utilities/PhotoDuckSignposts.swift`.
- **Tests:** `iOSCleanupTests/PhotoScanEngineTests.swift`, `iOSCleanupTests/PhotoScanPipelineTests.swift` (WS-24), `iOSCleanupTests/PhotoScanIncrementalTests.swift` (WS-23), `iOSCleanupTests/PhotoScanEngineEndToEndTests.swift` (WS-08/WS-40), `iOSCleanupTests/PhotoScanScaleGoldenTests.swift` (*new*), `iOSCleanupTests/PhotoScanUpdateDeltaTests.swift` (*new*), `iOSCleanupTests/Support/PhotoScanUpdateAccumulator.swift` (*new*), `iOSCleanupTests/AnalysisSnapshotBuilderTests.swift`, `iOSCleanupTests/PhotoResultsStoreTests.swift`.
- **Project and docs:** `iOSCleanup.xcodeproj/project.pbxproj`, `CLAUDE.md`.

**Findings covered:** SCAN-18 (P2, partially), SCAN-19 (P3, partially), SCAN-22 (P3, confirmed)
**Decisions applied:**
- **D-UPDATE-DELTAS:** `bufferingNewest(1)` stays. When `yield` returns `.dropped(old)`, merge `old`'s deltas into the new element and yield again. `targetAssetIDs` travels on the first update and stays in checkpoints.
- **D-REANALYSIS:** no `analyzerVersion` or `embeddingVersion` change.
- **Invariant 22:** final groups, keepers and delete plans are identical. A golden test proves it.

### Goal
- Peak edge memory drops roughly 4–5× with no change to grouping.
- Partial groups refresh at least every 2,048 assets or 15 s, whichever comes first.
- Per-batch work in the engine and on the main actor is proportional to the batch, not the library: delta updates, with no evaluated or unanalyzed ID ever lost to the dropping buffer.
- Counts are recomputed only when groups or categories change.
- The chronological drain (WS-24) and the context streaming (WS-23) are untouched.

### Current behavior (verified)
Baseline lines; WS-23 and WS-24 moved this code into `PhotoScanWorkingSet` and a sliding window.
- **Edges are never pruned.** `PhotoScanEngine.swift:549-550` declares `pairSignals` and `pairResults`. `:808-809` stores every retained edge in both (at most 24 per asset, 39 for bursts), and nothing prunes them. `PairEligibilityResult` (`SimilarityPolicyTypes.swift:198-205`) holds three heap arrays: hard blockers, soft blockers and reason strings.
- **Only `formClusters` reads `pairResults`.** It uses `eligible`, `provisionalBucket == .burstShot` and `similarityScore` (`SimilarityPolicyServices.swift:689-800`). `makeGroups` passes `pairSignals` into cluster evaluation (`PhotoScanEngine.swift:1300-1308`). `classifyCluster` recomputes every `PairEligibilityResult`, including reason strings and blockers, from those signals (`SimilarityPolicyServices.swift:365-380`). Nothing reads the edges' blockers or reason strings.
- **Full regroup at every refresh.** `makeGroups` (`:1255-1420`) re-sorts all descriptors and all eligible edges and re-runs `formClusters` over the whole library. `cachedGroups` reuses evaluations of unchanged member sets.
- **Refresh schedule doubles.** `PhotoScanRefreshSchedule.nextThreshold` (`:1915-1928`) is `min(target, max(processed + stride, current × 2))`, with an initial threshold and stride of 16 (`:606-607`). For a 60k target the last partial refresh is at 32,768, followed by completion. `testPartialGroupRefreshScheduleGrowsGeometrically` (`PhotoScanEngineTests.swift:279-293`) pins this.
- **Cumulative updates.** Each yield (`:935-962`) carries the cumulative `evaluatedAssetIDs`, `targetAssetIDs` and `unanalyzedAssetIDs`, then `evaluatedAssetIDs.insert` (`:846`) copy-on-writes the whole set while the buffered update still references it. `reviewableCount` (`:920-924`, `PhotoScanEngine.swift:1762-1775`) rebuilds a `Set` of every grouped ID each batch.
- **Main-actor cost.** The consumer (`HomeViewModel.swift:1693-1714`, now `AnalysisCheckpointState.fold` plus `PhotoResultsStore.mergeScanUpdate`/`PhotoGroupMerge`) runs `formUnion`, `subtract` and `isDisjoint` over library-sized sets for every update.
- **Already fixed.** WS-46 removed the per-asset pair-cache query (`:730-732`).
- **Fields added by earlier workstreams.** WS-22 added the run-cumulative `unanalyzedFailures` and the computed `unanalyzedReasonCounts`. WS-23 added the computed `affectedAssetIDs = evaluatedAssetIDs ∪ members(groups)`. WS-18 added `droppedRequiredAssetCount` on the first update. WS-40 inserts hidden burst extras into `evaluatedAssetIDs` before the loop.
- **Tests that read cumulative sets:** `PhotoScanEngineTests.swift:594, 629, 704, 737-761`, plus the WS-22/23/24 tests `testUnanalyzedAssetsCarryTypedReasons`, `testNewPhotoJoinsExistingGroupAsOneDisjointGroup` and `testEveryUpdateCommitsAChronologicalPrefix`.

### Implementation plan

**WS-53.1 — Golden groups at scale, captured before any change (commit 1)**
- **Change:** new `iOSCleanupTests/PhotoScanScaleGoldenTests.swift`. Build a deterministic fixture of 2,000 `ConfigurablePhotoScanTestAsset`s (WS-08) in 20 sessions of 100:
  - near-duplicate triples 2 s apart;
  - burst runs sharing a `burstIdentifier`, including WS-40 hidden extras;
  - visually-similar pairs in the 0.08–0.16 band;
  - screenshots;
  - singletons.

  Use WS-08's `TestEmbeddings` (`base(seed:)`, `offset(_:rmsDistance:seed:)`, `data(_:)`), an empty preference profile, and an isolated `PhotoMLBridge`.
  - `testCompactEdgesAndRefreshCadencePreserveFinalGroups`: run a full scan. Serialize the final groups, sorted by their first member ID, one line each: `reason;keeper;members(sorted);deletes(sorted);action;confidence`. Compare with a string literal captured on the **pre-change** code in this commit.
  - `testIncrementalRunGoldenUnchanged`: the same fixture, then an incremental pass with 50 required IDs, compared the same way.
- **Edge cases:** Keep the fixture small enough for the default test plan, `iOSCleanup.xctestplan` (under 10 s).

**WS-53.2 — Compact edges (SCAN-18 first step)**
- **Change:** new `iOSCleanup/Engines/CompactPairEdge.swift`:
  ```swift
  protocol ClusterEdgeEligibility {
      var eligible: Bool { get }
      var similarityScore: Double { get }
      var isBurstBucket: Bool { get }
  }
  extension PairEligibilityResult: ClusterEdgeEligibility {
      var isBurstBucket: Bool { provisionalBucket == .burstShot }
  }
  /// Everything formClusters needs. The score stays Double: narrowing it would change edge sort order.
  struct CompactPairEligibility: ClusterEdgeEligibility, Sendable, Equatable {
      let similarityScore: Double
      private let flags: UInt8                 // bit 0 eligible, bit 1 burst bucket
      init(_ result: PairEligibilityResult)
      var eligible: Bool { flags & 1 != 0 }
      var isBurstBucket: Bool { flags & 2 != 0 }
  }
  /// What the engine keeps per retained pair between refreshes. Reason strings and blockers are rebuilt by
  /// classifyCluster from `signals` when a cluster is evaluated.
  struct RetainedPairEdge: ClusterEdgeEligibility, Sendable, Equatable {
      let signals: SimilaritySignals
      let eligibility: CompactPairEligibility
      var eligible: Bool { eligibility.eligible }
      var similarityScore: Double { eligibility.similarityScore }
      var isBurstBucket: Bool { eligibility.isBurstBucket }
  }
  ```
  - `PhotoScanWorkingSet` (WS-23) replaces `pairSignals` and `pairResults` with `private(set) var edges: [SimilarityPairKey: RetainedPairEdge]`. The shared `evaluatePairs` stores `RetainedPairEdge(signals:, eligibility: CompactPairEligibility(result))` for target and context edges alike. WS-38's `ScreenshotHashIndex` (7 bands, also held by the working set) and its insert/evict calls are untouched.
  - `SimilarityCandidateGraph.formClusters` becomes generic: `func formClusters<Edge: ClusterEdgeEligibility>(descriptors:, pairResults: [SimilarityPairKey: Edge]) -> [[String]]`. Do the same for `bestCompleteLinkCandidate`. The body is unchanged except that `result.provisionalBucket != .burstShot` becomes `!result.isBurstBucket`. Existing tests calling it with `PairEligibilityResult` still compile.
  - `makeGroups` builds `clusterPairSignals[key] = workingSet.edges[key]?.signals`. WS-40's `burstOwnedIDs` filter before `formClusters` is unchanged.
  - Add DEBUG `private(set) var debugPeakRetainedEdgeCount` on the working set and `func debugPeakEdgeCount() -> Int` on the engine. At the end of a scan, the DEBUG log prints `peak_edges=<n> edge_stride=<MemoryLayout<RetainedPairEdge>.stride>`.
- **Edge cases:**
  - No blocker bitset is stored, because nothing reads edge blockers.
  - `cachedGroups` semantics are unchanged.

**WS-53.3 — Capped refresh stride and a 15 s refresh (SCAN-22; same PR as 53.2)**
- **Change** in `PhotoScanRefreshSchedule`:
  ```swift
  static let maximumStride = 2_048
  static let maximumInterval: TimeInterval = 15
  static func nextThreshold(after processed: Int, currentThreshold: Int, targetCount: Int, minimumStride: Int) -> Int {
      guard processed < targetCount else { return targetCount }
      return min(targetCount, processed + max(minimumStride, min(currentThreshold, maximumStride)))
  }
  /// A refresh is due at the threshold, at completion, or when 15 s passed and at least one asset drained since the last one.
  static func isRefreshDue(processed: Int, targetCount: Int, nextThreshold: Int,
                           drainedSinceLastRefresh: Int, now: TimeInterval, lastRefreshAt: TimeInterval) -> Bool
  ```
  - Add `refreshClock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }` as the last `PhotoScanEngine.init` parameter.
  - At each WS-24 yield point (every `progressYieldStride` drained, or when finished), regroup when `isRefreshDue`. Record `lastRefreshAt` and reset `drainedSinceLastRefresh`.
  - Add WS-09 event `engine.refresh` with the message `"trigger=stride"`, `"trigger=time"` or `"trigger=final"`.
- **Edge cases:**
  - A paused engine drains nothing, so it never regroups on time.
  - The existing geometric test still passes unchanged: its sequence never reaches the cap.

**WS-53.4 — Delta updates with drop-merge (SCAN-19, engine side)**
- **Change** in `PhotoScanUpdate`. Rename fields so the compiler finds every consumer:
  - `evaluatedAssetIDs` → `newlyEvaluatedAssetIDs`;
  - `unanalyzedAssetIDs` → `newlyUnanalyzedAssetIDs`;
  - `unanalyzedFailures` → `newlyUnanalyzedFailures`.

  Add `var groupsChanged = false` and `var categoriesChanged = false`. Document that `targetAssetIDs` and `droppedRequiredAssetCount` are non-empty only on the first *delivered* update. Delete `affectedAssetIDs` (WS-23) and `unanalyzedReasonCounts` (WS-22); they are meaningless on deltas, and the consumer derives both.
- **Change:** new `iOSCleanup/Engines/PhotoScanUpdateDelta.swift`:
  ```swift
  /// Engine-side changes since the last yield. `take()` moves the sets out (no copy-on-write of old sets).
  struct PhotoScanPendingDelta {
      var newlyEvaluatedAssetIDs = Set<String>()
      var newlyUnanalyzedAssetIDs = Set<String>()
      var newlyUnanalyzedFailures: [String: PhotoAnalysisFailureKind] = [:]
      var groupsChanged = false
      var categoriesChanged = false
      mutating func take() -> PhotoScanPendingDelta { let d = self; self = .init(); return d }
  }
  extension PhotoScanUpdate {
      /// `self` is newer. Sets and dictionaries union; flags OR; targetAssetIDs and droppedRequiredAssetCount
      /// come from whichever carries them; scalars, groups, screenshots, blurry and status come from `self`.
      func merging(droppedPredecessor old: PhotoScanUpdate) -> PhotoScanUpdate
  }
  enum PhotoScanUpdateYielder {
      /// D-UPDATE-DELTAS drop-merge. Returns true when a predecessor was dropped and merged.
      @discardableResult
      static func yield(_ update: PhotoScanUpdate,
                        to continuation: AsyncThrowingStream<PhotoScanUpdate, Error>.Continuation) -> Bool {
          guard case .dropped(let old) = continuation.yield(update) else { return false }
          _ = continuation.yield(update.merging(droppedPredecessor: old))   // drops `update`; merged ⊇ update
          return true
      }
  }
  ```
- **Change** in the engine:
  - Keep a `var pending = PhotoScanPendingDelta()`. Insert into it where `evaluatedAssetIDs.insert`/`unanalyzedAssetIDs.insert` happen today (drain order, WS-24). Pre-loop burst extras (WS-40) go in too.
  - Set `groupsChanged = true` when a refresh reassigns `latestGroups`, and `categoriesChanged = true` when `blurryAssets` gains an element.
  - Every yield site builds the update from `pending.take()` and goes through `PhotoScanUpdateYielder.yield`. The pre-loop first yield has `groupsChanged = true`, `categoriesChanged = true` and the full `targetAssetIDs`.
  - Delete the engine's cumulative `evaluatedAssetIDs`/`unanalyzedAssetIDs` sets unless something other than the yield reads them (keep counters). WS-22's DEBUG reason log uses a per-kind counter dictionary.
  - Add DEBUG `private(set) var debugDropMergeCount` (incremented when `yield` returns true) and `debugYieldCount`.
- **Change:** cache `reviewableCount` and `reclaimableBytes` in the engine. Recompute them only when `pending.groupsChanged || pending.categoriesChanged` since the last yield.
- **Edge cases:**
  - Within a run each asset drains once, so the delta sets are disjoint across updates, and `unanalyzed ⊆ evaluated` per delta. The consumer fold is therefore order-independent and idempotent under the re-yield race.
  - Never merge by *replacing* sets.

**WS-53.5 — Consumer fold, merge gate and counts on change (SCAN-19, main actor)**
- **Change** in `AnalysisCheckpointState` (WS-16):
  - Add `private(set) var runEvaluatedAssetIDs = Set<String>()`. It is reset by `preparingRun`, is not encoded, and is not part of the golden builder output.
  - `fold(update:offsets:)` becomes:
    ```swift
    evaluatedAssetIDs.formUnion(update.newlyEvaluatedAssetIDs)
    runEvaluatedAssetIDs.formUnion(update.newlyEvaluatedAssetIDs)
    targetAssetIDs.formUnion(update.targetAssetIDs)                 // first delivered update only
    unanalyzedAssetIDs.subtract(update.newlyEvaluatedAssetIDs)      // same order as today
    unanalyzedAssetIDs.formUnion(update.newlyUnanalyzedAssetIDs)
    ledger.fold(delta: update.newlyUnanalyzedFailures, evaluated: update.newlyEvaluatedAssetIDs)   // WS-22 ledger
    // committed-count arithmetic unchanged (ScanProgressMath)
    ```
- **Change:** new `iOSCleanup/Views/Home/PhotoScanResultsMergeGate.swift`:
  ```swift
  /// Decides whether merging this update could change the published results. Built once per run.
  struct PhotoScanResultsMergeGate {
      init(preserved: PreservedResults)      // indexes members of preserved groups, screenshots and blurry
      /// true when groupsChanged or categoriesChanged, or a newly evaluated ID touches a preserved item or a
      /// member of the current update's groups (that index is rebuilt whenever groupsChanged). O(delta) otherwise.
      mutating func needsMerge(_ update: PhotoScanUpdate) -> Bool
  }
  ```
- **Change** at the apply site:
  - Create the gate when a run starts.
  - Call `resultsStore.mergeScanUpdate(update, preserving:, runEvaluatedAssetIDs: checkpoint.runEvaluatedAssetIDs)` only when `gate.needsMerge(update)`. Inside, `PhotoGroupMerge.merge` receives `evaluatedAssetIDs: runEvaluated` and `affectedAssetIDs: runEvaluated ∪ members(update.groups)`, which reproduces WS-23's definition. The screenshot and blurry merges use `runEvaluated`.
  - Recompute `groupsFoundCount`, `reviewablePhotosCount` and `reclaimableBytesFoundSoFar` only after a merge.
  - WS-12's user-kept hook and WS-21's tombstones still apply inside the merge. Skipping a merge leaves the previously pruned state as it is.
- **Change:** in the WS-22 reason-count pass-throughs, read counts from `checkpoint.ledger`, not from the update.
- **Change:** tests that read cumulative sets use `iOSCleanupTests/Support/PhotoScanUpdateAccumulator.swift`, which folds deltas exactly like the consumer: `evaluated`, `unanalyzed`, `targets`, `failures`, `lastGroups`. Update every earlier test that reads a renamed or deleted `PhotoScanUpdate` field to accumulate; do not delete their assertions (README §9 contract 15). The known list:

  | Test (file) | From | Old read | New assertion |
  |---|---|---|---|
  | `testUnanalyzedAssetsCarryTypedReasons` (`PhotoScanEngineTests`) | WS-22 | final update's `unanalyzedFailures`, `unanalyzedReasonCounts`, `unanalyzedAssetIDs` | accumulated `failures` and `unanalyzed`; `unanalyzed == Set(failures.keys)`; reason counts computed from the accumulated failures |
  | `testNewPhotoJoinsExistingGroupAsOneDisjointGroup` (`PhotoScanIncrementalTests`) | WS-23 | `affectedAssetIDs ⊇ {A, B, C}` | `accumulated.evaluated ∪ members(lastGroups) ⊇ {A, B, C}` (the consumer's definition) |
  | `testEveryUpdateCommitsAChronologicalPrefix` (`PhotoScanPipelineTests`) | WS-24 | per update, `evaluatedAssetIDs == prefix(committed)` | per update, the accumulated `evaluated` so far `== Set(sortedTargets.prefix(committedProcessedPhotoCount))` |
  | `testPipelinePreservesGroupsAndOrder` (`PhotoScanPipelineTests`) | WS-24 | `evaluatedAssetIDs == target set` | accumulated `evaluated == target set` |
  | `testBufferedProgressCarriesDurableCheckpointIntoResumePlan` and the tests at baseline `PhotoScanEngineTests.swift:594, 629, 704, 737-761` | baseline, WS-24 | cumulative `evaluatedAssetIDs`/`unanalyzedAssetIDs` | the same assertions on accumulated values |
  | `testHiddenFramesAreNeverSentToAnalyzer` (`PhotoScanEngineEndToEndTests`) | WS-40 | the update's evaluated set, if it reads it | accumulated `evaluated` contains the hidden frames |
  | `AnalysisSnapshotBuilderTests`, `PhotoResultsStoreTests` fixtures that construct `PhotoScanUpdate` | WS-16, WS-21, WS-23 | old argument labels | new labels only; golden literals unchanged |

  Then run `grep -rn "evaluatedAssetIDs\|unanalyzedAssetIDs\|unanalyzedFailures\|affectedAssetIDs\|unanalyzedReasonCounts" iOSCleanupTests` and fix every remaining hit that reads a `PhotoScanUpdate`. Hits on `AnalysisCheckpointState`'s own cumulative sets are correct and stay.

**WS-53.6 — Measurement and docs**
- **Change:**
  - `CLAUDE.md` `PhotoScanEngine` row: "compact retained edges; partial regroup every 2,048 assets or 15 s; delta updates with drop-merge (D-UPDATE-DELTAS)".
  - In the PR summary, state that README invariant 17's delta clause is now implemented.
  - Add a `spec/BACKLOG.md` entry: "Time-window cluster finalization (SCAN-18 step 2), only if the WS-53 device run shows peak edges above 400k or memory warnings. Any frontier-based edge pruning or cluster freezing must exempt `isIdenticalCopy` edges (WS-61), which can join photos saved days apart, and must keep WS-38's `ScreenshotHashIndex` (and WS-61's `IdenticalCopyIndex`) consistent with whatever it evicts. vDSP distance only with a bit-exact threshold study."

### Tests
All run in the simulator unless marked device.
- **`PhotoScanScaleGoldenTests`** (WS-53.1): unchanged literals after 53.2–53.5.
- **`PhotoScanEngineTests`:**
  - `testRefreshStrideIsCappedAt2048`: processed 4,096 with current 4,096 gives 6,144; processed 40,000 gives 42,048.
  - The existing `testPartialGroupRefreshScheduleGrowsGeometrically` is unchanged.
  - `testTimeTriggeredRefreshHappensBeforeStrideThreshold`: a manual `refreshClock`; 400 assets; a near-duplicate pair at indices 60 and 61; the analyzer gated per slice. Advance the clock by 16 s after index 64 drains. The next update has `groupsChanged == true` and contains the pair, even though the stride threshold is 64 or more ahead.
  - `testNoTimeRefreshWithoutNewDrainedAssets`.
  - `testPeakEdgeCountIsReported`: the golden fixture gives `debugPeakEdgeCount() > 0` and `MemoryLayout<RetainedPairEdge>.stride ≤ 96`, compared with roughly 300–400 B per edge today.
  - `testSlowConsumerLosesNoDeltas` (D-UPDATE-DELTAS):
    1. Setup: 400 assets and a consumer that parks on a gate after receiving the first update.
    2. Wait until the analyzer has been called 400 times, then open the gate and accumulate every received update.
    3. The union of `newlyEvaluatedAssetIDs` equals all 400 IDs.
    4. `targetAssetIDs` was received non-empty exactly once and equals the target set.
    5. The union of `newlyUnanalyzedFailures` equals the analyzer's injected failures.
    6. `engine.debugDropMergeCount() > 0`, which proves drops happened.
  - `testGroupsChangedFalseBetweenRefreshes`.
  - `testReviewableCountRecomputedOnlyOnChange`: DEBUG counter.
  - Existing tests at `:594, 629, 704, 737-761`, and every test in WS-53.5's table (WS-22's `testUnanalyzedAssetsCarryTypedReasons`, WS-23's `testNewPhotoJoinsExistingGroupAsOneDisjointGroup`, WS-24's `testEveryUpdateCommitsAChronologicalPrefix` and `testPipelinePreservesGroupsAndOrder`), are rewritten to accumulate. Their assertions must hold on the accumulated values.
- **`PhotoScanUpdateDeltaTests`:**
  - `testYielderMergesDroppedPredecessors`: a real `AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1))`. Yield u1 (targets, E1, U1), u2 (E2), u3 (E3, groupsChanged), then finish. Iterating gives exactly one element with E1∪E2∪E3, U1, u1's targets, `groupsChanged == true` and u3's scalars.
  - `testMergeKeepsNewestScalarsAndGroups`.
  - `testReYieldRaceIsIdempotentForTheFold`: fold(u2) then fold(merged(u1, u2)) equals fold(u1) then fold(u2).
- **`AnalysisSnapshotBuilderTests`:**
  - `testDeltaFoldEqualsCumulativeFold`: copy today's cumulative fold into the test as a reference. For 100 seeded runs of 5–40 batches (with retried prior-unanalyzed IDs), both folds give identical evaluated, target and unanalyzed sets, ledgers and counts.
  - WS-16's golden builder literals are unchanged.
- **`PhotoResultsStoreTests`:**
  - `testMergeGateSkipsOnlyNoOpUpdates`: 500 seeded scenarios. Merging when the gate says "skip" never changes the output compared with merging anyway.
  - `testGateTriggersWhenNewIDTouchesPreservedGroup`.
- **Device:** see Device QA.

### Acceptance criteria
- [ ] Both golden tests are unchanged from the pre-change literal (final groups, keepers, deletes and actions are identical).
- [ ] Refreshes happen at least every 2,048 assets or 15 s during a scan (tests), and never while paused.
- [ ] Updates carry deltas. `testSlowConsumerLosesNoDeltas` passes. `targetAssetIDs` travels once and stays in checkpoints.
- [ ] Consumer per-update work is O(delta) except at refreshes (gate tests). Counts are recomputed only after merges.
- [ ] WS-08 end-to-end tests, WS-23 incremental and merge tests, WS-24 pipeline tests and WS-40 burst tests pass (accumulating where needed).
- [ ] Zero warnings, suite green, and `CLAUDE.md` and `BACKLOG.md` updated.
- [ ] The PR has device numbers: peak memory, `peak_edges`, `engine.regroup` p50/p99 and refresh intervals on a 50–60k library.

### Device QA
Add to `docs/DEVICE_QA.md` under "Engine at scale (WS-53)":
1. On a 50–60k library with dense events (an iPhone 12 or older if available), run a first Deep Clean with Instruments (Allocations, os_signpost, Time Profiler) for at least 30 minutes. Record:
   - peak memory and any memory warnings;
   - the DEBUG `peak_edges` value;
   - `engine.regroup` p50/p99;
   - the largest gap between `engine.refresh` events (must be ≤ 15 s plus one regroup);
   - main-thread hangs over 250 ms (must be none).
2. During the same run, confirm that "groups found" on Home changes at least every ~15 s in the second half of the scan.
3. If peak edges exceed 400k, or memory warnings appear, file the BACKLOG item for time-window finalization with these numbers.

### Pitfalls and out of scope
- **Invariant 17:** the stream stays `bufferingNewest(1)`, and drops merge. Chronological drain order and exactly-once watchdog slot release are untouched (WS-24).
- **Invariant 22:** the score stays `Double`, and `formClusters` logic stays byte-identical. Do not reorder edges or change tie-breaks.
- **Invariant 14:** checkpoints still record cumulative evaluated, target and unanalyzed sets. Only the transport changed.
- The WS-23 merge semantics must be reproduced exactly, with `affected = runEvaluated ∪ members(update.groups)` and **not** all context IDs.
- **Reconciliation:**
  - The field renames and deletions follow README §9 contract 15. WS-53.5's table lists every earlier test that must switch to accumulating.
  - This workstream adds **no** frontier-based edge pruning and **no** cluster freezing: every retained edge stays in `PhotoScanWorkingSet.edges` until the scan ends. WS-61 (chapter 13) relies on that for cross-date identical copies. If time-window finalization is ever built (BACKLOG), it must exempt `isIdenticalCopy` edges and keep WS-38's `ScreenshotHashIndex` (7 bands, in the working set) consistent with its evictions.
  - WS-61 later adds an `isIdenticalCopy` bit to `CompactPairEligibility.flags`. Keep `flags` a `UInt8` bitfield so that stays additive.
- **Out of scope:**
  - Window finalization and vDSP (BACKLOG).
  - The pair cache, already removed by WS-46.
  - Checkpoint cadence and size: WS-54.
  - Cross-date copies built on this engine: WS-61 (chapter 13).

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| SCAN-18 | partially | The verifier's correction holds: the maps are never pruned (`:549-550`, `:808-809`), there is a full regroup per refresh, and memory depends on edge density. The plan takes the cheaper first step: compact edges. Differences from the proposed fix: no `Float` score or blocker bitset (nothing reads edge blockers, and narrowing the score could reorder edges); time-window finalization is deferred to BACKLOG with a device trigger; vDSP is not adopted, because float accumulation could flip a threshold decision (invariant 22) for a small gain. WS-23 said WS-53 would own it; this defers it explicitly. |
| SCAN-19 | partially | The facts hold (`:846`, `:920-962`, `HomeViewModel.swift:1693-1714`). The magnitude is overstated because `bufferingNewest(1)` sheds updates, and the pair-cache part is stale after WS-46. The plan follows D-UPDATE-DELTAS with **renamed** fields, so the compiler finds every cumulative consumer. The consumer skips merges that are provably no-ops. WS-23's `affectedAssetIDs` and WS-22's `unanalyzedReasonCounts` move to the consumer. |
| SCAN-22 | confirmed | `nextThreshold` doubles (`:1915-1928`), and the last partial refresh at 60k is 32,768. The plan applies the proposed cap plus a 15 s trigger through an injected clock, and adds a "new work drained" condition so paused scans never regroup. It lands in the same PR as compact edges, as the verifier required. |

---

## WS-54 — Checkpoint and cache write cost

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M3 | L | WS-17, WS-47, WS-48, WS-52, WS-53 | no | `ws/54-checkpoint-write-cost` |

**Primary files:**
- **New code:** `iOSCleanup/Engines/PhotoAnalysisSnapshotDiskState.swift`, `iOSCleanup/Views/Home/ScanCheckpointPolicy.swift`.
- **Edited code:** `iOSCleanup/Engines/PhotoAnalysisCache.swift`, the apply site, `iOSCleanup/Views/Home/HomeViewModelDependencies.swift` (only if a seam is missing), `iOSCleanup/Utilities/PHAsset+FileSize.swift`, `iOSCleanup/Engines/FileScanEngine.swift`, `iOSCleanup/iOSCleanupApp.swift`, `iOSCleanup/Utilities/LRUCache.swift` (from WS-52; created here if WS-52 was cut).
- **Tests:** `iOSCleanupTests/PhotoAnalysisCacheTests.swift` (WS-17), `iOSCleanupTests/ScanCheckpointPolicyTests.swift` (*new*), `iOSCleanupTests/AssetFileSizeRepositoryTests.swift` (*new*, or the existing file-size tests in `FileScanEngineTests.swift`), `iOSCleanupTests/FileScanEngineTests.swift`, `iOSCleanupTests/AnalysisSnapshotBuilderTests.swift`, `iOSCleanupTests/ScalePerformanceTests.swift`.
- **Project and docs:** `iOSCleanup.xcodeproj/project.pbxproj`, `CLAUDE.md`.

**Findings covered:** SCAN-20 (P2, partially), PERF-06 (P2, confirmed), PERF-13 (P2, confirmed), PERF-12 (P3, confirmed)
**Decisions applied:**
- **D-SCAN-RESOURCES:** checkpoint when `elapsed ≥ max(20 s, 40 × last write time, bytes / 256 KB/s)` **and** (≥ 500 new photos or groups changed). Completion, pause and background always checkpoint (invariant 18).
- **Invariant 14:** single writer, generation ordering, newest-only pending writes, atomic writes, and a backup never overwritten by an older generation. WS-17's memo stays current, and WS-47's failure classification and `publishHealth` stay.
- **SCAN-20 long term:** the SQLite migration is post-v1 (BACKLOG).

### Goal
- A checkpoint write never decodes a snapshot, and it rotates the backup with a rename instead of rewriting it.
- Checkpoints happen only when worthwhile: a 60-minute 60k first scan writes under 1 GB of JSON in total.
- The snapshot is smaller: no derivable identifier array, no duplicate Deep Clean target array, and no escaped slashes.
- `asset-file-sizes-v1.json` is written at most once per 2 s, and flushed at the end of the video pass and on background.
- Video rescans read the size cache before touching `PHAssetResource`.
- Launch warm-up is O(n) with no evictions, and both file-size caches use the O(1) LRU.

### Current behavior (verified)
- **The write path decodes both files.** `PhotoAnalysisCache.swift:672-717`: for every checkpoint, the detached writer encodes the snapshot, then fully decodes the primary **and** the backup (`photoAnalysisCacheCandidate`, `:820-841`) only to compare generations. It then rewrites the backup with the old primary's bytes (`:697-700`) and writes the new primary. That is two full files written, and two decoded, per checkpoint.
- **Size cap.** `maximumCacheBytes = 64 MB` (`:491`). An oversized encode throws `snapshotTooLarge` (`:679`). WS-47 classifies it as `.snapshotTooLarge` with its own copy, so the failure is not silent.
- **Cadence.** `HomeViewModel.swift:9-13`: `periodicCheckpointInterval = 20`. `apply` returns a checkpoint every 20 s regardless of size or progress (`:1766-1776`). The worker flushes ML writes, then calls `scheduleSnapshot` (`:1178-1188`). The DEBUG-only `lastEncodeWriteDuration` and `lastEncodedByteCount` exist (`:505-511`).
- **Snapshot contents.** It encodes `libraryAssetIdentifiers` (`:46`) next to `libraryAssets` (`:47`); after WS-19 the identifiers are exactly `libraryAssets.map(\.localIdentifier)`. For Deep Clean, `scanTargetAssetIdentifiers` is the whole library. The decoder requires `libraryAssetIdentifiers` (`:244-247`). `JSONEncoder()` escapes every `/` in local identifiers.
- **WS-17's read path.** `loadNewestFromDisk()` decodes the primary and decodes the backup only when the primary is unusable or the backup's mtime is at least the primary's. WS-17's memo is set on successful writes.
- **File-size cache writes back to back.** `PHAsset+FileSize.swift`: every `store` (`:380`) calls `scheduleWrite()` (`:502`). That starts `beginWrite()` immediately, and `writeDidFinish` (`:542`) restarts it whenever `needsWrite` is set, so there is no coalescing window. After WS-30 the repository holds up to 60,000 entries in a file of up to 32 MB. `flush()` is at `:434`. `HomeViewModel.swift:1564` flushes on background.
- **Resources are enumerated before the cache is checked.** `representativeFile` (`:611`) calls `PHAssetResource.assetResources(for: self)` (`:613`) before the cache lookup (`:616`). The enumeration only feeds `displayName`, which `FileScanEngine` uses only for qualifying videos. WS-30 and WS-42 added the locality-revalidation and re-measure rules to this function.
- **Launch warm-up.** `warmMemoryCache()` (`:398-404`, called at `iOSCleanupApp.swift:29`) pushes every entry into the 2,048-entry front cache (`:296`), in hash order. Each store over capacity then evicts with `values.min(by:)` (`:316`), under the `NSLock` that main-thread `estimatedFileSize` takes. The repository's own `evictIfNeeded` (`:493`) was changed by WS-30 to one sort per overflow.
- **Performance tests to update.** WS-08 benchmark (6) wraps PERF-13 in `XCTExpectFailure(nonStrict)`. Benchmark (3) may wrap the 25 MB size assertion (SCAN-20/PERF-06).
- **Cleanup path.** WS-48's `AssetFileSizeRepository.removeAll()` does not know about a debounce task.

### Implementation plan

**WS-54.0 — `LRUCache`, only if WS-52 was cut (README §9 contract 19)**
- **Change:** if `iOSCleanup/Utilities/LRUCache.swift` does not exist because WS-52 was cut, land WS-52.1 exactly as written in WS-52 as this PR's **first commit**: the `LRUCache` type, the `PhotoImageRepository` switch and `LRUCacheTests`. Build nothing else from WS-52. Say in the PR that WS-52.1 landed here, so the lead can update the README status table.

**WS-54.1 — No decode on write, and zero-copy rotation (SCAN-20, PERF-06 item 1)**
- **Change:** new `iOSCleanup/Engines/PhotoAnalysisSnapshotDiskState.swift`:
  ```swift
  enum SnapshotSlotState: Equatable, Sendable {
      case absent, invalid                                  // missing; or corrupt, oversized or wrong schema
      case valid(generation: UInt64, savedAt: Date)
      case olderThanPrimary                                 // not decoded: backup mtime < primary mtime (WS-17 rule)
      case unknown                                          // never classified: treated as "may be newer"
  }
  struct PhotoAnalysisSnapshotDiskState: Equatable, Sendable {
      var primary: SnapshotSlotState = .unknown
      var backup: SnapshotSlotState = .unknown
      enum WritePlan: Equatable { case rotateThenWrite, writePrimaryOnly }
      /// Rotate only a valid primary, and never over a backup that is (or may be) newer.
      var plan: WritePlan {
          guard case .valid(let p, let pSaved) = primary else { return .writePrimaryOnly }
          switch backup {
          case .absent, .invalid, .olderThanPrimary: return .rotateThenWrite
          case .valid(let b, let bSaved): return (b, bSaved) <= (p, pSaved) ? .rotateThenWrite : .writePrimaryOnly
          case .unknown: return .writePrimaryOnly
          }
      }
      mutating func didWrite(_ plan: WritePlan, generation: UInt64, savedAt: Date, rotated: Bool)
  }
  ```
- **Change** in `PhotoAnalysisCache`:
  - Keep `private var diskState = PhotoAnalysisSnapshotDiskState()`.
  - WS-17's `loadNewestFromDisk()`, used by `loadSnapshot` and `hydrateDiskOrderingIfNeeded`, classifies **both** slots on every read:
    - a decoded file → `.valid`;
    - a missing file → `.absent`;
    - a failed decode, oversize or wrong schema → `.invalid`;
    - a backup skipped by the mtime rule → `.olderThanPrimary`.
  - `drainPendingSnapshots` passes `diskState.plan` into the detached writer. The writer then:
    1. Encodes with `PhotoAnalysisCache.makeSnapshotEncoder()` (WS-54.2).
    2. Checks the size (unchanged).
    3. For `.rotateThenWrite`: `try? fm.removeItem(at: backupURL)`, then `try fm.moveItem(at: fileURL, to: backupURL)` (a rename; no bytes copied). **If the move throws**, fall back to copying the primary's bytes without decoding (`Data(contentsOf:)` plus an atomic write to the backup). If that also fails, write the primary only.
    4. `try data.write(to: fileURL, options: .atomic)`.
  - Delete `photoAnalysisCacheCandidate` and `photoAnalysisCacheSnapshot(_:isNewerThan:)` if nothing else uses them.
  - The outcome keeps WS-47's `failure: PersistenceWriteFailureKind?` and adds `rotated: Bool` and `bytesWritten: Int` (new primary plus any fallback copy).
  - On success: `diskState.didWrite(…)`, where the backup becomes the old primary's state if rotated. Set WS-17's memo (unchanged rule), `publishHealth`, and the metrics (WS-54.3). On failure the disk state is unchanged, except that a successful rotation followed by a failed primary write sets `primary = .absent`, `backup = old primary`.
  - Inject file operations for tests: `struct SnapshotFileOperations: Sendable { var move, remove, write, readData }` with `.live`, added to `init(directoryURL:maximumCacheBytes:fileOperations:)` (defaulted).
  - WS-48's `removeAllSnapshots()` keeps its steps (drop the pending write, await idle, resume waiters, delete both files, purge WS-17's memo, keep `latestGeneration`) and also sets `diskState = PhotoAnalysisSnapshotDiskState(primary: .absent, backup: .absent)`, so the next write never tries to rotate a deleted file.
  - Add DEBUG `debugBytesWritten` and `debugRotationCount`.
- **Edge cases:**
  - **Crash windows are safe.** After the remove and before the move, only the primary exists. After the move and before the write, only the backup exists, and the read path decodes it. The atomic write uses a temp file and rename.
  - After a rename the backup keeps the old primary's mtime, which is older than the new primary's, so WS-17's primary-first read rule keeps working. No sidecar is needed.
  - `.unknown` should never occur after hydration. If it does, write the primary only and log it in DEBUG.

**WS-54.2 — Smaller snapshot encoding (SCAN-20 short term)**
- **Change** in `CachedPhotoAnalysisSnapshot`:
  - Add a custom `encode(to:)` that omits `libraryAssetIdentifiers`. It must write every other key the synthesized encoder wrote, including the additive ones from earlier workstreams. In particular, WS-37's `analyzerVersion` stamp is carried exactly: encoded when non-nil and omitted when nil, as the synthesized encoder did. It is never defaulted.
  - When `Set(scanTargetAssetIdentifiers) == Set(libraryAssets.map(\.localIdentifier))` (counts equal too), encode `scanTargetsCoverLibrary: true` instead of the `scanTargetAssetIdentifiers` array.
  - Decoding:
    - `libraryAssetIdentifiers = decodeIfPresent(...) ?? libraryAssets.map(\.localIdentifier)`;
    - if `scanTargetsCoverLibrary == true`, targets = `libraryAssets.map(\.localIdentifier)`; otherwise decode as today.
  - Keep `schemaVersion` 7; the change is additive for this build.
  - Add `static func makeSnapshotEncoder() -> JSONEncoder` in `PhotoAnalysisCache` with `outputFormatting = [.withoutEscapingSlashes]`, used by the writer and by WS-08 benchmark (3).
- **Edge cases:**
  - `hasConsistentCompletionState` (WS-17's stored flag, computed in `init(from:)`) sees the same union as before, so it is never loosened (invariant 14).
  - Older builds cannot decode a new file. Downgrades are unsupported (as in WS-30); say so in the PR.
  - WS-16's golden literals change: `libraryAssetIdentifiers` disappears, and Deep Clean goldens show the flag. Update them **in this PR** and explain each changed key.

**WS-54.3 — Write metrics and `ScanCheckpointPolicy` (PERF-06 item 2)**
- **Change:** in `PhotoAnalysisCache`, add `struct PhotoAnalysisCacheWriteMetrics: Sendable, Equatable { var duration: TimeInterval; var byteCount: Int; static let zero }`, stored in `private nonisolated let writeMetrics = OSAllocatedUnfairLock(initialState: PhotoAnalysisCacheWriteMetrics.zero)`, and `nonisolated func lastWriteMetrics() -> PhotoAnalysisCacheWriteMetrics`. The main actor reads it without an actor hop. Keep the DEBUG fields.
- **Change:** new `iOSCleanup/Views/Home/ScanCheckpointPolicy.swift`:
  ```swift
  enum ScanCheckpointPolicy {
      static let minimumInterval: TimeInterval = 20
      static let writeCostMultiplier: Double = 40
      static let sustainedBytesPerSecond: Double = 256 * 1_024
      static let minimumNewPhotos = 500
      struct Input: Equatable {
          var elapsedSinceLastCheckpoint: TimeInterval
          var lastWrite: PhotoAnalysisCacheWriteMetrics
          var processedSinceLastCheckpoint: Int
          var groupsChangedSinceLastCheckpoint: Bool
          var isDurabilityBoundary: Bool                    // completion, pause, background
      }
      static func minimumElapsed(for lastWrite: PhotoAnalysisCacheWriteMetrics) -> TimeInterval {
          max(minimumInterval, writeCostMultiplier * lastWrite.duration, Double(lastWrite.byteCount) / sustainedBytesPerSecond)
      }
      static func shouldCheckpoint(_ input: Input) -> Bool {
          if input.isDurabilityBoundary { return true }
          guard input.elapsedSinceLastCheckpoint >= minimumElapsed(for: input.lastWrite) else { return false }
          return input.processedSinceLastCheckpoint >= minimumNewPhotos || input.groupsChangedSinceLastCheckpoint
      }
  }
  ```
- **Change** at the apply site:
  - Replace the 20 s rule with `ScanCheckpointPolicy.shouldCheckpoint(…)`, where `isDurabilityBoundary = update.isComplete || isPaused`.
  - Track `lastCheckpointProcessedCount` and `groupsChangedSinceLastCheckpoint`. The latter is set when the photo-group set is reassigned and reset when a checkpoint is produced.
  - Delete `ScanPersistenceTuning`.
  - The pause, background, cancel and reconcile paths keep producing their checkpoints unconditionally (WS-16, WS-28).
  - The 3 s UserDefaults cadence is unchanged.
- **Edge cases:**
  - The first checkpoint of a run uses `.zero` metrics, so it waits 20 s and then needs 500 photos or a group change.
  - A crash loses at most about a minute and a few hundred photos of cheap-to-redo progress (D-SCAN-RESOURCES).

**WS-54.4 — Coalesced file-size writes (PERF-13)**
- **Change** in `AssetFileSizeRepository`:
  - `init(fileURL:maximumEntryCount:writeCoalescingDelay: Duration = .seconds(2), sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }, frontCache: AssetFileSizeCache = .shared)`. Make `AssetFileSizeCache` internal so tests can inject one.
  - Add `private var delayedWriteTask: Task<Void, Never>?`, `private var storeSequence: UInt64 = 0` (incremented by every mutation) and `private var writtenSequence: UInt64 = 0`.
  - `scheduleWrite()` sets `needsWrite = true`. If neither `writeTask` nor `delayedWriteTask` exists, it arms `delayedWriteTask = Task { [weak self, sleep, delay] in do { try await sleep(delay) } catch { return }; await self?.beginDelayedWrite() }`.
  - `beginDelayedWrite()` sets `delayedWriteTask = nil`, then calls `beginWrite()`.
  - `beginWrite()` captures `storeSequence` with its snapshot. On success, `writeDidFinish(writtenUpTo:)` sets `writtenSequence = max(…)`, and re-arms the **delayed** write if `needsWrite` is set. It is never immediate.
  - `flush()` does: `let target = storeSequence`; cancel and nil `delayedWriteTask`; then loop `while writtenSequence < target { if writeTask == nil { beginWrite() }; await writeTask?.value }`. Everything stored before `flush()` began is on disk when it returns.
  - WS-48's `removeAll()` also cancels `delayedWriteTask`.
  - Keep WS-08's DEBUG `debugCompletedWriteCount` and `debugBytesWritten`.
- **Change** in `FileScanEngine`:
  - Add `sizeRepository: AssetFileSizeRepository = .shared` to `init`, and use it for WS-30's `retain` and the default resolver.
  - At the end of the video scan loop (baseline `largePhotoAssets`, reached through WS-42's `scan(remeasureEstimates:onUpdate:)`), on success and on cancellation, `await sizeRepository.flush()`.
  - The background flush in the lifecycle code (`dependencies.fileSizeRepository.flush()`) stays.
- **Edge cases:** WS-30's `mergeFootprints` and batch APIs keep calling `scheduleWrite()` once per call; they are now coalesced too.

**WS-54.5 — Cache-first `representativeFile` and lazy display names (PERF-12 item 1)**
- **Change** in `PHAsset+FileSize.swift`:
  - Add `var displayName: String?` to `AssetFileSizeRecord` (synthesized `decodeIfPresent`; repository schema stays 1).
  - `PHAssetRepresentativeFile.displayName` becomes `String?`.
  - Add `struct AssetResourceCandidateProviding: Sendable { let candidates: @Sendable (PHAsset) -> [AssetResourceSizeCandidate]; static let live = … PHAssetResource.assetResources(for:) … }`.
  - Add `repository: AssetFileSizeRepository = .shared, resources: AssetResourceCandidateProviding = .live` as the last parameters of `representativeFile(…)`, keeping WS-30/42's parameters.
  - New order:
    1. Compute the cache key.
    2. `await repository.value(for:)`.
    3. If WS-30/42's rules (`RepresentativeCachePolicy.usesCachedRecord`, locality recheck) accept the record, return it with `displayName: cached.displayName` and **no** resource enumeration.
    4. Otherwise enumerate the candidates once, measure as today, and store the record **with** `displayName`.
  - Add `func representativeDisplayName(resources: AssetResourceCandidateProviding = .live) -> String` (`AssetResourceSizePolicy.displayFilename(from:mediaKind:)`), and `AssetFileSizeRepository.setDisplayName(_:for:)`, which updates an existing record and calls `scheduleWrite()`.
- **Change** in `FileScanEngine`: add `displayNameResolver: @escaping @Sendable (PHAsset) async -> String = { $0.representativeDisplayName() }` to `init`. For a qualifying file whose representative has `displayName == nil`, resolve the name, pass it to `LargeFile`, and backfill it with `setDisplayName`. Non-qualifying files never resolve a name.
- **Edge cases:**
  - WS-30's locality revalidation and WS-42's re-measure rules keep their semantics. Only the enumeration moves behind the cache decision.
  - A cached record with `displayName == nil` (legacy) is backfilled the first time it qualifies.

**WS-54.6 — O(1) LRUs, linear warm-up, front-cache capacity (PERF-12 items 2–3)**
- **Change:** `AssetFileSizeCache` uses `LRUCache<AssetFileSizeCacheKey, AssetFileSizeRecord>(countLimit: Self.defaultCapacity)` under its existing `NSLock`. `defaultCapacity = 8_192` is a tuning constant, raised from 2,048 only now that eviction is O(1) (FILES-24). Its memory cost is about 2 MB.
- **Change:** `AssetFileSizeRepository.entries` becomes `LRUCache<AssetFileSizeCacheKey, AssetFileSizeRecord>(countLimit: maximumEntryCount)`, replacing WS-30's sort-based `evictIfNeeded`.
  - **Persistence:** write `PersistentEntry`s in `keysFromLeastRecent()` order, with `accessOrdinal` equal to the position.
  - **Load:** sort by `accessOrdinal` ascending once and insert in that order. The file format is unchanged.
- **Change:** `warmMemoryCache()` takes `keysFromLeastRecent().suffix(2_048)` and inserts them oldest-first, so there are no evictions and the most recent entries win. WS-30's `warmMemoryCache(for:)` is unchanged.
- **Edge cases:** `retain(localIdentifiers:limitedTo:)` semantics are unchanged. Records with a nil `mediaKind` are never evicted by a scoped retain.

**WS-54.7 — Benchmarks and docs**
- **Change:**
  - Remove the PERF-13 `XCTExpectFailure` from WS-08 benchmark (6). Inject `writeCoalescingDelay: .seconds(3_600)`, so writes happen only at `flush()`, and assert `debugCompletedWriteCount == 1` after the flush at both sizes.
  - Remove any SCAN-20/PERF-06 size wrapper from benchmark (3), and encode with `makeSnapshotEncoder()`.
  - Add `testSnapshotEncodingAt150kFitsUnderCap`: 150,000 metadata rows plus 7,000 groups, encoded size < 64 MB. Record the size in the PR.
  - `CLAUDE.md` `PhotoAnalysisCache` row: "no decode on write; zero-copy backup rotation; cadence per `ScanCheckpointPolicy`". `AssetFileSizeRepository` row: "writes coalesced over 2 s; flushed at the end of the video pass and on background; O(1) LRU".
  - Add a `spec/BACKLOG.md` entry: "SCAN-20 long term: move inventory metadata and evaluated/unanalyzed sets to SQLite; JSON for groups only".

### Tests
All run in the simulator unless marked device.
- **`PhotoAnalysisCacheTests`** (temp directory per test):
  - `testSavesNeverDecodeOnWritePath`: an empty directory, then 3 saves: `debugDiskDecodeCount == 0`. A second instance over the resulting files hydrates with 1 decode (the primary), then 3 more saves leave the count at 1.
  - `testRotationKeepsPreviousGenerationAsBackup`: after 3 saves the backup holds generation n−1 and the primary holds n (decode both in the test), and `debugRotationCount == 2`.
  - `testBytesWrittenIsAboutOneSnapshotPerSave`: `debugBytesWritten` grows by the encoded size (±1%) per save.
  - `testNewerBackupIsNeverRotatedOver`: set up the recovery fixture where the backup's generation is newer than the primary's. A save writes the primary only, and the backup's bytes are unchanged.
  - `testFailedRenameFallsBackToCopy` (injected `move` throws): the backup holds the previous primary's bytes, and the new primary is written.
  - `testPrimaryWriteFailureAfterRotationStillRecovers` (injected `write` throws once): a fresh instance's `loadSnapshot()` returns the previous generation from the backup. `lastWriteFailure` is classified (WS-47).
  - `testMemoTracksLatestSuccessfulWrite` (WS-17 rule).
  - `testSnapshotOmitsDerivableIdentifiersAndRoundTrips`: the JSON has no `libraryAssetIdentifiers` key, and decoding reproduces the identifiers, targets and `hasConsistentCompletionState`.
  - `testDeepCleanTargetsEncodedAsFlagOnlyWhenEqual`.
  - `testCustomEncodingKeepsEveryOtherKeyIncludingAnalyzerVersion`: encode with the synthesized encoder (the pre-change copy kept in the test) and with the new one. The key sets differ only by `libraryAssetIdentifiers` and the Deep Clean target flag, and WS-37's `analyzerVersion` round-trips as 2 and as nil.
  - `testLegacySnapshotWithIdentifiersDecodes`.
  - `testLastWriteMetricsReadableFromMainActor`.
  - `testRemoveAllSnapshotsResetsDiskState`: after 2 saves, `removeAllSnapshots()` (WS-48), then 1 save. The primary exists, no backup exists, `debugRotationCount` did not grow, and WS-48's `testRemoveAllSnapshotsDropsPendingWriteAndResumesWaiters` still passes.
  - The existing WS-17 cache tests (`testCacheLoadChoosesNewerBackupGeneration`, `testSavePreservesNewerBackupBeforeReplacingPrimary`, `testCorruptCurrentCheckpointFallsBackToPriorValidGeneration`, `testFirstSaveHydratesExistingDiskGenerationBeforeEnqueue`, `testExplicitStaleGenerationCannotReplaceNewerSnapshot`) pass **unmodified**.
- **`ScanCheckpointPolicyTests`:**
  - `testDurabilityBoundariesAlwaysCheckpoint`.
  - `test25sWith2sWriteIsTooSoon` (80 s minimum).
  - `test90sWith1000NewPhotosCheckpoints` (5 MB last write).
  - `testGroupsChangedAloneSufficesAfterInterval`.
  - `testFewPhotosAndNoGroupChangeWaits`.
  - `testSixtyMinuteSixtyKSimulationWritesUnderOneGigabyte`: a pure simulation over 1 s steps. It processes 17 photos/s, the snapshot grows linearly to 22 MB, write duration = bytes / 40 MB/s, and groups change every 30 s. The sum of bytes over the checkpoints the policy allows is < 1 GB.
- **`AssetFileSizeRepositoryTests`** (temp `fileURL`, injected gate-based sleep):
  - `testStoresCoalesceIntoOneDelayedWrite`: 2,000 stores give `debugCompletedWriteCount == 0`. Release the sleep: exactly 1 write. Reloading from the file returns all 2,000 records.
  - `testWriteDidFinishRearmsDelayNotImmediate`.
  - `testFlushWritesImmediatelyAndCancelsDelayed`: releasing the old sleep afterwards produces no extra write.
  - `testFlushPersistsStoresMadeDuringInFlightWrite` (sequence guarantee).
  - `testRemoveAllCancelsDelayedWrite` (WS-48 API).
  - `testWarmKeepsTheMostRecent2048WithoutEvictions`: 10,000 stored in known order; the injected front cache holds exactly the last 2,048, and its eviction count is 0.
  - `testPersistedRecencyOrderSurvivesReload`.
  - `testRecordDecodesWithoutDisplayName`.
- **`FileScanEngineTests`:**
  - `testCachedNonQualifyingVideoEnumeratesNoResources`: seed a temp repository with a fresh-locality measured record under 50 MB. The counting `AssetResourceCandidateProviding` sees 0 calls, and the display-name resolver is not called.
  - `testCachedQualifyingVideoWithoutNameResolvesOnceAndBackfills`: the first scan calls the resolver once; the second scan calls it 0 times.
  - `testVideoPassFlushesSizeRepositoryAtEnd` (the repository's DEBUG write count increases by 1 after `scan` returns, with the delay injected large).
- **`AnalysisSnapshotBuilderTests`:** the golden literals are updated (WS-54.2) and every changed key is explained in the PR.
- **`ScalePerformanceTests`** (Performance plan): benchmarks (3) and (6) run without wrappers, plus the 150k size test.

### Acceptance criteria
- [ ] The write path contains no `JSONDecoder` (`grep` inside the writer and `drainPendingSnapshots`), and the no-decode test passes.
- [ ] The backup rotates by rename. A newer backup is never replaced. All WS-17 cache tests pass unmodified.
- [ ] `ScanCheckpointPolicy` governs periodic checkpoints. Pause, background and completion still produce a durable snapshot before returning (WS-08 and WS-28 tests). The 60-minute simulation stays under 1 GB.
- [ ] Snapshots omit `libraryAssetIdentifiers` and use the Deep Clean target flag. The 150k snapshot is under 64 MB.
- [ ] `asset-file-sizes-v1.json` writes are coalesced over 2 s and flushed at the end of the video pass and on background. The PERF-13 wrapper is gone and benchmark (6) is green.
- [ ] Cached video rescans enumerate `PHAssetResource`s only for qualifying videos missing a name. Warm-up keeps the 2,048 most recent without evictions. Both caches use `LRUCache`.
- [ ] Own footprint (M3 budget, README §9 contract 5): after a full scan of a 50k library, Storage & Data (WS-48) reports **≤ 160 MB**, recorded in `docs/DEVICE_QA.md` (Device QA 4). If it is over budget, `PhotoEmbeddingCachePolicy.capacity` was lowered from 10,000 in steps of 2,500 (never below 5,000) until it fits, and each step's measurement is recorded.
- [ ] Zero warnings, suite green, and `CLAUDE.md` and `BACKLOG.md` updated.

### Device QA
Add to `docs/DEVICE_QA.md` under "Disk writes (WS-54)":
1. **First Deep Clean on a 50–60k library for 60 minutes.** Sum the `checkpoint.write` signpost `bytes=` messages: the total must be < 1 GB. Record the checkpoint count and the largest snapshot size.
2. **Instruments File Activity during the first Large Videos pass on a 3,000+ video library.** `asset-file-sizes-v1.json` is written at most once per 2 s, and once at the end.
3. **Background the app mid-scan, force-quit from the app switcher, and relaunch.** The scan resumes from the last checkpoint (WS-28), and both snapshot files are present in the container.
4. **Record Storage & data (WS-48) after the full scan of a 50k library:** the total, plus the ML cache, both snapshot copies and the file-size cache (Download Container for the breakdown). The M3 budget is **≤ 160 MB** (README §9 contract 5). If the total is over budget, lower `PhotoEmbeddingCachePolicy.capacity` (WS-46, default 10,000) by 2,500, with a minimum of 5,000. Rescan, re-measure, and repeat until it fits or the minimum is reached. Record every step's capacity and total here and in the PR. If it is still over budget at 5,000, stop and report to the lead.
5. **Cold launch with 6,000+ cached video sizes.** The launch warm-up signpost (add a `sizes.warm` interval) is < 20 ms.

### Pitfalls and out of scope
- **Invariant 14 is the risk.** Never rotate over a backup that is, or may be, newer. Never let the memo hold something not on disk. Keep generation assignment in `enqueue` and WS-16's capture-sequence drop.
- **Invariant 18:** the policy applies only to periodic checkpoints.
- Keep WS-47's `failure` classification and `publishHealth` on every outcome, including the rename-fallback paths.
- `hasConsistentCompletionState` must see identical inputs after the encoding change. Test it.
- **Reconciliation:**
  - **No sidecar** (README §9 contract 21): slot state lives in the `PhotoAnalysisCache` actor, and the unread backup is classified by WS-17's primary-first mtime read rule. Rename rotation keeps the older mtime on the backup.
  - The firm order is WS-47 → WS-48 → WS-54, so WS-48 is listed as a dependency. The rewrite preserves WS-47's failure classification and `publishHealth`, WS-48's `PhotoAnalysisCache.removeAllSnapshots()` (which now also resets `diskState`) and `LargeVideoResultCache.removeAll()` (untouched here), and WS-48's `AssetFileSizeRepository.removeAll()`, which now also cancels WS-54.4's delayed write.
  - **Footprint budget:** ≤ 160 MB after a 50k scan, with the capacity-lowering rule in Device QA 4 (contract 5). It replaces the earlier 120 MB figure.
  - `LRUCache` comes from WS-52.1, or from WS-54.0 if WS-52 was cut (contract 19).
  - The custom snapshot encoder carries WS-37's `analyzerVersion` stamp unchanged (contract 14). No other snapshot field is dropped.
  - **Forward note:** WS-62 (chapter 13) adds `VideoInventoryCache` (`video-inventory-v1.json`, at most 20,000 fingerprints) under `PhotoDuckStorage`. It is written once per completed video pass with WS-27.1's serialized writes, is cleared by WS-48's reset, and counts toward this footprint. It is outside this workstream's coalescing.
- **Out of scope:**
  - The SQLite inventory migration (post-v1, BACKLOG).
  - The oversized-snapshot copy (WS-47, unchanged; the 64 MB cap stays).
  - ML cache design (WS-46). The only capacity change allowed here is the budget-driven step in Device QA 4.

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| SCAN-20 | partially | Both files are decoded on every write (`PhotoAnalysisCache.swift:672-717`, `:820-841`), and the 64 MB cap is at `:491`. Two corrections: the failure is not silent (WS-47 gives it its own copy), and the cap is reached nearer 180–200k assets. The plan applies the proposed short-term fix: slot state in the actor, with no sidecar, because WS-17's mtime read rule still classifies an unread backup; the identifier array dropped; the target flag. It adds unescaped slashes and a 150k size test. SQLite goes to BACKLOG. |
| PERF-06 | confirmed | 20 s size-blind cadence (`HomeViewModel.swift:9-13`, `:1766-1776`), a backup rewritten with the old primary's bytes (`:697-700`), and write metrics that are DEBUG-only. The plan follows the proposal: rename rotation when primary ≥ backup with a copy fallback, and the D-SCAN-RESOURCES policy with a non-DEBUG metrics read. It adds injectable file operations for crash-window tests and an explicit slot-state model so no decode is needed to choose the rotation. |
| PERF-13 | confirmed | No coalescing (`PHAsset+FileSize.swift:502-547`). It is worse after WS-30 raised the capacity to 60k entries and 32 MB. The plan follows the proposal (2 s delay, `flush` at the end of the pass and on background) and adds a store-sequence guarantee, so `flush` returns only when everything stored before it is on disk; the reviewer's version could return while a delayed write was still pending. |
| PERF-12 | confirmed | The resources are enumerated (`:613`) before the cache lookup (`:616`); warm-up is in hash order with O(n) evictions under the lock (`:296`, `:316`, `:398-404`). Item 4 (sliding window) was delivered by WS-24. The cache-first reorder keeps WS-30/42's locality and re-measure rules; display names are stored on miss and backfilled lazily. The front cache is raised to 8,192 only after O(1) eviction. |

---
