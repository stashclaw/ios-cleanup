# Chapter 02 — Dev loop: CI, simulator fixtures, engine safety nets and a device baseline

> **Milestone(s):** M0 · **Workstreams:** WS-06 – WS-10 · Read `spec/README.md` first: operating rules, invariants, build/test commands and the decision log apply to every workstream here.

## Chapter overview

Every later workstream needs to prove its change safe. Today nothing does that automatically. There is no CI. The Release configuration is never compiled. Five tests race the wall clock. The simulator cannot analyze a single photo (Vision error 9, runtime RT-1). `HomeViewModel` cannot be built in a test. No test ever drives a real scan to an explicit keeper/delete plan. Nothing measures scale, and nobody has timed the app on a real 10k–60k library.

This chapter builds that dev loop:
- **WS-06:** CI, test plans and deterministic tests. It also raises the minimum OS to iOS 17.
- **WS-07:** a simulator fixture harness and the `HomeViewModel` dependency seam.
- **WS-08:** engine golden-path, lifecycle and scale tests.
- **WS-09:** a device QA plan, signposts and a baseline run.
- **WS-10:** the mechanical split of the two giant view files.

When the chapter is done, an agent can reach Keep Best and Duck Mode in the simulator, and CI blocks regressions in Release builds, in determinism and in growth ratios. M1 also gets sized against real device numbers. The main risk is that the harness itself changes behavior. Everything fixture-related is `#if DEBUG && targetEnvironment(simulator)` and keeps its own stores, and every seam defaults to today's singletons.

---

## WS-06 — CI, test plans and deterministic tests

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M0 | M | WS-03 | no | `ws/06-ci-test-plans` |

**Primary files:**
- **Build and CI:** `scripts/test.sh` (*new*), `scripts/build-release.sh` (*new*), `scripts/sim-udid.sh` (*new*), `.github/workflows/ci.yml` (*new*), `.github/workflows/performance.yml` (*new*), `iOSCleanup.xctestplan` (*new*), `Performance.xctestplan` (*new*), `iOSCleanup.xcodeproj/xcshareddata/xcschemes/iOSCleanup.xcscheme`, `iOSCleanup.xcodeproj/project.pbxproj`.
- **App code:** `iOSCleanup/Engines/SimilarityCoreMLClassifier.swift`, `iOSCleanup/Engines/PhotoScanEngine.swift` (`PhotoScanAnalysisCoordinator` only), `iOSCleanup/Views/Photos/SwipeModeViewModel.swift`.
- **The six views with `onChange` call sites:** `iOSCleanup/ContentView.swift`, `iOSCleanup/Views/PhotoDuckShellView.swift`, `iOSCleanup/Views/HomeView.swift`, `iOSCleanup/Views/Files/FileResultsView.swift`, `iOSCleanup/Views/Photos/PhotoResultsView.swift`, `iOSCleanup/Views/Photos/SwipeModeView.swift`.
- **Tests:** `iOSCleanupTests/Support/AsyncTestSupport.swift` (*new*), `iOSCleanupTests/TestHygieneLintTests.swift` (*new*), `iOSCleanupTests/ScalePerformanceTests.swift` (*new*, placeholder that WS-08 fills), `iOSCleanupTests/PhotoScanEngineTests.swift`, `iOSCleanupTests/SimilarityPolicyTests.swift`, `iOSCleanupTests/PhotoMLStoreTests.swift`, `iOSCleanupTests/PhotoImageRepositoryTests.swift` (created by WS-03's split; use `FileScanEngineTests.swift` if that test was not moved).
- **Docs:** `CLAUDE.md`, `README.md`, `PhotoDuckWidgets/README.md`.

**Findings covered:** BUILD-08 (P2, confirmed), BUILD-10 (P2, partially), BUILD-14 (P2, confirmed)

**Decisions applied:**
- **D-MIN-OS:** set `IPHONEOS_DEPLOYMENT_TARGET = 17.0` on the project, app, test and widget configurations. The owner confirms before this workstream starts. If there is no answer, proceed with 17.0 and say so in the PR. The override path is described in WS-06.1.
- **D-PERF-GATE:** add a separate `Performance.xctestplan` that the PR job never runs. It runs nightly and on PRs labelled `performance`. WS-08 fills it.

### Goal
- Every PR and every push to `main` runs the default test plan (`iOSCleanup.xctestplan`) on an iPhone simulator, plus a Release device build with `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`.
- The documented test command works on any Mac with Xcode 26.
- No test uses a wall-clock sleep to order events.
- The test target can be signed for device runs.
- The deployment target is 17.0 everywhere, with zero warnings.

### Current behavior (verified)
- **No CI:** there is no `.github/` and no `scripts/` directory at the repo root (`ios-cleanup/`).
- **Scheme:** `iOSCleanup.xcodeproj/xcshareddata/xcschemes/iOSCleanup.xcscheme:25-44`:
  - The TestAction has `shouldAutocreateTestPlan = "YES"`.
  - One `TestableReference` has `parallelizable = "YES"`. The runtime log shows "Clone 1 of iPhone 17 Pro".
  - There is no coverage setting.
  - The StoreKit configuration is attached only to the LaunchAction (`:65-67`).
- **Deployment targets and signing in `project.pbxproj`:**
  - The project Debug/Release configurations set `IPHONEOS_DEPLOYMENT_TARGET = 16.0;` (`:697`, `:755`). So do the app (`:777`, `:798`) and the tests (`:815`, `:832`).
  - The widget sets `16.2` (`:851`, `:875`).
  - The test configurations `AA0000010000000000000D05`/`D06` (`:808-841`) have `CODE_SIGN_STYLE = Automatic;` and no `DEVELOPMENT_TEAM`. The app and widget use `JTNQE5NB5K`.
- **Docs:**
  - `CLAUDE.md:6` says "iOS 16.0 minimum".
  - `CLAUDE.md:12-22` hard-codes `name=iPhone 16`, but `CLAUDE.md:80` says only iPhone 17 Pro exists.
  - `README.md:9` says "iOS 16.0+", `README.md:64` says `iPhone 15`, and `PhotoDuckWidgets/README.md:10` says 16.2.
- **Raising the target to 17.0 is not warning-free.** A `swiftc -typecheck` of the app sources at `-target arm64-apple-ios17.0-simulator` gives 20 warnings and 2 errors; the same check at 16.0 is clean.
  - **20 warnings:** `'onChange(of:perform:)' was deprecated in iOS 17.0`, at:
    - `ContentView.swift:22`
    - `PhotoDuckShellView.swift:80, 88`
    - `HomeView.swift:213, 1548, 1553, 1557, 1561, 1569`
    - `FileResultsView.swift:464, 485, 494, 498, 501, 506`
    - `PhotoResultsView.swift:162, 167, 170`
    - `SwipeModeView.swift:56, 59`
  - **2 errors:** `expression is 'async' but is not marked with 'await'` at `SimilarityCoreMLClassifier.swift:122` and `:199`. Both are `prediction = try model.prediction(from: provider)` inside `async` actor methods. On iOS 17, overload resolution picks the new async `MLModel.prediction(from:)`.
  - The widget sources and the test sources compile clean at 17.0, apart from the 7 known `PurchaseManagerTests` warnings (fixed by WS-03 / BUILD-19).
  - The `guard #available(iOS 16.2, *)` lines in `ExternalPhotoExportService.swift:1686…1833` do **not** warn at 17.0 (verified with swiftc), so this workstream does not touch that file.
- **Timing-dependent tests:**
  - `PhotoScanEngineTests.swift:512-567` (`testTimedOutSlotIsReleasedExactlyOnceWhenOperationLaterCompletes`):
    - It sleeps 100 ms (`:532`) hoping the late completion has run.
    - It sleeps 20 ms (`:556`) assuming `async let blocking` already holds the only slot. If it doesn't, `rejected` gets the slot and `XCTAssertNil` fails.
  - `PhotoScanEngineTests.swift:473-510` (`testAnalysisWatchdogBoundsHungOperations`) uses a real 50 ms watchdog. Under load the *second* operation can also time out before its detached task runs, and then `XCTAssertEqual(second.embedding, Data([2]))` fails.
  - `PhotoScanAnalysisCoordinator` (`PhotoScanEngine.swift:240-305`):
    - `timeoutNanoseconds` is already injectable (`:245-254`).
    - The watchdog is `Task.sleep(nanoseconds:)` inside a detached task (`:272-283`).
    - `releaseSlot` (`:302-305`) is guarded by `PhotoScanSlotReleaseBox.markReleased()`.
  - `SwipeModeViewModel.swift:90-97` (`beginTransition`) sleeps a hard-coded 250 ms. `SimilarityPolicyTests.swift:505-532` (`testDuckModeUndoLastSwipeRestoresPendingDecision`) sleeps 350 ms to outlast it. `SwipeModeView.swift:13` is the only production caller of `SwipeModeViewModel(groups:)`.
  - `FileScanEngineTests.swift:686-707` (`testImageRepositoryCancelsPhotoWorkAfterFinalConsumerLeaves`, moved to `PhotoImageRepositoryTests.swift` by WS-03):
    - It sleeps 50 ms, then cancels. If the request has not started, `startedCount == 0` and the test fails.
    - It then polls for at most 200 ms.
  - `PhotoMLStoreTests.swift:1416-1436` (`testMLKeeperRankingCancellationFallsBackToAuthoritativeHeuristic`) sleeps 10 ms before cancelling. This does **not** flake, because both orders return the heuristic (`MLEnhancedKeeperRankingService.swift:43` checks `Task.isCancelled`). But it never proves the cancel lands mid-prediction.
  - `PhotoScanEngineTests.swift:996-1008` (`testScanCancellationPropagatesIntoInFlightAssetAnalysis`) polls with 100 × 5 ms, a 500 ms deadline that is too short for a loaded CI runner.
- **Test run time:** the whole suite runs in about 5 s (`test.log`: the slowest test takes 0.5 s).

### Implementation plan

**WS-06.1 — Minimum OS 17.0 and test-target signing (BUILD-14, D-MIN-OS)**
- **Why:** 16.x has never been run. CI would need a second destination. BUILD-04 needs `setComputeDevice` (iOS 17). The test bundle cannot be signed for a device, so the only Vision contract test can never run.
- **Change:**
  0. Check `spec/README.md` §6 for the owner's answer on D-MIN-OS.
     - **Override path:** if the owner overrode it, set the app to 16.2, leave the widget at 16.2 and skip steps 2–3. Add a CI matrix entry for an iOS 16.4 simulator runtime, installing it on the runner if the image has none, and note the extra minutes. WS-07 then needs `#available(iOS 17, *)` around `setComputeDevice`.
  1. In `project.pbxproj`, set `IPHONEOS_DEPLOYMENT_TARGET = 17.0;` in all 8 configurations: `:697`, `:755`, `:777`, `:798`, `:815`, `:832`, `:851`, `:875`. Add `DEVELOPMENT_TEAM = JTNQE5NB5K;` to both test configurations (`D05`, `D06`).
  2. Migrate the 20 `onChange` sites mechanically to the two-parameter form: `.onChange(of: x) { newValue in … }` becomes `.onChange(of: x) { _, newValue in … }`. Where the closure ignores its value (`{ _ in`), use the zero-parameter form `{ … }`. The new API with `initial: false` (the default) fires exactly when the old one did, so behavior is unchanged.
  3. `SimilarityCoreMLClassifier.swift:122` and `:199`: keep today's **synchronous** prediction, with no behavior change and no new Sendable crossings. Call a nonisolated sync helper:
     ```swift
     extension MLKeeperRankingService {   // and the same for MLGroupActionService
         /// A synchronous context resolves to the synchronous overload. On iOS 17
         /// an async context would pick `prediction(from:) async`.
         nonisolated static func predictSynchronously(
             _ model: MLModel, _ provider: MLFeatureProvider
         ) throws -> MLFeatureProvider {
             try model.prediction(from: provider)
         }
     }
     // call sites: prediction = try Self.predictSynchronously(model, provider)
     ```
     This variant was type-checked clean under `-strict-concurrency=complete` at iOS 17.
  4. Docs: `CLAUDE.md:6` should read "iOS 17.0 minimum"; also set `README.md:8-10` (Xcode 26, iOS 17.0+) and `PhotoDuckWidgets/README.md:10` (17.0; `ActivityContent` is always available).
- **Edge cases:**
  - Keep `@available(iOS 16.1, *)` on `FileScanEngineTests.swift:891`. It is harmless.
  - Keep `#available(iOS 18.4, *)` in `PurchaseManager.swift:66`.
  - Do not remove the `ExternalPhotoExportService` guards (see Pitfalls).

**WS-06.2 — Deterministic async test support (BUILD-10 foundation)**
- **Why:** Tests need explicit synchronization primitives instead of sleeps. Adding them once in `Support/` stops later workstreams from inventing their own.
- **Change:** new `iOSCleanupTests/Support/AsyncTestSupport.swift`, holding the three helpers below. All three were type-checked under strict concurrency.
  ```swift
  import XCTest

  /// Polls with a deadline. Polling is allowed; fixed sleeps used for ordering are not.
  @MainActor @discardableResult
  func waitUntil(
      timeout: Duration = .seconds(5),
      pollInterval: Duration = .milliseconds(10),
      file: StaticString = #filePath, line: UInt = #line,
      _ condition: @MainActor () async -> Bool
  ) async -> Bool {
      let clock = ContinuousClock()
      let deadline = clock.now.advanced(by: timeout)
      while clock.now < deadline {
          if await condition() { return true }
          try? await Task.sleep(for: pollInterval) // test-sleep-ok: deadline polling
      }
      let met = await condition()
      if !met { XCTFail("Condition not met within \(timeout)", file: file, line: line) }
      return met
  }

  /// One-shot latch. signal() may happen before or after wait().
  actor TestSignal { /* isSignalled + [CheckedContinuation<Void, Never>]; signal() resumes all */ }

  /// A gate that parks callers until open() is called.
  actor TestGate { /* moved from PhotoScanEngineTests' private PhotoScanTestGate */ }
  ```
  - Move `PhotoScanTestGate` (`PhotoScanEngineTests.swift:2170-2186`) into this file as `TestGate`, and update its references.
  - Add `ManualWatchdog` here too. It is an actor whose `nonisolated var sleep: PhotoScanAnalysisCoordinator.WatchdogSleep` parks each caller until `fireAll()`, and throws `CancellationError` when the caller's task is cancelled. It keeps a `cancelledBeforeArming` set so a cancel that races ahead of arming never leaves a continuation stranded. It exposes `armedCount`.
- **Edge cases:**
  - `waitUntil` is `@MainActor` so conditions can read `@MainActor` view models. From nonisolated tests, call it with `await`.
  - `TestGate.wait()` is not cancellation-aware. Never use it inside work that the test cancels; use `Task.sleep` in the stub for that (allowed, see WS-06.5).

**WS-06.3 — Watchdog seam and deterministic coordinator tests (BUILD-10)**
- **Why:** This removes the 20 ms and 100 ms sleeps and the load-sensitive 50 ms real watchdog.
- **Change:** confine all edits to `PhotoScanAnalysisCoordinator` (`PhotoScanEngine.swift:240-305`). Do not touch the rest of the engine; WS-07, WS-08 and WS-22 edit it.
  ```swift
  actor PhotoScanAnalysisCoordinator {
      typealias WatchdogSleep = @Sendable (_ nanoseconds: UInt64) async throws -> Void
      private let watchdogSleep: WatchdogSleep
      #if DEBUG
      private(set) var debugReleaseAttemptCount = 0            // test observability only
      var debugActiveOperationCount: Int { activeOperationCount }
      #endif
      init(maximumConcurrentOperationCount: Int,
           timeoutNanoseconds: UInt64 = 15_000_000_000,
           watchdogSleep: @escaping WatchdogSleep = { try await Task.sleep(nanoseconds: $0) }) { … }
      // In analyze(): the timeout task awaits `try await watchdogSleep(timeoutNanoseconds)`
      // in place of Task.sleep. Nothing else changes.
      private func releaseSlot(_ slot: PhotoScanSlotReleaseBox) {
          #if DEBUG
          debugReleaseAttemptCount += 1
          #endif
          guard slot.markReleased() else { return }
          activeOperationCount = max(activeOperationCount - 1, 0)
      }
  }
  ```
  - The production call site (`:596-605`) keeps its arguments, so it uses the default sleeper.
  - Rewrite `testAnalysisWatchdogBoundsHungOperations`:
    1. Start `first` in a `Task` whose operation waits on a `TestGate`.
    2. `await waitUntil { await watchdog.armedCount == 1 }`, then `await watchdog.fireAll()`.
    3. Assert `first.value.embedding == nil`.
    4. Run `second`. Its watchdog is armed but never fired. Assert it returns `Data([2])` and the invocation count is 2.
    5. Open the gate.
  - Rewrite `testTimedOutSlotIsReleasedExactlyOnceWhenOperationLaterCompletes`:
    1. Time out A as above, then open A's gate.
    2. `await waitUntil { await coordinator.debugReleaseAttemptCount == 2 }`. The two attempts are the timeout release and the late-completion release.
    3. Assert `debugActiveOperationCount == 0`.
    4. Start B. B signals a `TestSignal` when it starts, then waits on gate B. `await started.wait()`.
    5. Assert that `rejected` returns `embedding == nil` and `debugActiveOperationCount == 1`.
    6. Open gate B and assert B returns `Data([3])`.
- **Edge cases:** The default `watchdogSleep` must keep the exact production timeouts: 15 s, and 45 s with network (`:602-604`).
- **Forward note:** WS-22.4 (chapter 05) later changes only the default timeout, to `PhotoAnalysisTimeBudget.watchdog`, and keeps this injection. WS-24.6 restructures the timeout as a structured child task. That child must still await `watchdogSleep(timeoutNanoseconds)`, not `Task.sleep`, and keep the DEBUG counters, or these two tests lose their determinism.

**WS-06.4 — Injectable Duck Mode transition delay (BUILD-10)**
- **Change** in `SwipeModeViewModel.swift`:
  - Change the initializer to `init(groups: [PhotoGroup], transitionDelayNanoseconds: UInt64 = 250_000_000)` and store the delay.
  - In `beginTransition` (`:90-97`), sleep only `if transitionDelayNanoseconds > 0`.
  - Add `func waitForPendingTransition() async { await transitionTask?.value }`.
  - Rewrite the test:
    ```swift
    let viewModel = SwipeModeViewModel(groups: [group], transitionDelayNanoseconds: 0)
    viewModel.delete(); await viewModel.waitForPendingTransition()
    ```
    Keep every existing assertion.
- **Edge cases:** `SwipeModeView.swift:13` keeps the default 250 ms. Do not change Duck Mode visuals or timing.

**WS-06.5 — Remaining ordering sleeps (BUILD-10)**
- **Image repository cancellation** (test `testImageRepositoryCancelsPhotoWorkAfterFinalConsumerLeaves`):
  - Give `ImageOperationProbe` a `let started = TestSignal()`. In `makeImage()`, call `await started.signal()` right after incrementing `starts`.
  - Replace the 50 ms sleep with `await probe.started.wait()`.
  - Replace the 20 × 10 ms loop with `await waitUntil { probe.cancelledCount == 1 }`.
- **ML ranking cancellation** (`PhotoMLStoreTests`):
  - Add a private `CancellableKeeperPredictionService` actor. Its `predictKeeper` does `await started.signal(); try? await Task.sleep(for: .seconds(60)) // test-sleep-ok: cancelled stub`, then returns a prediction, and it counts calls.
  - The test awaits `started.wait()`, then cancels.
  - Assert that the result equals the heuristic and that the predictor was called exactly once. The call count proves the cancel landed mid-flight.
- **Engine cancellation polling:** in `PhotoScanEngineTests.swift:996-1008`, replace both loops with `waitUntil` (default 5 s).
- **Lint:** every remaining `Task.sleep` in `iOSCleanupTests/` must carry a trailing `// test-sleep-ok: <reason>` comment. Allowed reasons:
  - a stub simulating latency (for example `:720`);
  - a stub meant to be cancelled (`ScanAnalyzerProbe`, `VideoCompressionEngineTests.swift:250`, `ConfigurableKeeperPredictionService`);
  - deadline polling inside `waitUntil`;
  - the 1 ms elapsed-time separation in `testDiagnosticExportUsesCurrentSessionElapsedCutoff` (WS-02's rename of the test at `FileScanEngineTests.swift:2216`; it lives in `PhotoDuckDiagnosticLogTests.swift` after WS-03's split).
- **Enforcement:** new `iOSCleanupTests/TestHygieneLintTests.swift` scans every `.swift` file under `iOSCleanupTests/`. Use the `#filePath` pattern from `DesignLintTests.swift:69-99`, including its `XCTSkip` when sources are unavailable. The test fails on any `Task.sleep` / `usleep(` / `Thread.sleep` line without the marker.

**WS-06.6 — Test plans and scheme (BUILD-08, D-PERF-GATE)**
- **Change:**
  - `iOSCleanup.xctestplan` (*new*, repo root) is the default plan, a JSON file:
    ```json
    {
      "configurations" : [ { "id" : "<new UUID>", "name" : "Default", "options" : { } } ],
      "defaultOptions" : {
        "codeCoverage" : { "targets" : [ { "containerPath" : "container:iOSCleanup.xcodeproj",
                                           "identifier" : "AA0000010000000000000701", "name" : "iOSCleanup" } ] },
        "testExecutionOrdering" : "random"
      },
      "testTargets" : [ { "parallelizable" : false, "skippedTests" : [ "ScalePerformanceTests" ],
                          "target" : { "containerPath" : "container:iOSCleanup.xcodeproj",
                                       "identifier" : "AA0000010000000000000702", "name" : "iOSCleanupTests" } } ],
      "version" : 1
    }
    ```
  - `Performance.xctestplan` (*new*) has the same shape, with no `codeCoverage` and no random ordering, and `"selectedTests" : [ "ScalePerformanceTests" ]` in place of `skippedTests`. If Xcode rewrites these keys when you open the plan, commit what Xcode writes.
  - `iOSCleanupTests/ScalePerformanceTests.swift` (*new*) contains `final class ScalePerformanceTests: XCTestCase { func testPerformancePlanIsWired() { XCTAssertTrue(true) } }`, so the nightly job runs from day one. WS-08 replaces the body. Add it to `project.pbxproj` (recipe in Pitfalls).
  - In the scheme's `TestAction`:
    - delete `shouldAutocreateTestPlan = "YES"` and the whole `<Testables>` block;
    - add:
    ```xml
    <TestPlans>
       <TestPlanReference reference = "container:iOSCleanup.xctestplan" default = "YES"> </TestPlanReference>
       <TestPlanReference reference = "container:Performance.xctestplan"> </TestPlanReference>
    </TestPlans>
    ```
  - Verify that `xcodebuild -project iOSCleanup.xcodeproj -scheme iOSCleanup -showTestPlans` lists both plans.
  - **Plan names are a contract.** There are exactly two plans: `iOSCleanup.xctestplan` (the default; a plain `xcodebuild … test` and `scripts/test.sh` run it) and `Performance.xctestplan` (run with `-testPlan Performance`). There is **no** `Unit` plan. Any later reference to "the unit plan" or `-testPlan Unit` means the default `iOSCleanup.xctestplan`; per-class options such as WS-36's non-parallel purchase tests go into that plan.
- **Edge cases:**
  - **Random order:** it implements BUILD-09's random-ordering item, which WS-03 deferred to this plan. Run the suite at least 3 times. If any test is order-dependent (shared singletons such as `ExternalPhotoExportSessionGate.shared`, `AssetFileSizeCache.shared`, `PhotoFeedbackStore.shared`), isolate its state. Do not turn randomization off.
  - **StoreKit:** do not add a StoreKit configuration to the test plan here. WS-36 adds it together with its StoreKitTest tests, using Xcode's plan editor so the key is written correctly.

**WS-06.7 — Scripts (BUILD-08)**
- `scripts/sim-udid.sh <name>`:
  - Prints the UDID of the named available iPhone simulator. If that name doesn't exist, it prints the UDID of the first available iPhone on the newest iOS runtime.
  - Use `xcrun simctl list devices available --json` piped into a short `python3` script that reads the name from an environment variable. Only consider devices whose names start with "iPhone": this Mac has custom-named devices such as "CatJack Journey Audit".
  - Exit non-zero if none is found.
- `scripts/test.sh [extra xcodebuild args]`:
  ```bash
  #!/usr/bin/env bash
  set -euo pipefail
  cd "$(dirname "$0")/.."
  UDID="$(scripts/sim-udid.sh "${SIM_NAME:-iPhone 17 Pro}")"
  RESULT_BUNDLE="${RESULT_BUNDLE:-build/TestResults.xcresult}"
  rm -rf "$RESULT_BUNDLE"
  EXTRA=()
  [[ "${CI:-}" == "true" ]] && EXTRA+=(CODE_SIGNING_ALLOWED=NO)
  xcodebuild -project iOSCleanup.xcodeproj -scheme iOSCleanup \
    -destination "platform=iOS Simulator,id=$UDID" \
    -parallel-testing-enabled NO -resultBundlePath "$RESULT_BUNDLE" \
    SWIFT_TREAT_WARNINGS_AS_ERRORS="${WARNINGS_AS_ERRORS:-YES}" \
    ${EXTRA[@]+"${EXTRA[@]}"} test "$@"
  ```
  - `${EXTRA[@]+…}` is required: macOS ships bash 3.2, where `"${EXTRA[@]}"` on an empty array fails under `set -u`.
  - `scripts/test.sh -testPlan Performance` runs the benchmarks.
  - `scripts/test.sh -only-testing:iOSCleanupTests/Foo/testBar` runs one test.
- `scripts/build-release.sh`:
  ```bash
  xcodebuild -project iOSCleanup.xcodeproj -scheme iOSCleanup -configuration Release \
    -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES build
  ```
- Make all three scripts executable (`chmod +x`) and commit them with that mode.

**WS-06.8 — GitHub Actions (BUILD-08)**
- `.github/workflows/ci.yml` (inside `ios-cleanup/`, which is the repo root after WS-01):
  - `on: pull_request` and `push: branches: [main]`.
  - `concurrency: { group: ci-${{ github.ref }}, cancel-in-progress: true }`.
  - One job, `runs-on: macos-26`, `timeout-minutes: 45`. Steps:
    1. `actions/checkout@v4`.
    2. Select Xcode: `ls -d /Applications/Xcode*.app`, then `sudo xcode-select -s "$(ls -d /Applications/Xcode_26*.app | sort -V | tail -1)"`, `xcodebuild -version`, `xcrun simctl list devices available`.
    3. `plutil -lint iOSCleanup/Info.plist PhotoDuckWidgets/Info.plist iOSCleanup/PrivacyInfo.xcprivacy PhotoDuckWidgets/PrivacyInfo.xcprivacy iOSCleanup.xctestplan Performance.xctestplan`.
    4. `scripts/test.sh`.
    5. `scripts/build-release.sh`.
    6. `actions/upload-artifact@v4` with `if: failure()`, uploading `build/TestResults.xcresult`.
- `.github/workflows/performance.yml`:
  - `on: schedule` (`cron: '0 7 * * *'`), `workflow_dispatch`, and `pull_request: types: [labeled, synchronize]`.
  - The job runs only when `github.event_name != 'pull_request' || contains(github.event.pull_request.labels.*.name, 'performance')`.
  - It uses the same Xcode selection, then `scripts/test.sh -testPlan Performance` with `RESULT_BUNDLE=build/Performance.xcresult`, and always uploads the bundle.
- **Edge cases:**
  - **Runner image:** confirm the image in the first run. If `macos-26` is unavailable, use the newest `macos-*` image that ships Xcode 26.x and note it in the PR.
  - **Signing:** if hosted tests fail to launch because of `CODE_SIGNING_ALLOWED=NO`, drop that flag for the test job. Simulator builds sign ad hoc, and the app has no entitlements file.
  - **Branch protection** is an owner action. So is the one-off deliberately failing PR that proves the check blocks merges: it needs a push, which needs owner approval.

**WS-06.9 — Docs**
- Replace the command blocks in `CLAUDE.md:10-23` and `README.md:61-65` with:
  - `scripts/test.sh`
  - `scripts/test.sh -only-testing:iOSCleanupTests/<Class>/<test>`
  - `scripts/test.sh -testPlan Performance`
  - `scripts/build-release.sh`
- Add three lines to `CLAUDE.md` Key constraints:
  - "CI runs unit tests plus a Release build with warnings as errors."
  - "Tests never sleep for ordering; use `Support/AsyncTestSupport.swift`."
  - "New `Task.sleep` in tests needs `// test-sleep-ok:`."

### Tests
All run in the simulator unless noted.
- **Existing tests rewritten** (named above) in `PhotoScanEngineTests`, `SimilarityPolicyTests`, `PhotoImageRepositoryTests` and `PhotoMLStoreTests`. Each keeps its original assertions and adds the new ones:
  - the release-attempt count;
  - `debugActiveOperationCount == 1` while B holds the slot;
  - the predictor was called exactly once.
- `TestHygieneLintTests.testNoUnmarkedSleepsInTests` fails when a `Task.sleep` line lacks `test-sleep-ok`. To check it, temporarily add an unmarked line to a test file and confirm the failure; do not commit that line.
- `ScalePerformanceTests.testPerformancePlanIsWired` runs only in the Performance plan. Check with `scripts/test.sh -testPlan Performance`.
- **Stress run** (local, record in the PR):
  1. Start CPU load with `yes > /dev/null &` four times.
  2. Run:
     ```bash
     scripts/test.sh -only-testing:iOSCleanupTests/PhotoScanEngineTests \
       -only-testing:iOSCleanupTests/SimilarityPolicyTests \
       -only-testing:iOSCleanupTests/PhotoImageRepositoryTests \
       -only-testing:iOSCleanupTests/PhotoMLStoreTests \
       -test-iterations 50 -run-tests-until-failure
     ```
  3. Kill the load.
- **Device-only:** `testPinnedVisionFeaturePrintScaleUsingDeterministicFixtures` on a connected iPhone (Device QA below).

### Acceptance criteria
- [ ] All 8 configurations have `IPHONEOS_DEPLOYMENT_TARGET = 17.0`, or the documented override if the owner chose it. Both test configurations have `DEVELOPMENT_TEAM = JTNQE5NB5K`.
- [ ] `scripts/build-release.sh` succeeds with `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`. `grep -rn "onChange(of:[^)]*) { [a-zA-Z_]* in" iOSCleanup` returns nothing.
- [ ] `scripts/test.sh` passes with warnings as errors, on the default plan with random ordering, 3 times in a row locally.
- [ ] `xcodebuild -showTestPlans` lists `iOSCleanup` (default) and `Performance`, and the default plan (`iOSCleanup.xctestplan`) skips `ScalePerformanceTests`. No plan named `Unit` exists.
- [ ] `TestHygieneLintTests` passes, and `grep -rn "Task.sleep" iOSCleanupTests | grep -v test-sleep-ok` is empty.
- [ ] The 50-iteration stress run under load passes, with output quoted in the PR.
- [ ] CI is green on the PR, including the Release step. The runner image and Xcode version are recorded in the PR.
- [ ] `CLAUDE.md`, `README.md` and `PhotoDuckWidgets/README.md` state iOS 17.0 and the script commands, and no `iPhone 16` / `iPhone 15` destinations remain.
- [ ] Owner actions are listed in the PR: branch protection requiring the `CI` check; confirmation of D-MIN-OS if it was not already given; the optional failing-PR check.

### Device QA
Add to `docs/DEVICE_QA.md`, which WS-09 creates. Until it exists, put this in the PR:
- **DQA-BUILD-01:**
  - Connect an iPhone running iOS 17 or later.
  - Run `xcodebuild test -project iOSCleanup.xcodeproj -scheme iOSCleanup -destination 'platform=iOS,id=<UDID>' -only-testing:iOSCleanupTests/PhotoScanEngineTests/testPinnedVisionFeaturePrintScaleUsingDeterministicFixtures`.
  - Expect the bundle to sign and the test to **pass, not skip**.
  - Then run the full suite on the device. Expect 0 failures. Only the source-reading lints skip, because their `#filePath` sources are not on the device: `DesignLintTests`, `TestHygieneLintTests` and WS-02's `PrivacyManifestLintTests`.

### Pitfalls and out of scope
- **pbxproj recipe (used by every workstream in this chapter):**
  - Each new Swift file needs four entries:
    1. a `PBXFileReference` (`lastKnownFileType = sourcecode.swift; path = Name.swift; sourceTree = "<group>";`);
    2. a `PBXBuildFile` pointing at it;
    3. a `children` entry in its group (create a `PBXGroup` with `path = <Dir>;` for new folders such as `Views/Home`, `Views/Export`, `iOSCleanupTests/Support`);
    4. an entry in the right `PBXSourcesBuildPhase`: the app phase or the tests phase (`:604-618`).
  - Use fresh 24-hex-digit IDs with a workstream prefix (for example `B6…` for WS-06) and `grep` that each is unused.
  - Validate with `plutil -lint iOSCleanup.xcodeproj/project.pbxproj` and `xcodebuild -list`.
  - Test plans and scripts do **not** need pbxproj entries.
- **`ExternalPhotoExportService.swift` is off limits.** WS-05 owns that file until WS-35. Its `guard #available(iOS 16.2, *)` lines and the type-erased `activity: Any?` are harmless at 17.0. WS-35 may simplify them.
- **Merge overlaps:**
  - The `onChange` sites in `SwipeModeView.swift` overlap WS-04's edits to that file; rebase carefully and keep WS-04's `.id(asset.localIdentifier)` change.
  - The `HomeView.swift`/`FileResultsView.swift` sites land before WS-10 moves those files.
- **Warnings-as-errors stays out of `project.pbxproj`.** It is enforced by CI and `scripts/test.sh`, so a new Xcode's deprecations cannot block the owner's archive. Set `WARNINGS_AS_ERRORS=NO` only to iterate locally.
- **Out of scope:**
  - The StoreKitTest configuration (WS-36).
  - Filling the Performance plan (WS-08).
  - The simulator Vision CPU switch (WS-07).
  - Diagnostics clock changes (WS-02).
  - Removing the dead undo window (WS-11).
- Reconciliation (README §9, contract 9): the plans are named `iOSCleanup.xctestplan` (default) and `Performance.xctestplan`. "Unit-test plan" and "unit plan" wording was replaced with "default test plan", and WS-06.6 now states that no `Unit` plan exists.
- Reconciliation: the watchdog seam from WS-06.3 is kept by chapter 05. WS-22.4 changes only its default, and WS-24.6's structured-child rewrite still calls `watchdogSleep` (see the forward note in WS-06.3).

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| BUILD-08 | confirmed | No `.github`, no scripts. The scheme auto-creates its plan and is `parallelizable`, with no coverage, and has StoreKit only on Launch. `CLAUDE.md` uses iPhone 16. The 7 test-target warnings are the `PurchaseManagerTests` ones (fixed in WS-03). Plan follows the fix, with these differences: the UDID picker is a reusable script that skips custom-named devices; coverage covers the app target only; the StoreKit test configuration moves to WS-36; the Performance plan exists from day one. |
| BUILD-10 | partially | Real races: the 20 ms slot race, the 100 ms late-release wait (weakens the test rather than flaking it), the 250/350 ms Duck Mode debounce, and the 50 ms image-repository start. The "real 50 ms watchdog" is a genuine load hazard, but only for the operation that should *not* time out. The ML cancellation test does not flake (both orders return the heuristic); it is made deterministic anyway. The timeout is already injectable (`PhotoScanEngine.swift:245-254`), so the seam is an injectable watchdog *sleeper* plus DEBUG release counters, not a Clock. Also covered: the 500 ms polling loops at `:996-1008` and a lint so no new sleeps creep in. |
| BUILD-14 | confirmed | The test configurations lack `DEVELOPMENT_TEAM`; targets are 16.0/16.2. New facts: raising to 17.0 produces 20 `onChange` deprecation warnings and 2 Core ML compile errors (async overload), all fixed in WS-06.1. The acceptance "0 skipped on device" is unattainable, because source-reading lint tests skip on device; restated in Device QA. |

---

## WS-07 — Simulator fixture harness and HomeViewModel dependency seam

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M0 | M | WS-03, WS-06 | no | `ws/07-sim-fixtures-hvm-seam` |

**Primary files:**
- **Engine and cache:** `iOSCleanup/Engines/PhotoMLBridge.swift`, `iOSCleanup/Engines/PhotoScanEngine.swift`, `iOSCleanup/Engines/PhotoAnalysisCache.swift`.
- **Fixture harness (new):** `iOSCleanup/Utilities/DebugFixtureAnalyzer.swift` (*new*), `iOSCleanup/Utilities/DebugFixtureLibrary.swift` (*new*).
- **HomeViewModel seam:** `iOSCleanup/Views/Home/HomeViewModelDependencies.swift` (*new*), `iOSCleanup/Views/HomeViewModel.swift`, `iOSCleanup/iOSCleanupApp.swift`, `iOSCleanup/ContentView.swift`.
- **Tests:** `iOSCleanupTests/HomeViewModelTests.swift` (*new*), `iOSCleanupTests/Support/HomeViewModelTestHarness.swift` (*new*), `iOSCleanupTests/DebugFixtureAnalyzerTests.swift` (*new*).
- **Scripts, docs and project:** `scripts/sim-fixtures.sh` (*new*), `README.md`, `CLAUDE.md`, `iOSCleanup.xcodeproj/project.pbxproj`.

**Findings covered:** BUILD-04 (P1, confirmed)

**Decisions applied:**
- **D-HVM-DECOMP (phase 0):** add the `HomeViewModelDependencies` seam, with a `.live` default and an unchanged view API; delete verified-dead members; nothing else moves. WS-49 owns STATE-12.
- **D-MIN-OS:** `setComputeDevice` needs no availability check at iOS 17.

### Goal
- An agent can run `scripts/sim-fixtures.sh` on a fresh iPhone 17 Pro simulator and see Home with at least 1 auto-clean-eligible group and 0 unanalyzed photos. From there it can reach Keep Best, group detail and Duck Mode, all of which previously had no path in the simulator.
- `HomeViewModel` can be constructed in a unit test with temp stores, a temp `UserDefaults` suite, an injected engine factory and no PhotoKit observation.
- Release builds contain none of the fixture code.

### Current behavior (verified)
- `HomeViewModel.swift:1151`: `let engine = PhotoScanEngine()`. `:1405`: `let engine = FileScanEngine()`. `PhotoScanEngine.init` (`PhotoScanEngine.swift:364-377`) already accepts `assetProvider:`, `assetAnalyzer:` and `mlBridge:`.
- **Singletons and system reads in `HomeViewModel`:**
  - `:288-290` hold `PhotoAnalysisCache.shared`, `LargeVideoResultCache.shared` and `PhotoMLBridge.shared`.
  - `:2373` and `:2487` use `UserDefaults.standard` for `photoduck.cleanup-state.v2`.
  - `:1564` uses `AssetFileSizeRepository.shared.flush()`.
  - `:405-410` go through `PhotoDuckDiagnosticLog.shared`.
  - `:241-242`, `:317`, `:338`, `:1427` and `:1587` call `PHPhotoLibrary.authorizationStatus(for:)` directly.
  - `:2528-2548` (`currentLibraryPhotoMetadata`) enumerates `PHAsset.fetchAssets(with: .image)`.
- `init()` (`:298-309`) runs `bootstrapLibraryStateIfNeeded()`. On an authorized simulator, that registers the change observer and runs the restores and `scanNewPhotosIfNeeded()`.
- `ContentView.swift:5` has `@StateObject private var dashboardModel = HomeViewModel()`. WS-03 adds `AppEntry`, so hosted unit tests no longer create it.
- **Verified-dead members** (0 references outside `HomeViewModel.swift`, and none inside except each other):
  - `photoScanState` (`:350`), `hasAnyResult` (`:360`), `isAnyScanning` (`:488`), `isAllDone` (`:492`), `storageTotalFormatted` (`:578`);
  - `heroSecondaryText` (`:718`), `heroNextActionLabel` (`:739`), `heroSecondaryActionLabel` (`:766`), `completedOutcomeLabel` (`:810`, used only by `heroSecondaryText`);
  - `startSpeedClean()` (`:826`), `scanPhotos()` with no arguments (`:918`), `learningDebugSummary()` (`:2467`).
  - `findingsSoFarLabel` is still used at `:690-694`. **Keep it.**
- `isReadyForReview` (`:234`) is `@Published`. No view reads it; it is read at `:605` (`heroState`) and persisted.
- `isBackgroundExecutionState` (`:232`) is `@Published` but only written and persisted (`:1552`, `:2349`, `:2496`), never read for behavior.
- `PhotoMLBridge.makePinnedFeaturePrintRequest()` (`PhotoMLBridge.swift:44-48`) sets only `revision`.
- **Analysis failure path in `PhotoScanEngine.swift`:**
  - In the simulator, `analyzeAsset` (`:1009-1090`) falls back from `.analysisFast` to `.analysis` (`:1020-1031`), then Vision fails with error 9. The catch branch at `:1080-1087` returns `embedding: nil`, which counts as unanalyzed (`:667`).
  - Grouping uses `featureDistance(...) ?? PhotoEmbeddingValueDistance.normalizedDistance(...)` (`:750-756`), so embedding `Data` with no observation drives real grouping.
  - `makePerceptualHash` (`:1092`) and `makeKeeperSignals` (`:1116`) are `private nonisolated static`.
- The only Vision contract test skips on error 9 (`PhotoScanEngineTests.swift:48-54`). It builds its request through `PhotoMLBridge.makePinnedFeaturePrintRequest()` (`:2146`).
- **Store roots:** `PhotoAnalysisCache.init()` (`PhotoAnalysisCache.swift:513-524`) hard-codes `Application Support/PhotoDuck`. `LargeVideoResultCache(directoryURL:)` (`FileScanEngine.swift:301`) and `PhotoMLStore(directoryURL:)` (`PhotoMLStore.swift:90`) treat their argument as the Application-Support-equivalent root and append `PhotoDuck/…`.
- **Similarity constants** (`SimilarityPolicyTypes.swift:231-265`):
  - `maxNearDuplicateFeatureDistance = 0.05`, `maxVisualSimilarFeatureDistance = 0.18`.
  - The near-duplicate window is 20 s and the visual session window is 30 min.
- **Keeper ranking:** `ConservativeKeeperRankingService` (`SimilarityPolicyServices.swift:260-327`) weights sharpness 0.36 and blurPenalty −0.28, so a keeper margin of at least 0.08 needs a real sharpness gap. Identical copies tie and stay review-only (SCAN-04).
- **Runtime notes** (`spec/README.md` §4): `xcrun simctl privacy grant photos` "did not take effect in testing". The memory notes add that simulator MCP attach is broken, the Lunar overlay blocks clicks, and `addmedia` assets fail fastFormat loads.

### Implementation plan

**WS-07.1 — Force CPU Vision in the simulator (simulator half of SCAN-03)**
- **Why:** If CPU inference works in the simulator, real Vision runs there and the contract test stops skipping.
- **Change** in `PhotoMLBridge.swift`:
  - Add `import CoreML`.
  - Replace the factory with `nonisolated static func makePinnedFeaturePrintRequest(forceCPU: Bool = PhotoMLBridge.isSimulator) -> VNGenerateImageFeaturePrintRequest`, together with `static let isSimulator: Bool` (`#if targetEnvironment(simulator)` true, else false).
  - When `forceCPU` is true:
    ```swift
    if forceCPU,
       let devices = try? request.supportedComputeStageDevices,
       let cpu = devices[.main]?.first(where: { if case .cpu = $0 { return true } else { return false } }) {
        request.setComputeDevice(cpu, for: .main)
    }
    ```
    This compiles clean at iOS 17. This workstream adds no device retry. WS-22.3 (chapter 05) later moves this CPU-selection code into `PhotoVisionComputeDevice.applyCPU(to:)` and calls it from here under the simulator condition, so exactly one place selects the compute device.
- **Edge cases:**
  - On a device the default is `false`, so behavior is unchanged.
  - `testPinnedVisionRequestMatchesFeatureContract` (`PhotoMLStoreTests.swift:1284`) must still pass.
  - Record in the PR whether `testPinnedVisionFeaturePrintScaleUsingDeterministicFixtures` now **runs** or still skips in the simulator. The fixture analyzer is needed either way.

**WS-07.2 — `PhotoAnalysisCache(directoryURL:)`**
- **Change:**
  - Change the initializer to `init(directoryURL: URL? = nil)`. It uses `(directoryURL ?? Application Support).appendingPathComponent("PhotoDuck", isDirectory: true)`, matching the root semantics of `LargeVideoResultCache` and `PhotoMLStore`.
  - `static let shared = PhotoAnalysisCache()` stays as it is.
- **Edge cases:** Directory-creation failure still sets `persistenceHealthy = false`.

**WS-07.3 — `HomeViewModelDependencies` (STATE-12 phase 0)**
- **Change:** new file `iOSCleanup/Views/Home/HomeViewModelDependencies.swift`:
  ```swift
  @MainActor
  struct HomeViewModelDependencies {
      var analysisCache: PhotoAnalysisCache
      var largeVideoCache: LargeVideoResultCache
      var mlBridge: PhotoMLBridge
      var defaults: UserDefaults
      var diagnosticLog: PhotoDuckDiagnosticLog
      var fileSizeRepository: AssetFileSizeRepository
      var makePhotoScanEngine: @MainActor () -> PhotoScanEngine
      var makeFileScanEngine: @MainActor () -> FileScanEngine
      var observesPhotoLibrary: Bool
      var authorizationStatus: @Sendable () -> PHAuthorizationStatus
      var fetchLibraryPhotoMetadata: @Sendable () async -> [String: CachedPhotoAssetMetadata]

      /// Computed rather than a static let: `UserDefaults` is not Sendable, and a
      /// stored static would warn under strict concurrency. It returns today's singletons.
      static var live: HomeViewModelDependencies {
          HomeViewModelDependencies(
              analysisCache: .shared, largeVideoCache: .shared, mlBridge: .shared,
              defaults: .standard, diagnosticLog: .shared, fileSizeRepository: .shared,
              makePhotoScanEngine: { PhotoScanEngine(mlBridge: .shared) },
              makeFileScanEngine: { FileScanEngine() },
              observesPhotoLibrary: true,
              authorizationStatus: { PHPhotoLibrary.authorizationStatus(for: .readWrite) },
              fetchLibraryPhotoMetadata: { await HomeViewModelDependencies.systemLibraryPhotoMetadata() })
      }
      /// Moved verbatim from HomeViewModel.currentLibraryPhotoMetadata (:2528-2548).
      nonisolated static func systemLibraryPhotoMetadata() async -> [String: CachedPhotoAssetMetadata] { … }

      /// Returns `.debugFixture()` when the fixture flag is set (DEBUG + simulator only), else `.live`.
      static func resolvedForLaunch() -> HomeViewModelDependencies { … }
  }
  ```
- **The struct is designed to grow** (README §9, contract 16). Every field added after WS-07 is declared **with its production default**, so `.live`, `.debugFixture()` and `makeIsolatedDependencies` keep compiling unchanged, and a test overrides only what it isolates (`var deps = …; deps.feedbackStore = tempStore`):
  ```swift
  // Pattern for later fields (example from WS-47):
  var feedbackStore: PhotoFeedbackStore = .shared
  // Hooks default the same way (WS-08.6):
  var onBackgroundCheckpointStep: (@Sendable (BackgroundCheckpointStep) -> Void)? = nil
  ```
  - Known additions: `keepDecisions` (WS-12); the diagnostics recorder and the cleanup-state store (WS-15); `librarySource` (WS-18, which replaces `fetchLibraryPhotoMetadata` and routes authorization reads through the inventory); `resourceMonitor` (WS-25); `makeBackgroundTaskLease` (WS-28); `idleTimerCoordinator` and `makeScanBackgroundContinuation` (WS-29); `footprintSource` (WS-30); the storage-volume reader (WS-32); `feedbackStore` (WS-47); `preferenceProfileStore` (WS-48); `progressClock` and `progressSleep` (WS-50); and the WS-59 library readers.
  - A field that owns on-disk or `UserDefaults` state also gets a temp-root instance in `makeIsolatedDependencies`, in the same PR.
  - `fileSizeRepository` already exists here. WS-48 reuses it and does not add a second field.
  - `authorizationStatus` and `fetchLibraryPhotoMetadata` already let `scanPhotos` run end to end in unit tests (see `testDeepCleanUsesInjectedEngineFactoryAndPublishesExplicitPlan`). WS-26–WS-29's integration tests rely on this. After WS-18, the harness provides a stub `librarySource` instead.
- **Change** in `HomeViewModel.swift`:
  - Add `init(dependencies: HomeViewModelDependencies = .live)`. Store `private let dependencies`, and initialize the existing `analysisCache`, `largeVideoResultCache` and `mlBridge` lets from it. Keep the property names, so the capture lists at `:1561-1562` and `:899` are unchanged.
  - Replace:
    - `:1151` with `dependencies.makePhotoScanEngine()` and `:1405` with `dependencies.makeFileScanEngine()`;
    - `:2373`/`:2487` with `dependencies.defaults`, `:1564` with `dependencies.fileSizeRepository.flush()`, and `:409` with `dependencies.diagnosticLog`;
    - every `PHPhotoLibrary.authorizationStatus(for: .readWrite)` read (`:317`, `:338`, `:1427`, `:1587`) with `dependencies.authorizationStatus()`;
    - the `currentLibraryPhotoMetadata()` call with `dependencies.fetchLibraryPhotoMetadata()`, then delete the moved function.
  - The `@Published` initializer at `:241-242` becomes `= .notDetermined`, and `init` sets it from `dependencies.authorizationStatus()` before anything else.
  - `observesPhotoLibrary == false` means:
    - `init` does **not** call `bootstrapLibraryStateIfNeeded()`;
    - `bootstrapLibraryStateIfNeeded()` returns immediately;
    - `startPhotoLibraryObservationIfDetermined()` never registers the observer.
  - `PHPhotoLibrary.requestAuthorization` (`:550`, the user-initiated in-context request) stays as it is.
- **Edge cases:**
  - The `.live` path must produce exactly today's behavior. `PhotoScanEngine(mlBridge: .shared)` is today's default.
  - The remaining singletons (`CleanupNotificationScheduler.shared`, `ExternalPhotoExportSessionGate`) are out of scope. Neither is touched by the smoke tests: notifications are unauthorized in the test host.

**WS-07.4 — Delete dead members and stop over-publishing**
- **Change:**
  - Delete the 12 verified-dead members listed above.
  - Make `isReadyForReview` a `private var` (not `@Published`). It is still written where it is today, still read at `:605` and still persisted.
  - Make `isBackgroundExecutionState` a `private var`, still written, still persisted in `PersistedCleanupState`, so old data decodes.
  - Grep `iOSCleanup` and `iOSCleanupTests` for each name before deleting.
- **Edge cases:** `heroState` keeps working. Every write to `isReadyForReview` happens together with a change to a `@Published` property (`photoGroups`, `hasPartialResults` or `scanState`), so views still re-render.
- **Forward note:** the deleted members stay deleted. WS-15's `restoringResults` copy table lists `heroSecondaryText` and `heroNextActionLabel` rows, and WS-15 must not re-add those properties. Only live properties such as `heroStatusLabel` and `heroDetailText` get the new copy. WS-15's `HeroStateInputs` reads the now-private `isReadyForReview` from inside `HomeViewModel`, which still works.

**WS-07.5 — Hoist ownership to the App**
- **Change:**
  - `iOSCleanupApp` gets `@StateObject private var dashboardModel = HomeViewModel(dependencies: .resolvedForLaunch())` and passes it as `ContentView(dashboardModel: dashboardModel)`.
  - In `ContentView`, change `@StateObject private var dashboardModel = HomeViewModel()` to `@ObservedObject var dashboardModel: HomeViewModel`. Its `.onAppear` bootstrap call and its `onChange(of: scenePhase)` stay (in WS-06's migrated form).
- **Edge cases:** WS-03's `AppEntry`/`UnitTestHostApp` must not create it. Check that the hosted test run creates no `HomeViewModel`, for example by setting a breakpoint or temporarily logging in `init`.

**WS-07.6 — Deterministic fixture analyzer (DEBUG + simulator)**
- **Why:** This yields real 2,048-float embeddings without Vision, so the real grouping, keeper and delete-plan path runs in the simulator.
- **Change:**
  - In `PhotoScanEngine.swift`, change `makePerceptualHash(from:)` and `makeKeeperSignals(from:asset:)` from `private nonisolated static` to `nonisolated static` (internal). Do not copy them.
  - New `iOSCleanup/Utilities/DebugFixtureAnalyzer.swift`, whole file wrapped in `#if DEBUG && targetEnvironment(simulator)`:
  ```swift
  enum DebugFixtureAnalyzer {
      static let embeddingWidth = 64, embeddingHeight = 32      // 64×32 == PhotoEmbeddingContract.elementCount
      static let lowPassWidth = 16, lowPassHeight = 8
      static let analysisSide: CGFloat = 224                     // same request as analyzeAsset

      static func analyze(_ asset: PHAsset, allowNetworkAccess: Bool) async -> PhotoScanAssetAnalysis {
          let image = await PhotoImageRepository.shared.image(
              for: asset, targetSize: CGSize(width: analysisSide, height: analysisSide),
              contentMode: .aspectFill, qualityIntent: .analysis,   // highQuality: avoids the fastFormat 3303 miss
              allowNetworkAccess: allowNetworkAccess)
          guard let cgImage = image?.cgImage else { return .unavailable }
          return analysis(for: cgImage, asset: asset)
      }
      /// Pure; unit-tested without PhotoKit.
      static func analysis(for image: CGImage, asset: PHAsset) -> PhotoScanAssetAnalysis {
          PhotoScanAssetAnalysis(observation: nil, embedding: embedding(for: image),
                                 perceptualHash: PhotoScanEngine.makePerceptualHash(from: image),
                                 keeperSignals: PhotoScanEngine.makeKeeperSignals(from: image, asset: asset))
      }
      /// Low-frequency grayscale layout. Draw into a 16×8 DeviceGray context
      /// (interpolationQuality .high, area average), redraw that into 64×32 (bilinear),
      /// and emit Float(luma)/255 in row order.
      /// Returns 8,192 bytes, or nil if a context cannot be created.
      static func embedding(for image: CGImage) -> Data? { … }
      /// Test helper: center-crops to a square and scales to 224, mimicking PhotoKit's aspectFill.
      static func analysisInput(from image: CGImage) -> CGImage? { … }
  }
  ```
  The low-pass embedding is deliberate:
  - Sharpness lives in high frequencies, so a sharp photo and a softened copy stay at a near-duplicate distance and still differ in keeper signals.
  - Different layouts are far apart.
- **Edge cases:**
  - Normalized RMS distance is `sqrt(mean(delta²))` on values in 0…1, which matches `PhotoEmbeddingValueDistance`.
  - The ML store version checks (`PhotoEmbeddingContract.expectedByteCount`) accept 8,192 bytes.

**WS-07.7 — Fixture library and in-app seeding (DEBUG + simulator)**
- **Why:** `addmedia` files lack reliable EXIF dates, and fastFormat fails on them. Near-duplicates must fall inside the 20 s window, so seeding sets `creationDate` explicitly.
- **Change:** new `iOSCleanup/Utilities/DebugFixtureLibrary.swift`, wrapped in `#if DEBUG && targetEnvironment(simulator)`.
  - `enum DebugFixtureScene: String, CaseIterable` has 10 scenes. Base date `2026-01-15T10:00:00Z`; the offsets are relative to it:

    | Scene | Offset | Content |
    |---|---|---|
    | `pondSharp` | +0 s | sharp |
    | `pondSoft` | +1 s | mild blur |
    | `pondSofter` | +2 s | mild blur and brightness +3% |
    | `berriesA` | +3,600 s | |
    | `berriesB` | +3,601 s | shifted composition, targeting the visually-similar band 0.08–0.16 |
    | `lighthouse` | +7,200 s | unrelated |
    | `citrus` | +10,800 s | unrelated |
    | `screenshotSettings` | +14,400 s | screenshot |
    | `screenshotChat` | +14,460 s | screenshot |
    | `blurredForest` | +18,000 s | heavy blur |

  - `enum DebugFixtureImageFactory { static func image(for: DebugFixtureScene) -> CGImage }` draws deterministic 1200×900 images:
    - 3–5 large color blocks or gradients with a layout unique per scene;
    - a high-contrast checker texture with 16–28 px cells, so it survives the 224 → 64 px keeper-signal downsample;
    - softening with a hand-written separable box blur on the RGBA buffer, not Core Image, so it is deterministic. Radius about 8–14 px for "soft" and about 40 px for `blurredForest`.
    - These starting values are tuned until `DebugFixtureAnalyzerTests` pass.
  - `enum DebugFixtureSeeder { static func seedIfRequested() async }`:
    - It runs only when `UserDefaults.standard.bool(forKey: "PhotoDuckSeedFixtures")` is true. The launch argument `-PhotoDuckSeedFixtures YES` populates the argument domain.
    - If authorization is `.notDetermined`, it calls `PHPhotoLibrary.requestAuthorization(for: .readWrite)`. This is the one documented DEBUG-simulator exception to "request only in context": seeding *is* the context. If the result is not `.authorized`, log and return.
    - It skips seeding if every ID stored under `PhotoDuckDebugSeededFixtureIDs` still resolves through `PHAsset.fetchAssets(withLocalIdentifiers:)`.
    - Otherwise, for each scene, inside one `performChanges`: `PHAssetCreationRequest.forAsset()`, then `addResource(with: .photo, data: jpegData(quality 0.9))` and `creationDate = …`. Store the placeholders' `localIdentifier`s.
    - Screenshots: write JPEGs through `CGImageDestination` with EXIF `UserComment = "Screenshot"`. **Unverified** whether PhotoKit then sets `.photoScreenshot`. Log the resulting `mediaSubtypes` and record it in the PR. The harness does not depend on it.
    - Log `seeded=<n>` through `Logger(subsystem: "com.photoduck.app", category: "DebugFixtures").notice`.
  - `iOSCleanupApp` gets `.task { #if DEBUG && targetEnvironment(simulator) await DebugFixtureSeeder.seedIfRequested() #endif }`.
- **Edge cases:** Seeding never runs on a device (compile-time gate), never deletes anything, and is idempotent. Pass `PHFetchOptions()`, not `options: nil`, to the existence check's `PHAsset.fetchAssets(withLocalIdentifiers:options:)`: WS-40's `PhotoFetchLintTests` later forbids `options: nil` anywhere in `iOSCleanup/`, DEBUG code included.

**WS-07.8 — Fixture mode wiring (DEBUG + simulator)**
- **Change:** `HomeViewModelDependencies.debugFixture()` lives under `#if DEBUG && targetEnvironment(simulator)`:
  - The root is `Application Support/PhotoDuck-DebugFixture/`. The analysis cache, large-video cache and `PhotoMLStore(directoryURL: root)` all live under it; the ML files land in `root/PhotoDuck/ml/`.
  - `defaults` is `UserDefaults(suiteName: "com.photoduck.debug-fixture")!`.
  - `makePhotoScanEngine` returns `{ PhotoScanEngine(assetAnalyzer: { await DebugFixtureAnalyzer.analyze($0, allowNetworkAccess: $1) }, mlBridge: fixtureBridge) }`.
  - Everything else is `.live`.
  - `resolvedForLaunch()` returns it when `UserDefaults.standard.bool(forKey: "PhotoDuckFixtureAnalyzer")` is true.
  - DEBUG + simulator only: if `UserDefaults.standard.bool(forKey: "PhotoDuckAutoStartScan")` is true, `HomeViewModel` calls `startDeepClean()` once, at the end of the bootstrap Task.
- **Why isolated stores:** fixture embeddings must never enter the warm-analysis cache or `photo_asset_analysis` rows of a real library. Both are keyed by `analyzerVersion` 1, so a later real scan would reuse them.
- **Edge cases:**
  - `PhotoFeedbackStore.shared` still writes feedback to the real ML store in fixture mode. That is accepted for DEBUG-simulator use; note it in `CLAUDE.md`. Once WS-47 adds `feedbackStore` to the dependencies, `debugFixture()` may point it at the fixture root.
- **Forward contract: later engine stages must keep fixture mode reaching Keep Best.** Fixture mode replaces only the per-asset analyzer. Engine stages added later still run in the simulator, where Vision fails with error 9. Each workstream below extends `debugFixture()` (and `DebugFixtureAnalyzer` where needed) in the same PR:
  - **WS-37** gates the blurry category on `blurConfirmation == .confirmed`. `DebugFixtureAnalyzer` must fill `blurConfirmation`, `confirmedSharpness` and `edgeDensity` from the fixture image, so `blurredForest` stays in the blurry category. WS-37 also adds `KeepBestEvidenceCollector(enricher:)`; fixture mode passes a no-op `KeeperEnriching` (face-quality requests fail in the simulator).
  - **WS-38** adds `DuplicateVerificationService(recognizer:)`. Fixture mode passes `keepBestEvidence: KeepBestEvidenceCollector(enricher: <no-op>, verifier: DuplicateVerificationService(recognizer: FixtureTextRecognizer()))`. `FixtureTextRecognizer` returns `[]` and lives under the same `#if DEBUG && targetEnvironment(simulator)` gate. Without it, the OCR and barcode requests fail, every verdict becomes `.unavailable`, every group becomes review-only, and Keep Best is unreachable in the simulator.
  - The check is `DebugFixtureAnalyzerTests` plus a `scripts/sim-fixtures.sh` run that still shows a Keep Best-eligible pond group.

**WS-07.9 — `scripts/sim-fixtures.sh` and docs**
- **Script:** `SIM_NAME` defaults to "iPhone 17 Pro". `SKIP_BUILD=1` skips step 1. The flow:
  1. Resolve the UDID with `scripts/sim-udid.sh`, then `simctl boot` (ignore "already booted") and `simctl bootstatus -b`.
  2. Build with `xcodebuild … -configuration Debug -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath build/DerivedData build`.
  3. `simctl install` the `.app`.
  4. `simctl privacy "$UDID" grant photos com.photoduck.app`. This is best effort, and the README says it may not stick.
  5. Launch with `-hasOnboarded YES -PhotoDuckSeedFixtures YES`.
  6. Poll for up to 90 s with `xcrun simctl spawn "$UDID" log show --last 3m --style compact --predicate 'subsystem == "com.photoduck.app" AND category == "DebugFixtures"' | grep -q seeded=`. While polling, print "If the Photos permission alert is showing, tap Allow Full Access."
  7. Terminate, then relaunch with `-hasOnboarded YES -PhotoDuckFixtureAnalyzer YES -PhotoDuckAutoStartScan YES`.
  8. Wait 20 s, then `simctl io "$UDID" screenshot build/sim-fixtures-home.png`.
- **Docs:** In `README.md` and `CLAUDE.md`, add a "Simulator fixture harness" section listing:
  - the flags;
  - the script;
  - the isolated fixture stores;
  - how to reach Keep Best: open the near-duplicate group, tap Keep Best, and confirm the iOS delete dialog by tapping, for example via the iOS Simulator MCP `tap` action, which works headless;
  - that Duck Mode is reachable from the results screen;
  - the rule that everything is `#if DEBUG && targetEnvironment(simulator)`.
- Replace `spec/README.md` §4's `addmedia` advice only through the lead (see cross-chapter issues). Do not edit `spec/`.

### Tests
All run in the simulator. The fixture tests are wrapped in `#if DEBUG && targetEnvironment(simulator)`.

**Harness file:** `iOSCleanupTests/Support/HomeViewModelTestHarness.swift` (*new*). WS-08, WS-15 and later workstreams reuse it.
- `@MainActor func makeIsolatedDependencies(assets: [PHAsset], analyzer: @escaping PhotoScanAssetAnalyzer, authorization: PHAuthorizationStatus = .authorized) -> (HomeViewModelDependencies, TestStores)`. It builds:
  - a UUID temp root with `addTeardownBlock` removal;
  - `PhotoAnalysisCache(directoryURL:)`, `LargeVideoResultCache(directoryURL:)`, `PhotoMLBridge(store: PhotoMLStore(directoryURL:))`, `AssetFileSizeRepository(fileURL:)` and `PhotoDuckDiagnosticLog(fileURL:)`, all under the temp root;
  - a `UserDefaults(suiteName:)` with a UUID name, removed in teardown;
  - `observesPhotoLibrary: false`;
  - `authorizationStatus` returning the given status;
  - `fetchLibraryPhotoMetadata` derived from `assets`;
  - `makePhotoScanEngine`, which counts its calls and returns `PhotoScanEngine(assetProvider: StubPhotoScanAssetProvider(assets:), assetAnalyzer: analyzer, mlBridge: bridge)`;
  - `makeFileScanEngine` returning `FileScanEngine(authorizationProvider: .init(currentStatus: { .denied }, requestReadWrite: { .denied }))`. It is `.denied` on purpose: an authorized stub would call `AssetFileSizeRepository.shared.retain` (`FileScanEngine.swift:142`) and write the host's shared file-size cache.
- Move `StubPhotoScanAssetProvider` into `Support/` if WS-03 did not.
- **Forward note:** the harness's `makePhotoScanEngine` and the engine-level `testFixtureLibraryScanProducesExpectedGroups` build engines over fake assets, just like WS-08's end-to-end tests. When WS-37 and WS-38 add `PhotoScanEngine.init(keepBestEvidence:)`, they inject the same stubs here in the same PR: a no-op `KeeperEnriching`, and `StubDuplicateVerifier(result:)` from WS-38. Otherwise the default loader calls PhotoKit on fake assets and turns every plan review-only.

**`iOSCleanupTests/HomeViewModelTests.swift`:**
- `testInitWithIsolatedDependenciesDoesNotBootstrapOrScan`: construct the model. Assert:
  - `scanState == .idle`;
  - the engine factory was called 0 times;
  - `photoAuthorizationStatus == .authorized`, from the injected closure;
  - the temp `UserDefaults` suite has no `photoduck.cleanup-state.v2` key yet.
- `testRestoresPersistedStateFromInjectedDefaults`:
  1. Run a first model's scan to completion (as in the next test), so `persistCleanupState` writes to the suite.
  2. Construct a second model over the same dependencies.
  3. Assert that `lastCompletedAt` and `lastCompletedGroupsCount` are restored.
- `testDeepCleanUsesInjectedEngineFactoryAndPublishesExplicitPlan`:
  - Use the 5 fixture assets: 3 pond scenes (`ConfigurablePhotoScanTestAsset`/`TestPhotoAsset` with the fixture dates) plus lighthouse and citrus.
  - The analyzer maps each asset ID to `DebugFixtureAnalyzer.analysis(for: analysisInput(from: factory image), asset:)`.
  - Call `await model.scanPhotos(mode: .deepClean)`, then `await waitUntil(timeout: .seconds(10)) { model.scanState == .completed }`.
  - Assert:
    - the factory was called exactly once;
    - `unanalyzedPhotoCount == 0`;
    - exactly one group has `keeperAssetID == "pondSharp"` and `Set(deleteCandidateIDs) == ["pondSoft", "pondSofter"]`;
    - that group has `isAutoCleanEligible == true`.

**`iOSCleanupTests/DebugFixtureAnalyzerTests.swift`:**
- **Pipeline:** every image goes through JPEG 0.9 round trip, then `analysisInput`, then `analysis(for:asset:)`.
- **Tests:**
  - `testEmbeddingHasContractByteCount`: 8,192 bytes, and `PhotoEmbeddingValueDistance.normalizedDistance` of an image against itself is `0`.
  - `testPondVariantsAreNearDuplicates`: every pond pair is at most 0.035, safely under 0.05.
  - `testBerriesPairIsVisuallySimilarOnly`: the distance is in `0.08...0.16`.
  - `testUnrelatedScenesAreFarApart`: every cross-scene pair among pond, berries, lighthouse and citrus is at least 0.25, above 0.18.
  - `testSharpPondWinsKeeperRankingWithMargin`: `ConservativeKeeperRankingService` over the 3 pond descriptors and signals ranks `pondSharp` first, and the score gap to the runner-up is at least 0.12.
  - `testOnlyBlurredForestIsBlurryCategory`: `blurredForest` sharpness is at most 0.15. Every other non-screenshot scene is at least 0.30.
  - `testFixtureLibraryScanProducesExpectedGroups`: engine-level, with `StubPhotoScanAssetProvider` over 10 test assets. The screenshots use `mediaSubtypes: .photoScreenshot`. Pass an isolated bridge. Assert:
    - exactly one `.nearDuplicate` group, with keeper `pondSharp`, delete `[pondSoft, pondSofter]` and `recommendedAction == .keepBestTrashRest`;
    - exactly one `.visuallySimilar` group, `{berriesA, berriesB}`, with empty `deleteCandidateIDs`;
    - `blurryAssets == [blurredForest]`;
    - no group contains lighthouse, citrus or a screenshot together with a camera photo;
    - `unanalyzedPhotoCount == 0`.

### Acceptance criteria
- [ ] `HomeViewModel(dependencies:)` exists with `.live` as the default. `grep -n "PhotoScanEngine()\|FileScanEngine()\|UserDefaults.standard\|\.shared" iOSCleanup/Views/HomeViewModel.swift` shows only `CleanupNotificationScheduler.shared`, `ExternalPhotoExportSessionGate`-free code and `UIApplication.shared`.
- [ ] The 12 dead members are gone. `isReadyForReview` and `isBackgroundExecutionState` are no longer `@Published`. `PersistedCleanupState` is unchanged.
- [ ] `iOSCleanupApp` owns the `@StateObject`, and `ContentView` takes `@ObservedObject`. Hosted unit tests construct no live `HomeViewModel`.
- [ ] All new tests pass. The suite is green, with warnings as errors, and `scripts/build-release.sh` succeeds. `nm`/`strings` on the Release binary shows no `DebugFixture` symbols.
- [ ] On a fresh iPhone 17 Pro simulator, `scripts/sim-fixtures.sh` ends with a screenshot of Home showing at least 1 group. Where the app surfaces diagnostics, it shows 0 unanalyzed. Keep Best on the pond group presents the iOS delete dialog, and after confirming, Home shows updated freed counts. Duck Mode opens with the pond delete candidates. Attach the screenshots to the PR, and note any step that needed a manual tap.
- [ ] The PR records whether the pinned Vision test ran or skipped in the simulator, and the `mediaSubtypes` the seeded screenshots actually got.
- [ ] `README.md` and `CLAUDE.md` document the harness, the flags, the isolated stores and the dependency seam.

### Pitfalls and out of scope
- **DECISION (owner may override):** the fixture analyzer, seeding and auto-start are compiled only under `DEBUG && targetEnvironment(simulator)`, not merely `DEBUG`.
  - A fixture analyzer on a device would build Keep Best plans for real photos from fake embeddings, and seeding would write into the owner's real library.
  - If the owner wants fixtures on a device, that needs a separate reviewed change.
- **Invariants at risk:**
  - PhotoKit is never touched while authorization is `notDetermined`. The live path still checks `dependencies.authorizationStatus()` before any fetch. The seeder is the documented DEBUG-simulator exception.
  - Release contains no fixture code (invariant 27).
  - The `HomeViewModel` view API is unchanged.
- **Do not grow `HomeViewModel.swift`:** net lines must go down, because the dead-member deletion outweighs the plumbing.
- **Out of scope:**
  - Device Vision CPU retry and failure reasons (WS-22).
  - Moving persistence out of `HomeViewModel` (WS-15).
  - The single-flight inventory, which replaces `fetchLibraryPhotoMetadata` (WS-18).
  - `CleanupNotificationScheduler` injection (WS-15).
  - Keep Best on identical copies (WS-38).
- Reconciliation (README §9, contract 16): WS-07.3 now states that `HomeViewModelDependencies` grows, shows the defaulted-field pattern, lists the known additions, and notes that `fileSizeRepository` already exists, so WS-48 reuses it.
- Reconciliation (reported by chapter 08): fixture mode must inject `FixtureTextRecognizer` and a no-op `KeeperEnriching` once WS-37 and WS-38 exist, and the harness must inject the same stubs as WS-08. Otherwise every simulator group becomes review-only. WS-37's blur confirmation must also keep `blurredForest` blurry (WS-07.8 forward contract).
- Reconciliation: WS-22.3 moves the simulator CPU selection into `PhotoVisionComputeDevice.applyCPU(to:)`. The earlier text claimed WS-22 reuses `forceCPU: true`; that claim was wrong.
- Reconciliation: chapter 04's WS-15 copy table still names `heroSecondaryText` and `heroNextActionLabel`, which WS-07.4 deletes. Earlier wins: they stay deleted (forward note in WS-07.4).
- Reconciliation: DEBUG PhotoKit fetches added here (the seeder's existence check) pass `PHFetchOptions()`, not `nil`. WS-40 later routes them through `PhotoLibraryFetch` factories, because its `PhotoFetchLintTests` rejects both `options: nil` and inline `PHFetchOptions()` outside `PhotoLibraryFetch.swift` (README contract 33). That edit belongs to WS-40, not here.

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| BUILD-04 | confirmed | Every cited line matches. Whether CPU Vision works in the simulator is unverifiable statically, so WS-07.1 is a probe. The plan differs from the proposed fix in five ways: (1) no `usesCPUOnly` branch (iOS 17 per D-MIN-OS); (2) the embedding is a low-pass 16×8 → 64×32 layout instead of raw 64×32 luma, so fixtures can differ in sharpness and still pass the keeper margin, which raw luma would break (SCAN-04 ties); (3) fixture mode uses isolated stores, and every fixture path is simulator-only; (4) injection goes through `HomeViewModelDependencies` (D-HVM-DECOMP), which also has to inject authorization and library metadata, or `scanPhotos` would read the host simulator's real library; (5) seeding happens in-app, with explicit `creationDate`, instead of `addmedia`. |

---

## WS-08 — Engine safety nets: end-to-end groups, lifecycle tests, scale benchmarks

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M0 | L | WS-06, WS-07 | no | `ws/08-engine-safety-nets` |

**Primary files:**
- **App code:** `iOSCleanup/Engines/PhotoScanEngine.swift` (init only), `iOSCleanup/Engines/PhotoMLBridge.swift`, `iOSCleanup/Views/Home/ScanProgressMath.swift` (*new*), `iOSCleanup/Views/Home/HomeViewModelDependencies.swift`, `iOSCleanup/Views/HomeViewModel.swift`, `iOSCleanup/Utilities/PHAsset+FileSize.swift` (DEBUG counters only).
- **Test support (new):** `iOSCleanupTests/Support/ConfigurablePhotoScanTestAsset.swift` (*new*), `iOSCleanupTests/Support/ScaleBenchmark.swift` (*new*).
- **Tests:** `iOSCleanupTests/PhotoScanEngineEndToEndTests.swift` (*new*), `iOSCleanupTests/ScanProgressMathTests.swift` (*new*), `iOSCleanupTests/PhotoMLStoreTests.swift`, `iOSCleanupTests/HomeViewModelTests.swift`, `iOSCleanupTests/ScalePerformanceTests.swift`.
- **Plan, baselines and project:** `Performance.xctestplan`, `iOSCleanup.xcodeproj/xcshareddata/xcbaselines/` (*new*), `iOSCleanup.xcodeproj/project.pbxproj`.

**Findings covered:** FSB-05 (P2, partially), FSB-12 (P3, confirmed), PERF-15 (P3, confirmed)

**Decisions applied:**
- **D-PERF-GATE:** benchmarks live only in the Performance plan. Growth ratios (`time(4n)/time(n) < 6`) are hard assertions. The known PERF-01 and PERF-13 ratios are wrapped in `XCTExpectFailure` that names the finding. Absolute baselines are advisory.

### Goal
Before any engine or performance change lands, three things are under automated test:
- the engine's golden path: a real `PhotoScanEngine.scan` producing explicit keeper and delete IDs, and review-only `visuallySimilar` groups;
- its lifecycle hooks: write-buffer flushing, pause flush, background checkpoint ordering, and progress monotonicity;
- its scale characteristics.

These tests are the regression net for WS-13, WS-17, WS-22–25, WS-37–40, WS-53 and WS-54.

### Current behavior (verified)
- **Scan output is never tested:**
  - The only scan-output assertion on groups is `XCTAssertTrue(finalUpdate?.groups.isEmpty == true)` (`PhotoScanEngineTests.swift:412`).
  - `testWarmIncrementalScanReusesUnchangedContextAnalysis` (`:635-705`) feeds identical embeddings and never checks the group.
- **Test double:** `PhotoScanTestAsset` (`:2197-2226`) hard-codes 4032×3024 and has no subtype, burst or favorite knobs. WS-03 replaces it with `Support/TestPhotoAsset.swift`.
- **Global preference profile:** `PhotoScanEngine.swift:493` reads `let preferenceProfile = await PhotoPreferenceProfileStore.shared.snapshot()`, the app-global profile. `PhotoPreferenceProfile()` (`PhotoPreferenceProfile.swift:53-68`) is an empty profile, because every stored property has a default.
- **Final action and delete candidates** (`makeGroups`, `PhotoScanEngine.swift:1255-1419`):
  - `finalAction` is `.reviewManually` for `.visuallySimilar` or incomplete keeper evidence (`:1353-1355`).
  - `finalDeleteCandidateIDs` is non-empty only for `.keepBestTrashRest` (`:1356-1358`).
- **Guardrails** (`PhotoDeletionGuardrails.swift:83-120`):
  - `validate(group:)` checks `recommendedAction == .keepBestTrashRest` **first**. A `visuallySimilar` group, which `PhotoGroup.init` downgrades to `.reviewManually`, therefore throws `.automaticActionNotAllowed`, not `.visuallySimilarReviewOnly`.
  - There is no `validate(groups:)`. The group-level entry point is `compatibleAutoCleanGroups(from:)` (`:58-81`).
- **Write buffering** (`PhotoMLBridge.swift`):
  - The buffer tuning is a private enum (`:34-38`): 96 features, 384 pairs, 1.5 s latency. `bufferAssetAnalyses` also uses the feature count (`:128-138`).
  - `flushBufferedWrites()` is at `:140-151`. The latency flush is at `:228-237`.
  - `PhotoMLStore.stats()` (`PhotoMLStore.swift:1182`) returns `featureCount`.
- `PhotoScanEngine.pause()` (`:379-382`) sets `isPaused` and awaits `mlBridge.flushBufferedWrites()`.
- **Resume progress math** is inline in `HomeViewModel.apply(update:)` (`:1684-1692`):
  ```swift
  scanTargetCount = resumedTargetCount.map { max($0, progressOffset + update.scanTargetCount) } ?? update.scanTargetCount
  processedPhotoCount = progressOffset + update.processedPhotoCount
  progressFraction = scanTargetCount == 0 ? 1 : min(Double(processedPhotoCount) / Double(scanTargetCount), 1)
  ```
- **Background handler** (`HomeViewModel.swift:1550-1575`): when `hasHydratedAnalysisCache` is true and the state is scanning or paused, it builds a checkpoint. In a `Task` it then awaits, in order:
  1. the pending diagnostic write;
  2. the file-size flush;
  3. `mlBridge.flushBufferedWrites()`;
  4. `analysisCache.saveSnapshot(checkpoint)`.
- **No scale benchmarks:** `grep` finds no `measure`, `XCTClockMetric` or `XCTMemoryMetric` in `iOSCleanupTests`.
- **Benchmark targets:**
  - PERF-01 target: `CachedPhotoGroup.makeGroup(using:)` (`PhotoAnalysisCache.swift:403-440`) builds `Set(assetsByID.keys)` **per group**, which is quadratic. `rehydrateGroups` (`:768-779`) needs PhotoKit, so benchmark `makeGroup` directly.
  - `PhotoScanResumePlanner.requiredAssetIDs` (`:267-335`) and `hasConsistentCompletionState` (`:61-93`) are linear.
  - `PhotoImageRepository.store` (`SharedHelpers.swift:442-461`) evicts with an O(cache) `min` per insert.
  - `AssetFileSizeRepository` (`PHAsset+FileSize.swift:325-540`) rewrites its whole JSON after every coalesced `store`. It has no write counter.
  - `PhotoScanRefreshSchedule.nextThreshold` (`PhotoScanEngine.swift:1915-1927`) doubles, so regrouping is amortized linear.
  - `PhotoResultsPresentation` does not exist yet; WS-50 adds benchmark (4).

### Implementation plan

**WS-08.1 — Injectable preference profile (FSB-05)**
- **Change:**
  - Add `preferenceProfileProvider: @escaping @Sendable () async -> PhotoPreferenceProfile = { await PhotoPreferenceProfileStore.shared.snapshot() }` as the last `PhotoScanEngine.init` parameter. Store it, and use it at `:493`.
  - This is the only engine edit in this workstream.
- **Edge cases:** Existing callers and `.live` keep the default. The fixture dependencies from WS-07 keep the default too.

**WS-08.2 — Test doubles and embedding helper (FSB-05)**
- **Change:** new `iOSCleanupTests/Support/ConfigurablePhotoScanTestAsset.swift`:
  ```swift
  /// Photo-scan test asset. Built on WS-03's TestPhotoAsset, which WS-03 declares non-final for this subclass.
  class ConfigurablePhotoScanTestAsset: TestPhotoAsset {
      private let testHasAdjustments: Bool
      private let testSourceType: PHAssetSourceType
      init(localIdentifier: String, creationDate: Date,
           modificationDate: Date? = nil,              // nil means equal to creationDate, so not "edited"
           pixelWidth: Int = 4_032, pixelHeight: Int = 3_024,
           mediaSubtypes: PHAssetMediaSubtype = [], burstIdentifier: String? = nil,
           isFavorite: Bool = false, hasAdjustments: Bool = false,
           sourceType: PHAssetSourceType = .typeUserLibrary) { … super.init(…) }
      override var hasAdjustments: Bool { testHasAdjustments }
      override var sourceType: PHAssetSourceType { testSourceType }
  }

  enum TestEmbeddings {
      /// Deterministic SplitMix64 values in 0..<1, 2,048 floats.
      static func base(seed: UInt64) -> [Float]
      /// base + a ±d pattern (signs from the seed), so the RMS distance is exactly d.
      static func offset(_ base: [Float], rmsDistance d: Double, seed: UInt64) -> [Float]
      static func data(_ values: [Float]) -> Data
  }
  enum TestKeeperSignals {
      /// blurPenalty = 1 - s, motionBlurPenalty = 0.3 * (1 - s), exposure 0.8, framing 0.8, resolution 0.1.
      static func make(sharpness s: Double) -> KeeperSignals
  }
  ```
  - `hasAdjustments` and `sourceType` exist now because WS-13 (SCAN-21) and WS-37 (SCAN-10) extend these tests.
  - Chapter 08 expects this class to exist, and to be the type it adds overrides to.
- **Edge cases:** The helper test asserts that `PhotoEmbeddingValueDistance.normalizedDistance` for each helper output matches `d` within 1e-4. Two unrelated seeds come out at about 0.41, well above 0.18.

**WS-08.3 — Five (plus one) end-to-end engine tests (FSB-05)**
- **Change:** new `iOSCleanupTests/PhotoScanEngineEndToEndTests.swift`.
  - Each test makes a temp root with teardown removal and `PhotoMLBridge(store: PhotoMLStore(directoryURL:))`.
  - Each passes `preferenceProfileProvider: { PhotoPreferenceProfile() }` and an analyzer closure mapping ID → `PhotoScanAssetAnalysis(observation: nil, embedding:, perceptualHash:, keeperSignals:)`.
  - Each drains `engine.scan(mode: .deepClean)` and keeps the `isComplete` update.
  - Tests:
    - **`testEndToEndNearDuplicatePairProducesExplicitKeepBestPlan`:**
      - Setup: A and B are 2 s apart at distance 0.02; C is 1 h later, unrelated. A has sharpness 0.9 and B has 0.5, a margin of about 0.25.
      - Assert one group with:
        - `reason == .nearDuplicate`, `keeperAssetID == "A"`, `deleteCandidateIDs == ["B"]`;
        - `recommendedAction == .keepBestTrashRest`, `isAutoCleanEligible`;
        - `XCTAssertNoThrow(try PhotoDeletionGuardrails.validate(group:))`;
        - `PhotoDeletionGuardrails.compatibleAutoCleanGroups(from: groups).map(\.id) == [group.id]`;
        - C in no group.
    - **`testEndToEndVisuallySimilarGroupHasNoDeleteCandidates`:**
      - Setup: distance 0.12, 2 s apart.
      - Assert `reason == .visuallySimilar`, `deleteCandidateIDs.isEmpty`, `recommendedAction == .reviewManually` and `!isAutoCleanEligible`.
      - Also assert that `validate(group:)` throws `.automaticActionNotAllowed`, and that the lower-level `validate(keeperAssetID:deleteCandidateIDs:assetIDs:recommendedAction: .keepBestTrashRest, reason: .visuallySimilar, …)` throws `.visuallySimilarReviewOnly`. Together these prove both layers.
    - **`testEndToEndScreenshotDuplicatesGroup`:**
      - Setup: two `.photoScreenshot` assets with the same `perceptualHash`, the same dimensions and distance 0.01.
      - Assert:
        - both appear in `screenshotAssets`;
        - exactly one group has exactly those two members and `reason == .nearDuplicate`;
        - if its action is `.keepBestTrashRest`, the keeper is not in `deleteCandidateIDs`.
      - Record the current action with a comment rather than over-constraining it.
    - **`testEndToEndScreenshotNeverGroupsWithCameraPhoto`** (added for invariant 8): a camera photo with the same hash and distance 0.01 as a screenshot, 1 s apart. Assert that no group contains both.
    - **`testEndToEndBlurryCategory`:** one asset with sharpness 0.1 and an unrelated embedding. Assert `blurryAssets` contains it, no group contains it, and `unanalyzedPhotoCount == 0`.
    - **`testEndToEndIdenticalCopiesProduceReviewableGroup`:**
      - Setup: identical embeddings (distance 0) and identical signals.
      - Assert a `.nearDuplicate` group exists with `recommendedAction == .reviewManually` and empty `deleteCandidateIDs`.
      - Mark it with the comment `// SCAN-04: tied keeper scores fail the 0.08 margin. WS-38 flips this pin.`
- **Edge cases:**
  - Give every asset complete keeper signals except where the test says otherwise.
  - If the golden-path test fails on current code, stop and report. Do not change thresholds or policy to make it pass.
  - **Build every engine in this file through one private helper**, for example `makeEndToEndEngine(assets:analyses:bridge:)`. Later workstreams must inject stubs into every test here, and the helper keeps each of those edits to one place.
- **Forward note: later workstreams change these tests and must inject stubs.**
  - **WS-37** injects a no-op `KeeperEnriching` into every test, because the default enrichment loader would call PhotoKit on fake assets. It also updates `testEndToEndBlurryCategory`: its signals must carry `blurConfirmation: .confirmed, confirmedSharpness: 0.1, edgeDensity: 0.2`.
  - **WS-38** injects `StubDuplicateVerifier(result:)` plus the no-op enricher through `PhotoScanEngine.init(keepBestEvidence:)` into every test, because the default verifier would load images for fake assets and make every plan review-only. It also flips `testEndToEndIdenticalCopiesProduceReviewableGroup` into `testEndToEndIdenticalCopiesBecomeKeepBestEligible`. `testEndToEndNearDuplicatePairProducesExplicitKeepBestPlan` stays green with a `.sceneMatch` stub. Benchmark (7) in `ScalePerformanceTests` also builds engines over fake assets and takes the same stubs, so it keeps measuring the scan loop and not failed PhotoKit loads.
  - **WS-53** renames `PhotoScanUpdate` fields and may switch these tests to accumulate updates instead of reading only the `isComplete` update. It updates them in its own PR.

**WS-08.4 — Injectable write-buffer tuning (FSB-12)**
- **Change** in `PhotoMLBridge.swift`:
  - Replace the private `WriteBufferTuning` enum with:
    ```swift
    struct PhotoMLWriteBufferTuning: Sendable, Equatable {
        var featureFlushCount = 96
        var pairFlushCount = 384
        var maximumFlushLatencyNanoseconds: UInt64 = 1_500_000_000
        static let `default` = PhotoMLWriteBufferTuning()
    }
    ```
  - The initializer becomes `init(store: PhotoMLStore = .shared, writeBufferTuning: PhotoMLWriteBufferTuning = .default)`.
  - The four use sites (`:108`, `:118`, `:131-132`, `:231`) read the stored instance.
- **Edge cases:** `.shared` must still use the defaults. A test pins that.

**WS-08.5 — `ScanProgressMath` (FSB-12)**
- **Change:** new `iOSCleanup/Views/Home/ScanProgressMath.swift`:
  ```swift
  enum ScanProgressMath {
      struct Progress: Equatable { let processed: Int; let target: Int; let fraction: Double }
      static func resumedProgress(progressOffset: Int, updateProcessed: Int,
                                  updateTarget: Int, resumedTarget: Int?) -> Progress {
          let target = resumedTarget.map { max($0, progressOffset + updateTarget) } ?? updateTarget
          let processed = progressOffset + updateProcessed
          return Progress(processed: processed, target: target,
                          fraction: target == 0 ? 1 : min(Double(processed) / Double(target), 1))
      }
  }
  ```
  - `apply(update:)` (`HomeViewModel.swift:1684-1692`) calls it and assigns the three fields.
  - The result must be byte-for-byte the same math.

**WS-08.6 — Background checkpoint ordering hook (FSB-12 test #7)**
- **Change:**
  - Add `enum BackgroundCheckpointStep: Sendable, Equatable { case mlWritesFlushed, snapshotSaved }` to `HomeViewModelDependencies.swift`.
  - Add `var onBackgroundCheckpointStep: (@Sendable (BackgroundCheckpointStep) -> Void)? = nil` to the dependencies. It stays nil in `.live`.
  - In the background `Task` (`HomeViewModel.swift:1561-1573`), call it right after `flushBufferedWrites()` and right after `saveSnapshot`. Capture the closure in the capture list.
- **Edge cases:** This is observation only; the order and awaits are unchanged. WS-09's `checkpoint.write` signpost sits next to it.

**WS-08.7 — Scale benchmarks (PERF-15, D-PERF-GATE)**

- **`iOSCleanupTests/Support/ScaleBenchmark.swift`** (*new*):
  ```swift
  enum ScaleBenchmark {
      static let maximumGrowthRatio = 6.0
      /// Minimum-of-`repeats` ContinuousClock time of work(factor·n) divided by that of work(n).
      static func growthRatio(baseSize n: Int, factor: Int = 4, repeats: Int = 3,
                              _ work: (Int) throws -> Void) rethrows -> Double
  }
  extension XCTestCase {
      /// Bridges async work into synchronous measure/ratio blocks: XCTestExpectation plus wait(for:).
      func runBlocking(timeout: TimeInterval = 120, _ work: @escaping @Sendable () async -> Void)
  }
  ```
- **`ScalePerformanceTests`:** replace WS-06's placeholder. Test methods are **synchronous**, because `measure` and `wait(for:)` are unavailable from async contexts.
  - Each method does two things:
    1. computes the ratio and runs `XCTAssertLessThan(ratio, ScaleBenchmark.maximumGrowthRatio, "…ratio=\(ratio)")`;
    2. runs `measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: .iterations(3))` at the base size.
  - **Benchmarks:**

    | # | Test | Sizes (n → 4n) | Work | Known-failure wrapper |
    |---|---|---|---|---|
    | 1 | `testRehydrateMakeGroupScales` | 500 → 2,000 groups of 3 `ConfigurablePhotoScanTestAsset`s | `cached.compactMap { $0.makeGroup(using: assetsByID) }` | `XCTExpectFailure("PERF-01: makeGroup rebuilds Set(assetsByID.keys) per group; WS-17 removes this wrapper")`, strict |
    | 2 | `testResumePlannerScalesTo60k` | 15,000 → 60,000 synthetic IDs and metadata; a completed Deep Clean snapshot | `requiredAssetIDs(snapshot:currentAssetIDs:currentMetadata:mode:.deepClean, forceFullRescan:false)` plus `hasConsistentCompletionState` | none |
    | 3 | `testSnapshotCodingScalesTo60k` | 15,000 assets / 750 groups → 60,000 / 3,000 | `JSONEncoder().encode` plus `JSONDecoder().decode` of `CachedPhotoAnalysisSnapshot`; also `XCTAssertLessThan(encoded.count, 25 * 1_024 * 1_024)` at 60k | none (see edge cases) |
    | 5 | `testImageRepositoryLRUScales` | 2,500 → 10,000 distinct keys; capacity fixed at 500 images | `repository.image(for: key) { tiny UIImage }` | none |
    | 6 | `testFileSizeRepositoryWritesScale` | 1,250 → 5,000 `store` calls, then `flush()` | temp `fileURL`; record `debugCompletedWriteCount` and `debugBytesWritten` | `XCTExpectFailure("PERF-13: …; WS-54 removes this wrapper", options: nonStrict)` |
    | 7 | `testEngineThroughputWithFiveMillisecondAnalyzer` | 500 → 2,000 assets, 10 s apart; every 10th asset is a near-duplicate of the previous one | analyzer: 5 ms stub `Task.sleep` (`// test-sleep-ok: latency stub`), fresh temp bridge per run, empty profile | none |

  - **Fixture realism for #3:**
    - IDs look like `"\(UUID().uuidString)/L0/001"`.
    - Groups carry 3 candidates, reasons and a `ScoreBreakdown`.
  - **Output for #7:** print `PERF engine_photos_per_second=<x> n=<n>`. This is the PERF-02 baseline WS-24 compares against.
- **DEBUG counters for #6:** in `AssetFileSizeRepository`, add `#if DEBUG private(set) var debugCompletedWriteCount = 0` and `debugBytesWritten = 0`. Increment them in `beginWrite`'s detached task, after a successful write, through an actor hop, for example `await self?.recordWrite(bytes:)`.
- **`Performance.xctestplan`** keeps `selectedTests: ["ScalePerformanceTests"]`.
- **Baselines:** in Xcode, run the Performance plan on the iPhone 17 Pro simulator, then use **Set Baseline** in the Report navigator for each `measure` test. Commit `iOSCleanup.xcodeproj/xcshareddata/xcbaselines/`. If the implementer cannot use the Xcode UI, land without baselines, and list "set and commit baselines" as an owner action in the PR. Baselines are advisory under D-PERF-GATE; the ratios are the gate.
- **Edge cases:**
  - **#3 size:** the estimate is about 20–25 MB, and the true size is unknown statically. If the 25 MB assertion fails on current code, do not loosen it. Wrap it in `XCTExpectFailure("SCAN-20/PERF-06: snapshot exceeds 25 MB at 60k; WS-54 removes this wrapper")`, record the measured size, and flag it in the PR, because the M0 exit criterion names only PERF-01 and PERF-13.
  - **#6 strictness:** the PERF-13 ratio depends on timing (how many writes coalesce), hence the non-strict wrapper.
  - **Time budget:** the whole plan must finish in under 3 minutes. Shrink `n` if needed, not `factor`.

### Tests
- **`PhotoScanEngineEndToEndTests`:** the 6 tests above (simulator).
- **`PhotoMLStoreTests`** (simulator):
  - `testDefaultWriteBufferTuningMatchesPerformanceContract`: 96 / 384 / 1.5 s.
  - `testBridgeFlushesFeaturesAtCountThreshold`:
    - Tuning: `featureFlushCount 4`, latency 3,600 s.
    - Buffer 3 records and assert `store.stats().featureCount == 0`. Buffer the 4th and assert 4.
    - Keep one variant with the real defaults: 95 records give 0, and the 96th gives 96.
  - `testBridgeFlushesPairsAtCountThreshold`: the same shape, for pairs.
  - `testBridgeFlushesAfterLatency`: latency 50 ms; buffer 1 record; `await waitUntil { (try? await store.stats().featureCount) == 1 }`.
  - `testEnginePauseFlushesBufferedWrites`: a bridge with 3,600 s latency and count 1,000. Buffer 5 feature records, construct `PhotoScanEngine(mlBridge: bridge)`, `await engine.pause()`, and assert `featureCount == 5`.
- **`ScanProgressMathTests`** (*new*):
  - `testResumedProgressIsMonotonic`: offset 40, `updateTarget` 60, `resumedTarget` 100, `updateProcessed` 0…60. Assert:
    - `processed` starts at 40 and never decreases;
    - `target == 100` at every step;
    - `fraction` never decreases and is at most 1.
  - `testFreshScanUsesUpdateTarget`: `resumedTarget` nil.
  - `testZeroTargetIsComplete`: `target == 0` gives `fraction == 1`.
- **`HomeViewModelTests`**, using WS-07's harness:
  - **`testBackgroundCheckpointFlushesMLWritesBeforeSavingSnapshot`:**
    1. Setup: 24 assets. The analyzer parks on a `TestGate` for asset index 12. The bridge uses tuning with latency 3,600 s and count 1,000. An `onBackgroundCheckpointStep` recorder is backed by a lock.
    2. `scanPhotos(mode: .deepClean)`, then `waitUntil { model.scanState == .scanning && model.processedPhotoCount >= 8 }`.
    3. Buffer 1 extra feature record into the bridge.
    4. `model.updateScenePhase(.background)`, then `waitUntil { recorder.steps.count == 2 }`.
    5. Assert `steps == [.mlWritesFlushed, .snapshotSaved]`, that `featureCount` is at least 1 in the temp store, and that the temp cache's `loadSnapshot()` is non-nil with `isComplete == false`.
    6. Open the gate and `waitUntil { model.scanState == .completed }` (10 s).
  - **`testProgressSnapshotNeverRegressesAcrossPauseAndResume`:**
    1. Same gated setup. Record `progressSnapshot.processedPhotoCount` through a Combine sink on `$progressSnapshot`.
    2. Wait until at least 8 are processed. `pauseDeepClean()`, open the gate, then `resumeDeepClean()`.
    3. Wait for `.completed`.
    4. Assert the recorded sequence never decreases and ends at 24.
    5. Forward note: WS-50 (chapter 11) makes `progressSnapshot` non-published and moves this sink to `progressStore.$snapshot`, with the same assertions.
- **`ScalePerformanceTests`:** the 6 benchmarks, run by `scripts/test.sh -testPlan Performance` (simulator; never in the PR job).

### Acceptance criteria
- [ ] The 6 end-to-end tests pass. Removing the `reason == .visuallySimilar` clause from `finalAction` (`PhotoScanEngine.swift:1353`) makes `testEndToEndVisuallySimilarGroupHasNoDeleteCandidates` fail. Try it locally; do not commit it.
- [ ] Deleting the `flushBufferedWrites()` call from `pause()` fails `testEnginePauseFlushesBufferedWrites`. Changing `ScanProgressMath` to drop `progressOffset` fails `testResumedProgressIsMonotonic`. Swapping the flush and save order in the background handler fails the ordering test. Record each local mutation check in the PR.
- [ ] `PhotoMLBridge.shared` and `HomeViewModelDependencies.live` behave exactly as before, with defaults pinned by a test.
- [ ] `scripts/test.sh -testPlan Performance` finishes in under 3 minutes.
- [ ] In the Performance run, `XCTExpectFailure` wraps only PERF-01, which fails as expected, and PERF-13, which is non-strict; any snapshot-size wrapper is reported in the PR. Every other ratio is below 6. The console shows `PERF engine_photos_per_second=…`.
- [ ] Baselines are committed under `xcshareddata/xcbaselines/`, or listed as an owner action.
- [ ] The unit suite is green in random order, with no new warnings, and CI is green.

### Pitfalls and out of scope
- **Invariant 22:** performance work never changes classification, keeper choice or deletion semantics, and this workstream changes none. The only production edits are:
  - one init parameter;
  - the injectable tuning;
  - a pure extraction;
  - an observer closure;
  - DEBUG counters.
- **Pinned expectations:** the engine tests pin today's policy. When a later workstream changes it on purpose (WS-13, WS-37, WS-38), that workstream updates the pin in the same PR, with its finding ID in the comment.
- Reconciliation (reported by chapter 08): WS-37 and WS-38 update this file's end-to-end tests. They inject a no-op `KeeperEnriching` and `StubDuplicateVerifier`, update the blurry fixture's signals and flip the identical-copies pin. Hence the single engine-builder helper required in WS-08.3.
- Reconciliation (README §9, contract 15): WS-50 moves `testProgressSnapshotNeverRegressesAcrossPauseAndResume` to `progressStore.$snapshot`. WS-53's `PhotoScanUpdate` field renames may make these tests accumulate updates. Both changes are made in those workstreams, not here.
- **Merge overlap:** WS-09 may land in parallel and also edits `PhotoScanEngine.swift` and `HomeViewModel.swift` (instrumentation lines). Rebase carefully; the edits don't overlap semantically.
- **Out of scope:**
  - Benchmark (4) (WS-50).
  - Fixing PERF-01 (WS-17) or PERF-13 (WS-54).
  - Engine throughput changes (WS-24).
  - `CheckpointLifecycleCoordinator`: not created, because WS-07's seam replaces it.

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| FSB-05 | partially | The gap is real: `:412` is the only group assertion, and `:493` reads the global profile. Two proposed assertions are wrong for the current API. `validate(groups:)` does not exist; the plan uses `validate(group:)` plus `compatibleAutoCleanGroups(from:)`. A `visuallySimilar` group throws `.automaticActionNotAllowed` first, because `PhotoGroup.init` downgrades its action; the plan asserts both layers. `ConfigurablePhotoScanTestAsset` subclasses WS-03's `TestPhotoAsset` and adds `hasAdjustments`/`sourceType`. The camera/screenshot separation test is an addition. |
| FSB-12 | confirmed | The private tuning (`:34-38`), the `pause()` flush (`:379-382`) and the inline math (`:1684-1692`) all match. Test #7 uses WS-07's `HomeViewModelDependencies` plus an ordering observer, instead of a `CheckpointLifecycleCoordinator`. Tests poll with `waitUntil`, with no fixed sleeps. A HomeViewModel-level pause/resume monotonic test is added. |
| PERF-15 | confirmed | There are no `measure`/metric tests. Benchmark (1) targets `makeGroup(using:)` directly, because `rehydrateGroups` needs PhotoKit. Benchmark (4) belongs to WS-50 (`PhotoResultsPresentation` doesn't exist). Benchmark (6) needs DEBUG write counters. Ratios are measured by a helper, outside `measure`, to fit the 3-minute budget. The 25 MB snapshot bound may fail today and has a documented contingency. |

---

## WS-09 — Device QA plan, signposts and baseline run

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M0 | M | WS-02, WS-07 | yes | `ws/09-device-qa-baseline` |

**Primary files:**
- **Docs:** `docs/DEVICE_QA.md` (*new*), `docs/qa-runs/TEMPLATE.md` (*new*), `README.md`, `CLAUDE.md`.
- **Instrumentation (new):** `iOSCleanup/Utilities/PhotoDuckSignposts.swift` (*new*), `iOSCleanup/Utilities/ScanPerformanceRecorder.swift` (*new*), `iOSCleanup/Utilities/PairDistanceHistogram.swift` (*new*, DEBUG), `iOSCleanup/Utilities/DebugQAProbes.swift` (*new*, DEBUG).
- **One-line signposts in:** `iOSCleanup/Utilities/SharedHelpers.swift`, `iOSCleanup/Engines/PhotoScanEngine.swift`, `iOSCleanup/Engines/PhotoAnalysisCache.swift`, `iOSCleanup/Engines/PhotoMLBridge.swift`, `iOSCleanup/Engines/FileScanEngine.swift`, `iOSCleanup/Views/HomeViewModel.swift`, `iOSCleanup/Views/Home/HomeViewModelDependencies.swift`, `iOSCleanup/iOSCleanupApp.swift`.
- **Tests:** `iOSCleanupTests/ScanInstrumentationTests.swift` (*new*).

**Findings covered:** BUILD-07 (P1, confirmed)

**Decisions applied:**
- **D-SCAN-ADAPT defaults** (spec/README §6) are "tuning constants that WS-09 and later QA runs may adjust". This run supplies their first data points; it changes no constants.
- **D-THRESHOLDS (verify-first calibration):** this run provides the DEBUG pair-distance histogram.

### Goal
- A repeatable real-device checklist exists, together with a results template.
- Scan, restore, checkpoint and inventory work shows as named signpost intervals in Instruments.
- A scan prints a one-line performance summary: photos/s, p50/p99 item latency, counts and thermal state.
- DEBUG probes answer the verify-first questions.
- The owner then records a baseline run on a device with at least 10k photos. That run sizes M1 and feeds WS-11, WS-13, WS-18, WS-19, WS-20, WS-22, WS-28, WS-37 and WS-39.

### Current behavior (verified)
- No `OSSignposter` or `os_signpost` exists anywhere in `iOSCleanup/`. There is no `docs/` directory. `CLAUDE.md:79` says "Real-device PhotoKit behavior still needs device QA".
- **Loggers:** they use two subsystems, `com.photoduck.app` (`PhotoAnalysisCache.swift:490`, `ExternalPhotoExportService.swift:1673`) and `com.photoduck.iOSCleanup` (the engine, HomeViewModel, MLBridge and CoreML loggers). The engine logs only at DEBUG level (`PhotoScanEngine.swift:504`, `:930`, `:975`).
- **Instrumentation anchor points** (line numbers as of this writing; WS-07 moves the metadata enumeration):
  - **Full photo enumerations:**
    - `PhotoScanEngine.swift:62-80` (`SystemPhotoScanAssetProvider.fetchImageAssets`);
    - `HomeViewModel.swift:2528-2548` (metadata; `HomeViewModelDependencies.systemLibraryPhotoMetadata` after WS-07);
    - `HomeViewModel.swift:2272-2280` (the premature-completion repair).
  - **Video enumeration:** `FileScanEngine.swift:35-44`.
  - **Snapshot decodes:** `PhotoAnalysisCache.swift:584` (in `loadSnapshot(from:)`) and `:830` (the write-path candidate check). **Rehydrate:** `:768-795`. **Encode and write:** `:671-700` (a detached task; `lastEncodedByteCount` is DEBUG-only, `:509`).
  - **Per-item analysis:** the task-group closure at `PhotoScanEngine.swift:648-663`.
  - **Serial drain:** `:686-900`. **Regroup:** the `makeGroups` call at `:901-915`.
  - **Analysis failures:** the fast-format miss at `:1020`, where `loadedImage == nil` leads to the fallback; the Vision failure catch at `:1080`.
  - **Degraded delivery:** the `PHImageResultIsDegradedKey` read at `SharedHelpers.swift:590-592`.
  - **ML flush:** `PhotoMLBridge.flushBufferedWrites()` (`:140-151`).
  - **Hydration done:** `HomeViewModel.swift:2126` (`hasHydratedAnalysisCache = true`).
- **Verify-first APIs:** `PHPhotoLibrary.fetchPersistentChanges(since:)`, `PHPersistentChangeToken` (NSSecureCoding), `PHAsset.sourceType`, `canPerform(.delete)` and `hasAdjustments`. All type-check at iOS 17.

### Implementation plan

**WS-09.1 — Signposter**
- **Change:** new `iOSCleanup/Utilities/PhotoDuckSignposts.swift`:
  ```swift
  import os
  /// Interval names are a contract: later workstreams and DEVICE_QA.md cite them.
  /// Never put asset IDs, filenames or paths in signpost messages; counts and bytes only.
  enum PhotoDuckSignposts {
      static let signposter = OSSignposter(subsystem: "com.photoduck.app", category: .pointsOfInterest)
      static func interval<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
          try signposter.withIntervalSignpost(name, around: body)
      }
      static func interval<T>(_ name: StaticString, _ body: () async throws -> T) async rethrows -> T {
          let state = signposter.beginInterval(name, id: signposter.makeSignpostID())
          defer { signposter.endInterval(name, state) }
          return try await body()
      }
  }
  ```
  This shape type-checks under strict concurrency.

  **Intervals.** Each is added with one line, or one begin/end pair. Messages carry only the value noted.

  | Interval | Placement | Message |
  |---|---|---|
  | `restore.decode` | `PhotoAnalysisCache.swift:584` | — |
  | `restore.rehydrate` | `rehydrateGroups` / `rehydrateAssets` | group or asset count |
  | `inventory.enumerate` | the 3 photo sites and the video site | `"photos.engine"`, `"photos.metadata"`, `"photos.repair"`, `"videos"`, plus the count |
  | `analyze.item` | around `assetAnalyzer(workItem.asset, allowNetworkAccess)` inside the coordinator operation, so it covers injected analyzers too | — |
  | `engine.drain` | the per-batch serial block, from `for analysis in analyses` through the three `buffer…` calls | batch size |
  | `engine.regroup` | the `makeGroups` call | descriptor count |
  | `ml.flush` | the body of `flushBufferedWrites` | feature, pair and asset-analysis counts |
  | `checkpoint.write` | inside the detached encode/write task | `"bytes=\(data.count)"` on success, `"failed"` otherwise |

  **Events** (`emitEvent`):

  | Event | Where |
  |---|---|
  | `scan.started` | `scanPhotos(mode:)` entry, after the run lock is taken |
  | `scan.firstGroup` | in `apply(update:)`, when `groupsFoundCount` goes from 0 to more than 0 in the active run |
  | `scan.completed` | where `lastCompletedAt = Date()` is set |
  | `home.hydrated` | `HomeViewModel.swift:2126` |
  | `analyze.fastMiss` | `PhotoScanEngine.swift:1020` branch |
  | `analyze.visionFailure` | catch at `:1080`, message = `(error as NSError).code` |
  | `image.degraded` | `SharedHelpers.swift:590`, when `isDegraded && deliveryMode == .fastFormat` |
- **Edge cases:**
  - Signposts are no-ops unless recording.
  - Keep each insertion to one line, or a begin/end pair, with no logic changes.
  - Do not add signposts inside tight per-pair loops.

**WS-09.2 — Scan performance summary**
- **Change:** new `iOSCleanup/Utilities/ScanPerformanceRecorder.swift`:
  ```swift
  final class ScanPerformanceRecorder: @unchecked Sendable {   // NSLock-protected
      func recordItem(duration: Duration)              // called from the task-group closure
      func summary(processed: Int, analyzed: Int, unanalyzed: Int, groups: Int,
                   elapsed: Duration, thermal: ProcessInfo.ThermalState) -> ScanPerformanceSummary
  }
  struct ScanPerformanceSummary: Equatable, Sendable {
      let photosPerSecond: Double; let p50Milliseconds: Double; let p99Milliseconds: Double
      let processed, analyzed, unanalyzed, groups: Int; let thermalState: String
      /// Nearest-rank percentile over a sorted copy. The recorder keeps at most 100_000 samples,
      /// dropping the oldest, so it stays bounded.
      static func percentile(_ p: Double, of sortedMilliseconds: [Double]) -> Double
      var logLine: String   // "scan_summary photos_per_s=… p50_ms=… p99_ms=… processed=… analyzed=… unanalyzed=… groups=… thermal=…"
  }
  ```
  - `performScan` creates one recorder per run and measures each item with `ContinuousClock` around the same call that `analyze.item` wraps.
  - At completion or cancellation it logs `logLine` through `Logger(subsystem: "com.photoduck.app", category: "ScanPerformance").notice`, which is numbers only, so it is visible in Release Console.
- **Edge cases:**
  - The recorder has no effect on scan control flow.
  - The sample count is bounded, as the engineering rules require.

**WS-09.3 — DEBUG probes**
- **Pair-distance histogram:** new `PairDistanceHistogram.swift`, `#if DEBUG`.
  - A `struct PairDistanceHistogram` with 30 bins of 0.01 from 0 to 0.30, plus an overflow bin. `mutating func record(_ distance: Double)` and `var logLine: String`.
  - The engine records `distanceResolution.distance` for each evaluated generic pair, at `PhotoScanEngine.swift:760`. Screenshot pairs are tallied separately.
  - The engine logs both histograms once per completed scan (DEBUG).
  - WS-39 calibrates from this output.
- **QA probes:** new `DebugQAProbes.swift`, `#if DEBUG`, launch-argument driven. It is called from `iOSCleanupApp` `.task` only when authorization is `.authorized` or `.limited`, never while `notDetermined`.
  - `-PhotoDuckQACensus YES` enumerates images once and logs counts only:
    - total;
    - by `sourceType` (userLibrary, cloudShared, iTunesSynced);
    - `canPerform(.delete) == false`;
    - favorites;
    - the edit heuristic (`modificationDate` more than 1 s from `creationDate`, matching `SharedHelpers.swift:493-496`) versus `hasAdjustments`: both, heuristic only, adjustments only;
    - favorites flagged as edited by the heuristic;
    - `PhotoMLBridge.shared.stats()` counts: features, embeddings, pairs, feedback and training rows. This replaces the deleted `learningDebugSummary`.
  - Put the counting in a pure `static func tally(_ samples: [CensusSample]) -> LibraryCensus` so it can be tested.
  - `-PhotoDuckPersistentChangeProbe YES`:
    - On launch, archive `PHPhotoLibrary.shared().currentChangeToken` into `UserDefaults` (`PhotoDuckDebugChangeToken`).
    - If a previous token exists, call `fetchPersistentChanges(since:)` and log the change count plus the summed inserted/updated/deleted counts from `changeDetails(for: .asset)`. Log any thrown error's domain and code.
- **Edge cases:**
  - Probes log counts only: no identifiers or filenames (invariant 26).
  - They never run in Release.
  - The census enumeration passes a `PHFetchOptions()`, never `options: nil`. WS-40's `PhotoFetchLintTests` later forbids `nil` and inline `PHFetchOptions()` outside `PhotoLibraryFetch.swift`, and WS-40 switches the census to `PhotoLibraryFetch.imageOptions()` so that hidden burst frames are counted.

**WS-09.4 — `docs/DEVICE_QA.md` and `docs/qa-runs/TEMPLATE.md`**
- **Existing file:** WS-02, WS-04 and WS-05 may already have created `docs/DEVICE_QA.md` with a `## Pending steps from chapter 01` section. Do not overwrite it. Fold each pending step into its area below with a step ID and an "(added by WS-NN)" tag, then delete the pending section. WS-06's DQA-BUILD-01, which waited in its PR, joins the standing checklist.
- **`DEVICE_QA.md` sections:**
  0. **How to use this doc:**
     - Each step has an ID `DQA-<AREA>-<n>`.
     - Later workstreams append steps under their area and tag them "(added by WS-NN)".
     - Results go into `docs/qa-runs/<yyyy-mm-dd>-<device>-<build>.md`, copied from the template.
     - Attach the in-app diagnostic export (opt-in) to the run file or its issue.
  1. **Builds:**
     - **Pass A, performance:** Xcode ▸ Product ▸ Profile, which is Release and dev-signed. Use an Instruments document with Points of Interest, os_signpost, Allocations, Thermal State and optionally Time Profiler.
     - **Pass B, observations:** an Xcode Run (Debug), for the histogram and probes. Set launch arguments in the scheme.
     - **Pass C, TestFlight install:** WS-02 makes this possible. It is an install and launch sanity check only; Instruments cannot attach to TestFlight builds.
  2. **Devices and libraries:**
     - One iOS 17.x device (the minimum OS) and one current iPhone.
     - Libraries:
       - (a) about 500 local photos;
       - (b) about 10k local;
       - (c) 30–60k with iCloud Photos plus Optimize iPhone Storage, run once online and once in airplane mode;
       - (d) Limited access;
       - (e) access denied.
     - Record the library composition from the census.
  3. **DQA-BASE-01 baseline procedure (Pass A):** force-quit the app, start recording, launch, and let the first Deep Clean run to completion (or 60 minutes). Record every metric:
     - **cold launch to hydrated Home:** process start to the `home.hydrated` event;
     - **time to first group:** `scan.started` to `scan.firstGroup`;
     - **total scan time:** `scan.started` to `scan.completed`;
     - **photos/s, p50/p99 item latency, analyzed/unanalyzed/groups:** from the `scan_summary` Console line;
     - **peak memory:** Allocations or the Xcode gauge;
     - **snapshot bytes:** the last `checkpoint.write` bytes;
     - **checkpoint bytes per minute:** the sum of `checkpoint.write` bytes over the run divided by minutes;
     - **background checkpoint write duration:** the `checkpoint.write` interval right after backgrounding. WS-28 reads this.
     - **thermal state at the 30-minute mark:** from the Thermal State track;
     - **full enumerations:** the `inventory.enumerate` count per cold launch, and per Control Center pull-down and dismissal during idle.
  4. **Verify-first observations (Pass B).** Each lists its steps, what to record, and the workstream that consumes it:
     - **DQA-VF-DEL06 (WS-11):**
       1. In Duck Mode, swipe-delete asset X, so it is pending.
       2. Switch to Photos and delete X there.
       3. Return and commit the pending deletes.
       4. Record whether the system dialog appears, the error domain and code shown, and whether the other pending assets were deleted.
     - **DQA-VF-SCAN21 (WS-13):** on a device with Finder/iTunes-synced albums, run the census. Record the `sourceType` counts and the `canPerform(.delete) == false` count.
     - **DQA-VF-SCAN14 (WS-22):** run a scan offline with iCloud optimization on. Record `analyze.fastMiss`, `image.degraded` and `analyze.visionFailure` counts, plus p50/p99, and whether local photos produce `image.degraded`.
     - **DQA-VF-SCAN10 (WS-37):**
       1. Favorite 3 unedited photos.
       2. Import 3 photos from Files or AirDrop.
       3. Edit 3 photos (crop or filter).
       4. Run the census before and after. Record heuristic versus `hasAdjustments` for each group.
     - **DQA-VF-SCAN05 (WS-39):** run a full Debug scan and paste both histogram lines.
     - **DQA-VF-STATE01 (WS-19):**
       1. Start a Deep Clean.
       2. At about 30%, take a new photo.
       3. Let the scan finish, then force-quit and relaunch.
       4. Record the Home hero text, any "paused" state or storage warning, and the unanalyzed count.
     - **DQA-VF-STATE02 (WS-20):**
       1. Run the census to get ML stats.
       2. Switch Settings ▸ Photos access from Full to Limited, selecting 5 photos. Open the app and wait 1 minute.
       3. Switch back to Full, open the app, and run the census again.
       4. Record ML feature and pair counts before and after, and whether the full-library results survived.
     - **DQA-VF-STATE07 (WS-28):**
       1. During a Deep Clean, switch apps 20 times, staying away about 10 s each time.
       2. Record the unanalyzed count before and after, the `analyze.visionFailure` events after backgrounding, and any "Background task … still not ended" console warnings.
     - **DQA-VF-WS18 (WS-18):**
       1. Launch with the persistent-change probe.
       2. Add 2, edit 1 and delete 1 photo in Photos.
       3. Relaunch with the probe.
       4. Record whether inserted/updated/deleted details were returned, their counts, and any error.
  5. **Standing checklist** (BUILD-07). Each item gets a step ID:
     - Background mid-scan; force-quit and relaunch (resume from checkpoint); edit the library while PhotoDuck is open.
     - **Reclaim honesty:** note Settings free space, Keep Best N groups, check the Recently Deleted count, empty it, and compare the free-space delta with PhotoDuck's number (expect within 10%).
     - **Safety:** the keeper never appears in Recently Deleted; visuallySimilar groups offer no delete; declining the system dialog restores the UI with no error.
     - **Video:** compress a 4K clip; check that date, location and favorite are preserved, and the storage delta.
     - **Export:** to a USB-C drive and to iCloud Drive; cancel and resume; background for more than 30 s; check the Live Activity; verify the manifest before deleting originals.
     - **Purchases:** sandbox purchase, restore on a second device, Ask to Buy, offline launch with the cached entitlement.
     - **Release:** archive, Organizer Validate and Privacy Report, then install from TestFlight.
     - **DQA-BUILD-01** (from WS-06).
- **`TEMPLATE.md`:**
  - A header block: date, tester, device model, iOS version, build (commit and configuration), library composition from the census, iCloud settings, and network.
  - A metrics table with one row per DQA-BASE-01 metric: value, how measured, notes.
  - One section per DQA-VF step, with raw log lines pasted.
  - A "Surprises / new bugs" list.
- **Docs:** link `docs/DEVICE_QA.md` from `README.md` and `CLAUDE.md`. Add a `CLAUDE.md` line: "Signpost names in `PhotoDuckSignposts.swift` are a contract; see DEVICE_QA.md."

**WS-09.5 — The baseline run (owner action)**
- The owner runs DQA-BASE-01 and all DQA-VF steps on at least one device with 10k or more photos. The owner commits `docs/qa-runs/<date>-<device>-baseline.md` in a follow-up PR, or pastes it for an agent to commit.
- Sonnet's PR lands the instrumentation and docs. The M0 exit criterion needs the run file.

### Tests
- **`iOSCleanupTests/ScanInstrumentationTests.swift`** (*new*, simulator):
  - `testPercentileNearestRank`: for 1…100 ms, p50 = 50 and p99 = 99. For a single sample, p50 = p99 = that sample.
  - `testSummaryPhotosPerSecond`: 120 processed in 60 s gives 2.0. Zero elapsed gives 0, never infinity.
  - `testRecorderIsBounded`: 100,050 records keep 100,000.
  - `testHistogramBinsAndOverflow` (DEBUG): 0.004 goes to bin 0, 0.05 to bin 5, 0.29 to bin 29, and 0.9 to overflow. `logLine` contains no letters apart from its fixed labels.
  - `testCensusTally` (DEBUG): 6 synthetic samples produce the expected source-type, deletability and edit-heuristic-versus-adjustment counts.
  - `testScanCompletesWithInstrumentation`: the existing stub-provider scan with an isolated bridge still completes with the same counts. It proves signposts and the recorder don't change behavior.
- The full existing suite must stay green.
- The device run is manual (Pass A, B and C).

### Acceptance criteria
- [ ] `docs/DEVICE_QA.md` has the sections above, with step IDs. `docs/qa-runs/TEMPLATE.md` exists. `README.md` and `CLAUDE.md` link to them.
- [ ] Instruments on a device, or at least the simulator with the fixture harness, shows every interval name listed in WS-09.1. The PR includes a screenshot of the Points of Interest track from a simulator fixture scan.
- [ ] A simulator fixture scan logs one `scan_summary` line and, in Debug, the histogram lines. A `DebugQAProbes` census run in the simulator logs counts only.
- [ ] No signpost, log line or probe output contains an asset ID, filename or path. Check this by grepping the new format strings.
- [ ] `scripts/build-release.sh` succeeds, and `PairDistanceHistogram` and `DebugQAProbes` are absent from Release.
- [ ] All tests pass; there are no new warnings.
- [ ] **M0 exit (owner action):** `docs/qa-runs/<date>-<device>-baseline.md` records every DQA-BASE-01 metric and every DQA-VF observation on a library of 10k or more.

### Device QA
This workstream **is** the Device QA plan. Run DQA-BASE-01, then DQA-VF-DEL06, SCAN21, SCAN14, SCAN10, SCAN05, STATE01, STATE02, STATE07 and WS18, then the standing checklist, as written in `docs/DEVICE_QA.md`.

### Pitfalls and out of scope
- **Diagnostics hygiene (invariant 26):** signpost and summary messages carry numbers only. Do not route any of this into the user-exportable diagnostics log, which WS-02 and WS-15 own.
- **Signposts are not logic.** Do not refactor while inserting them. If an anchor point has moved because WS-08 landed first, place the marker at the equivalent statement.
- **The DEBUG seeder is not a QA tool on devices.** It is simulator-only (WS-07), so device libraries come from real photos.
- **Out of scope:** fixing anything the baseline reveals. File each finding against its workstream, or in `spec/BACKLOG.md`.
- Reconciliation: chapter 01 (WS-02, WS-04, WS-05) tells its Device QA steps to wait in a `## Pending steps from chapter 01` section for WS-09 to fold in. WS-09.4 now does that explicitly, instead of recreating the file.
- Reconciliation: the census fetch avoids `options: nil`, because of WS-40's `PhotoFetchLintTests` (chapter 08).

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| BUILD-07 | confirmed | There are no signposts or QA docs. `CLAUDE.md:79` still says device QA is needed. The plan keeps the finding's checklist and adds: the interval names later chapters cite; a Release-visible `scan_summary` line for photos/s and p50/p99, which Instruments' interval summary can't give directly; DEBUG probes for SCAN-21/SCAN-10/STATE-02/WS-18 and the SCAN-05 histogram; and a split into Profile, Debug and TestFlight passes, because Instruments cannot attach to TestFlight builds. |

---

## WS-10 — Mechanical decomposition of giant view files

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M0 | L | WS-04, WS-05, WS-06 | no | `ws/10-view-decomposition` |

**Primary files:**
- **Files views:** `iOSCleanup/Views/Files/FileResultsView.swift`, `iOSCleanup/Views/Files/LargeVideoReviewModel.swift` (*new*), `iOSCleanup/Views/Files/LargeVideoRowViews.swift` (*new*), `iOSCleanup/Views/Files/LargeVideoPlayerView.swift` (*new*), `iOSCleanup/Views/Files/FileResultsView+Export.swift` (*new*), `iOSCleanup/Views/Files/FileResultsView+Banners.swift` (*new*), `iOSCleanup/Views/Files/ExternalExportCoordinator.swift` (*new*), `iOSCleanup/Views/Files/VideoCompressionView.swift`.
- **Export views:** `iOSCleanup/Views/Export/ExportAlbumView.swift` (*new*), `iOSCleanup/Views/Export/ExternalFolderPicker.swift` (*new*), `iOSCleanup/Views/Export/ExternalPhotoExportProgressStatusView.swift` (*new*).
- **Views moved out of HomeView:** `iOSCleanup/Views/Photos/PhotoCategoryReviewView.swift` (*new*), `iOSCleanup/Views/Components/CategoryPhotoThumbnail.swift` (*new*), `iOSCleanup/Views/Home/CompletionOverlay.swift` (*new*), `iOSCleanup/Views/HomeView.swift`.
- **Utilities:** `iOSCleanup/Utilities/PhotoKitRequestState.swift` (*new*), `iOSCleanup/Utilities/PHAsset+FileSize.swift`.
- **Tests and project:** `iOSCleanupTests/PhotoKitRequestStateTests.swift` (*new*), `iOSCleanupTests/ExternalExportCoordinatorTests.swift` (*new*), `iOSCleanup.xcodeproj/project.pbxproj`.

**Findings covered:** FILES-21 (P2, confirmed)

**Decisions applied:** None specific. Invariants 24 (export: copy, verify, manifest, explicit delete) and 29 (no visual redesign) constrain every step.

### Goal
- No file in `Views/Files` exceeds about 600 lines.
- `ExportAlbumView`, `PhotoCategoryReviewView` and `CompletionOverlay` live outside `HomeView.swift`.
- Export orchestration exists once, in `ExternalExportCoordinator`, used by both export screens.
- The four video PhotoKit request-state classes become one generic type.
- Nothing changes for the user, apart from the listed, intentional alignment of the video export path with the album export path.
- Later workstreams (WS-11, WS-14, WS-27, WS-29, WS-35, WS-42, WS-57) edit small files without conflicts.

### Current behavior (verified)
- **`FileResultsView.swift` is 2,281 lines:**
  - **Model types:** `FileDeletionErrorPolicy` `:7`, `LargeVideoOrganization` `:18`, `LargeVideoReviewLayout` `:26`, `LargeVideoReviewSection` `:31`, `LargeVideoReviewOrganizer` `:37`, `LargeVideoReviewSectionMemo` `:147-199`, `LargeVideoExportSelection` `:200-229`.
  - **`FileResultsView`:** `:231-1326`, with 30 `@State`/`@EnvironmentObject` properties at `:238-268`.
    - **Views:** `body` `:327`, `reviewSection` `:683-752`, banners `:775-840`, `selectedExportActionBar` `:841-970`, `continueToExportBar` `:971-1005`.
    - **Export actions:** `:1006-1131`, and `exportSelectedVideos` at `:1133-1283`.
    - **Deletion:** `:1285-1326`.
  - **Row views:** `FileRow` `:1330-1545`, `LargeVideoGridCard` `:1548-1715`, `LargeVideoThumbnail` `:1716-1876`.
  - **Player:** `LargeVideoPlayerView` `:1879-2112`, `VideoPlaybackLoadingError` `:2113`.
  - **Request states:** `VideoPlaybackAssetRequestState` `:2127-2203`, `VideoPlayerItemRequestState` `:2205-2281`.
- **`HomeView.swift`:** 2,158 lines, including WIP committed by WS-01.
  - `CompletionOverlay` `:1024-1085` and `PhotoCategoryReviewView` `:1086-1292`.
  - `ExternalPhotoExportProgressStatusView` `:1293-1368`. Per the WIP it takes `@ObservedObject var store`, `onCancel` and `cancellationHelp`, and shows a byte-progress label.
  - `ExportAlbumView` `:1369-2069`, with `exportAlbum(to:)` at `:1819-1978`.
  - `ExternalFolderPicker` `:2070-2109` and `CategoryPhotoThumbnail` `:2110-2158`.
  - `CategoryPhotoThumbnail` is used by both `PhotoCategoryReviewView` (`:1177`) and `ExportAlbumView` (`:1492`).
- **Two export orchestrations**, in `FileResultsView:1133-1283` and `ExportAlbumView:1819-1978`. Both do the same lifecycle work:
  - `ExternalPhotoExportSessionGate.shared.acquire()` (a private init; `ExternalPhotoExportService.swift:251-268`), and release in `defer`;
  - `await Task.yield()`;
  - the idle timer on;
  - `beginBackgroundTask`, whose expiration calls `liveActivity.markPaused()`;
  - `liveActivity.start(totalFileCount: 0)`;
  - `ExternalPhotoExportService().export(assets:to:onProgress:)`, where each progress callback updates the store and the Live Activity;
  - Live Activity `end` with a phase mapped from `wasCancelled` / `failures`;
  - separate `CancellationError` and generic `catch` paths.
- **Where they diverge:**
  - (a) `ExportAlbumView` treats `exportedAssetIDs ∪ alreadyExportedAssetIDs` as verified. `FileResultsView` uses `exportedAssetIDs` only, so already-on-drive videos stay selected as "unfinished" (part of FILES-11).
  - (b) Only `ExportAlbumView` adds the migrated-legacy-folder note and the "already on this drive" note.
  - (c) Only `ExportAlbumView` raises an alert when every item failed.
  - (d) Only `ExportAlbumView` offers deletion afterwards (`deleteAfterExport`, `showPostExportActions`).
  - (e) Only `FileResultsView` plays `DuckHaptics.success()`.
  - (f) The background-task names and all user-facing strings differ.
  - (g) Only `ExportAlbumView` pre-checks for unavailable selected items.
- **Four request-state classes** built the same way (lock, continuation, request ID, finished flag):
  - `VideoAssetRequestState` (`VideoCompressionView.swift:458-537`);
  - the two classes in `FileResultsView`;
  - `VideoFileSizeRequestState` (`PHAsset+FileSize.swift:550-607`).
- **How they differ:**
  - The first three use `CheckedContinuation<Void, Error>`, keep the value in a locked box (`AVAsset`/`AVPlayerItem` are not Sendable), throw `CancellationError` on cancel, and cancel a late request ID only `if isCancelled`.
  - `VideoFileSizeRequestState` uses `CheckedContinuation<Int64?, Never>`, resumes `nil` on cancel or when installed after finishing, and cancels a late request ID `if isFinished`, which also covers timeouts.
- A fifth, different class, `PhotoImageRequestState` (`SharedHelpers.swift`, used by `PHAsset.loadImage`), is **not** part of this consolidation.
- `FileRow` and `LargeVideoGridCard` take the same 11 parameters: the file, the purchase manager, 4 flags and 5 closures (`:1330-1341`, `:1548-1559`). Call sites are at `:702-718` and `:731-747`.

### Implementation plan
Do one commit per step. Steps 1–4 and 8 are pure moves; the build and the full suite must pass after each.

**WS-10.1 — Move the review model**
- Move `:7-229` (everything above `struct FileResultsView`) to `Views/Files/LargeVideoReviewModel.swift`.
- `FileScanEngineTests` references these types (`LargeVideoReviewOrganizer`, `LargeVideoExportSelection`); they stay internal.

**WS-10.2 — Move the row views**
- Move `FileRow`, `LargeVideoGridCard` and `LargeVideoThumbnail` to `Views/Files/LargeVideoRowViews.swift`. Drop `private`, because they are now used across files.
- If the file exceeds about 600 lines, give `LargeVideoThumbnail` its own `LargeVideoThumbnail.swift`.

**WS-10.3 — Move the player**
- Move `LargeVideoPlayerView` and `VideoPlaybackLoadingError` to `Views/Files/LargeVideoPlayerView.swift`.
- The two request-state classes move with them for now; step 5 replaces them.

**WS-10.4 — Move the HomeView satellites**
- `CompletionOverlay` goes to `Views/Home/CompletionOverlay.swift`.
- `PhotoCategoryReviewView` goes to `Views/Photos/PhotoCategoryReviewView.swift`.
- `CategoryPhotoThumbnail` goes to `Views/Components/CategoryPhotoThumbnail.swift` (internal).
- `ExternalPhotoExportProgressStatusView`, `ExportAlbumView` and `ExternalFolderPicker` go to `Views/Export/*.swift`.
- `DiagnosticShareItem` and `DiagnosticActivityView`, `StatMiniCard` and `HomeCategoryTile` stay in `HomeView.swift`.
- Add the new `Views/Export` group to `project.pbxproj`, and `Views/Home` if WS-07 has not.

**WS-10.5 — `PhotoKitRequestState<Value>`**
- **Why:** A cancellation-race fix in one copy never reached the other three.
- **Change:** new `Utilities/PhotoKitRequestState.swift`:
  ```swift
  /// One lock-guarded bridge from a PhotoKit request callback to an async caller.
  /// The value is stored, not passed through the continuation, because AVAsset/AVPlayerItem are not Sendable.
  final class PhotoKitRequestState<Value>: @unchecked Sendable {
      typealias RequestCanceller = (PHImageRequestID) -> Void
      var value: Value? { get }                      // under the lock
      /// Returns false and resumes by throwing CancellationError if the state was cancelled before install.
      /// If it already completed, resumes immediately with the stored outcome.
      func install(_ continuation: CheckedContinuation<Void, Error>) -> Bool
      /// Cancels `requestID` right away if the state already finished for any reason
      /// (cancelled, timed out or completed). That is the file-size semantics; for a completed
      /// request it is a PhotoKit no-op.
      func setRequestID(_ requestID: PHImageRequestID, cancel: RequestCanceller)
      func complete(_ result: Result<Value, Error>)  // first outcome wins
      func cancel(_ cancelRequest: RequestCanceller) // cancels the stored ID once; resumes with CancellationError
  }
  ```
  - **Adopt it at four sites:**
    - `VideoCompressionView` uses `PhotoKitRequestState<AVAsset>`.
    - The player uses `<AVAsset>` and `<AVPlayerItem>`.
    - `PHAsset+FileSize.currentVideoURLByteSize` uses `<Int64>`. A cancel or timeout (`complete(.success(nil))` becomes `cancel`) maps to `nil` at the call site: `do { try await …; return state.value } catch { return nil }`.
  - Delete the four old classes.
- **Edge cases:**
  - The single semantic unification is that `setRequestID` cancels when the state has *finished*, not only when it was cancelled. Cancelling an already-finished request ID is a no-op in PhotoKit. List it in the PR.
  - Timeouts and delivery options stay exactly as they are; WS-24 changes timeouts later.
- **Forward note (README §9, contract 8):** this step **creates** `iOSCleanup/Utilities/PhotoKitRequestState.swift`. WS-24.5 (chapter 05) later moves `PhotoImageRequestState` and its executors from `SharedHelpers.swift` into this existing file, and does not create it. `VideoFileSizeRequestState` no longer exists after this step. WS-24.5's cancellable file-size timeout therefore applies to the `PhotoKitRequestState<Int64>` used by `currentVideoURLByteSize`. WS-30, WS-59 and WS-62 reuse `PhotoKitRequestState<Value>`.

**WS-10.6 — `ExternalExportCoordinator`**
- **Why:** Seven export fixes (FILES-01/10/11/13/15/16/17) would otherwise have to be made twice.
- **Change:** new `Views/Files/ExternalExportCoordinator.swift`:
  ```swift
  enum ExternalExportOutcome {
      case busy                                                     // gate held elsewhere
      case finished(ExternalPhotoExportResult, verifiedAssetIDs: Set<String>)
      case cancelled(completedFileCount: Int, totalFileCount: Int)
      case failed(Error)
  }
  struct ExternalExportLifecycle {        // injectable for tests; .live uses UIApplication
      var setIdleTimerDisabled: @MainActor (Bool) -> Void
      var beginBackgroundTask: @MainActor (String, @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier
      var endBackgroundTask: @MainActor (UIBackgroundTaskIdentifier) -> Void
      static let live: ExternalExportLifecycle   // live: UIApplication.shared.isIdleTimerDisabled = …, etc.
  }
  @MainActor
  final class ExternalExportCoordinator: ObservableObject {
      typealias ExportOperation = @MainActor ([PHAsset], URL,
          @escaping @Sendable (ExternalPhotoExportProgress) -> Void) async throws -> ExternalPhotoExportResult
      let progressStore = ExternalPhotoExportProgressStore()
      @Published private(set) var isRunning = false
      init(export: @escaping ExportOperation = { try await ExternalPhotoExportService().export(assets: $0, to: $1, onProgress: $2) },
           gate: ExternalPhotoExportSessionGate = .shared,
           liveActivity: ExportLiveActivityController = ExportLiveActivityController(),
           lifecycle: ExternalExportLifecycle = .live)
      /// Owns the whole shared lifecycle: gate, yield, idle timer, background task
      /// (expiration marks the Live Activity paused), Live Activity start, update and end,
      /// progress store reset and update, error and cancel mapping, and the verified-ID set.
      func run(assets: [PHAsset], to directoryURL: URL, backgroundTaskName: String) async -> ExternalExportOutcome
  }
  ```
  - `verifiedAssetIDs` is exactly `Set(result.deletionEligibleAssetIDs)`, WS-05.7's hash-verified set. That is what `ExportAlbumView` uses once WS-05 lands (WS-05.7 already replaced the old `exportedAssetIDs ∪ alreadyExportedAssetIDs` union). Never widen it: unverified already-exported items and assets whose journal append failed stay out.
  - Both views hold `@StateObject private var exportCoordinator = ExternalExportCoordinator()`. They replace their `liveActivity`/`selectedExportLiveActivity` and progress-store `@State` with `exportCoordinator.progressStore`, and keep all messages, selection updates, delete offers, haptics and pre-checks. Divergences (b)–(g) stay per view, exactly as they are.
  - `FileResultsView` gets divergence (a) aligned: it uses `verifiedAssetIDs`, so already-on-drive videos stop showing as "unfinished". This is the one intentional user-visible change. List it, and every other difference, in the PR.
  - The cancel buttons still cancel the view-owned `Task` that awaits `run`.
- **Edge cases:**
  - The gate must be released on every path, including `busy`, which never acquired it.
  - Idle timer and background-task end happen in `defer`.
  - `ExportLiveActivityController` stays in `ExternalPhotoExportService.swift`; WS-05 owns that file.
  - WS-29 later replaces the live idle-timer closure with `IdleTimerCoordinator`. Keep the `UIApplication.shared.isIdleTimerDisabled` assignment inside `ExternalExportLifecycle.live` in this file, so that swap stays local. WS-29 uses `IdleTimerCoordinator.shared.acquire(reason: "export")` and `release(_:)` on every exit (README §9, contract 7). It may reshape `setIdleTimerDisabled` into acquire and release closures, and the lifecycle tests follow.

**WS-10.7 — Row parameter structs**
- **Change:** in `LargeVideoRowViews.swift`, add:
  ```swift
  struct LargeVideoRowState { let isQueuedForExport, isSelectingForExport, isSelectedForExport, isDeleting: Bool }
  struct LargeVideoRowActions { let play, toggleExportSelection, addToExport, delete, compress: () -> Void }
  ```
  - `FileRow` and `LargeVideoGridCard` take `file`, `purchaseManager`, `state` and `actions`.
  - Build the actions once per file, in a `FileResultsView` helper `rowActions(for:)`, used by both call sites.

**WS-10.8 — Bring `FileResultsView.swift` under ~600 lines**
- **Change:** move members into same-type extensions in new files:
  - `FileResultsView+Export.swift`: `selectedExportActionBar`, `continueToExportBar`, `addToExportAlbum…beginExternalExport`, and the coordinator call that replaces `exportSelectedVideos`.
  - `FileResultsView+Banners.swift`: `scanningBanner`, `completedScanBanner`, `exportGuidanceCard`.
  - Remove `private` only from the members those extensions need; keep everything else private.
- **Edge cases:** `DesignLintTests` scans all of `Views/` and must stay green.

### Tests
All run in the simulator.
- **The existing suite passes unchanged after every commit.** This includes `LargeVideoReviewOrganizer`, `LargeVideoExportSelection` and `FileDeletionErrorPolicy` tests, and `DesignLintTests`.
- **`iOSCleanupTests/PhotoKitRequestStateTests.swift`** (*new*). Use a recording canceller closure.
  - `testCancelBeforeInstallThrowsCancellation`: `install` returns false, the continuation throws `CancellationError`, and the canceller is not called (no ID yet).
  - `testCompleteAfterCancelIsIgnored`: `value` stays nil.
  - `testDoubleCompleteFirstWins`.
  - `testSetRequestIDAfterCancelCancelsThatID` and `testSetRequestIDAfterCompletionCancelsThatID`, which pins the unified semantics.
  - `testCancelAfterRequestIDCancelsOnce`: two `cancel` calls produce one canceller call with the right ID.
  - `testInstallAfterCompletionResumesImmediately`.
- **`iOSCleanupTests/ExternalExportCoordinatorTests.swift`** (*new*, `@MainActor`). Inject the export closure and a recording `ExternalExportLifecycle`.
  - `testBusyWhenGateHeld`: acquire `ExternalPhotoExportSessionGate.shared` in the test and release it in `addTeardownBlock`. Assert `.busy`, the export was not called, and the idle timer was untouched.
  - `testAlreadyExportedCountsAsVerified`: the result has `exportedAssetIDs ["a","c"]`, `alreadyExportedAssetIDs ["b","d"]` and `deletionEligibleAssetIDs ["a","b"]`. Assert `verifiedAssetIDs == ["a","b"]`: the hash-verified already-exported `b` counts, while `c` and `d` never do.
  - `testLifecycleRestoredOnSuccessFailureAndCancel`: three runs, where the export returns, throws, and throws `CancellationError`. Each time assert that the idle timer was set true then false, the background task was begun and ended once, `isRunning` is false, and the gate can be re-acquired.
  - `testProgressUpdatesReachStore`: the export calls `onProgress` twice. `await waitUntil { coordinator.progressStore.progress?.completedFileCount == 2 }`, then assert the store is reset after the run.
- **Simulator smoke:** WS-07's `scripts/sim-fixtures.sh` flow still reaches groups. Open Files and the Export Album screen and check the screenshots look unchanged.

### Acceptance criteria
- [ ] `wc -l iOSCleanup/Views/Files/*.swift` shows no file over about 600 lines.
- [ ] `grep -n "struct ExportAlbumView\|struct PhotoCategoryReviewView\|struct CompletionOverlay\|struct ExternalFolderPicker" iOSCleanup/Views/HomeView.swift` is empty.
- [ ] `grep -rn "RequestState: @unchecked Sendable" iOSCleanup` shows only `PhotoKitRequestState` and `SharedHelpers.swift`'s `PhotoImageRequestState`.
- [ ] `grep -rn "ExternalPhotoExportSessionGate.shared.acquire\|isIdleTimerDisabled\|beginBackgroundTask(withName: \"PhotoDuck" iOSCleanup/Views` matches only `ExternalExportCoordinator.swift`.
- [ ] The full suite passes after every commit. The new `PhotoKitRequestStateTests` and `ExternalExportCoordinatorTests` pass. There are no new warnings, and `scripts/build-release.sh` passes.
- [ ] The PR lists every export-path difference (a)–(g) and which view keeps which behavior, the `verifiedAssetIDs` alignment for videos, and the `setRequestID` unification.
- [ ] Simulator screenshots of Files (list and grid), the video player, Export Album and category review are unchanged from `main`.
- [ ] `CLAUDE.md` Navigation and architecture mention `Views/Export/`, `ExternalExportCoordinator` and `PhotoKitRequestState`.

### Device QA
Add to `docs/DEVICE_QA.md` under Export:
- **DQA-EXPORT-10 (added by WS-10):** on a device, export 3 large videos from Files ▸ Select and 5 items from the Export Album to a USB-C drive. Check that:
  - the Live Activity starts, updates and ends;
  - backgrounding for more than 30 s shows "paused", and returning resumes;
  - the screen does not auto-lock during the export;
  - re-exporting the same videos reports them as already on the drive and no longer leaves them selected.

### Pitfalls and out of scope
- **No visual changes.** Files, compression and Duck Mode await the design handoff (invariant 29). Moves must not alter modifiers, fonts or tokens.
- **Invariant 24:** the coordinator never deletes anything. Delete offers stay in `ExportAlbumView` and go through `DeletionManager`.
- **Access control:** extensions in other files can't see `private` members. Widen only what is needed, to `internal`; never `public`.
- **Commit order:** land after WS-04 (`SwipeModeView`, group detail) and WS-05 (the export service and result types). Rebase on WS-06's `onChange` migration. Every later workstream touching these views depends on this one, so land it before M1.
- **Out of scope:**
  - Export behavior fixes: FILES-01/10/11 (beyond the video alignment)/13/15/16/17. WS-05, WS-35 and WS-57 own them.
  - `PhotoImageRequestState` and all timeouts (WS-24, WS-52).
  - A delete offer on the video export path (WS-35).
  - HomeView size targets beyond these moves (WS-45, WS-50).
- Reconciliation (README §9, contract 8): WS-10.5 creates `Utilities/PhotoKitRequestState.swift`. WS-24.5 moves `PhotoImageRequestState` into it later, and WS-14 refers to it as WS-10's file.
- Reconciliation: `ExternalExportCoordinator.verifiedAssetIDs` is WS-05's `deletionEligibleAssetIDs`, not a union and not a conditional choice. The coordinator test now pins it.
- Reconciliation (README §9, contract 7): the `IdleTimerCoordinator` names that WS-29 swaps in are `acquire(reason:)` and `release(_:)`.

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| FILES-21 | confirmed | Every range matches, with small drift: `exportAlbum` is now at `HomeView.swift:1819-1978` because of the WIP. The rows take 11 parameters, but 5 are closures, not 8. There are exactly four *video* request-state copies with two distinct semantics; the unified type adopts the file-size variant's "cancel late ID when finished", which is a harmless superset. Moving only the listed types still leaves `FileResultsView.swift` at about 1,000 lines, so step 8 adds `FileResultsView+Export/+Banners` extensions to reach about 600. Coordinator divergences resolve to `ExportAlbumView`'s behavior, as the workstream notes require. The only user-visible effect is on the video path's already-exported handling. `PhotoCategoryReviewView`, `CompletionOverlay` and `CategoryPhotoThumbnail` moves are enablers added per the notes. |
| Reconciliation (WS-05) | — | "Current behavior" was verified before WS-05. Because WS-10 depends on WS-05, two divergences have already changed when WS-10 starts. (a) `ExportAlbumView` uses `result.deletionEligibleAssetIDs`, not the `exportedAssetIDs ∪ alreadyExportedAssetIDs` union. (b) Both views append `result.supplementaryNotes`, so the legacy-folder and "already on this drive" notes are no longer `ExportAlbumView`-only. The coordinator adopts (a) as `verifiedAssetIDs`; (c)–(g) stay per view as written. |
