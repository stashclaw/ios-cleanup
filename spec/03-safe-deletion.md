# Chapter 03 — Safe deletion: one honest API, protected automation, trustworthy previews

> **Milestone(s):** M1 · **Workstreams:** WS-11 – WS-14 · Read `spec/README.md` first: operating rules, invariants, build/test commands and the decision log apply to every workstream here.

## Chapter overview

Every photo PhotoDuck removes passes through `DeletionManager`. Today its documented safety net, the 10-second undo window, is dead code, yet five views still wire themselves to it. Tapping "Don't Allow" shows raw PhotoKit errors, a double tap produces two iOS prompts, and commits reuse stale snapshot `PHAsset`s that are never re-checked.

This chapter delivers four things:
- **WS-11** makes the gateway honest: one API per action, typed `.declined` results, a receipt, an in-flight guard, and re-resolution at commit time.
- **WS-12** makes the bulk flows lossless: Duck Mode never drops decisions silently, user "Keep" choices are remembered, and Auto-clean works in bounded batches.
- **WS-13** keeps favorites, undeletable photos and album-curated frames out of every automated plan.
- **WS-14** guarantees a real preview, or an explicit "unavailable" state, before anything can be deleted.

When the chapter is done, each action shows one iOS prompt followed by one receipt, and nothing silently undoes the user's own judgment.

**Key risk.** WS-11 is the largest cross-view PR in M1, and its commit pipeline decides which asset objects reach `PHAssetChangeRequest.deleteAssets`. Every rule therefore lives in a pure planner with table tests.

**Execution order:** WS-11, WS-12, WS-13, WS-14.
- WS-12 and WS-13 both edit `DeletionManager.init`, `PhotoDeletionGuardrails` and `PhotoGroup.swift`. Run them one after the other, never concurrently.
- WS-14 may start once WS-11 has merged. It must not run concurrently with WS-11 or WS-12, because all three edit `SwipeModeView.swift`.

---

## WS-11 — Deletion core: one honest deletion API

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M1 | L | WS-03, WS-04, WS-10 | yes | `ws/11-deletion-core` |

**Primary files:**
- Engines: `iOSCleanup/Engines/DeletionManager.swift`, `iOSCleanup/Engines/DeletionTypes.swift` (*new*), `iOSCleanup/Engines/DeletionCommitPlanner.swift` (*new*), `iOSCleanup/Engines/PhotoDeletionGuardrails.swift`, `iOSCleanup/Engines/VideoCompressionEngine.swift` (comment only).
- Components: `iOSCleanup/Views/Components/DeletionReceiptToast.swift` (*new*; replaces `UndoToast.swift`, which is deleted), `iOSCleanup/Views/Components/DeletionFailureCopy.swift` (*new*), `iOSCleanup/Views/Components/DuckToast.swift` (comment only).
- App and views: `iOSCleanup/iOSCleanupApp.swift`, `iOSCleanup/Views/PhotoDuckShellView.swift`, `iOSCleanup/Views/HomeView.swift`, `iOSCleanup/Views/Photos/PhotoResultsView.swift`, `iOSCleanup/Views/Photos/PhotoGroupDetailView.swift`, `iOSCleanup/Views/Photos/SwipeModeView.swift`, `iOSCleanup/Views/Photos/SwipeModeViewModel.swift`, `iOSCleanup/Views/Photos/PhotoCategoryReviewView.swift`, `iOSCleanup/Views/Export/ExportAlbumView.swift`, and `iOSCleanup/Views/Files/FileResultsView.swift` or wherever WS-10 put `deletePhotoLibraryFile`.
- Docs: `CLAUDE.md`, `../CLAUDE.md`, `README.md`.
- Tests: `iOSCleanupTests/DeletionManagerTests.swift`, `iOSCleanupTests/DeletionCommitPlannerTests.swift` (*new*), `iOSCleanupTests/DeletionLintTests.swift` (*new*), `iOSCleanupTests/SwipeModeViewModelTests.swift` (*new* if WS-06 did not create it), `iOSCleanupTests/FileScanEngineTests.swift`.
- Project: `iOSCleanup.xcodeproj/project.pbxproj`.

**Findings covered:**
- DEL-02 (P1, confirmed; merged: UI-04, BUILD-02, FSA-05, VALUE-05, DEL-03, FILES-24)
- DEL-10 (P2, confirmed; merged: UI-12)
- DEL-11 (P2, confirmed)
- DEL-06 (P1, confirmed; the batch-failure consequence is device-dependent and is checked first)

**Decisions applied:**
- **D-UNDO** (owner; if the owner has not answered, apply the default): retire the window. PhotoKit commits immediately after the guardrails and presents the iOS confirmation. A post-commit receipt toast follows, and Recently Deleted (30 days) is the recovery path. There is no app-level undo.
- **D-FAVORITES-USER:** `delete(assets:…)` is user-authored and may delete favorites. Automated plans (`keepBest…`) drop live favorites and hidden assets at commit time.
- **D-FREE-KEEPBEST / D-GATING:** unchanged. This PR adds and moves no paid gate.

### Goal

`DeletionManager` exposes exactly one API per action, and each returns `DeletionResult` (`.deleted(DeletionReceipt)` or `.declined`). Only real failures are thrown.

Before PhotoKit sees anything:
- Every commit is single-flight.
- IDs are re-resolved from PhotoKit.
- A group whose keeper vanished is skipped.
- Missing and undeletable assets are dropped.
- Automated plans also drop live favorites and hidden assets.
- Only freshly fetched objects reach the deleter.

After this PR:
- "Don't Allow" never shows an error on any surface.
- A successful delete shows one receipt: "Moved N (≈X) to Recently Deleted".
- Code, UI copy, `CLAUDE.md`, `../CLAUDE.md` and `README.md` all describe the same immediate-commit semantics.
- The dead undo machinery is gone, about 150 lines in `DeletionManager` plus the observers in five views.

### Current behavior (verified)

**The API always takes the immediate path.**
- `iOSCleanup/Engines/DeletionManager.swift:105-111`: both `keepBest(from:)` overloads forward to `keepBestImmediately`.
- `:146-148`: `delete(assets:)` forwards to `deleteImmediately`.
- Both paths call `performDelete` (`:366-381`), which hands the *caller's* `PHAsset` objects straight to `PHAssetChangeRequest.deleteAssets` inside `PHPhotoLibrary.performChanges`.

**The undo window is dead code.**
- `:280-364`: `private func scheduleDelete` has no callers (grep).
- It is the only writer of `toastVisible = true` (`:318`), `toastDeadline`, `commitTask` and `pendingAssets`.
- As a result `hasPendingDeletion` (`:99-101`, `commitTask != nil`) is always false.
- Unreachable: `undoLast` (`:182-196`), `beginUndoWindowLease`/`endUndoWindowLease` (`:216-231`), `commitPendingDeletionImmediately` (`:236-268`), `restoreAfterDeclinedDeletion` (`:272-276`) and `clearPendingDeletion` (`:383-393`).
- Dead published state: `:66-79` (`toastVisible`, `toastFreedBytes`, `toastID`, `toastDeadline`, `lastCommittedToastID`, `lastDeletionError`, `undoEventID`, `lastUndoneAssetIDs`, `lastFailedAssetIDs`, `toastFreedCount`) and `:81-89` (the pending state, `undoWindowSeconds`).
- `totalBytesFreed` and `totalItemsFreed` (`:75-76`) have no readers outside the manager (grep). Only `lifetimeBytesFreed` and `lifetimeItemsFreed` are shown (`HomeView.swift:599-603`).

**There is no in-flight protection.**
- The only "guards" compare against the always-empty `pendingAssets`: `keepBestImmediately` `:124-133` and `deleteImmediately` `:157-169`.
- `SwipeModeViewModel.commitDeletes` (`SwipeModeViewModel.swift:194-230`) clears `toDeleteAssets` only after the await.
- `PhotoCategoryReviewView` and the Export Album delete buttons have no local in-flight state. They rely only on `.disabled(deletionManager.hasPendingDeletion)` (`HomeView.swift:1242`, `:1755`, `:1780`; `SwipeModeView.swift:76`, `:336-337`), which is always false.

**Declines show up as raw errors.**
- `DeletionManager.isUserCancellation` (`:205-210`) treats `CancellationError` and `PHPhotosErrorDomain` code 3072 as a decline.
- Only `PhotoResultsView.autoCleanAll` (`PhotoResultsView.swift:222`) and Export Album (`HomeView.swift:1995`, `:2034`) call it.
- `FileResultsView.swift:7-16` duplicates it as `FileDeletionErrorPolicy`, tested at `FileScanEngineTests.swift:816-825`.
- Raw 3072 text reaches the user in five places:
  - `PhotoGroupDetailView.swift:231-235` (`keepBest`)
  - `:270-274` (`deleteSelected`); both of these catch only `CancellationError`, then show `error.localizedDescription`
  - `PhotoResultsView.swift:412-416` (row Keep Best)
  - `SwipeModeViewModel.swift:227-229`
  - `HomeView.swift:1287-1289` (`PhotoCategoryReviewView.deleteSelectedAssets`, shown as a "Couldn't Delete Photos" alert)

**The toast modifier and its observers are still wired.**
- `.deletionUndoToast()` (`UndoToast.swift:50-86`) is attached at:
  - `iOSCleanupApp.swift:23` (the root)
  - `PhotoDuckShellView.swift:276` (results sheet)
  - `:282` (Duck Mode cover)
  - `HomeView.swift:145` (HomeView's own results sheet). This is a separate presentation, not a duplicate of the root, so it stays.
- Dead observers:
  - `PhotoResultsView.swift:97` (`toastVisible` padding), `:167-176`, and `:264-277` (`restoreGroupsAffectedByUndo`)
  - `SwipeModeView.swift:56-62`, plus the comments at `:74-75`, `:264-265`, `:334-335`
  - `SwipeModeViewModel.swift:44-46` (`optimisticallyCommittedAssets`), `:224-226` (the comment "the global deletion toast is the authoritative undo path") and `:232-264` (`restoreUndoneAssets`)
  - `FileResultsView.swift:498-509` and `:1313-1326` (`restoreUndonePhotoLibraryFiles`)
  - `HomeView.swift:1548-1560`, `:2001-2010` (`restoreAlbumAfterFailedDeletion`) and `pendingDeletionAssetIDs` (`:1377`)

**Copy and docs promise an undo that does not exist.**
- `HomeView.swift:1608` "You'll have 10 seconds to undo."
- `:1993` "Deleting N items — undo is available for 10 seconds."
- `:2031` "Original deletion is waiting in the undo window."
- Comments at `:1935-1936`, `:1979-1980`, `FileResultsView.swift:1299-1301`, `VideoCompressionEngine.swift:472-476` and `DuckToast.swift:10`.
- Docs at `CLAUDE.md:39`, `CLAUDE.md:77`, `README.md:41-42` and `../CLAUDE.md:17`.

**Large-video deletion takes its own path.**
- `FileResultsView.swift:1297-1311` calls `deleteImmediately(assets: [asset])` and records `PHAsset.estimatedFileSize` (`PHAsset+FileSize.swift:665-675`), not the row's `LargeFile.byteSize`.
- The front cache behind that estimate is capped at 2,048 entries (`PHAsset+FileSize.swift:296`).

**Nothing is checked at commit time.**
- There is no `fetchAssets(withLocalIdentifiers:)`, no `canPerform(.delete)` and no keeper-existence check.
- Duck Mode captures `groups` once at init (`SwipeModeView.swift:11-14`).
- After a failure, `commitDeletes` keeps the stale assets in `toDeleteAssets`, so every retry sends them again.

**Locations after WS-10.** WS-10 moves `PhotoCategoryReviewView` to `Views/Photos/PhotoCategoryReviewView.swift`, `ExportAlbumView` to `Views/Export/ExportAlbumView.swift`, and may move `deletePhotoLibraryFile`/`FileDeletionErrorPolicy` into `Views/Files/LargeVideoReviewModel.swift`. Re-find each symbol with grep; the line numbers above are from the pre-WS-10 tree.

### Implementation plan

**WS-11.1 — Verify first and confirm the seams**
- **Why:** DEL-06's claim that "one stale asset fails the whole batch" depends on device behavior. The fix is safe either way, but the PR must record the fact.
- **Change:**
  1. Open the WS-09 baseline run (`docs/qa-runs/*.md`) and copy its DEL-06 observation into the PR description: did a batch containing an already-deleted asset fail as a whole? If the baseline has no answer, write "not measured". Either way, implement WS-11.3 unchanged: the keeper check and fresh objects are required in both cases.
  2. Confirm that WS-03 landed these seams in `iOSCleanup/Engines/PhotoLibraryDeleting.swift`, and use these names wherever this spec says `deleter`, `assetResolver` or `byteEstimator`:
     - `PhotoLibraryDeleting` / `SystemPhotoLibraryDeleter` (the `deleter`)
     - `PhotoAssetResolver` with its default `PhotoLibraryDefaults.resolveAssets` (the `assetResolver`), which fetches fresh `PHAsset`s by ID off the main actor
     - `PhotoAssetByteEstimator` with its default `PhotoLibraryDefaults.estimateBytes` (the `byteEstimator`)
  3. Make the resolver's result Sendable. Add `struct ResolvedPhotoAssets: @unchecked Sendable { let byID: [String: PHAsset] }` (an `@unchecked Sendable` wrapper around `[String: PHAsset]`) to `DeletionTypes.swift`, and change WS-03's typealias to `typealias PhotoAssetResolver = @Sendable ([String]) async -> ResolvedPhotoAssets`:
     - `PhotoLibraryDefaults.resolveAssets` wraps its dictionary inside the detached task: `ResolvedPhotoAssets(byID: byID)`.
     - WS-03's `makeManager` test helper passes `assetResolver: { _ in ResolvedPhotoAssets(byID: [:]) }`.
     - WS-59, WS-60 and WS-62 (chapter 13) reuse `ResolvedPhotoAssets`, so define it even if WS-03's dictionary return compiles without warnings.
     - If WS-03 did not add a resolver, add `PhotoLibraryDefaults.resolveAssets` with this signature yourself.
  4. Confirm that WS-04's `keepBest(from:deleting:)` exists.
  5. Check the D-UNDO line in the README status table. If the owner chose to restore the window, stop and report.
- **Edge cases:**
  - The resolver must not introduce new strict-concurrency warnings. Wrap the dictionary; do not mark `PHAsset` as `Sendable`.
  - Keep WS-03's `fetchAssets(withLocalIdentifiers:options: nil)` for now. WS-40 (chapter 08) switches it to `PhotoLibraryFetch.identifierOptions()` (`includeAllBurstAssets = true`), and its `PhotoFetchLintTests` fails on any `options: nil`. Without that switch, hidden burst frames would resolve as `.missing` and be skipped.

**WS-11.2 — Pure types and the commit planner**
- **Why:** the decision about which assets may be deleted right now must be pure and table-tested. The PhotoKit calls around it stay thin.
- **Change:** create `iOSCleanup/Engines/DeletionTypes.swift`:
  ```swift
  enum DeletionContext: String, Sendable, Equatable {
      case automatedPlan   // Keep Best, Keep Best subset, Auto-clean: classifier-authored
      case userSelection   // manual select, Duck Mode swipes, category, Export Album, large video
  }
  enum DeletionSkipReason: String, CaseIterable, Sendable, Codable {
      case missing        // no longer resolvable (deleted elsewhere, hidden, or outside Limited access)
      case undeletable    // canPerform(.delete) == false
      case keeperMissing  // the photo this item duplicates no longer resolves
      case favorite       // automatedPlan only, live isFavorite
      case hidden         // automatedPlan only, live isHidden
      // WS-13 adds: albumCurated
  }
  struct DeletionSkipSummary: Equatable, Sendable {
      private(set) var idsByReason: [DeletionSkipReason: Set<String>] = [:]
      private(set) var skippedGroupIDs: Set<UUID> = []
      var allIDs: Set<String> { idsByReason.values.reduce(into: []) { $0.formUnion($1) } }
      var count: Int { allIDs.count }
      var isEmpty: Bool { idsByReason.isEmpty }
      mutating func record(_ id: String, _ reason: DeletionSkipReason) { idsByReason[reason, default: []].insert(id) }
      mutating func recordSkippedGroup(_ id: UUID) { skippedGroupIDs.insert(id) }
  }
  struct DeletionReceipt: Identifiable, Equatable, Sendable {
      let id: UUID
      let assetIDs: Set<String>      // exactly what PhotoKit deleted
      let itemCount: Int
      let videoCount: Int
      let estimatedBytes: Int64
      let date: Date
      let context: DeletionContext
      let skipped: DeletionSkipSummary
  }
  enum DeletionResult: Equatable, Sendable { case deleted(DeletionReceipt), declined }
  struct DeletionCommitItem: Equatable, Sendable {
      let assetID: String
      let requiredKeeperID: String?  // must still resolve, else skip (.keeperMissing)
      let groupID: UUID?
  }
  struct ResolvedAssetState: Equatable, Sendable {
      let canDelete: Bool, isFavorite: Bool, isHidden: Bool
  }
  extension ResolvedAssetState {
      init(_ asset: PHAsset) { self.init(canDelete: asset.canPerform(.delete), isFavorite: asset.isFavorite, isHidden: asset.isHidden) }
  }
  ```
  Also in this file:
  - Add `case nothingLeftToDelete(DeletionSkipSummary)` to the existing `DeletionManagerError`. Its `errorDescription` is "These photos changed since the scan, so nothing was moved. Review them again."
  - Add an extension on `DeletionReceipt` with:
    - `summaryMessage`: "Moved \(itemCount.formatted()) (≈\(ByteCountFormatter.string(fromByteCount: estimatedBytes, countStyle: .file))) to Recently Deleted"
    - `skippedNote`: nil, or "\(n) skipped"
    - `accessibilitySummary`: "Moved 12 photos, about 48 MB, to Recently Deleted. You can recover them there for 30 days." Use "photo"/"photos" when `videoCount == 0`, "video"/"videos" when `videoCount == itemCount`, and "item"/"items" otherwise, pluralized correctly.

  Create `iOSCleanup/Engines/DeletionCommitPlanner.swift`:
  ```swift
  struct DeletionCommitPlan: Equatable, Sendable {
      let deleteIDs: [String]            // unique, in incoming order
      let skipped: DeletionSkipSummary
  }
  enum DeletionCommitPlanner {
      static func plan(items: [DeletionCommitItem],
                       resolved: [String: ResolvedAssetState],   // only IDs that still exist
                       context: DeletionContext) -> DeletionCommitPlan {
          var seen = Set<String>(), deleteIDs: [String] = [], skipped = DeletionSkipSummary()
          var groupsWithDeletion = Set<UUID>(), groupsSeen = Set<UUID>()
          for item in items where seen.insert(item.assetID).inserted {
              if let g = item.groupID { groupsSeen.insert(g) }
              guard let state = resolved[item.assetID] else { skipped.record(item.assetID, .missing); continue }
              if let keeper = item.requiredKeeperID, resolved[keeper] == nil { skipped.record(item.assetID, .keeperMissing); continue }
              guard state.canDelete else { skipped.record(item.assetID, .undeletable); continue }
              if context == .automatedPlan {
                  if state.isFavorite { skipped.record(item.assetID, .favorite); continue }
                  if state.isHidden { skipped.record(item.assetID, .hidden); continue }
              }
              deleteIDs.append(item.assetID)
              if let g = item.groupID { groupsWithDeletion.insert(g) }
          }
          for g in groupsSeen.subtracting(groupsWithDeletion) { skipped.recordSkippedGroup(g) }
          return DeletionCommitPlan(deleteIDs: deleteIDs, skipped: skipped)
      }
  }
  ```
- **Edge cases:**
  - Check `.missing` before `.keeperMissing`. A vanished item is reported as missing. WS-21's library-change reconcile removes it from results (its `confirmedDeletions` carries only `receipt.assetIDs`).
  - The planner never adds IDs; it only filters. The keeper can never enter `deleteIDs`, because keeper IDs are never items (validated in WS-11.3).
  - Keep the file free of UIKit/SwiftUI imports. `ResolvedAssetState.init(_ asset: PHAsset)` needs only `Photos`.

**WS-11.3 — Rewrite `DeletionManager` around one commit pipeline**
- **Why:** this removes DEL-02's dead state, DEL-10's raw declines, DEL-11's double commits and DEL-06's stale-object commits in one place.
- **Change (in order):**
  1. **Delete:**
     - `scheduleDelete`, `undoLast`, `dismissLastError`, `beginUndoWindowLease`, `endUndoWindowLease`, `commitPendingDeletionImmediately`, `restoreAfterDeclinedDeletion`, `clearPendingDeletion`, `hasPendingDeletion`, `keepBestImmediately`, `deleteImmediately`
     - every property listed under "The undo window is dead code", plus `totalBytesFreed`/`totalItemsFreed`
     - the `recordUndoRestore` call. Leave `PhotoFeedbackStore.recordUndoRestore` itself in place; it is tested in `PhotoFeedbackLearningTests`.
  2. **Add** `@Published private(set) var inFlightAssetIDs: Set<String> = []`, `var isDeleting: Bool { !inFlightAssetIDs.isEmpty }` and `@Published private(set) var lastReceipt: DeletionReceipt?`. Add no other published deletion state; WS-12 and WS-32 read `lastReceipt`. (WS-21 later adds a non-`@Published` `confirmedDeletions` subject next to it.)
  3. **Add** `case deletionAlreadyInProgress` to `PhotoDeletionGuardrailError`, with errorDescription "Another deletion is still finishing. Try again in a moment."
  4. **Public API.** The functions are not `@discardableResult`: every call site must handle `.declined`.
     ```swift
     func keepBest(from groups: [PhotoGroup]) async throws -> DeletionResult {
         try PhotoDeletionGuardrails.validate(groups: groups)                     // sync
         let items = groups.flatMap { g in g.deleteCandidateIDs.map {
             DeletionCommitItem(assetID: $0, requiredKeeperID: g.keeperAssetID, groupID: g.id) } }
         try claimInFlight(items)                                                 // sync, before any await
         defer { inFlightAssetIDs = [] }
         return try await commit(items, context: .automatedPlan, knownBytes: [:])
     }
     func keepBest(from group: PhotoGroup) async throws -> DeletionResult { try await keepBest(from: [group]) }
     // WS-04's subset API: keep its validation, then build items with the group's keeper and context .automatedPlan.
     func keepBest(from group: PhotoGroup, deleting subset: Set<String>) async throws -> DeletionResult
     func delete(assets: [PHAsset],
                 requiredKeeperIDs: [String: String] = [:],   // assetID → keeperID that must still exist
                 knownBytes: [String: Int64] = [:]) async throws -> DeletionResult {
         let ids = PhotoAssetIdentity.unique(assets).map(\.localIdentifier)
         guard !ids.isEmpty else { throw PhotoDeletionGuardrailError.emptyDeleteCandidateList }
         guard Set(requiredKeeperIDs.values).isDisjoint(with: ids) else {
             throw PhotoDeletionGuardrailError.crossGroupKeeperConflict }
         let items = ids.map { DeletionCommitItem(assetID: $0, requiredKeeperID: requiredKeeperIDs[$0], groupID: nil) }
         try claimInFlight(items); defer { inFlightAssetIDs = [] }
         return try await commit(items, context: .userSelection, knownBytes: knownBytes)
     }
     private func claimInFlight(_ items: [DeletionCommitItem]) throws {
         guard inFlightAssetIDs.isEmpty else { throw PhotoDeletionGuardrailError.deletionAlreadyInProgress }
         inFlightAssetIDs = Set(items.map(\.assetID))
     }
     ```
  5. **`private func commit(_:context:knownBytes:) async throws -> DeletionResult`** runs these steps:
     1. Resolve `itemIDs ∪ requiredKeeperIDs` through `assetResolver`, off the main actor.
     2. Map the result to `ResolvedAssetState` on the main actor.
     3. Call `DeletionCommitPlanner.plan`.
     4. If `deleteIDs` is empty, throw `DeletionManagerError.nothingLeftToDelete(plan.skipped)`.
     5. Build `assets` from the **resolved** objects in `deleteIDs` order.
     6. Compute `bytes = Σ (knownBytes[id] ?? byteEstimator(asset))` and `videoCount` from the resolved `mediaType`.
     7. Call `try await deleter.delete(assets)`. If it throws something where `Self.isUserCancellation(error)` is true, return `.declined` with no stats, no receipt and no haptic. Rethrow anything else unchanged.
     8. On success, in this order:
        - `recordConfirmedDeletion(bytes:itemCount:)`
        - build the receipt, with `id: UUID()` and `date: now()`; add an injectable `now: @escaping () -> Date = Date.init` to init
        - `lastReceipt = receipt`
        - `UIAccessibility.post(notification: .announcement, argument: receipt.accessibilitySummary)`
        - `DuckHaptics.success()`
        - return `.deleted(receipt)`
  6. Keep `static func isUserCancellation(_:)` and mark it `nonisolated`.
- **Edge cases:**
  - `claimInFlight` must run before the first `await` in each public method. That is what makes a double tap throw `.deletionAlreadyInProgress` rather than open a second prompt.
  - The single-flight rule is global: any second deletion is rejected while one is in flight, even with disjoint IDs. There must be exactly one iOS prompt at a time.
  - `defer { inFlightAssetIDs = [] }` must also clear the flag on a throw and on `.declined`.
  - `knownBytes` applies only to IDs that were actually deleted.
  - Stats and the receipt are recorded only after PhotoKit returns success (invariant 9).

**WS-11.4 — The receipt toast and friendly failure copy**
- **Why:** users need a truthful confirmation. Errors must never be raw `PHPhotosErrorDomain` text.
- **Change:**
  - Delete `iOSCleanup/Views/Components/UndoToast.swift`, and remove it from `project.pbxproj`.
  - Create `DeletionReceiptToast.swift`:
    ```swift
    private struct DeletionReceiptToastModifier: ViewModifier {
        @EnvironmentObject private var deletionManager: DeletionManager
        let bottomPadding: CGFloat
        @State private var visible: DeletionReceipt?
        func body(content: Content) -> some View {
            content
                .overlay(alignment: .bottom) {
                    if let receipt = visible {
                        DuckToast(style: .info, message: receipt.summaryMessage, trailingDetail: receipt.skippedNote)
                            .padding(.bottom, bottomPadding)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(receipt.accessibilitySummary)
                    }
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: visible?.id)
                .onChange(of: deletionManager.lastReceipt?.id) { _ in visible = deletionManager.lastReceipt }
                .task(id: visible?.id) {
                    guard visible != nil else { return }
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    if !Task.isCancelled { visible = nil }
                }
        }
    }
    extension View {
        func deletionReceiptToast(bottomPadding: CGFloat = 16) -> some View {
            modifier(DeletionReceiptToastModifier(bottomPadding: bottomPadding))
        }
    }
    ```
    The overlay does not change layout. A newly mounted modifier does not replay an old receipt, because it reacts only to `onChange`. There is no global error alert: errors surface where the action happened.
  - Replace `.deletionUndoToast()` at each site:
    - `iOSCleanupApp.swift:23` becomes `.deletionReceiptToast(bottomPadding: 72)`, to clear the tab bar, which floats on iOS 26.
    - `PhotoDuckShellView.swift:276` and `:282`, and `HomeView.swift:145`, become `.deletionReceiptToast()`.
  - Create `DeletionFailureCopy.swift` with `enum DeletionFailureCopy { static func message(for error: Error) -> String }`:
    - `PhotoDeletionGuardrailError` and `DeletionManagerError`: return their `errorDescription`.
    - An `NSError` in `PHPhotosErrorDomain`: "Photos couldn't delete these items. Nothing was removed. (Photos error \(code))".
    - Anything else: "Photos couldn't delete these items. Nothing was removed."
    - Callers never pass declines here, because declines are `.declined`.
  - In `DuckToast.swift:10`, change the comment to "destructive notices"; leave the API unchanged.
- **Edge cases:**
  - While a sheet is up, the root overlay renders underneath it. That is invisible, and the receipt remains visible if the sheet closes within 4 s.
  - The VoiceOver announcement is posted once by the manager, never by the modifiers, which may be mounted two at a time.

**WS-11.5 — Update every call site**
- **Why:** the new result type and the removed state must be handled consistently. Declines keep the user's selection; failures show friendly copy.
- **Change:** apply the table below. Replace every `deletionManager.hasPendingDeletion` with `deletionManager.isDeleting`. Remove every `onChange(of: deletionManager.undoEventID / lastDeletionError / lastCommittedToastID)` and every restore helper named in "Current behavior".

| Call site | On `.deleted(receipt)` | On `.declined` | On throw |
|---|---|---|---|
| `PhotoGroupDetailView.keepBest()`, WS-04's subset path, `deleteSelected()` | Record feedback with `deletedAssetIDs: Array(receipt.assetIDs)` (never the requested set); `keptAssetIDs` is unchanged. Then `onDeleteGroup?()`, `dismiss()`. For `deleteSelected()`, pass `requiredKeeperIDs` mapping every selected ID to the keeper the grid shows (after WS-04: the user-chosen keeper if swapped, else `group.keeperAssetID`; omit when nil). | `deleteError = nil`; keep `deleteSet`; stay | `deleteError = DeletionFailureCopy.message(for:)` |
| `PhotoResultsView` row Keep Best (`:385-421`) | Record feedback as above; hide the group | Nothing | `deletionError = DeletionFailureCopy.message(for:)` |
| `PhotoResultsView.autoCleanAll` (`:193-225`) | Hide only groups with at least one ID in `receipt.assetIDs`; call `recordAutoCleanFeedback` with those groups only | `deletionError = nil` | Same copy |
| `SwipeModeViewModel.commitDeletes` | See WS-11.5b | See WS-11.5b | See WS-11.5b |
| `PhotoCategoryReviewView.deleteSelectedAssets` | `selectedAssetIDs.subtract(receipt.assetIDs ∪ receipt.skipped.allIDs)` | Keep the selection | Alert with the copy |
| ExportAlbumView `deleteSelectedWithoutExporting` | `exportAlbum.remove(assetIDs: receipt.assetIDs)`; `selectedAssetIDs.subtract(receipt.assetIDs)`; status "Moved \(n) item(s) to Recently Deleted." | Nothing | `errorMessage = "PhotoDuck could not delete those items. " + copy` |
| ExportAlbumView `deleteExportedOriginals` | Remove `receipt.assetIDs` from the album and from `exportedAssetIDs`; status "Originals moved to Recently Deleted. Your verified copies are on the drive." | Keep `exportedAssetIDs` (WS-35 adds a persistent retry) | "The export is safe, but PhotoDuck could not delete the originals. " + copy |
| Large video `deletePhotoLibraryFile` | `hiddenFileIDs.insert`, `onAssetDeleted`. Call `delete(assets: [asset], knownBytes: file.isEstimated ? [:] : [asset.localIdentifier: file.byteSize])`, using the actual `LargeFile` field names | Remove from `pendingPhotoFileIDs` | `deletionError = copy` |

  - **WS-11.5b — `SwipeModeViewModel`:**
    - Delete `optimisticallyCommittedAssets` and `restoreUndoneAssets`, and fix the `:224-226` comment to read: "Committed swipes are in Recently Deleted; there is no in-app undo."
    - Add `@Published private(set) var isCommitting = false`, `private(set) var lastCommitReceipt: DeletionReceipt?` and `private var keeperAssetByGroupID: [UUID: PHAsset]`. Fill the dictionary in `buildQueue` from `group.bestAsset`, and expose `func keeperAsset(forGroupID id: UUID) -> PHAsset?`.
    - Add the outcome type and the new `commitDeletes`:
    ```swift
    enum DuckModeCommitOutcome: Equatable { case committed(DeletionReceipt), declined, failed, nothingToCommit }
    func commitDeletes(using deletionManager: DeletionManager) async -> DuckModeCommitOutcome {
        guard !isCommitting, !toDeleteAssets.isEmpty else { return .nothingToCommit }
        isCommitting = true; defer { isCommitting = false }
        let keepers = toDeleteAssets.reduce(into: [String: String]()) { map, asset in
            if let g = toDeleteGroupIDsByAssetID[asset.localIdentifier],
               let k = keeperAssetByGroupID[g]?.localIdentifier { map[asset.localIdentifier] = k } }
        do {
            switch try await deletionManager.delete(assets: toDeleteAssets, requiredKeeperIDs: keepers) {
            case .declined: deleteError = nil; return .declined
            case .deleted(let receipt):
                removePending(receipt.assetIDs.union(receipt.skipped.allIDs))   // also updates bytes and group map
                deletedCount += receipt.itemCount; deletedBytes += receipt.estimatedBytes
                lastCommitReceipt = receipt; swipeHistory.removeAll()
                recordCommittedFeedback(receipt.assetIDs)                        // existing recordSwipeDecision loop
                return .committed(receipt)
            }
        } catch DeletionManagerError.nothingLeftToDelete(let summary) {
            removePending(summary.allIDs); deleteError = DeletionFailureCopy.message(for: DeletionManagerError.nothingLeftToDelete(summary)); return .failed
        } catch { deleteError = DeletionFailureCopy.message(for: error); return .failed }
    }
    ```
    - `SwipeModeView` keeps its current dismissal behavior in this PR (WS-12 changes it). Its buttons use `.disabled(viewModel.isCommitting || deletionManager.isDeleting)`, and the completion button's title becomes "Moving…" while `isCommitting`.
- **Edge cases:**
  - Skipped IDs are removed from pending, because retrying them can never succeed. The receipt's `skippedNote` tells the user.
  - Feedback must use `receipt.assetIDs`, never the requested IDs (invariant 9).
  - `PhotoCategoryReviewView` has no keeper, so it passes no `requiredKeeperIDs`.

**WS-11.6 — Docs, comments and lint**
- **Why:** code, copy and both CLAUDE.md files must agree (exit criterion 1).
- **Change:**
  - `CLAUDE.md:39`: replace the `DeletionManager` row with: "The only normal photo-deletion gateway. One API per action (`keepBest(from:)`, `keepBest(from:deleting:)`, `delete(assets:requiredKeeperIDs:knownBytes:)`), each returning `DeletionResult` (`.deleted(DeletionReceipt)` / `.declined`). Order: static guardrails → single-flight claim → re-resolve IDs from PhotoKit (skip vanished keepers, missing or undeletable assets; automated plans also skip favorites and hidden assets) → `performChanges` → iOS system confirmation. There is no app-level undo window; Recently Deleted (30 days) is the recovery path. Lifetime stats and feedback are recorded only after PhotoKit confirms."
  - `CLAUDE.md:77`: keep the compression exemption, and replace "the coalesced undo window cannot represent that atomic swap" with "it is a user-confirmed save-then-replace (WS-43 makes it one PhotoKit transaction)".
  - `../CLAUDE.md:17`: replace with "Photo deletion goes through `DeletionManager`: guardrails, then the iOS system confirmation; Recently Deleted (30 days) is the undo. There is no app-level undo window." This file belongs to the outer repo. Edit it only if it exists and the owner allows outer-repo edits (README §3 rule 5); otherwise list it under Follow-ups.
  - `README.md:41-42`: replace the "Undo bar" bullet with "**Deletion**: every delete shows the iOS confirmation, then a receipt toast ('Moved N (≈X) to Recently Deleted'). Items stay in Recently Deleted for 30 days. There is no app-level undo window."
  - Fix the stale comments at `VideoCompressionEngine.swift:472-476`, `FileResultsView.swift:1299-1301` and `HomeView.swift:1935-1936, 1979-1980`, and in `SwipeModeView` (`:74-75`, `:264-265`, `:334-335`).
  - Export Album copy (DEL-03):
    - dialog message (`:1608`): "These move to Recently Deleted without being copied to a drive first. iOS will ask you to confirm. You can recover them from Photos › Albums › Recently Deleted for 30 days."
    - status strings: see the table in WS-11.5.
  - Add `DeletionLintTests` (see Tests).
- **Edge cases:** do not touch the unrelated "Undo" in the Review Later toast (`PhotoResultsView.swift:89-94`). The lint matches specific phrases and symbols only.

### Tests

All tests run in the simulator. Use WS-03's doubles: `TestPhotoAsset` (overridable `isFavorite`, `isHidden`, `canPerform(_:)` defaulting to true, and `mediaType`), `RecordingDeleter`, and an isolated `UserDefaults(suiteName:)` for `CleanupStatsStore`. Add `isHidden` to `TestPhotoAsset` if WS-03 did not. The resolver double returns a `ResolvedPhotoAssets` built from a list of *new* `TestPhotoAsset` instances filtered by the requested IDs.

**`iOSCleanupTests/DeletionCommitPlannerTests.swift` (new, pure):**

| Test | Asserts |
|---|---|
| `testAllResolvableItemsAreDeletedInOrder` | Plain items produce `deleteIDs` in input order |
| `testMissingItemIsSkippedAsMissing` | A missing item lands in `.missing`; the others are kept |
| `testMissingKeeperSkipsEveryItemOfItsGroup` | All items of that group land in `.keeperMissing`; the group ID is in `skippedGroupIDs` |
| `testUndeletableItemIsSkippedInBothContexts` | `canDelete: false` lands in `.undeletable` for `.automatedPlan` and for `.userSelection` |
| `testAutomatedPlanSkipsFavoriteAndHidden` | Favorite and hidden items land in `.favorite` and `.hidden` |
| `testUserSelectionKeepsFavoriteAndHidden` | Both are deleted under `.userSelection` |
| `testDuplicateItemsAreDeduplicated` | Duplicates are removed and the first occurrence's order wins |
| `testEverythingSkippedYieldsEmptyPlanWithFullSummary` | An all-skipped input gives an empty plan with a complete summary |

**`iOSCleanupTests/DeletionManagerTests.swift` (extend WS-03's):**

| Test | Asserts |
|---|---|
| `testKeepBestReturnsReceiptWithExactCandidateIDs` | `receipt.assetIDs == Set(deleteCandidateIDs)`; the keeper is never sent; stats +1 once; `lastReceipt == receipt` |
| `testDeclinedPromptReturnsDeclinedAndRecordsNothing` | The deleter throws 3072: result is `.declined`; stats unchanged; `lastReceipt` nil; `isDeleting` false |
| `testSwiftCancellationIsTreatedAsDeclined` | A `CancellationError` from the deleter gives `.declined` |
| `testGenericFailureIsRethrownAndRecordsNothing` | The error is rethrown; stats unchanged; `isDeleting` false |
| `testSecondDeleteWhileFirstInFlightThrowsDeletionAlreadyInProgress` | With `SuspendingDeleter` (below): the second call (disjoint IDs) throws `.deletionAlreadyInProgress`; after release the first returns `.deleted`; `deleter.callCount == 1`; stats recorded once |
| `testIsDeletingIsTrueOnlyDuringCommit` | `waitUntil { isDeleting }` (WS-06), then release; afterwards it is false |
| `testKeeperThatNoLongerResolvesSkipsGroup` | The resolver omits the keeper: no candidates reach the deleter; throws `.nothingLeftToDelete` containing the group ID |
| `testStaleCandidateIsDroppedAndRestDeleted` | The resolver omits one candidate: the others are deleted; `receipt.skipped` has it under `.missing` |
| `testDeleterReceivesFreshlyResolvedObjects` | `RecordingDeleter` records `ObjectIdentifier`s; they equal the resolver's instances, not the caller's |
| `testUndeletableCandidateIsDropped` | `canPerform(.delete) == false` is skipped as `.undeletable` |
| `testAutomatedPlanDropsLiveFavorite` | A group built while the candidate was not a favorite, resolved as a favorite, is skipped as `.favorite` |
| `testUserSelectionDeletesFavorite` | A favorite passed to `delete(assets:)` is deleted |
| `testKnownBytesOverrideEstimator` | `estimatedBytes` equals the known value for that ID and the estimator for the rest |
| `testRequiredKeeperMissingSkipsUserSelectionItem` | `delete(assets:requiredKeeperIDs:)` with the keeper unresolved gives `.keeperMissing` |
| `testRequiredKeeperInsideDeleteSetIsRejected` | Throws `.crossGroupKeeperConflict`; the deleter is not called |
| `testIsUserCancellationRecognisesPhotosCancelAndSwiftCancellation` | Moved from `FileScanEngineTests.swift:816-825`; delete that test together with `FileDeletionErrorPolicy` |
| `testFailureCopyIsFriendlyAndCarriesCode` | `DeletionFailureCopy.message(for: NSError(domain: PHPhotosErrorDomain, code: 3300))` contains "Nothing was removed" and "3300" but not "PHPhotosErrorDomain" |
| `testReceiptCopyPluralisesByMediaKind` | 1 photo, 3 photos, 2 videos, mixed items; `summaryMessage` format "Moved 3 (≈…) to Recently Deleted" |

`SuspendingDeleter` is a test actor conforming to `PhotoLibraryDeleting`. Its `delete` increments `callCount` and then awaits a stored `CheckedContinuation` until the test calls `release(throwing:)`. Wait on conditions with WS-06's `waitUntil` helper (chapter 02), never with fixed sleeps.

**`iOSCleanupTests/SwipeModeViewModelTests.swift` (new if absent):** construct the view model with WS-06's `transitionDelayNanoseconds: 0`.

| Test | Asserts |
|---|---|
| `testCommitDeletesDeclinedKeepsPendingAndShowsNoError` | `.declined`; `pendingDeleteCount` unchanged; `deleteError == nil` |
| `testCommitDeletesSuccessClearsPendingAndCountsReceipt` | `.committed`; `deletedCount == receipt.itemCount` |
| `testCommitDeletesRemovesSkippedIDsFromPending` | The resolver omits one asset: the rest are committed; pending is empty; `receipt.skipped` has 1 |
| `testCommitDeletesPassesGroupKeeperAsRequiredKeeper` | The resolver omits the keeper: `.failed`; `deleteError` is the "changed since the scan" copy; pending is emptied |
| `testConcurrentCommitDeletesCallsDeleterOnce` | Two concurrent calls: the second returns `.nothingToCommit`; `callCount == 1` |

**`iOSCleanupTests/DeletionLintTests.swift` (new).** Walk `iOSCleanup/` recursively from `#filePath` (copy DesignLintTests' pattern).

| Test | Asserts |
|---|---|
| `testNoUndoWindowCopyOrSymbolsRemain` | No `.swift` file contains `seconds to undo`, `undo is available`, `undo window`, `10-second`, `ten-second`, `scheduleDelete`, `undoLast(`, `undoEventID`, `hasPendingDeletion`, `lastUndoneAssetIDs`, `deletionUndoToast`, `keepBestImmediately`, `deleteImmediately` or `FileDeletionErrorPolicy` |
| `testDeleteAssetsCallOnlyInAllowedFiles` | `PHAssetChangeRequest.deleteAssets` appears only in `PhotoLibraryDeleting.swift` (WS-03) and in `VideoCompressionEngine.swift`. This is the same rule as WS-03's `TestIsolationLintTests.testPhotoKitDeleteIsCalledOnlyFromTheDeletionSeam`; if that test exists, do not add this row |
| `testRepositoryDocsDescribeImmediateDeletion` | `CLAUDE.md` and `README.md` contain none of the phrases above, and `CLAUDE.md` contains "Recently Deleted (30 days)" |

### Acceptance criteria
- [ ] `DeletionManager`'s public deletion API is exactly `keepBest(from: [PhotoGroup])`, `keepBest(from: PhotoGroup)`, `keepBest(from:deleting:)` and `delete(assets:requiredKeeperIDs:knownBytes:)`, all returning `DeletionResult`. `UndoToast.swift` is deleted and removed from the project.
- [ ] `DeletionLintTests` pass. `grep -rn "hasPendingDeletion\|undoEventID\|restoreUndone\|restoreGroupsAffectedByUndo\|restoreAlbumAfterFailedDeletion" iOSCleanup` is empty.
- [ ] Declining the iOS prompt returns `.declined` (tested). No surface shows an error for it: the 9 surfaces in the WS-11.5 table (device QA).
- [ ] A concurrent second delete throws `.deletionAlreadyInProgress`, and the deleter runs once (tested). Every commit control is disabled while `isDeleting`.
- [ ] A group whose keeper no longer resolves is skipped; stale candidates are dropped; the deleter receives only freshly resolved objects (tested).
- [ ] A successful delete publishes exactly one `lastReceipt` and advances lifetime stats exactly once (tested). The receipt toast appears in the top-most presentation layer (simulator check with WS-07 fixtures).
- [ ] `CLAUDE.md`, `README.md` and, if permitted, `../CLAUDE.md` describe immediate deletion with Recently Deleted as recovery. Export Album copy no longer promises an undo.
- [ ] The PR description records the WS-09 DEL-06 observation.
- [ ] The full suite is green, with zero warnings under strict concurrency.

### Device QA
Append to `docs/DEVICE_QA.md` under "Deletion (WS-11)":
1. **Decline.** On each surface, tap the delete action, then **Don't Allow** in the iOS prompt. Expect no error, no toast, and an unchanged selection. The surfaces: group detail Keep Best, detail Delete Selected, results-row Keep Best, Auto-clean, Duck Mode commit, Screenshots/Blurry delete, Export Album "Delete from Photos", Export & Delete, and large-video delete.
2. **Allow.** Expect exactly one toast "Moved N (≈X) to Recently Deleted" in the visible layer: results sheet, Duck Mode cover, or tab root. It disappears after about 4 s. Photos › Recently Deleted contains exactly those items.
3. **Double tap.** Double-tap each commit button quickly. Expect exactly one iOS prompt.
4. **Stale candidate.** Start Duck Mode and mark 5 photos for deletion. Delete one of them from another device on the same iCloud account (or from the Photos app via app switching) and wait for sync. Commit. Expect the iOS prompt to count 4, and the toast to say "1 skipped".
5. **Keeper gone.** Open a group detail. In Photos, delete that group's keeper. Return and tap Keep Best. Expect "These photos changed since the scan, so nothing was moved." and nothing deleted.
6. **Background during the prompt.** Tap Keep Best. While the iOS prompt is visible, press Home, then return. Record what PhotoKit does. The app must not show a stuck spinner, and `isDeleting` must reset: every button is enabled again.

### Pitfalls and out of scope
- **Invariant 4.** `PHAssetChangeRequest.deleteAssets` stays inside `DeletionManager`'s deleter. The only exemption is the compression replace (WS-43, chapter 09). The lint enforces this.
- **Invariant 9.** Stats, feedback and the receipt are recorded only after PhotoKit returns success, and only for `receipt.assetIDs`.
- **Do not** keep `keepBestImmediately`/`deleteImmediately` as aliases, and do not reintroduce any deferred commit.
- **Do not** add a global error alert. Errors belong to the surface that acted.
- **Out of scope:**
  - Freed-byte honesty and the 30-day ledger: WS-32 (chapter 07). It reads `DeletionReceipt`.
  - Tombstoning deleted IDs across surfaces: WS-21 (chapter 04). It adds a `confirmedDeletions` subject, sent in `commit` right after `lastReceipt = receipt` with `receipt.assetIDs`. IDs skipped as `.missing` leave results through its library-change reconcile.
  - Deferring the Export & Delete prompt until `.active`, and a persistent "Delete Originals": WS-35 (chapter 07).
  - `ExportAlbumStore.restore(assetIDs:)` becomes unused. Leave it for WS-35 to delete, because it lives in `ExternalPhotoExportService.swift`, which is WS-35's file.
  - The capped front cache behind `estimatedFileSize`: WS-54 (chapter 11).
  - Duck Mode exit policy and "Review again": WS-12.
  - Favorite protection at plan time: WS-13.
- **Reconciliation:** `ResolvedPhotoAssets` is always defined here and becomes the return type of WS-03's `PhotoAssetResolver`, because WS-59, WS-60 and WS-62 (chapter 13) consume it. WS-11.1 now names WS-03's actual seams (`PhotoLibraryDeleting.swift`, `PhotoLibraryDefaults.resolveAssets`/`estimateBytes`) instead of hedging on whether they exist.
- **Reconciliation:** once WS-40 (chapter 08) lands, `DeletionManager`'s identifier resolver (`PhotoLibraryDefaults.resolveAssets`) must fetch with `PhotoLibraryFetch.identifierOptions()`. WS-40's `PhotoFetchLintTests` forbids `options: nil` on every `PHAsset.fetchAssets` call, and without the switch hidden burst frames resolve as `.missing`.
- **Reconciliation:** the condition-wait helper in these tests is WS-06's `waitUntil` (chapter 02), not a WS-08 helper.
- **Reconciliation:** WS-60 (chapter 13) later adds `statsPolicy: DeletionStatsPolicy = .record` to `delete(assets:requiredKeeperIDs:knownBytes:)`. The change is additive: the receipt, `lastReceipt`, WS-21's `confirmedDeletions` and `DeletionLintTests` are unchanged, and the acceptance criterion's API list describes this PR only.
- **Reconciliation:** WS-21 publishes deletions through its own `confirmedDeletions` subject (only `receipt.assetIDs`), not by reading `lastReceipt`. The out-of-scope line and the WS-11.2 `.missing` note now say so.

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| DEL-02 | confirmed | `scheduleDelete` has no callers (`DeletionManager.swift:280`); every undo artifact is unreachable. Plan follows D-UNDO (Option B). The toast is driven by `lastReceipt`; there is no parallel `lastCommitSummary`. |
| UI-04 | confirmed | Same facts. Its `.deletionInFlight` error is named `.deletionAlreadyInProgress` per the workstream note. |
| BUILD-02 | confirmed | README `:41-42` and `CLAUDE.md:39/77` are also stale. Its "keep `lastUndoneAssetIDs` for declines" idea is dropped, because `.declined` is returned to the caller, so no global restore channel is needed. |
| FSA-05 | confirmed | Facts verified. Its preferred fix (restore the window, coalescing, re-arm on `.active`) is rejected per D-UNDO. Its fallback branch matches this plan. |
| VALUE-05 | confirmed | Facts verified. Its recommended option (restore the window for multi-item paths) is rejected per D-UNDO. The per-site `isUserCancellation` wrapping is replaced by `.declined` from the manager. |
| DEL-03 | confirmed | Strings at `HomeView.swift:1608/1993/2031`. Replaced with the reviewer's copy (the status strings use the receipt count). |
| FILES-24 | partially | The exemption is real (`FileResultsView.swift:1302`). The large-video path now uses `delete(assets:knownBytes:)`, so no exemption remains. The capped-cache estimate is real (`PHAsset+FileSize.swift:296`), but its cap change is deferred to WS-54; `knownBytes` fixes the freed-bytes figure here. |
| DEL-10 | confirmed | Five raw-error paths plus the duplicated `FileDeletionErrorPolicy`. Implemented as reviewed (`DeletionResult.declined`, friendly copy). |
| UI-12 | confirmed | Same facts. Its "rethrow CancellationError" approach is replaced by the typed `.declined`. |
| DEL-11 | confirmed | `hasPendingDeletion` is always false; there are no local in-flight flags. Plan: the claim happens synchronously before the first await. The guard is **global** single-flight rather than "overlapping IDs only", so there is exactly one iOS prompt at a time. `inFlightAssetIDs` is still published for per-row spinners. |
| DEL-06 | confirmed | No resolution, `canPerform` or keeper check at commit. Snapshot objects reach PhotoKit. Whether one stale asset fails the whole batch is device behavior (recorded from WS-09 in WS-11.1); the fix is identical either way. Differences from the reviewer: a pure planner; `.nothingLeftToDelete` thrown instead of an outcome struct; `requiredKeeperIDs` also covers Duck Mode and manual detail deletes (the reviewer's scenario (b)). |

---

## WS-12 — Bulk commit flows: Duck Mode lifecycle, remembered keeps, Auto-clean batching

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M1 | L | WS-11 | no | `ws/12-bulk-commit-flows` |

**Primary files:**
- Engines: `iOSCleanup/Engines/UserKeepDecisionStore.swift` (*new*), `iOSCleanup/Engines/UserKeepDecisionApplier.swift` (*new*), `iOSCleanup/Engines/AutoCleanPlanner.swift` (*new*), `iOSCleanup/Engines/PhotoDeletionGuardrails.swift`, `iOSCleanup/Engines/DeletionManager.swift`.
- Model: `iOSCleanup/Models/PhotoGroup.swift`.
- Views:
  - Home: `iOSCleanup/Views/HomeViewModel.swift` (minimal).
  - Photos:
    - `SwipeModeView.swift`, `SwipeModeViewModel.swift`
    - `DuckModeExitPolicy.swift` (*new*), `DuckKeeperChip.swift` (*new*), `FullscreenGroupCompareView.swift` (*new*, moved)
    - `AutoCleanConfirmationSheet.swift` (*new*, moved, with the progress overlay)
    - `PhotoResultsView.swift`, `PhotoGroupDetailView.swift`
  - Shell: `iOSCleanup/Views/PhotoDuckShellView.swift`.
- App: `iOSCleanup/iOSCleanupApp.swift`.
- Tests: `iOSCleanupTests/UserKeepDecisionStoreTests.swift` (*new*), `iOSCleanupTests/PhotoGroupUserKeepTests.swift` (*new*), `iOSCleanupTests/AutoCleanPlannerTests.swift` (*new*), `iOSCleanupTests/DuckModeExitPolicyTests.swift` (*new*), `iOSCleanupTests/SwipeModeViewModelTests.swift`, `iOSCleanupTests/DeletionManagerTests.swift`, `iOSCleanupTests/SimilarityPolicyTests.swift`.
- Project: `iOSCleanup.xcodeproj/project.pbxproj`.

**Findings covered:**
- DEL-08 (P1, confirmed; merged: UI-13, DEL-09)
- DEL-04 (P1, confirmed)
- DEL-12 (P2, confirmed; large-batch PhotoKit timing tuned on device)
- VALUE-17 (P2, confirmed; merged: UI-14)

**Decisions applied:**
- **D-UNDO:** Duck Mode and Auto-clean commit immediately. There are no restore hooks; the receipt toast is the confirmation.
- **D-BACKUP:** keep decisions live in `Application Support/PhotoDuck/user-keep-decisions.json`. That directory is excluded from backup at the directory level by WS-34 (chapter 07). Until WS-34 lands, this store also sets `isExcludedFromBackup` on its own file after every write.
- **D-FAVORITES-USER:** unchanged. Duck Mode swipes stay user-authored.
- **D-GATING:** unchanged. Duck Mode commits stay free; Auto-clean stays paid (the gate stays inline until WS-36).

### Goal

- **Duck Mode never loses review effort.**
  - Any exit with pending delete marks requires an explicit Commit or Discard.
  - A declined or failed commit never closes the screen.
  - "Review again" never re-queues photos already deleted.
- **User "Keep" choices persist.** A photo the user swiped Keep on, or unmarked in the detail grid before committing, is never proposed again by Keep Best, Auto-clean or Duck Mode until the user resets kept photos.
- **Auto-clean runs in bounded batches.** Each run commits at most 1,000 photos, never splits a group, excludes "Review Later" groups, and shows a blocking progress overlay.
- **Every Duck Mode card shows the photo being kept.**

### Current behavior (verified)

**Duck Mode exits** (`iOSCleanup/Views/Photos/SwipeModeView.swift`):
- `:34-42`: Done confirms only when `viewModel.hasPendingDeletes, !viewModel.isComplete`. On the completion screen it dismisses at once.
- `:357`: "Back to Library" calls `onDismiss()` directly (wired at `:20-24` to `dismiss()`).
- `:68-73`: the confirmation's "Move N" button runs `await viewModel.commitDeletes(...); dismiss()` whatever the outcome. After WS-11 the returned `DuckModeCommitOutcome` is still ignored.

**Duck Mode state** (`SwipeModeViewModel.swift`):
- `:137-151`: `resetQueue()` clears `toDeleteAssets` and `keptAssets`, then rebuilds from the init-time `allGroups` (`:35`, `:63-66`), including assets committed earlier in the session.
- `:106-118`: a Keep swipe only appends to the in-memory `keptAssets` and records a feedback event. `grep -rn "userKept\|protectedAssetIDs" iOSCleanup` is empty.
- `:10-20`: `QueueEntry.asset(PHAsset, groupID: UUID)` carries no keeper. `buildQueue` excludes keepers (`:300`). `DuckAssetCard` (`SwipeModeView.swift:416-500`) renders only the candidate.

**Group rebuilds keep stale plans** (`HomeViewModel.swift`):
- `:1859-1881` (reconcile) rebuilds each group with its old `recommendedAction` and the surviving `deleteCandidateIDs`, so a photo swiped Keep stays a delete candidate.
- The other `photoGroups` assignment sites are `:1726` (scan update, guarded by `contentSignature`, which includes `deleteCandidateIDs`, `:2566-2582`) and `:2193` (restore).

**`PhotoGroup.init` re-infers deletions** (`iOSCleanup/Models/PhotoGroup.swift:75-90`): when `deleteCandidateIDs` is empty for a high-confidence `nearDuplicate` group with a keeper and no blockers, init infers **every unprotected non-keeper**. Simply filtering out kept IDs would let init add them back.

**Auto-clean** (`PhotoResultsView.swift`):
- `:29-35`: `visibleGroups` appends deferred ("Review Later") groups at the end. `:48-52`: `autoCleanEligibleGroups` derives from them, so deferred groups are included.
- `:193-225`: `autoCleanAll` sends every eligible group in one commit. The only feedback is a toolbar `ProgressView` (`:117-118`).
- `AutoCleanConfirmationSheet` (`:459-540`) previews 30 of all the candidates.

**Other facts:**
- `FullscreenGroupCompareView`, `ZoomablePhotoCanvas` and `CompareThumbnail` are `private` in `PhotoGroupDetailView.swift:485-649`.
- The Similar tab's gear `Menu` (`PhotoDuckShellView.swift`, `SimilarPhotosDashboardView` toolbar, about `:236-262`) is the only settings-like menu in the photo flow. Duck Mode is presented from that view as `SwipeModeView(groups: viewModel.photoGroups)` (`:278-283`).

### Implementation plan

**WS-12.1 — `UserKeepDecisionStore`**
- **Why:** DEL-04. Keep decisions must survive relaunch and outrank later automation.
- **Change:** in the new file `iOSCleanup/Engines/UserKeepDecisionStore.swift`:
  ```swift
  @MainActor
  final class UserKeepDecisionStore: ObservableObject {
      static let shared = UserKeepDecisionStore()
      @Published private(set) var keptIDs: Set<String> = []
      private var decidedAt: [String: Date] = [:]
      private var isLoaded = false
      private let fileURL: URL                // default: Application Support/PhotoDuck/user-keep-decisions.json
      private let now: () -> Date
      init(fileURL: URL = UserKeepDecisionStore.defaultFileURL, now: @escaping () -> Date = Date.init)
      func ensureLoaded() async               // decodes off-main once; missing or corrupt file → empty set, never throws
      func loadedKeptIDs() async -> Set<String> { await ensureLoaded(); return keptIDs }
      func markKept<S: Sequence>(_ ids: S) where S.Element == String
      func unmarkKept<S: Sequence>(_ ids: S) where S.Element == String
      func reset()
      var count: Int { keptIDs.count }
  }
  ```
  - **File format:** `{"version":1,"decisions":{"<localIdentifier>":"<ISO-8601 date>"}}`, via a `Codable` struct.
  - **Writes:** every mutation schedules an **immediate** off-main atomic write through one serial writer (a private actor), and the newest snapshot wins. Do not debounce: a lost keep could let Auto-clean delete a photo the user kept. Create the directory if needed. Write with `.atomic` and `.completeFileProtectionUntilFirstUserAuthentication`, then set `URLResourceValues.isExcludedFromBackup = true` on the file.
  - **Injection:**
    - `iOSCleanupApp` injects `UserKeepDecisionStore.shared` as an `@EnvironmentObject`, and also passes it explicitly wherever `deletionManager` is passed explicitly (the sheets in `PhotoDuckShellView` and `HomeView`).
    - Add `keepDecisions: UserKeepDecisionStore` to WS-07's `HomeViewModelDependencies` as a field with the production default `.shared` (WS-07's grow-with-defaults pattern). Tests pass a store on a temporary file.
- **Edge cases:**
  - Mutations made before loading completes are applied on top of the loaded set: merge, never overwrite.
  - IDs of photos deleted later stay in the file, which is harmless and bounded by the number of keeps. WS-48's local-data clear calls `reset()`.

**WS-12.2 — Apply keeps to plans, and guard them**
- **Why:** DEL-04. Automation must never propose a kept photo, and naive filtering is re-inferred by `PhotoGroup.init`.
- **Change:**
  1. Add to `iOSCleanup/Models/PhotoGroup.swift`:
     ```swift
     extension PhotoGroup {
         /// Removes user-kept IDs from the delete plan. Kept candidates are marked protected so
         /// PhotoGroup.init can never re-infer them; an emptied plan becomes reviewManually.
         func applyingUserKeptIDs(_ kept: Set<String>) -> PhotoGroup {
             let keptCandidates = Set(deleteCandidateIDs).intersection(kept)
             guard !keptCandidates.isEmpty else { return self }
             let remaining = deleteCandidateIDs.filter { !kept.contains($0) }
             let protectedCandidates = candidates.map {
                 keptCandidates.contains($0.photoId) ? $0.markedProtected() : $0 }  // new SimilarPhotoCandidate helper
             return PhotoGroup(id: id, assets: assets, similarity: similarity, reason: reason,
                 groupType: groupType, groupConfidence: groupConfidence, reviewState: reviewState,
                 recommendedAction: remaining.isEmpty ? .reviewManually : recommendedAction,
                 keeperAssetID: keeperAssetID, deleteCandidateIDs: remaining, bestShotPhotoId: bestShotPhotoId,
                 groupReasonsSummary: (groupReasonsSummary + ["You chose to keep some of these photos"]).uniquePreservingOrder(),
                 blockerFlags: blockerFlags, scoreBreakdown: scoreBreakdown,
                 preferenceQueuePriority: preferenceQueuePriority,
                 preferenceAdjustmentReasons: preferenceAdjustmentReasons,
                 captureDateRange: captureDateRange,
                 candidates: protectedCandidates.isEmpty ? Self.protectedPlaceholderCandidates(assets, keeperAssetID, keptCandidates) : protectedCandidates,
                 reclaimableBytes: nil)
         }
     }
     ```
     - `markedProtected()` returns a copy with `isProtected: true`, `isSelectedForTrash: false` and `selectionState: .protected`.
     - When `candidates` is empty (only groups built in tests), build minimal candidates for every asset: the keeper gets `.keep`, and the kept IDs are `isProtected`.
  2. Add `iOSCleanup/Engines/UserKeepDecisionApplier.swift`: `enum UserKeepDecisionApplier { static func apply(_ kept: Set<String>, to groups: [PhotoGroup]) -> [PhotoGroup] }`. It is a pure map that returns the same array when `kept` is empty.
  3. `PhotoDeletionGuardrails`:
     - Add `case userKeptAssetInDeleteCandidates`, with errorDescription "You chose to keep some of these photos. Review this group again."
     - Add a defaulted parameter to `validate(group:keptIDs: Set<String> = [])`, `validate(groups:keptIDs:)` and `compatibleAutoCleanGroups(from:keptIDs:)`. Throw when `!keptIDs.isDisjoint(with: group.deleteCandidateIDs)`, after the existing checks.
  4. `DeletionManager`:
     - Add the init parameter `keptIDsProvider: @escaping @MainActor () async -> Set<String> = { [] }`. `iOSCleanupApp` passes `{ await UserKeepDecisionStore.shared.loadedKeptIDs() }`.
     - In both `keepBest` paths, call it **after** `claimInFlight`, then run `PhotoDeletionGuardrails.validate(groups:keptIDs:)` again before `commit`. The claim must stay the first thing each method does, before any await.
- **Edge cases:**
  - The guardrail throws only for automated plans. `delete(assets:)` (user-authored) never checks kept IDs. A user may later delete a photo they once kept, for example by selecting it manually.
  - `compatibleAutoCleanGroups` skips such groups instead of failing the batch.

**WS-12.3 — Wire keeps into HomeViewModel, group detail and a reset control**
- **Why:** DEL-04. Every surface must see the same filtered plans.
- **Change (keep the HomeViewModel diff minimal; WS-16 moves it into `PhotoResultsStore`):**
  1. Add `private func applyingUserKeeps(_ groups: [PhotoGroup]) -> [PhotoGroup] { UserKeepDecisionApplier.apply(dependencies.keepDecisions.keptIDs, to: groups) }`.
  2. Apply it at the three assignment sites:
     - `:1726`: build `nextGroups` from `applyingUserKeeps(unaffectedGroups + update.groups)` before the signature comparison.
     - `:1859`: wrap the `compactMap` result.
     - `:2193`: call `await dependencies.keepDecisions.ensureLoaded()` before `photoGroups = applyingUserKeeps(restoredGroups)`.
  3. In `init`, subscribe: `keepDecisions.$keptIDs.dropFirst().removeDuplicates().sink { [weak self] kept in self?.reapplyUserKeeps(kept) }`. It sets `photoGroups = UserKeepDecisionApplier.apply(kept, to: photoGroups)` and `reclaimableBytesFoundSoFar = photoGroups.totalReclaimableBytes`, and does nothing else.
  4. **Group detail:** after a `.deleted(receipt)` from WS-04's subset path or from `deleteSelected()`, call `keepStore.markKept(Set(group.deleteCandidateIDs).subtracting(receipt.assetIDs).subtracting(receipt.skipped.allIDs))`. These are the recommended candidates the user explicitly unmarked. A plain Keep Best marks nothing.
  5. **Temporary reset control** (WS-48 moves it): in the gear `Menu` that holds "Scan Again" (`PhotoDuckShellView.swift`, the `gearshape.fill` toolbar menu of `SimilarPhotosDashboardView`, about `:234-262`), add "Reset Kept Photos (\(n))" directly below "Scan Again". Disable it when `n == 0`. It opens a confirmation with the title "Reset kept photos?" and the message "PhotoDuck may suggest these \(n) photos for cleanup again after your next scan." The destructive "Reset" button calls `keepDecisions.reset()`.
- **Edge cases:**
  - Restore awaits `ensureLoaded()`, so any UI built from `photoGroups` (including Duck Mode) sees the loaded kept set.
  - After a reset, plans are not restored until the next scan re-evaluates those clusters. Kept candidates stay `isProtected` in the snapshot. The confirmation copy says so, and that is intended.

**WS-12.4 — Duck Mode lifecycle**
- **Why:**
  - DEL-08/UI-13: silent discards, and dismissal after a decline.
  - DEL-09: "Review again" re-queues deleted photos.
  - DEL-04: keeps must persist, and the queue must skip them.
- **Change:**
  1. Add `iOSCleanup/Views/Photos/DuckModeExitPolicy.swift`:
     ```swift
     enum DuckModeExitPolicy {
         enum ExitAction: Equatable { case dismiss, confirm }
         static func exitAction(hasPendingDeletes: Bool) -> ExitAction { hasPendingDeletes ? .confirm : .dismiss }
         static func shouldDismiss(after outcome: DuckModeCommitOutcome) -> Bool {
             if case .committed = outcome { return true } else { return false } }
         static func canReviewAgain(hasPendingDeletes: Bool, isCommitting: Bool, totalReviewableCount: Int) -> Bool {
             !hasPendingDeletes && !isCommitting && totalReviewableCount > 0 }
     }
     ```
  2. `SwipeModeView`:
     - **Done** switches on `exitAction(hasPendingDeletes:)` regardless of `isComplete`, and is `.disabled(viewModel.isCommitting)`.
     - `DuckModeCompletion`'s `onDismiss` becomes `onRequestExit`, which calls the same function as Done. "Back to Library" never dismisses directly.
     - The dialog's "Move N" button becomes `Task { let o = await viewModel.commitDeletes(using: deletionManager); if DuckModeExitPolicy.shouldDismiss(after: o) { dismiss() } }`.
     - On `.declined` the view stays, and the dialog closes by itself. On `.failed` the view stays and shows `viewModel.deleteError`.
     - "Discard Decisions" still dismisses.
     - Show "Review again" only when `canReviewAgain(...)`. With pending deletes, the completion screen offers only "Move to Recently Deleted" and the exit (which confirms).
  3. `SwipeModeViewModel`:
     - The new initializer is `init(groups: [PhotoGroup], keepStore: UserKeepDecisionStore, transitionDelayNanoseconds: UInt64 = 250_000_000)`, keeping WS-06's parameter and default. `SwipeModeView(groups:keepStore:)` passes the store from the shell's environment object.
     - Add `private var committedAssetIDs = Set<String>()` and `private var sessionKeptIDs = Set<String>()`.
     - Each `swipeHistory` entry gains `wasKeptBefore: Bool`.
     - **Keep swipe:** `wasKeptBefore = keepStore.keptIDs.contains(id)`, then `keepStore.markKept([id])` and `sessionKeptIDs.insert(id)`.
     - **Delete swipe:** record `wasKeptBefore`. If it is true, call `keepStore.unmarkKept([id])`: the latest decision wins.
     - **`undoLastSwipe`:** for a keep with `!wasKeptBefore`, call `unmarkKept`. For a delete with `wasKeptBefore`, call `markKept`.
     - **`commitDeletes`**, on `.committed(receipt)`: `committedAssetIDs.formUnion(receipt.assetIDs ∪ receipt.skipped.allIDs)`.
     - **`buildQueue(from:)`** skips `committedAssetIDs` and `keepStore.keptIDs.subtracting(sessionKeptIDs)`. Its existing keeper exclusion stays. When the initializer runs, `sessionKeptIDs` is empty, so every previously kept ID is skipped.
     - **`resetQueue()`** is a no-op while `hasPendingDeletes || isCommitting`. This is a safeguard; the button is hidden then anyway. Otherwise it keeps its current resets, rebuilds, and does **not** clear `committedAssetIDs` or `sessionKeptIDs`.
- **Edge cases:**
  - "Discard Decisions" discards only the delete marks. Keep decisions made in the session stay remembered. DECISION (owner may override): keep swipes are persisted the moment they are made, because the dialog's own copy promises "discard the marks and keep the photos".
  - WS-51 later adds `upcomingAssets(limit:)`. All queue access stays inside `SwipeModeViewModel`, and `SwipeModeView` must not index `queue` directly.

**WS-12.5 — Keeper chip and compare view (VALUE-17)**
- **Why:** users cannot judge a duplicate without seeing the photo that will be kept.
- **Change:**
  1. Pure move, in its own commit: move `FullscreenGroupCompareView`, `ZoomablePhotoCanvas` and `CompareThumbnail` from `PhotoGroupDetailView.swift:485-649` to the new `iOSCleanup/Views/Photos/FullscreenGroupCompareView.swift` as internal types. Skip this step if WS-14 already did it.
  2. Add `iOSCleanup/Views/Photos/DuckKeeperChip.swift`:
     - The view is `DuckKeeperChip(keeper: PHAsset, onTap: () -> Void)`.
     - It shows a 64 pt rounded thumbnail with a white 2 pt stroke. Beneath it sits the existing keeper badge style from `PhotoGroupAssetCell`: a `Color.success` capsule with `star.fill` and the text "Keeping". Use existing tokens (`.duckMicro`, `.duckLabel`, `DuckRadius.s`).
     - It loads through `PhotoImageRepository.shared.image(… .thumbnail, allowNetworkAccess: false)`. On nil it shows the `photo` SF Symbol, never a spinner. WS-14 converts it to `PhotoThumbnailView`.
     - Accessibility: label "Kept photo", hint "Opens a side-by-side comparison".
  3. In `SwipeModeView.cardStack`, overlay the chip at `.bottomTrailing` of `DuckAssetCard`, with padding 18 so it clears the date/size text, which is leading-aligned. Get the keeper from `viewModel.keeperAsset(forGroupID:)`, which WS-11 added. Tapping it presents `FullscreenGroupCompareView(assets: [candidate, keeper], initialAssetID: candidate.localIdentifier, keeperAssetID: keeper.localIdentifier)` as a `fullScreenCover`.
- **Edge cases:**
  - When the keeper can't be found in the snapshot, show no chip. The commit-time `requiredKeeperIDs` check still protects the user.
  - This adds no other visual change to Duck Mode (invariant 29).

**WS-12.6 — Auto-clean batching (DEL-12)**
- **Why:** a 50k library can produce thousands of candidates in one `performChanges`, with no progress shown and all-or-nothing failure.
- **Change:**
  1. Add `iOSCleanup/Engines/AutoCleanPlanner.swift`:
     ```swift
     struct AutoCleanBatchPlan: Equatable, Sendable {
         let groupIDs: [UUID]; let assetCount: Int
         let remainingGroupCount: Int; let remainingAssetCount: Int; let deferredGroupCount: Int
     }
     enum AutoCleanPlanner {
         /// Tuning constant; revisit with the device QA timing below.
         static let maxAssetsPerRun = 1_000
         /// Contiguous prefix in input order; never splits a group; a single oversized first group runs alone.
         static func plan(candidateCounts: [(groupID: UUID, count: Int)], deferred: Set<UUID>,
                          maxAssets: Int = maxAssetsPerRun) -> AutoCleanBatchPlan
     }
     ```
     - Groups that are deferred or have a count of 0 are excluded and counted in `deferredGroupCount`, if deferred.
     - Iterate in order. If the batch is empty and `count > maxAssets`, take that group alone and stop. Otherwise take the group if it fits, and stop at the first group that does not.
     - Everything eligible but not taken counts as remaining.
  2. `PhotoResultsView`:
     - `autoCleanEligibleGroups` still comes from `compatibleAutoCleanGroups(from:keptIDs:)` over `filteredGroups.filter(\.isAutoCleanEligible)`, with `keptIDs` from the environment store. Keep this filter in that one property: WS-40 (chapter 08) swaps it to `isAutoCleanAllEligible`.
     - The toolbar action calls the planner with `deferred: Set(deferredGroupIDs)` and stores the batch's groups in `pendingAutoCleanGroups`.
     - While `isAutoCleaningAll`, add `.overlay { AutoCleanProgressOverlay(count:) }` and `.interactiveDismissDisabled(isAutoCleaningAll)`.
  3. Move `AutoCleanConfirmationSheet` and `AutoCleanDeleteThumbnail` to `iOSCleanup/Views/Photos/AutoCleanConfirmationSheet.swift`, and add `AutoCleanProgressOverlay` there.
     - The sheet takes the batch plan and shows "Cleaning \(assetCount) of \(assetCount + remainingAssetCount) now. Run Auto-clean again for the rest." whenever `remainingAssetCount > 0`.
     - It shows "\(deferredGroupCount) groups you marked Review Later are not included." whenever `deferredGroupCount > 0`.
     - The overlay is a dimmed full-screen layer holding a `DuckCard` with a `ProgressView` and the text "Moving \(count) photos to Recently Deleted… Keep PhotoDuck open."
     - The sheet's existing copy is unchanged.
- **Edge cases:**
  - Each run is one `keepBest(from:)` call, so there is one iOS prompt per run.
  - After `.deleted`, only groups whose candidates appear in `receipt.assetIDs` are hidden (WS-11.5), so skipped groups remain for the next run.
  - A 1-photo cap would stall on a 2-photo group. The oversized-first-group rule prevents that.

### Tests

Simulator for all of them. Use WS-03's `TestPhotoAsset`, WS-06's `transitionDelayNanoseconds: 0`, and temporary directories from WS-03's temp-store helper.

- **`UserKeepDecisionStoreTests` (new, `@MainActor`):**
  - `testMarkUnmarkResetRoundTripAcrossInstances`: write, create a new store on the same file, then `ensureLoaded`; the sets are equal.
  - `testCorruptFileLoadsEmptyWithoutThrowing`
  - `testMutationBeforeLoadIsMergedWithLoadedSet`
  - `testFileIsExcludedFromBackup`: after a write, `resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true`.
  - Wait on the async write with WS-06's `waitUntil` helper (chapter 02), or use the store's `flushForTesting() async` (DEBUG), which awaits the writer.
- **`PhotoGroupUserKeepTests` (new):**
  - `testApplyingKeptIDsRemovesThemFromPlan`
  - `testApplyingAllCandidatesDowngradesToReviewManuallyWithoutReinference`: a high-confidence `nearDuplicate` [K, A, B]; kept {A, B} gives `.reviewManually`, empty `deleteCandidateIDs`, `isAutoCleanEligible == false`, and A and B have `isProtected`.
  - `testApplyingEmptyOrDisjointSetReturnsIdenticalGroup`: same `id`, same plan.
  - `testKeptCandidateProtectionSurvivesRebuildThroughInit`: rebuild the result through `PhotoGroup(... deleteCandidateIDs: [])`; the kept IDs are still not inferred.
  - `testApplierMapsEveryGroup`
- **`SimilarityPolicyTests` (extend):**
  - `testGuardrailRejectsUserKeptCandidate`: `validate(group:keptIDs:)` throws `.userKeptAssetInDeleteCandidates`.
  - `testCompatibleAutoCleanGroupsSkipsGroupsWithKeptCandidates`
- **`DeletionManagerTests` (extend):**
  - `testKeepBestRejectsGroupContainingKeptIDAndDeleterNotCalled`: `keptIDsProvider` returns the candidate ID.
  - `testUserSelectionIgnoresKeptIDs`
- **`DuckModeExitPolicyTests` (new):**
  - `testExitRequiresConfirmationWheneverDeletesArePendingRegardlessOfCompletion`
  - `testOnlyCommittedOutcomeDismisses`: `.declined`, `.failed` and `.nothingToCommit` give false.
  - `testReviewAgainUnavailableWithPendingDeletesOrCommitting`
- **`SwipeModeViewModelTests` (extend):**
  - `testKeepSwipePersistsAndUndoUnmarks`
  - `testDeleteSwipeOnPreviouslyKeptUnmarksAndUndoRestores`
  - `testQueueSkipsPersistedKeptIDs`
  - `testResetQueueExcludesCommittedIDs`: commit 2, then `resetQueue`; neither is queued and `totalReviewableCount` dropped by 2.
  - `testResetQueueReincludesSessionKeeps`
  - `testResetQueueIsNoOpWithPendingDeletes`
  - `testDeclinedCommitKeepsPendingForDialogToStay`
  - `testKeeperLookupMatchesGroupKeeperAndKeepersNeverQueued`
- **`AutoCleanPlannerTests` (new, pure, UUID/count inputs):**
  - `testBatchNeverExceedsCapUnlessSingleOversizedGroup`
  - `testGroupsAreNeverSplit`
  - `testStopsAtFirstGroupThatDoesNotFit`
  - `testDeferredGroupsExcludedAndCounted`
  - `testRemainingCountsAreExact`
  - `testEmptyInputYieldsEmptyPlan`
  - `testZeroCountGroupsIgnored`

### Acceptance criteria
- [ ] Duck Mode has no exit that discards pending delete marks without a confirmation (tests plus Device QA 1-3). A declined or failed commit leaves the screen open with the marks intact.
- [ ] "Review again" never shows a photo committed in this session, and is unavailable while marks are pending (tests).
- [ ] A photo the user swiped Keep, or unmarked in the detail grid before committing, never appears again in Duck Mode, Keep Best or Auto-clean after relaunch, until "Reset Kept Photos" (tests plus Device QA 4). The guardrail rejects any automated plan containing a kept ID.
- [ ] `user-keep-decisions.json` is written atomically under Application Support/PhotoDuck and excluded from backup (test).
- [ ] Each Auto-clean run commits at most `AutoCleanPlanner.maxAssetsPerRun` photos. Runs never split a group, exclude deferred groups, and show the blocking overlay (planner tests plus Device QA 6).
- [ ] Every Duck Mode card that has a resolvable keeper shows the keeper chip, and tapping it opens the two-up compare view.
- [ ] `CLAUDE.md` is updated:
  - the `SwipeModeViewModel` row mentions remembered keeps and the exit policy;
  - a "User keep decisions" line under Key constraints says automated plans exclude kept IDs.
- [ ] The full suite is green, with zero warnings.

### Device QA
Append to `docs/DEVICE_QA.md` under "Bulk commit flows (WS-12)":
1. Swipe to the completion screen with at least 3 marked and tap **Back to Library**. Expect the confirmation, and Keep Reviewing returns to the screen. Repeat with **Done**.
2. In the confirmation, tap **Move N**, then **Don't Allow** in the iOS prompt. Expect Duck Mode to stay open with the same N marked.
3. Commit, then tap **Review again**. Expect no deleted photo to reappear (no spinner "ghost" cards).
4. In a group [K, A, B], swipe A Delete and B Keep, then commit. Force-quit and relaunch. Expect the group to be review-only (or B protected) in detail and the row. Auto-clean does not list B, and Duck Mode does not show B. **Reset Kept Photos** shows count 1.
5. The keeper chip is visible on each card. Tapping it shows the candidate and the keeper side by side.
6. On a library with more than 1,000 Auto-clean candidates, check that:
   - the sheet says "Cleaning 1,000 of N";
   - the iOS prompt says 1,000;
   - the overlay blocks interaction until done.

   Record the seconds from **Allow** to the receipt, on an iCloud "Optimize Storage" library. If it exceeds 20 s, lower `maxAssetsPerRun` and note the value in the PR.

### Pitfalls and out of scope
- **Invariant 1:** every rebuild goes through `PhotoGroup.init`, including `applyingUserKeptIDs`. Never assign `deleteCandidateIDs` directly.
- **Invariant 10:** a Duck Mode commit is free. Do not add a paywall at commit.
- Do not redesign Duck Mode (invariant 29). The chip reuses the keeper badge style.
- `HomeViewModel` edits stay limited to the helper, the three call sites and one subscription. WS-16 (chapter 04) moves them into `PhotoResultsStore`.
- **Reconciliation:** WS-06's `SwipeModeViewModel` parameter is `transitionDelayNanoseconds` (not `transitionDelay`), and the async-wait helper is WS-06's `waitUntil` (not a WS-08 helper).
- **Reconciliation (lead L22):** the temporary "Reset Kept Photos" item goes in the gear/overflow menu next to "Scan Again". In code that is the `gearshape.fill` menu in `PhotoDuckShellView.swift`, the file where WS-48 (chapter 10) greps for the item and moves it into Help & Privacy. Do not put it in Home's `questionmark.circle` support menu, which WS-48 replaces.
- **Reconciliation:** WS-40 (chapter 08) adds `PhotoGroup.isAutoCleanAllEligible` (it excludes `.perGroupOnly` burst groups) and switches `autoCleanEligibleGroups` to it, so `AutoCleanPlanner` receives only those groups. WS-36's `AutoCleanToolbarState` count uses the same list.
- **Reconciliation:** later stored `PhotoGroup` fields must survive the `applyingUserKeptIDs` rebuild: WS-40's `autoCleanPolicy` (chapter 08) and WS-63's `pairEvidence` (chapter 13). Each of those workstreams adds its field to this `PhotoGroup(...)` call.
- **Out of scope:**
  - The Duck Mode completion screen's persistent receipt line and freed-bytes wording: WS-32 (chapter 07), using `lastCommitReceipt`.
  - Duck Mode prefetch: WS-51.
  - The final location of "Reset Kept Photos" (Help & Privacy): WS-48.
  - Screenshot and blurry swipe queues (`SwipeQueueSource`): WS-41, which must keep `committedAssetIDs`, the keep-store calls and the nil-keeper handling.
  - Paid gate unification: WS-36.
  - The directory-level backup flag: WS-34.
  - Persisting pending Duck Mode marks across app kills (DEL-08 item 5, optional): not planned for v1; add it to `spec/BACKLOG.md`.

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| DEL-08 | confirmed | `SwipeModeView.swift:37`, `:357`, `:69-72`. For "Review again", the plan uses the reviewer's alternative (unavailable while marks are pending) instead of preserving marks across a reset, which avoids inconsistent counters. |
| UI-13 | confirmed | Same facts. The in-flight part was delivered by WS-11 (`isCommitting`). `committedAssetIDs` is implemented as proposed. The "Moved N" completion line comes from the receipt toast now, with a persistent line in WS-32. |
| DEL-09 | confirmed | `resetQueue` rebuilds from init-time `allGroups` (`SwipeModeViewModel.swift:150`). Excluding `committedAssetIDs` plus skipped IDs fixes it. Observing `lastReceipt` for other surfaces is unnecessary, because Duck Mode is a full-screen cover. |
| DEL-04 | confirmed | No per-asset keep memory exists anywhere. Reconcile preserves stale plans (`HomeViewModel.swift:1859-1881`). Correction to the reviewer's fix: filtering `deleteCandidateIDs` alone is unsafe, because `PhotoGroup.init:75-90` re-infers every unprotected non-keeper. Kept candidates are therefore also marked protected, and an emptied plan is forced to `.reviewManually`. Kept IDs are validated by guardrail throw; they are not silently dropped at commit. |
| DEL-12 | confirmed | A single `performChanges` for every candidate (`PhotoResultsView.swift:204`). PhotoKit's behavior on very large batches is unmeasured, so the 1,000 cap is a tuning constant set by Device QA 6. A contiguous-prefix rule was chosen for determinism. |
| VALUE-17 | confirmed | `QueueEntry` has no keeper, and the card renders only the candidate. The keeper is looked up in `SwipeModeViewModel.keeperAsset(forGroupID:)` instead of being added to the enum payload, because WS-41 reshapes `QueueEntry` (optional groupID). |
| UI-14 | confirmed | Same. The chip is tap-to-compare (reusing `FullscreenGroupCompareView`), not long-press. |

---

## WS-13 — Automated-plan protections: favorites, undeletable assets, album curation

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M1 | M | WS-08, WS-11 | yes | `ws/13-automated-plan-protections` |

**Primary files:**
- Engines: `iOSCleanup/Engines/AutomatedPlanProtection.swift` (*new*), `iOSCleanup/Engines/AlbumMembership.swift` (*new*), `iOSCleanup/Engines/PhotoScanEngine.swift` (limited to `init`, `makeGroups` and `makeCandidates`), `iOSCleanup/Engines/PhotoDeletionGuardrails.swift`, `iOSCleanup/Engines/MLEnhancedKeeperRankingService.swift`, `iOSCleanup/Engines/DeletionManager.swift`, `iOSCleanup/Engines/DeletionCommitPlanner.swift`, `iOSCleanup/Engines/DeletionTypes.swift`.
- Model: `iOSCleanup/Models/PhotoGroup.swift`.
- Tests: `iOSCleanupTests/AutomatedPlanProtectionTests.swift` (*new*), `iOSCleanupTests/SimilarityPolicyTests.swift`, `iOSCleanupTests/PhotoScanEngineEndToEndTests.swift`, `iOSCleanupTests/Support/ConfigurablePhotoScanTestAsset.swift`, `iOSCleanupTests/PhotoMLStoreTests.swift`, `iOSCleanupTests/DeletionCommitPlannerTests.swift`, `iOSCleanupTests/DeletionManagerTests.swift`.
- Project: `iOSCleanup.xcodeproj/project.pbxproj`.

`SimilarityPolicyServices.swift` does **not** change: keeper ranking stays score-based.

**Findings covered:**
- SCAN-01 (P1, partially; merged: DEL-05)
- SCAN-21 (P3, unverifiable-statically; the cheap protection is implemented regardless)
- SCAN-M02 (P2, confirmed)

**Decisions applied:**
- **D-FAVORITES-USER:** favorites are never in automated plans. They are excluded from `deleteCandidateIDs` at plan time, protected in `PhotoGroup.init`, rejected by the static guardrail, and dropped at commit when live. User-authored paths may still delete them.

### Goal
Keep Best and Auto-clean never propose, and never delete:
- a favorite, whether favorited at scan time or afterwards;
- a photo PhotoKit won't let the app delete;
- a non-keeper that sits in a user album the keeper is not in.

Groups whose deletable set becomes empty are downgraded to review-only. Keeper ranking is unchanged. The album-membership data is exposed so that WS-38 can use user-album count as a tie-break.

### Current behavior (verified)

**Favorites get only a score bonus.**
- `iOSCleanup/Engines/SimilarityPolicyServices.swift:295-298`: being a favorite adds `favoriteBonus` (0.08, set at `PhotoScanEngine.swift:1199`) and nothing else.
- `:578-583`: `makeResult` sets `deleteCandidateIDs` to every non-keeper.

**`makeGroups` does not filter.**
- `PhotoScanEngine.swift:1357-1359` takes `classification.deleteCandidateIDs` as-is.
- `makeCandidates` hard-codes `isProtected: false` (`:1458`).
- `containsFavorite` (`:1346`) only feeds `PreferenceAdjustedRecommendationService`, which downgrades favorites only when the learned `keepRate >= 0.60` (`PreferenceAdjustedRecommendationService.swift:96-107`). `keepRate` returns 0 without data (`:181-185`).

**Ranking favorites first would break the margin rule.** `keeperScoreMargin` (`PreferenceAdjustedRecommendationService.swift:187-194`) is the top-1 minus top-2 **score**, whichever asset is the keeper. A "favorites first" keeper would decouple that margin from the keeper, which is the verifier's correction.

**The ML override ignores favorites.** `MLEnhancedKeeperRankingService.swift:59-107` can replace the heuristic keeper with any ML winner. It is dormant, since no `.mlmodelc` is bundled.

**Protection comes only from candidates.** `PhotoGroup.swift:65-84` builds `protectedCandidateIDs` only from candidates, and the inferred near-duplicate plan selects every unprotected non-keeper.

**Nothing checks favorites or deletability.** `PhotoDeletionGuardrails.swift:83-138` has no `isFavorite` or `canPerform` check. `grep -rn "canPerform" iOSCleanup` is empty. The library fetch (`PhotoScanEngine.swift:61-80`) uses default `PHFetchOptions` apart from sorting.

**Nothing reads albums.** `grep -rn "PHAssetCollection" iOSCleanup` is empty. Deleting a `PHAsset` removes it from every album.

**How groups are built and restored.**
- The engine's group cache lives for one run (`PhotoScanEngine.swift:556`). Each `makeGroups` pass (`:902-915`, at every refresh stride) evaluates only clusters whose key is new.
- Restore (`PhotoAnalysisCache.swift:403-450`) fetches assets fresh and passes stored candidates, including their `isProtected`, through `PhotoGroup.init`. The live `isFavorite` is therefore visible at restore.

**WS-11 already drops live favorites.** Its planner skips live favorites and hidden assets on automated paths. This workstream adds the plan-time, init-time, guardrail and album layers.

### Implementation plan

**WS-13.1 — Verify first, and prepare the test doubles**
- **Why:**
  - SCAN-21's reachability depends on the device. PhotoKit may not return computer-synced (`.typeiTunesSynced`) assets at all.
  - `canPerform(.delete)` on a bare `PHAsset` test double may return false, which would flip every existing engine test to review-only.
- **Change:**
  1. Copy the WS-09 baseline's SCAN-21 observation (`sourceType` counts, and `canPerform(.delete)` for a Finder-synced album) into the PR. Implement WS-13.3's undeletable protection either way; it is cheap and safe.
  2. Make sure **every** `PHAsset` double used by engine and group tests overrides `canPerform(_:)` to return `true` by default:
     - WS-03's `TestPhotoAsset` (its `Stub.canPerform` already defaults to `true`)
     - WS-08's `ConfigurablePhotoScanTestAsset`
     - any private `PhotoScanTestAsset` still left in `PhotoScanEngineTests.swift:2197`
  3. Add a `canDelete: Bool = true` configuration to `ConfigurablePhotoScanTestAsset`, next to its existing `isFavorite`.
  4. WS-03's `TestPhotoAsset.stub` is immutable. Add `var favoriteOverride: Bool?` to `TestPhotoAsset`, and make `isFavorite` return `favoriteOverride ?? stub.isFavorite`, so tests can model "favorited after the scan".
- **Edge cases:** run the whole suite once after this step alone. It must stay green before any production change.

**WS-13.2 — Pure protection policy and the album-membership seam**
- **Why:** plan-time protection must be one pure, testable rule set that `makeGroups` and the commit path share.
- **Change:**
  1. `iOSCleanup/Engines/AutomatedPlanProtection.swift`:
     ```swift
     enum PlanProtectionReason: String, Codable, Sendable, CaseIterable { case favorite, undeletable, albumCurated }
     enum AutomatedPlanProtection {
         static func groupReason(for reason: PlanProtectionReason) -> String   // user-facing, see below
         /// Candidates that an automated plan must not delete. The keeper is never returned. Priority: favorite > undeletable > albumCurated.
         static func protectedCandidates(keeperID: String, candidateIDs: [String],
                                         favoriteIDs: Set<String>, undeletableIDs: Set<String>,
                                         albums: AssetAlbumMembership?) -> [String: PlanProtectionReason] {
             var result: [String: PlanProtectionReason] = [:]
             let keeperAlbums = albums?.albumIDs(for: keeperID) ?? []
             for id in candidateIDs where id != keeperID {
                 if favoriteIDs.contains(id) { result[id] = .favorite }
                 else if undeletableIDs.contains(id) { result[id] = .undeletable }
                 else if let albums, !albums.albumIDs(for: id).isSubset(of: keeperAlbums) { result[id] = .albumCurated }
             }
             return result
         }
     }
     ```
     The group reasons are:
     - `favorite`: "Favorited photos are never auto-selected"
     - `undeletable`: "Some photos can't be deleted by PhotoDuck (for example, synced from a computer)"
     - `albumCurated`: "Photos in albums the kept photo isn't in are never auto-selected"
  2. `iOSCleanup/Engines/AlbumMembership.swift`:
     ```swift
     struct AssetAlbumMembership: Equatable, Sendable {
         let albumIDsByAssetID: [String: Set<String>]      // user albums only (.album / .albumRegular)
         func albumIDs(for assetID: String) -> Set<String> { albumIDsByAssetID[assetID] ?? [] }
         func userAlbumCount(for assetID: String) -> Int { albumIDs(for: assetID).count }   // WS-38 tie-break
     }
     protocol AlbumMembershipProviding: Sendable {
         /// nil when membership cannot be known (e.g. Limited access hides user albums).
         func userAlbumMembership(for assetIDs: Set<String>) async -> AssetAlbumMembership?
     }
     actor SystemAlbumMembershipProvider: AlbumMembershipProviding { … }
     ```
     `SystemAlbumMembershipProvider`:
     - Returns nil unless `PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized`.
     - Otherwise it builds an index `[assetID: Set<albumLocalIdentifier>]` once. It enumerates `PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)` and, for each album, collects the `localIdentifier`s from `PHAsset.fetchAssets(in: album, options: PHFetchOptions())`. Never pass `options: nil` to a `PHAsset.fetchAssets` call; WS-40's `PhotoFetchLintTests` forbids it.
     - It caches the index keyed by `PHPhotoLibrary.shared().currentChangeToken`, compared with `isEqual`, and rebuilds it when the token changes.
     - It answers by filtering the index to the requested IDs.
     - The index build is wrapped in the `os_signpost` interval `albums.index`, using WS-09's signpost helper.
     - Shared albums, smart albums, `.albumSyncedAlbum` and `.albumImported` are excluded.
- **Edge cases:**
  - DECISION (owner may override): under Limited access the provider returns nil and the album rule is skipped. PhotoKit does not reliably expose user albums then, and Keep Best would otherwise become unusable. Device QA 5 verifies this.
  - The index costs one fetch per album plus one enumeration per album member. It is built at most once per library change, never per cluster.
  - **The per-asset user-album count for WS-38** is `AssetAlbumMembership.userAlbumCount(for:)`. WS-38 (chapter 08) fills its tie-break field `SimilarityAssetDescriptor.userAlbumCount: Int?` for `keepBestTrashRest` clusters with `membership?.userAlbumCount(for: id)`, where `membership` comes from the engine's `albumMembershipProvider` (WS-13.3). The value is nil when the provider returns nil (Limited access). Because the index is cached, a second lookup in the same pass is cheap. Keep both names stable.

**WS-13.3 — Protect candidates at plan time in `makeGroups`/`makeCandidates`**
- **Why:**
  - SCAN-01/DEL-05: favorites become delete candidates.
  - SCAN-21: undeletable members can enter plans.
  - SCAN-M02: album-curated frames can be deleted.
- **Change:**
  1. `PhotoScanEngine.init` gains `albumMembershipProvider: any AlbumMembershipProviding = SystemAlbumMembershipProvider.shared`, stored as `private let albumMembershipProvider` (WS-38 reads it too). This is the only init change; tests pass a stub. Make `SystemAlbumMembershipProvider` have a `static let shared` so the cache persists across engine instances.
  2. In `makeGroups`, after `finalAction`/`finalDeleteCandidateIDs` are computed (`:1354-1359`), make both `var`s and add:
     ```swift
     var protection: [String: PlanProtectionReason] = [:]
     if finalAction == .keepBestTrashRest, let keeperID {
         let favoriteIDs = Set(assets.filter(\.isFavorite).map(\.localIdentifier))
         let undeletableIDs = Set(assets.filter { !$0.canPerform(.delete) }.map(\.localIdentifier))
         protection = AutomatedPlanProtection.protectedCandidates(keeperID: keeperID, candidateIDs: finalDeleteCandidateIDs,
             favoriteIDs: favoriteIDs, undeletableIDs: undeletableIDs, albums: nil)
         if finalDeleteCandidateIDs.contains(where: { protection[$0] == nil }) {
             let albums = await albumMembershipProvider.userAlbumMembership(for: Set(ids))
             protection = AutomatedPlanProtection.protectedCandidates(keeperID: keeperID, candidateIDs: finalDeleteCandidateIDs,
                 favoriteIDs: favoriteIDs, undeletableIDs: undeletableIDs, albums: albums)
         }
         finalDeleteCandidateIDs.removeAll { protection[$0] != nil }
         if finalDeleteCandidateIDs.isEmpty { finalAction = .reviewManually }
     }
     ```
  3. Append `Set(protection.values).map(AutomatedPlanProtection.groupReason)` to the group `reasons`, sorted by `rawValue`.
  4. `makeCandidates(assets:ranking:deleteCandidateIDs:exposeDeleteCandidates:protection:)` sets `isProtected: protection[assetID] != nil` and `selectionState: .protected` for those IDs; the keeper stays `.keep`.
  5. `reclaimableBytes` already uses the final list.
- **Edge cases:**
  - Keeper ranking is untouched. Favorites still receive only the +0.08 bonus, so `keeperScoreMargin` keeps its meaning (verifier correction).
  - A favorite may still be the keeper.
  - The album fetch runs only for new `keepBestTrashRest` clusters that still have an unprotected candidate.
  - Do **not** bump `analyzerVersion` (D-REANALYSIS). Groups restored from older snapshots are covered by WS-13.4 (favorites) and WS-13.6 (albums and undeletable at commit).

**WS-13.4 — `PhotoGroup.init` favorite protection and the static guardrail**
- **Why:** restored or rebuilt groups must never carry a favorite in an automated plan.
- **Change:**
  1. In `PhotoGroup.init` (`PhotoGroup.swift:65-71`), extend the protected set:
     ```swift
     let favoriteNonKeeperIDs = Set(assets.lazy.filter(\.isFavorite).map(\.localIdentifier))
         .subtracting([effectiveKeeperAssetID].compactMap { $0 })
     let protectedCandidateIDs = Set(candidates.filter { $0.isProtected || $0.selectionState == .protected }.map(\.photoId))
         .union(favoriteNonKeeperIDs)
     ```
     With this set:
     - an explicit plan containing a favorite is no longer well formed, so the group becomes `reviewManually` with empty candidates;
     - an inferred plan simply skips favorites.
  2. In `PhotoDeletionGuardrails`:
     - Add `case favoriteInAutomatedPlan`, with errorDescription "Favorited photos are never removed automatically. Review this group to choose."
     - In `validate(group:keptIDs:)`, after the existing checks, add `if group.deleteCandidateAssets.contains(where: \.isFavorite) { throw .favoriteInAutomatedPlan }`.
     - `validateManualSelection` does **not** get this check (D-FAVORITES-USER).
- **Edge cases:**
  - `PhotoGroup.init` changes can flip existing tests that build a `keepBestTrashRest` group with a favorite candidate. Update such tests on purpose and name each in the PR.
  - `reconcile` (`HomeViewModel.swift:1859`) reuses snapshot assets. That is fine: the commit-time check (WS-11) covers live changes.

**WS-13.5 — The ML keeper override respects favorites**
- **Why:** SCAN-01 step 3. It is dormant today but must be safe before any model ships.
- **Change:** in `MLEnhancedKeeperRankingService.rankKeeper`, after `newKeeperID` is computed (`:96-99`), add:
  ```swift
  if input.assets.contains(where: \.isFavorite),
     input.assets.first(where: { $0.id == newKeeperID })?.isFavorite != true { return heuristicResult }
  ```
- **Edge cases:** when the heuristic keeper is not a favorite but the ML winner is, the override is still allowed.

**WS-13.6 — Album and undeletable protection at commit time**
- **Why:** plans restored from older snapshots, and album changes made after the scan, must still be protected. Exit criterion: "automated plans exclude … undeletable assets"; `.undeletable` is already skipped by WS-11.
- **Change:**
  1. Add `case albumCurated` to `DeletionSkipReason`.
  2. `DeletionCommitPlanner.plan(items:resolved:context:albums: AssetAlbumMembership? = nil)`: for `.automatedPlan` items that have a `requiredKeeperID`, when `albums` is non-nil and `!albums.albumIDs(for: id).isSubset(of: albums.albumIDs(for: keeper))`, record `.albumCurated` and skip the item. This check runs after the favorite and hidden checks.
  3. `DeletionManager` gains `albumMembership: any AlbumMembershipProviding = SystemAlbumMembershipProvider.shared`. Inside `commit`, only for `.automatedPlan`, fetch `await albumMembership.userAlbumMembership(for: itemIDs ∪ keeperIDs)` after resolution, and pass it to the planner.
- **Edge cases:**
  - This adds some latency before the iOS prompt. A cached index makes it cheap; the first build after a library change is timed in Device QA 6.
  - User-authored deletions never consult albums.

### Tests
All tests run in the simulator, except the `SystemAlbumMembershipProvider` behavior (device only).
- **`AutomatedPlanProtectionTests` (new, pure):**
  - `testFavoriteNonKeeperIsProtected`
  - `testKeeperIsNeverReturnedEvenIfFavorite`
  - `testUndeletableIsProtected`
  - `testCandidateInAlbumKeeperIsNotInIsProtected`
  - `testCandidateInSameAlbumsAsKeeperIsNotProtected`
  - `testNilMembershipSkipsAlbumRule`
  - `testPriorityFavoriteOverUndeletableOverAlbum`
  - `testUserAlbumCount`
- **`SimilarityPolicyTests` (extend):**
  - `testPhotoGroupInitRejectsExplicitPlanContainingFavorite`: the result is `.reviewManually` with empty candidates.
  - `testPhotoGroupInferredPlanSkipsFavorite`: a high `nearDuplicate` group with an empty plan never infers the favorite.
  - `testGuardrailThrowsFavoriteInAutomatedPlanWhenFavoritedAfterConstruction`: build the group, then set `favoriteOverride = true`; `validate(group:)` throws `.favoriteInAutomatedPlan`, and `compatibleAutoCleanGroups` skips it.
  - `testManualSelectionMayIncludeFavorite`: `validateManualSelection` does not throw.
- **`PhotoMLStoreTests` (extend, reusing its private `ConfigurableKeeperPredictionService` and `FixedKeeperRankingService`):**
  - `testMLOverrideRejectedWhenItWouldDemoteFavorite`: the heuristic keeper "a" is a favorite, and ML predicts 0.95 for "b"; the result equals the heuristic.
  - `testMLOverrideAllowedWhenWinnerIsFavorite`
- **`PhotoScanEngineEndToEndTests` (extend WS-08's fixtures, with the stub album provider):**
  - `testFavoriteNonKeeperIsNeverADeleteCandidate`: 3 members; the favorite has lower sharpness than the keeper; the favorite is absent from `deleteCandidateIDs` and marked `isProtected`.
  - `testTwoFavoritesOnlyGroupBecomesReviewManually`
  - `testUndeletableMemberIsProtected`
  - `testAlbumCuratedNonKeeperIsProtected`
  - `testAllCandidatesProtectedDowngradesAndIsNotAutoCleanEligible`
- **`DeletionCommitPlannerTests` / `DeletionManagerTests` (extend):**
  - `testAutomatedPlanSkipsAlbumCuratedCandidate`
  - `testUserSelectionIgnoresAlbums`
  - `testKeepBestConsultsAlbumProviderOnlyForAutomatedPlans`: the stub counts its calls.

### Acceptance criteria
- [ ] No automated plan lists a favorite, an undeletable asset, or a non-keeper in a user album the keeper is not in:
  - at plan time (end-to-end tests);
  - after restore (`PhotoGroup.init` tests);
  - at commit time, with live values (planner and manager tests).
- [ ] Favorites remain deletable through user-authored paths (tests).
- [ ] Keeper ranking is unchanged: `ConservativeKeeperRankingService` is not edited, and all existing `SimilarityPolicyTests` pass unchanged.
- [ ] The ML override never replaces a favorite keeper with a non-favorite (test).
- [ ] The PR records the WS-09 SCAN-21 observation.
- [ ] `CLAUDE.md` Key constraints gains: "Automated plans exclude favorites, undeletable assets (`canPerform(.delete)`), user-kept IDs and non-keepers in user albums the keeper isn't in: at plan time (`AutomatedPlanProtection`), in `PhotoGroup.init` (favorites), in `PhotoDeletionGuardrails`, and at commit time in `DeletionManager`."
- [ ] The full suite is green, with zero warnings.

### Device QA
Append to `docs/DEVICE_QA.md` under "Automated-plan protections (WS-13)":
1. Favorite two of three near-identical shots, then scan. Expect the favorites never to be marked red in detail, and Auto-clean's sheet not to include them. If both non-keepers are favorites, the group is review-only.
2. After a scan, favorite a delete candidate in Photos, return, and tap Keep Best on that group. Expect the favorite not to be deleted: the toast shows "1 skipped", or you see "changed since the scan".
3. Put a non-keeper frame into a new album "QA Album" and rescan. Expect it to be protected, and after Keep Best the album still contains it. Repeat, adding it to the album *after* the scan: Keep Best skips it at commit.
4. If the device has a Finder-synced album, record `sourceType` counts and whether any such photo appears in a group. It must never be marked for deletion.
5. Under Limited Photos access, check whether `fetchAssetCollections(.album)` returns user albums. Record the result. Keep Best must still work there, because the album rule is skipped.
6. On a 30-60k library with at least 20 albums, record the duration of the `albums.index` signpost (first build and cached) and the time from tapping Keep Best to the iOS prompt.

### Pitfalls and out of scope
- **Do not** rank favorites first (verifier correction). `keeperScoreMargin` compares the top-2 scores.
- **Invariant 7** applies to automated paths only. Never add favorite, album or kept checks to `delete(assets:)` or `validateManualSelection`.
- **Invariant 5:** `PhotoScanEngine` only gathers facts (`isFavorite`, `canPerform`, album IDs). The rule lives in `AutomatedPlanProtection`.
- **Invariant 12:** do not bump `analyzerVersion`.
- **Out of scope:**
  - `PreferenceAdjustedRecommendationService` changes: WS-33 (chapter 07).
  - Verified-identical tie-breaks using `userAlbumCount`: WS-38 (chapter 08).
  - Excluding favorites from Select All in category grids: WS-41 (chapter 09).
  - User-pick burst frames: WS-40 (chapter 08).
  - Adding the keeper to the candidate's albums at commit (Apple "Merge"-style): not planned; add it to `spec/BACKLOG.md`.
- **Reconciliation:** WS-38 needs a per-asset user-album count for `keepBestTrashRest` clusters. It is fixed as `AssetAlbumMembership.userAlbumCount(for:)`, read through the engine's stored `albumMembershipProvider` (nil under Limited access), and consumed as `SimilarityAssetDescriptor.userAlbumCount`.
- **Reconciliation:** the album-content fetch passes `PHFetchOptions()` instead of `options: nil`, because WS-40 (chapter 08) adds a lint that forbids `options: nil` on every `PHAsset.fetchAssets` call.
- **Reconciliation:** `TestPhotoAsset` changes are phrased against WS-03's `Stub`-based double: `canPerform` already defaults to true, and "favorited after the scan" uses a new `favoriteOverride`.

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| SCAN-01 | partially | The code is as described (`SimilarityPolicyServices.swift:295`, `:578-583`; `PhotoScanEngine.swift:1458`). The realistic path is 2+ favorites in one group, or a favorite added after the scan; a single edited favorite usually hits a soft blocker. Following the verifier's correction, ranking stays score-based and favorites are excluded from the plan, protected in `PhotoGroup.init`, rejected by guardrail, and dropped live at commit (WS-11). The ML guard is implemented, though dormant. |
| DEL-05 | partially | Same facts. Its guardrail name `.favoriteInDeleteCandidates` is replaced by `.favoriteInAutomatedPlan`, per the workstream note. The live-at-commit check is the WS-11 planner's `.favorite` skip, not a thrown error, so one stale favorite cannot sink an Auto-clean batch. |
| SCAN-21 | unverifiable-statically | No `canPerform` call exists, and the fetch uses default options. Whether computer-synced assets are fetched at all is device behavior (WS-09 records it). The cheap plan-time protection and the WS-11 commit-time skip ship regardless. |
| SCAN-M02 | confirmed | No album API is used anywhere. The plan differs from the reviewer's in four ways: (1) membership comes from a change-token-cached index, not per-asset `fetchAssetCollectionsContaining` calls inside every cluster (bounded cost at 60k); (2) it is also enforced at commit for restored plans; (3) the tie-break is exposed (`userAlbumCount`) but not wired into ranking, because exact score ties already fall below the 0.08 margin, so WS-38 wires it for verified-identical clusters; (4) under Limited access the rule is skipped (DECISION). |

---

## WS-14 — Trustworthy previews

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M1 | M | WS-04, WS-10 | no | `ws/14-trustworthy-previews` |

**Primary files:**
- Utilities: `iOSCleanup/Utilities/SharedHelpers.swift` (`PhotoImageRepository`, intents, `loadImage`, and `PhotoImageRequestState`, which stays in this file until WS-24.5), `iOSCleanup/Utilities/PhotoImageDeliveryDecision.swift` (*new*). Do not edit WS-10's `iOSCleanup/Utilities/PhotoKitRequestState.swift`: it holds only the generic `PhotoKitRequestState<Value>`, and WS-24.5 (chapter 05) later moves `PhotoImageRequestState` into it.
- Components: `iOSCleanup/Views/Components/PhotoThumbnailView.swift` (*new*), `iOSCleanup/Views/Components/PhotoAccessibilityText.swift` (*new*).
- Photos views: `iOSCleanup/Views/Photos/DuckCardActionPolicy.swift` (*new*), `SwipeModeView.swift`, `PhotoResultsView.swift`, `AutoCleanConfirmationSheet.swift` (after WS-12), `PhotoGroupDetailView.swift`, `FullscreenGroupCompareView.swift` (move it here if WS-12 has not), `PhotoCategoryReviewView.swift`, and `DuckKeeperChip.swift` (if WS-12 landed).
- Other views: `iOSCleanup/Views/Components/CategoryPhotoThumbnail.swift` (moved there by WS-10); `iOSCleanup/Views/PhotoDuckShellView.swift`.
- Docs: `CLAUDE.md`.
- Tests: `iOSCleanupTests/PhotoImageDeliveryDecisionTests.swift` (*new*), `iOSCleanupTests/ThumbnailPhaseTests.swift` (*new*), `iOSCleanupTests/ThumbnailLintTests.swift` (*new*), and `iOSCleanupTests/PhotoImageRepositoryTests.swift` (WS-03 moved the repository and `testImageRequest*` tests there from `FileScanEngineTests.swift:612-770`).
- Project: `iOSCleanup.xcodeproj/project.pbxproj`.

**Findings covered:** FSA-11 (P2, confirmed), UI-16 (P2, confirmed; how often the degraded first frame occurs is device-dependent), SCAN-16 (P2, confirmed)

**Decisions applied:** none directly. The screen keeps D-UNDO's copy rules and adds no undo promise. D-FAVORITES-USER is unaffected.

### Goal
Every surface where the user decides what to delete shows either the real photo or an explicit, static "Preview unavailable" state with Retry. Nowhere spins forever. Specifically:
- Duck Mode's Delete is enabled only once the card's photo has actually loaded.
- Grid thumbnails are never the locked-in degraded first frame.
- Category photos can be opened full screen.
- VoiceOver users hear the date and size of each photo.
- Analysis traffic during a scan no longer evicts UI thumbnails from the shared cache.

`PhotoThumbnailView` accepts a point size, so WS-52 can add pixel buckets, a UI lane and prefetch without touching call sites.

### Current behavior (verified)

**The shared cache stores everything.**
- `iOSCleanup/Utilities/SharedHelpers.swift:283`: a 96 MB decoded-byte LRU.
- `:405-424`: `finishConsumer` stores **every** non-nil result for every intent, including `.analysisFast` and `.analysis`, whose keys are never requested again.
- `:442-461`: eviction scans with `min(by:)`.

**Thumbnails accept the degraded first frame.**
- `:309-332`: `.thumbnail` uses `.opportunistic`, `acceptsDegradedResult = true` and 8 s; `.review` and `.fullscreen` use `.highQualityFormat` with 20 s and 30 s.
- `loadImage` (`:545-617`) resolves on the first callback that carries an image when degraded images are accepted (`:590-601`). The later high-quality callback is dropped and the request is not cancelled, and the repository caches whatever arrived first.

**Several paths return nil.** The timeout (`:566-568`) returns nil, and so does the request executor's cap: 16 scheduled requests (`:36-47`), returning nil immediately at `:608-610`, which can happen during scans.

**Every UI site renders `if let image {…} else { … ProgressView() }` with no finished or failed state.** Those sites:
- `SwipeModeView.swift:439-448`: `DuckAssetCard`, the card being swiped for deletion.
- `:380-390`: `PendingDeleteThumbnail`.
- `PhotoResultsView.swift:542-580`: `AutoCleanDeleteThumbnail`, on the paid Auto-clean confirmation. WS-12 moves it to `AutoCleanConfirmationSheet.swift`.
- `:582-742`: the three `GroupOverviewCard` tiles, loaded by a task group into a dictionary.
- `PhotoGroupDetailView.swift:351-359`: `PhotoGroupAssetCell`.
- `:605-649`: `CompareThumbnail`.
- `HomeView.swift:2110-2158`: `CategoryPhotoThumbnail`, shared by the category review and the Export Album grids.
- `PhotoDuckShellView.swift:578-702`: `SimilarGroupPreviewCard`.
- `ZoomablePhotoCanvas` (`PhotoGroupDetailView.swift:552-603`) also spins forever on nil. It requests `PHImageManagerMaximumSize`; WS-51 owns that size.

**Duck Mode lets the user delete an image that never loaded.** The drag gesture and Delete button (`SwipeModeView.swift:113-126`, `:176-184`) are enabled whether or not an image loaded.

**The category grid** (`HomeView.swift:1167-1187`):
- Tapping only toggles selection. There is no preview.
- VoiceOver labels are "Selected photo" or "Unselected photo" (`:1183-1187`).

**Unaffected:** `LargeVideoThumbnail` (`FileResultsView.swift:1716-1850`) already handles nil with `localThumbnailUnavailable`, so it is out of scope.

**Existing tests:** repository tests (`FileScanEngineTests.swift:611-705`) use the operation-based entry point `image(for:operation:)`, and a `PhotoImageRequestState` timeout test sits at `:706+`.

### Implementation plan

**WS-14.1 — Analysis images never enter the shared cache (SCAN-16)**
- **Why:** during a 50k scan, analysis images evict visible grid thumbnails, cells flicker and re-hit PhotoKit, and up to 96 MB is held by dead entries.
- **Change:** add this in `SharedHelpers.swift` next to the intent enum:
  ```swift
  extension PhotoImageQualityIntent {
      /// Analysis images are requested once per scan; caching them only evicts UI thumbnails.
      /// WS-51 (chapter 11) also turns .review and .fullscreen off.
      var isCacheable: Bool {
          switch self { case .thumbnail, .review, .fullscreen: return true
                        case .analysisFast, .analysis: return false }
      }
  }
  ```
  In `finishConsumer`, store only when `key.qualityIntent.isCacheable`. In-flight coalescing stays for all intents.
- **Edge cases:** an analysis result still returns to every coalesced consumer.

**WS-14.2 — Never cache or lock in a degraded frame (UI-16 part 1)**
- **Why:** blurry review cannot be judged on degraded thumbnails.
- **Change:**
  1. Add `iOSCleanup/Utilities/PhotoImageDeliveryDecision.swift`. This workstream introduces the file and the type. WS-22 (chapter 05) **extends** them with its analysis-lane rules. It must not create a second file, or redeclare `PhotoImageDeliveryDecision`, `PhotoImageDeliveryAction` or `PhotoImageLoadResult`.
     ```swift
     struct PhotoImageLoadResult: @unchecked Sendable { let image: UIImage; let isDegraded: Bool }
     enum PhotoImageDeliveryAction: Equatable { case resolve, rememberDegradedAndWait, resolveWithRememberedOrNil, wait }
     enum PhotoImageDeliveryDecision {
         static func decide(imagePresent: Bool, isDegraded: Bool, hasError: Bool,
                            acceptsDegraded: Bool, fallsBackToDegraded: Bool) -> PhotoImageDeliveryAction {
             if imagePresent && (!isDegraded || acceptsDegraded) { return .resolve }
             if imagePresent && isDegraded { return fallsBackToDegraded ? .rememberDegradedAndWait : .wait }
             if hasError || !isDegraded { return fallsBackToDegraded ? .resolveWithRememberedOrNil : .resolve }
             return .wait
         }
     }
     ```
     `.resolve` with no image resolves nil, exactly as today.
  2. In `PhotoImageRequestState` (still in `SharedHelpers.swift`; WS-10 did not move it, and WS-24.5 moves it later):
     - Add `rememberDegraded(_:)`, `resolveWithRememberedOrNil()` and `private(set) var deliveredDegraded`, all guarded by the existing lock.
     - `resolve(_:isDegraded:)` records the flag.
     - `cancel(cancelRequest:)` gains `fallbackToRemembered: Bool = false`. On timeout it resolves with the remembered degraded image (flagged) when enabled, and with nil otherwise.
     - The continuation type stays `UIImage?`, so the existing timeout test keeps compiling.
  3. `PHAsset.loadImage`:
     - Rename its body to `loadImageResult(… fallsBackToDegraded: Bool = false) async -> PhotoImageLoadResult?`. It uses the decision function in the callback, and its timeout passes `fallbackToRemembered: fallsBackToDegraded`.
     - Keep `loadImage(…) -> UIImage?` as a one-line wrapper, since CLAUDE.md names it as the shared helper.
  4. In `PhotoImageRepository`:
     - `SendablePhotoImage` gains `isDegraded`.
     - Add `typealias ImageResultOperation = @Sendable () async -> PhotoImageLoadResult?` and `image(for key:resultOperation:)`. The existing `image(for:operation:)` wraps it, treating results as not degraded, so existing tests are unchanged.
     - `finishConsumer` stores only `!result.isDegraded && key.qualityIntent.isCacheable`.
     - For `.thumbnail`, the asset entry point sets `acceptsDegradedResult = max(targetSize.width, targetSize.height) < 200` and `fallsBackToDegraded = true`. Every other intent keeps its current values, with `fallsBackToDegraded = false`.
- **Edge cases:**
  - An iCloud-only photo with the network off still shows the local degraded frame; it is simply not cached. That is better than `acceptsDegradedResult = false` alone, which would show nothing.
  - Analysis intents are byte-for-byte unchanged, because `fallsBackToDegraded` is false (invariant 22).

**WS-14.3 — `PhotoThumbnailView` with explicit phases (FSA-11)**
- **Why:** nil must end in a visible, static state, and deletion screens must know whether the user actually saw the photo.
- **Change:** in `iOSCleanup/Views/Components/PhotoThumbnailView.swift`:
  ```swift
  enum ThumbnailPhase: Equatable {
      case loading, loaded(UIImage), unavailable
      enum Kind: Equatable, Sendable { case loading, loaded, unavailable }
      var kind: Kind { switch self { case .loading: .loading; case .loaded: .loaded; case .unavailable: .unavailable } }
      static func reduce(_ image: UIImage?) -> ThumbnailPhase { image.map(ThumbnailPhase.loaded) ?? .unavailable }
      static func == (l: Self, r: Self) -> Bool { switch (l, r) {
          case (.loading, .loading), (.unavailable, .unavailable): true
          case let (.loaded(a), .loaded(b)): a === b
          default: false } }
  }
  struct PhotoThumbnailView<Placeholder: View>: View {
      enum Sizing: Equatable { case points(CGSize), pixels(CGSize) }   // WS-52 buckets .points
      let asset: PHAsset
      let sizing: Sizing
      var contentMode: PHImageContentMode = .aspectFill
      var qualityIntent: PhotoImageQualityIntent = .thumbnail
      var allowNetworkAccess = false
      var showsRetry = false                        // true for Duck Mode, detail cells, fullscreen
      var onPhaseChange: ((ThumbnailPhase.Kind) -> Void)? = nil
      @ViewBuilder var placeholder: () -> Placeholder   // each site keeps its current background
      @Environment(\.displayScale) private var displayScale
      @State private var phase: ThumbnailPhase = .loading
      @State private var attempt = 0
      // .task(id: "\(asset.localIdentifier)|\(pixelW)x\(pixelH)|\(attempt)"): phase = .loading → request → phase = .reduce(image)
  }
  ```
  - Add a convenience init where `Placeholder == Color` (default `Color.decorPink.opacity(0.3)`).
  - **Pixel size:** for `.points(p)` it is `ceil(p × displayScale)`; for `.pixels(s)` it is `s`.
  - **Loaded:** `Image(uiImage:)`, resizable, with a fill or fit mode.
  - **Loading:** the placeholder with a tinted `ProgressView`.
  - **Unavailable:** the placeholder plus an SF Symbol: `icloud.slash` when `!allowNetworkAccess`, otherwise `photo`. Add the caption "Preview unavailable" when the rendered height is at least 100 pt. When `showsRetry`, add a "Retry" button that increments `attempt`.
  - Call `onPhaseChange(phase.kind)` on every change.
  - Accessibility: the unavailable state has the label "Preview unavailable".
- **Edge cases:**
  - Reset `phase = .loading` at the start of each task, so a reused view never shows a previous asset. Keep WS-04's `.id(asset.localIdentifier)` on `DuckAssetCard`.
  - Ignore results after `Task.isCancelled`.

**WS-14.4 — Migrate every site and gate Duck Mode's Delete**
- **Why:** FSA-11: no endless spinner on any deletion-decision screen, and no delete of an unseen card.
- **Change:**
  - Replace every UI site's `PhotoImageRepository.shared.image` call and `if let image` block:

    | Site | Sizing / intent / network / retry |
    |---|---|
    | `DuckAssetCard` | `.pixels(targetSize)` as computed today; `.review`; network `true`; retry; `onPhaseChange` reported up |
    | `PendingDeleteThumbnail` | `.points(88×88)`; `.thumbnail`; `false` |
    | `AutoCleanDeleteThumbnail` | `.points(110×110)`; `.thumbnail`; `false`; `onPhaseChange` |
    | `GroupOverviewCard` | Three `PhotoThumbnailView(.points(120×104))`; delete `loadThumbnails` and `requestThumb` |
    | `PhotoGroupAssetCell` | `.pixels(displayTargetSize(for:))` as today (WS-51 replaces the sizing); `.aspectFit`; `.review`; `true`; retry |
    | `CompareThumbnail` | `.points(72×72)` |
    | `CategoryPhotoThumbnail` | `.points(130×130)`, a nominal tile size covering 3-column grids up to 430 pt wide |
    | `SimilarGroupPreviewCard` | Three tiles `.points(120×104)`, keeping the gradient placeholder; delete the sequential `loadThumbnails` |
    | `DuckKeeperChip` (if WS-12 landed) | `.points(64×64)` |

  - `ZoomablePhotoCanvas` keeps its own view for zoom, but adopts `ThumbnailPhase`. On nil it shows "Preview unavailable" plus "Retry" instead of a spinner. Its request is unchanged (WS-51 owns sizing).
  - Add `iOSCleanup/Views/Photos/DuckCardActionPolicy.swift`: `enum DuckCardActionPolicy { static func canDelete(phase: ThumbnailPhase.Kind, isTransitioning: Bool) -> Bool { phase == .loaded && !isTransitioning } }`.
  - `SwipeModeView` holds `@State private var cardPhase: ThumbnailPhase.Kind = .loading`, reset to `.loading` whenever the current asset ID changes, and set from `DuckAssetCard`'s `onPhaseChange`. Gate on it:
    - The Delete button is `.disabled(!canDelete)`.
    - `swipeLeft()` guards on `canDelete`.
    - The drag's `onEnded` snaps back with `DuckHaptics.rigid()` when a left swipe is not allowed.
    - `deleteCueIntensity` is 0 when `!canDelete`.
    - When `cardPhase == .unavailable`, show the caption "Can't show this photo. Keep it, or tap Retry." above the buttons, using existing tokens.
    - Keep always works.
  - `AutoCleanConfirmationSheet` collects the unavailable IDs from the preview tiles. When the set is non-empty, it shows "Previews for \(n) of these photos aren't available offline."
- **Edge cases:**
  - DECISION (owner may override): Delete is disabled while the card is still *loading*, not only when it is unavailable. The spec requires a real preview before a delete. WS-51's prefetch makes the wait invisible.
  - WS-55's future accessibility "Delete" action must call the same policy.

**WS-14.5 — Category preview and VoiceOver labels (UI-16 parts 2-3)**
- **Why:** blurry and screenshot review needs a larger view, and VoiceOver users must know which photo they are deleting.
- **Change:**
  1. If `FullscreenGroupCompareView.swift` does not exist yet, move `FullscreenGroupCompareView`, `ZoomablePhotoCanvas` and `CompareThumbnail` there as internal types, as a pure-move commit.
  2. In `PhotoCategoryReviewView`:
     - Add `@State private var previewAssetID: String?`.
     - Each grid `Button` gets `.contextMenu { Button { previewAssetID = asset.localIdentifier } label: { Label("Preview", systemImage: "arrow.up.left.and.arrow.down.right") } }` and `.accessibilityAction(named: "Preview") { … }`.
     - Present `.fullScreenCover` with `FullscreenGroupCompareView(assets: categoryAssets, initialAssetID: id, keeperAssetID: nil)`.
  3. Add `iOSCleanup/Views/Components/PhotoAccessibilityText.swift`: `static func label(creationDate: Date?, estimatedBytes: Int64?, mediaType: PHAssetMediaType) -> String`. It returns "Photo, 3 Mar 2025, 2.4 MB", using the medium date style and a `.file` byte count, and omits missing parts.
  4. The category grid uses:
     - `.accessibilityLabel(PhotoAccessibilityText.label(…asset.creationDate, asset.estimatedFileSize, asset.mediaType))`
     - `.accessibilityValue(isSelected ? "Selected" : "Not selected")`
     - `.accessibilityHint("Double tap to select for deletion")`
- **Edge cases:** the context menu must not change tap-to-select. There is no double-tap gesture here, per WS-55's direction.

**WS-14.6 — Lint and docs**
- **Why:** new UI code must not reintroduce direct loads that spin forever.
- **Change:**
  - Add `ThumbnailLintTests`, which fails if `PhotoImageRepository.shared.image(` appears under `iOSCleanup/Views/` outside `PhotoThumbnailView.swift`, `FullscreenGroupCompareView.swift` (`ZoomablePhotoCanvas`) and the file containing `LargeVideoThumbnail`.
  - Update the `CLAUDE.md` Key constraints line "Photo thumbnails must use the shared `PHAsset.loadImage` helper…" to add: "UI images render through `PhotoThumbnailView` (loading / loaded / unavailable with Retry). The repository never caches degraded results or analysis intents. Duck Mode's Delete is enabled only after the card's preview has loaded."

### Tests
All tests run in the simulator.
- **`PhotoImageDeliveryDecisionTests` (new, pure table):**
  - `testNonDegradedImageResolves`
  - `testDegradedAcceptedResolves`
  - `testDegradedNotAcceptedWithFallbackIsRemembered`
  - `testDegradedNotAcceptedWithoutFallbackWaits` (the analysis intents' behavior is unchanged)
  - `testFinalNilUsesRememberedFallback`
  - `testErrorWithoutFallbackResolvesNil`
- **`PhotoImageRequestState` tests (next to the existing timeout test):**
  - `testTimeoutResolvesRememberedDegradedWhenFallbackEnabled`: `deliveredDegraded == true`.
  - `testTimeoutResolvesNilWhenFallbackDisabled`
- **Repository tests (`PhotoImageRepositoryTests.swift`, where WS-03 moved them):**
  - `testDegradedResultIsReturnedButNotCached`: a `resultOperation` returning `isDegraded: true`; the second request re-runs the operation, `startedCount == 2` and `debugCachedImageCount() == 0`.
  - `testAnalysisIntentsAreNotCachedButStillCoalesce`: two concurrent `.analysis` requests give `startedCount == 1` and a cached count of 0.
  - `testThumbnailIntentIsCached`: the cached count is 1.
  - `testIsCacheableTable`
- **`ThumbnailPhaseTests` (new):**
  - `testReduceNilIsUnavailable`
  - `testReduceImageIsLoaded`
  - `testLoadedEqualityIsIdentity`
  - `testDuckCardCanDeleteOnlyWhenLoadedAndNotTransitioning`: a table over every `Kind` and transition state.
  - `testAccessibilityLabelIncludesDateAndSize`
  - `testAccessibilityLabelOmitsMissingParts`
- **`ThumbnailLintTests` (new):** `testNoDirectRepositoryImageCallsInViews`
- **Device only:** the real degraded-then-final PhotoKit sequence, and iCloud-only unavailability (Device QA 1-3).

### Acceptance criteria
- [ ] No UI site under `Views/` renders an endless spinner. Every site, as listed in WS-14.4, goes through `PhotoThumbnailView` or its phase model, and `ThumbnailLintTests` pass.
- [ ] Duck Mode's Delete button and left swipe do nothing unless the current card's phase is `.loaded` (policy test plus Device QA 1).
- [ ] The repository never caches degraded results or analysis intents, and in-flight coalescing is unchanged (tests).
- [ ] Analysis-intent loading behavior is unchanged: `fallsBackToDegraded` is false for `.analysisFast` and `.analysis` (test), and WS-08's end-to-end and benchmark tests pass.
- [ ] Category grid photos can be opened full screen from a long press or the accessibility action, and VoiceOver reads date, size and selection state.
- [ ] `PhotoThumbnailView` accepts `.points` sizing, so WS-52 can bucket without editing call sites.
- [ ] `CLAUDE.md` is updated. The full suite is green, with zero warnings.

### Device QA
Append to `docs/DEVICE_QA.md` under "Previews (WS-14)":
1. Turn on Airplane Mode on an "Optimize iPhone Storage" library and open Duck Mode on a group with iCloud-only photos. Expect the card to show "Preview unavailable" within about 20 s, Delete to be disabled, and Keep to work. Turn the network back on and tap Retry: the photo loads and Delete becomes enabled.
2. In Airplane Mode, open the Similar list, the Auto-clean confirmation and the Duck Mode completion thumbnails. Expect static placeholders (`icloud.slash`), no spinners after about 8 s, and the Auto-clean sheet to show "Previews for N … aren't available offline" when relevant.
3. On Blurry Photos, check that the thumbnails look as sharp as in Photos. Long-press opens Preview full screen. VoiceOver reads "Photo, <date>, <size>, Not selected".
4. During a running scan, scroll the Similar results list for 60 s. Expect no visible re-loading or flicker of thumbnails that were already shown (SCAN-16).

### Pitfalls and out of scope
- **Invariant 21:** images load only through `PhotoImageRepository`. Do not create one-off `PHImageManager` continuations. `PhotoThumbnailView` calls the repository.
- **Invariant 22:** analysis intents keep identical delivery semantics. Only `.thumbnail` gets the degraded fallback.
- **Invariant 29:** no Duck Mode redesign. Placeholders keep each site's current background, and the unavailable caption uses existing tokens.
- **Keep** WS-04's `.id(asset.localIdentifier)` and task identity on `DuckAssetCard`.
- **Strictly sequential with** WS-22, WS-24, WS-51 and WS-52, which touch the same repository region. This workstream lands first.
- **Out of scope:**
  - The review and fullscreen cache policy and `ReviewImageSizePolicy`: WS-51 (chapter 11), which extends `isCacheable`.
  - Pixel buckets, the UI request lane, prefetch and the O(1) LRU: WS-52 (chapter 11).
  - Analysis loader outcomes and capacity waits: WS-22 (chapter 05), which extends `PhotoImageDeliveryDecision`.
  - Duck Mode accessibility actions: WS-55 (chapter 12).
  - Export Album grid labels: optional here; covered by WS-56's polish if not done.
- **Reconciliation (lead L8):** `PhotoKitRequestState.swift` is WS-10's file for the generic `PhotoKitRequestState<Value>`. `PhotoImageRequestState` is still in `SharedHelpers.swift` when this PR lands, and WS-24.5 (chapter 05) moves it into WS-10's file. This PR edits it in `SharedHelpers.swift`.
- **Reconciliation (lead L26):** `PhotoImageDeliveryDecision.swift` and its types are introduced here. WS-22 extends them and keeps this chapter's `.thumbnail` semantics: `fallsBackToDegraded`, the remembered degraded frame, and no caching of degraded results. It also keeps the `loadImageResult` and `image(for:resultOperation:)` entry points, which WS-51 uses.
- **Reconciliation:** `CategoryPhotoThumbnail` is named at its post-WS-10 path, `Views/Components/CategoryPhotoThumbnail.swift`. The repository and `PhotoImageRequestState` timeout tests are extended in WS-03's `PhotoImageRepositoryTests.swift`, not `FileScanEngineTests.swift`.

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| FSA-11 | confirmed | All 8 cited sites render a spinner forever on nil. `ZoomablePhotoCanvas` does too (added here, without changing its size). Nil also comes from the 16-request executor cap during scans, not only from iCloud or timeouts. Delete is gated on `.loaded`, not only on "unavailable or loading past the timeout" (DECISION). |
| UI-16 | confirmed | The code resolves on the first callback and caches it (`SharedHelpers.swift:595-597`, `:415-417`). How often PhotoKit's first opportunistic frame is degraded is device-dependent (Device QA 3). Difference from the reviewer: instead of `acceptsDegradedResult = false` alone, which would blank iCloud-only thumbnails, thumbnails of 200 px or more wait for the final image, fall back to the remembered degraded frame, and never cache it. Preview uses a context menu plus an accessibility action. |
| SCAN-16 | confirmed | Matches the verifier. Implemented exactly as proposed (`isCacheable`, coalescing kept). WS-51 extends it to review and fullscreen. |
