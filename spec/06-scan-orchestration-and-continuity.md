# Chapter 06 — Scan orchestration and continuity

> **Milestone(s):** M1 · **Workstreams:** WS-26 – WS-29 · Read `spec/README.md` first: operating rules, invariants, build/test commands and the decision log apply to every workstream here.

## Chapter overview

These four workstreams decide when a scan runs, in what order, and what happens when the user leaves the app, and they all edit the same lifecycle code. That is why they ship in one chapter and in strict order.

- **WS-26** separates scans the user started from automatic ones. The "Scan complete" sheet stops popping up after launch or library-change scans, and a full-library rescan needs an explicit, confirmed tap. Granting Photos access in onboarding starts the first scan.
- **WS-27** checks large videos first on every user-started scan, keeps their results fresh, and never locks photo review while videos are being sized. Large videos are usually most of the reclaimable bytes.
- **WS-28** fixes the run lock across pause and resume. It pauses the engine cleanly after a complete checkpoint when the app goes to the background, resumes on return, and resumes interrupted scans at relaunch without a tap.
- **WS-29** keeps the screen awake during foreground scans and uses `BGContinuedProcessingTask` on iOS 26. "Notify me" is offered only when a background continuation actually exists.

When the chapter is done, a 40k-photo iCloud library gets its first gigabytes of video results within about a minute of tapping Start. The scan survives auto-lock, app switches and relaunches, and the app never promises background work it cannot do.

The key risk is concurrency. Invariant 13 (run lock and completion barrier), invariant 16 (photo and video scans never load PhotoKit at the same time) and invariant 19 (a user's explicit Pause is sticky) are all touched here. Every task below states how it preserves them.

Line numbers below are the 2026-09-27 baseline (before WS-07 … WS-25 land). Re-find code by the quoted text; several bodies will have moved into the small types created by WS-15, WS-16, WS-18 and WS-21.

---

## WS-26 — User-initiated vs automatic scans and first-scan auto-start

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M1 | M | WS-17, WS-21 | no | `ws/26-scan-origins` |

**Primary files:** `iOSCleanup/Views/HomeViewModel.swift`, `iOSCleanup/Views/Home/ScanOrigin.swift` (*new*), `iOSCleanup/Views/Home/CompletionPresentationPolicy.swift` (*new*), `iOSCleanup/Views/Home/FirstScanAutoStartPolicy.swift` (*new*), `iOSCleanup/Views/HomeView.swift`, `iOSCleanup/Views/Home/CompletionOverlay.swift` (moved there by WS-10), `iOSCleanup/Views/PhotoDuckShellView.swift`, `iOSCleanup/Views/OnboardingView.swift`, `iOSCleanupTests/ScanOriginPolicyTests.swift` (*new*), `iOSCleanupTests/HomeViewModelTests.swift`, `iOSCleanup.xcodeproj/project.pbxproj`
**Findings covered:** VALUE-16 (P2, confirmed; merged: UI-20), UI-19 (P2, confirmed), FSB-13 (P3, confirmed)
**Decisions applied:**
- D-SCAN-CONTINUITY: granting access in onboarding auto-starts the first scan as a *user-initiated* scan, and a first-scan auto-start never counts as a user pause. The owner was asked to confirm; if there is no answer, proceed with the default and say so in the PR.

### Goal
- The "Scan complete" sheet appears only after scans the user started. It never collides with another Home sheet, dialog or alert.
- Automatic scans (launch, library change) complete silently. When they add groups, a small toast says so.
- Only the confirmed gear-menu "Scan Again" rebuilds the whole library. Every other button runs an incremental pass.
- A new user who grants access in onboarding lands on a running scan.

### Current behavior (verified)
- `iOSCleanup/Views/HomeView.swift:213-218` presents the sheet on any false→true flip:
  `.onChange(of: viewModel.activeScanRunIsComplete) { if isComplete, isHomeTabSelected, viewModel.lastCompletedAt != nil { … showCompletion = true } }`.
  Nothing checks who started the scan.
- `HomeViewModel.swift:498-504, 514-522`: `activeScanRunIsComplete = scanState == .completed && !isFinalizingPhotoScan && !isFinishingSupportingScans`. It flips false→true in four situations:
  - Every run of `scanPhotos`. The lock is set at `:935` and cleared by the completion barrier at `:1241`.
  - The no-work path. `:1036` sets `.completed` and `:1057` clears the lock while the state stays `.completed`.
  - The supporting video pass (`:1796` true, `:1807` false). The sheet can therefore pop twice per run.
- Automatic callers of `scanPhotos`:
  - The bootstrap Task `HomeViewModel.swift:324-330` → `scanNewPhotosIfNeeded()` (`:1921-1946`, calls `scanPhotos` at `:1943`).
  - `reconcilePhotoLibraryChange()` → `scanPhotos` at `:1913-1915`.
  - After WS-19 and WS-21 there are also the post-run follow-up `scanNewPhotosIfNeeded()` and the `libraryChangedDuringRun` reconcile.
- `HomeView.swift` stacks many presentations on one `NavigationStack` with no queueing:
  - 4 `.sheet`s: paywall `:122`, completion `:125`, review `:139`, diagnostics `:147`.
  - 3 `.confirmationDialog`s: `:150`, `:162`, `:177`.
  - 2 `.alert`s: `:192`, `:200`.
- `restartPhotoScan()` (`HomeViewModel.swift:837-853`):
  - `.paused` → resume.
  - Otherwise it loads the snapshot. An incomplete snapshot gets an incremental pass; complete or nil gets `scanPhotos(mode: lastCompletedMode ?? .deepClean, forceFullRescan: true)`.
  - What a forced pass does:
    - `preservedGroups/Screenshots/Blurry = []` (`:1062-1064`).
    - `screenshotAssets`/`blurryAssets` are emptied (`:1101-1102`).
    - The first `apply` replaces `photoGroups` (`:1725-1727`).
  - WS-17 fixes only the CTA phantom-rescan path: the restore-window guard, so a tap before restore finishes cannot force a rescan. Per README contract 1, it does **not** turn the gear "Scan Again" into a no-op. It notes that this workstream replaces `restartPhotoScan`. Re-read WS-17's landed code (grep `RestartScanPolicy`) before editing.
- `restartPhotoScan()` has four callers, and none of them asks for confirmation:
  - Home CTA `HomeView.swift:446` ("Scan again" when there are 0 groups and 0 unanalyzed; the subtitle at `:391` says "runs a fresh photo scan").
  - `CompletionOverlay` "Scan Again" (`HomeView.swift:1063-1067`).
  - Similar `.freshScan` (`PhotoDuckShellView.swift:199-200`).
  - Gear "Scan Again" (`PhotoDuckShellView.swift:248`).
- Onboarding and first launch:
  - `OnboardingView.swift:99-105` requests authorization and calls `onNext()` on `.authorized`/`.limited`.
  - `:107` shows "Continue" when access is already granted; `:109` is "Skip for now".
  - `ContentView.swift:12-21` then shows the shell, whose `.onAppear` calls `bootstrapLibraryStateIfNeeded()`.
  - With no snapshot, `scanNewPhotosIfNeeded` only refreshes metadata (`:1929-1933`), so no scan starts.
  - ROADMAP.md:75 (playbook #4) asks for exactly this auto-start; ROADMAP.md:21 lists it as deferred.

### Implementation plan

**WS-26.1 — `ScanOrigin` and entry points**
- **Why:** The view model cannot tell a user's scan from an automatic one, and no seam says which buttons may force a full rescan.
- **Change:** Create `iOSCleanup/Views/Home/ScanOrigin.swift`:
  ```swift
  enum ScanOrigin: String, Codable, Sendable { case userInitiated, automatic }

  enum PhotoScanPassKind: Equatable, Sendable { case incremental, fullRescan }

  /// Every control that can start a photo scan. Only the confirmed gear
  /// action may force a full-library rescan (UI-19).
  enum PhotoScanEntryPoint: CaseIterable, Sendable {
      case homePrimaryCTA            // idle "Start scan", 0-group "Scan again"
      case scanFailureRetry          // HomeView scanFailureBanner "Retry"
      case similarPrimaryAction      // Similar dock/empty-state .freshScan
      case completionSheetScanAgain  // CompletionOverlay "Scan Again"
      case onboardingFirstScan       // FSB-13 auto-start
      case gearRescanConfirmed       // gear "Scan Again" after confirmation

      var origin: ScanOrigin { .userInitiated }
      var passKind: PhotoScanPassKind {
          self == .gearRescanConfirmed ? .fullRescan : .incremental
      }
  }

  struct AutomaticScanNotice: Equatable, Identifiable, Sendable {
      let id: UUID
      let checkedPhotoCount: Int
      let newGroupCount: Int
      var message: String {
          let photos = checkedPhotoCount == 1 ? "photo" : "photos"
          let groups = newGroupCount == 1 ? "group" : "groups"
          return "Checked \(checkedPhotoCount.formatted()) new \(photos) · \(newGroupCount.formatted()) new \(groups)"
      }
      /// nil unless the automatic run added at least one group.
      static func make(checkedPhotoCount: Int, groupsBefore: Int, groupsAfter: Int) -> AutomaticScanNotice?
  }
  ```
  `make` returns nil when `groupsAfter - groupsBefore <= 0` or `checkedPhotoCount <= 0`.
- **Edge cases:** WS-31 later moves the copy into its formatter (`CountText`). Keep this string in one place so WS-31 can swap it.

**WS-26.2 — Thread the origin through `scanPhotos` and publish a completion token**
- **Why:** The sheet must follow *who started the run*, not a Bool that every run toggles (VALUE-16, UI-20).
- **Change** (`HomeViewModel.swift`):
  1. Change the signature to `scanPhotos(mode:allowNetworkAccess:forceFullRescan:retryUnanalyzed:origin:)`. `origin` has **no default**, so every call site must choose. Keep the `origin` parameter in scope where `scanPhotos` calls `PhotoScanResumePlanner.requiredAssetIDs`: WS-37 (chapter 08) reads `origin == .userInitiated` there as `AnalyzerUpgradePolicy`'s `isUserInitiated` (README contract 14).
  2. Add `private var activeScanOrigin: ScanOrigin = .automatic`. Assign it right after the run-lock guard claims the run (after `isFinalizingPhotoScan = true`, baseline `:935`). Also capture `let groupCountAtRunStart = photoGroups.count` as a local next to `progressOffset`, so the worker closure can use it for the notice.
  3. **Upgrade rule.** In the lock guard (baseline `:931`, `guard !isFinalizingPhotoScan else { return }`), if the caller is `.userInitiated`, set `activeScanOrigin = .userInitiated` before returning. A user tap during an automatic run then still gets the completion sheet for the run already in progress.
  4. Add `@Published private(set) var completedUserScanToken: UUID?` and `@Published private(set) var automaticScanNotice: AutomaticScanNotice?`.
  5. In the worker's completion block (baseline `:1192-1243`), keep every existing statement and its order. Add the issuance **after** `self.isFinalizingPhotoScan = false; self.persistCleanupState()`:
     ```swift
     switch self.activeScanOrigin {
     case .userInitiated:
         self.completedUserScanToken = UUID()
     case .automatic:
         self.automaticScanNotice = AutomaticScanNotice.make(
             checkedPhotoCount: self.processedPhotoCount - progressOffset,
             groupsBefore: groupCountAtRunStart,
             groupsAfter: self.groupsFoundCount)
     }
     ```
     Issuing the token last guarantees the sheet's first render reads the stamped `lastCompleted*` values.
  6. On the no-work path (baseline `:1030-1059`), after the lock is cleared and state is persisted: if `activeScanOrigin == .userInitiated`, set `completedUserScanToken = UUID()`. **DECISION (owner may override):** a user-started refresh that finds nothing new still shows the completion sheet summarizing current results, so the tap always gets feedback.
  7. Map each caller to an origin:

     | Caller | Origin |
     |---|---|
     | `refreshPhotoScan`/`rescanEntireLibrary` (26.4) | `.userInitiated` |
     | `retryIncludingICloudPhotos` | `.userInitiated` |
     | the new-run branch of `resumeDeepClean` | `.userInitiated` |
     | `scanNewPhotosIfNeeded` | `.automatic` |
     | `reconcilePhotoLibraryChange` | `.automatic` |
     | WS-19's post-run call | `.automatic` |
     | WS-21's follow-up reconcile | `.automatic` |

     The in-place branch of `resumeDeepClean` (the user tapped Continue) also sets `activeScanOrigin = .userInitiated`.
  8. Keep `activeScanRunIsComplete` and its static; WS-27 edits them. After this workstream, nothing in `HomeView` observes it.
- **Edge cases:**
  - A superseded run never issues a token: the completion block is already fenced by `activeScanID == scanID`.
  - Failure and cancellation issue nothing.
  - Never issue the token before the barrier (invariant 13).

**WS-26.3 — Present only for user scans, and queue behind other presentations**
- **Why:** UI-20. SwiftUI refuses a second sheet while one is up, so `showCompletion` stays true while nothing is shown.
- **Change:** Create `iOSCleanup/Views/Home/CompletionPresentationPolicy.swift`:
  ```swift
  enum CompletionPresentationDecision: Equatable { case present, queue, drop }

  enum CompletionPresentationPolicy {
      static func decide(isHomeSelected: Bool,
                         isCompletionAlreadyPresented: Bool,
                         isOtherPresentationActive: Bool) -> CompletionPresentationDecision {
          guard isHomeSelected, !isCompletionAlreadyPresented else { return .drop }
          return isOtherPresentationActive ? .queue : .present
      }
  }
  ```
  `HomeView.swift` changes:
  - Delete the `.onChange(of: viewModel.activeScanRunIsComplete)` block (`:213-218`).
  - Add `@State private var hasQueuedCompletion = false`.
  - Add a computed `isOtherPresentationActive`, true when any of these is set: `showPaywall`, `showReviewResults`, `diagnosticShareItem`, `showICloudScanConfirmation`, `showNotificationPrePrompt`, `showNotificationSettingsAlert`, `showDiagnosticsDisclosure`, `diagnosticExportError`.
  - Observe `completedUserScanToken`:
    - `.present`: `DuckHaptics.success(); showCompletion = true`.
    - `.queue`: `hasQueuedCompletion = true`.
    - `.drop`: nothing.
  - `.onChange(of: isOtherPresentationActive)`: when it becomes false while `hasQueuedCompletion && isHomeTabSelected`, clear the flag. Then `Task { @MainActor in await Task.yield(); showCompletion = true }` so the previous sheet finishes dismissing first.
  - `.onChange(of: isHomeTabSelected)`: when it becomes false, clear `hasQueuedCompletion`.
  - **DECISION (owner may override):** if Home is not the selected tab when a user scan completes, the sheet is dropped (same as today). The Similar tab already shows live results, so a sheet popping up much later when the user returns to Home would surprise them.
  - Add an automatic-scan toast. `.onChange(of: viewModel.automaticScanNotice)` stores it in `@State private var visibleNotice: AutomaticScanNotice?` only when Home is selected. Render `DuckToast(style: .info, message: notice.message)` in `.overlay(alignment: .top)` with `DuckSpace` padding, and clear it with `.task(id: visibleNotice?.id)` after 3 s. The 3 s sleep is UI-only; no test depends on it.
- **Edge cases:**
  - The review-after-completion flow (`openReviewAfterCompletion`, `:125-138`) keeps working. `showCompletion` is part of `isCompletionAlreadyPresented`, not of `isOtherPresentationActive`, so its dismissal does not replay the queue.
  - Do not restyle `CompletionOverlay`; WS-31 owns its content.

**WS-26.4 — Split `restartPhotoScan` into incremental and confirmed-full entry points (UI-19)**
- **Why:** One tap must never discard results and start hours of re-analysis.
- **Change** (`HomeViewModel.swift`): delete `restartPhotoScan()`, so no forced path is reachable by accident, and add:
  ```swift
  func startPhotoScan(from entry: PhotoScanEntryPoint) {
      switch entry.passKind {
      case .incremental: refreshPhotoScan()
      case .fullRescan: rescanEntireLibrary()
      }
  }
  func startDeepClean() { startPhotoScan(from: .homePrimaryCTA) }   // keeps existing callers

  /// The canonical incremental, user-initiated entry point. Internal, not private: WS-31 and WS-45
  /// call `viewModel.refreshPhotoScan()` directly for "Check for new photos" / "Scan again".
  func refreshPhotoScan() {
      if scanState == .paused { resumeDeepClean(); return }
      Task(priority: .utility) {
          await scanPhotos(mode: lastCompletedMode ?? .deepClean, origin: .userInitiated)
      }
  }

  private func rescanEntireLibrary() {
      guard scanState != .scanning, scanState != .paused else { return }
      Task(priority: .utility) {
          await restoreCachedAnalysisIfNeeded()   // WS-17: never plan from an unhydrated window
          await scanPhotos(mode: lastCompletedMode ?? .deepClean,
                           forceFullRescan: true, origin: .userInitiated)
      }
  }
  ```
  `rescanEntireLibrary()` stays `private` and has **no** early return when groups exist (README contract 1): the user explicitly confirmed a rebuild, and it is reachable only through `startPhotoScan(from: .gearRescanConfirmed)`. `scanPhotos` itself still awaits the restore before planning. WS-17's CTA protection is now structural, because no CTA path can force a rescan. If WS-17's `RestartScanPolicy` (`Views/Home/RestartScanPolicy.swift`) has no caller left once `restartPhotoScan` is deleted, delete it and its pure tests in the same commit. The restore-window CTA no-op (WS-15's `.restoringResults`) stays.

  Call sites (the enum case follows each path):

  | Screen | Location | New call |
  |---|---|---|
  | `HomeView` | `handleCTAAction` `.scanFailure, .idlePrompt` | `startDeepClean()` (unchanged) |
  | `HomeView` | the `else` branch that called `restartPhotoScan()` | `viewModel.startPhotoScan(from: .homePrimaryCTA)` |
  | `HomeView` | `scanFailureBanner` Retry | `startPhotoScan(from: .scanFailureRetry)` |
  | `CompletionOverlay` | "Scan Again" | `viewModel.startPhotoScan(from: .completionSheetScanAgain)` |
  | `PhotoDuckShellView` | `performPrimaryAction` `.freshScan` | `viewModel.startPhotoScan(from: .similarPrimaryAction)` |

  Change the `HomeView` CTA subtitle at `:391` from "No photo issues found · runs a fresh photo scan" to "No photo issues found · checks new photos".

  Gear menu (`PhotoDuckShellView.swift:248`):
  - `Button("Scan Again")` now sets `@State private var showRescanConfirmation = true`.
  - Add a `.confirmationDialog("Rescan your whole library?", isPresented: $showRescanConfirmation, titleVisibility: .visible)` with:
    - `Button("Rescan Library", role: .destructive) { viewModel.startPhotoScan(from: .gearRescanConfirmed) }`
    - `Button("Cancel", role: .cancel) {}`
  - Message:
    - `n > 0`: "Your current \(n) \(n == 1 ? "group" : "groups") will be rebuilt. Large libraries can take a long time."
    - `n == 0`: "Your current results will be rebuilt."
  - Keep the existing `.disabled(...)` conditions. WS-27 changes `isCompletingActiveScan`.
  - Keep WS-12's temporary "Reset Kept Photos (n)" item and its confirmation directly below "Scan Again" (README contract 22). WS-48 moves it to Help & Privacy later. The two confirmation dialogs use separate `@State` flags.
- **Edge cases:**
  - `retryIncludingICloudPhotos` still forces a full pass for legacy failure records. That path is already confirmed through the iCloud dialog; leave it alone.
  - Keeping old results visible during a forced rescan (UI-19 item 3) is out of scope; the confirmation covers it.

**WS-26.5 — First scan auto-starts after onboarding grants access (FSB-13)**
- **Why:** Time to first value on the most important session.
- **Change:**
  1. Create `iOSCleanup/Views/Home/FirstScanAutoStartPolicy.swift`:
     ```swift
     enum FirstScanAutoStartPolicy {
         static let pendingFlagKey = "photoduck.pendingFirstScan"
         static func shouldAutoStart(pendingFlag: Bool, hasSnapshot: Bool,
                                     scanState: HomeViewModel.ScanState,
                                     authorization: PHAuthorizationStatus) -> Bool {
             pendingFlag && !hasSnapshot && scanState == .idle
                 && (authorization == .authorized || authorization == .limited)
         }
     }
     ```
  2. `OnboardingView.swift`, `PhotoPermissionStep`: add `@AppStorage(FirstScanAutoStartPolicy.pendingFlagKey) private var pendingFirstScan = false`.
     - In the request branch (`:101-104`), set `pendingFirstScan = true` just before `onNext()` when the result is `.authorized` or `.limited`.
     - **DECISION (owner may override):** in the "Continue" branch (`:107`, access already granted), also set the flag when `status` is `.authorized`/`.limited`.
     - Never set it on "Skip for now" or on denial.
     - This is a functional change only; do not restyle (design handoff pending).
  3. `HomeViewModel`: add `private func startFirstScanIfPending() async`. Call it inside the bootstrap Task right after `scanNewPhotosIfNeeded()` (and after the restores and any WS-20 state reconciliation). It:
     - reads the flag through the injected defaults (`HomeViewModelDependencies.defaults` from WS-07; live is `.standard`, which `@AppStorage` also uses);
     - **always clears the flag** (one-shot) whenever authorization is determined;
     - evaluates the policy with `hasSnapshot: await analysisCache.loadSnapshot() != nil` (memoized by WS-17), and calls `startPhotoScan(from: .onboardingFirstScan)` when it is true.
- **Edge cases:**
  - If the app is killed between the grant and Home appearing, the flag is still set, so the next launch starts the scan.
  - Under Limited access (WS-20) no snapshot is ever written. Clearing the flag prevents a scan on every launch.
  - If WS-48 (STORE-05) stops asking for access in onboarding, the flag is simply never set.
  - WS-27 applies its videos-first order to this start, and WS-29 applies its idle timer. WS-29 deliberately does **not** request a background continuation for it (see WS-29.4).

### Tests
All tests run in the simulator.
- `iOSCleanupTests/ScanOriginPolicyTests.swift` (*new*, pure, no doubles):
  - `testOnlyConfirmedGearRescanIsFullRescan`: iterates `PhotoScanEntryPoint.allCases`. Asserts `.fullRescan` only for `.gearRescanConfirmed`.
  - `testEveryEntryPointIsUserInitiated`.
  - `testCompletionPresentsWhenHomeSelectedAndNothingElseShown` → `.present`.
  - `testCompletionQueuesBehindOtherPresentation` → `.queue`.
  - `testCompletionDroppedWhenHomeNotSelected` and `testCompletionDroppedWhenAlreadyPresented` → `.drop`.
  - `testAutomaticNoticeOnlyWhenGroupsIncrease`:
    - 5 checked, groups 3→4 gives a notice whose message is "Checked 5 new photos · 1 new group".
    - 3→3 gives nil; 0 checked gives nil.
  - `testFirstScanAutoStartTable`:
    - true for (flag, no snapshot, `.idle`, `.authorized`) and for `.limited`;
    - false when the flag is unset, a snapshot exists, the state is `.scanning`/`.paused`/`.completed`, or authorization is `.denied`/`.restricted`/`.notDetermined`.
- `iOSCleanupTests/HomeViewModelTests.swift`, using the WS-07/WS-08 harness:
  - Setup: WS-07's `makeIsolatedDependencies(assets:analyzer:authorization:)` (`iOSCleanupTests/Support/HomeViewModelTestHarness.swift`), which already provides the temp `UserDefaults` suite, temp caches, `observesPhotoLibrary: false`, the injected `authorizationStatus` and `makePhotoScanEngine` returning `PhotoScanEngine(assetProvider: StubPhotoScanAssetProvider(assets:), assetAnalyzer:, mlBridge: <isolated>)` over `ConfigurablePhotoScanTestAsset`s.
  - Library reads go through WS-18's `PhotoLibraryInventory`, built from `HomeViewModelDependencies.librarySource`. Inject a fake `PhotoLibrarySource` over the same assets. If a read `scanPhotos` needs is still not injectable, add the missing provider to `HomeViewModelDependencies` with a live default (README contract 16). That is test plumbing only.
  - Tests:
    - `testAutomaticScanNeverIssuesCompletionToken`: seed a completed snapshot, add 2 new asset IDs to the stub, run the automatic path (`scanNewPhotosIfNeeded` via bootstrap, or a test hook that calls `scanPhotos(..., origin: .automatic)`). Assert `completedUserScanToken == nil` and `automaticScanNotice != nil` exactly when groups grew.
    - `testUserScanIssuesTokenAfterCompletionStamp`: subscribe to `$completedUserScanToken` with `.dropFirst()`. In the sink, assert `viewModel.lastCompletedAt` is later than the pre-run value and `viewModel.isFinalizingPhotoScan == false`.
    - `testUserRequestDuringAutomaticRunUpgradesOrigin`: gate the analyzer (continuation-released) so an automatic run is in flight, call `startPhotoScan(from: .homePrimaryCTA)`, release the gate, and assert a token is issued.
    - `testRefreshNeverClearsExistingGroups`: seed a complete snapshot with 2 groups and an unchanged stub library. Call `startPhotoScan(from: .similarPrimaryAction)`. Assert `photoGroups.count == 2` throughout (sink) and that a token is issued (no-work path).
    - `testBootstrapAutoStartsFirstScanWhenFlagSet`: set the flag in the temp suite, no snapshot, authorization stub `.authorized`. Assert the engine factory was invoked and the flag is cleared.
    - `testBootstrapClearsFlagWithoutScanWhenSnapshotExists`.
  - Poll with a deadline helper (WS-06/BUILD-10); no fixed sleeps.

### Acceptance criteria
- [ ] Automatic scans (launch with new photos, library-change reconcile, WS-19/WS-21 follow-ups) never present `CompletionOverlay`. Covered by `testAutomaticScanNeverIssuesCompletionToken`.
- [ ] User-started scans present the sheet exactly once per run, after `lastCompletedAt` is stamped. It queues behind any open Home sheet, dialog or alert, and is dropped when Home isn't selected.
- [ ] `restartPhotoScan` no longer exists. Only `PhotoScanEntryPoint.gearRescanConfirmed` reaches `forceFullRescan: true`, and it is reachable only through the confirmation dialog.
- [ ] Granting Full or Limited access in onboarding lands on Home with a scan running. "Skip for now" and denial leave Home idle.
- [ ] All new files are in `project.pbxproj`; zero warnings; the full suite is green.
- [ ] `ios-cleanup/CLAUDE.md` (ViewModel layer) documents:
  - scan origins;
  - that only the confirmed gear rescan forces a full pass;
  - the `photoduck.pendingFirstScan` one-shot flag.

### Device QA
Add to `docs/DEVICE_QA.md` under "Scan orchestration". In the simulator, use WS-07's fixture analyzer launch argument.
1. Delete the app, install, onboard, and tap "Allow Photos Access" → Allow Full Access. Home must show a running scan without a tap.
2. Repeat, choosing "Skip for now". Home must be idle, showing "Start scan".
3. With a completed scan, take 3 photos, force-quit and relaunch. The scan must complete without showing "Scan complete". At most a top toast appears, and only if a group was added.
4. Start a scan, open the paywall before it finishes, and wait for completion. "Scan complete" must appear only after the paywall is dismissed.
5. Similar tab → gear → "Scan Again". The confirmation must show the current group count; Cancel changes nothing.

### Pitfalls and out of scope
- **Invariant 13:** the token is issued after the barrier, never before. Do not move `isFinalizingPhotoScan = false`.
- `@AppStorage` and the injected defaults must be the same store in Release (`.standard`). Assert it in a comment where the live dependency is built.
- The copy and content of the completion sheet, hero and notifications belong to WS-31 (chapter 07). Notification routing and the rule that automatic scans must not post alerts are also WS-31; this workstream only supplies `activeScanOrigin`.
- Videos-first ordering is WS-27; the idle timer and background continuation are WS-29.
- **Reconciliation (README contract 1):** `restartPhotoScan` is deleted here and split into `refreshPhotoScan()` (incremental, user-initiated, **internal** so WS-31/WS-45 can call it) and `rescanEntireLibrary()` (private, forced, confirmed gear action, no early return). WS-17 keeps only its CTA restore-window fix. `RestartScanPolicy` is deleted if it has no caller left.
- **Reconciliation (README contract 14):** `scanPhotos`'s `origin` argument is the user/automatic flag that WS-37's analyzer-upgrade rule reads at the planner call site.
- **Reconciliation (README contract 16):** tests reuse WS-07's harness and WS-18's `librarySource` seam. Add a `HomeViewModelDependencies` field only if a read is still not injectable, and give it a production default.
- **Forward note (WS-45, chapter 09):** the Home CTA "Scan again" action (`HomeCTAAction.scanAgain`) calls `refreshPhotoScan()`, the same incremental entry point as the completion sheet's "Scan Again".
- **Reconciliation (README contract 22):** the gear menu edited in 26.4 also holds WS-12's temporary "Reset Kept Photos (n)" item directly below "Scan Again". Keep it, with its own confirmation.

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| VALUE-16 | confirmed | Also flips on the no-work path (`:1030-1059`) and again after the supporting pass (`:1796/:1807`), so the sheet can pop twice. The plan uses a token issued after the barrier instead of a published `lastScanOrigin` Bool. The toast appears only when groups were added. |
| UI-20 (merged) | confirmed | 4 sheets, 3 confirmation dialogs and 2 alerts share one NavigationStack. The queue watches all of them, not only sheets. |
| UI-19 | confirmed | An earlier WS-17 draft made the old `restartPhotoScan` a no-op when groups exist, which would silently break the gear action; README contract 1 limits WS-17 to the CTA restore-window fix. The plan deletes `restartPhotoScan` and splits it into `refreshPhotoScan` and `rescanEntireLibrary`. It also fixes the CTA subtitle that promised "a fresh photo scan". Optional item 3 (keep old results visible during a forced rescan) is not done. |
| FSB-13 | confirmed | The policy lives in its own file rather than as a static on HomeViewModel. The flag is also set on onboarding's "Continue" when access is already granted (DECISION). The auto-start is a normal user-initiated start, so WS-27 and WS-29 apply, except for the background continuation. |

---

## WS-27 — Videos first, always fresh, never blocking photo review

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M1 | L | WS-10, WS-16, WS-26 | no | `ws/27-videos-first` |

**Primary files:** `iOSCleanup/Views/Home/LargeVideoScanController.swift` (from WS-16), `iOSCleanup/Views/HomeViewModel.swift`, `iOSCleanup/Views/Home/FileScanDecision.swift` (*new*), `iOSCleanup/Views/Home/LargeVideoFreshnessPolicy.swift` (*new*), `iOSCleanup/Views/Files/LargeVideoListState.swift` (*new*), `iOSCleanup/Engines/FileScanEngine.swift`, `iOSCleanup/Engines/PhotoScanEngine.swift`, `iOSCleanup/Engines/ScanPauseGate.swift` (from WS-24), `iOSCleanup/Engines/PhotoLibraryInventory.swift` (from WS-18; read-only consumer of its `videoCount` and `onVideosInserted`, no edit), `iOSCleanup/Views/Files/FileResultsView.swift` and the WS-10 split files (`LargeVideoReviewModel.swift`, `LargeVideoRowViews.swift`), `iOSCleanup/Views/HomeView.swift`, `iOSCleanup/Views/PhotoDuckShellView.swift`, tests: `iOSCleanupTests/FileScanDecisionTests.swift` (*new*), `iOSCleanupTests/LargeVideoFreshnessPolicyTests.swift` (*new*), `iOSCleanupTests/LargeVideoListStateTests.swift` (*new*), `iOSCleanupTests/LargeVideoScanControllerTests.swift` (from WS-16), `iOSCleanupTests/FileScanEngineTests.swift`, `iOSCleanupTests/PhotoScanEngineTests.swift`, `iOSCleanupTests/HomeViewModelTests.swift`
**Findings covered:** VALUE-01 (P1, confirmed; merged: FSA-02), FILES-02 (P1, confirmed), STATE-04 (P2, confirmed), STATE-14 (P3, confirmed)
**Decisions applied:**
- D-RESULTS-FRESHNESS: only the photo durability window locks completion; the video pass never locks photo review.
- D-SCOPE: "videos-first plus freshness" is v1.

### Goal
- A user-started scan checks large videos first, bounded to about 90 s. Videos then stay fresh after 6 h, on a video-count change, on missing saved results, and when new videos are recorded.
- Photo review (Home CTA, Duck Mode dock, gear actions) stays usable during any video pass.
- Files never says "No videos over 100 MB were found" unless a video scan actually completed.
- "Check Videos Now" always gives visible feedback.
- Photo and video scans still never load PhotoKit at the same time.
- The large-video results file always equals the in-memory snapshot.

Land it as 8 commits in the task order below; each leaves the suite green.

### Current behavior (verified)
- **Lock:**
  - `HomeViewModel.swift:524-531` `isScanCompletionLocked` returns `isFinishingSupportingScans || (scanState == .completed && isFinalizingPhotoScan)`.
  - `:514-522` `isScanRunComplete` also requires `!isFinishingSupportingScans`.
  - `startSupportingScansAfterSuccessfulPhotoScan` (`:1788-1819`) holds `isFinishingSupportingScans = true` for the whole `FileScanEngine` run.
  - While it is true, all of these are disabled:
    - the Home CTA ("Finishing video scan…", `HomeView.swift:354-357`, `.disabled(viewModel.isCompletingActiveScan)` `:423`);
    - the Similar dock button (`PhotoDuckShellView.swift:488`);
    - the empty-state button (`:517-520`);
    - the gear menu's Smart Cleanup and Scan Again (`:243-253`).
  - The complete photo snapshot is already durable at `:1181`.
  - `PhotoScanEngineTests.swift:1319-1372` pins this behavior.
- **Gating:**
  - Supporting scans start only if `scanState == .completed, !isFinalizingPhotoScan, processedPhotoCount >= scanTargetCount, (scanTargetCount > 0 || knownLibraryAssetIdentifiers.isEmpty), (analyzedPhotoCount > 0 || knownLibraryAssetIdentifiers.isEmpty)` (`:1334-1344`). A run where Vision failed for every photo therefore never scans videos (RT-1 shows exactly that in the simulator).
  - `scanFiles` starts with `guard !isFinalizingPhotoScan, scanState != .scanning else { return }` (`:1378-1381`), which applies even to `force: true`. It then returns unless `force || fileScanState` is `.idle`/`.failed`/`.paused` (`:1383-1388`).
  - Nothing sets `fileScanState` back to `.idle`. Assignments are only at `:1397`, `:1411`, `:1418`, `:1441`, `:1459`, `:2162`.
- **Restore:** `performCachedLargeVideoRestore` (`:2152-2180`) sets `fileScanState = .completed` even when every cached identifier is missing ("No large videos in the saved scan.").
- **Callers:**
  - The Files tab calls `scanFiles()` with force false (`PhotoDuckShellView.swift:80-86`).
  - The supporting pass calls `scanFiles()` with force false (`:1784`).
  - The reconcile only removes deleted IDs from `largeFiles` (`:1884`).
- **Files UI:** `FileResultsView.swift:525-603` `resultsContent` has no `.idle`/`.paused`/`.failed` branch. `visibleFiles.isEmpty` renders `EmptyStateView(title: "No Large Videos", message: "No videos over 100 MB were found.")` with "Scan Videos Again" (`:573-586`), which calls `onRefresh` → `scanFiles(force: true)` and hits the silent guard.
- **Home tile:** the Large Videos tile (`HomeView.swift:701-731`) is not tappable at count 0 (no `navigatesWhenEmpty`). `largeVideoCategoryNote` shows "Waiting for scan" for `.idle` (`:897-914`).
- **`LargeVideoResultCache`** (`FileScanEngine.swift:294-435`):
  - `load()` sets `hasLoaded = true` *before* `await Task.detached { decode }` (`:313-334`). A concurrent caller gets `nil`, and a `save` that runs during the await is overwritten by the older decode.
  - `save` (`:377-410`) and `remove` (`:412-435`) each start an unordered detached write.
  - `remove` works on the value returned by `await load()`, which can be stale after the suspension, and re-stamps `savedAt: Date()`, which would defeat any age-based freshness.
- **Photo engine pause:** `PhotoScanEngine.pause()` (`:379-386`) sets a flag and flushes ML writes. It does not wait for in-flight analyses. WS-24 replaces the polling with a reason-set `ScanPauseGate` (`pause(_ reason: ScanPauseReason)`/`resume(_:)`/`waitIfPaused()`, reason `.user`). Its sliding window parks only at `drainPoint()` and exposes `inFlightAnalysisCount` and `isInAnalysisLoop`. WS-25 adds `ScanPauseReason.thermal` for thermal suspension.
- **After WS-16:** the `scanFiles` body, `largeFiles`, `fileScanState`, `fileScanProgress` and the `FileScanEngine` factory live in `LargeVideoScanController` (`runScan(force:) -> Outcome`, `restoreIfNeeded(authorization:)`, `removeFile(assetID:)`, `pruneFiles(keeping:)`); `HomeViewModel` keeps pass-throughs. After WS-18, `PhotoLibraryInventory` retains image and video `PHFetchResult`s and exposes the video count (`videoCount`) and a video-insert signal (`onVideosInserted`, from `changeDetails.insertedObjects`) (README contract 3).

### Implementation plan

**Serialization rules** (invariant 16). Every task below must keep these true:
- **R1.** A video pass never runs while a photo engine is analyzing. If `activePhotoScanEngine != nil`, the video pass first holds the engine's `.videoPass` pause reason *with quiesce* (27.4), and releases it when the pass ends.
- **R2.** A photo engine never analyzes while a video pass runs:
  - Automatic photo scans do not start while a video pass or a user scan sequence is running. They set `libraryChangedDuringRun = true` (WS-21's flag) and return.
  - User-initiated `scanPhotos` takes the run lock, then awaits the running pass.
  - An in-place resume awaits the running pass before `engine.resume`.
- **R3.** The video pass is single-flight. `fileScanState == .scanning` means "skip", and waiters use `LargeVideoScanController.waitForCurrentPass()`.
- **R4.** The end of *any* video pass (pre-pass, explicit refresh, insertion rescan, tab visit, freshness or deferred request) runs WS-21's single deferred follow-up when `libraryChangedDuringRun` is set (README contract 4). Concretely, `runVideoPass` ends with `if libraryChangedDuringRun, !isPhotoRunActive, scanState != .scanning, scanState != .paused { await runPostRunFollowUpIfNeeded() }`, WS-19/WS-21's function that captures and clears the flag. Use `isFinalizingPhotoScan` until WS-28 renames it. If WS-21 gave it a `runSucceeded:` parameter, pass `false`, so a video pass alone never starts an incremental scan when the flag is clear.
  - A pass that ran while a photo run was active or paused (the transparent `.videoPass` pause) leaves the flag set; that photo run's own end handles it (WS-21.5: a paused run has not ended).
  - After the pre-pass, any automatic scan the reconcile starts defers again (`userScanTask != nil`), so the user's photo run picks the flag up at its end.
  - The post-photo (supporting) pass is the exception: WS-19.4's existing call at the end of the supporting-scan task *is* its follow-up. `runVideoPass` skips R4 for `trigger == .afterPhotoRun`, so it never runs twice.

**WS-27.1 — `LargeVideoResultCache`: single-flight load, revision guard, serialized writes (STATE-14)**
- **Why:** Concurrent load, save and remove can return nil, drop a newer save, or land older content last on disk.
- **Change** (`FileScanEngine.swift`, `actor LargeVideoResultCache`):
  ```swift
  private var revision = 0
  private var inFlightLoad: (task: Task<CachedLargeVideoSnapshot?, Never>, startRevision: Int)?

  func load() async -> CachedLargeVideoSnapshot? {
      if hasLoaded { return cachedSnapshot }
      let pending = inFlightLoad ?? {
          let url = fileURL
          let entry = (Task.detached(priority: .utility) { Self.decodeSnapshot(at: url) }, revision)
          inFlightLoad = entry
          return entry
      }()
      let decoded = await pending.task.value
      if !hasLoaded {                               // no save/remove happened meanwhile
          if revision == pending.startRevision { cachedSnapshot = decoded }
          hasLoaded = true
      }
      inFlightLoad = nil
      return cachedSnapshot
  }

  func save(files: [LargeFile], totalVideoCount: Int) { commit(/* snapshot built as today, savedAt: Date() */) }

  func remove(assetIdentifier: String) async {
      _ = await load()                              // the only suspension point
      guard let current = cachedSnapshot else { return }   // read AFTER the await
      let remaining = current.results.filter { $0.assetIdentifier != assetIdentifier }
      guard remaining.count != current.results.count else { return }
      commit(CachedLargeVideoSnapshot(schemaVersion: current.schemaVersion,
                                      savedAt: current.savedAt,     // scan time, not removal time
                                      totalVideoCount: max(current.totalVideoCount - 1, 0),
                                      results: remaining))
  }

  private func commit(_ snapshot: CachedLargeVideoSnapshot) {
      revision += 1; cachedSnapshot = snapshot; hasLoaded = true
      Self.write(snapshot, to: fileURL)   // synchronous, .atomic, createDirectory; errors ignored as today
  }
  ```
  `decodeSnapshot(at:)` and `write(_:to:)` are `nonisolated static` helpers that hold the existing decode, schema check and write code. The file is kilobytes; after WS-42's v2 it is still bounded, so a synchronous write on the actor is acceptable.
- **Add** `savedAt: Date` to `RestoredLargeVideoResults` (set it from `snapshot.savedAt` in `restoreFiles()`), for 27.5.
- **Edge cases:**
  - `save` is no longer `async`. Callers keep `await` because it is an actor hop.
  - The re-save of a pruned restore (`:2173-2178`, now in the controller) must keep `savedAt` too. Add `save(files:totalVideoCount:savedAt:)` with a default of `Date()`, and pass `restored.savedAt` there.

**WS-27.2 — Relax the review lock and add `isVideoPassRunning` (STATE-04)**
- **Why:** Photo results are durable before the video pass; locking review on it hides the payoff at the moment of highest intent.
- **Change:**
  1. `HomeViewModel.swift` statics. Drop the supporting parameter from both:
     ```swift
     nonisolated static func isScanRunComplete(scanState: ScanState, isFinalizingPhotoScan: Bool) -> Bool {
         scanState == .completed && !isFinalizingPhotoScan
     }
     nonisolated static func isScanCompletionLocked(scanState: ScanState, isFinalizingPhotoScan: Bool) -> Bool {
         scanState == .completed && isFinalizingPhotoScan
     }
     var isVideoPassRunning: Bool { isFinishingSupportingScans || fileScanState == .scanning }
     ```
     Add to `LargeVideoScanController`: `var progressLabel: String`, which is "Checking large videos… \(processed.formatted())/\(total.formatted())", or "Checking large videos…" while `total == 0`.
  2. `HomeView.swift` `ctaTitle`, for `.completedResultsAvailable, .reviewReadyPartialResults`:
     - `isCompletingActiveScan` → "Finishing photo scan…";
     - otherwise `totalGroups > 0` → "Review \(totalGroups) groups ready";
     - otherwise the existing retry / "Scan again" copy.
  3. `ctaSubtitle`:
     - `isCompletingActiveScan` → "Saving the completed photo results";
     - `isVideoPassRunning` → `viewModel.videoPassProgressLabel` (a pass-through to `progressLabel`);
     - then the existing lines.
  4. `heroDetailText` (`.completedResultsAvailable`): replace `if isFinishingSupportingScans` with `if isVideoPassRunning`, keeping the same text source.
  5. `PhotoDuckShellView`: no code change is needed. Its `.disabled(viewModel.isCompletingActiveScan)` uses now cover only the durability window. Leave "Scan Again" disabled while `scanState == .scanning || .paused` as today.
  6. Diagnostics keep the `isFinishingSupportingScans` JSON key of `PhotoDuckDiagnosticReportSnapshot` (`SharedHelpers.swift`; built by WS-15's `makeDiagnosticReport()`) and feed it `isVideoPassRunning` (README contract 29). Do not rename the key.
  7. The completion sheet already presents at photo durability through WS-26's token. Verify nothing waits for `isFinishingSupportingScans`.
- **Edge cases:**
  - A photo scan the user starts from the gear during a supporting pass: `scanPhotos` currently cancels `supportingScansTask` without waiting (`:948-951`). Change it to cancel and `await` the task before continuing (R2).
  - Automatic callers never reach that line; see 27.5.

**WS-27.3 — Pure policies: decision, freshness, list state**
- **Why:** Every "should the video scan run, and what should Files say" question becomes a tested table instead of guards scattered around the code.
- **Change:** Create `iOSCleanup/Views/Home/FileScanDecision.swift`:
  ```swift
  enum FileScanTrigger: Equatable, Sendable {
      case userExplicit, userScanPrePass, afterPhotoRun, tabVisit,
           automaticFreshness, libraryVideoInsertions, deferredRequest
      var isExplicit: Bool { self == .userExplicit || self == .userScanPrePass || self == .deferredRequest }
  }
  enum PhotoRunPhase: Equatable, Sendable { case none, preparingOrFinalizing, scanning, paused }
  enum FileScanDecision: Equatable, Sendable { case run, runPausingPhotoScan, deferred, skip }

  enum FileScanDecisionPolicy {
      static func decide(trigger: FileScanTrigger, photoPhase: PhotoRunPhase,
                         fileScanState: HomeViewModel.ScanState,
                         rescanReason: LargeVideoRescanReason?) -> FileScanDecision {
          if fileScanState == .scanning { return .skip }                    // R3
          guard trigger.isExplicit || rescanReason != nil else { return .skip }
          switch photoPhase {
          case .none, .paused: return .run                                   // R1 applied at run time
          case .scanning: return trigger == .userExplicit ? .runPausingPhotoScan : .deferred
          case .preparingOrFinalizing: return .deferred
          }
      }
      /// VALUE-01: no `analyzedPhotoCount > 0` clause.
      static func shouldRunPostPhotoVideoPass(scanState: HomeViewModel.ScanState, isPhotoRunActive: Bool,
                                              processedCount: Int, targetCount: Int, libraryIsEmpty: Bool) -> Bool {
          scanState == .completed && !isPhotoRunActive && processedCount >= targetCount
              && (targetCount > 0 || libraryIsEmpty)
      }
  }

  enum UserScanStep: Equatable, Sendable { case videos, photos }
  enum UserScanPlan {
      static func steps(rescanReason: LargeVideoRescanReason?, forceVideoPass: Bool) -> [UserScanStep] {
          (rescanReason != nil || forceVideoPass) ? [.videos, .photos] : [.photos]
      }
  }
  ```
  Create `iOSCleanup/Views/Home/LargeVideoFreshnessPolicy.swift`:
  ```swift
  enum LargeVideoRescanReason: String, Equatable, Sendable {
      case neverScanned, lastScanIncomplete, savedResultsMissing, videoCountChanged, resultsOlderThanMaxAge
  }
  enum LargeVideoFreshnessPolicy {
      static let maxResultAge: TimeInterval = 6 * 60 * 60
      static let prePassTimeBudget: Duration = .seconds(90)
      static let insertionDebounce: Duration = .seconds(10)
      static func rescanReason(fileScanState: HomeViewModel.ScanState, hasCompletedVideoScan: Bool,
                               lastScannedAt: Date?, now: Date, scannedTotalVideoCount: Int?,
                               currentVideoCount: Int?, restoredMissingResultCount: Int) -> LargeVideoRescanReason? {
          switch fileScanState {
          case .scanning: return nil
          case .paused, .failed: return .lastScanIncomplete
          case .idle, .permissionRequired: return .neverScanned
          case .completed: break
          }
          guard hasCompletedVideoScan, let lastScannedAt else { return .neverScanned }
          if restoredMissingResultCount > 0 { return .savedResultsMissing }
          if let current = currentVideoCount, let scanned = scannedTotalVideoCount, current != scanned { return .videoCountChanged }
          if abs(now.timeIntervalSince(lastScannedAt)) > maxResultAge { return .resultsOlderThanMaxAge }
          return nil
      }
  }
  ```
  Create `iOSCleanup/Views/Files/LargeVideoListState.swift`:
  ```swift
  enum LargeVideoListState: Equatable {
      case permissionRequired, notScannedYet, waitingForPhotoScan, scanning, paused, failed, empty, results
      static func resolve(fileScanState: HomeViewModel.ScanState, hasCompletedVideoScan: Bool,
                          isVideoScanDeferred: Bool, fileCount: Int) -> LargeVideoListState {
          if fileScanState == .permissionRequired { return .permissionRequired }
          if fileCount > 0 { return .results }            // banners cover scanning/paused over results
          switch fileScanState {
          case .scanning: return .scanning
          case .paused: return .paused
          case .failed: return .failed
          case .completed where hasCompletedVideoScan: return .empty
          default: return isVideoScanDeferred ? .waitingForPhotoScan : .notScannedYet
          }
      }
  }
  ```
- **Edge cases:**
  - Do **not** add FILES-02's trigger "restored files are empty while the video count > 0". A user with videos but none of 100 MB or more would rescan on every check. Missing saved results and count changes already cover restored devices.
  - A clock change backwards is caught by `abs(...)`.

**WS-27.4 — Engine: reason-aware pause with quiesce and acknowledgment**
- **Why:** R1 needs the photo engine to stop starting analyses *and* finish its in-flight ones before a video pass touches PhotoKit. WS-28 reuses the same call to write a background checkpoint that equals the engine's committed count.
- **Change:**
  1. `ScanPauseGate.swift` (WS-24). The gate is already reason-set based (README contract 2): `pause(_ reason: ScanPauseReason)`/`resume(_:)`, open only when the set is empty, with `.user` (WS-24) and `.thermal` (WS-25). Add only `case videoPass` to `ScanPauseReason`; WS-28 adds `.background`. Do not restructure the gate. A video pass can never lift a thermal or user pause, because waiters resume only when the set is empty.
  2. `PhotoScanEngine.swift`:
     ```swift
     struct PhotoScanPauseAck: Equatable, Sendable {
         /// Engine-relative drained count; equals `committedProcessedPhotoCount`
         /// of the last update yielded before parking.
         let committedProcessedCount: Int
         /// false when the quiesce timeout elapsed with analyses still in flight.
         let quiesced: Bool
     }
     func pause(reason: ScanPauseReason, quiesceTimeout: Duration?) async -> PhotoScanPauseAck
     func resume(reason: ScanPauseReason) async
     func pause() async { _ = await pause(reason: .user, quiesceTimeout: nil) }   // existing API
     func resume() async { await resume(reason: .user) }
     ```
     Add a `quiesceSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }` parameter to `PhotoScanEngine.init`. It is used only for the quiesce timeout; tests inject a sleep that never returns until released. It is separate from WS-25's `sleep: (UInt64)` pacing parameter, so the two labels do not collide.

     Semantics, implemented on WS-24's drain point (README contract 2). This workstream adds `private var pendingQuiesce` (waiting callers plus a deadline flag) and `private(set) var lastYieldedCommittedCount`, set at every yield:
     - `pause` closes the gate for `reason`.
     - If `!isInAnalysisLoop` (planning, `makeGroups` outside the loop, retention, finished), return immediately with `lastYieldedCommittedCount` and `quiesced: true`.
     - Otherwise WS-24's step 2 already stops top-ups, because the gate is closed. Extend only `drainPoint()`: while a quiesce is pending, `inFlightAnalysisCount > 0` and the deadline has not passed, it returns **without parking**. The loop keeps receiving and draining finished results in index order through the unchanged per-asset block, which never parks.
     - When `inFlightAnalysisCount` reaches 0, or the deadline has passed, `drainPoint()` yields one `PhotoScanUpdate` if anything was drained since the last yield, records the ack, resumes the pause callers, and parks on `waitWhilePaused()`.
     - Race the timeout inside `pause` itself, because the loop may be blocked in `group.next()` behind a hung analysis. On expiry, `pause` marks the deadline passed and returns `quiesced: false` with `lastYieldedCommittedCount`. The next drain point then parks without waiting for in-flight work.
     - `pause` then awaits `mlBridge.flushBufferedWrites()` as today.
     - A nil `quiesceTimeout` keeps today's semantics (no wait for in-flight); the ack is still returned once the loop parks.
     - Concurrent `pause` calls share the same park.
- **Edge cases:**
  - The engine must never report more committed than it yielded (invariant 17: strict order, bounded stream, each watchdog slot released exactly once).
  - `scanPhotos` currently resumes the old engine before cancelling it (`:945-947`). With cancellation-aware waiters, cancellation alone unparks it. Keep a `resume(reason: .user)` there only if WS-24 left it.

**WS-27.5 — `scanFiles(trigger:)`, controller freshness state, deferral and the post-photo pass (VALUE-01, FILES-02)**
- **Why:** No path may silently bail, results must refresh on their own, and a run in which Vision analyzed nothing must still scan videos.
- **Change:**
  1. `LargeVideoScanController` additions:
     ```swift
     @Published private(set) var lastScannedAt: Date?          // restore: savedAt; scan completion: now
     @Published private(set) var hasCompletedVideoScan = false // true after a completed scan, or a restore with missingResultCount == 0
     private(set) var scannedTotalVideoCount: Int?             // fileScanProgress.totalVideoCount at completion/restore
     private(set) var restoredMissingResultCount = 0           // cleared by the next completed scan
     @Published private(set) var isVideoScanDeferred = false
     private var currentPassTask: Task<Outcome, Never>?
     private(set) var passGeneration: UInt64 = 0               // README contract 24: fences writes after a clear
     init(..., videoCountProvider: @escaping @MainActor () -> Int? = { nil }, sleep: ...)   // nil = skip the count check; keeps WS-16's tests compiling
     func rescanReason(now: Date) async -> LargeVideoRescanReason?
     func run(budget: Duration?) async -> Outcome   // replaces WS-16's runScan(force:); same Outcome; single-flight via currentPassTask
     func waitForCurrentPass() async
     func setDeferred(_ deferred: Bool)     // sets/clears the status message too
     /// WS-48's Storage & Data "Clear": bump the generation, cancel the running pass and await it.
     func invalidateAndCancelCurrentPass() async
     ```
     - `run(budget:)` replaces WS-16's `runScan(force:)`. The `force` flag is gone because `FileScanDecisionPolicy` now decides. It returns WS-16's `Outcome` and keeps WS-20's injected `canPersist` check before every `resultCache.save`/`remove` (Limited access never writes).
     - **Generation fence (README contract 24).** `run` captures `let generation = passGeneration` at entry. Before every `resultCache.save`/`remove` and every assignment to published results (`largeFiles`, `fileScanState`, `fileScanProgress`, `lastScannedAt`, `hasCompletedVideoScan`, `scannedTotalVideoCount`) it checks `generation == passGeneration` and drops the write otherwise. `invalidateAndCancelCurrentPass()` does `passGeneration &+= 1; currentPassTask?.cancel(); _ = await currentPassTask?.value`. A pass that started before WS-48's Clear therefore can never write `large-video-results.json` or publish results after it. WS-48's `stopAllRunsForLocalDataClear` calls it instead of adding its own `videoScanGeneration`.
     - `videoCountProvider` reads WS-18's `PhotoLibraryInventory.videoCount` (README contract 3; use WS-18's landed name if it differs). The facade passes `{ [inventory] in inventory.videoCount }`. It is nil before the first refresh and while authorization is not determined; the inventory already applies invariant 20. There is no direct `PHAsset.fetchAssets` fallback: WS-40's `PhotoFetchLintTests` forbids `options: nil`, and the inventory is the single PhotoKit reader.
     - `hasCompletedVideoScan` is **not** set by a restore whose results are all missing.
     - Under Limited access (WS-20) the cache is not written. The restore finds nothing, so `neverScanned` triggers a cheap pass per launch; that is acceptable.
  2. `HomeViewModel` facade. Replace `scanFiles(force:)` with:
     ```swift
     func scanFiles(trigger: FileScanTrigger) async {
         await restoreCachedLargeVideosIfNeeded()
         let reason = await largeVideoScanController.rescanReason(now: Date())
         let decision = FileScanDecisionPolicy.decide(trigger: trigger, photoPhase: photoRunPhase,
                                                     fileScanState: fileScanState, rescanReason: reason)
         recordDiagnostic(.videoScanRequested(force: trigger.isExplicit, previousState: fileScanState.rawValue))
         switch decision {
         case .skip: return
         case .deferred: largeVideoScanController.setDeferred(true)
             // message: "Videos will be checked when the photo scan pauses or finishes"
         case .run, .runPausingPhotoScan: await runVideoPass(trigger: trigger)
         }
     }
     private var photoRunPhase: PhotoRunPhase {
         if scanState == .paused { return .paused }
         if scanState == .scanning, activePhotoScanEngine != nil { return .scanning }
         return isFinalizingPhotoScan ? .preparingOrFinalizing : .none
     }
     ```
     `runVideoPass(trigger:)` does, in order:
     - `setDeferred(false)`;
     - `if let engine = activePhotoScanEngine { _ = await engine.pause(reason: .videoPass, quiesceTimeout: .seconds(10)) }` (R1);
     - `let outcome = await largeVideoScanController.run(budget: trigger == .userScanPrePass ? LargeVideoFreshnessPolicy.prePassTimeBudget : nil)`, then handle `outcome` exactly as WS-16's `scanFiles(force:)` facade did (`.permissionRequired(message)` sets `scanErrorMessage` and `photoAuthorizationStatus`);
     - `await engine?.resume(reason: .videoPass)`;
     - R4 (skipped for `.afterPhotoRun`; see the serialization rules).

     The engine stays parked afterwards if the user paused it meanwhile (`.user` is still held).
  3. **Post-photo pass.** At baseline `:1334-1344`, replace the condition with `FileScanDecisionPolicy.shouldRunPostPhotoVideoPass(...)`, and make `scanSupportingCategoriesIfNeeded` call `scanFiles(trigger: .afterPhotoRun)`.
  4. **Replay deferred requests.** When a photo run reaches any terminal state (completed, failed, permission, cancelled) or the user pauses (after the pause checkpoint), and `isVideoScanDeferred` is set, call `scanFiles(trigger: .deferredRequest)`. For the completed case the post-photo pass already does it; do not run it twice.
  5. **Automatic photo scans defer to video work (R2).** At the top of `scanPhotos`, before the lock guard:
     ```swift
     if origin == .automatic, isVideoPassRunning || userScanTask != nil {
         libraryChangedDuringRun = true; return      // R4 replays it once the pass ends
     }
     ```
     `scanNewPhotosIfNeeded` gets the same early return.
  6. **User-initiated `scanPhotos`.** After claiming the lock, do `supportingScansTask?.cancel(); await supportingScansTask?.value` (27.2), then `await largeVideoScanController.waitForCurrentPass()` (R2).
  7. **Video inserts.** Consume WS-18's `PhotoLibraryInventory.onVideosInserted` (README contract 3). Do not edit the inventory. WS-18 defines and fires it through `PhotoLibraryInventory.applyVideoChange(_:)` (from the retained video fetch result's `changeDetails.insertedObjects`, or a count increase when there are no details). WS-21.3's change consumer calls that method. If WS-18 landed under other names, use them; do not add a second hook.
     - `HomeViewModel` sets it to call `largeVideoScanController.scheduleInsertionRescan()`. That debounces with `insertionDebounce` (injected sleep), then calls a closure provided by `HomeViewModel` that runs `scanFiles(trigger: .libraryVideoInsertions)`.
     - Removals never trigger a rescan; WS-21's pruner handles them.
  8. **Call sites:**
     - Files tab `onChange(of: selectedTab)` → `scanFiles(trigger: .tabVisit)`.
     - Both `FileResultsView` `onRefresh` closures (Home tile destination and Files tab) → `scanFiles(trigger: .userExplicit)`.
     - The Home tile destination also gets `.task { await viewModel.scanFiles(trigger: .tabVisit) }`.
     - The end of the bootstrap Task (after WS-26's `startFirstScanIfPending`) → `await scanFiles(trigger: .automaticFreshness)`. It returns early when `userScanTask != nil`.
  9. `removeLargeFileFromResults` is unchanged apart from calling the new cache `remove`, which keeps `savedAt`.
- **Edge cases:**
  - An explicit request during `.preparingOrFinalizing` is deferred with visible copy, never silent.
  - `.permissionRequired` maps to `neverScanned`, so the engine re-checks authorization and throws the permission error visibly.
  - The `.idle` + `.notDetermined` path must not touch PhotoKit: `videoCountProvider` returns nil.

**WS-27.6 — Videos first for user-initiated scans (VALUE-01 item 2)**
- **Why:** Videos are usually most of the reclaimable bytes and are cheap to size; they must not wait behind hours of Vision.
- **Change** (`HomeViewModel.swift`, about 30 lines; nothing else grows):
  ```swift
  @Published private(set) var isVideoPrePassRunning = false
  private var userScanTask: Task<Void, Never>?

  private func runUserInitiatedScan(mode: CleanupMode, forceFullRescan: Bool) {
      if isFinalizingPhotoScan || scanState == .scanning { activeScanOrigin = .userInitiated; return } // WS-26 upgrade
      guard userScanTask == nil else { return }
      userScanTask = Task(priority: .utility) { [weak self] in
          guard let self else { return }
          self.isVideoPrePassRunning = true
          await self.largeVideoScanController.waitForCurrentPass()      // a running pass *is* the pre-pass
          await self.restoreCachedLargeVideosIfNeeded()
          let reason = await self.largeVideoScanController.rescanReason(now: Date())
          if UserScanPlan.steps(rescanReason: reason, forceVideoPass: forceFullRescan).first == .videos {
              await self.scanFiles(trigger: .userScanPrePass)
          }
          self.isVideoPrePassRunning = false
          await self.scanPhotos(mode: mode, forceFullRescan: forceFullRescan, origin: .userInitiated)
          self.userScanTask = nil
      }
  }
  ```
  - `refreshPhotoScan()` and `rescanEntireLibrary()` (WS-26.4) call `runUserInitiatedScan` instead of `scanPhotos` directly. Keep `refreshPhotoScan`'s paused→resume check in front of it. `rescanEntireLibrary`'s explicit restore can go, because `scanPhotos` awaits `restoreCachedAnalysisIfNeeded()` before planning. `resumeDeepClean` and `retryIncludingICloudPhotos` do not call `runUserInitiatedScan`; they have no pre-pass.
  - `scanPhotos` claims the lock synchronously on its first line, so no automatic scan can slip in between `isVideoPrePassRunning = false` and the lock.
  - **Budget.** `LargeVideoScanController.run(budget:)` races the pass against the injected sleep for `prePassTimeBudget`. On expiry it cancels the pass, which takes the existing CancellationError branch → `.paused`. Partial `largeFiles` stay published; sizes are cached in `AssetFileSizeRepository`. Status message: "Checked \(processed) of \(total) videos — the rest continue after the photo scan." The post-photo pass then sees `.lastScanIncomplete` and finishes. **DECISION (owner may override):** a 90 s budget, so photos always start within about 90 s even on an iCloud-heavy library.
  - **Hero and CTA during the pre-pass:**
    - `heroState` returns `.deepCleanActive` when `isVideoPrePassRunning`. Check it after the permission, failure and WS-15 `.restoringResults` checks, and immediately before the `scanState == .scanning` check.
    - `heroDetailText` for `.deepCleanActive` returns "Checking large videos first · \(videoPassProgressLabel)" when `isVideoPrePassRunning`.
    - `HomeView.ctaTitle` returns "Checking large videos…" and the subtitle "Photos start right after", and the button is `.disabled(... || viewModel.isVideoPrePassRunning)`.
    - The scan footer is not shown (`scanState` is unchanged).
- **Edge cases:**
  - If the app is killed during the pre-pass, no photo state was persisted, so relaunch shows the previous state. WS-26's flag was already cleared, so a first-time user sees "Start scan"; accept this.
  - A second tap during the pre-pass is ignored (`userScanTask != nil`).

**WS-27.7 — Files and Home UI states (VALUE-01 items 3–5, FILES-02 item 5)**
- **Change:**
  - `FileResultsView` gets new init parameters with defaults so previews and tests compile: `hasCompletedVideoScan: Bool = true`, `isVideoScanDeferred: Bool = false`, `lastScannedAt: Date? = nil`. Both call sites pass the facade pass-throughs (`viewModel.hasCompletedVideoScan`, `isVideoScanDeferred`, `largeVideoResultsLastCheckedAt`). Forward note (README contract 27): WS-50 later replaces `scanProgress`, `onRefresh` and `onAssetDeleted` with `progress: VideoScanProgressStore` and `actions: LargeVideoActions`, and keeps these three inputs, read from the controller.
  - `resultsContent` switches on `LargeVideoListState.resolve(...)`:
    - `.permissionRequired`, `.scanning`: the existing views.
    - `.notScannedYet`: `EmptyStateView(title: "Videos haven’t been checked yet", icon: "video", message: "PhotoDuck looks for videos over 100 MB. It usually takes about a minute.", actionTitle: "Check Videos Now", action: refreshVideos)`.
    - `.waitingForPhotoScan`: title "Videos are next", message `scanProgress.statusMessage ?? "Videos will be checked when the photo scan pauses or finishes."`, action "Check Videos Now".
    - `.paused`: title "Video check paused", message `scanProgress.statusMessage`, action "Continue Checking Videos".
    - `.failed`: title "Video check didn’t finish", action "Try Again".
    - `.empty`: the existing "No Large Videos" / "No videos over 100 MB were found." / "Scan Videos Again".
    - `.results`: the existing list.
  - The completed banner (wherever WS-10 put `completedScanBanner`) appends "Last checked \(RelativeDateTimeFormatter().localizedString(for: lastScannedAt, relativeTo: Date()))" when `lastScannedAt != nil`.
  - Use existing components and tokens only; no redesign (Files awaits the design handoff).
  - `HomeView` Large Videos tile:
    - add `navigatesWhenEmpty: true`;
    - `supportingScanStatus(.idle)` returns "Not checked";
    - `largeVideoCategoryNote` for `.idle`, and for `.completed` when `!hasCompletedVideoScan`, returns "Not checked yet";
    - while `fileScanState == .scanning` the note shows `fileScanProgress.statusMessage` (already the case).

**WS-27.8 — Update the pinned tests and docs**
- `PhotoScanEngineTests.swift:1319-1372`:
  - Rename `testScanRunCompletionWaitsForPhotoAndSupportingFinalization` to `testScanRunCompletionIgnoresSupportingVideoPass`. Assert (completed, finalizing false) is true and (completed, finalizing true) is false.
  - In `testScanCompletionLockOnlyBlocksTheFinalCompletionWindow`, delete the case with `isFinishingSupportingScans: true` and keep the other three, adjusted to the new signature.
  - Explain both changes in the PR summary (README rule 6).
- `ios-cleanup/CLAUDE.md`: add a "Large Videos" paragraph covering videos-first with the 90 s budget, the freshness triggers, R1–R4, and that the video pass never locks review.

### Tests
All tests run in the simulator.
- `iOSCleanupTests/FileScanDecisionTests.swift` (*new*, pure):
  - `testDecisionTable`: all 7 triggers × 4 phases × 6 file states × {nil, `.neverScanned`}. Spot-assert:
    - scanning file state → `.skip`;
    - `.userExplicit` + photo `.scanning` → `.runPausingPhotoScan`;
    - `.tabVisit` + photo `.scanning` + reason → `.deferred`;
    - `.afterPhotoRun` + no reason → `.skip`;
    - `.userExplicit` + no reason + photo `.none` → `.run`;
    - `.preparingOrFinalizing` + `.userExplicit` → `.deferred`.
  - `testPostPhotoPassRunsWhenNothingWasAnalyzed`: completed, lock false, processed == target == 14, library not empty → true (the RT-1 case).
  - `testPostPhotoPassWaitsForDurability`: lock true → false.
  - `testUserScanPlanRunsVideosFirstWhenStaleOrMissing`, `testUserScanPlanSkipsPrePassWhenFresh`, `testForcedRescanAlwaysRunsVideoPrePass`.
- `iOSCleanupTests/LargeVideoFreshnessPolicyTests.swift` (*new*):
  - `testIdleIsNeverScanned`, `testPausedAndFailedAreIncomplete`;
  - `testMissingSavedResults`;
  - `testVideoCountChanged` (FILES-02 test a: scanned 12, current 20);
  - `testOlderThanSixHours` (test b: 6 h + 1 s);
  - `testFreshReturnsNil` (5 h 59 m, counts equal);
  - `testRestoreWithAllMissingIsNotCompleted` (`hasCompletedVideoScan` false → `.neverScanned`, test c);
  - `testNilCurrentCountSkipsCountCheck`.
- `iOSCleanupTests/LargeVideoListStateTests.swift` (*new*):
  - `testIdleNeverMapsToEmpty` (every non-completed state with 0 files ≠ `.empty`);
  - `testCompletedWithoutTrustworthyScanIsNotEmpty`;
  - `testDeferredShowsWaitingForPhotoScan`;
  - `testResultsWinOverScanning`;
  - `testPermissionFirst`.
- `iOSCleanupTests/FileScanEngineTests.swift` (STATE-14), each with a temp `directoryURL` and WS-03's test asset double:
  - `testConcurrentSaveAndRemoveLeaveDiskEqualToMemory`: 50 iterations of `async let a = cache.save(...)` plus `async let b = cache.remove(...)`. Then decode the file with a fresh `LargeVideoResultCache(directoryURL:)` and assert it equals `await cache.load()`.
  - `testConcurrentLoadsBothReturnSnapshot`: file present; `async let x = cache.load(); async let y = cache.load()` are both non-nil and equal.
  - `testLoadRacingSaveKeepsNewerSnapshot`: after `async let l = cache.load(); async let s = cache.save(newFiles)`, `await cache.load()` returns `newFiles` and the disk matches.
  - `testRemovePreservesScanTimestamp`: `savedAt` is unchanged after `remove`.
- `iOSCleanupTests/PhotoScanEngineTests.swift`:
  - The two updated pinned tests (27.8).
  - `testPauseQuiescesInFlightAnalysesBeforeReturning`:
    - Setup: 32 `ConfigurablePhotoScanTestAsset`s, an isolated ML store, and an analyzer that parks each call on a test-controlled continuation and counts concurrent calls.
    - Start the scan and wait until 8 calls have started. Start `pause(reason: .videoPass, quiesceTimeout: .seconds(60))` in a child task; the timeout is injected and never fires.
    - Assert it has not returned. Release the 8 calls; assert it returns `quiesced == true` with `committedProcessedCount == 8`, and that a yielded update carries `committedProcessedPhotoCount == 8`.
  - `testPausedEngineStartsNoAnalysisUntilResume`: the analyzer call count stays at 8 until `resume(reason: .videoPass)`.
  - `testUserPauseSurvivesVideoPassResume`: pause `.user`, pause `.videoPass`, resume `.videoPass` → still no new analyzer calls.
  - `testThermalReasonIsIndependent`: hold `.thermal` and `.videoPass`, resume `.videoPass` → still no new analyzer calls. WS-25's `testGateStaysPausedWhileAnyReasonRemains` covers the gate alone; this covers the engine.
  - `testQuiesceTimeoutReturnsUnquiesced`: one analyzer call never returns; fire the injected `quiesceSleep`. `pause` returns `quiesced == false` with the last yielded committed count, and no new analyzer call starts afterwards.
- `iOSCleanupTests/LargeVideoScanControllerTests.swift` (from WS-16):
  - `testInvalidatedPassNeverWritesResults` (README contract 24): park the resolver mid-pass, call `invalidateAndCancelCurrentPass()`, release the resolver. The cache file is unchanged, `largeFiles` is unchanged, and `passGeneration` increased by 1.
  - Update WS-16's tests from `runScan(force:)` to `run(budget: nil)`.
- `iOSCleanupTests/HomeViewModelTests.swift` (WS-26 harness plus `makeFileScanEngine` returning `FileScanEngine(authorizationProvider: .init(currentStatus: { .authorized }, requestReadWrite: { .authorized }), assetProvider: <stub>, representativeResolver: <stub>)`). WS-07's harness uses a `.denied` file engine on purpose, because an authorized one can write `AssetFileSizeRepository.shared`. Make sure these authorized stubs never reach the shared repository: the stub resolver returns sizes directly. If `FileScanEngine` still retains through `.shared` on this path, inject the harness's isolated repository instead.
  - `testFollowUpRunsOnceAfterSupportingPass` (R4): a library change during the post-photo pass sets `libraryChangedDuringRun`; exactly one reconcile runs after the pass (WS-19.4's call), not two.
  - `testUserInitiatedFirstScanRunsVideoPassBeforePhotoEngine`:
    - A shared `actor OrderLog` records "video.fetch", "video.resolve" and "photo.fetch" from the stub providers.
    - Call `startPhotoScan(from: .homePrimaryCTA)` with no video cache.
    - Assert the last "video.resolve" comes before the first "photo.fetch", and that `largeFiles` is populated before `lastCompletedAt` changes.
  - `testPrePassBudgetYieldsToPhotos`:
    - Inject the controller's `sleep` so the test fires the budget, and park the video resolver.
    - After firing: `fileScanState == .paused`, the photo engine starts, and after photos complete the post-photo pass finishes the videos (`fileScanState == .completed`).
  - `testExplicitVideoRefreshDuringPhotoScanPausesAndResumesEngine`: with a gated photo analyzer mid-run, `scanFiles(trigger: .userExplicit)` → no photo analyzer call starts while the video resolver runs; afterwards the photo scan completes.
  - `testAutomaticPhotoScanDeferredWhileVideoPassRuns`: during a parked video pass, invoke the automatic path → no photo engine is created until the pass ends, then exactly one follow-up runs.
  - `testVideoPassNeverLocksReview`: during the post-photo pass, `isCompletingActiveScan == false`, `isVideoPassRunning == true`, and the WS-26 token was already issued.
  - `testNonForcedScanFilesRescansWhenCountChanged` (FILES-02 a, via `videoCountProvider` returning 20 over a restored snapshot of 12).
  - `testSupportingPassRunsAfterZeroAnalyzedRun` (FILES-02 d / VALUE-01 case 2; analyzer returns `.unavailable` for all).

### Acceptance criteria
- [ ] On a user-initiated scan with missing or stale video results, the video pass runs before the photo engine starts. The photo engine starts within 90 s regardless of video count.
- [ ] While any video pass runs:
  - [ ] the Home CTA reads "Review N groups ready" with "Checking large videos… x/y" and is enabled;
  - [ ] Duck Mode and "Review Results" are enabled;
  - [ ] `isCompletingActiveScan` is true only in the photo durability window.
- [ ] Files never renders "No videos over 100 MB were found" unless `hasCompletedVideoScan` is true. Every explicit refresh either runs, pauses the photo engine and runs, or shows the deferred message.
- [ ] Large Videos rescans on its own after 6 h, on a video-count change, on missing saved results, and 10 s after new videos are inserted. `lastScannedAt` is shown as "Last checked …".
- [ ] After a run with 0 analyzed photos, Large Videos populates without visiting Files.
- [ ] The large-video results file equals the actor's memory after any interleaving (the four cache tests); `remove` preserves `savedAt`.
- [ ] Photo and video scans never run concurrently: the ordering, explicit-refresh and automatic-deferral tests pass.
- [ ] The end of every video pass runs WS-21's follow-up at most once (README contract 4), and a pass invalidated by `invalidateAndCancelCurrentPass()` never writes results (README contract 24).
- [ ] Zero warnings; the full suite is green; `CLAUDE.md` is updated.

### Device QA
1. On a fresh install with a library of 500+ videos (iCloud "Optimize iPhone Storage" on), tap Start scan:
   - the Large Videos tile shows "Checking large videos… x/y" within seconds;
   - videos appear before any photo group;
   - photos start within about 90 s;
   - record the pre-pass duration in the QA run.
2. During the photo scan, open Files and pull to refresh. The hero stays "in progress", the video check runs, and photo progress resumes afterwards without a tap.
3. Record a video of 100 MB or more with Camera, return to PhotoDuck, and wait about 15 s. The video appears in Files with a fresh "Last checked".
4. When the post-photo video pass runs, tap "Review N groups ready" immediately. Results open while "Checking large videos…" is still shown.
5. Restore a device from backup (or delete `Application Support/PhotoDuck/large-video-results.json` identifiers by reinstalling). Files shows "Videos haven’t been checked yet", never "No Large Videos", until a scan completes.

### Pitfalls and out of scope
- Reconciliation (from chapter 10): `userScanTask` (WS-27.6) does not check for cancellation after its awaits. WS-48's local-data Clear cancels it and adds the `Task.isCancelled` guard. If you touch that task here, add the guard now: check `Task.isCancelled` after each await before publishing or persisting.
- **Invariant 16** is the trap: relaxing the lock makes more code paths reachable during a video pass. Check every new call against R1–R4.
- Do not persist the video pre-pass as a photo scan state; `scanState` stays untouched during it.
- The reason-aware gate must not let `.videoPass` or `.background` release `.thermal` (WS-25) or `.user` (invariant 19).
- Out of scope:
  - bulk video delete, thresholds and screen recordings: WS-42 (chapter 09), which must keep 27.1's single-flight load, revision guard, synchronous writes and `savedAt`-preserving `remove` when it bumps the schema;
  - on-device vs iCloud video bytes and the video locality probe: WS-30 (chapter 07);
  - CTA ordering: `HomeCTAAction` and its resolver are introduced by WS-31 (chapter 07). WS-45 (chapter 09) extends them: `isVideoPrePassRunning` → CTA disabled, "Checking large videos…"; `isVideoPassRunning` → `.reviewResults` (README contract 26). The `ctaTitle`/`ctaSubtitle` edits here are interim until then;
  - library-change reconciliation: WS-21 (chapter 04);
  - background pause: WS-28.
- **Forward note (README contract 25):** WS-42 renames `FileScanUpdate.largeFiles` to `retainedVideos`, changes `FileRepresentativeResolver` to `(asset, remeasureEstimates)`, makes `scan()` return `FileScanResult` and deletes `FileScanEngine.minimumFileSizeBytes`. WS-42 owns updating this workstream's code and tests that use the old names: `LargeVideoScanController.run`, the `FileScanEngineTests` and `LargeVideoScanControllerTests` stubs, and the `HomeViewModelTests` resolver stubs. The controller's `largeFiles` stays as the derived, threshold-filtered list.
- **Reconciliation (README contract 2):** the gate was already reason-set based in WS-24 (`ScanPauseReason`). This workstream adds only `.videoPass` and builds the quiesce on WS-24's `drainPoint()`, `inFlightAnalysisCount` and `isInAnalysisLoop`, instead of converting the gate. The quiesce sleep is `quiesceSleep`, so it does not collide with WS-25's `sleep` pacing parameter.
- **Reconciliation (README contracts 3 and 4):** the video count and insert signal come from WS-18's inventory (`videoCount`, `onVideosInserted`), with no inventory edit and no `PHAsset.fetchAssets(…options: nil)` fallback. R4 names WS-19/WS-21's `runPostRunFollowUpIfNeeded()` and skips the supporting pass, whose follow-up WS-19.4 already runs.
- **Reconciliation (README contract 24):** `LargeVideoScanController` exposes `passGeneration` and `invalidateAndCancelCurrentPass()`. WS-48's Clear uses them instead of adding its own `videoScanGeneration`.
- **Reconciliation (WS-16 API):** `run(budget:) -> Outcome` replaces WS-16's `runScan(force:)`, and the facade keeps WS-16's outcome handling.
- **Reconciliation (README contract 29):** the diagnostic JSON key `isFinishingSupportingScans` stays, fed from `isVideoPassRunning`.

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| VALUE-01 | confirmed | All four claims hold at the cited lines. The plan adds a 90 s pre-pass budget, which the finding did not have, so photos are never starved on iCloud-heavy libraries. It uses trigger-based `FileScanDecisionPolicy` inputs instead of a `force` Bool. |
| FSA-02 (merged) | confirmed | Its `fileScanDecision` enum is adopted. `.runPausingPhotoScan` uses an engine pause reason `.videoPass` *with quiesce* (strict invariant 16) instead of a plain `pause()`, and resumes automatically rather than showing a user-visible pause (VALUE-01's variant). **DECISION (owner may override):** a transparent engine pause for explicit video refreshes. |
| FILES-02 | confirmed | Additional defect: `remove()` re-stamps `savedAt`, which would defeat the age check, so `remove` now preserves it. The "restored empty while videoCount > 0" trigger is dropped (it would rescan forever for users without large videos). "Force on every supporting pass" becomes freshness checks plus videos-first. Insertions are debounced through WS-18/WS-21's retained video fetch result. |
| STATE-04 | confirmed | `isVideoPassRunning` also covers explicit and pre-pass video scans (`fileScanState == .scanning`). The completion sheet already presents at durability through WS-26's token. The pinned tests are updated as the finding describes. |
| STATE-14 | confirmed | Also: `remove()` does a read-modify-write across `await load()`, so it now re-reads `cachedSnapshot` after the await. Writes are synchronous inside the actor (no detached write). |

---

## WS-28 — Scan run lifecycle: run lock, backgrounding, interrupted-scan recovery

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M1 | M | WS-15, WS-24, WS-27 | yes | `ws/28-scan-continuity` |

**Primary files:** `iOSCleanup/Views/HomeViewModel.swift`, `iOSCleanup/Views/Home/CleanupStateStore.swift` (from WS-15), `iOSCleanup/Views/Home/ScenePhaseScanPolicy.swift` (*new*), `iOSCleanup/Views/Home/ScanAutoResumePolicy.swift` (*new*), `iOSCleanup/Views/Home/CommittedProgressWaiter.swift` (*new*), `iOSCleanup/Utilities/BackgroundTaskLease.swift` (*new*, moved from HomeViewModel.swift), `iOSCleanup/Engines/ScanPauseGate.swift` (adds `ScanPauseReason.background`), `iOSCleanup/Views/Home/HomeViewModelDependencies.swift` (`makeBackgroundTaskLease`), `iOSCleanup/Utilities/SharedHelpers.swift` (diagnostic control actions only), `iOSCleanup/Views/HomeView.swift`, tests: `iOSCleanupTests/ScanLifecyclePolicyTests.swift` (*new*), `iOSCleanupTests/BackgroundTaskLeaseTests.swift` (*new*), `iOSCleanupTests/CommittedProgressWaiterTests.swift` (*new*), `iOSCleanupTests/CleanupStateStoreTests.swift`, `iOSCleanupTests/HomeViewModelTests.swift`, `iOSCleanupTests/PhotoScanEngineTests.swift`
**Findings covered:** STATE-03 (P2, confirmed), STATE-07 (P2, partially), STATE-08 (P2, confirmed)
**Decisions applied:**
- D-SCAN-CONTINUITY:
  - auto-pause on background unless a continued-processing task is running;
  - auto-resume on return;
  - auto-resume interrupted scans at launch with a 2-attempt / 8-photo guard;
  - an explicit Pause is sticky.
- D-BACKGROUND: a clean pause on background replaces the "keep running under a lease" behavior.
- D-SCAN-RESOURCES: pause and background always write a checkpoint.

### Goal
- Pause then Continue keeps the run lock, so a resumed run cannot publish "completed" before its results are stamped and durable.
- Backgrounding mid-scan quiesces the engine, writes a checkpoint equal to the engine's committed count, ends the background task synchronously on expiry, and resumes automatically on return.
- A scan interrupted by termination or jetsam resumes at relaunch without a tap, unless the user paused it or it keeps crashing.

Land it as 3 commits: STATE-03, STATE-07, STATE-08.

### Current behavior (verified)
- **Resume and pause:**
  - `resumeDeepClean` in-place branch (`HomeViewModel.swift:864-877`): sets `scanState = .scanning`, `isPaused = false`, `persistCleanupState()`, `engine.resume()`. It **never restores** `isFinalizingPhotoScan`.
  - `pauseDeepClean` clears it at `:900` ("The scan is suspended, not finalizing").
- **Consequences for a resumed run:**
  - The final `apply` sets `.completed` (`:1751-1756`), so `activeScanRunIsComplete` is true before the worker's `await saveSnapshot` (`:1181`) and before the completion block stamps `lastCompleted*` (`:1192-1243`).
  - `persistCleanupState`'s durable mapping (`:2341-2344`) no longer applies.
  - The `scanPhotos` guard (`:931`) and reconcile's first branch (`:1831`) are open, so a reconcile can supersede `activeScanID` and lose the completion record.
- **Final update while paused:** `apply` ignores `isPaused` when `update.isComplete`, so a final update that arrives while paused sets `.completed`. Continue then falls through to a superseding `scanPhotos` (`:879`).
- **`.background` (`:1550-1574`):**
  - Sets `isBackgroundExecutionState` (`:1552`; read by no view, and WS-07 stops publishing it).
  - Builds a checkpoint from committed counters **before** anything pauses, takes `PhotoDuckBackgroundTaskLease`, flushes and saves.
  - Never calls `activePhotoScanEngine.pause()`, so work committed after the checkpoint is lost if iOS kills the suspended app.
- **The lease** (`:15-34`): its expiration handler is `{ [weak self] in Task { @MainActor [weak self] in self?.end() } }`, so `endBackgroundTask` runs in a later main-actor turn instead of inside the handler.
- **In-flight PhotoKit requests** use `DispatchQueue.global().asyncAfter` timeouts (`SharedHelpers.swift:~323-336` for 4 s/6 s analysis, `~564-566`). WS-24.5 makes them cancellable `DispatchSourceTimer`s (`PhotoKitTimeoutScheduling`); they are still wall-clock. Whether they fire across suspension, and whether Vision fails after backgrounding, is **device behavior** (WS-09 records it).
- **Relaunch:**
  - `loadPersistedCleanupState` maps persisted `.scanning` to `.paused` + `isPaused` (`:2518-2522`).
  - `performCachedAnalysisRestore` maps any incomplete snapshot to `.paused` (`:2197-2201`).
  - `scanNewPhotosIfNeeded` runs only for `.completed`/`.idle` (`:1925-1926`).
  - Nothing calls resume at launch, and `PersistedCleanupState` (`:175-200`, now in WS-15's `CleanupStateStore`) has no pause reason.
- **Diagnostics:** `PhotoDuckDiagnosticReportSnapshot` has `isFinalizingPhotoScan`/`isFinishingSupportingScans` keys (`SharedHelpers.swift:997-998, 1500-1502`), and `PhotoDuckDiagnosticControlAction` has two cases (`:626-629`).

### Implementation plan

**WS-28.0 — Verify-first (read, don't code)**
Read the WS-09 baseline QA run in `docs/qa-runs/` for:
- the unanalyzed count before and after 20 app switches mid-scan;
- any Vision failures after backgrounding;
- "Background task … not ended" console warnings;
- how long the background checkpoint write took.

Record these numbers in the PR description. If the checkpoint write plus a 10 s quiesce could exceed about 25 s on the baseline device, lower `backgroundQuiesceTimeout` (below) to fit and note it. The fix stands whatever the numbers are; they set the timeout and serve as the before/after evidence.

**WS-28.1 — Commit 1, STATE-03: resume keeps the run lock; rename to `isPhotoRunActive`**
- **Why:** After Pause → Continue, the completion sheet shows stale counts, UserDefaults can say completed before the snapshot is durable, and a reconcile can lose the completion.
- **Change:**
  1. Rename `isFinalizingPhotoScan` to `@Published private(set) var isPhotoRunActive` everywhere in `HomeViewModel` and its extracted types. Add `var isFinalizingPhotoScan: Bool { isPhotoRunActive && scanState == .completed }` for HomeView copy (`:383`). Rename the static parameter labels (`isScanRunComplete(scanState:isPhotoRunActive:)`, `isScanCompletionLocked(...)`) and update `PhotoScanEngineTests` accordingly. Keep the diagnostic JSON key `isFinalizingPhotoScan`, fed from `isPhotoRunActive`.
  2. Add `ScanResumePolicy` to `iOSCleanup/Views/Home/ScenePhaseScanPolicy.swift`:
     ```swift
     enum ScanResumeAction: Equatable { case resumeInPlace, startNewRun, ignore }
     enum ScanResumePolicy {
         static func action(scanState: HomeViewModel.ScanState, hasEngine: Bool, hasScanTask: Bool) -> ScanResumeAction {
             switch scanState {
             case .completed, .scanning: return .ignore          // never supersede a finished or running run
             case .paused: return hasEngine && hasScanTask ? .resumeInPlace : .startNewRun
             case .idle, .failed, .permissionRequired: return .startNewRun
             }
         }
         /// true = the in-place branch must hold the run lock; nil = no-op / the new run takes it itself.
         static func runLockAfterResume(_ action: ScanResumeAction) -> Bool? { action == .resumeInPlace ? true : nil }
     }
     ```
  3. `resumeDeepClean()` becomes the user entry point: it clears the WS-28.4 ledger and blocked message, sets `activeScanOrigin = .userInitiated` (WS-26), then calls `private func resumeScan(trigger: ResumeTrigger)` with `enum ResumeTrigger { case user, returnFromBackground, relaunch }`. By policy:
     - `.ignore`: return (records the diagnostic only).
     - `.resumeInPlace`, in this order:
       - `scanState = .scanning; isPaused = false; pauseReason = nil; isPhotoRunActive = true` (**before** `persistCleanupState()`);
       - reset the rate sample;
       - `persistCleanupState()`;
       - then `Task { await largeVideoScanController.waitForCurrentPass(); await engine.resume(reason: .user); await engine.resume(reason: .background) }`. The wait is WS-27's R2; resuming a reason that isn't held is a no-op.
     - `.startNewRun`: `Task { await scanPhotos(mode: cleanupMode, origin: activeScanOrigin) }`.
  4. In `apply`, keep `nextScanState` as is. `.ignore` on `.completed` is what fixes "Continue after a final update while paused".
- **Edge cases:**
  - `pauseDeepClean` still clears the lock. Paused guards must not dead-end, which is the reason documented at `:895-900`.
  - The lock now means "a run is active and not suspended", which is what every guard expects (invariant 13).

**WS-28.2 — Commit 2a: `BackgroundTaskLease` ends synchronously**
- **Change:** Move the private `PhotoDuckBackgroundTaskLease` (`HomeViewModel.swift:15-34`) to `iOSCleanup/Utilities/BackgroundTaskLease.swift`, renamed to an internal `@MainActor final class BackgroundTaskLease` with injectable begin and end closures. This is the lease's single home. WS-44 (chapter 09) reuses `BackgroundTaskLease(name:)` for compression and does not move or redeclare it.
  ```swift
  @MainActor
  final class BackgroundTaskLease {
      typealias Begin = @MainActor (_ name: String, _ onExpire: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier
      private var identifier: UIBackgroundTaskIdentifier = .invalid
      private let endTask: @MainActor (UIBackgroundTaskIdentifier) -> Void
      init(name: String,
           begin: Begin = BackgroundTaskLease.liveBegin,
           end: @escaping @MainActor (UIBackgroundTaskIdentifier) -> Void = { UIApplication.shared.endBackgroundTask($0) }) {
          endTask = end
          identifier = begin(name) { [weak self] in self?.end() }      // synchronous inside the handler
      }
      func end() {
          guard identifier != .invalid else { return }
          let id = identifier; identifier = .invalid; endTask(id)
      }
      static let liveBegin: Begin = { name, onExpire in
          UIApplication.shared.beginBackgroundTask(withName: name) {
              MainActor.assumeIsolated { onExpire() }   // UIKit delivers the handler on the main thread
          }
      }
  }
  ```
  If the SDK already types the handler as `@MainActor`, call `onExpire()` directly. `MainActor.assumeIsolated` needs iOS 17 (D-MIN-OS). If the owner keeps iOS 16, use `dispatchPrecondition(condition: .onQueue(.main))` plus an `@unchecked Sendable` box.

  Add `makeBackgroundTaskLease: @MainActor (String) -> BackgroundTaskLease` to `HomeViewModelDependencies`. The live value is `{ BackgroundTaskLease(name: $0) }`; tests pass a lease with fake begin and end closures. Replace both lease constructions in `HomeViewModel`: the `.background` checkpoint path, and 28.3's pause path.

**WS-28.3 — Commit 2, STATE-07: pause on background with an exact checkpoint, resume on return**
- **Why:** Work done after the checkpoint is lost, suspended in-flight requests time out into "unanalyzed", and the lease can overrun.
- **Change:**
  1. Create `iOSCleanup/Views/Home/ScanAutoResumePolicy.swift` with `enum PauseReason: String, Codable, Sendable { case user, backgrounded, interrupted }`; 28.4 adds more to this file. Separately, add `case background` to the engine gate's `ScanPauseReason` (`ScanPauseGate.swift`, README contract 2). `PauseReason` is the persisted `HomeViewModel` state; `ScanPauseReason.background` is the engine gate reason held for a `.backgrounded` pause. Do not merge the two.
  2. `HomeViewModel`:
     - `@Published private(set) var pauseReason: PauseReason?` (meaningful only while `.paused`; cleared at every run start, resume and completion);
     - `private var currentScenePhase: ScenePhase = .active`, updated in `updateScenePhase`;
     - `private let committedProgressWaiter = CommittedProgressWaiter()`;
     - `static let backgroundQuiesceTimeout: Duration = .seconds(10)`.
  3. Create `iOSCleanup/Views/Home/CommittedProgressWaiter.swift`:
     ```swift
     @MainActor
     final class CommittedProgressWaiter {
         private(set) var appliedCommittedCount = 0
         private var waiters: [UUID: (threshold: Int, continuation: CheckedContinuation<Bool, Never>)] = [:]
         private let sleep: @Sendable (Duration) async -> Void
         init(sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) { self.sleep = sleep }

         func reset() { appliedCommittedCount = 0; resumeAll(false) }
         func didApply(committedCount: Int) {
             appliedCommittedCount = max(appliedCommittedCount, committedCount)
             for (id, w) in waiters where w.threshold <= appliedCommittedCount {
                 waiters[id] = nil; w.continuation.resume(returning: true)
             }
         }
         /// true once an update with committed >= threshold was applied; false on timeout.
         func wait(untilCommitted threshold: Int, timeout: Duration) async -> Bool {
             if appliedCommittedCount >= threshold { return true }
             let id = UUID()
             return await withCheckedContinuation { continuation in
                 waiters[id] = (threshold, continuation)
                 Task { @MainActor [weak self, sleep] in
                     await sleep(timeout)
                     self?.waiters.removeValue(forKey: id)?.continuation.resume(returning: false)
                 }
             }
         }
     }
     ```
     If the toolchain does not run the `withCheckedContinuation` body on the main actor, register the waiter with `MainActor.assumeIsolated` inside it; it must compile warning-free. Call `committedProgressWaiter.reset()` at each `scanPhotos` engine start. In `apply`, call `committedProgressWaiter.didApply(committedCount: update.committedProcessedPhotoCount ?? 0)`; this count is engine-relative, before the offset.
  4. In `ScenePhaseScanPolicy.swift`:
     ```swift
     enum ScenePhaseScanAction: Equatable { case pauseForBackground, checkpoint, resumeFromBackground, none }
     enum ScenePhaseScanPolicy {
         static func action(phase: ScenePhase, scanState: HomeViewModel.ScanState, pauseReason: PauseReason?,
                            hasEngine: Bool, hasContinuedProcessing: Bool) -> ScenePhaseScanAction {
             switch phase {
             case .background:
                 if scanState == .scanning, hasEngine, !hasContinuedProcessing { return .pauseForBackground }
                 return (scanState == .scanning || scanState == .paused) ? .checkpoint : .none
             case .active:
                 return (scanState == .paused && pauseReason == .backgrounded && hasEngine) ? .resumeFromBackground : .none
             default:
                 return .none
             }
         }
     }
     ```
     `hasContinuedProcessing` is `false` until WS-29 wires it.
  5. Extract the pause body into `private func suspendActiveRun(reason: PauseReason)`. `pauseDeepClean()` becomes `suspendActiveRun(reason: .user)` plus WS-27's deferred-video replay. `suspendActiveRun`, synchronously:
     - `guard scanState == .scanning`; record the diagnostic;
     - `scanState = .paused; isPaused = true; pauseReason = reason; isPhotoRunActive = false; persistCleanupState()`;
     - take `let lease = reason == .backgrounded ? dependencies.makeBackgroundTaskLease("PhotoDuck background pause") : nil` (28.2's seam, so tests can fake it);
     - if `activePhotoScanEngine` is nil, keep today's direct checkpoint path.

     Then:
     ```swift
     let scanID = activeScanID
     Task(priority: .utility) { [weak self] in
         let ack = await engine.pause(reason: reason == .user ? .user : .background,
                                      quiesceTimeout: HomeViewModel.backgroundQuiesceTimeout)
         guard let self, self.activeScanID == scanID else { lease?.end(); return }   // run fencing
         _ = await self.committedProgressWaiter.wait(untilCommitted: ack.committedProcessedCount, timeout: .seconds(2))
         // Capture the checkpoint inputs on main now (WS-16's AnalysisSnapshotInputs); build off-main as WS-16 does.
         let checkpoint = self.makeAnalysisSnapshot(isComplete: false)
         await self.mlBridge.flushBufferedWrites()                // WS-08 test #7 order: flush, then save
         if self.persistenceGate.allowsRunWrite { await self.analysisCache.saveSnapshot(checkpoint) }   // WS-20's gate for pause writes
         if reason == .backgrounded {
             await self.dependencies.fileSizeRepository.flush()   // WS-07's injected repository, never .shared
             await self.diagnostics.awaitPendingWrites()          // WS-15's ScanDiagnosticsRecorder
         }
         lease?.end()
     }
     ```
  6. `updateScenePhase(_:)`: store `currentScenePhase`, then switch on `ScenePhaseScanPolicy.action(...)`:
     - `.pauseForBackground`: `suspendActiveRun(reason: .backgrounded)`.
     - `.checkpoint`: today's `.background` body minus the `isBackgroundExecutionState` line (flush, checkpoint from committed counters, lease).
     - `.resumeFromBackground`: `resumeScan(trigger: .returnFromBackground)`. It does not touch the ledger or origin.
     - `.none`: nothing.

     Keep the existing `.active` work (WS-18's inventory refresh on background→active) and the diagnostics. Delete every write of `isBackgroundExecutionState`, and delete the stored property. Its persisted field becomes `Bool?`, decoded with `decodeIfPresent` and written as `nil`.
  7. **Engine started while backgrounded.** In `scanPhotos`, right after `activePhotoScanEngine = engine` and the worker start: if `currentScenePhase == .background` and there is no continued processing (WS-29), call `suspendActiveRun(reason: .backgrounded)`. This covers the planning window, where the app went to the background before the engine existed.
  8. `heroState`: for `.paused`, return `.deepCleanActive` when `pauseReason == .backgrounded`, otherwise `.deepCleanPaused`. The scan footer (`HomeView.swift:816-831`) uses `scanState == .paused && viewModel.pauseReason != .backgrounded` for "Scan paused"/"Continue".
  9. Add `PhotoDuckDiagnosticControlAction` cases: `autoPausedForBackground = "auto_paused_background"`, `autoResumedFromBackground = "auto_resumed_background"`, `autoResumedAtLaunch = "auto_resumed_launch"`, `autoResumeBlocked = "auto_resume_blocked"`.
- **Edge cases:**
  - **A quick app switch.** The user returns before the pause Task finishes, so `.active` resumes the engine while the Task still waits for its ack. The Task then saves a checkpoint of the committed state (still valid) and ends the lease. It must not change `scanState` after its first synchronous section.
  - **A user Pause, then background.** The action is `.checkpoint`. The reason stays `.user`, so nothing resumes on return (invariant 19).
  - **In-flight Vision after backgrounding.** Analyses still in flight during the quiesce run in the background. WS-22's CPU retry absorbs GPU-denied failures; device QA verifies that 20 switches add 0 unanalyzed photos.
  - **WS-25 thermal suspension** is not a `PauseReason` and is never persisted as `.user`.

**WS-28.4 — Commit 3, STATE-08: relaunch auto-resume with a crash-loop guard**
- **Why:** Long scans rarely finish if every jetsam or Xcode stop waits for a tap.
- **Change:**
  1. In `ScanAutoResumePolicy.swift`:
     ```swift
     struct AutoResumeLedger: Codable, Equatable, Sendable { var attempts: Int; var baselineProcessedCount: Int }
     enum AutoResumeDecision: Equatable { case resume(AutoResumeLedger), blocked, notApplicable }

     enum ScanAutoResumePolicy {
         static let maxAttemptsWithoutProgress = 2
         static let minimumProgress = 8                     // one analysis batch
         static func decide(scanState: HomeViewModel.ScanState, pauseReason: PauseReason?,
                            authorization: PHAuthorizationStatus, processedCount: Int,
                            ledger: AutoResumeLedger?) -> AutoResumeDecision {
             guard scanState == .paused, pauseReason == .interrupted || pauseReason == .backgrounded,
                   authorization == .authorized || authorization == .limited else { return .notApplicable }
             guard let ledger, processedCount < ledger.baselineProcessedCount + minimumProgress else {
                 return .resume(AutoResumeLedger(attempts: 1, baselineProcessedCount: processedCount))
             }
             guard ledger.attempts < maxAttemptsWithoutProgress else { return .blocked }
             return .resume(AutoResumeLedger(attempts: ledger.attempts + 1, baselineProcessedCount: ledger.baselineProcessedCount))
         }
         /// Legacy and new decode mapping. A persisted `.scanning` always means interrupted.
         static func restoredPauseReason(persistedScanState: HomeViewModel.ScanState, persistedReason: PauseReason?) -> PauseReason? {
             switch persistedScanState {
             case .scanning: return .interrupted
             case .paused: return persistedReason ?? .user
             default: return nil
             }
         }
     }
     ```
  2. `CleanupStateStore` (WS-15). Add to the persisted struct, all `decodeIfPresent`, with no schema bump beyond WS-15's `schemaVersion` default:
     - `pauseReason: PauseReason?`
     - `scanOrigin: ScanOrigin?` (WS-26's origin, so an auto-resumed user scan still gets its completion sheet)
     - `autoResumeLedger: AutoResumeLedger?`

     `loadPersistedCleanupState` sets `pauseReason = ScanAutoResumePolicy.restoredPauseReason(...)` **before** the existing `.scanning → .paused` mapping. It also restores `activeScanOrigin = persisted.scanOrigin ?? .automatic` and the ledger. `persistCleanupState` writes all three.
  3. `HomeViewModel`:
     - add `@Published private(set) var autoResumeBlockedMessage: String?`;
     - add `private func autoResumeInterruptedScanIfNeeded()`, called in the bootstrap Task right after `restoreCachedAnalysisIfNeeded()`. It runs before WS-26's first-scan check and WS-27's freshness call; those conditions exclude `.paused`, so the order is safe.

     It switches on `decide(... processedCount: processedPhotoCount /* the restored checkpoint */ ...)`:
     - `.notApplicable`: return.
     - `.blocked`: `autoResumeBlockedMessage = "PhotoDuck stopped unexpectedly. Tap Continue to try again."`; record `autoResumeBlocked`.
     - `.resume(ledger)`: `autoResumeLedger = ledger; persistCleanupState()` (the attempt counts even if we crash now); record `autoResumedAtLaunch`; `resumeScan(trigger: .relaunch)`.
  4. Clear the ledger and the message on:
     - a user `resumeDeepClean()`;
     - the completion barrier;
     - the start of any user-initiated run;
     - `rescanEntireLibrary`.
  5. In `scanPhotos`, change the resume activity message (baseline `:1085-1086`, `isResumingCheckpoint`) to "Picking up where PhotoDuck left off…".
  6. `heroDetailText` for `.deepCleanPaused`: when `autoResumeBlockedMessage != nil`, return it in place of the progress line.
- **Edge cases:**
  - An incomplete snapshot with `pauseReason == nil` (the persisted state was completed or idle) is treated as a user pause: no auto-resume.
  - WS-15's `CleanupStateReconciler` resets the state to idle when the snapshot is nil. A first scan killed before its first checkpoint therefore does not auto-resume; accept this and document it.
  - Denied or restricted access: `.notApplicable`, and the permission UI shows.
  - `.backgrounded` persisted from a jetsam while suspended resumes like `.interrupted`.

### Tests
All tests run in the simulator.
- `iOSCleanupTests/ScanLifecyclePolicyTests.swift` (*new*, pure):
  - `testResumePolicy`:
    - `.paused` with engine and task → `.resumeInPlace`, and `runLockAfterResume == true`;
    - `.paused` without engine → `.startNewRun`;
    - `.completed` → `.ignore` and nil;
    - `.scanning` → `.ignore`.
  - `testScenePhaseTable`:
    - background + scanning + engine → `.pauseForBackground`;
    - background + scanning + continued processing → `.checkpoint`;
    - background + paused → `.checkpoint`;
    - active + paused + `.backgrounded` + engine → `.resumeFromBackground`;
    - active + paused + `.user` → `.none`;
    - active + paused + `.backgrounded` + no engine → `.none`;
    - inactive → `.none`.
  - `testAutoResumeTable`:
    - `.user` → `.notApplicable`;
    - `.interrupted` with no ledger → `.resume(attempts 1, baseline = processed)`;
    - no progress with attempts 1 → `.resume(attempts 2)`;
    - no progress with attempts 2 → `.blocked`;
    - progress ≥ 8 → `.resume(attempts 1, new baseline)`;
    - `.denied` → `.notApplicable`;
    - `.backgrounded` → resumes.
  - `testRestoredPauseReasonMapping`: persisted `.scanning` + any reason → `.interrupted`; `.paused` + nil → `.user`; `.paused` + `.backgrounded` → `.backgrounded`; `.completed` → nil.
- `iOSCleanupTests/CleanupStateStoreTests.swift`:
  - `testLegacyJSONWithoutPauseReasonDecodes`: fixture JSON of v2 shape without the new keys; scanState `scanning` → the loaded reason is `.interrupted`.
  - `testPauseReasonOriginAndLedgerRoundTrip`.
  - `testBackgroundExecutionFieldIsOptional`.
- `iOSCleanupTests/BackgroundTaskLeaseTests.swift` (*new*):
  - `testExpirationEndsSynchronously`: the fake `begin` captures `onExpire` and returns id 7; calling `onExpire()` calls the fake `end` with 7 exactly once *before returning*.
  - `testEndIsIdempotent`.
- `iOSCleanupTests/CommittedProgressWaiterTests.swift` (*new*):
  - `testReturnsImmediatelyWhenAlreadyApplied`.
  - `testResumesWhenThresholdApplied`.
  - `testTimesOutWithInjectedSleep`: the injected sleep awaits a test continuation; release it and assert false.
  - `testResetFailsPendingWaiters`.
- `iOSCleanupTests/HomeViewModelTests.swift` (WS-26/WS-27 harness, gated analyzer):
  - `testResumeRestoresRunLockBeforeFinalUpdate` (STATE-03):
    - Subscribe to `$scanState`. In the sink, when the new value is `.completed`, record whether `viewModel.isPhotoRunActive` is true or `lastCompletedAt` has changed.
    - Start a user scan of 16 assets, park the analyzer after 8, call `pauseDeepClean()` then `resumeDeepClean()`, release, and wait (deadline poll) for `lastCompletedAt` to change.
    - Assert every recorded `.completed` transition had the lock held, `isPhotoRunActive == true` right after resume, and that WS-26's token fired after the stamp.
  - `testContinueAfterCompletionIsNoOp`: `.completed` → `resumeDeepClean()` creates no new engine (factory call count unchanged).
  - `testBackgroundPausesEngineAndCheckpointsCommittedCount` (STATE-07):
    - Mid-scan with 8 analyses parked, call `updateScenePhase(.background)`; assert `scanState == .paused` and `pauseReason == .backgrounded` synchronously.
    - Release the parked analyses; wait for the save.
    - Decode the snapshot from the temp cache; assert `processedPhotoCount == progressOffset + 8`, equal to the engine ack.
  - `testActiveResumesBackgroundPause`: then `updateScenePhase(.active)` → `.scanning`, lock held, and the run completes.
  - `testUserPauseSurvivesBackgroundRoundTrip`: pause, background, active → still `.paused`/`.user`, and the analyzer call count is unchanged.
  - `testBootstrapAutoResumesInterruptedScan` (STATE-08):
    - Seed the temp defaults with persisted `.scanning` and a temp incomplete checkpoint; construct the view model with the authorization stub `.authorized`.
    - Assert a new engine is created, `pauseReason == nil`, and the ledger has attempts 1.
  - `testBootstrapKeepsUserPause`: persisted `.paused` + `.user` → no engine is created.
  - `testCrashLoopGuardBlocksAfterTwoAttempts`: ledger `(2, processed)` with no progress → no engine, and `autoResumeBlockedMessage` is set.

### Acceptance criteria
- [ ] After Pause and Continue:
  - [ ] `isPhotoRunActive` is true until the completion barrier;
  - [ ] `CompletionOverlay`'s first render shows the new run's counts;
  - [ ] UserDefaults never holds `.completed` before the complete snapshot is durable.
- [ ] Backgrounding mid-scan pauses the engine. The saved checkpoint's processed count equals the engine's committed count at pause (test). Returning to the app resumes automatically, and the hero never shows "paused" for it.
- [ ] The lease ends inside the expiration handler (test), and there are no "background task … not ended" console warnings (device).
- [ ] Stopping the app from Xcode mid-scan and relaunching continues scanning without a tap. An explicit Pause survives relaunch. After 2 no-progress auto-resumes, the app shows "PhotoDuck stopped unexpectedly. Tap Continue to try again."
- [ ] `isBackgroundExecutionState` is gone from `HomeViewModel`; the persisted field still decodes.
- [ ] Zero warnings; the full suite is green.
- [ ] `ios-cleanup/CLAUDE.md` documents:
  - `isPhotoRunActive` (the run lock, including after resume);
  - the pause reasons and their relaunch behavior;
  - the crash-loop guard.

### Device QA
1. Mid-scan on a library of 10k or more, note "unanalyzed" (Home, or the diagnostics export). Switch to another app and back 20 times, 5–30 s each. The unanalyzed count must be unchanged, the scan resumes each time without a tap, and Console shows no "Background task still not ended".
2. Mid-scan, stop the app from Xcode and relaunch. The scan continues ("Picking up where PhotoDuck left off…").
3. Tap Pause, stop from Xcode, relaunch. The app shows "Scan paused" and waits for Continue.
4. Start a scan, then stop from Xcode within 5 s of each relaunch, three times. The third launch shows "PhotoDuck stopped unexpectedly. Tap Continue to try again."
5. Pause, Continue, let it finish. The first frame of "Scan complete" shows the new counts; record a screen recording.

### Pitfalls and out of scope
- **Invariants 13, 18 and 19** are all at stake:
  - never publish `.completed` without the lock;
  - pause and background always end in a durable snapshot;
  - never write `pauseReason = .user` for anything the user didn't tap.
- Keep `activeScanID` fencing on every new main-actor hop (the pause Task must check that the run it paused is still the active one before saving: capture `scanID`).
- Do not auto-resume under `.notDetermined`, `.denied` or `.restricted` (invariant 20).
- WS-49 (chapter 11) later moves this lifecycle code into `PhotoScanCoordinator` verbatim; keep the new logic in the new policy files, not inline.
- The idle timer and `BGContinuedProcessingTask` are WS-29.
- Completion notifications and "Notify me" gating are WS-29 and WS-31.
- **Reconciliation (BackgroundTaskLease location):** WS-28.2 is the one move of `PhotoDuckBackgroundTaskLease` out of `HomeViewModel.swift`. It lives in `iOSCleanup/Utilities/BackgroundTaskLease.swift` as `BackgroundTaskLease`, and WS-44 (chapter 09) reuses it. `HomeViewModel` builds leases only through `HomeViewModelDependencies.makeBackgroundTaskLease`, including in `suspendActiveRun`.
- **Reconciliation (README contract 2):** this workstream adds `ScanPauseReason.background` to WS-24's gate. The persisted `PauseReason` stays a separate type.
- **Reconciliation (README contract 29):** after the rename, the diagnostic JSON keys stay `isFinalizingPhotoScan` (fed from `isPhotoRunActive`) and `isFinishingSupportingScans` (fed from `isVideoPassRunning`, WS-27).
- **Reconciliation (earlier-workstream seams):** the pause Task flushes WS-07's injected `dependencies.fileSizeRepository` (never `AssetFileSizeRepository.shared`), awaits WS-15's `diagnostics.awaitPendingWrites()`, and gates the snapshot write with WS-20's `persistenceGate.allowsRunWrite`. PhotoKit request timers are WS-24.5's cancellable `DispatchSourceTimer`s, not `DispatchWorkItem`s.
- **Forward note (WS-48, chapter 10):** `stopAllRunsForLocalDataClear` pauses the engine and clears the run lock (`isPhotoRunActive`). For the video pass it uses WS-27's `LargeVideoScanController.invalidateAndCancelCurrentPass()`.

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| STATE-03 | confirmed | All three consequences hold (`:1751-1756`, `:2341-2344`, `:931`/`:1831`), and so does the Continue-after-final-update supersession (`:879`). `ScanResumePolicy.action` replaces the `Bool?` helper (it keeps `runLockAfterResume`). In-place resume also waits for any running video pass (WS-27 R2). |
| STATE-07 | partially | Confirmed statically: no engine pause on background, a checkpoint built before any pause, an async lease end, and `isBackgroundExecutionState` read by no view. Device-only: timeouts firing on resume and Vision failing after backgrounding (WS-09 observations; the device QA step verifies them). Fix changes: "pause, then build the checkpoint on main" alone does not equal the committed count, because the engine yields only every 8 drained assets. The plan adds WS-27's quiesce+ack and a `CommittedProgressWaiter`. WS-07 already stopped publishing `isBackgroundExecutionState`; this workstream removes the remaining writes. |
| STATE-08 | confirmed | The origin is persisted too, so an auto-resumed user scan still ends with its completion sheet. The ledger counts an attempt before resuming. |

---

## WS-29 — Long scans on a real device: idle timer and background continuation

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M1 | M | WS-25, WS-28 | yes | `ws/29-idle-timer-bg-continuation` |

**Primary files:** `iOSCleanup/Utilities/IdleTimerCoordinator.swift` (*new*), `iOSCleanup/Views/Home/ScanIdleTimerPolicy.swift` (*new*), `iOSCleanup/Views/Home/ScanBackgroundContinuation.swift` (*new*), `iOSCleanup/Views/Home/HomeViewModelDependencies.swift` (from WS-07), `iOSCleanup/Views/HomeViewModel.swift`, `iOSCleanup/Views/HomeView.swift`, `iOSCleanup/iOSCleanupApp.swift`, `iOSCleanup/Info.plist`, `iOSCleanup/Views/Files/ExternalExportCoordinator.swift` (from WS-10), tests: `iOSCleanupTests/ExternalExportCoordinatorTests.swift` (from WS-10; lifecycle fakes only), `iOSCleanupTests/IdleTimerCoordinatorTests.swift` (*new*), `iOSCleanupTests/ScanIdleTimerPolicyTests.swift` (*new*), `iOSCleanupTests/ScanBackgroundContinuationTests.swift` (*new*), `iOSCleanupTests/HomeViewModelTests.swift`, `docs/qa-runs/` (spike notes)
**Findings covered:** VALUE-08 (P1, confirmed; merged: UI-09)
**Decisions applied:**
- D-BACKGROUND:
  - keep the screen awake during active foreground scans only while thermal state is `.fair` or better;
  - use `BGContinuedProcessingTask` for user-initiated scans on iOS 26+;
  - otherwise use WS-28's clean pause;
  - show "Notify me" only when a continuation was scheduled;
  - `BGProcessingTask`-while-charging is optional.
- D-MIN-OS: iOS 17 minimum; `BGContinuedProcessingTask` is behind `#available(iOS 26, *)`.
- D-SCAN-CONTINUITY: while a continuation runs, WS-28's pause-on-background is skipped.

### Goal
- The phone does not auto-lock during an active foreground scan (unless it is hot).
- Exports and scans share the idle timer without clobbering each other.
- On iOS 26, a user-started scan keeps running in the background with the system progress UI and pauses cleanly when iOS expires it.
- The UI promises background completion only when a continuation actually exists.

### Current behavior (verified)
- **No background execution:**
  - No `BGTaskScheduler` or `BackgroundTasks` usage anywhere.
  - `Info.plist` (50 lines) has no `BGTaskSchedulerPermittedIdentifiers` or `UIBackgroundModes`.
- **Idle timer:**
  - `isIdleTimerDisabled` is written only by the two export paths:
    - `HomeView.swift:1846/1875` (ExportAlbumView);
    - `FileResultsView.swift:1155/1182` (selected-video export).
  - WS-10 unifies both into `ExternalExportCoordinator`.
  - Each export path sets `false` in `defer`, which would clobber any other owner.
  - Compression never disables it; UI-09's claim that compression already does is wrong.
- **Promises the app cannot keep:**
  - The scan footer offers "Notify me when this scan is ready" (`HomeView.swift:840-856`).
  - The settings alert says "…alert you when a background scan is ready" (`:198`).
  - `CleanupNotificationScheduler.schedule` posts with `trigger: nil` at completion (`HomeViewModel.swift:2598-2621`).
  - Foreground presentation is suppressed (`iOSCleanupApp.swift:76-83`, invariant 26).
- **After WS-28,** `.background` pauses the engine unless `hasContinuedProcessing`, which is always false so far.

### Implementation plan

**WS-29.0 — Verify-first spike on an iOS 26 device (not merged)**
On a throwaway branch, add a DEBUG button that submits a `BGContinuedProcessingTaskRequest` wrapping the existing scan. On a real iOS 26 device, confirm and write down in `docs/qa-runs/<date>-ws29-spike.md`:
1. Which is required:
   - registration with the wildcard `com.photoduck.app.scan.*` in `BGTaskSchedulerPermittedIdentifiers`, versus the exact `com.photoduck.app.scan.photos`;
   - whether registering at launch (`iOSCleanupApp.init`) is required, or registering later works;
   - whether any `UIBackgroundModes` entry is needed.
2. That `submit` succeeds with `strategy = .fail` when called from a button tap. Also test whether it succeeds from a Task started about 1 s after a tap; that decides the onboarding case (below).
3. That the system progress UI appears after leaving the app, and reflects `task.progress` and `updateTitle(_:subtitle:)`.
4. Whether the scan keeps making progress in the background:
   - count unanalyzed photos after 3 minutes in the background;
   - check whether Vision fails without `requiredResources = .gpu`, and whether `BGTaskScheduler.supportedResources.contains(.gpu)` on that device.
5. The expiration path. Trigger it with Xcode's debugger: `e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateExpirationForTaskWithIdentifier:@"com.photoduck.app.scan.photos"]`. Confirm the handler runs and how long the app keeps running after `setTaskCompleted`.

Adjust identifiers, plist keys and `requiredResources` in 29.3 to match. If background Vision fails even with the GPU resource, rely on WS-22's CPU retry. If that also fails, request no GPU and note it; the continuation still helps the video pre-pass and checkpointing. Put the results in the PR.

**WS-29.1 — `IdleTimerCoordinator` (single writer of `isIdleTimerDisabled`)**
- **Why:** The export's `defer` would turn the idle timer back on in the middle of a scan, and a scan must not keep it off after an export ends.
- **Change:** Create `iOSCleanup/Utilities/IdleTimerCoordinator.swift`:
  ```swift
  @MainActor
  final class IdleTimerCoordinator {
      static let shared = IdleTimerCoordinator()
      struct Token: Hashable, Sendable { fileprivate let id = UUID(); let reason: String }
      private var holders = Set<Token>()
      private var applied: Bool?
      private let apply: @MainActor (Bool) -> Void
      init(apply: @escaping @MainActor (Bool) -> Void = { UIApplication.shared.isIdleTimerDisabled = $0 }) { self.apply = apply }
      func acquire(reason: String) -> Token { let t = Token(reason: reason); holders.insert(t); sync(); return t }
      func release(_ token: Token?) { guard let token, holders.remove(token) != nil else { return }; sync() }
      var isHeld: Bool { !holders.isEmpty }
      private func sync() {
          let disabled = !holders.isEmpty
          guard applied != disabled else { return }
          applied = disabled; apply(disabled)
      }
  }
  ```
  **Canonical API (README contract 7).** Other workstreams use exactly these names:
  - `IdleTimerCoordinator.shared.acquire(reason: String) -> IdleTimerCoordinator.Token`;
  - `IdleTimerCoordinator.shared.release(_ token: Token?)`, where nil and repeated releases are no-ops;
  - the test seam `init(apply: @escaping @MainActor (Bool) -> Void)`, so tests build their own instance and never touch `UIApplication`.

  Reasons in use: `"export"` (below), `"scan"` (29.2) and `"compression"` (WS-44, chapter 09, which acquires when compression enters `.preparing` and releases on every exit path). There is no enum-based `acquire(.compression)` variant.

  In `ExternalExportCoordinator.swift` (WS-10), the idle-timer write lives in `ExternalExportLifecycle.live`'s `setIdleTimerDisabled` closure. Reshape it into `acquireIdleHold: @MainActor () -> IdleTimerCoordinator.Token?` and `releaseIdleHold: @MainActor (IdleTimerCoordinator.Token?) -> Void`. `.live` uses `IdleTimerCoordinator.shared.acquire(reason: "export")` and `IdleTimerCoordinator.shared.release(_:)`. `run` acquires where it used to disable the timer and releases in the same `defer`, on every path. Update WS-10's `ExternalExportCoordinatorTests` lifecycle fakes to match. Run `grep -rn isIdleTimerDisabled iOSCleanup`; afterwards it must match only `IdleTimerCoordinator.swift`.

**WS-29.2 — Keep the screen awake during active foreground scans**
- **Change:** Create `iOSCleanup/Views/Home/ScanIdleTimerPolicy.swift`:
  ```swift
  enum ScanIdleTimerPolicy {
      static func shouldKeepScreenAwake(scanState: HomeViewModel.ScanState, isVideoPassRunning: Bool,
                                        isVideoPrePassRunning: Bool, scenePhase: ScenePhase,
                                        thermalState: ProcessInfo.ThermalState) -> Bool {
          guard scenePhase == .active else { return false }
          guard thermalState == .nominal || thermalState == .fair else { return false }   // D-BACKGROUND
          return scanState == .scanning || isVideoPassRunning || isVideoPrePassRunning
      }
  }

  @MainActor
  final class ScanIdleTimerHold {
      private let coordinator: IdleTimerCoordinator
      private var token: IdleTimerCoordinator.Token?
      init(coordinator: IdleTimerCoordinator) { self.coordinator = coordinator }
      func update(keepAwake: Bool) {
          if keepAwake, token == nil { token = coordinator.acquire(reason: "scan") }
          else if !keepAwake, token != nil { coordinator.release(token); token = nil }
      }
  }
  ```
  `HomeViewModelDependencies` gains `idleTimerCoordinator: IdleTimerCoordinator` (live `.shared`). `HomeViewModel` owns a `ScanIdleTimerHold` and adds a single `private func refreshIdleTimerHold()`. Call it:
  - from `didSet` on `scanState` and `isVideoPrePassRunning`;
  - from the subscription to `LargeVideoScanController`'s `fileScanState` (the one WS-16 uses to forward `objectWillChange`);
  - from `updateScenePhase`;
  - from WS-25's monitor, `HomeViewModelDependencies.resourceMonitor`: iterate `stateUpdates()` in one task owned by `HomeViewModel`, and read the thermal input as `resourceMonitor.currentState.thermal`.

  A user or background pause (`scanState == .paused`) releases the hold, so the screen can lock. WS-25's thermal suspension is **not** a paused state: the scan stays `.scanning` with the cool-down message. The thermal guard (`.serious`/`.critical` → false) releases the hold there.

**WS-29.3 — `ScanBackgroundContinuation` abstraction and the iOS 26 implementation**
- **Change:** Create `iOSCleanup/Views/Home/ScanBackgroundContinuation.swift`:
  ```swift
  enum BackgroundContinuationState: Equatable, Sendable { case none, submitted, running }

  @MainActor
  protocol ScanBackgroundContinuing: AnyObject {
      var state: BackgroundContinuationState { get }
      var onStateChange: ((BackgroundContinuationState) -> Void)? { get set }
      /// false when the OS/device can't run a continuation now; the caller stays foreground-only.
      func begin(title: String, subtitle: String, onExpire: @escaping @MainActor () -> Void) -> Bool
      func update(completed: Int64, total: Int64, title: String?, subtitle: String?)  // implementation throttles to 1 Hz
      func end(success: Bool)                                                        // idempotent
  }

  @MainActor final class ForegroundOnlyScanContinuation: ScanBackgroundContinuing { /* begin returns false; state .none */ }

  enum ScanFooterPresentation {
      static func message(for state: BackgroundContinuationState) -> String {
          state == .running
              ? "You can switch apps. iOS keeps the scan going and shows its progress."
              : "Keep PhotoDuck open. Scanning pauses in the background."
      }
      static func showsNotifyMe(for state: BackgroundContinuationState) -> Bool { state != .none }
  }
  ```
  - `@available(iOS 26, *) @MainActor final class ContinuedProcessingScanContinuation: ScanBackgroundContinuing`, in the same file:
    - `static let taskIdentifier = "com.photoduck.app.scan.photos"`.
    - `private static weak var active: ContinuedProcessingScanContinuation?`.
    - `static func registerLaunchHandler()` calls `BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: .main)`. The handler does `MainActor.assumeIsolated`, casts to `BGContinuedProcessingTask` and hands it to `active?.attach(task)`; with no owner it calls `task.setTaskCompleted(success: false)`.
    - `begin` builds `BGContinuedProcessingTaskRequest(identifier:title:subtitle:)` with `strategy = .fail` (plus `requiredResources = .gpu` only if 29.0 showed it's needed and `BGTaskScheduler.supportedResources.contains(.gpu)`). It then calls `try BGTaskScheduler.shared.submit(request)`; any error returns false. On success it sets `Self.active = self; state = .submitted`.
    - `attach` sets `state = .running` and `task.expirationHandler = { Task { @MainActor [weak self] in self?.handleExpiration() } }`.
    - `update` sets `task.progress.totalUnitCount/completedUnitCount` and calls `task.updateTitle(_:subtitle:)` when changed.
    - `end` calls `task.setTaskCompleted(success:)` once and sets `state = .none`.
  - Confirm the API names against the iOS 26 SDK headers during 29.0, and adapt the sketch if the names differ.
  - `iOSCleanupApp.init`: `if #available(iOS 26, *) { ContinuedProcessingScanContinuation.registerLaunchHandler() }`. Tests don't boot the app (WS-03's AppEntry), so registration never runs in tests.
  - `Info.plist`: add `BGTaskSchedulerPermittedIdentifiers` = [`com.photoduck.app.scan.*`], or the exact identifier per 29.0. Add no `UIBackgroundModes` unless 29.0 proves one is required.
  - `HomeViewModelDependencies.makeScanBackgroundContinuation: @MainActor () -> any ScanBackgroundContinuing`. Live: `#available(iOS 26, *) ? ContinuedProcessingScanContinuation() : ForegroundOnlyScanContinuation()`. Tests inject a fake.

**WS-29.4 — Wire the continuation into the scan lifecycle**
- **Change** (`HomeViewModel`, delegating to the continuation object; about 40 lines):
  - `@Published private(set) var backgroundContinuationState: BackgroundContinuationState = .none`, mirrored through `onStateChange`.
  - **Begin** in `runUserInitiatedScan` (WS-27.6) before the pre-pass, and in the user-tapped `resumeDeepClean()`. Titles:
    - "Checking large videos" with subtitle `videoPassProgressLabel` during the pre-pass;
    - "Scanning your photos" with subtitle "\(processed.formatted()) of \(target.formatted()) photos checked" afterwards.

    Never begin for automatic scans, for `.returnFromBackground` or `.relaunch` resumes, or for `startPhotoScan(from: .onboardingFirstScan)`. Pass a `requestsBackgroundContinuation: entry != .onboardingFirstScan` flag down. The internal `refreshPhotoScan()` gains `requestsBackgroundContinuation: Bool = true`, so the direct calls from WS-31 and WS-45 (user taps) still begin a continuation. **DECISION (owner may override):** onboarding auto-start does not request a continuation, because Apple ties these requests to an explicit user action and the submit happens after the onboarding flow. If 29.0 shows a submit about 1 s after the tap succeeds, the owner may flip this.
  - **Progress:** from `publishProgressSnapshot()` (photos) and from the video progress publisher (pre-pass).
  - **End:**
    - `success: true` at the completion barrier and on the no-work path;
    - `success: false` on user pause, failure, permission error, supersession and cancellation.
  - **Expiry** (`onExpire`): if `currentScenePhase != .active && scanState == .scanning`, call `suspendActiveRun(reason: .backgrounded)` (WS-28; it takes its own lease and checkpoints). In every case, then call `end(success: false)`. If the app is in the foreground, the scan simply continues without the continuation.
  - Pass `hasContinuedProcessing: backgroundContinuationState == .running` into `ScenePhaseScanPolicy`. When it is true, `.background` performs `.checkpoint` (flush plus a scheduled checkpoint) instead of pausing.
  - WS-28's "engine started while backgrounded" check in `scanPhotos` also skips the pause when the state is `.running`.
- **Edge cases:**
  - `submit` fails with `.fail` strategy when the system can't run it now. The state stays `.none`, so the footer says "Keep PhotoDuck open" and there is no "Notify me".
  - After an expiry and a return to the foreground, WS-28's `.resumeFromBackground` resumes. A new continuation needs a new user tap (Continue); do not auto-submit.

**WS-29.5 — Honest copy and "Notify me" gating (VALUE-08 item 3, UI-09)**
- **Change** (`HomeView.swift`):
  - The scan footer (`:802-860`) adds `Text(ScanFooterPresentation.message(for: viewModel.backgroundContinuationState))` in `.duckCaption`/`Color.textSecondary` under the progress row.
  - Wrap the "Notify me" button in `if ScanFooterPresentation.showsNotifyMe(for: viewModel.backgroundContinuationState)`. Label: "Notify me when this scan is ready" stays; "Completion alert enabled" stays.
  - Change the alert at `:198` to "Turn on notifications in Settings to get an alert when a scan finishes while PhotoDuck is in the background."
  - The pre-prompt dialog copy (`:162-176`) stays.
  - WS-31 owns notification content, authorization refresh and routing.

**WS-29.6 — Optional: `BGProcessingTask` while charging on iOS 17–25**
Skip by default. Only do this if the PR is under about 800 lines and the owner asks. The shape:
- a `BGProcessingTaskRequest(identifier: "com.photoduck.app.scan.charging")` with `requiresExternalPower = true`, scheduled when a user scan pauses for background on iOS < 26;
- its handler resumes the incremental scan, and its expiration handler calls `suspendActiveRun(reason: .backgrounded)`;
- `UIBackgroundModes` = `processing`, plus the identifier in the permitted list;
- "Notify me" then also shows with the copy "…while your iPhone charges".

Otherwise open a `spec/BACKLOG.md` entry.

### Tests
- `iOSCleanupTests/IdleTimerCoordinatorTests.swift` (*new*, simulator):
  - `testFirstAcquireDisablesLastReleaseEnables`: two holders; `apply` is recorded as `[true]` then `[true, false]` only after both release.
  - `testReleaseIsIdempotent`.
  - `testApplyCalledOnlyOnChange`.
- `iOSCleanupTests/ScanIdleTimerPolicyTests.swift` (*new*): the full table over 6 `ScanState`s × {video pass, pre-pass} × 3 `ScenePhase`s × 4 thermal states. Key asserts:
  - scanning + active + nominal → true;
  - scanning + active + serious → false;
  - scanning + background → false;
  - paused → false;
  - idle + video pass + active + fair → true.
- `iOSCleanupTests/ScanBackgroundContinuationTests.swift` (*new*), with a `FakeScanContinuation` that records calls and can `simulateRunning()`/`simulateExpire()`, injected via `HomeViewModelDependencies`:
  - `testUserScanBeginsContinuation`.
  - `testAutomaticScanNeverBegins`.
  - `testOnboardingAutoStartNeverBegins`.
  - `testRelaunchAndBackgroundResumeNeverBegin`.
  - `testCompletionEndsWithSuccess`.
  - `testUserPauseEndsWithoutSuccess`.
  - `testExpiryInBackgroundPausesWithBackgroundReason`: `updateScenePhase(.background)` while running performs `.checkpoint` (no pause); then `simulateExpire()` → `scanState == .paused`, `pauseReason == .backgrounded`, and end(false).
  - `testFooterPresentation`: `.none` → no Notify me plus the "Keep PhotoDuck open" copy; `.submitted`/`.running` → Notify me shown.
- Device-only: 29.0 and the Device QA below.

### Acceptance criteria
- [ ] `grep -rn isIdleTimerDisabled iOSCleanup` matches only `IdleTimerCoordinator.swift`. Export and scan overlap correctly (coordinator tests).
- [ ] During an active foreground scan or video pass with thermal `.nominal`/`.fair`, the screen does not auto-lock. When paused, finished, backgrounded or at `.serious`+, it can (device).
- [ ] On iOS 26, a user-started scan submits a continued-processing request, shows system progress when the user leaves the app, continues, and ends with `setTaskCompleted`. On expiry in the background it pauses with a checkpoint and resumes on return (device, plus the fake tests).
- [ ] "Notify me" appears only while a continuation is submitted or running. No copy promises background progress otherwise.
- [ ] The 29.0 spike results are recorded in `docs/qa-runs/`.
- [ ] Zero warnings; the full suite is green.
- [ ] `ios-cleanup/CLAUDE.md` documents:
  - `IdleTimerCoordinator` as the single owner;
  - the continuation rules (user-initiated only; not for onboarding, auto-resume or automatic scans);
  - the "Notify me" gating.

### Device QA
1. Settings → Display → Auto-Lock 30 s. Start a scan and leave the phone untouched on Home for 3 minutes; the screen stays on. Tap Pause; the screen locks within about 30 s.
2. Xcode → Devices → Device Conditions → Thermal State "Serious" during a scan. The screen is allowed to lock. Set it back to Nominal; the hold returns.
3. Start an Export Album export during a scan and let the export finish. The screen stays awake while the scan continues.
4. On an iOS 26 device, tap Start scan, then go to the Home Screen:
   - system progress appears and advances;
   - return after 2 minutes: progress has moved and unanalyzed has not grown;
   - the completion notification arrives if enabled.
5. On iOS 26, simulate expiry with the debugger command from 29.0 while backgrounded. The scan pauses with a checkpoint, and on return it resumes automatically; the footer switches to "Keep PhotoDuck open".
6. On an iOS 17–25 device, the footer reads "Keep PhotoDuck open. Scanning pauses in the background." and no "Notify me" button is shown.

### Pitfalls and out of scope
- Never write `UIApplication.shared.isIdleTimerDisabled` outside the coordinator.
- Never submit a continuation for automatic or auto-resumed work.
- The expiration handler must not await long work before `setTaskCompleted`. WS-28's lease covers the checkpoint.
- A continuation that is `.submitted` but not yet `.running` must not skip WS-28's pause.
- Out of scope:
  - notification content, authorization refresh and routing: WS-31 (chapter 07);
  - compression's idle timer and background task: WS-44 (chapter 09);
  - moving this into `PhotoScanCoordinator`: WS-49 (chapter 11).
- **Reconciliation (README contract 7):** 29.1 states the canonical `IdleTimerCoordinator` API: `shared.acquire(reason: String) -> Token`, `release(_ token: Token?)` and the `init(apply:)` test seam. WS-44 uses `acquire(reason: "compression")` and releases on every exit. UI-09's claim that compression already disables the idle timer is wrong, so WS-44 must adopt the coordinator.
- **Reconciliation (WS-10 export lifecycle):** the export's idle-timer write sits in WS-10's `ExternalExportLifecycle.live`. 29.1 swaps it there for acquire and release closures, so the change stays local to `ExternalExportCoordinator.swift`.
- **Reconciliation (WS-25 API):** the thermal input comes from `HomeViewModelDependencies.resourceMonitor` (`currentState.thermal`, `stateUpdates()`). Thermal suspension keeps `scanState == .scanning`, so the thermal guard, not a paused state, releases the screen hold.
- **Reconciliation (README contract 1):** `refreshPhotoScan()` is internal and takes a defaulted `requestsBackgroundContinuation`, so WS-31 and WS-45 can call it directly.

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| VALUE-08 | confirmed | No BGTaskScheduler, no plist keys, no idle timer during scans, and the "Notify me" and "background scan" copy are all verified at the cited lines. The plan uses an ownership-counting `IdleTimerCoordinator` instead of a boolean `updateIdleTimer()`, gated by WS-25's thermal state (D-BACKGROUND). The iOS 16–25 `BGProcessingTask` is optional (29.6), not default. The continuation is never requested for automatic, auto-resumed or onboarding-started scans. |
| UI-09 (merged) | confirmed | Minor inaccuracy: `FileResultsView.swift:1155` is the selected-video *export*; compression never disables the idle timer (WS-44 adopts the coordinator). Its item 4 ("paused while in background — continuing" message) is covered by WS-28's transparent auto-resume, where the hero never shows paused for background. |
