# Chapter 09 — Bulk reclaim: screenshots, videos, compression and a byte-led Home

> **Milestone(s):** M2 · **Workstreams:** WS-41 – WS-45 · Read `spec/README.md` first: operating rules, invariants, build/test commands and the decision log apply to every workstream here.

## Chapter overview

These five workstreams make the categories that hold most of a library's bytes practical to clear.

- **WS-41 (screenshots and blurry):** a free swipe review, plus Pro Select All / Select Month.
- **WS-42 (videos):** covers every video by threshold and kind, including screen recordings of any size. Slo-mo is sized correctly, and Pro users can delete many videos with one system prompt.
- **WS-43 (compression safety):** Compress & Replace becomes one atomic PhotoKit transaction that keeps albums and metadata.
- **WS-44 (compression UX):** compression survives screen lock and explains its trade-offs before it starts.
- **WS-45 (Home):** Home is ordered by device-reclaimable bytes, and its CTA never pauses a scan.

The key risk is deletion safety. Every new bulk path must:
- go through `DeletionManager.delete(assets:)` with explicit IDs;
- show the D-GATING lock before any selection effort.

The compression swap is the only deletion outside `DeletionManager`. It must be proven atomic on a device before it ships.

Tracks (README §2): WS-41 and WS-42 are Track A. WS-43, WS-44 and WS-45 are Track B. WS-42 therefore lands long before WS-43, which is why WS-42 carries its own slo-mo compression refusal (WS-42.5).

Types from earlier workstreams that this chapter consumes. Names follow their chapters; if the landed name differs, use the landed one and note it under Deviations.

| Type / API | From | Used by |
|---|---|---|
| `DeletionManager.delete(assets:) async throws -> DeletionResult` (`.deleted(DeletionReceipt)` / `.declined`), `DeletionReceipt.assetIDs` | WS-11 (ch. 03) | WS-41, WS-42 |
| `SwipeModeViewModel` commit outcome, committed/kept-ID exclusion, `UserKeepDecisionStore` | WS-12 (ch. 03) | WS-41 |
| `PhotoThumbnailView` | WS-14 (ch. 03) | WS-41 |
| `LargeVideoScanController` | WS-16 (ch. 04) | WS-42 |
| `LargeVideoScanController.excludeAndRemoveFiles(_:)` and its publish-path filter; `DeletionManager.confirmedDeletions` | WS-21 (ch. 04) | WS-41, WS-42 |
| `LargeVideoReviewModel.swift`, `LargeVideoRowViews.swift`, `Views/Photos/PhotoCategoryReviewView.swift` | WS-10 (ch. 02) | WS-41, WS-42 |
| `startPhotoScan(from: PhotoScanEntryPoint)`, which routes to `refreshPhotoScan()` (incremental) or `rescanEntireLibrary()` (only `.gearRescanConfirmed`) | WS-26 (ch. 06) | WS-45 |
| `LargeVideoResultCache` single-flight load, revision guard, synchronous writes, `savedAt`-preserving `remove`; `isVideoPassRunning`, `isVideoPrePassRunning`, `videoPassProgressLabel` | WS-27 (ch. 06) | WS-42, WS-45 |
| `BackgroundTaskLease` (`Utilities/BackgroundTaskLease.swift`, `init(name:)`, `end()`) | WS-28 (ch. 06) | WS-44 |
| `IdleTimerCoordinator.shared.acquire(reason:) -> Token`, `release(_ token: Token?)`, test seam `init(apply:)` | WS-29 (ch. 06) | WS-44 |
| `videoSizeProbe(version:allowNetworkAccess:) -> VideoSizeProbe` (`.measured(Int64)` / `.composition` / `.iCloudOnly` / `.unavailable`), `AssetStorageLocation` (`.onDevice` / `.partial` / `.iCloudOnly` / `.unknown`; `.partial` counts as on-device) on `LargeFile.storageLocation` and `CachedLargeVideoResult.storageLocation`, the `revalidateLocality: Bool` flag on `scan(revalidateLocality:onUpdate:)` and `FileRepresentativeResolver = (PHAsset, Bool)` (renamed `remeasureEstimates` by WS-42), `ReclaimSizing`, per-asset measured-or-estimated bytes | WS-30 (ch. 07) | all |
| `ScanOutcomeSummary` (`PrimaryAction`: `.route(HomeRoute)` / `.done`), `ScanOutcomeInputs`, `CleanupOpportunity` with nested `CleanupOpportunity.Kind`, `HomeRoute`, `HomeRouteDestinationView`, `HomeDashboardPresentation`, `HomeCTAAction`, `CountText`, `ByteText` | WS-31 (ch. 07) | WS-41, WS-42, WS-45 |
| `DeletionManager.recordCompressionSavings(originalBytes:outputBytes:)` (forwards to `CleanupStatsStore` in `Engines/CleanupStats.swift`), the "On this iPhone" and "Sent to Recently Deleted" stats, removal of `reclaimablePercent` | WS-32 (ch. 07) | WS-44, WS-45 |
| `CleanupAccessPolicy`: `CleanupAction` (`.bulkSelect(BulkSelectSurface)`, `.manualDelete(ManualDeleteSurface, count:)`, `.duckModeCommit(count:)`, `.compressVideo`), `purchaseManager.canUse(_:)` / `accessDecision(for:)`, `PaywallRequest` + `.paywallGate`, `VideoCompressionStartGate` | WS-36 (ch. 08) | WS-41, WS-42, WS-43, WS-44 |

---

## WS-41 — Screenshots and blurry at scale

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M2 | M | WS-12, WS-14, WS-36 | no | `ws/41-screenshots-at-scale` |

**Primary files:**
- Views: `iOSCleanup/Views/Photos/PhotoCategoryReviewView.swift` (moved out of `HomeView.swift` by WS-10), `iOSCleanup/Views/Photos/CategorySelectionModel.swift` (*new*), `iOSCleanup/Views/Photos/SwipeQueueBuilder.swift` (*new*), `iOSCleanup/Views/Photos/SwipeModeViewModel.swift`, `iOSCleanup/Views/Photos/SwipeModeView.swift`, `iOSCleanup/Views/HomeView.swift`, `iOSCleanup/Views/Home/HomeRouteDestinationView.swift` (WS-31; the category call sites)
- Store: none. WS-36 already defines every `CleanupAction` case this workstream calls.
- Tests: `iOSCleanupTests/CategorySelectionModelTests.swift` (*new*), `iOSCleanupTests/SwipeQueueBuilderTests.swift` (*new*), `iOSCleanupTests/Support/TestPhotoAsset.swift`
- Project and docs: `iOSCleanup.xcodeproj/project.pbxproj`, `CLAUDE.md`

**Findings covered:** VALUE-07 (P1, confirmed; merged: UI-11 confirmed)

**Decisions applied:**
- **D-GATING:** Select All, Select Month and "Older than 30 days" are Pro. Their lock shows on the control itself, before any selection. A swipe-review commit of screenshots or blurry photos is free.
- **D-FAVORITES-USER:** favorites are excluded from every bulk selection and carry a badge. A manual tap or a swipe may still delete them.
- **D-SCOPE:** bulk screenshots/blurry with a free swipe review is v1.
- **D-UNDO:** commits use WS-11's `delete(assets:)`. The iOS confirmation appears immediately, the user gets a receipt toast, and there is no undo window.

### Goal
A user with 2,500 screenshots can clear them without 2,500 tap-and-confirm cycles:
- **Free users** swipe through the category in Duck Mode and commit with one Photos confirmation.
- **Pro users** can select the whole category, one month, or everything older than 30 days in one tap.

The category header shows the count and total bytes (≈ when estimated). Favorites are never swept up by a bulk selection. Nothing is pre-selected on entry. Selection state lives in a small, testable model that keeps a running byte total instead of rescanning the grid on every render (this is PERF-11 item 2, so WS-50 only memoizes `PhotoResultsView` and `ExportAlbumView`).

### Current behavior (verified)
- **The category grid is tap-only.** `iOSCleanup/Views/HomeView.swift:1086-1291` holds `private struct PhotoCategoryReviewView`; WS-10 moves it to `Views/Photos/PhotoCategoryReviewView.swift`, so re-find it by name. The grid only toggles one tile per tap (`toggleSelection(for:)`, 1173-1177 and 1271-1278). There is no Select All, no month section, no sort, no favorites handling and no category byte total.
- **Derived state is recomputed on every render.** `categoryAssets` recomputes `PhotoAssetIdentity.unique(assets)` in every body evaluation. `selectedAssets` and `selectedBytes` filter and reduce the whole array each time (1106-1117).
- **The Pro lock appears after the effort.** The action bar (1219-1261) runs `if selectedAssetIDs.count > 1, !purchaseManager.isPurchased { showPaywall = true }`, so the lock shows only after two or more items are selected. WS-36.4 replaces this with a commit-time decision, `purchaseManager.accessDecision(for: .manualDelete(surface, count: selected))`, a `let surface: ManualDeleteSurface` passed by the tiles, a `PaywallRequest` with `resume`, and a caption visible from the first render. Keep that lock-before-effort behavior: selecting is never blocked, and only the commit control locks.
- **Deletion is already one call:** `deleteSelectedAssets()` (1280-1290) calls `deletionManager.delete(assets:)` once with the explicit selection.
- **Home tiles show counts only.** The Screenshots tile (645-663) and Blurry tile (665-683) show a count and no bytes; only Large Videos gets `sizeBadge` (713-714).
- **Duck Mode only handles groups.**
  - `iOSCleanup/Views/Photos/SwipeModeViewModel.swift:10-20`: `QueueEntry.asset(PHAsset, groupID: UUID)`, where groupID is not optional.
  - `buildQueue(from:)` (272-340) queues only `deleteCandidateIDs` of `group.isAutoCleanEligible` groups (292-294). Screenshots can never reach Duck Mode.
  - The only initializer is `init(groups:)` (63-66). `SwipeModeView.init(groups:)` is at `SwipeModeView.swift:11-14`, and its only call site is `PhotoDuckShellView.swift:279`.
- **Feedback already accepts no group:** `PhotoFeedbackStore.recordSwipeDecision(asset:groupID: UUID? = nil, kind:stage:note:)` (`PhotoFeedbackStore.swift:197-203`).
- **The category type exists:** `enum PhotoReviewCategory { case screenshot, blurry }` at `iOSCleanup/Engines/PhotoScanEngine.swift:1742`.
- **SwipeModeViewModel will have changed by then.** WS-11 and WS-12 remove `restoreUndoneAssets`/`optimisticallyCommittedAssets`, make `commitDeletes` return an outcome, and exclude committed and user-kept IDs in `buildQueue`. Build on that shape, not on the lines above.

### Implementation plan

**WS-41.1 — `CategorySelectionModel` (new file)**
- **Why:** selection work is O(n) per render today. At 3,500 screenshots, taps lag and a Select All would re-reduce 3,500 sizes on every render. It also has to be unit-testable.
- **Change:** create `iOSCleanup/Views/Photos/CategorySelectionModel.swift`:

```swift
enum CategorySortOrder: String, CaseIterable, Identifiable {
    case oldest, newest, largest
    var id: Self { self }
    static func storageKey(for category: PhotoReviewCategory) -> String   // "photoduck.category-sort.screenshot" / ".blurry"
}
struct CategoryAssetSize: Equatable, Sendable { let bytes: Int64; let isEstimated: Bool }
struct CategoryMonthSection: Identifiable, Equatable {
    let id: String              // "2024-03", "largest", "date-unknown"
    let title: String           // "March 2024" via Date.FormatStyle .dateTime.month(.wide).year()
    let assetIDs: [String]      // display order
    let bytes: Int64
    let bulkSelectableIDs: [String]   // non-favorites only
}
enum CategorySelectionChange: Equatable { case selected, deselected }   // selection is never gated (WS-36 lock-before-effort)

enum CategorySelection {        // pure helpers, unit-tested directly
    static func sections(assets: [PHAsset], sizes: [String: CategoryAssetSize],
                         sort: CategorySortOrder, calendar: Calendar) -> [CategoryMonthSection]
    static func olderThanIDs(_ assets: [PHAsset], days: Int, now: Date, calendar: Calendar) -> [String]
}

@MainActor final class CategorySelectionModel: ObservableObject {
    @Published private(set) var sections: [CategoryMonthSection] = []
    @Published private(set) var selectedIDs: Set<String> = []
    @Published private(set) var selectedBytes: Int64 = 0
    @Published private(set) var selectedEstimatedCount = 0
    private(set) var orderedAssets: [PHAsset] = []   // unique, display order
    private(set) var totalBytes: Int64 = 0
    private(set) var totalIsEstimated = false
    var sortOrder: CategorySortOrder = .oldest { didSet { if sortOrder != oldValue { rebuildSections() } } }
    init(sizer: @escaping (PHAsset) -> CategoryAssetSize = CategoryAssetSize.live,
         calendar: Calendar = .current, now: @escaping () -> Date = Date.init)
    func configure(assets: [PHAsset])                 // dedupe; drop vanished selections; NEVER adds
    func toggle(_ id: String) -> CategorySelectionChange
    func selectAll(); func selectMonth(_ sectionID: String); func selectOlderThan(days: Int)
    func clear(); func deselect(_ ids: Set<String>)
    func selectedAssetsInDisplayOrder() -> [PHAsset]
}
```

- **Running total:** every mutation computes a local `Set` delta, adjusts `selectedBytes` and `selectedEstimatedCount` for the added or removed IDs only, and assigns the `@Published` properties once per operation. `configure` computes `sizes` once, not per render.
- **Sizes:** `CategoryAssetSize.live` reads WS-30's per-asset measured-or-estimated bytes. If WS-30 only exposed `estimatedFileSize`, return `isEstimated: true`.
- **Favorites:** `selectAll`, `selectMonth` and `selectOlderThan` insert only non-favorites (`!asset.isFavorite`). `toggle` may select a favorite, because that is user-authored (D-FAVORITES-USER).
- **`toggle(_:)`:** if the ID is selected, deselect it; otherwise select it. There is no entitlement input. Free users may select any number of tiles, because a selection also feeds the free "Add to Export" chip. Only the commit control locks (WS-41.2, step 8).
- **Sorting:**
  - `.oldest` and `.newest` give one section per calendar month (by `creationDate`), with months and tiles in that order and ties broken by `localIdentifier`.
  - `.largest` gives a single section titled "Largest first", sorted by bytes descending, then `creationDate` descending, then ID.
  - Assets with a nil `creationDate` go into a final "Date unknown" section for the date sorts, and are excluded from `olderThanIDs`.
- **Edge cases:**
  - Duplicate `PHAsset` objects in the input: keep the first per `localIdentifier`.
  - `configure` called after a deletion: remove vanished IDs from the selection and subtract their bytes.
  - Empty input gives no sections.

**WS-41.2 — `PhotoCategoryReviewView`: sections, bulk controls, header and commit**
- **Why:** paid users otherwise need 3,500 taps. Free users see no bulk option. Favorites are unprotected, and there is no byte total.
- **Change** (edit `Views/Photos/PhotoCategoryReviewView.swift`; keep the file small by putting the section header in a private `CategoryMonthHeader` view in the same file):
  1. Replace WS-36.4's `let surface: ManualDeleteSurface` parameter with `let category: PhotoReviewCategory`. Keep `title`, `subtitle` and `assets`. Derive both policy surfaces from the category with an exhaustive `switch` (no `default`), in a small extension in this file:
     ```swift
     extension PhotoReviewCategory {
         var manualDeleteSurface: ManualDeleteSurface { switch self { case .screenshot: return .screenshots; case .blurry: return .blurry } }
         var bulkSelectSurface: BulkSelectSurface { switch self { case .screenshot: return .screenshots; case .blurry: return .blurry } }
     }
     ```
     WS-59 adds `.largePhoto` here, mapped to `.largePhotos` in both.
  2. Add `@StateObject private var selection = CategorySelectionModel()`.
  3. Add the sort key as an `AppStorage` created in `init`: `_sortRaw = AppStorage(wrappedValue: CategorySortOrder.oldest.rawValue, CategorySortOrder.storageKey(for: category))`. Apply it with `.onAppear` and `.onChange(of: sortRaw)`.
  4. Configure the model with `.onAppear { selection.configure(assets: assets) }` and `.onChange(of: assets.identifierSignature) { _ in selection.configure(assets: assets) }`. `identifierSignature` is already defined at `HomeViewModel.swift:2586`.
  5. **Header card:**
     - First line: "2,341 screenshots · ≈2.1 GB". Use WS-31's `CountText` and `ByteText.approximate(_:isEstimated:)`, with "≈" when `totalIsEstimated`.
     - Primary button (WS-41.4): "Swipe through screenshots" or "Swipe through blurry photos".
     - Keep the existing "Add to Export" chip. Its count comes from `selection.selectedIDs.count`.
  6. **Toolbar `Menu`** (trailing):
     - a `Picker` for sort (Oldest first / Newest first / Largest first);
     - "Select All (N)", where N counts only non-favorites;
     - "Select Older Than 30 Days";
     - "Clear Selection", enabled only when something is selected.
     - For users without the bulk entitlement, both select items show `lock.fill` from the first render and open the paywall instead of selecting (step 8).
  7. **Grid:** `LazyVGrid(columns:, spacing: 4, pinnedViews: [.sectionHeaders])` with one `Section` per `selection.sections` entry.
     - The header shows "March 2024 · 214 · ≈180 MB" plus a "Select month" button, with a lock for free users. Hide the button when the sort is `.largest`.
     - Tiles use WS-14's `PhotoThumbnailView` (keep its long-press Preview and accessibility label). Add the selection check and a `heart.fill` badge when `asset.isFavorite`; append ", favorite" to the accessibility label.
  8. **Gating** (WS-36's cases exactly; never check `isPurchased` inline):
     - **Bulk controls** (Select All, Select Month, Select Older Than 30 Days) switch on `purchaseManager.accessDecision(for: .bulkSelect(category.bulkSelectSurface))`. `.allowed` selects. `.requiresUnlock(f)` sets `paywallRequest = PaywallRequest(feature: f, resume: { <the same selection call> })` and selects nothing.
     - **Tile taps** always call `selection.toggle(id)`. They are never gated.
     - **Commit** keeps WS-36.4's decision, `accessDecision(for: .manualDelete(category.manualDeleteSurface, count: selection.selectedIDs.count))`. `.requiresUnlock(f)` shows the lock glyph and "· Pro", and a tap sets `PaywallRequest(feature: f, resume: { Task { await deleteSelectedAssets() } })`. Keep WS-36.4's first-render caption.
  9. **Commit:** the action bar keeps its layout. The label becomes "Delete N · ≈X".
     - On tap, take `let assets = selection.selectedAssetsInDisplayOrder()` and call `try await deletionManager.delete(assets: assets)` once.
     - `.deleted(receipt)` → `selection.deselect(receipt.assetIDs)`. `.declined` → keep the selection.
     - A thrown error → the existing alert. Ignore a benign cancellation via `FileDeletionErrorPolicy.isBenignCancellation`.
     - While awaiting, show a blocking overlay: "Moving N items to Recently Deleted… Keep PhotoDuck open."
- **Edge cases:**
  - WS-21 removes deleted assets from `HomeViewModel.screenshotAssets` and `blurryAssets`. The `.onChange` above then reconfigures the model, and vanished IDs leave the selection.
  - A selection larger than 1,000: no cap in this workstream. See Device QA step 3, and apply WS-12's `AutoCleanPlanner` asset cap only if that step fails.
  - Nothing is pre-selected on entry or after a sort change.

**WS-41.3 — `SwipeQueueSource` and a pure queue builder**
- **Why:** Duck Mode, the free bulk path, only accepts auto-clean-eligible groups, so screenshots and blurry photos can't be swiped.
- **Change:**
  1. In `SwipeModeViewModel.swift`, add:
     ```swift
     enum SwipeQueueSource {
         case groups([PhotoGroup])
         case assets([PHAsset], category: PhotoReviewCategory)
     }
     ```
     Change `QueueEntry.asset(PHAsset, groupID: UUID?)` and every stored `groupID` (swipe history, `toDeleteGroupIDsByAssetID`) to `UUID?`.
  2. Add the designated `init(source: SwipeQueueSource, …WS-12's injected dependencies…)` and keep `convenience init(groups: [PhotoGroup])`, which forwards `.groups(groups)`.
  3. Create `iOSCleanup/Views/Photos/SwipeQueueBuilder.swift`:
     ```swift
     struct SwipeQueueBuild { let entries: [SwipeModeViewModel.QueueEntry]; let fileSizeByAssetID: [String: Int64]; let reviewableCount: Int }
     enum SwipeQueueBuilder {
         static func build(source: SwipeQueueSource, excludedIDs: Set<String>,
                           sizeOf: (PHAsset) -> Int64, calendar: Calendar) -> SwipeQueueBuild
     }
     ```
     - **`.groups`:** move the existing (WS-12-updated) group logic here verbatim: eligible groups only, keeper never queued, `deleteCandidateIDs` only, chronological order, month headers.
     - **`.assets`:** `PhotoAssetIdentity.unique`, drop `excludedIDs` (WS-12's committed plus user-kept IDs), sort ascending by `creationDate` then `localIdentifier`, add month headers the same way, and `groupID` = nil. Favorites are included; a swipe is user-authored.
     - `buildQueue` and `resetQueue` call the builder.
  4. **Feedback:** `commit(.keep)` and the commit loop pass the optional `groupID` straight to `recordSwipeDecision` (nil for assets). `keepStore.markKept` (WS-12) is called for asset-source keeps too.
  5. **`SwipeModeView`:**
     - Add `init(source:)` and keep `init(groups:)`.
     - The navigation title is "Duck Mode" for `.groups`, and "Screenshots" or "Blurry Photos" for `.assets`.
     - Pass `asset.isFavorite` to `DuckAssetCard` and render a small "Favorite" `StatusBadge` on the card. This is a functional badge, not a redesign.
- **DECISION (owner may override):** a swipe "Keep" on a screenshot or blurry photo is written to `UserKeepDecisionStore`, like group keeps. Later category swipe queues skip those IDs. The grid still shows them, and WS-12's "Reset kept photos" restores them.
- **Edge cases:**
  - An empty asset source: the queue is complete immediately and the completion view says there is nothing to review.
  - A source asset deleted elsewhere mid-review: WS-11 resolves IDs at commit and drops missing ones.
  - `WS-51` later adds `upcomingAssets()`; keep queue access inside the view model.

**WS-41.4 — "Swipe through …" entry point**
- **Why:** the free bulk path has to be discoverable where the screenshots are.
- **Change:**
  - In `PhotoCategoryReviewView`, add `@State private var showSwipe = false` and the header button (WS-41.2, step 5).
  - Present `.fullScreenCover(isPresented: $showSwipe) { SwipeModeView(source: .assets(selection.orderedAssets, category: category)) }`, with the same environment objects and receipt-toast modifier that `PhotoDuckShellView` attaches to its Duck Mode cover (after WS-11/WS-12: `deletionManager`, `purchaseManager`, the keep store).
  - The button is free: no policy call. D-GATING lists "Duck Mode commits including a screenshot/blurry swipe queue" as free.
  - Disable it when `orderedAssets` is empty.
- **Edge cases:** swipe review ignores any grid selection. After the cover dismisses, the grid reconfigures through WS-21's removal.

**WS-41.5 — Home tiles and docs**
- **Why:** the tiles should show bytes (VALUE-07, item 3), and the view needs the category.
- **Change:**
  - In `HomeView.categoryGrid` and in WS-31's `HomeRouteDestinationView` (`.screenshots` / `.blurry` routes), pass `category: .screenshot` / `.blurry` to `PhotoCategoryReviewView` in place of WS-36's `surface:`.
  - Set `sizeBadge` on the Screenshots and Blurry tiles from WS-31's opportunities (`CleanupOpportunity.Kind.screenshots` / `.blurry`, `ByteText.approximate(opportunity.sizing)`, so "≈" when estimated). WS-45 later rebuilds the whole grid; keep this change to those two tiles.
  - Update `ios-cleanup/CLAUDE.md`:
    - the Free list: "Duck Mode swipe commits, including swipe review of screenshots and blurry photos";
    - the "Screenshots and blurry photos" constraint: "Select All / Month exclude favorites and require Pro; nothing is pre-selected";
    - the `SwipeModeViewModel` line: "queue built from groups or from a screenshot/blurry asset list".

### Tests
All tests run in the simulator. Use `TestPhotoAsset` (`iOSCleanupTests/Support/TestPhotoAsset.swift`, from WS-03); if it lacks `creationDate` or `isFavorite` overrides, add them there.

**`iOSCleanupTests/CategorySelectionModelTests.swift`** (new). Inject `sizer`, a fixed `calendar` (gregorian, UTC) and `now`.
- `testConfigureSelectsNothing`: after `configure`, `selectedIDs` is empty and `selectedBytes == 0`.
- `testConfigureDeduplicatesByLocalIdentifier`: two objects with the same ID give one tile and `totalBytes` counted once.
- `testOldestSortGroupsByCalendarMonthAscending` and `testNewestSortGroupsByCalendarMonthDescending`: section IDs, titles and asset order.
- `testUnknownDatesGoLastAndAreNeverOlderThan`.
- `testLargestSortIsSingleSectionBySizeThenDate`.
- `testSelectAllExcludesFavorites`, `testSelectMonthSelectsOnlyThatMonthWithoutFavorites` and `testSelectOlderThan30DaysUsesInjectedNow`, which checks the boundary: exactly 30 days old is not selected, 30 days plus 1 s is.
- `testManualToggleCanSelectFavorite`.
- `testToggleNeverBlocksMultipleSelection`: toggling three IDs gives `.selected` three times and `selectedIDs.count == 3`; toggling one again gives `.deselected`.
- `testRunningTotalMatchesRecomputation`: run a scripted sequence of 30 operations (toggle, selectMonth, deselect, clear, reconfigure). After each one, assert `selectedBytes == sizes(selectedIDs).sum` and that `selectedEstimatedCount` matches.
- `testReconfigureDropsVanishedSelectionsAndBytes`.

**`iOSCleanupTests/SwipeQueueBuilderTests.swift`** (new)
- `testAssetSourceQueuesEveryAssetOnceWithMonthHeaders`: three assets across two months give header, a, b, header, c; `reviewableCount == 3`; every `groupID` is nil.
- `testAssetSourceExcludesKeptAndCommittedIDs`.
- `testAssetSourceIncludesFavorites`.
- `testGroupSourceMatchesPreviousBehavior`: move or duplicate WS-12's group queue assertions (eligible-only, no keeper, no visuallySimilar) so the refactor is pinned.

**`SwipeModeViewModel` with `.assets`** (in WS-12's view-model test file, using its injected deleter). These go through `DeletionManager` and WS-03's `PhotoLibraryDeleting` fake.
- `testAssetSourceCommitDeletesExactlyLeftSwipedAssetsInOneCall`: 5 assets; swipe L, R, L, L, R; commit. The fake deleter receives exactly 3 IDs in one call.
- `testAssetSourceUndoLastSwipeRemovesPendingDelete`.
- `testAssetSourceKeepMarksUserKeepStore`.

**`CleanupAccessPolicyTests`** (no new policy case; WS-36's suite already covers `.bulkSelect` and `.manualDelete`)
- `testDuckModeCommitOf500IsFree`: `.duckModeCommit(count: 500)` is `.allowed` for a free user. Add it only if WS-36's suite has no equivalent.
- `testCategorySurfacesMapExhaustively`: `.screenshot` → `.screenshots`/`.screenshots`, `.blurry` → `.blurry`/`.blurry`.

Device-only: Device QA below.

### Acceptance criteria
- [ ] A free user can open Screenshots, tap "Swipe through screenshots", swipe 500 left, commit, and see exactly one Photos confirmation (Device QA 1). `testAssetSourceCommitDeletesExactlyLeftSwipedAssetsInOneCall` is green.
- [ ] For a free user, Select All, Select Month and Older than 30 days show a lock and open the paywall without selecting anything. For a Pro user, Select Month selects that month's non-favorites in one tap.
- [ ] A free user can tap-select any number of tiles (for Add to Export). The Delete control shows the lock and "· Pro" once more than one is selected, and WS-36.4's caption shows from the first render. `grep -n "allowsMultiple\|requiresUnlock" iOSCleanup/Views/Photos/CategorySelectionModel.swift` finds nothing.
- [ ] Favorites are never included by a bulk control, and each shows a heart badge.
- [ ] Nothing is selected on entry or after a sort change. The sort choice persists per category across relaunch.
- [ ] The header shows the count and ≈bytes. The Screenshots and Blurry Home tiles show a bytes badge.
- [ ] No `PhotoAssetIdentity.unique` call and no full-array reduce happens in the body of `PhotoCategoryReviewView`. `grep -n "unique(\|reduce" iOSCleanup/Views/Photos/PhotoCategoryReviewView.swift` finds none.
- [ ] All new tests pass, the full suite is green, there are no new warnings, and the new files are in `project.pbxproj`.
- [ ] `CLAUDE.md` is updated (WS-41.5).

### Device QA
Add to `docs/DEVICE_QA.md`:
1. Seed 500+ screenshots (for example with a Shortcuts loop). Sign in as a free user, go to Screenshots, then "Swipe through screenshots". Swipe 500 left and commit. Expect exactly one system prompt, 500 items in Recently Deleted, and the grid updating without a rescan.
2. As a Pro user, use Select Month on a month containing a favorite. Expect the favorite unselected and badged, and the header byte total to match the sum of the selection.
3. With 3,000 screenshots, Select All and Delete. Record the time until the system prompt and until the receipt. If it fails or stalls for more than 10 s, file a follow-up to apply WS-12's per-commit cap.
4. Scroll a 3,000-item grid. It must not visibly stutter, and selection taps must respond immediately.

### Pitfalls and out of scope
- Do not pre-select anything, and do not let bulk controls touch favorites (invariants 7 and 8).
- Gates go through `CleanupAccessPolicy` only (invariant 10). The swipe entry is free.
- Do not change group-source queue semantics. `visuallySimilar` and non-eligible groups stay out of Duck Mode (invariant 2).
- Duck Mode visuals: only the favorite badge is added. No redesign (invariant 29).
- Memoizing `PhotoResultsView` and `ExportAlbumView` is WS-50 (chapter 11). Accessibility actions in Duck Mode are WS-55 (chapter 12). Thumbnail prefetch is WS-51 and WS-52 (chapter 11).
- **Reconciliation (README §9, contract 11 and ch08's lock-before-effort decision):** gating uses WS-36's `CleanupAction` cases exactly: `.bulkSelect(category.bulkSelectSurface)` for Select All/Month/Older, `.manualDelete(category.manualDeleteSurface, count:)` for the commit, and `.duckModeCommit` (free) for swipe review. The earlier `allowsMultiple`/`requiresUnlock` tile gate and the fallback `categoryBulkSelect(count:)` case are removed. WS-36.4's `surface:` parameter becomes `category:`, and the surfaces are derived through an exhaustive switch that WS-59 extends with `.largePhoto`.

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| VALUE-07 | confirmed | All four claims hold: tap-only grid (HomeView.swift:1171-1190), paywall at >1 selected (1222), eligible-groups-only queue (SwipeModeViewModel.swift:292), and a count-only tile (645-663). The plan follows the fix, with these differences: the commit path uses WS-11's typed `DeletionResult`; favorites are included in the swipe queue with a badge (D-FAVORITES-USER); swipe keeps persist to WS-12's store (DECISION). |
| UI-11 (merged) | confirmed | There is no sort and no category total; assets appear in scan order. The helpers live in `CategorySelection`/`CategorySelectionModel` rather than as static functions on the view. The default sort is Oldest first. "Largest first" is a single section. |

---

## WS-42 — Large videos: bulk delete, full coverage, screen recordings, correct slo-mo sizes

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M2 | L | WS-21, WS-27, WS-30, WS-31, WS-36 | no | `ws/42-video-coverage` |

**Primary files:**
- Models and engines: `iOSCleanup/Models/LargeFile.swift`, `iOSCleanup/Models/VideoInventory.swift` (*new*), `iOSCleanup/Engines/FileScanEngine.swift`, `iOSCleanup/Engines/ScreenRecordingAlbumCrossCheck.swift` (*new*, DEBUG)
- Utilities: `iOSCleanup/Utilities/VideoSizeMeasurement.swift` (*new*), `iOSCleanup/Utilities/PHAsset+FileSize.swift`
- Home: `iOSCleanup/Views/Home/LargeVideoScanController.swift`, `iOSCleanup/Views/Home/ScanOutcomeSummary.swift`, `iOSCleanup/Views/Home/HomeRouteDestinationView.swift`, `iOSCleanup/Views/HomeView.swift`, `iOSCleanup/Views/HomeViewModel.swift` (pass-throughs only)
- Files views: `iOSCleanup/Views/Files/FileResultsView.swift`, `iOSCleanup/Views/Files/LargeVideoReviewModel.swift`, `iOSCleanup/Views/Files/LargeVideoRowViews.swift`, `iOSCleanup/Views/Files/LargeVideoFilter.swift` (*new*), `iOSCleanup/Views/Files/LargeVideoFilterBar.swift` (*new*), `iOSCleanup/Views/Files/LargeVideoDeletionPlan.swift` (*new*), `iOSCleanup/Views/Files/LargeVideoCompressionAvailability.swift` (*new*), `iOSCleanup/Views/Files/VideoCompressionView.swift` (a 5-line guard)
- Tests: `iOSCleanupTests/FileScanEngineTests.swift` (or the file WS-03 split the large-video tests into), `iOSCleanupTests/LargeVideoInventoryTests.swift` (*new*), `iOSCleanupTests/VideoSizeMeasurementTests.swift` (*new*), plus the WS-16/WS-27/WS-30/WS-31 tests listed under "Earlier tests this workstream updates" in the Tests section (`LargeVideoScanControllerTests.swift`, `HomeViewModelTests.swift`, `LargeVideoLocalityTests.swift`, `ScanOutcomeSummaryTests.swift`)
- Project: `project.pbxproj`

**Findings covered:** VALUE-06 (P1, confirmed), VALUE-13 (P2, partially; merged: FILES-20 confirmed, FSB-06 confirmed), FILES-04 (P1, confirmed)

**Decisions applied:**
- **D-SCOPE:** all-video thresholds and kinds, screen recordings of any size via `PHAssetMediaSubtype.videoScreenRecording`, and multi-delete are v1. Duplicate videos are WS-62.
- **D-GATING:** deleting one video is free. Multi-delete of large videos or screen recordings is Pro, and the lock and note are visible as soon as Select is entered.
- **D-UNDO:** a multi-delete makes one `delete(assets:)` call, which shows one system prompt, and produces a receipt.

### Goal
Everyone sees all their video storage:
- a total for all videos;
- a threshold chooser (50 MB / 100 MB / 500 MB / 1 GB, default 100 MB, persisted);
- kind filters (Screen recordings, Slo-mo, Time-lapse, Cinematic);
- screen recordings listed at any size, as their own Home tile;
- slo-mo sized from the stored original;
- estimated sizes re-measured on an explicit refresh.

Pro users can select many videos and delete them with one Photos confirmation. Compress is not offered for slo-mo. Now that slo-mo sizes are measured, the accidental `unverifiedOriginalSize` guard no longer protects slo-mo from being flattened, so the refusal ships here.

This PR can be split into two if it goes over about 1,500 lines:
- **(a) data:** WS-42.1–42.4 and 42.8;
- **(b) UI:** WS-42.5–42.7.

### Current behavior (verified)
- **Everything under 100 MB is dropped.**
  - `iOSCleanup/Engines/FileScanEngine.swift:88`: `static let minimumFileSizeBytes: Int64 = 100 * 1024 * 1024`.
  - `FileScanPolicy.qualifies(byteSize:)` (261-265) drops everything smaller.
  - The measurement loop (166-245) resolves every video's size and then keeps only qualifying `LargeFile`s. There is no total for all videos.
- **No media kind anywhere.** `LargeFile` (`Models/LargeFile.swift:4-42`) has no kind information. `grep -rn "videoScreenRecording\|smartAlbumScreenRecordings\|videoHighFrameRate" iOSCleanup` finds nothing. The iPhoneOS 26.5 SDK declares `PHAssetMediaSubtypeVideoScreenRecording` (iOS 13, `PhotosTypes.h:155`), `…VideoHighFrameRate` (:153), `…VideoTimelapse` (:154), `…VideoCinematic` (iOS 15, :156) and `PHAssetCollectionSubtypeSmartAlbumScreenRecordings` (iOS 14, :107). No `#available` checks are needed.
- **The result cache.** `CachedLargeVideoResult`/`CachedLargeVideoSnapshot` (`FileScanEngine.swift:267-285`) is schema v1: id, assetIdentifier, displayName, byteSize, byteSizeIsEstimated and creationDate, plus totalVideoCount. `LargeVideoResultCache.remove(assetIdentifier:)` (412-435) removes one ID per write. **After WS-27.1/WS-30.4:** the actor has a single-flight `load()`, a `revision` guard, synchronous `commit` writes, `save(files:totalVideoCount:savedAt:)`, a `remove` that keeps `savedAt` (the scan time), and an optional `storageLocation` per result.
- **Size probe.** In `iOSCleanup/Utilities/PHAsset+FileSize.swift:684-716`, `currentVideoURLByteSize` requests `options.version = .current` (693) and accepts only `asset as? AVURLAsset` (697-703). Anything else resolves nil. After 5 s it cancels and returns nil (709-711). **After WS-30:** it is the internal per-version probe `videoSizeProbe(version: PHVideoRequestOptionsVersion = .current, allowNetworkAccess: Bool = false) async -> VideoSizeProbe` (`.measured(Int64)` / `.composition` / `.iCloudOnly` / `.unavailable`) on `PhotoKitRequestState<VideoSizeProbe>`. `representativeFile` still calls it with `.current` only. `FileRepresentativeResolver` is `@Sendable (_ asset: PHAsset, _ revalidateLocality: Bool) async -> PHAssetRepresentativeFile`, `scan(revalidateLocality:onUpdate:)` exists (there is no `FileScanOptions`), and `representativeFile(allowNetworkAccess:revalidateLocality:)` re-probes a video when the flag is set or its `locationCheckedAt` is older than `AssetLocalityPolicy.recheckInterval`. WS-30's forward note hands the flag's rename to this workstream.
- **Fallback estimate.** With nil, `AssetResourceSizePolicy.resolveByteCount` (153-179) falls to `estimatedByteCount`, which assumes 12 Mbps for 2–8 MP video (202).
- **Estimates are cached forever.** `representativeFile` (611-658) returns any cached record regardless of provenance (616-626). The cache key is (localIdentifier, modificationDate), so an estimate is never re-measured. Provenance has only `measuredCurrentVersion`/`estimated` (269-272).
- **Compression of slo-mo fails.** `VideoCompressionView.loadAVAsset` (`Views/Files/VideoCompressionView.swift:413-415`) leaves the version at the default `.current`. For a slo-mo clip, PhotoKit delivers an `AVComposition` with the time ramp, so `(asset as? AVURLAsset)?.url` is nil. Because the size is an estimate, `resolveOriginalBytes` throws `.unverifiedOriginalSize`. That accident is the only thing that stops a flattening compression today.
- **Selection mode is export-only.** In `iOSCleanup/Views/Files/FileResultsView.swift`, `selectedExportActionBar` (841-969) offers only "Export N Selected…" and "Add N to Export Album".
- **Delete is per row.** `requestDeletion(of:)` → `deletePhotoLibraryFile` → `deletionManager.deleteImmediately(assets: [asset])` (1290-1311), which is one system prompt per video. After WS-11 this is `delete(assets:)`.
- **Organization.** `LargeVideoOrganization` offers only Size/Year/Month (18-24). The refresh hint says "videos over 100 megabytes" (379).
- **Other readers of `largeFiles`.** `HomeViewModel.largeFiles` feeds:
  - `DashboardCollectionSummary.largeFileBytes` (`HomeViewModel.swift:113`);
  - reclaimable bytes (353);
  - notification copy (815-816, 1517);
  - diagnostics (481, 2431-2432);
  - reconcile (1856, 1884);
  - the Home tile (`HomeView.swift:701-727`).

  WS-16 moves the storage into `LargeVideoScanController`. WS-21 adds `excludeAndRemoveFiles(_ ids: Set<String>) -> Bool`, fed by `DeletionManager.confirmedDeletions`, and filters `update.largeFiles` in the publish path. WS-30's `DashboardCollectionSummary.make(…largeFiles:…)` and `largeVideoSizing`, and WS-31's `ScanOutcomeInputs.largeVideoCount`/`largeVideoSizing`, read the controller's `largeFiles`.

### Implementation plan

**WS-42.1 — `VideoKind` on `LargeFile`**
- **Why:** screen recordings, slo-mo, time-lapse and Cinematic are invisible today. Slo-mo compression must be refused.
- **Change** in `Models/LargeFile.swift`:
  ```swift
  enum VideoKind: String, Codable, Sendable, CaseIterable {
      case standard, screenRecording, slowMotion, timelapse, cinematic
      static func classify(_ subtypes: PHAssetMediaSubtype) -> VideoKind {
          if subtypes.contains(.videoScreenRecording) { return .screenRecording }
          if subtypes.contains(.videoHighFrameRate) { return .slowMotion }
          if subtypes.contains(.videoTimelapse) { return .timelapse }
          if subtypes.contains(.videoCinematic) { return .cinematic }
          return .standard
      }
      var badgeTitle: String? // nil, "Screen recording", "Slo-mo", "Time-lapse", "Cinematic"
  }
  ```
  - Add `let videoKind: VideoKind` to `LargeFile`, with an init parameter defaulting to `.standard` so existing call sites compile.
  - Add `var isScreenRecording: Bool { videoKind == .screenRecording }`.
  - Detection uses media subtypes only. Never use the "RPReplay" filename.

**WS-42.2 — Slo-mo measured from the original; re-measure estimates on explicit refresh**
- **Why:** a 300 MB slo-mo clip is estimated at about 90 MB and never appears. At baseline, estimates and timeouts are cached forever. WS-30 re-probes every 7 days, but only with `.current`, so a slo-mo `.composition` never becomes a measurement.
- **First step (device check):** on a device with one slo-mo clip and one normal clip, log `type(of:)` of the asset delivered for `.current` and `.original` in a DEBUG build. Record the result in the PR. The code below works whichever way PhotoKit behaves.
- **Change:** create `iOSCleanup/Utilities/VideoSizeMeasurement.swift`. It reuses WS-30's per-version probe, `videoSizeProbe(version:allowNetworkAccess:) async -> VideoSizeProbe` (`.measured(Int64)` / `.composition` / `.iCloudOnly` / `.unavailable`). Do not declare a second probe-result enum.
  ```swift
  enum VideoSizeMeasurement {
      /// HFR: ask for .original only. Otherwise .current, and if that is a .composition
      /// (not a file-backed AVURLAsset), retry once with .original.
      static func measure(
          isHighFrameRate: Bool,
          request: (PHVideoRequestOptionsVersion) async -> VideoSizeProbe
      ) async -> (probe: VideoSizeProbe, version: PHVideoRequestOptionsVersion)
  }
  ```
  - In WS-30's `representativeFile`, replace the single `videoSizeProbe(version: .current, allowNetworkAccess:)` call with `VideoSizeMeasurement.measure(isHighFrameRate: mediaSubtypes.contains(.videoHighFrameRate), request: { await self.videoSizeProbe(version: $0, allowNetworkAccess: allowNetworkAccess) })`. WS-30's storage rules for the result are unchanged: `.measured` stores bytes with `.onDevice`, `.iCloudOnly` stores an estimate with `.iCloudOnly`, and a `.composition` that survives the `.original` retry, or `.unavailable`, keeps the previous bytes with `.unknown`.
  - Add the provenance `AssetFileSizeProvenance.measuredOriginalVersion`. Adding a case decodes old stores unchanged. Store it when `version == .original`; `.current` keeps WS-30's `.measuredCurrentVersion`.
- **Change (re-measure):** rename WS-30's single flag. In `PHAsset+FileSize.swift`, `representativeFile(allowNetworkAccess:revalidateLocality:)` becomes `representativeFile(allowNetworkAccess: Bool = false, remeasureEstimates: Bool = false)`. It is the same flag with the same trigger, and it now also forces estimated records to be re-measured. Put the decision in a pure helper in `VideoSizeMeasurement.swift`:
  ```swift
  enum RepresentativeCachePolicy {
      /// true = return the cached record as-is. Keeps WS-30's locality rule and adds the re-measure rule.
      static func usesCachedRecord(_ record: AssetFileSizeRecord, mediaKind: AssetMediaKind,
                                   remeasureEstimates: Bool, now: Date) -> Bool
      // Videos: false when remeasureEstimates (WS-30's revalidateLocality semantics: re-probe on explicit refresh),
      //         or when record.locationCheckedAt is nil or older than AssetLocalityPolicy.recheckInterval (WS-30).
      // Photos and other kinds: WS-30's rules unchanged.
  }
  ```
- **Change (threading):** rename the flag in the engine as well (contract 25):
  - `FileRepresentativeResolver` goes from WS-30's `@Sendable (_ asset: PHAsset, _ revalidateLocality: Bool) async -> PHAssetRepresentativeFile` to `@Sendable (_ asset: PHAsset, _ remeasureEstimates: Bool) async -> PHAssetRepresentativeFile`.
  - `scan(revalidateLocality:onUpdate:)` becomes `scan(remeasureEstimates: Bool = false, onUpdate:)`. There is still only one `scan`.
  - WS-30 threads the flag through `LargeVideoScanController.run`, and it stays `true` only for WS-27's `.userExplicit` trigger (the Refresh button, pull-to-refresh, "Check Videos Now" and "Scan Videos Again"). Every other trigger (`.automaticFreshness`, `.tabVisit`, `.afterPhotoRun`, `.libraryVideoInsertions`, `.userScanPrePass`, `.deferredRequest`) passes `false`.
  - Test resolvers keep the `{ asset, _ in … }` shape from WS-30. Only tests that name or assert the flag change (see Tests).
- **Edge cases:**
  - An iCloud-only video with the network off still ends as `.iCloudOnly` (WS-30's `VideoSizeProbe`) with an estimated size. Keep WS-30's '≈' display and its `storageLocation: .iCloudOnly`.
  - The second request has its own 5 s budget.
  - Keep the `unverifiedOriginalSize` gate in compression unchanged.

**WS-42.3 — Engine retention, inventory, policy and cache v2**
- **Why:** sub-100 MB clips and recordings are thrown away and there is no total for all videos. Changing the threshold in the UI must not need a rescan.
- **Change:** create `iOSCleanup/Models/VideoInventory.swift`:
  ```swift
  enum LargeVideoThreshold {
      static let retentionFloorBytes: Int64 = 50_000_000
      static let options: [Int64] = [50_000_000, 100_000_000, 500_000_000, 1_000_000_000]
      static let defaultMinimumBytes: Int64 = 100_000_000
      static let userDefaultsKey = "photoduck.large-videos.minimum-bytes"
      static let maximumRetainedResults = 10_000
      static func sanitized(_ raw: Int64) -> Int64      // unknown value -> default
  }
  struct VideoInventorySummary: Codable, Equatable, Sendable {
      var videoCount = 0, estimatedVideoCount = 0
      var totalBytes: Int64 = 0, onDeviceBytes: Int64 = 0, iCloudOnlyBytes: Int64 = 0
      static let empty = VideoInventorySummary()
      mutating func add(bytes: Int64, isEstimated: Bool, location: AssetStorageLocation)   // .onDevice/.partial → onDeviceBytes (WS-30 rule); .iCloudOnly → iCloudOnlyBytes; .unknown → neither
  }
  struct LargeVideoInventoryPartition: Equatable {
      let largeVideos: [LargeFile]       // non-recordings with byteSize >= minimumBytes
      let screenRecordings: [LargeFile]  // every recording, any size
      static func make(retained: [LargeFile], minimumBytes: Int64) -> Self
  }
  enum LargeVideoRetention {
      /// Keeps every recording (largest first if recordings alone exceed limit), then the largest non-recordings.
      static func capped(_ files: [LargeFile], limit: Int) -> [LargeFile]
  }
  ```
- **Decimal thresholds.** DECISION (owner may override): thresholds are decimal bytes, so "100 MB" matches what `ByteCountFormatter` shows on each row. The default moves from 100 MiB to 100,000,000 bytes, so a few more videos qualify.
- **Policy.** Replace `FileScanPolicy` with:
  - `retains(byteSize:isScreenRecording:)`, true when it is a recording or `byteSize >= retentionFloorBytes`;
  - `qualifies(byteSize:isScreenRecording:minimumBytes: Int64 = LargeVideoThreshold.defaultMinimumBytes)`, true when it is a recording or `byteSize >= minimumBytes`.

  Delete `FileScanEngine.minimumFileSizeBytes` and update every reference in code and tests (README §9, contract 25). Known sites at baseline: `FileScanEngineTests.swift:129` (`testVideoFallbackIsDurationAndResolutionAware`: compare against `LargeVideoThreshold.defaultMinimumBytes`), `:132-135` (`testLargeVideoThresholdIsOneHundredMegabytes`, replaced below), and `:160` (the fixture size in `testVideoScanPublishesMonotonicProgressAndHonestCacheReuse`: use `LargeVideoThreshold.defaultMinimumBytes`). Also grep WS-16's `LargeVideoScanControllerTests`, WS-27's `HomeViewModelTests` and WS-30's `LargeVideoLocalityTests` fixtures, and replace any use with `LargeVideoThreshold`.
- **Scan loop.** In the loop, build each `LargeFile` with `videoKind: VideoKind.classify(asset.mediaSubtypes)` plus WS-30's `storageLocation: representative.storageLocation`.
  - Add every measured video to a `VideoInventorySummary`.
  - Keep a file when `FileScanPolicy.retains`.
  - After the loop, apply `LargeVideoRetention.capped(_, limit: maximumRetainedResults)`.
  - Keep the per-video value creation in one small function (`makeMeasuredVideo`) so WS-62 can add its fingerprint candidate there.
- **Scan result and updates.** `scan(remeasureEstimates:onUpdate:)` returns `struct FileScanResult: Sendable { let retainedVideos: [LargeFile]; let inventory: VideoInventorySummary }`. Rename `FileScanUpdate.largeFiles` to `retainedVideos` and add `inventory: VideoInventorySummary?`, set whenever results publish. Keep the progress and publication stride unchanged. This workstream updates every consumer of the old names (contract 25): WS-16's controller publish path, WS-21's `excludedAssetIDs` filter (now over `update.retainedVideos`), WS-27's `run(budget:)` and `FileScanDecision` code, and WS-30's scan call sites.
- **Cache v2:**
  - `CachedLargeVideoSnapshot.schemaVersion = 2`.
  - Add `inventory: VideoInventorySummary`. Add `videoKind: VideoKind` to `CachedLargeVideoResult`, and keep WS-30's `storageLocation: AssetStorageLocation?` field.
  - `save` becomes `save(files: [LargeFile], inventory: VideoInventorySummary, savedAt: Date = Date())`. It keeps WS-27's synchronous `commit`. `totalVideoCount` is now `inventory.videoCount`, and WS-27's restore re-save passes `restored.savedAt`.
  - A v1 file fails the existing `schemaVersion ==` check (inside WS-27's `decodeSnapshot(at:)`) and is treated as a miss. There is no migration, because v1 lacks sub-100 MB files and kinds. The rescan is cheap because sizes are cached per asset in `AssetFileSizeRepository`.
  - Replace WS-27's `remove(assetIdentifier:)` with `remove(assetIdentifiers: Set<String>)`. It keeps WS-27's shape exactly: `_ = await load()` is the only suspension point, it reads `cachedSnapshot` after the await, returns without writing when nothing matched, and makes one `commit` that subtracts the removed bytes and count from `inventory` and **keeps `savedAt`** (the scan time, not the removal time).
  - Keep WS-27's single-flight `load()`, `revision` guard, synchronous `commit` writes and `decodeSnapshot`/`write` helpers unchanged, and WS-20's `canPersist` check ("no cache writes under Limited access").
- **Edge cases:**
  - A library with 0 videos gives an empty result, an empty inventory and the existing message.
  - The cap only matters for libraries with more than 10,000 videos of 50 MB or more.

**WS-42.4 — Controller partition, threshold and batch removal**
- **Why:** every existing reader of `largeFiles` (Home tile, reclaimable bytes, WS-31 opportunities, WS-32 storage split, notifications, diagnostics) must keep meaning "large videos at the chosen threshold". Recordings must not be double-counted.
- **Change** in `LargeVideoScanController`:
  - `retainedVideos` becomes the source of truth. It is what the engine publishes and the cache persists.
  - Add `@Published var largeVideoMinimumBytes: Int64`, read from and written to `dependencies.defaults` under `LargeVideoThreshold.userDefaultsKey` and sanitized.
  - Keep `largeFiles` as a derived, published array: `partition.largeVideos`. Add `screenRecordings` and `videoInventory`.
  - Re-partition in `didSet` of `retainedVideos` and `largeVideoMinimumBytes`, and trigger the existing summary rebuild hook (WS-16).
  - Batch removal reuses WS-21's `excludeAndRemoveFiles(_ ids: Set<String>) -> Bool` (do not add a second removal API). It now filters `retainedVideos`, adjusts `fileScanProgress` counts, and calls the cache's `remove(assetIdentifiers:)` once, behind WS-20's `canPersist`. WS-16's `removeLargeFileFromResults(assetID:)` forwards to it with a one-element set.
  - The reconcile path (`HomeViewModel.swift:1856-1884`, now WS-21's pruner plus `excludeAndRemoveFiles`) filters `retainedVideos`.
  - `HomeViewModel` gets pass-throughs only (facade rule): `retainedVideos`, `screenRecordings`, `videoInventory`, `largeVideoMinimumBytes` (get/set) and `removeLargeFilesFromResults(assetIDs:)`, a one-line forward to `excludeAndRemoveFiles`. It is idempotent with WS-21's `confirmedDeletions` path, which also removes every receipt ID.
- **DECISION (owner may override):** screen recordings are their own category. They are excluded from the Large Videos tile and bytes, so nothing is counted twice, and they always appear in the Files list whatever the threshold.
- **Edge cases:** changing the threshold never rescans. It re-partitions in memory, which is O(n) over at most 10,000 items.

**WS-42.5 — Files UI: threshold, kinds, totals, badges, slo-mo compress refusal**
- **Why:** users can't see or review anything under 100 MB or by kind. Compress would flatten slo-mo now that its size is measured.
- **Filter model.** Create `iOSCleanup/Views/Files/LargeVideoFilter.swift`:
  ```swift
  enum LargeVideoKindFilter: String, CaseIterable, Identifiable { case all, screenRecordings, slowMotion, timelapse, cinematic }
  struct LargeVideoFilter: Equatable {
      var minimumBytes: Int64
      var kind: LargeVideoKindFilter
      func includes(_ f: LargeFile) -> Bool
      // .all: FileScanPolicy.qualifies(...minimumBytes:)  (recordings always included)
      // .screenRecordings: f.isScreenRecording (threshold ignored)
      // other kinds: f.videoKind matches && f.byteSize >= minimumBytes
      static func chipSummaries(_ files: [LargeFile], minimumBytes: Int64)
          -> [LargeVideoKindFilter: (count: Int, bytes: Int64)]
  }
  ```
- **Organizer and memo.** Apply the filter inside `LargeVideoReviewOrganizer.sections(for:organization:filter:calendar:)` in `LargeVideoReviewModel.swift`, and add `filter` to `LargeVideoReviewSectionMemo`'s key.
- **Filter bar.** Create `iOSCleanup/Views/Files/LargeVideoFilterBar.swift`:
  - a threshold `Menu` ("≥ 100 MB ▾", options from `LargeVideoThreshold.options`);
  - a horizontal row of kind chips showing count and bytes, with only kinds whose count is above 0 shown and "All" always shown;
  - a summary line from `videoInventory`: "All videos: 2,040 · ≈128 GB (≈61 GB on this iPhone) · showing 40". Use "≈" when `estimatedVideoCount > 0`.
- **`FileResultsView` changes:**
  - `files` is now fed `retainedVideos` at every call site: the `HomeView` tile, WS-31's `HomeRouteDestinationView` (`.largeVideos`, plus the new `.screenRecordings`) and the `PhotoDuckShellView` Files tab.
  - New init parameters: `minimumBytes: Int64`, `onMinimumBytesChange: (Int64) -> Void`, `inventory: VideoInventorySummary`, `initialKindFilter: LargeVideoKindFilter = .all`, and `onAssetsDeleted: ((Set<String>) -> Void)?`. The last replaces the per-ID `onAssetDeleted`; update every call site. Keep WS-27's inputs (`hasCompletedVideoScan`, `lastScannedAt`, the deferred message) and WS-36.7's `compressionLocked` row value.
  - The navigation title is "Screen Recordings" when that chip is active, otherwise "Large Videos".
  - Update the refresh accessibility hint (379).
- **Rows.** Create `LargeVideoCompressionAvailability.swift` with `enum { case available, unsupportedSlowMotion; static func make(for: LargeFile) -> Self; var caption: String? }`. In `LargeVideoRowViews.swift` (`FileRow`, `LargeVideoGridCard`):
  - show `videoKind.badgeTitle` as a `StatusBadge`;
  - when availability is `.unsupportedSlowMotion`, disable Compress and show the caption "Slow-motion videos can't be compressed without losing the slow-motion effect."
- **Defensive guard.** At the top of `VideoCompressionView.startCompression()`, refuse `.unsupportedSlowMotion` and show the caption as a non-retryable failure. Put it **before** WS-36.7's `VideoCompressionStartGate.decide(...)` call, so a free user is never shown the paywall for a video that can't be compressed. Leave the entitlement gate itself untouched. This covers direct presentation. WS-43 lands later (Track B) and adds a generic composition-source refusal in the engine; it must keep this view guard (see WS-43.5).
- **Edge cases:**
  - `initialKindFilter` applies only on first appearance. After that, the user's chip choice wins.
  - An empty filter result shows "No videos match this filter" with a "Show all" button.

**WS-42.6 — Pro multi-delete with one prompt**
- **Why:** 40 videos currently take 40 taps and 40 confirmations.
- **Plan builder.** Create `iOSCleanup/Views/Files/LargeVideoDeletionPlan.swift`:
  ```swift
  struct LargeVideoDeletionPlan: Equatable {
      let assets: [PHAsset]          // review order, unique, explicit selection only
      let assetIDs: Set<String>
      let fileIDs: Set<UUID>
      let totalBytes: Int64
      let onDeviceBytes: Int64       // files whose storageLocation is .onDevice or .partial (WS-30 AssetStorageLocation)
      let bytesAreEstimated: Bool
      static func make(selectedAssetIDs: Set<String>, orderedFiles: [LargeFile]) -> LargeVideoDeletionPlan
  }
  ```
  Use `LargeVideoExportSelection.selectedFiles(in:assetIDs:)` for the ordering.
- **Selection bar.** Make the selection bar general. Add a destructive "Delete N" button under the export buttons.
  - Gating: `purchaseManager.accessDecision(for: .manualDelete(surface, count: N))` (WS-36's case exactly), where `surface` is `.screenRecordings` while the Screen recordings chip is active and `.largeVideos` otherwise. The policy is count-based (≤ 1 free), so the surface only labels the action. No policy change is needed.
  - A free user with N > 1 sees "Delete N · Pro" with `lock.fill`. A tap sets `paywallRequest = PaywallRequest(feature: f, resume: { pendingDeletionPlan = plan })` through WS-36.2's `.paywallGate`, so the in-app confirmation (and then the iOS prompt) appears only after the paywall is fully dismissed. The resume never deletes directly.
  - When a free user taps Select, show under the bar: "Deleting several videos at once is Pro. Export is free, and you can delete one video at a time." This happens before any selection.
- **Confirmation.** `@State private var pendingDeletionPlan: LargeVideoDeletionPlan?` drives it: an allowed tap sets it directly, and a locked tap sets it through the paywall's `resume`. DECISION (owner may override): an in-app `confirmationDialog` comes before the iOS prompt, because the system prompt does not show sizes: "Move N videos (≈X) to Recently Deleted?", with the message "≈Y of this is on this iPhone; the rest is stored only in iCloud." and a destructive "Move N to Recently Deleted" button.
- **Commit:**
  ```swift
  @MainActor private func deleteSelection(_ plan: LargeVideoDeletionPlan) async {
      guard !isDeletingSelection else { return }
      isDeletingSelection = true; pendingPhotoFileIDs.formUnion(plan.fileIDs)
      defer { isDeletingSelection = false; pendingPhotoFileIDs.subtract(plan.fileIDs) }
      do {
          switch try await deletionManager.delete(assets: plan.assets) {   // exactly one call
          case .deleted(let receipt):
              hideFiles(assetIDs: receipt.assetIDs)
              selectedVideoAssetIDs.subtract(receipt.assetIDs)
              onAssetsDeleted?(receipt.assetIDs)
              if selectedVideoAssetIDs.isEmpty { finishExportSelection() }
          case .declined: break                                          // selection kept
          }
      } catch {
          if !FileDeletionErrorPolicy.isBenignCancellation(error) { deletionError = error.localizedDescription }
      }
  }
  ```
- **Edge cases:**
  - A receipt can be a subset, because WS-11 drops unresolvable IDs. Hide only the receipt's IDs.
  - Disable the button during an export (`isExportingSelection`) and while deleting.
  - Single-row Delete stays as it is (free).

**WS-42.7 — Screen-recordings opportunity and Home tile**
- **Why:** recordings are a safe, high-count category (FSB-06) with no entry point.
- **Change:**
  - Add `case screenRecordings` to WS-31's nested `CleanupOpportunity.Kind` (additive; not review-only). Add `var screenRecordingCount = 0` and `var screenRecordingSizing = ReclaimSizing.zero` to `ScanOutcomeInputs`, defaulted so WS-31's tests compile unchanged. `HomeViewModel.scanOutcomeInputs` fills them from the controller's `screenRecordings`, with sizing built like WS-30's `largeVideoSizing` (by `storageLocation`). `ScanOutcomeSummary.make` builds the opportunity when the count is above 0 and uses `CountText.items(n, "screen recording", "screen recordings")` in its detail line. `.largeVideos` now comes from the partition (non-recordings).
  - Add `case screenRecordings` to WS-31's `HomeRoute` (pushed; `isPushed == true`), and make `CleanupOpportunity.route` map `.screenRecordings` to it. WS-31's `HomeRouteDestinationView` builds `FileResultsView(… initialKindFilter: .screenRecordings)` for it, so the completion sheet's row and the CTA reach it through `open(_:)`. In `HomeDashboardPresentation.make`, add the CTA copy for `.route(.screenRecordings)`: "Review \(CountText.items(n, "screen recording", "screen recordings"))", with the subtitle "≈X · you choose what to delete".
  - In `HomeView.categoryGrid`, add a "Screen recordings" tile after Large Videos: icon `record.circle`, color `.accentDeep`, count, and a ≈bytes `sizeBadge`. Its destination is `FileResultsView(… initialKindFilter: .screenRecordings)`. WS-45 later moves it into the byte-ordered grid.
- **Edge cases:** hide the tile's size badge while `fileScanState == .scanning`, matching the Large Videos tile.

**WS-42.8 — DEBUG cross-check against the Screen Recordings album**
- **Change:** create `iOSCleanup/Engines/ScreenRecordingAlbumCrossCheck.swift`, wrapped entirely in `#if DEBUG`.
  - `static func albumCount() -> Int` fetches `PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumScreenRecordings, options: nil)` and counts `PHAsset.fetchAssets(in:options:)` of type video.
  - The controller calls it at the end of a completed video scan, inside the same task (never concurrently with a photo scan), and logs `Logger(subsystem: "com.photoduck.app", category: "videos").debug("screen recordings scan=\(n) album=\(m)")`. Counts only; no identifiers (invariant 26).
- The Release build must not contain the symbol. Verify with `nm` or by making sure the file compiles to nothing outside DEBUG.

### Tests
All simulator unit tests. Add a small video double (in `iOSCleanupTests/Support/`, or extend WS-03's `TestPhotoAsset`) with overridable `localIdentifier`, `mediaType = .video`, `mediaSubtypes`, `duration`, `pixelWidth/Height` and `creationDate`.

**`iOSCleanupTests/LargeVideoInventoryTests.swift`** (new)
- `testVideoKindClassification`: each subtype, `[.videoScreenRecording, .videoHighFrameRate]` → `.screenRecording`, and `[]` → `.standard`.
- `testScreenRecordingQualifiesBelowLargeThreshold`: a 5 MB recording qualifies. A 5 MB standard video does not. A standard video of 100,000,000 bytes qualifies at the default.
- `testRetentionFloorIsFiftyMegabytes`.
- `testDefaultThresholdIsOneHundredMegabytes`, which replaces `testLargeVideoThresholdIsOneHundredMegabytes`. Also assert `sanitized(123) == default`.
- `testPartitionExcludesRecordingsFromLargeVideos`, and `testPartitionFollowsThresholdChange`.
- `testRetentionCapKeepsEveryRecordingThenLargest`.
- `testFilterAllIncludesSmallRecordings`, `testFilterScreenRecordingsIgnoresThreshold`, `testFilterSlowMotionAppliesThreshold`, and `testChipSummariesCountAndBytes`.
- `testDeletionPlanUsesReviewOrderAndSumsBytes`: selected IDs out of order give assets in review order, correct totals and on-device bytes, and `bytesAreEstimated` when any file is estimated.
- `testCompressionUnavailableForSlowMotion`.
- `testCacheV2RoundTripsKindAndInventory`, `testV1CacheIsTreatedAsMiss` (write a v1 JSON by hand, then `load()` returns nil), and `testBatchRemoveUpdatesInventoryInOneWrite`.

**`iOSCleanupTests/VideoSizeMeasurementTests.swift`** (new). A fake `request` closure returns WS-30's `VideoSizeProbe` values and records the versions it was asked for.
- `testHighFrameRateRequestsOriginalOnly`: `[.original]`, `.measured(300 MB)` → 300 MB, version `.original`.
- `testCompositionFallsBackToOriginal`: `.current → .composition`, `.original → .measured(300 MB)`.
- `testFileBackedCurrentNeedsNoSecondRequest`.
- `testCompositionThenUnavailableIsUnavailable` and `testICloudOnlyPassesThrough`.
- `testCachePolicyRemeasuresEveryVideoRecordOnExplicitRefresh` (estimated and measured records both give false), `testCachePolicyKeepsFreshRecordWithoutRemeasure` (`locationCheckedAt` 1 day old → true), and `testCachePolicyRechecksStaleLocalityWithoutRemeasure` (8 days old or nil → false; WS-30's rule).

**`FileScanEngineTests`** (existing file, or WS-03's split)
- `testScanRetainsRecordingsAndFiftyMegabytePlusAndCountsAllVideos`: sizes of 5 MB (recording), 30 MB, 60 MB and 150 MB (slo-mo) give retained [150 MB slo-mo, 60 MB, 5 MB recording], `inventory.videoCount == 4` and `totalBytes` equal to the sum.
- WS-30's `testForcedScanRequestsLocalityRevalidation` is renamed `testForcedScanPassesRemeasureToResolver`: the resolver records its `remeasureEstimates` flag, so the default is false and `scan(remeasureEstimates: true, …)` gives true.
- `testRemoveManyPreservesScanTimestampAndInventory`: after `remove(assetIdentifiers:)` of two IDs, `savedAt` is unchanged, `inventory.videoCount` drops by 2 and `totalBytes` by their sum, and the disk equals `load()`.

**Earlier tests this workstream updates** (contract 25; do not weaken their assertions):
- `FileScanEngineTests.swift:129`, `:132-135` and `:160` for `minimumFileSizeBytes` (see WS-42.3).
- `testVideoScanPublishesMonotonicProgressAndHonestCacheReuse` (`:140-181`): read `captured.last?.retainedVideos` instead of `.largeFiles` (`:181`), and use the `FileScanResult` return.
- `testLargeVideoResultsPersistAcrossCacheInstances` (`:194`): `save(files:inventory:)` and assert `inventory.videoCount == 42`.
- WS-27's cache tests `testConcurrentSaveAndRemoveLeaveDiskEqualToMemory`, `testConcurrentLoadsBothReturnSnapshot`, `testLoadRacingSaveKeepsNewerSnapshot` and `testRemovePreservesScanTimestamp`: switch to `save(files:inventory:)` and `remove(assetIdentifiers: [id])`, with the same assertions.
- WS-16's `LargeVideoScanControllerTests` (`testCompletedScanPublishesFilesAndSavesCache`, `testRemoveFileAdjustsCompletedCounts`) and WS-21's `excludeAndRemoveFiles` tests: assert on `retainedVideos`; `largeFiles` stays the derived partition.
- WS-27's `HomeViewModelTests.testUserInitiatedFirstScanRunsVideoPassBeforePhotoEngine` ("`largeFiles` is populated"): the stub videos must meet `LargeVideoThreshold.defaultMinimumBytes` (100,000,000 bytes), or assert on `retainedVideos`.
- WS-30's `LargeVideoLocalityTests`: `testFileScanCarriesProbeLocality` keeps its `{ asset, _ in … }` resolver and changes only for the `FileScanResult` return and `retainedVideos`. `testForcedScanRequestsLocalityRevalidation` becomes `testForcedScanPassesRemeasureToResolver` (above). WS-30's `testVideoProbeMapping` stays unchanged.
- WS-31's `ScanOutcomeSummaryTests`: unchanged, because the new inputs default to zero. Add `testScreenRecordingsOpportunityRoutesToFiles`: 3 recordings → one `.screenRecordings` opportunity whose `route == .screenRecordings`.

**`CleanupAccessPolicyTests`:** none. WS-36 already covers `.manualDelete(.largeVideos/.screenRecordings, count:)` (count 1 free, 2 Pro).

Device-only: see Device QA below.

### Acceptance criteria
- [ ] The Files tab offers threshold chips (50 MB / 100 MB / 500 MB / 1 GB, persisted) and kind chips. The summary line shows the count and bytes of all videos.
- [ ] Screen recordings under 100 MB are listed and deletable, and have their own Home tile. On a device, the in-app count matches the Photos Screen Recordings album (Device QA 1).
- [ ] A Pro user deletes 40 selected videos with exactly one `delete(assets:)` call and one system prompt. A free user sees the lock and note on entering Select. Single-video delete stays free.
- [ ] Slo-mo sizes come from the original (Device QA 3). An explicit Refresh re-measures estimated video records. Compress is disabled for slo-mo, with the caption, and `VideoCompressionView` refuses slo-mo when presented directly.
- [ ] The Large Videos tile, reclaimable bytes and WS-31 opportunities count only non-recordings at the chosen threshold. Screen recordings are counted once, in their own opportunity.
- [ ] Cache v2 is written. v1 is treated as a miss. WS-27's single-flight load, revision guard, synchronous writes and `savedAt`-preserving removal, and WS-20's Limited-access guard, still pass their (updated) tests.
- [ ] `grep -rn "RPReplay\|minimumFileSizeBytes" iOSCleanup iOSCleanupTests` finds nothing. No `FileScanUpdate.largeFiles` remains (the compiler enforces this), and every earlier test listed under "Earlier tests this workstream updates" is green.
- [ ] All tests pass, there are no new warnings, and the new files are in `project.pbxproj`. `CLAUDE.md`'s `FileScanEngine` row describes the retained inventory (50 MB or more plus all screen recordings, kinds from media subtypes, v2 cache).

### Device QA
Add to `docs/DEVICE_QA.md`:
1. Record 5 screen recordings of 5–60 MB. After a video refresh, the "Screen recordings" tile count equals Photos › Albums › Screen Recordings. The DEBUG log shows `scan=N album=N`.
2. As a Pro user, select 40 videos and tap Delete. Confirm the in-app dialog, then check there is exactly one iOS prompt, 40 items in Recently Deleted, and rows gone without a rescan. As a free user, tap Select and check that the note shows before any selection.
3. Record a 60 s 240 fps slo-mo clip. The size in the app is within 5% of the size in the Photos info panel, and Compress is disabled with the caption.
4. On a library with "Optimize iPhone Storage", tap Refresh. Videos downloaded since the last scan lose their "≈". Record how long the refresh takes.
5. Change the threshold to 50 MB and back. The list updates instantly, the Home tile follows, and nothing rescans.

### Pitfalls and out of scope
- Photo and video scans never load PhotoKit concurrently (invariant 16). The cross-check runs inside the video task.
- Do not add a second size-persistence path. Store only through `AssetFileSizeRepository` (WS-30 and WS-54 own its write cadence).
- Limited access must not write the v2 cache (invariant 15, WS-20).
- Nothing is pre-selected in Select mode (invariant 8).
- Duplicate-video detection is WS-62 (chapter 13); leave `makeMeasuredVideo` as its seam. Live Photo and RAW categories are WS-59 (chapter 13).
- The Home grid ordering is WS-45. Only add the tile here.
- The compression engine is WS-43/WS-44. Only the slo-mo guard is added here.
- WS-50 (chapter 11) later folds `FileResultsView`'s `onRefresh`, `onAssetsDeleted` and `onMinimumBytesChange` closures into `actions: LargeVideoActions` (contract 27). Keep them as plain closures here.
- **Reconciliation (README §9, contracts 10, 11 and 25; WS-21/27/30 definitions win):**
  - Names: `CleanupOpportunity.Kind.screenRecordings` (not `CleanupOpportunityKind`), and a flat pushed `HomeRoute.screenRecordings`, matching WS-59/WS-62's `.largePhotos`/`.duplicateVideos` style.
  - Gating: WS-36's `.manualDelete(.largeVideos/.screenRecordings, count:)` with `PaywallRequest`. No fallback policy case.
  - Resolver: exactly as contract 25 and WS-30's forward note say. WS-30's single `revalidateLocality` flag is renamed `remeasureEstimates` in `representativeFile`, `scan` and `FileRepresentativeResolver = (asset, remeasureEstimates)`. It keeps the same `.userExplicit`-only trigger, and `RepresentativeCachePolicy` keeps WS-30's `locationCheckedAt`/`recheckInterval` rule.
  - Probe: `VideoSizeMeasurement` builds on WS-30's per-version `videoSizeProbe(version:allowNetworkAccess:)` and its `VideoSizeProbe` (`.composition`, `.iCloudOnly`). There is no second probe-result enum.
  - Cache and removal: batch removal reuses WS-21's `excludeAndRemoveFiles`. Cache v2 keeps every WS-27.1 guarantee, including `savedAt` on removal.
  - Tests: this workstream owns updating every WS-16/21/27/30 test that uses `largeFiles` on `FileScanUpdate`, `minimumFileSizeBytes`, `save(files:totalVideoCount:)` or `remove(assetIdentifier:)`.

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| VALUE-06 | confirmed | The selection bar is export-only (FileResultsView.swift:841-969) and deletion is per row (1290-1311). The plan adds the plan builder, one `delete(assets:)` call and D-GATING. It uses WS-11's receipt instead of `lastCommittedToastID`, which WS-11 removes, and adds an in-app confirmation with bytes (DECISION). |
| VALUE-13 | partially | The coverage gap is real. The plan departs from the fix in three ways. Detection uses `mediaSubtypes` (FSB-06), not the "RPReplay" filename. The retention floor is 50 MB, bounded to 10,000 records, not 20 MB. There is no v1→v2 migration, because v1 lacks sub-100 MB files and kinds; sizes are cached, so the rescan is cheap. The claim that "compressing slo-mo flattens it" is currently blocked by the accidental `unverifiedOriginalSize` error, and becomes real once WS-42.2 measures sizes, so the refusal ships here. |
| FILES-20 (merged) | confirmed | The fixed 100 MiB threshold is at FileScanEngine.swift:88 and 261-265. Thresholds become decimal (DECISION), with chips at 50/100/500 MB and 1 GB. |
| FSB-06 (merged) | confirmed | There is no use of `videoScreenRecording` or `smartAlbumScreenRecordings`, and both exist in the SDK at the iOS 16+ minimum. Recordings become their own opportunity and tile, not part of Large Videos (DECISION). |
| FILES-04 | confirmed | Code path confirmed at PHAsset+FileSize.swift:693, 697-703, 616-626 and 202. That PhotoKit returns an `AVComposition` for slo-mo with `.current` is documented behavior and is re-checked on a device (WS-42.2, first step). Re-measuring is limited to the explicit user refresh, not automatic freshness rescans. |

---

## WS-43 — Compression safety

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M2 | L | WS-11, WS-30, WS-36, WS-42 | yes | `ws/43-compression-safety` |

**Primary files:**
- Engine: `iOSCleanup/Engines/VideoCompressionEngine.swift`, `iOSCleanup/Engines/CompressionReplacement.swift` (*new*)
- Views: `iOSCleanup/Views/Files/VideoCompressionView.swift`, `iOSCleanup/Views/Files/VideoAssetLoader.swift` (*new*: moved from `VideoCompressionView.swift`)
- Tests: `iOSCleanupTests/VideoCompressionEngineTests.swift`
- Docs: `CLAUDE.md`

**Findings covered:** FILES-06 (P1, confirmed; merged: FSA-09 confirmed, moot), FILES-07 (P1, confirmed; merged: FSA-10 confirmed, DEL-13 partially), FILES-05 (P1, confirmed)

**Decisions applied:**
- **D-UNDO:** the single-transaction swap is the only deletion outside `DeletionManager`. The iOS prompt is the confirmation, and Recently Deleted is the recovery.
- **D-COMPRESSION:** the output is `.mov` with metadata passthrough. Presets and savings rules are WS-44.

### Goal
Compress & Replace is one PhotoKit change block. It creates the compressed asset with the original's filename stem, date, location, favorite and hidden flags, adds it to every editable album that held the original, and deletes the original.
- **Declined:** declining the iOS prompt applies nothing. The user then sees a neutral "Nothing changed" state with "Replace Original" (no re-encode) and "Discard".
- **Validated output:** output is `.mov` with camera metadata, and its duration is validated before any replace.
- **Honest space check:** the disk preflight no longer counts a local source twice, so a local 3 GB video compresses with about 1 GB free.

### Current behavior (verified)
- **Two separate transactions.** In `iOSCleanup/Engines/VideoCompressionEngine.swift:477-531`, `saveAndDeleteOriginal` runs one `performChanges` for `creationRequestForAssetFromVideo(atFileURL:)` (copying only `creationDate`, `location` and `isFavorite`, 486-491) and then a second `performChanges { deleteAssets }` (520-522). A cancel in the second is mapped by `outcomeAfterSavedCopy` (533-549) to `.savedButOriginalKept(..., userCancelledDeletion: true)`.
- **A decline looks like success.** `VideoCompressionView.swift:333-343` sets `hasSavedCopy = true` and `.success(outcome)` for both saved cases. The banner is a green `checkmark.circle.fill` (204-224) with "Compressed Copy Saved" (394-395). `onOriginalDeleted` fires only for `.savedAndDeleted`, and the `hasSavedCopy` guard is per-sheet `@State` (16-17), so reopening creates another copy.
- **The temp file is always deleted.** `defer { removeItem(compressedURL) }` (481) deletes the output in every path.
- **Albums and metadata are lost.** No album membership is carried over, and `isHidden` is not copied. The export writes `.mp4` (`compressed_<UUID>.mp4` 427, `outputFileType = .mp4` 429, and compatibility is checked against `.mp4` at 407). `session.metadata` is never set.
- **Misleading copy.** The success text (`VideoCompressionView.swift:390-393`) says "The smaller copy keeps the original date and location."
- **The orphan sweep** (150-168) removes only `compressed_*.mp4`. It runs once per process from `iOSCleanupApp.swift:13` and `init()`.
- **The source is counted twice.**
  - The view always calls `preflightSourceDownload(originalBytes: file.byteSize)` (`VideoCompressionView.swift:268-270`), which is `validateDiskCapacity(originalBytes: X, estimatedOutputBytes: X)`, requiring about 2.2×source plus 128 MB (173-213).
  - After the AVAsset has loaded, `compress()` calls `validateDiskCapacity(originalBytes: verifiedOriginalBytes, estimatedOutputBytes: estimate.outputBytes)` (322-326), adding the source again.
- **No duration check.** Output validation checks only size (`validateOutputSize`, 215-231). Duration and the video track are never checked.
- **Network and version.** `loadAVAsset` allows the network (`VideoCompressionView.swift:415`) and uses the default `.current` version.
- **CLAUDE.md.** `ios-cleanup/CLAUDE.md:77` calls this an "atomic swap", and line 36 says "separate save/delete outcomes".
- **The test that pins the two-step behavior:** `testUserCancelledDeletionReportsSavedCopyAndKeepsOriginal` (`VideoCompressionEngineTests.swift:284-305`).

### Implementation plan

**WS-43.0 — VERIFY-FIRST (device, before merging)**

Build the branch with WS-43.1–43.5 in place (the view must call `replaceOriginal`) and run it on a device with a disposable video that is in two user albums and is a favorite.
1. Compress it and **decline** the prompt. Expect: no new asset (library count unchanged), the original still in both albums, and nothing in Recently Deleted.
2. Log whether the temp file still exists after the decline. This decides between "Replace Original" and "Compress Again" in WS-43.5.
3. Compress again and **allow**. Expect: the new asset is in both albums, is a favorite, has the same date and location and the original base filename (Photos info panel), and the original is in Recently Deleted.

Record the results in the PR and in `docs/DEVICE_QA.md`. **If step 1 shows that a declined block applied the creation, stop.** Do not ship the single-transaction path: keep today's two-step flow, show the neutral state with a "Delete compressed copy" action, and escalate to the owner.

**WS-43.1 — Seams and pure replacement planner**
- **Why:** the swap must be testable without PhotoKit. Change requests cannot run outside a real change block.
- **Change:** create `iOSCleanup/Engines/CompressionReplacement.swift`:
  ```swift
  protocol PhotoLibraryChangePerforming: Sendable {
      func performChanges(_ changes: @escaping @Sendable () -> Void) async throws
  }
  struct SystemPhotoLibraryChangePerformer: PhotoLibraryChangePerforming {
      func performChanges(_ changes: @escaping @Sendable () -> Void) async throws {
          try await PHPhotoLibrary.shared().performChanges(changes)
      }
  }
  struct ReplacementAlbumCandidate: Equatable, Sendable { let localIdentifier: String; let canAddContent: Bool }
  struct ReplacementInputs: @unchecked Sendable {     // PHAssetCollection is not Sendable
      let originalResourceFilename: String?           // .video, else .fullSizeVideo originalFilename
      let albums: [PHAssetCollection]                 // already filtered by albumIdentifiersToCarry
      static let live: @Sendable (PHAsset) async -> ReplacementInputs
  }
  enum ReplacementPlanner {
      static func derivedFilename(from original: String?) -> String
      static func albumIdentifiersToCarry(_ candidates: [ReplacementAlbumCandidate]) -> [String]
      static func outcome(for error: Error) -> VideoCompressionEngine.ReplacementOutcome   // userCancelled -> .declined
  }
  ```
  - **`derivedFilename`:** keep the original stem and use `.MOV` when the original extension is all uppercase, otherwise `.mov`. So `IMG_1.MOV` → `IMG_1.MOV`, `clip.mp4` → `clip.mov`, `a.b.MP4` → `a.b.MOV`, and nil or empty → `Video.mov`.
  - **`ReplacementInputs.live`:**
    - Uses `PHAssetResource.assetResources(for:)` and `PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil)`.
    - Maps each album to `ReplacementAlbumCandidate(localIdentifier:, canAddContent: collection.canPerform(.addContent))`.
    - Keeps only the carried ones. This excludes shared albums and smart albums.
    - Runs on the engine actor (off the main actor).
  - **`outcome(for:)`:** `(error as NSError).domain == PHPhotosErrorDomain && code == PHPhotosError.userCancelled.rawValue` gives `.declined`; anything else gives `.failed("Photos couldn't replace the video: …")`.
- **Engine init:** `VideoCompressionEngine.init(changePerformer: PhotoLibraryChangePerforming = SystemPhotoLibraryChangePerformer(), inputsProvider: @escaping @Sendable (PHAsset) async -> ReplacementInputs = ReplacementInputs.live)`. Keep the one-time startup sweep in `init`.

**WS-43.2 — `replaceOriginal`: one transaction, three outcomes**
- **Why:** a declined second transaction leaves a duplicate that looks like success (FILES-06), and albums are lost (FILES-07, FSA-10).
- **Change:**
  - Replace `saveAndDeleteOriginal` and `outcomeAfterSavedCopy` with `func replaceOriginal(compressedURL: URL, originalAsset: PHAsset) async -> ReplacementOutcome`.
  - Replace `ReplacementOutcome` with `.replaced(savedAssetIdentifier: String?)`, `.declined` and `.failed(String)`, and delete `savedAssetIdentifier`/`didSaveCopy`.

  ```swift
  func replaceOriginal(compressedURL: URL, originalAsset: PHAsset) async -> ReplacementOutcome {
      guard FileManager.default.fileExists(atPath: compressedURL.path) else {
          return .failed("The compressed file is no longer available. Compress again.")
      }
      let inputs = await inputsProvider(originalAsset)
      let filename = ReplacementPlanner.derivedFilename(from: inputs.originalResourceFilename)
      let box = CreatedAssetIdentifierBox()
      do {
          try await changePerformer.performChanges {
              let request = PHAssetCreationRequest.forAsset()
              let options = PHAssetResourceCreationOptions()
              options.originalFilename = filename
              options.shouldMoveFile = true
              request.addResource(with: .video, fileURL: compressedURL, options: options)
              request.creationDate = originalAsset.creationDate
              request.location = originalAsset.location
              request.isFavorite = originalAsset.isFavorite
              request.isHidden = originalAsset.isHidden
              if let placeholder = request.placeholderForCreatedAsset {
                  box.value = placeholder.localIdentifier
                  for album in inputs.albums {
                      PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
                  }
              }
              PHAssetChangeRequest.deleteAssets([originalAsset] as NSArray)   // same block: atomic
          }
      } catch {
          return ReplacementPlanner.outcome(for: error)      // temp file is NOT removed
      }
      try? FileManager.default.removeItem(at: compressedURL)  // defensive: normally moved by Photos
      return .replaced(savedAssetIdentifier: box.value)
  }
  ```
  - The only `deleteAssets` in this file is inside this block. Remove the old `Task.isCancelled` branch.
  - Rewrite the doc comment so it describes the single-transaction exemption.
- **Edge cases:**
  - A nil placeholder (not expected): the swap still happens atomically but albums are skipped. Leave a comment; there is no second transaction.
  - `performChanges` is not cancellable. Keep the view's `.saving` state non-dismissable (it is today, 71-72).

**WS-43.3 — `.mov` output with metadata passthrough; sweep both extensions**
- **Change:**
  - In `export(...)`: `compressed_<UUID>.mov`, `session.outputFileType = .mov`, and `session.metadata = try await asset.load(.metadata)`. Keep `shouldOptimizeForNetworkUse`.
  - `compatiblePresetName` checks against `.mov`.
  - `sweepOrphanedTemporaryFiles` removes `compressed_*` files whose extension is `mp4` or `mov`, case-insensitive. `discardTemporaryOutput(at:)` keeps its `compressed_` prefix check.
- **Edge cases:** `load(.metadata)` failing is not fatal. Use `(try? await asset.load(.metadata)) ?? []`.

**WS-43.4 — Validate the output's duration and video track**
- **Why:** a truncated export that is still smaller would pass today, and the original would be deleted (DEL-13 b).
- **Change:**
  - Add `case outputDurationMismatch(sourceSeconds: Double, outputSeconds: Double)` (not retryable) to `CompressionError`, with copy "The compressed video is a different length from the original, so nothing was replaced."
  - Add `nonisolated static func validateOutputDuration(sourceSeconds: Double, outputSeconds: Double) throws`. It throws when either value is non-finite, when `sourceSeconds <= 0`, or when `abs(output - source) > max(0.5, source * 0.01)`.
  - In `compress()`, right after `export`, load the duration and the video tracks from `AVURLAsset(url: outputURL)`. An empty video track list gives `.emptyOutput`. Then call `validateOutputDuration`, then `validateOutputSize`.
  - On any validation failure, remove the output and call `control.clearExport()`, as the size check already does (337-345).

**WS-43.5 — Refuse composition sources (and the declined-state UI)**
- **Why:** a source that PhotoKit renders live would be flattened, and its original's editable data discarded.
- **Refusal:** DECISION (owner may override): compression refuses any source delivered as something other than a file-backed `AVURLAsset`. That covers slo-mo, and possibly Cinematic if PhotoKit renders it as a composition.
  - In `compress()`, before `resolveOriginalBytes`: `guard let urlAsset = asset as? AVURLAsset, urlAsset.url.isFileURL else { throw CompressionError.unsupportedSource }`.
  - `unsupportedSource` is not retryable. Its copy: "This video uses an effect Photos renders live, like slow motion. Compressing would flatten it, so PhotoDuck left it unchanged."
  - Keep WS-42's slo-mo guard (`LargeVideoCompressionAvailability.unsupportedSlowMotion`) at the top of `startCompression`, before WS-36.7's entitlement gate, and keep `testCompressionUnavailableForSlowMotion`. The two refusals are layered: WS-42's row and view guard refuse by media subtype before any work, and this engine guard refuses any composition source (slo-mo, possibly Cinematic) after the AVAsset loads.
- **View state.** Move `loadAVAsset` and `VideoAssetRequestState` (401-537) unchanged into `iOSCleanup/Views/Files/VideoAssetLoader.swift`, as `enum VideoAssetLoader { static func load(_ asset: PHAsset, allowNetworkAccess: Bool, progress: …) async throws -> AVAsset }`. Then in `VideoCompressionView`:
  - Replace `.success(ReplacementOutcome)` with `.replaced(CompressionResultSummary)` (`struct CompressionResultSummary { originalBytes; outputBytes; savedAssetIdentifier }`, which WS-44 renders richly).
  - Add `.replacementPending(VideoCompressionEngine.CompressionOutput, reason: PendingReplacementReason)` with `enum PendingReplacementReason: Equatable { case declined, failed(String) }`.
  - Delete `hasSavedCopy` and `savedCopyAssetIdentifier`. They are unnecessary now that nothing can be saved without the delete. WS-36.7's `VideoCompressionStartGate.decide(access:isBusy:)` call reads them, so change its input to `isBusy: compressionTask != nil || state is .saving or .replaced`. `.replacementPending` is not busy, because its buttons handle retry. Keep `VideoCompressionStartGateTests` green.
- **`.replacementPending` UI** (neutral, not green): the title "Nothing changed" and the body "The original is kept." (or the failure message).
  - "Replace Original" re-calls `replaceOriginal` with the same `output.url` and no re-encode. It is shown only when `FileManager.default.fileExists(atPath: output.url.path)`; otherwise show "Compress Again", which calls `startCompression()`.
  - "Discard Compressed Copy" calls `discardTemporaryOutput(at:)` and returns to `.idle`.
  - Both buttons are disabled while a save is in flight.
- **Temp lifecycle:**
  - `onDisappear` cancels the task and, if the state is `.replacementPending` or a completed output was not yet replaced, discards the temp file.
  - `.replaced` calls `onOriginalDeleted?()`, as today.
- **Copy before start:** show one line under the presets: "Keeps date, location, favorite and albums. Shared albums, People tags and captions are not copied."
- **Copy after success:** "Compressed & Replaced", with "The original is in Recently Deleted." WS-44 adds the bytes.
- **DEBUG gate.** Remove any `#if DEBUG` gate on the compression entry point that was added under README §2's "Compression before WS-43" note, and say so in the PR.

**WS-43.6 — Disk preflight counts the source only when it must be downloaded**
- **Why:** a local 3 GB video needs about 0.74 GB but is refused with "6.73 GB needed".
- **Change:**
  - Extract the estimate math from `estimate(asset:…)` (247-292) into `nonisolated static func estimatedOutputBytes(originalBytes: Int64, durationSeconds: Double, sourcePixelCount: Double, preset: Preset, usesHEVC: Bool) -> Int64`. The formula is unchanged, and `estimate` calls it. WS-44 reuses it for the per-preset UI.
  - Rename the parameter: `validateDiskCapacity(additionalSourceBytes:estimatedOutputBytes:availableCapacity:)`. Keep the overflow clamping and the 128 MB reserve.
  - In `compress()`, `additionalSourceBytes` is 0 when `(asset as? AVURLAsset)?.url` is a file URL that exists. Otherwise it is `verifiedOriginalBytes`, which is unreachable after WS-43.5 but kept for safety.
  - Replace the preflight with `preflightSourceDownload(sourceBytes: Int64, estimatedOutputBytes: Int64, sourceIsLocal: Bool, availableCapacity: Int64? = availableTemporaryCapacity()) throws -> Int64`, where required = `(sourceIsLocal ? 0 : sourceBytes) + 1.2 × estimate + reserve`.
- **In the view:**
  - `sourceIsLocal` comes from WS-30's `file.storageLocation`: `.onDevice` and `.partial` are local (WS-30's rule), and `.iCloudOnly` is not.
  - For `.unknown`, run WS-30's `photoAsset.videoSizeProbe(version: .current, allowNetworkAccess: false)`. `.measured` means local; anything else (`.composition`, `.iCloudOnly`, `.unavailable`) means not local.
  - The estimate is `estimatedOutputBytes(...)` for the selected preset, from `file.byteSize`, `photoAsset.duration` and pixel size, with `usesHEVC: preset != .p720`.
  - Change the `insufficientDiskSpace` copy to "Not enough free space to compress safely. X is needed (including Y to download the video from iCloud); Z is available." Show the parenthesis only when not local; the error case gains a `downloadBytes: Int64` field.
- **Edge cases:**
  - Unknown capacity (nil) never blocks. Keep `testDiskPreflightDoesNotInventFailureWhenCapacityCannotBeRead`.
  - Keep `shouldMoveFile = true` so the import needs no second copy of the output.

**WS-43.7 — Docs**
- In `ios-cleanup/CLAUDE.md`:
  - **Line 36 (`VideoCompressionEngine` row):** "Cancellable `AVAssetExportSession` actor: disk/output/duration validation, `.mov` output with metadata passthrough, and a single-transaction replace (create copy + album adds + delete original); declining the iOS prompt changes nothing."
  - **Line 77:** "One documented exemption: `VideoCompressionEngine.replaceOriginal` deletes the original inside the same PhotoKit change block that creates the compressed copy, so the iOS confirmation covers both, declining applies neither, and the original goes to Recently Deleted."
- Check that the invariant text written by WS-11 still agrees in both CLAUDE.md files.

### Tests
Everything below runs in the simulator. `FakeChangePerformer` is an actor that records its call count and either returns or throws an injected error. **It never runs the block**, because PhotoKit change requests raise outside a change block. `ReplacementInputs` is stubbed with `(filename, albums: [])`.

**`iOSCleanupTests/VideoCompressionEngineTests.swift`**
- **Replacement outcomes.** A test-local `PHAsset` subclass is enough as the original.
  - `testReplaceOriginalIssuesExactlyOneChangeBlock`.
  - `testDeclinedReplacementSavesNothingAndKeepsTempForRetry` replaces `testUserCancelledDeletionReportsSavedCopyAndKeepsOriginal`: the fake throws `NSError(PHPhotosErrorDomain, userCancelled)`, which gives `.declined` with the temp file still present.
  - `testFailedReplacementKeepsTempAndReportsFailed` replaces `testOtherDeletionFailureStillDoesNotOfferExportRetry`.
  - `testSuccessfulReplacementRemovesLeftoverTemp`.
  - `testMissingTempFileFailsWithoutCallingPhotos`.
- **Planner.**
  - `testDerivedFilenameKeepsStem`, covering the four cases in WS-43.1.
  - `testAlbumsToCarryKeepsOnlyEditableAlbums`.
- **Duration.** `testOutputDurationTolerance`: 10 s source with 9.6 passes and 9.4 fails; 600 s source with 594.5 passes and 593 fails; a zero or non-finite source throws.
- **Disk capacity.**
  - `testLocalSourceNeedsOnlyExportSpace`: `validateDiskCapacity(additionalSourceBytes: 0, estimatedOutputBytes: 510_000_000, availableCapacity: 1_000_000_000)` passes and returns `ceil(510e6 × 1.2) + 128 MiB`.
  - `testICloudSourceNeedsDownloadSpace`: the same call with 3 GB of source fails.
  - `testPreflightIgnoresSourceWhenLocal` and `testPreflightUsesPresetEstimateNotSourceSize`.
  - Existing overflow and nil-capacity tests: update to the new labels, keeping their assertions.
- **Estimate and source type.**
  - `testEstimatedOutputBytesMatchesAssetEstimate`: the extracted helper equals the old `estimate` for the synthetic clip (pixel count 640×360, 1 s).
  - `testCompositionSourceIsRefused`: pass `AVMutableComposition()`, which gives `.failed(.unsupportedSource)` before export.
- **Orphan sweep.** Rename `testOrphanSweepRemovesOnlyOwnedCompressedMP4Files` to `…MP4AndMOVFiles` and add `compressed_x.mov` and `compressed_y.MOV`.
- **Smoke test.** Extend `testCompressProducesValidatedFileAndProgress`:
  - The synthetic writer sets `writer.metadata` with an `AVMutableMetadataItem` for `.commonIdentifierCreationDate`.
  - Assert `output.url.pathExtension == "mov"` and that `AVURLAsset(url:).load(.commonMetadata)` contains the creation date.
  - WS-44.4 (next) adds a savings policy and updates this smoke test to pass a permissive one.

Device-only: WS-43.0 and Device QA below.

### Acceptance criteria
- [ ] WS-43.0 is done and recorded: a declined prompt leaves the library unchanged, the original stays in its albums, and nothing is in Recently Deleted.
- [ ] `grep -n "deleteAssets" iOSCleanup/Engines/VideoCompressionEngine.swift` shows exactly one site, inside `replaceOriginal`'s change block. `saveAndDeleteOriginal` and `outcomeAfterSavedCopy` no longer exist.
- [ ] After an allowed replace, the new video is in every editable user album the original was in, with the same date, location, favorite and hidden flags, the original base filename (`.MOV`/`.mov`), and make/model metadata (Device QA 2).
- [ ] After a decline, the UI shows "Nothing changed" with Replace Original (or Compress Again) and Discard. No green success is shown and the row stays.
- [ ] A local 3 GB video can start compressing to 1080p with about 1 GB free. An iCloud-only video still requires download space, and the message says so.
- [ ] Output with a mismatched duration or no video track never replaces the original. Composition sources are refused.
- [ ] Every test above passes, there are no new warnings, `VideoAssetLoader.swift` and `CompressionReplacement.swift` are in `project.pbxproj`, and both CLAUDE.md files agree.

### Device QA
Add to `docs/DEVICE_QA.md`:
1. WS-43.0, steps 1–3 (declined leaves the library unchanged; albums, date, location, favorite and filename preserved).
2. After a replace, open the new video's info panel in Photos. The camera make/model and the location appear.
3. With about 1.2 GB free, compress a local video of 2 GB or more to 1080p. The preflight passes.
4. Compress an iCloud-only video (Optimize Storage on). The preflight includes download space, and the error text mentions the download when space is short.
5. Decline, then tap Replace Original. The same file replaces the original without re-encoding, and the prompt appears once.

### Pitfalls and out of scope
- **Never split create and delete** into two change blocks again, and never call `DeletionManager` here (invariant 4's single exemption).
- **Keep the existing guards** (invariant 25): `unverifiedOriginalSize`, output-not-smaller, leases and the orphan sweep.
- **Temp-file cleanup is subtle.** The `CompressionOutput` lease is claimed by the view (`claimTemporaryFile()`, 297-298), so from then on the view owns cleanup on every non-replaced path.
- **Belongs to WS-44 (this chapter):** idle timer, interruption, presets, savings threshold and recorded savings.
- **Belongs to WS-30 (chapter 07):** the pre-start iCloud download notice for iCloud-only files. WS-43 only consumes the locality.
- **Reconciliation:**
  - WS-42's slo-mo guard stays when this workstream adds the generic `unsupportedSource` refusal (ch09 cross-issue).
  - Deleting `hasSavedCopy`/`savedCopyAssetIdentifier` updates WS-36.7's `VideoCompressionStartGate` busy input.
  - Locality uses WS-30's exact names (`storageLocation`, `AssetStorageLocation`, `videoSizeProbe(version:allowNetworkAccess:)`), with `.partial` treated as local.
  - WS-36 and WS-42 are listed as dependencies because this workstream edits code they add.

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| FILES-06 | confirmed | There are two `performChanges` calls (477-531); a decline is shown as green success (333-343, 204-224); CLAUDE.md:77 says "atomic". Whether a declined mixed change block applies nothing is device behavior, so WS-43.0 checks it first. The plan follows the fix, adding a `PhotoLibraryChangePerforming` seam plus a stubbed inputs provider, because the change block itself cannot run in tests. |
| FSA-09 (merged) | confirmed, moot | The per-sheet `@State` guard is real (16-17). A single-transaction swap cannot save a copy without deleting, so no ledger is built. |
| FILES-07 | confirmed | Only three properties are copied, there are no album adds, output is `.mp4`, and there is no `session.metadata`. How many QuickTime keys an `.mp4` would drop is device-dependent; the plan uses `.mov` with explicit metadata either way (D-COMPRESSION). |
| FSA-10 (merged) | confirmed | Temp name `compressed_<UUID>.mp4` (427). The filename is derived as stem + `.MOV`/`.mov`, not `.mp4`, because the output is now `.mov`. |
| DEL-13 (merged) | partially | Albums, `isHidden` and the unchecked duration are confirmed, and fixed here. The iCloud "device space goes up" case is real but only needs copy (WS-44). "Re-fetch the saved ID before deleting" is moot with one transaction. Stats move to WS-44 via WS-32's API. |
| FILES-05 | confirmed | 2.2×source + 128 MB preflight (268-270, 173-183) and the source added again in `compress()` (322-326). The plan uses the metadata estimate instead of 1.2×source in the preflight, and WS-30 locality (with a network-off probe fallback) instead of a new probe. |

---

## WS-44 — Compression UX and outcome

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M2 | M | WS-28, WS-29, WS-32, WS-43 | no | `ws/44-compression-ux` |

**Primary files:**
- Views: `iOSCleanup/Views/Files/VideoCompressionView.swift`, `iOSCleanup/Views/Files/CompressionPresentation.swift` (*new*), `iOSCleanup/Views/Files/VideoSourceInspector.swift` (*new*), `iOSCleanup/Views/Files/FileResultsView.swift` (one `.environmentObject` line)
- Engines: `iOSCleanup/Engines/VideoCompressionEngine.swift`
- Utilities (read only): `iOSCleanup/Utilities/BackgroundTaskLease.swift` (WS-28.2), `iOSCleanup/Utilities/IdleTimerCoordinator.swift` (WS-29.1)
- Tests: `iOSCleanupTests/VideoCompressionEngineTests.swift`, `iOSCleanupTests/CompressionPresentationTests.swift` (*new*)

**Findings covered:** FILES-08 (P1, confirmed), FILES-19 (P2, confirmed), FILES-22 (P3, confirmed)

**Decisions applied:**
- **D-COMPRESSION:** HEVC 1080p is the default. "Maximum quality" is hidden for HEVC sources. Savings must be at least 10% and at least 20 MB (decimal).
- **D-GATING:** compression is Pro. Keep WS-36's entitlement guard inside `VideoCompressionView`.
- **D-BACKGROUND:** compression is foreground-only, with the screen kept awake. There is no background continuation.

### Goal
A multi-minute compression finishes untouched under the default Auto-Lock. If the app leaves the screen, the user sees a specific "interrupted" message with Resume instead of "Operation Stopped".

Before starting, each preset shows its codec, an estimated size and the saving. HEVC 1080p is the default, and presets that cannot save enough are disabled.

After a replace, the user sees exactly what was saved and learns that the space is freed when Recently Deleted is emptied. The replacement is recorded through WS-32's `recordCompressionSavings(originalBytes:outputBytes:)` only on `.replaced`: net savings go to `lifetimeCompressionSavedBytes`, and the original enters the Recently Deleted ledger as `.compressionOriginal`.

### Current behavior (verified)
- **Nothing keeps the export alive.** `VideoCompressionView.runCompression` (`Views/Files/VideoCompressionView.swift:261-359`) never touches the idle timer, never takes a background task, and never observes `scenePhase`. Export flows elsewhere do all three (`FileResultsView.swift:1155-1182`, `HomeView.swift:1846-1875`).
- **Every export failure is generic.** In `VideoCompressionEngine.export` (416-460), anything other than completed or cancelled becomes `CompressionError.exportFailed(session.error?.localizedDescription …)` (453-455).
- **Presets.**
  - The default is `@State private var selectedPreset: … = .p720` (12). `.p720` uses `AVAssetExportPreset1280x720` (H.264; the comment says there is no HEVC 720p preset, 26-28).
  - `.original` has the raw value "Original Quality" but uses `AVAssetExportPresetHEVCHighestQuality` (35-38).
  - The picker shows `preset.rawValue` (132). `estimatedLabel` returns "Analyze on start" for every row until the export begins (375-383).
- **Any saving is accepted.** `validateOutputSize` accepts any output at least 1 byte smaller (215-231).
- **The success banner shows no numbers.** It says "Compressed & Saved" with no bytes and nothing about Recently Deleted (204-224, 385-399).
- **Savings are never counted.** `DeletionManager.recordConfirmedDeletion` is private (`DeletionManager.swift:401-407`), and compression never records anything. WS-32.2 adds `CleanupStatsStore.recordCompressionSavings(originalBytes:outputBytes:)` (in `Engines/CleanupStats.swift`) and a forwarding `DeletionManager.recordCompressionSavings(originalBytes:outputBytes:)`. Nothing calls it yet.
- **A reusable background-task helper.** At baseline it is the private `PhotoDuckBackgroundTaskLease` in `HomeViewModel.swift:15-33`. WS-28.2 moves it to `iOSCleanup/Utilities/BackgroundTaskLease.swift` as `@MainActor final class BackgroundTaskLease` (`init(name:begin:end:)`, `end()`).
- **Idle timer.** WS-29.1 makes `IdleTimerCoordinator` the single writer of `isIdleTimerDisabled` (`acquire(reason:) -> Token`, `release(_:)`), and its grep acceptance leaves compression to this workstream.

### Implementation plan

**WS-44.1 — Keep the screen awake; map interruptions; Resume**
- **Why:** 30 s or 1 min Auto-Lock kills a 2–5 minute export, and every retry restarts at 0% with a generic error.
- **Change (engine):**
  - Add `case interrupted` to `CompressionError`. It is retryable, with the copy "Compression stopped because PhotoDuck left the screen. Keep PhotoDuck open while compressing."
  - In `export(...)`, replace the generic throw with `throw CompressionError.fromExportError(session.error)`, where `nonisolated static func fromExportError(_ error: Error?) -> CompressionError` maps `AVFoundationErrorDomain` codes `AVError.operationInterrupted.rawValue` and `AVError.sessionWasInterrupted.rawValue` to `.interrupted`, and anything else to `.exportFailed(localizedDescription)`.
- **Change (view policy).** In `CompressionPresentation.swift`:
  ```swift
  enum CompressionInterruptionPolicy {
      /// Any export failure after the scene left .active during .compressing counts as an interruption.
      static func classify(_ error: CompressionError, wasBackgroundedDuringExport: Bool) -> CompressionError
  }
  ```
- **Change (view):**
  - Add `@Environment(\.scenePhase)`. On `.background` or `.inactive` while in `.compressing`, set `wasBackgroundedDuringExport = true`. Reset it when a new run starts.
  - On `.failed(error)`, show `classify(error, …)`. For `.interrupted`, the error section shows "Resume", which calls `startCompression()`; the subtitle is "Starts the export again — the video doesn't need to download again."
  - Add `CompressionIdleHold` to `CompressionPresentation.swift`: a `@MainActor struct` holding `IdleTimerCoordinator.Token?`. `begin()` calls `coordinator.acquire(reason: "compression")` (WS-29's API exactly) if no token is held. `end()` calls `coordinator.release(token)` and sets the token to nil. The view keeps `@State private var idleHold = CompressionIdleHold()`, calls `idleHold.begin()` when entering `.preparing`, and calls `idleHold.end()` on **every** exit: `runCompression`'s `defer` (success, failure, cancel) and `onDisappear`. `release(nil)` and a double `end()` are no-ops. Never set `UIApplication.shared.isIdleTimerDisabled` directly.
  - Wrap every `engine.replaceOriginal` call (the first save and Replace Original) in WS-28's lease: `let lease = BackgroundTaskLease(name: "PhotoDuck compression replace"); defer { lease.end() }`. Do not create or move the lease type; WS-28.2 already did.
  - Under the progress bar, show "Keep PhotoDuck open. Your screen will stay on."
- **Edge cases:**
  - Record on the device which error code the backgrounded export actually produces (Device QA 1), and add it to the mapping if it differs.
  - A cancel from the toolbar is still `.cancelled`, not an interruption.

**WS-44.2 — Presets: HEVC 1080p default, honest names, hide "Maximum quality" for HEVC**
- **Why:** the 720p H.264 default silently turns 4K HDR into 720p SDR, and "Original Quality" is a lossy re-encode.
- **Change:**
  - Keep the `Preset` case names (and the `rawValue`s used in diagnostics). Add presentation in `CompressionPresentation.swift`:
    ```swift
    extension VideoCompressionEngine.Preset {
        var title: String   // .p1080 "Balanced · 1080p HEVC", .p720 "Smallest · 720p H.264", .original "Maximum quality · HEVC"
        var detail: String  // .p720 "HDR becomes SDR", .p1080 "Keeps HDR", .original "Largest file, least loss"
    }
    enum VideoSourceCodec: Equatable { case hevc, h264, other, unknown
        static func from(mediaSubType: FourCharCode) -> VideoSourceCodec }  // kCMVideoCodecType_HEVC / _H264
    enum CompressionPresetAvailability {
        static let defaultPreset: VideoCompressionEngine.Preset = .p1080
        static func visiblePresets(sourceCodec: VideoSourceCodec) -> [VideoCompressionEngine.Preset]   // drops .original for .hevc
    }
    ```
  - Create `VideoSourceInspector.swift` with `static func inspect(_ asset: PHAsset) async -> VideoSourceCodec`. It uses `VideoAssetLoader.load(asset, allowNetworkAccess: false)` with a 3 s timeout and reads the first video track's `formatDescriptions` via `CMFormatDescriptionGetMediaSubType`. An iCloud-only or timed-out source gives `.unknown`.
  - Run it in the view's `.task`. Set `selectedPreset = CompressionPresetAvailability.defaultPreset`.
  - **Engine backstop:** in `compress()`, when `preset == .original` and the loaded asset's codec is HEVC, throw `CompressionError.presetWouldNotSaveSpace` before exporting. It is not retryable; its copy: "This video is already HEVC, so Maximum quality would barely shrink it. Choose 1080p or 720p." This covers `.unknown` at display time.
  - Show this disclosure line under the presets: "Re-encodes the video (some quality loss). Edits are applied permanently; HDR is kept with HEVC presets."
- **DECISION (owner may override):** 720p stays H.264 and is labeled as such, rather than building a custom HEVC 720p video composition.

**WS-44.3 — Per-preset estimate before starting**
- **Why:** "Analyze on start" makes users wait minutes to learn whether it is worth it.
- **Change:**
  ```swift
  struct CompressionPresetEstimate: Equatable {
      let outputBytes: Int64; let savedBytes: Int64; let isApproximate: Bool; let meetsSavingsPolicy: Bool
      static func make(sourceBytes: Int64, sourceBytesAreEstimated: Bool, durationSeconds: Double,
                       pixelWidth: Int, pixelHeight: Int, preset: VideoCompressionEngine.Preset,
                       policy: CompressionSavingsPolicy) -> CompressionPresetEstimate?   // nil when duration or dimensions are unknown
  }
  ```
  - It calls WS-43's `VideoCompressionEngine.estimatedOutputBytes(...)` with `usesHEVC: preset != .p720`. `isApproximate` is always true, because this is a pre-export estimate.
  - Each row shows "≈480 MB · saves ≈1.4 GB". When `!meetsSavingsPolicy`, the row says "Won't save enough" and is disabled.
  - If the default is disabled, select the first enabled preset. If none is enabled, show "This video is already compact" and disable Compress.
  - Replace `estimatedLabel`, and delete the separate `estimatedSizes` row.
- **Edge cases:** a duration of 0 or less, or unknown dimensions, gives an estimate of nil, and the row shows only the codec line.

**WS-44.4 — Require meaningful savings**
- **Why:** a 2% saving costs a generation of quality loss.
- **Change** in `VideoCompressionEngine.swift`:
  ```swift
  struct CompressionSavingsPolicy: Sendable, Equatable {
      let minimumFraction: Double; let minimumBytes: Int64
      static let standard = CompressionSavingsPolicy(minimumFraction: 0.10, minimumBytes: 20_000_000)
      func accepts(originalBytes: Int64, outputBytes: Int64) -> Bool   // saved >= minimumBytes && saved >= fraction*original
  }
  ```
  - `validateOutputSize(originalBytes:outputBytes:policy: = .standard)`:
    - `outputBytes <= 0` → `.emptyOutput`;
    - `originalBytes <= 0` → `.invalidOriginalSize`;
    - `outputBytes >= originalBytes` → `.outputNotSmaller`;
    - `!policy.accepts` → new `.insufficientSavings(originalBytes:outputBytes:)`, not retryable. Copy: "Compressing would save only X (Y%), so the original was left unchanged."
  - `compress(asset:preset:originalBytes:originalBytesAreEstimated:savingsPolicy: CompressionSavingsPolicy = .standard)`.
  - Update the smoke test to pass `CompressionSavingsPolicy(minimumFraction: 0, minimumBytes: 1)`.

**WS-44.5 — Outcome content and recorded savings**
- **Why:** users can't tell whether it worked, and "Freed" stays at 0.
- **Change** in `CompressionPresentation.swift`:
  ```swift
  struct CompressionOutcomeContent: Equatable {
      let title: String; let headline: String; let details: [String]
      static func replaced(originalBytes: Int64, outputBytes: Int64, sourceWasICloudOnly: Bool) -> Self
      static func savingsToRecord(for outcome: VideoCompressionEngine.ReplacementOutcome,
                                  originalBytes: Int64, outputBytes: Int64)
          -> (originalBytes: Int64, outputBytes: Int64)?   // nil unless .replaced
  }
  ```
  - `replaced(...)` builds:
    - title "Compressed & Replaced";
    - headline "Saved 1.4 GB (2.1 GB → 700 MB)", using WS-31's bytes formatter;
    - details: "Keeps date, location, favorite and albums."; "Space is released when Recently Deleted is emptied (Photos › Albums › Recently Deleted)."; and, when `sourceWasICloudOnly`, "This video was stored in iCloud. This iPhone now keeps the smaller copy; iCloud space is freed after Recently Deleted is emptied."
  - `sourceWasICloudOnly` is true when WS-30's `file.storageLocation == .iCloudOnly`, or when `VideoAssetLoader`'s progress handler reported a value below 1 during this run.
  - On `.replaced`, render the content in the existing success banner. The visual layout is unchanged; only the text changes. If `savingsToRecord` returns a value, call WS-32's `deletionManager.recordCompressionSavings(originalBytes:outputBytes:)` (the `DeletionManager` environment object). Per WS-32, that adds `max(original − output, 0)` to `lifetimeCompressionSavedBytes` and `originalBytes` to today's `.compressionOriginal` Recently Deleted entry, so the "Finish freeing space" card includes the original. There is no `recordCompressionSavings(bytes:)` variant (contract 6); do not add one.
  - `FileResultsView`'s sheet must add `.environmentObject(deletionManager)`, next to WS-36.7's `purchaseManager` injection.
  - Keep the existing `onOriginalDeleted?()` call on `.replaced`. Its presenter removes the row through `removeLargeFileFromResults`, which per WS-32.1 also calls `refreshStorage()`, so the Home storage card updates after compression. Check that this chain holds; if a presenter bypasses it, call `viewModel.refreshStorage()` there.
- **Edge cases:** `.declined` and `.failed` never record anything. Replace Original's success records once.

### Tests
**`iOSCleanupTests/CompressionPresentationTests.swift`** (new; pure, simulator)
- `testInterruptionPolicyTreatsFailureAfterBackgroundAsInterrupted` and `testInterruptionPolicyLeavesForegroundFailuresAlone`.
- `testDefaultPresetIs1080p` and `testVisiblePresetsHideMaximumQualityForHEVC` (`.h264` and `.unknown` keep all three).
- `testCodecFromFourCC`: HEVC, H.264 and other.
- `testPresetEstimatesStayBelowSourceAndMaximumIsLargest`: for a 4K 60 s 2 GB source, every preset's estimate is below the source and `.original` is the largest. (With the current formula, 1080p HEVC can come out slightly smaller than 720p H.264 for a 4K source, so do not assert p720 ≤ p1080.)
- `testPresetEstimateFlagsInsufficientSavings`: a 1080p source of 50 MB at p1080 is estimated at about 34 MB, saving about 16 MB, which does not meet the policy. A 1080p 500 MB source at p1080 does.
- `testReplacedContentShowsSavedBytesAndRecentlyDeletedNote`, `testICloudNoteOnlyWhenSourceWasICloudOnly`, and `testSavingsRecordedOnlyForReplaced` (declined and failed give nil; replaced gives `(originalBytes, outputBytes)` unchanged).

**`iOSCleanupTests/VideoCompressionEngineTests.swift`**
- `testInterruptedExportErrorMapsToInterrupted`: `NSError(domain: AVFoundationErrorDomain, code: AVError.operationInterrupted.rawValue)` gives `.interrupted` with `isRetryable == true`. Any other code gives `.exportFailed`.
- `testSavingsPolicy`:
  - 1,000,000,000 → 950,000,000 is rejected (5%).
  - 100,000,000 → 90,000,000 is rejected (10 MB).
  - 200,000,000 → 180,000,000 is accepted (exactly 10% and 20 MB).
  - 1,000,000,000 → 700,000,000 is accepted.
  - Output of original size or larger is still `.outputNotSmaller`.
- `testSafetyFailuresDoNotOfferBlindRetry`: extend to cover `.insufficientSavings`, `.presetWouldNotSaveSpace`, `.unsupportedSource` and `.outputDurationMismatch` (all false) and `.interrupted` (true).
- **Idle timer** (in `CompressionPresentationTests`): `testCompressionHoldIsReleasedOnEveryExit`. Construct `CompressionIdleHold(coordinator:)` (from WS-44.1) with WS-29's `IdleTimerCoordinator(apply:)` seam, recording applied values. Drive it through success, failure, cancel and disappear, including a double `end()`. After each, `coordinator.isHeld == false` and the last applied value is `false`.
- **Stats:** no new `DeletionManager` API. WS-32's `CleanupStatsStoreTests` already cover `recordCompressionSavings(originalBytes:outputBytes:)`.

Device-only: interruption and screen lock (Device QA below).

### Acceptance criteria
- [ ] Under the default Auto-Lock, a 3-minute compression finishes with the device untouched (Device QA 2). Backgrounding mid-export shows the interrupted message with Resume, and Resume completes.
- [ ] The default preset is 1080p HEVC. For an HEVC source, "Maximum quality" is hidden or refused before export. Every row shows its codec plus an estimate and saving before the start.
- [ ] No replacement happens for a saving under 10% or under 20 MB (`testSavingsPolicy`).
- [ ] After `.replaced`, the screen shows "Saved X (A → B)" and the Recently Deleted note. `deletionManager.cleanupStats.lifetimeCompressionSavedBytes` grows by exactly original − output, and today's `.compressionOriginal` ledger entry grows by the original's bytes, through exactly one `recordCompressionSavings(originalBytes:outputBytes:)` call. Nothing is recorded on declined or failed.
- [ ] `grep -rn "isIdleTimerDisabled" iOSCleanup` still matches only `IdleTimerCoordinator.swift` (WS-29's acceptance). `grep -n "acquire(reason: \"compression\")" iOSCleanup/Views/Files/CompressionPresentation.swift` finds the hold, and `testCompressionHoldIsReleasedOnEveryExit` passes.
- [ ] `grep -rn "recordCompressionSavings(bytes:" iOSCleanup` finds nothing, and WS-44 adds no new lease type (it uses WS-28's `BackgroundTaskLease`).
- [ ] WS-36's entitlement guard in `VideoCompressionView` is untouched.
- [ ] Tests pass, there are no new warnings, and new files are in `project.pbxproj`.

### Device QA
Add to `docs/DEVICE_QA.md`:
1. Start compressing a 3 GB 4K video and press the side button mid-export. On return, the app shows the "interrupted" copy with Resume. Log and record the AVError domain and code.
2. Leave the device untouched with 30 s Auto-Lock during a 3-minute compression. It completes, and the screen stays on.
3. Compress an HDR clip with 1080p HEVC. It stays HDR in Photos (the HDR badge shows).
4. Pick an HEVC source. "Maximum quality" is absent, and the row estimates are within about 30% of the actual output.
5. After a replace, Home's "Finish freeing space" card (WS-32) includes the original's size, because it now sits in Recently Deleted. `testSavingsRecordedOnlyForReplaced` and WS-32's stats tests cover the `lifetimeCompressionSavedBytes` arithmetic.

### Pitfalls and out of scope
- Never run the export in the background, and no `BGContinuedProcessingTask` for compression in v1 (D-BACKGROUND). The hold must be released on every exit path, or the screen stays on forever.
- Keep every WS-43 guard, including invariant 25.
- Do not redesign the compression screen beyond text, rows and states (invariant 29).
- The row-level slo-mo refusal is WS-42. The iCloud download notice is WS-30 (chapter 07). The receipt and "Finish freeing space" card are WS-32 (chapter 07).
- **Reconciliation (README §9, contracts 6 and 7):**
  - Stats: the only stats call is WS-32's `recordCompressionSavings(originalBytes:outputBytes:)`, on `.replaced` only. The `(bytes:)` fallback and its `DeletionManagerTests` test are removed. The acceptance now checks `lifetimeCompressionSavedBytes` and the `.compressionOriginal` ledger rather than "Freed".
  - Idle timer: uses WS-29's `IdleTimerCoordinator.shared.acquire(reason: "compression")` / `release(_:)` through `CompressionIdleHold`, released on every exit. The test uses the `init(apply:)` seam unconditionally.
  - Lease: uses WS-28.2's `BackgroundTaskLease`. WS-44 no longer moves or creates it, and WS-28 is listed as a dependency.

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| FILES-08 | confirmed | There is no idle-timer, background-task or scene-phase handling (261-359), and failures are generic (453-455). The exact AVError code on backgrounding is device behavior, so the plan also classifies by scene phase and records the code in Device QA. It uses WS-29's coordinator and a shared lease, not direct `isIdleTimerDisabled` writes. |
| FILES-19 | confirmed | The default is `.p720` (12), the "Original Quality" label is on an HEVC re-encode (35-38), rows say "Analyze on start" (375-383), and any 1-byte saving is accepted (215-231). The plan keeps 720p as labeled H.264 (DECISION) rather than building an HEVC 720p composition, and backs the "hide Maximum quality" rule with an engine check for sources whose codec was unknown. |
| FILES-22 | confirmed | There are no bytes in the success banner and no stats (`recordConfirmedDeletion` is private, DeletionManager.swift:401). The plan uses WS-32's `recordCompressionSavings(originalBytes:outputBytes:)` instead of adding `recordExternalReclaim`. |
| Reconciliation (L6, L7) | n/a | The stats call and idle-timer API were placeholders; they now use the canonical WS-32 and WS-29 signatures. |

---

## WS-45 — Home leads with bytes

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M2 | M | WS-26, WS-27, WS-31, WS-32, WS-42 | no | `ws/45-home-bytes` |

**Primary files:**
- Home: `iOSCleanup/Views/HomeView.swift`, `iOSCleanup/Views/Home/HomeCTAAction.swift` (WS-31; extended in place), `iOSCleanup/Views/Home/HomeTileLayout.swift` (*new*), `iOSCleanup/Views/Home/HomeDashboardPresentation.swift` (WS-31), `iOSCleanup/Views/HomeViewModel.swift` (pass-throughs only), `iOSCleanup/Views/PhotoDuckShellView.swift`
- Photos: `iOSCleanup/Views/Photos/PhotoResultsView.swift`, `iOSCleanup/Views/Photos/GroupSortOrder.swift` (*new*)
- Tests: `iOSCleanupTests/HomeTileLayoutTests.swift` (*new*), `iOSCleanupTests/HomeCTAActionTests.swift` (*new*), `iOSCleanupTests/GroupSortOrderTests.swift` (*new*), `iOSCleanupTests/DesignLintTests.swift`, `iOSCleanupTests/HomeDashboardPresentationTests.swift` (WS-31; keep green)

**Findings covered:** UI-18 (P2, confirmed; merged: VALUE-18 partially), VALUE-11 (P2, confirmed; merged: UI-25 partially), UI-22 (P2, confirmed)

**Decisions applied:**
- **D-RESULTS-FRESHNESS:** only the photo durability window (`isFinalizingPhotoScan`, `isPhotoRunActive` after WS-28) and WS-27's videos-first pre-pass (`isVideoPrePassRunning`, "Checking large videos…") make the CTA non-interactive. The post-photo video pass (`isVideoPassRunning`) never blocks "Review N groups".
- **D-SCOPE:** v1 tiles are Large Videos, Screen recordings, Duplicates (including WS-40 burst extras if they are a separate kind), Screenshots, Blurry, Similar (review-only) and Export Album. Live Photo and RAW tiles are M4 (WS-59).

This workstream is cuttable (README §2). It covers ordering, badges, copy and functional layout only; the visual redesign waits for the design handoff.

### Goal
- The Home grid is ordered by device-reclaimable bytes, with review-only Similar and Export Album last, so on a video-heavy library Large Videos comes first with a GB badge.
- Every opportunity tile shows a ≈bytes badge.
- The big CTA never pauses a scan. During a scan it opens "Review N groups found so far" or is a plain status row, and Pause exists only in the scan footer.
- No copy mentions Speed Clean, Deep Clean or Smart Cleanup.
- Review lists default to the largest savings first, with a persisted sort choice.
- On first launch, the hero no longer duplicates the CTA, and the tiles are not buried under the tab bar.

### Current behavior (verified)
- **The tile order is hard-coded.** `HomeView.categoryGrid` (`Views/HomeView.swift:611-733`) lists Duplicates, Similar, Screenshots, Blurry, Export Album, Large Videos. Only Large Videos passes `sizeBadge` (713-714).
- **Screenshot and blurry bytes are missing.** `DashboardCollectionSummary.make` (`HomeViewModel.swift:54-117`) sums group bytes and large-video bytes but no screenshot or blurry bytes. WS-31 replaced this with `CleanupOpportunity` values sorted review-only-last, then by bytes, and WS-42 adds `.screenRecordings`.
- **The stat label is unexplained.** The stats row labels `reclaimableFormatted` "Photos + videos" (594-597). **After WS-32.4** that tile reads "On this iPhone" (device-only photo and large-video sizing), and "Freed with PhotoDuck" reads "Sent to Recently Deleted".
- **The CTA after WS-26/27/31.** WS-31.3 created `Views/Home/HomeCTAAction.swift`: the `HomeCTAAction` enum (`openSettings, startScan, pause, resume, refreshScan, route(HomeRoute), none`) plus `resolve(_ inputs: HomeDashboardInputs)`, holding today's branching verbatim, including `.deepCleanActive` → `.pause`. Hero and CTA copy and `ctaIsEnabled` live in `HomeDashboardPresentation.make`, pinned by `testNonCompletedStatesMatchLegacyCopy`. WS-27 added `isVideoPrePassRunning` ("Checking large videos…", `.none`, disabled) and `isVideoPassRunning` ("Review N groups ready" + `videoPassProgressLabel`). WS-26 replaced `restartPhotoScan()` with `startPhotoScan(from:)`.
- **The CTA pauses the scan.**
  - During `.deepCleanActive`, the CTA title is "Scanning your library…" (349-350). Its subtitle is `viewModel.scanActivityMessage ?? "Tap to pause"` (375); the message is nearly always set, so the hint never shows.
  - `handleCTAAction` calls `viewModel.pauseDeepClean()` (436-437).
  - The only explicit Pause is the footer button (826-837).
  - Partial results are reachable from the CTA only in `.speedCleanActive` (432-435), which nothing starts. `startSpeedClean` (`HomeViewModel.swift:826-828`) has no callers and WS-07 deletes it.
- **Retired mode names remain in user-facing strings.**
  - `HomeViewModel.swift:623, 625, 627, 684, 688, 714, 758-775, 1215` still say "Speed Clean" and "Deep Clean". WS-31 moves most of these into `HomeDashboardPresentation`/`CompletionNotificationContent`, so re-find them there.
  - `HomeView.swift:348` says "Speed Clean is scanning…".
  - `PhotoDuckShellView.swift:189` and `:240` say "Smart Cleanup", both for a fresh scan and for Duck Mode; `:238` says "Pause Deep Clean"; `:504` says "…start Smart Cleanup…".
- **The percentage can read 0%.** The Similar tab's "Can free up \(reclaimablePercent)% of storage" (151-155, 168) uses `Int(rounded)`, so 300 MB of 256 GB shows "0%". WS-32 replaces percent-of-device claims; check whether this line survived.
- **Groups are ordered oldest first.** `PhotoScanEngine.swift:1410-1418` sorts by preference priority, then capture date ascending. `PhotoResultsView.visibleGroups` (`PhotoResultsView.swift:29-35`) keeps that order, and deferred groups are appended at the end. `SimilarPhotosDashboardView.featuredGroups` is `Array(similarGroups.prefix(4))` (`PhotoDuckShellView.swift:109`).
- **Tile and tab contents differ.** The Home "Similar" tile shows only `visuallySimilarPhotoGroups` (631-643), while the "Similar" tab shows every group.
- **First launch (runtime RT-3).** The hero value is "Start cleanup" (`heroPrimaryMetricValue` `.idlePrompt`) directly above a CTA reading "Start scan", followed by a stats row of zeros. The category tiles start under the floating tab bar.

### Implementation plan

**WS-45.1 — Byte-ordered tiles with ≈ badges**
- **Why:** the highest-yield category (videos) is visually last, and most tiles show no bytes.
- **Change:** create `iOSCleanup/Views/Home/HomeTileLayout.swift`:
  ```swift
  enum HomeTileKind: Hashable { case opportunity(CleanupOpportunity.Kind), exportAlbum }
  struct HomeTileSpec: Identifiable, Equatable {
      let kind: HomeTileKind; let itemCount: Int; let sizing: ReclaimSizing   // WS-30/31 sizing of the opportunity
      let isReviewOnly: Bool
      var bytes: Int64 { sizing.totalBytes }
      var bytesAreEstimated: Bool { sizing.isEstimated }
      var id: HomeTileKind { kind }
      var sizeBadge: String?     // nil when bytes == 0 or isReviewOnly; else ByteText.approximate(sizing) ("≈" when estimated)
  }
  enum HomeTileLayout {
      static let canonicalOrder: [CleanupOpportunity.Kind]   // .largeVideos, .screenRecordings, .duplicates, .screenshots, .blurry, .similarReviewOnly
      static func make(opportunities: [CleanupOpportunity], exportAlbumCount: Int) -> [HomeTileSpec]
      /// Sum of every non-review-only opportunity's sizing (WS-59 later also skips supplementary kinds).
      static func reclaimableTotal(_ opportunities: [CleanupOpportunity]) -> ReclaimSizing
  }
  ```
- **Ordering rules** (the same keys as WS-31's opportunity sort, so the grid and the completion sheet agree):
  1. Non-review-only tiles by `sizing.deviceBytes` descending, then `sizing.totalBytes` descending, then `itemCount` descending, then canonical index.
  2. Then review-only tiles in canonical order.
  3. Then Export Album.
  4. Kinds missing from `opportunities` are filled with zero specs, so the grid is stable before the first scan (all zero means canonical order).
- **Grid.** In `HomeView.categoryGrid`, `ForEach(HomeTileLayout.make(...))` feeds `@ViewBuilder func tile(for spec: HomeTileSpec)`, which switches **exhaustively** over `CleanupOpportunity.Kind` with no `default`, so new kinds (WS-59, WS-62) fail to compile until they get a tile. Destinations, icons, colors, status and note keep their current values.
  - Screen recordings use WS-42's tile.
  - The Similar tile gets the status "Review only" (resolving UI-25's tile/tab mismatch without renaming the tab).
  - Keep `navigatesWhenEmpty` for Export Album.
  - Move the current `categoryStatus`, `categoryNote` and `largeVideoCategoryNote` helpers into a small `HomeTilePresentation` enum in the same new file, so `HomeView.swift` shrinks.
- **Stats row.** WS-32.4 already replaced "Photos + videos" with "On this iPhone". Keep WS-32's label and its device-only rule (unmeasured bytes are never iPhone space). Change only its input to `ByteText.stat(HomeTileLayout.reclaimableTotal(opportunities).deviceBytes)`, so the stat covers every non-review-only tile (screenshots, blurry and screen recordings included) and equals the sum of the tiles' device bytes. Do not rename it to "Could free".
- **Similar tab percentage.** WS-32.6 deleted `reclaimablePercent` and the "Can free up N%" line. Nothing to do here; verify with `grep -n "reclaimablePercent" iOSCleanup` (no match).
- **Edge cases:** while `fileScanState == .scanning`, video tiles keep their scanning note and no badge (the WS-42 behavior). The ordering uses the last known bytes.

**WS-45.2 — `HomeCTAAction`: a pure resolver that never pauses**
- **Why:** tapping the big button mid-scan silently pauses a multi-hour scan, and partial results are unreachable from it.
- **Change:** WS-31.3 created `iOSCleanup/Views/Home/HomeCTAAction.swift` with `enum HomeCTAAction: Equatable { case openSettings, startScan, pause, resume, refreshScan, route(HomeRoute), none }` and `static func resolve(_ inputs: HomeDashboardInputs) -> HomeCTAAction`. That resolver holds today's branching moved verbatim, including `.deepCleanActive` → `.pause`. `HomeDashboardPresentation.make` calls it and adds `ctaTitle`, `ctaSubtitle` and `ctaIsEnabled`. This workstream **extends that file in place and never declares a second enum, resolver or input type** (README §9, contract 26). It changes exactly three things:
  1. **Delete `case pause`.** After this workstream nothing produces it; Pause lives only in the scan footer, which calls `pauseDeepClean()` directly. This is the UI-18 fix. Remove the matching `switch` arm in `HomeView.handleCTAAction` in the same commit.
  2. **Rewrite the body of `resolve(_ inputs: HomeDashboardInputs)`** to the table below. It reads the fields WS-31 already carries: `heroState`; the group count; `isVideoPrePassRunning` (WS-27.6); `isVideoPassRunning` and `videoPassProgressLabel` (WS-27.2); `isPhotoRunActive` (the photo durability window, formerly `isFinalizingPhotoScan`, WS-28); and `outcome.primaryAction` (`ScanOutcomeSummary.PrimaryAction`).
  3. **Update `HomeDashboardPresentation.make`** so its CTA copy follows the same rows, and set `ctaIsEnabled = (ctaAction != .none)`. There is no separate copy type.
- **Resolution** (put this table in the doc comment; rows are checked top to bottom):

  | Hero state | Condition | Action | Copy (title / subtitle) |
  |---|---|---|---|
  | `permissionRequired` | — | `.openSettings` | WS-31's |
  | `scanFailure`, `idlePrompt` | — | `.startScan` | WS-31's |
  | `deepCleanActive` (and `speedCleanActive` if the case still exists) | `isVideoPrePassRunning` | `.none` (disabled) | "Checking large videos…" / "Photos start right after" (WS-27.6) |
  | same | `groupCount > 0` | `.route(.reviewGroups)` | "Review \(CountText.groups(n)) found so far" / activity message |
  | same | `groupCount == 0` | `.none` | "Scanning your library…" / activity message |
  | `deepCleanPaused` | — | `.resume` | WS-31's |
  | `completedResultsAvailable`, `reviewReadyPartialResults` | `isPhotoRunActive` (the durability window) | `.none` | "Finishing photo scan…" / "Saving the completed photo results" (WS-27.2) |
  | same | `groupCount > 0 && isVideoPassRunning` | `.route(.reviewGroups)` | "Review \(CountText.groups(n)) ready" / `videoPassProgressLabel` (WS-27.2) |
  | same | otherwise | from `outcome.primaryAction` | WS-31's completed-state copy |

  The `outcome.primaryAction` mapping is `.route(r)` → `.route(r)` (review groups, large videos, screen recordings, screenshots, blurry, retry unanalyzed, similar review-only), and `.done` → `.refreshScan`. Reuse WS-31's strings for completed states; do not invent new ones.
- **`HomeView`** keeps WS-31's `handleCTAAction` switch over `ctaAction`:
  - `.route(r)` → WS-31.4's `open(r)`. That covers `.reviewGroups` → `showReviewResults = true`, `.retryUnanalyzed` → WS-22's retry confirmation, and pushed routes → `homePath.append(r)`.
  - `.refreshScan` → WS-26's incremental user entry point, `viewModel.startPhotoScan(from: .homePrimaryCTA)`, which routes to `refreshPhotoScan()`. Never `.gearRescanConfirmed`/`rescanEntireLibrary()`; only the confirmed gear action forces a full rescan.
  - `.resume` → `viewModel.resumeDeepClean()`; `.startScan` → `viewModel.startDeepClean()`; `.openSettings` → unchanged.
  - For `.none` (`ctaIsEnabled == false`), render the same label without the chevron and without a `Button` (`.accessibilityElement(children: .combine)`), in place of WS-31's `.disabled(!presentation.ctaIsEnabled)` button.
- **`HomeViewModel`:** no new inputs. `HomeDashboardInputs` already carries every field the table reads.

**WS-45.3 — Copy: retire Speed Clean / Deep Clean / Smart Cleanup**
- **Why:** the copy advertises modes that don't exist, and one label covers two actions.
- **Change:**
  - **`HomeDashboardPresentation`** (WS-31) and wherever the hero copy lives now:
    - status: "Scanning your library" / "Scan paused";
    - permission detail: "Allow Photos access to find big videos, duplicates and screenshots.";
    - idle detail: "Finds big videos, duplicates and screenshots. Nothing is deleted without your OK.";
    - idle metric value: "Not scanned yet" (removes the "Start cleanup" versus "Start scan" duplication);
    - `speedCleanActive`, if the case survived: the same copy as `deepCleanActive`.
    - Keep `CleanupMode.speedClean` and the diagnostics values; they are persisted and internal.
  - **`PhotoDuckShellView`:**
    - `primaryActionTitle`: `.freshScan` → "Scan Library", `.review` → "Swipe Review";
    - the menu's "Smart Cleanup" → "Swipe Review", and "Pause Deep Clean" → "Pause Scan";
    - the empty state → "Run a scan from Home to find similar photos."
    - `SimilarPhotosPrimaryAction` and its test (`PhotoScanEngineTests.swift:1374-1403`) stay unchanged. The Similar tab's explicit "Pause" label is honest.
  - **Notification copy:** the notification string "Deep Clean is ready" (1215, or `CompletionNotificationContent` after WS-31) → "Your scan is ready".
- **Test:** add to `DesignLintTests`:
  ```swift
  func testNoRetiredModeNamesInUserFacingStrings() throws {
      let regex = try NSRegularExpression(pattern: #""[^"\n]*(Speed Clean|Deep Clean|Smart Cleanup)[^"\n]*""#)
      let offenders = try scanViews { line in regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil }
      XCTAssertTrue(offenders.isEmpty, "Retired mode names in user-facing strings: \(offenders)")
  }
  ```

**WS-45.4 — `GroupSortOrder`: largest savings first**
- **Why:** on a 50k library the first groups are old 2-photo pairs, and the 40-frame burst sits deep in the list.
- **Change:** create `iOSCleanup/Views/Photos/GroupSortOrder.swift`:
  ```swift
  enum GroupSortOrder: String, CaseIterable, Identifiable {
      case largestSavings, newest, oldest
      static let storageKey = "photoduck.results-sort"
      var id: Self { self }
      var title: String   // "Largest savings", "Newest", "Oldest"
      static func sorted(_ groups: [PhotoGroup], by order: GroupSortOrder) -> [PhotoGroup]
  }
  enum PhotoResultsOrdering {
      /// sort(regular) + deferred in deferral order; hidden removed. The single entry point WS-50 memoizes.
      static func visibleGroups(_ groups: [PhotoGroup], hiddenIDs: Set<UUID>,
                                deferredIDs: [UUID], sort: GroupSortOrder) -> [PhotoGroup]
  }
  ```
  - **`.largestSavings`:** groups where `isAutoCleanEligible` is true come first, by WS-30.9's `group.reclaimSizing.deviceBytes` descending, then `reclaimSizing.totalBytes` descending. Then review-only groups by `photoCount` descending. Ties break by `id.uuidString`.
  - **`.newest` / `.oldest`:** by `captureDateRange?.start ?? .distantPast`, with ties by ID.
- **`PhotoResultsView`:**
  - Add `@AppStorage(GroupSortOrder.storageKey) private var sortRaw = GroupSortOrder.largestSavings.rawValue`.
  - `visibleGroups` becomes `PhotoResultsOrdering.visibleGroups(...)`.
  - Add a sort `Menu` in the filter-pill row.
- **`SimilarPhotosDashboardView`:** `featuredGroups = Array(GroupSortOrder.sorted(similarGroups, by: .largestSavings).prefix(4))`, and `groupIndex` still resolves from `similarGroups`.
- **Edge cases:**
  - Sorting never changes keeper or delete-candidate data; it reorders whole `PhotoGroup` values (invariant 1).
  - Auto-clean's planner (WS-12) receives groups in the new order, so the first batch holds the largest groups. That is acceptable, because it never splits a group.
  - The Duck Mode queue order is unchanged.

**WS-45.5 — Functional first-launch layout (runtime RT-3)**
- **First step:** in the simulator (iPhone 17 Pro), take `xcrun simctl io booted screenshot` of first launch (idle, no results) and of the WS-07 fixture state. Put both in the PR.
- **Change:**
  - Add a pure `HomeLayoutPolicy.showsStatsRow(heroState:hasAnyResults:lifetimeItemsFreed:) -> Bool` in `HomeTileLayout.swift`. It is false for `.idlePrompt` and `.permissionRequired` when there are no results and nothing has been freed. Hide the stats row when it is false.
  - With the hero duplication gone (WS-45.3), the first tile row should sit above the tab bar at first paint.
  - Make sure the last tile can scroll fully above the floating tab bar. Increase the scroll content's bottom padding (today 32) until it does; 96 matches other screens.
- **After screenshots:** first launch shows the CTA and the first tile row fully visible, and the last tile scrolls clear of the tab bar.

**WS-45.6 — (Optional, copy only) Photos' Duplicates album pointer**
- Interim for SCAN-17 until WS-61 ships.
- At the bottom of `PhotoResultsView`'s list, and in its empty state, add a caption: "Exact copies saved on different days? iOS also lists them in Photos › Albums › Utilities › Duplicates."
- No deep link.

### Tests
All simulator unit tests.

**`iOSCleanupTests/HomeTileLayoutTests.swift`** (new). Build `CleanupOpportunity` fixtures:
- `testTilesSortByDeviceBytesDescending`: Large Videos 25 GB, Screenshots 2 GB, Duplicates 1 GB gives that order.
- `testReviewOnlySimilarAndExportAlbumComeLast`.
- `testTiesUseItemCountThenCanonicalOrder`.
- `testEmptyStateUsesCanonicalOrderWithAllTiles`.
- `testSizeBadgeUsesApproxPrefixWhenEstimatedAndNilForReviewOnly`.
- `testReclaimableTotalExcludesReviewOnly`: the returned `ReclaimSizing` sums the non-review-only sizings field by field.
- `testStatsRowHiddenOnFirstLaunchOnly`.

**`iOSCleanupTests/HomeCTAActionTests.swift`** (new; builds `HomeDashboardInputs` fixtures and calls WS-31's `HomeCTAAction.resolve`)
- `testScanningWithGroupsReviewsResults` (`.route(.reviewGroups)`) and `testScanningWithoutGroupsIsNonInteractive` (`.none`).
- `testScanningNeverResolvesToPauseLikeAction`: every `HeroState` with a group count of 0 and 5, and every combination of the three flags. `.deepCleanActive` resolves only to `.route(.reviewGroups)` or `.none`. `HomeCTAAction` has no `pause` case, so the compiler enforces the rest.
- `testVideoPrePassIsNonInteractive` (contract 26): `.deepCleanActive` with `isVideoPrePassRunning: true` → `.none` for group counts 0 and 5.
- `testCompletedWithGroupsDuringVideoPassReviewsResults`: the STATE-04 case, `resolve(.completedResultsAvailable, groups: 3, isVideoPassRunning: true) == .route(.reviewGroups)`.
- `testFinalizingPhotoScanIsNonInteractive`.
- `testPausedResumes` (`.resume`), `testPermissionOpensSettings` and `testIdleStartsScan`.
- `testCompletedMapsSummaryActionAndNeverRestarts`: `.route(.screenshots)` → `.route(.screenshots)`, `.route(.screenRecordings)` → `.route(.screenRecordings)`, and `.done` → `.refreshScan`.
- In `HomeDashboardPresentationTests` (WS-31's file): add `testCopyForScanningWithGroups` ("Review 12 groups found so far", via `CountText`) and `testCTAIsEnabledExactlyWhenActionIsNotNone`. Update the `.deepCleanActive` rows of `testNonCompletedStatesMatchLegacyCopy` to the new copy, because this workstream intentionally changes them (no pause). Its pre-pass, finishing and video-pass rows stay unchanged. WS-31's other tests, including `testCompletedNoFindingsCTARefreshesIncrementally`, stay green.

**`iOSCleanupTests/GroupSortOrderTests.swift`** (new)
- `testLargestSavingsPutsEligibleFirstByBytes`, `testReviewOnlyOrderedByPhotoCount` and `testTiesAreStableByID`.
- `testNewestAndOldest`.
- `testVisibleGroupsKeepsDeferredSuffixAndDropsHidden`.
- `testFeaturedGroupsAreTopFourBySavings`: exercise `sorted(…).prefix(4)`.

**`DesignLintTests.testNoRetiredModeNamesInUserFacingStrings`** (WS-45.3).

Keep `testSimilarPhotosPrimaryActionProtectsActiveScanProgress` green and unchanged.

Device-only: the time-to-first-GB step below.

### Acceptance criteria
- [ ] Home tiles are sorted by device-reclaimable bytes, with review-only Similar and Export Album last. Every non-review-only tile with bytes shows a ≈ badge (`HomeTileLayoutTests`).
- [ ] The primary CTA never pauses a scan. Mid-scan with groups, it opens results. `grep -n "pauseDeepClean" iOSCleanup/Views/HomeView.swift` shows only the scan-footer call. There is exactly one `enum HomeCTAAction` in the target (`grep -rn "enum HomeCTAAction" iOSCleanup` gives one match, in `HomeCTAAction.swift`), and it has no `pause` case.
- [ ] While the post-photo video pass runs, "Review N groups" stays tappable (STATE-04 test). During the videos-first pre-pass the CTA reads "Checking large videos…" and is not a button (`testVideoPrePassIsNonInteractive`).
- [ ] `DesignLintTests.testNoRetiredModeNamesInUserFacingStrings` passes. "Swipe Review" is used consistently.
- [ ] Results default to largest savings first, and the sort choice persists across relaunch. The Similar tab's featured groups are the top 4 by savings.
- [ ] The before and after simulator screenshots show no hero/CTA duplication on first launch, and tiles reachable above the tab bar.
- [ ] Tests pass, there are no new warnings, and new files are in `project.pbxproj`. `CLAUDE.md` navigation and the Home description mention byte-ordered tiles and "Swipe Review".

### Device QA
Add to `docs/DEVICE_QA.md`:
1. **M2 exit check.** On a 10k library with videos, measure the time from finishing onboarding to the first GB moved to Recently Deleted (via the Large Videos tile, which should be first). Target: 5 minutes or less. Record the time and the path taken.
2. Mid-scan, tap the big CTA. The scan keeps running: if groups exist, the results sheet opens; otherwise nothing happens.
3. After the scan, check that the tile order matches the tile badges.

### Pitfalls and out of scope
- **No visual redesign** (invariant 29). Only ordering, badges, copy and the two layout fixes.
- **Do not grow `HomeView.swift` or `HomeViewModel.swift`.** New logic goes in the new files, and `HomeViewModel` only gets pass-throughs (invariant 28).
- **`.refreshScan` must never force a full rescan.** It goes through `startPhotoScan(from: .homePrimaryCTA)`, never `.gearRescanConfirmed`.
- **Reconciliation (README §9, contracts 10 and 26, and ch06/ch07 issues):**
  - CTA enum: WS-45 extends WS-31's `HomeCTAAction` and uses its case names (`.resume`, `.refreshScan`, `.route(HomeRoute)`, `.none`). The chapter's earlier `resumeScan`/`reviewResults`/`openOpportunity`/`retryUnanalyzed`/`scanAgain` cases, its own `Input` struct and the `HomeCTACopy` type are dropped. It rewrites WS-31's `resolve(_ inputs: HomeDashboardInputs)` in WS-31's file, deletes only `.pause` (UI-18), and adds the `isVideoPrePassRunning` (disabled "Checking large videos…") and `isVideoPassRunning` (`.route(.reviewGroups)`) rows.
  - Inputs and entry points: the completed-state action comes from WS-31's `outcome.primaryAction` (`ScanOutcomeSummary.PrimaryAction`) inside `HomeDashboardInputs`, and `.refreshScan` uses WS-26's `startPhotoScan(from: .homePrimaryCTA)` → `refreshPhotoScan()`. Tiles use `CleanupOpportunity.Kind`.
  - Stats: the stats row keeps WS-32.4's "On this iPhone" label, and the percent line is already gone (WS-32.6).
- **Belongs to other workstreams:**
  - memoizing `PhotoResultsPresentation` (WS-50, chapter 11), which must call `PhotoResultsOrdering.visibleGroups`;
  - navigation stability and accessibility (WS-55, chapter 12);
  - contrast and hit targets (WS-56, chapter 12);
  - Live Photo and RAW tiles (WS-59, chapter 13);
  - the duplicate-videos tile (WS-62, chapter 13).

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| UI-18 | confirmed | `.deepCleanActive` → `pauseDeepClean()` (HomeView.swift:436-437), the "Tap to pause" fallback is effectively hidden (375), and partial results are reachable only via the dead `.speedCleanActive` branch. The plan follows the fix. The resolver has no pause case at all, and adds the STATE-04 video-pass case. |
| VALUE-18 (merged) | partially | The CTA-pauses-scan problem and the "Smart Cleanup" naming (PhotoDuckShellView.swift:189, 240) are confirmed. `heroSecondaryActionLabel`/`heroNextActionLabel` are stale: WS-07 deletes them. |
| VALUE-11 | confirmed | Hard-coded order (611-733), only Large Videos badged (713), no screenshot or blurry bytes in the summary (54-117), idle Speed Clean copy (HomeViewModel.swift:714), and "0%" (PhotoDuckShellView.swift:151-168). Tiles come from WS-31's opportunities. The percent line may already have been replaced by WS-32, so the plan only touches it if it survived. |
| UI-25 (merged) | partially | The Speed Clean copy and the naming are confirmed. The dead hero helpers are stale (WS-07). The paywall feature list belongs to WS-36. The tile-versus-tab mismatch is resolved with a "Review only" tile status instead of renaming the tab. |
| UI-22 | confirmed | Engine order is priority, then date ascending (PhotoScanEngine.swift:1410-1418), used unchanged by PhotoResultsView (29-35) and `featuredGroups` (PhotoDuckShellView.swift:109). The plan follows the fix. Sorting lives in `PhotoResultsOrdering` so WS-50's memo reuses it. |
