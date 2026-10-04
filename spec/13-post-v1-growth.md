# Chapter 13 — Post-v1 growth: Live Photos, RAW, cross-date copies, duplicate videos, presets, retention

> **Milestone(s):** M4 · **Workstreams:** WS-59 – WS-64 · Read `spec/README.md` first: operating rules, invariants, build/test commands and the decision log apply to every workstream here.

## Chapter overview

These six workstreams add the reclaim categories and the retention loop that v1 deliberately left out (D-SCOPE, D-GROWTH). Each one builds on a layer that v1 proved on devices:
- WS-30's measurer and locality model;
- WS-38's pixel/text verification;
- WS-11's deletion API;
- WS-36's entitlement policy;
- WS-39's injectable threshold profile.

When the chapter is done, users see how much space Live Photo motion takes and can convert chosen Live Photos to stills. They can find RAW and 48 MP originals, identical copies saved weeks apart, and re-encoded duplicate videos. They can make "Similar" stricter without touching Keep Best. A monthly card, a recap card, a widget, a Siri phrase and an opt-in reminder bring them back. The key risk is **WS-60**: it is the only workstream in the plan that *creates* photos and then deletes originals, so a declined prompt, a failed verification or a crash must never leave silent duplicates or lose an effect, an edit, hidden state or an album. The second risk is **WS-63**: review-only thresholds interact with destructive clusters (see WS-63 "Current behavior"), so presets are implemented as a review-only filter and never re-run clustering.

**Order.** WS-59 → WS-60 is a strict chain. WS-61 → WS-62 is a chain, because WS-62 reuses WS-61's `PerceptualHash`. WS-63 and WS-64 are independent of the rest. Execute in numeric order.

**Archived planning docs.** WS-58 moved `ROADMAP.md` (and `FIXSPEC.md`, `PERFORMANCE_MASTER_PROMPT.md`) to `docs/archive/` and prepended a header. `ROADMAP.md:NN` citations in this chapter point at `docs/archive/ROADMAP.md`; their line numbers are pre-archive, so re-find the text by content.

### Types this chapter consumes

Names follow their chapters. If a landed name differs, use the landed one and record it under **Deviations** in the PR.

| Type / API | From | Used by |
|---|---|---|
| `AssetDeviceFootprintMeasurer`, `LiveAssetResourceFootprintSource`, `ResourceMeasurement.Outcome.classify`, `AssetFootprintMath.combine`, `AssetStorageLocation`, `AssetDeviceFootprint`, `ReclaimSizing`, `AssetLocalityPolicy.recheckInterval`, `AssetResourceSizePolicy.livePhotoMotionEstimateBytes` / `estimatedResourceBytes`, `AssetFileSizeRepository.records(for:)` / `mergeFootprints(_:)` / `warmMemoryCache(for:)`, `ReclaimMeasurementController` (`isMeasuring`, `canMeasure` rule) | WS-30 (ch. 07) | WS-59, WS-60 |
| `PhotoKitRequestState<Value>` | WS-10 (ch. 02) | WS-59, WS-62 |
| `DeletionManager.delete(assets:requiredKeeperIDs:knownBytes:) -> DeletionResult`, `DeletionReceipt`, `DeletionContext`, `DeletionManager.isUserCancellation`, `ResolvedPhotoAssets` | WS-11 (ch. 03) | WS-59, WS-60, WS-62 |
| `DeletionManager.confirmedDeletions`, `HomeViewModel.applyConfirmedDeletion(assetIDs:)` | WS-21 (ch. 04) | WS-59, WS-60, WS-62, WS-64 |
| `CleanupAccessPolicy`, `CleanupAction.convertLivePhotos(count:)` / `.manualDelete` / `.bulkSelect`, `ManualDeleteSurface`, `BulkSelectSurface`, `PaidFeature.livePhotoBatchConversion`, `PaywallRequest`, `.paywallGate(_:)`, `purchaseManager.canUse(_:)` | WS-36 (ch. 08) | WS-59, WS-60, WS-62 |
| `CategorySelectionModel`, `CategorySortOrder`, `CategoryAssetSize`, `PhotoCategoryReviewView(category:…)`, `SwipeQueueSource`, `SwipeQueueBuilder` | WS-41 (ch. 09) | WS-59, WS-60, WS-64 |
| `VideoKind`, `makeMeasuredVideo`, `FileScanResult`, `VideoInventorySummary`, `LargeVideoScanController`, serialized `LargeVideoResultCache` writes (WS-27.1 pattern) | WS-42 / WS-16 / WS-27 | WS-62 |
| `PhotoLibraryChangePerforming`, `ReplacementAlbumCandidate`, `ReplacementPlanner.albumIdentifiersToCarry`, `CreatedAssetIdentifierBox` | WS-43 (ch. 09) | WS-60 |
| `ScanOutcomeSummary`, `ScanOutcomeInputs`, `CleanupOpportunity` and its nested `CleanupOpportunity.Kind` (the only name; README §9 contract 10), `HomeRoute`, `HomeRouteDestinationView`, `CountText`, `ByteText`, `CleanupReviewTarget`, `NotificationTargetRouting`, `CleanupNotificationRouter.consumePendingTarget()` | WS-31 (ch. 07) | all |
| `HomeTileLayout`, `HomeTileSpec`, exhaustive `tile(for:)` | WS-45 (ch. 09) | WS-59, WS-62 |
| `CleanupStats` (decodeIfPresent decoder), `CleanupStatsStore(defaults:now:)`, `CleanupStatsStoreTests` | WS-32 (ch. 07) | WS-60, WS-64 |
| `DuplicateVerificationService`, `DuplicateVerificationGate`, `KeepBestEvidenceCollector`, `KeeperTieBreaker`, `ScreenshotHashIndex`, `PreferenceAdjustedRecommendationInput.isVerifiedIdenticalCluster` | WS-38 (ch. 08) | WS-61 |
| `SimilarityThresholdProfile` (`destructive`, `reviewOnly`, `scoring`, `.standard`, `revision`), `PhotoScanEngine.init(thresholdProfile:)`, profile-injected classifiers | WS-39 (ch. 08) | WS-61, WS-63 |
| `PhotoScanWorkingSet`, `PhotoScanResidentFeatures`, `PhotoScanContextStream`, `incrementalAssets` (extended window) | WS-23 (ch. 05) | WS-61 |
| `PhotoLibraryFetch.imageOptions()` / `videoOptions()` / `identifierOptions()`, `PhotoFetchLintTests` (no `options: nil`, no `PHFetchOptions()` outside `PhotoLibraryFetch.swift`); `PhotoGroup.autoCleanPolicy` (passed through every rebuild site) | WS-18 / WS-40 (ch. 04, 08) | WS-59, WS-60, WS-62, WS-63 |
| `PhotoAssetAnalysisPipeline` (calls `PhotoScanEngine.makePerceptualHash`) | WS-22 / WS-37 | WS-61 |
| `PhotoEmbeddingCachePolicy.capacity` (warm cache = 10,000 newest photos), `PhotoMLBridge.cachedAssetAnalyses(for:)` | WS-46 (ch. 10) / today | WS-61, WS-63 |
| `StorageAndDataView` (with the `// WS-63` marker), `LocalDataClearing`, `PhotoDuckLocalDataReset`, `PhotoDuckStorageFootprint` | WS-48 (ch. 10) | WS-62, WS-63 |
| `PhotoDuckStorage.directory(_:)` | WS-34 (ch. 07) | WS-62 |
| `HomeViewModelDependencies` (`defaults`, `mlBridge`, …), `ConfigurablePhotoScanTestAsset`, `TestEmbeddings`, `TestKeeperSignals`, `PhotoScanEngineEndToEndTests`, `StubDuplicateVerifier` | WS-07 / WS-08 / WS-38 | all |
| `CompletionNotificationService` (`refreshAuthorization`, `requestAuthorization`) | WS-15 (ch. 04) | WS-64 |
| `LargeVideoScanController.run(budget:)`, `passGeneration` and `invalidateAndCancelCurrentPass()` (a pass that started before WS-48's Clear never writes afterwards; README §9 contract 24) | WS-27 (ch. 06) | WS-62 |
| `IdleTimerCoordinator.shared.acquire(reason:)` / `release(_:)` (test seam `init(apply:)`) | WS-29 (ch. 06) | WS-60 |
| `PhotoScanCoordinator` (the scan lifecycle, including WS-30's `ReclaimMeasurementController` cancel/refresh hooks), unless WS-49 was cut | WS-49 (ch. 11) | WS-59, WS-62, WS-64 |
| `PhotoScanWorkingSet.edges: [SimilarityPairKey: RetainedPairEdge]`, `CompactPairEligibility` (`UInt8` flags), generic `formClusters`, `PhotoScanScaleGoldenTests`; no frontier pruning | WS-53 (ch. 11) | WS-61 |
| `CachedPhotoAnalysisSnapshot` encoding, `testSnapshotEncodingAt150kFitsUnderCap` (< 64 MB), the ≤ 160 MB footprint record | WS-54 (ch. 11) | WS-62, WS-63 |
| `HomeTileRoute.route(for:)` (exhaustive over `HomeTileKind`), `homePath: NavigationPath`, `HomeCategoryTile(route:)`, `PhotoGroupRoute` | WS-55 (ch. 12) | WS-59, WS-62 |
| `DuckTone`, `StatusBadge(title:tone:onDark:)`, `DuckChipButtonStyle`, `DuckTextLinkLabel`, and the `DesignLintTests` rules (plurals via `CountText`, controls sized inside their label, no brand-colored text on light surfaces, no raw corner radii) | WS-56 (ch. 12) | all UI |
| `ExportActivityAttributes.swift`'s shared `ContentState` presentation extension and the `.interrupted` phase | WS-57 (ch. 12) | WS-64 |
| App Store review prompt (`ReviewPromptModifier`, only if the owner accepted D-GROWTH) | WS-58 (ch. 12) | WS-64 (never duplicated) |

### Rules shared by every workstream in this chapter

1. **Supplementary opportunity kinds.** WS-59 adds `CleanupOpportunity.Kind.livePhotoMotion` and `.largePhotos`, and WS-62 adds `.duplicateVideos`. They overlap other categories: a RAW can also be a duplicate delete candidate, a duplicate video can also be a large video, and motion bytes belong to photos counted elsewhere. WS-59.1 adds `Kind.isSupplementary`. Supplementary kinds get tiles and routes, and WS-45 sorts them by bytes like any other tile. They are **excluded** from:
   - every combined byte total: the `ScanOutcomeSummary` headline, `HomeTileLayout.reclaimableTotal`, WS-32's storage card and WS-64's widget total;
   - the choice of `primaryAction` while any non-supplementary actionable opportunity exists.
2. **Idle-time PhotoKit work runs one worker at a time.** WS-30's `ReclaimMeasurementController` runs only when `canMeasure` holds (`!isPhotoRunActive && !isVideoPassRunning && scenePhase == .active`, plus WS-25's thermal gate). This chapter adds two idle workers under the same gate, chained in this fixed order:
   1. reclaim measurement (WS-30);
   2. `StorageInsightsController` (WS-59);
   3. `DuplicateVideoScanController` (WS-62).

   A worker starts only when the previous one is idle. All of them cancel when a photo run or video pass starts and on `.background`. Invariant 16 extends to them: none of them ever loads PhotoKit concurrently with a scan.

   If WS-49 landed, WS-30's cancel and refresh calls live in `PhotoScanCoordinator` (its `reclaimMeasurement` collaborator). Hook the new workers at exactly those points: pass them to the coordinator as collaborators too, and keep `PhotoScanCoordinatorHost` at 12 requirements or fewer. Otherwise hook them next to WS-30's calls in `HomeViewModel`.
3. **One size-persistence path.** Every byte measurement is stored through `AssetFileSizeRepository`. This chapter adds exactly two other persisted things:
   - WS-62's `video-inventory-v1.json`, under `PhotoDuckStorage`: backup-excluded, cleared by Storage & Data, not written under Limited access;
   - WS-60's conversion journal, in UserDefaults: safety data, never cleared by Storage & Data.
4. **Limited access (D-LIMITED-ACCESS, invariant 15).** New derived state stays in memory under `.limited`. Per-asset repository records may be written, as WS-30 allows, but nothing prunes.
5. **Destructive paths.** Only WS-61 adds an *automated* destructive path: verified cross-date identical copies. It goes through the same pair classifier, WS-38 gate, `PhotoGroup.init` and guardrails as every other plan (invariants 1–3, 6, 7). Every other deletion in this chapter is user-selected, goes through `DeletionManager` and shows the D-GATING lock before effort (invariants 4, 10).
6. **The simulator cannot run Vision** (runtime finding RT-1). It also has no Live Photos, RAW files or iCloud-only assets. Everything here is unit-tested through injected protocols. Every PhotoKit behavior claim gets a Device QA step.
7. **UI follows chapter 12's contracts.** Every new view passes WS-56's `DesignLintTests`:
   - counts go through `CountText` (never `"\(n) photos"`);
   - text on light surfaces uses `DuckTone`/`*Text` tokens, and badges are `StatusBadge(title:tone:)`;
   - controls size inside their label (`DuckChipButtonStyle`, `DuckTextLinkLabel`);
   - radii come from `DuckRadius` only.

   Home tiles push `HomeRoute` values through WS-55's `HomeTileRoute`. Lists push values; they never use view-destination `NavigationLink`s.
8. **PhotoKit fetches use WS-40's factories.** Every `PHAsset.fetchAssets(…)` starts from `PhotoLibraryFetch.imageOptions()`, `videoOptions()` or `identifierOptions()`, and mutates the result for an extra predicate, `fetchLimit` or `includeHiddenAssets`. `PhotoFetchLintTests` rejects `options: nil` and any `PHFetchOptions()` outside `PhotoLibraryFetch.swift`, DEBUG code included.

---

## WS-59 — Live Photo and RAW/48 MP measurement

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M4 | M | WS-30, WS-45 | no | `ws/59-live-photo-raw-measurement` |

**Primary files:**
- Engines: `iOSCleanup/Engines/LivePhotoScanner.swift` (*new*), `iOSCleanup/Engines/LargePhotoScanner.swift` (*new*), `iOSCleanup/Engines/AssetDeviceFootprintMeasurer.swift` (extract one helper), `iOSCleanup/Engines/PhotoScanEngine.swift` (one enum case only)
- Models and utilities: `iOSCleanup/Utilities/PHAsset+FileSize.swift` (record field + batch merge), `iOSCleanup/Models/AssetStorageLocation.swift` (`ReclaimSizing.isExtrapolated`)
- Home: `iOSCleanup/Views/Home/StorageInsightsController.swift` (*new*), `iOSCleanup/Views/Home/ScanOutcomeSummary.swift`, `iOSCleanup/Views/Home/HomeTileLayout.swift`, `iOSCleanup/Views/Home/HomeTileRoute.swift` (WS-55), `iOSCleanup/Views/Home/HomeRouteDestinationView.swift`, `iOSCleanup/Views/Home/HomeViewModelDependencies.swift`, `iOSCleanup/Views/HomeViewModel.swift` (pass-throughs only), `iOSCleanup/Views/Home/PhotoScanCoordinator.swift` (worker hooks, if WS-49 landed)
- Photos: `iOSCleanup/Views/Photos/LivePhotoMotionExplainerView.swift` (*new*), `iOSCleanup/Views/Photos/PhotoCategoryReviewView.swift`, `iOSCleanup/Views/Photos/CategorySelectionModel.swift`
- Store: `iOSCleanup/Store/CleanupAccessPolicy.swift`
- Tests: `iOSCleanupTests/LivePhotoScannerTests.swift` (*new*), `iOSCleanupTests/LargePhotoScannerTests.swift` (*new*), `iOSCleanupTests/SupplementaryOpportunityTests.swift` (*new*), `iOSCleanupTests/StorageInsightsControllerTests.swift` (*new*), `iOSCleanupTests/CleanupAccessPolicyTests.swift`, `iOSCleanupTests/HomeTileLayoutTests.swift`, `iOSCleanupTests/HomeTileRouteTests.swift` (WS-55)
- Project and docs: `iOSCleanup.xcodeproj/project.pbxproj`, `CLAUDE.md`

**Findings covered:** VALUE-09 (P1, confirmed; phase 1 here, phase 2 is WS-60), VALUE-14 (P2, confirmed)

**Decisions applied:**
- **D-LIVEPHOTO:** step one: measure and disclose sampled "≈" motion bytes. Conversion is WS-60.
- **D-SCOPE:** M4. WS-59.1–59.2, 59.4 and the Live Photo half of 59.5 do not depend on the RAW half, so the owner can pull them into v1 (option 3).
- **D-GATING:** deleting one RAW or 48 MP photo is free. Multi-select and Select All are Pro, locked before selection.
- **D-FAVORITES-USER:** favorites are listed in RAW & 48 MP but excluded from bulk selection (WS-41 rule). Favorite Live Photos are excluded from the eligible count (they are excluded from conversion by default).
- **D-LIMITED-ACCESS:** summaries are computed in memory, per-asset records may be stored, and nothing is pruned.

### Goal
- Home shows a **Live Photos** tile: "≈X of motion on this iPhone". X is measured on a deterministic sample of up to 200 eligible Live Photos and extrapolated with "≈". An explainer says what motion is, how the figure was estimated, what was not counted, and what the user can do today.
- Home shows a **RAW & 48 MP** tile. It opens the category grid sorted largest first, where sizes are measured by WS-30's measurer (typed "≈" estimates for the rest). Deletion follows `CleanupAccessPolicy`.
- Neither category is added to any combined byte total.

### Current behavior (verified)
- `iOSCleanup/Utilities/PHAsset+FileSize.swift:99-117` `AssetResourceSizePolicy.representative`, doc comment: "Related resources such as adjustment data and a Live Photo's paired video are never summed."
- `iOSCleanup/Utilities/PHAsset+FileSize.swift:233-243`: image ranks cover `fullSizePhoto`, `photo`, `alternatePhoto` and `adjustmentBasePhoto` only. Paired-video kinds have no image rank.
- `.photoLive` is read only to fill descriptors and ML features: `SimilarityPolicyTypes.swift:377`, `PhotoMLBridge.swift:65` and `PhotoMLStore.swift:479`. No count, category or tile exists.
- `grep -rn "smartAlbumRAW\|pixelWidth >=" iOSCleanup` finds nothing. `PhotoScanEngine.swift:1652-1667` `assetPriority` adds 40 for ≥12 MP and 20 for ≥8 MP, but only to order work.
- `iOSCleanup/Engines/PhotoScanEngine.swift:1742-1745`: `enum PhotoReviewCategory { case screenshot, blurry }`.
- `ROADMAP.md:19` defers Live Photo conversion.
- After WS-30:
  - `LiveAssetResourceFootprintSource` streams **every** resource of an asset with network off.
  - `estimatedResourceBytes` gives `livePhotoMotionEstimateBytes` (2,000,000) for paired-video kinds and 1.5 B/px for RAW types.
  - The repository holds 60,000 records and `mergeFootprints` writes once per call.
- After WS-45: `HomeView.categoryGrid` renders `HomeTileLayout.make(...)` through an exhaustive `switch` on the opportunity kind, so new kinds fail to compile until they get a tile.

### Implementation plan

**WS-59.1 — Shared plumbing: supplementary kinds, extrapolated sizing, a streaming helper**
- **Why:** New categories overlap existing ones. Adding them to totals would double-count bytes, which breaks WS-32's "numbers are honest" guarantee.
- **Change:**
  1. `Models/AssetStorageLocation.swift`: add `var isExtrapolated = false` to `ReclaimSizing`.
     - `isEstimated` becomes `isExtrapolated || iCloudOnlyBytes > 0 || unknownLocalityBytes > 0`.
     - `+` ORs the flag.
     - Add `static func extrapolated(device: Int64, iCloudOnly: Int64, unknown: Int64) -> ReclaimSizing`, which sets the flag.
     - WS-30 code never sets it.
  2. `Views/Home/ScanOutcomeSummary.swift`:
     - Add `case livePhotoMotion, largePhotos` to `CleanupOpportunity.Kind`.
     - Add `var isSupplementary: Bool`, true for exactly these two. WS-62 adds `.duplicateVideos`.
     - `ScanOutcomeInputs` gains `livePhotoCount = 0`, `livePhotoSizing = ReclaimSizing.zero`, `largePhotoCount = 0` and `largePhotoSizing = .zero`, defaulted so existing tests compile.
     - `make` builds these opportunities when their count is above 0. They count toward `.findings`.
     - Exclude them from the headline byte sums.
     - `primaryAction` becomes: the first non-review-only, non-supplementary opportunity; else `.retryUnanalyzed` when `unanalyzed > 0` (WS-31's rule, unchanged); else the first supplementary one; else similar; else `.done`.
     - Detail lines include them ("12,340 Live Photos · ≈24 GB of motion").
     - `CompletionNotificationContent` picks its top line with the same preference.
  3. `Views/Home/HomeTileLayout.swift`:
     - `canonicalOrder` gains `.largePhotos` and `.livePhotoMotion`, after `.blurry` and before `.similarReviewOnly`.
     - `reclaimableTotal(_:)` skips `isSupplementary`.
     - Add the two `tile(for:)` cases:
       - **Live Photos:** SF Symbol `livephoto`, title "Live Photos", `sizeBadge` from sizing ("≈" whenever `isEstimated`, which includes every extrapolated figure), note `"Estimated from \(CountText.photos(n))"` when extrapolated.
       - **RAW & 48 MP:** SF Symbol `camera.aperture`, title "RAW & 48 MP", `sizeBadge`.
     - Use existing tile components and tokens only (invariant 29). Tile colors are a `DuckTone` (WS-56): `.accent` for Live Photos, `.secondary` for RAW & 48 MP.
  4. `HomeRoute` gains `.livePhotos` and `.largePhotos` (both pushed; `isPushed` returns `true`). `HomeRouteDestinationView` builds `LivePhotoMotionExplainerView` and `PhotoCategoryReviewView(category: .largePhoto, …)` (WS-59.5). WS-55's exhaustive `HomeTileRoute.route(for:)` gains `case .livePhotoMotion: return .livePhotos` and `case .largePhotos: return .largePhotos`. `HomeTileRouteTests.testEveryTileKindMapsToAPushedRoute` then covers both.
  5. `Engines/AssetDeviceFootprintMeasurer.swift`: extract the per-resource streaming body of `LiveAssetResourceFootprintSource.measureResources(of:)` into:
     ```swift
     extension LiveAssetResourceFootprintSource {
         /// Streams one resource with network OFF and returns its local byte count or why it is not local.
         /// Unchanged WS-30 semantics: counter only (never retains data), 30 s watchdog, cancellation-safe.
         static func streamLocalBytes(of resource: PHAssetResource) async -> ResourceMeasurement.Outcome
     }
     ```
     `measureResources(of:)` calls it in its loop. This is a behavior-neutral refactor, and WS-30's tests stay green.
- **Edge cases:**
  - `ReclaimSizing` equality now includes the flag. `testReclaimableBytesEqualsSizingTotal` (WS-30) is unaffected.
  - WS-32's `StorageCardPresentation.make` takes only photo and large-video sizing, so it needs no change. Assert that in a test (below).

**WS-59.2 — `LivePhotoScanner`: exact eligible count, sampled paired-video bytes**
- **Why:** VALUE-09 estimates 30–60 GB of motion clips on a 20k Live-Photo library, and the app reports none of it.
- **Change:** new file `iOSCleanup/Engines/LivePhotoScanner.swift` (`@preconcurrency import Photos`):
  ```swift
  enum LivePhotoPlayback: String, Sendable { case livePhoto, loopOrBounce, other }   // playbackStyle .livePhoto / .videoLooping / anything else
  struct LivePhotoCandidateFacts: Equatable, Sendable {
      let id: String; let creationDate: Date?; let modificationDate: Date?
      let pixelWidth: Int; let pixelHeight: Int
      let playback: LivePhotoPlayback
      let isHidden, isFavorite, isDepthEffect, isUserLibrary, hasAdjustments, canDelete: Bool
      init(asset: PHAsset)       // isUserLibrary = asset.sourceType.contains(.typeUserLibrary); canDelete = asset.canPerform(.delete)
  }
  enum LivePhotoExclusion: String, CaseIterable, Sendable {
      case loopOrBounce, notLivePlayback, hidden, favorite, depthEffect, notInUserLibrary, edited, cannotDelete
  }
  /// Metadata-only prefilter. WS-60's LivePhotoConversionPlanner calls this first and adds resource-level checks.
  enum LivePhotoCandidateFilter {
      static func exclusions(_ f: LivePhotoCandidateFacts, includeFavorites: Bool = false) -> [LivePhotoExclusion]  // [] == eligible; order = enum order
  }
  enum LivePhotoMotionSampler {
      static let maximumSamples = 200
      /// Deterministic, evenly spaced: index floor(i * n / k) for i in 0..<k, over IDs pre-sorted by (creationDate, id).
      static func sampleIDs(_ orderedIDs: [String], maximum: Int = maximumSamples) -> [String]
  }
  struct LivePhotoMotionMeasurement: Codable, Equatable, Sendable {
      enum Outcome: String, Codable, Sendable { case local, iCloudOnly, unavailable }
      let outcome: Outcome; let deviceBytes: Int64; let measuredAt: Date
  }
  struct LivePhotoMotionSummary: Equatable, Sendable {
      let totalLivePhotoCount: Int; let eligibleCount: Int; let sampledCount: Int
      let exclusionCounts: [LivePhotoExclusion: Int]
      let sizing: ReclaimSizing; let measuredAt: Date
      static func make(totalLivePhotoCount: Int, eligibleCount: Int, exclusionCounts: [LivePhotoExclusion: Int],
                       samples: [LivePhotoMotionMeasurement], now: Date) -> LivePhotoMotionSummary
  }
  protocol LivePhotoLibraryReading: Sendable {
      func livePhotoFacts() async -> [LivePhotoCandidateFacts]                // off-main enumeration, sorted by creationDate
      func assets(for ids: [String]) async -> ResolvedPhotoAssets
  }
  protocol PairedVideoMeasuring: Sendable {
      func measurePairedVideo(of asset: PHAsset, now: Date) async -> LivePhotoMotionMeasurement
  }
  actor LivePhotoScanner {
      static let recheckInterval: TimeInterval = 7 * 86_400
      init(library: any LivePhotoLibraryReading = SystemLivePhotoLibrary(),
           measurer: any PairedVideoMeasuring = LivePairedVideoMeasurer(),
           repository: AssetFileSizeRepository = .shared,
           now: @escaping @Sendable () -> Date = { Date() })
      func scan() async -> LivePhotoMotionSummary
  }
  ```
  - **`exclusions` rules** (all metadata):
    - `.loopOrBounce` when the playback is `.loopOrBounce`, and `.notLivePlayback` when it is `.other` (Long Exposure and friends);
    - `.hidden`;
    - `.favorite` unless `includeFavorites`;
    - `.depthEffect`;
    - `.notInUserLibrary`;
    - `.edited` when `hasAdjustments`;
    - `.cannotDelete`.
  - **`SystemLivePhotoLibrary.livePhotoFacts()`** runs in `Task.detached(priority: .utility)`.
    - Start from `let options = PhotoLibraryFetch.imageOptions()` (WS-18/WS-40: `creationDate` ascending sort, hidden assets excluded). Never write `PHFetchOptions()` or `options: nil`, because WS-40's `PhotoFetchLintTests` rejects both. AND the predicate `NSPredicate(format: "(mediaSubtypes & %ld) != 0", Int(PHAssetMediaSubtype.photoLive.rawValue))` into `options.predicate` with `NSCompoundPredicate(andPredicateWithSubpredicates:)` if the factory already set one. Pass `Int` with `%ld`; a `UInt` with `%d` is undefined. Then call `PHAsset.fetchAssets(with: .image, options: options)`.
    - Map each asset to `LivePhotoCandidateFacts(asset:)`.
    - One pass, no per-asset resource reads.
  - **`LivePairedVideoMeasurer`:**
    - Take `PHAssetResource.assetResources(for:)`, filtered to `.pairedVideo`, `.fullSizePairedVideo` and `.adjustmentBasePairedVideo` (via `AssetResourceKind`).
    - Stream each with `LiveAssetResourceFootprintSource.streamLocalBytes(of:)`.
    - Combine:
      - all local → `.local` with the sum;
      - any `iCloudOnly` → `.iCloudOnly`, with `deviceBytes` = the local parts;
      - no paired resource, or all unavailable → `.unavailable`.
    - Network is **always off** (invariant 11).
  - **`scan()`:**
    1. Take the facts. Compute `exclusionCounts`, and the eligible IDs in `(creationDate, id)` order.
    2. `sampleIDs`.
    3. Batch-read the repository with `records(for:)`, keyed by `AssetFileSizeCacheKey(localIdentifier:modificationDate:)`. Reuse any `record.livePhotoMotion` younger than `recheckInterval`.
    4. Resolve the missing sample IDs to `PHAsset` (`library.assets(for:)`) and measure them with at most 2 in flight. Use a `withTaskGroup` sliding window, check `Task.isCancelled` before each add, and on cancellation return the partial summary with no merge.
    5. Call `repository.mergeLivePhotoMotion(_:)` once.
    6. Return `LivePhotoMotionSummary.make(...)`.
  - **`LivePhotoMotionSummary.make`:**
    - Let `n = samples.count`.
    - `device = round(Σ deviceBytes / n × eligible)`.
    - `iCloudOnly = round(count(.iCloudOnly) / n × eligible × livePhotoMotionEstimateBytes)`.
    - `unknown = round(count(.unavailable) / n × eligible × livePhotoMotionEstimateBytes)`.
    - Use saturating arithmetic.
    - `isExtrapolated = n < eligible`. When `n == eligible` (200 or fewer eligible Live Photos), the sizing is the plain sum and is not extrapolated.
    - `eligible == 0` or `n == 0` → `.zero`.
  - **`PHAsset+FileSize.swift`:**
    - `AssetFileSizeRecord` gains `var livePhotoMotion: LivePhotoMotionMeasurement?`, optional, so old files decode.
    - `AssetFileSizeRepository` gains:
      ```swift
      struct LivePhotoMotionMergeItem: Sendable { let key: AssetFileSizeCacheKey; let measurement: LivePhotoMotionMeasurement; let fallbackImageBytes: Int64 }
      func mergeLivePhotoMotion(_ items: [LivePhotoMotionMergeItem]) async   // one eviction pass, ONE scheduleWrite()
      ```
      - An existing record keeps `bytes`, `provenance`, `footprint` and locality, and gains `livePhotoMotion`.
      - A missing record is created as `AssetFileSizeRecord(bytes: max(fallbackImageBytes, 1), provenance: .estimated, savedAt: now, mediaKind: .image, livePhotoMotion: m)`. `fallbackImageBytes` is `AssetResourceSizePolicy.estimatedByteCount(mediaKind: .image, …)`, exactly what `representativeFile()` would have stored, so `estimatedFileSize` does not change.
    - Add `var cachedLivePhotoMotion: LivePhotoMotionMeasurement?` to the `PHAsset` extension. It reads the front cache only, the same way as `estimatedFileSize`, and WS-60 uses it.
- **Edge cases:**
  - The simulator library has no Live Photos. `scan()` returns the zero summary and no tile appears.
  - Under Limited access the facts cover only the shared photos. The summary lives in memory only.
  - A sample that is deleted between enumeration and measurement resolves to nothing and is skipped. `n` shrinks, which is fine.
  - Cost: 200 × about 3 MB of local reads per 7 days. That is seconds on a device, idle-time only.

**WS-59.3 — `LargePhotoScanner`: RAW and 48 MP originals**
- **Why:** VALUE-14. A ProRAW shooter with 600 DNGs (about 30 GB) is never told.
- **Change:** new file `iOSCleanup/Engines/LargePhotoScanner.swift`:
  ```swift
  enum LargePhotoPolicy {
      static let minimumPixelCount: Int64 = 40_000_000       // catches 48 MP (8064×6048); excludes 24 MP
      static let minimumShortEdge = 4_700                    // fetch prefilter; excludes panoramas (DECISION below)
      static let maximumCandidates = 2_000                   // list cap, largest pixel count first
      static let maximumMeasuredPerPass = 200                // WS-30 measurer streams whole RAW files
      static func qualifies(pixelWidth: Int, pixelHeight: Int, isInRAWAlbum: Bool) -> Bool
      // isInRAWAlbum || (Int64(w) * Int64(h) >= minimumPixelCount && min(w, h) >= minimumShortEdge)
  }
  struct LargePhotoCandidate: Equatable, Sendable { let id: String; let pixelWidth, pixelHeight: Int; let creationDate, modificationDate: Date?; let isRAW: Bool }
  struct LargePhotoItem: Equatable, Sendable {
      let candidate: LargePhotoCandidate
      let footprint: AssetDeviceFootprint?          // measured (repository) or nil
      let estimatedBytes: Int64                     // typed estimate from resource list when footprint == nil
      var sortBytes: Int64 { footprint?.totalBytes ?? estimatedBytes }
  }
  struct LargePhotoScanResult: Equatable, Sendable {
      let items: [LargePhotoItem]                   // sortBytes desc, then pixel count desc, then creationDate desc, then id
      let sizing: ReclaimSizing                     // Σ footprint.reclaimSizing, plus .unmeasured(estimatedBytes) for the rest
      let rawCount: Int; let isTruncated: Bool; let unmeasuredCount: Int
  }
  protocol LargePhotoLibraryReading: Sendable {
      func rawAlbumCandidates() async -> [LargePhotoCandidate]
      func largeImageCandidates(minimumShortEdge: Int) async -> [LargePhotoCandidate]
      func resourceEstimates(for ids: [String]) async -> [String: Int64]  // Σ estimatedResourceBytes over PHAssetResource list
      func assets(for ids: [String]) async -> ResolvedPhotoAssets
  }
  actor LargePhotoScanner {
      init(library: any LargePhotoLibraryReading = SystemLargePhotoLibrary(),
           measurer: AssetDeviceFootprintMeasurer = AssetDeviceFootprintMeasurer(),
           repository: AssetFileSizeRepository = .shared,
           now: @escaping @Sendable () -> Date = { Date() })
      func scan() async -> LargePhotoScanResult
  }
  ```
  - **`SystemLargePhotoLibrary`** (all detached, `.utility`):
    - The RAW album is `PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumRAW, options: nil)` (collection fetches are outside WS-40's lint) → `PHAsset.fetchAssets(in:options: PhotoLibraryFetch.imageOptions())`.
    - Large images use `PHAsset.fetchAssets(with: .image, options:)` on `PhotoLibraryFetch.imageOptions()`, with the predicate `pixelWidth >= %ld AND pixelHeight >= %ld` (with `Int` arguments) ANDed into it.
    - `assets(for:)` and `resourceEstimates(for:)` resolve IDs with `PHAsset.fetchAssets(withLocalIdentifiers:options: PhotoLibraryFetch.identifierOptions())`. The same applies to `SystemLivePhotoLibrary.assets(for:)`.
  - **`scan()`:**
    1. Union by ID (`isRAW` if in the album) and filter with `qualifies`.
    2. Order by pixel count descending and cap at `maximumCandidates` (`isTruncated`).
    3. `records(for:)` supplies footprints younger than `AssetLocalityPolicy.recheckInterval`.
    4. Measure up to `maximumMeasuredPerPass` unmeasured candidates, largest pixel count first, with WS-30's `AssetDeviceFootprintMeasurer.measure(_:onResult:)` (2 in flight).
    5. Persist with `mergeFootprints` in batches of 64.
    6. `warmMemoryCache(for:)` the measured keys, so `CategoryAssetSize.live` and `estimatedFileSize` read the measured totals in the grid and in the deletion receipt.
    7. Estimate the rest with `resourceEstimates` (in memory only, never merged). Later passes measure more.
- **Edge cases:**
  - Favorites are included (user-authored review). WS-41's bulk selection excludes them.
  - A RAW+JPEG pair is one asset. Its footprint already includes the `.alternatePhoto`, because WS-30 sums every resource.
  - "Keep JPEG, remove RAW" is a later phase. Add it to `spec/BACKLOG.md`; do not build it.
  - Under Limited access, only shared photos are scanned, and nothing is pruned.

**WS-59.4 — `StorageInsightsController` and facade wiring**
- **Why:** Both scanners are idle-time PhotoKit work (chapter rule 2). The facade must stay forwarding-only (invariant 28).
- **Change:** new file `iOSCleanup/Views/Home/StorageInsightsController.swift`:
  ```swift
  @MainActor final class StorageInsightsController: ObservableObject {
      @Published private(set) var livePhotoSummary: LivePhotoMotionSummary?
      @Published private(set) var largePhotos: LargePhotoScanResult?
      @Published private(set) var largePhotoAssets: [PHAsset] = []      // resolved in items order, for the grid
      @Published private(set) var isRunning = false
      static let minimumPassInterval: TimeInterval = 24 * 3_600
      init(livePhotoScanner: LivePhotoScanner, largePhotoScanner: LargePhotoScanner,
           resolveAssets: @escaping @Sendable ([String]) async -> ResolvedPhotoAssets,
           now: @escaping () -> Date = Date.init)
      func refresh(canRun: Bool, force: Bool = false)   // single-flight; Live Photos then large photos; skips if the last pass < 24 h unless force
      func cancel()
      func applyConfirmedDeletion(_ ids: Set<String>)    // drops items/assets; leaves the Live Photo estimate until the next pass
      var onPassFinished: (() -> Void)?                  // WS-62 chains the duplicate-video worker here
  }
  ```
  - Add three entries to `HomeViewModelDependencies`, each with its live default: `livePhotoLibrary: any LivePhotoLibraryReading`, `pairedVideoMeasurer: any PairedVideoMeasuring` and `largePhotoLibrary: any LargePhotoLibraryReading`. Tests inject stubs. `.debugFixture()` uses empty stubs.
  - **`HomeViewModel`** (forwarding only):
    - own the controller;
    - call `refresh(canRun: canMeasure)` when WS-30's `ReclaimMeasurementController.isMeasuring` turns false, using a Combine sink on `$isMeasuring` that `dropFirst`s and filters `false`, and on `.active` when the controller's last pass is stale;
    - call `cancel()` everywhere WS-30 cancels its controller (photo run start, video pass start, `.background`);
    - forward `applyConfirmedDeletion(assetIDs:)` (WS-21) to it;
    - feed `ScanOutcomeInputs.livePhotoCount` (= `eligibleCount`) and `livePhotoSizing`, plus `largePhotoCount` and `largePhotoSizing`;
    - expose `livePhotoSummary` and `largePhotoAssets`;
    - never run while authorization is `.notDetermined` or `.denied` (invariant 20).
  - Do **not** schedule a snapshot write for these values. Nothing here enters `CachedPhotoAnalysisSnapshot`.
- **Edge cases:** a scan that starts mid-pass cancels it. The partial Live Photo summary is discarded, and the previous summary stays published.

**WS-59.5 — UI: Live Photo explainer, RAW & 48 MP grid, gating**
- **Change:**
  1. New `iOSCleanup/Views/Photos/LivePhotoMotionExplainerView.swift`. It is pushed from the tile and uses `DuckCard`, `duck*` fonts and `CountText`/`ByteText`. Lines:
     - "\(CountText.items(eligible, "Live Photo", "Live Photos")) · \(ByteText.approximate(sizing)) of motion on this iPhone".
     - When extrapolated: "Estimated from \(sampled) of your Live Photos."
     - When `iCloudOnlyBytes > 0`: "About \(ByteText.stat(iCloudOnlyBytes)) more is stored only in iCloud."
     - "Each Live Photo keeps a short video with sound next to the photo."
     - "Not counted: " followed by the non-zero `exclusionCounts`, e.g. "120 Loop or Bounce, 45 edited, 30 favorites, 12 portrait".
     - "To keep new photos smaller, turn off Live in the Camera app. To keep it off, go to Settings › Camera › Preserve Settings › Live Photo."

     Instructions only: no URL scheme. Leave `// WS-60: conversion entry goes here` below the card.
  2. `PhotoScanEngine.swift:1742`: add `case largePhoto` to `PhotoReviewCategory`. At the one exhaustive switch over `PhotoReviewCategoryClassifier.classify(...)` in the scan loop (or wherever WS-23/WS-24 moved it), add `case .largePhoto: break`. The classifier never returns it.
  3. WS-41 files:
     - `CategorySortOrder.storageKey(for: .largePhoto)` is `"photoduck.category-sort.largePhoto"`.
     - Add `static func defaultOrder(for category: PhotoReviewCategory) -> CategorySortOrder`: `.largest` for `.largePhoto`, `.oldest` otherwise. `PhotoCategoryReviewView`'s `AppStorage` initializer uses it.
     - Header: "\(CountText.photos(n)) · \(ByteText.approximate(sizing))". Title "RAW & 48 MP".
     - The swipe button reads "Swipe through large photos" (`SwipeQueueSource.assets(_, category: .largePhoto)`).
     - Tiles for `isRAW` items show `StatusBadge(title: "RAW", tone: .secondary)` (WS-56's signature).
     - Caption under the header: "RAW files are the originals your camera captured. Add them to Export before deleting if you edit them elsewhere."
  4. `Store/CleanupAccessPolicy.swift`: add `ManualDeleteSurface.largePhotos` and `BulkSelectSurface.largePhotos`. `PhotoCategoryReviewView` maps `.largePhoto` to both.
- **Edge cases:**
  - Nothing is pre-selected (invariant 8).
  - The commit is WS-41's single `delete(assets:)` call.
  - WS-21's confirmed-deletion path removes the IDs from `StorageInsightsController` through the facade forward.

### Tests
All run in the simulator with stubs. Add every new file to `project.pbxproj`.
- **`iOSCleanupTests/LivePhotoScannerTests.swift`:**
  - `testExclusionsCoverEveryMetadataRule`: one facts value per `LivePhotoExclusion`, plus one eligible value that returns `[]`.
  - `testIncludeFavoritesRemovesOnlyFavoriteExclusion`.
  - `testSamplerIsDeterministicAndEvenlySpaced`: 1,000 IDs give 200 samples; the first ID is sampled; the gaps are 5; two calls are equal.
  - `testSamplerReturnsAllWhenFewerThanMaximum`.
  - `testSummaryExtrapolatesLocalMeanAndMarksEstimate`: 200 samples of 2.5 MB local each and 10,000 eligible give `deviceBytes == 25_000_000_000`, `isExtrapolated`, and `isEstimated`.
  - `testSummaryICloudOnlySamplesAddTypedICloudBytesNotDevice`.
  - `testSummaryNotExtrapolatedWhenEverythingSampled`.
  - `testScanReusesFreshRecordsAndMeasuresOnlyMissing`: a stub measurer counts calls; a temp repository is pre-seeded with 150 fresh records → exactly 50 measurements.
  - `testScanRemeasuresRecordsOlderThanSevenDays`: injected `now`.
  - `testScanMergesOnceAndPreservesExistingRecordBytes`: uses WS-30's DEBUG `writeCount`.
  - `testScanCancellationReturnsWithoutMerge`.
  - `testLegacyRecordWithoutMotionDecodes`.
- **`iOSCleanupTests/LargePhotoScannerTests.swift`:**
  - `testQualifiesRAWAlbumAtAnySize`.
  - `testQualifies48MPButNot24MP`.
  - `testPanoramaExcludedUnlessRAW`: 16000×3000 is excluded.
  - `testUnionDedupesAndOrdersBySortBytes`.
  - `testMeasuresAtMostTwoHundredPerPassLargestFirst`: stub library with 450 candidates.
  - `testUnmeasuredItemsUseTypedEstimateAndMarkSizingEstimated`.
  - `testCapSetsTruncated`.
- **`iOSCleanupTests/SupplementaryOpportunityTests.swift`:**
  - `testSupplementaryKindsExcludedFromHeadlineBytes`.
  - `testPrimaryActionPrefersNonSupplementary`.
  - `testOnlySupplementaryOpportunityBecomesPrimary`.
  - `testReclaimableTotalSkipsSupplementary` (`HomeTileLayout`).
  - `testStorageCardIgnoresSupplementaryKinds`: `StorageCardPresentation.make` output is unchanged when Live Photo sizing is added to the inputs.
  - `testTileOrderPlacesSupplementaryByBytes`.
  - `testExtrapolatedSizingRendersApproximate`: `ByteText.approximate` starts with "≈".
- **`iOSCleanupTests/StorageInsightsControllerTests.swift`** (`@MainActor`, stubs):
  - `testRefreshDoesNothingWhenCannotRun`.
  - `testRefreshIsSingleFlight`.
  - `testRefreshSkipsWithinTwentyFourHoursUnlessForced`.
  - `testCancelKeepsPreviousSummary`.
  - `testConfirmedDeletionDropsLargePhotoItems`.
  - `testOnPassFinishedFiresOncePerPass`.
- **`CleanupAccessPolicyTests`:** `testLargePhotoSingleDeleteFreeMultiPro`, `testLargePhotoBulkSelectIsPro`.
- **`HomeTileLayoutTests`:** extend `testEmptyStateUsesCanonicalOrderWithAllTiles` to the new kinds.
- **`HomeTileRouteTests`** (WS-55): `testEveryTileKindMapsToAPushedRoute` passes with the two new kinds, and `testSupplementaryTilesPushTheirRoutes` checks `.livePhotoMotion → .livePhotos` and `.largePhotos → .largePhotos`.
- Device-only: see Device QA.

### Acceptance criteria
- [ ] On a device with Live Photos, Home shows a Live Photos tile with "≈" bytes, and the explainer states the sample size and the exclusions (Device QA 1).
- [ ] The Live Photo figure is within ±20% of the sum measured by the DEBUG check in Device QA 2.
- [ ] A library with ProRAW or 48 MP photos shows a "RAW & 48 MP" tile sorted largest first. Single delete is free, and multi-select and Select All show the lock before selection (tests plus Device QA 3).
- [ ] No combined total (headline, "Could free", storage card) includes supplementary bytes (`SupplementaryOpportunityTests`).
- [ ] No network access in any measurement: `streamLocalBytes(of:)` and WS-30's measurer have no network parameter, and `grep -n "isNetworkAccessAllowed = true" iOSCleanup/Engines/LivePhotoScanner.swift iOSCleanup/Engines/LargePhotoScanner.swift iOSCleanup/Engines/AssetDeviceFootprintMeasurer.swift` finds nothing.
- [ ] Legacy `asset-file-sizes-v1.json` still decodes (test).
- [ ] WS-30's tests are unchanged and green. The full suite passes with zero new warnings.
- [ ] `CLAUDE.md` lists the two categories, notes that they are supplementary (excluded from totals), and describes the idle-worker order.

### Device QA
Add to `docs/DEVICE_QA.md`:
1. On an iPhone with at least 1,000 Live Photos, wait for the idle pass after a scan (os_log category `StorageInsights`, start and finish with counts only). Record the tile value, the eligible count, the sample size and the pass duration.
2. DEBUG check: in a DEBUG build, add a temporary one-off call that runs `LivePairedVideoMeasurer` over **all** eligible Live Photos and logs the total. Do not commit it. Compare the total with the tile (±20%).
3. Shoot 3 ProRAW photos. After the idle pass, the RAW tile lists them first with measured sizes (no "≈" after the measurement). Deleting one shows one iOS prompt, and it lands in Recently Deleted.
4. With Optimize iPhone Storage on, confirm that the explainer shows an iCloud-only line and that no download indicator appears during the pass.

### Pitfalls and out of scope
- Never sum motion bytes into `estimatedFileSize`, group reclaim or the storage bar. They are a separate, supplementary opportunity.
- Never use `isNetworkAccessAllowed = true` here (invariant 11).
- Do not persist the summaries. Records go through `AssetFileSizeRepository` only (chapter rule 3).
- Conversion, the selection grid and the journal belong to WS-60. "Keep JPEG, remove RAW" goes to the backlog.
- Do not visually redesign Home tiles (invariant 29). Reuse WS-45's tile.
- **Reconciliation:**
  - The kinds are added to WS-31's nested `CleanupOpportunity.Kind` (README §9 contract 10).
  - `.largePhotos` is added to WS-36's `ManualDeleteSurface` and `BulkSelectSurface` additively, with policy tests (contract 11).
  - Tiles route through WS-55's `HomeTileRoute`, and badges, colors and counts follow WS-56 (`StatusBadge(title:tone:)`, `DuckTone`, `CountText`).
  - Worker hooks follow chapter rule 2 when WS-49's coordinator exists.
  - Every `PHAsset` fetch starts from WS-40's `PhotoLibraryFetch` factories (`imageOptions()`, `identifierOptions()`), because `PhotoFetchLintTests` rejects `options: nil` and any `PHFetchOptions()` outside `PhotoLibraryFetch.swift`. Collection fetches (`PHAssetCollection.fetchAssetCollections`) are outside the lint.
  - Locality uses WS-30's `AssetStorageLocation` (`.onDevice`, `.iCloudOnly`, `.unknown`, plus `.partial` for photos).

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| VALUE-09 | confirmed | `representative` never sums paired video (PHAsset+FileSize.swift:99-117; image ranks 233-243), and `.photoLive` only feeds descriptors (SimilarityPolicyTypes.swift:377). After WS-30, measured footprints of delete candidates include paired video, but no category surfaces motion. The finding cited `VideoCompressionEngine.swift:476-530`; the function is at 477-531. The plan implements phase 1 with FSB-01's corrections: 200 samples instead of 500, a metadata eligibility filter shared with WS-60, and a new optional record field instead of a new store. Its phase 2 (chunks of 50, no Loop/Bounce, edit or decline handling) is superseded by FSB-01 in WS-60. |
| VALUE-14 | confirmed | No RAW or large-photo category exists. `assetPriority` (PhotoScanEngine.swift:1652-1667) only orders work, and `.alternatePhoto` is ranked (233-243) but never surfaced. Differences from the fix: the category reuses WS-41's `PhotoCategoryReviewView` instead of a new list. Panoramas are excluded by a short-edge prefilter (DECISION below). WS-30's measurer streams whole RAW files, so at most 200 are measured per idle pass and the rest carry typed "≈" estimates. |

DECISION (owner may override): the "RAW & 48 MP" category excludes panoramas and other photos whose short edge is under 4,700 px, unless they are in the RAW album.
DECISION (owner may override): at most 200 RAW/48 MP photos are stream-measured per idle pass. The rest show WS-30's typed "≈" estimates until later passes measure them.
DECISION (owner may override): Live Photos, RAW & 48 MP and (WS-62) Duplicate videos are supplementary. They never enter combined "could free" totals, and they are the completion sheet's primary action only when nothing else is actionable.

---

## WS-60 — Live Photo to still conversion

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M4 | L | WS-11, WS-36, WS-59 | yes | `ws/60-live-photo-conversion` |

**Primary files:**
- Engines: `iOSCleanup/Engines/LivePhotoConversionPlanner.swift` (*new*), `iOSCleanup/Engines/LivePhotoStillConversionService.swift` (*new*), `iOSCleanup/Engines/LivePhotoConversionJournal.swift` (*new*), `iOSCleanup/Engines/LivePhotoLibraryWriter.swift` (*new*), `iOSCleanup/Engines/DeletionManager.swift`, `iOSCleanup/Engines/DeletionTypes.swift`
- Views: `iOSCleanup/Views/Photos/LivePhotoReviewView.swift` (*new*), `iOSCleanup/Views/Photos/LivePhotoConversionModel.swift` (*new*), `iOSCleanup/Views/Home/LivePhotoPendingStillsCard.swift` (*new*), `iOSCleanup/Views/Photos/LivePhotoMotionExplainerView.swift`, `iOSCleanup/Views/HomeView.swift` (one line), `iOSCleanup/Views/HomeViewModel.swift` (pass-throughs)
- App: `iOSCleanup/iOSCleanupApp.swift` (temp sweep)
- Tests: `iOSCleanupTests/LivePhotoConversionPlannerTests.swift` (*new*), `iOSCleanupTests/LivePhotoStillConversionServiceTests.swift` (*new*), `iOSCleanupTests/LivePhotoConversionJournalTests.swift` (*new*), `iOSCleanupTests/DeletionManagerTests.swift`, `iOSCleanupTests/CleanupStatsStoreTests.swift`
- Project and docs: `project.pbxproj`, `CLAUDE.md`, `../CLAUDE.md` (outer repo: owner approval required)

**Findings covered:** FSB-01 (P1, confirmed; it also carries VALUE-09's phase 2 as corrected)

**Decisions applied:**
- **D-LIVEPHOTO:** explicit selection only. Loop/Bounce, edited, hidden, favorited (by default), non-user-library, depth-effect and non-local items are excluded. Chunks hold at most 25. Stills are verified before any delete, originals are deleted through `DeletionManager`, and a journal records the created stills.
- **D-GATING:** converting one Live Photo is free and more than one is Pro (`CleanupAction.convertLivePhotos(count:)`, already in WS-36). The lock shows on the second selection and on Select All/Month, never at commit.
- **D-FAVORITES-USER:** favorites are excluded by default. The "Include favorites" toggle is user-authored.
- **D-UNDO:** there is one iOS prompt per chunk, and Recently Deleted (30 days) is the recovery path.
- **Invariant 4:** originals are deleted with `DeletionManager.delete(assets:…)` after verification. This is **not** a second exemption: no `deleteAssets` call appears in any file this workstream adds.

### Goal
A user selects Live Photos in a month-sectioned grid with nothing pre-selected. They confirm a dialog that says motion and sound will be removed, and get stills that keep date, location, favorite, hidden state and user albums. The originals go to Recently Deleted through `DeletionManager`, one iOS prompt per chunk of 25 or fewer. A declined prompt, a failed verification or a crash never leaves unexplained duplicates: a journal records every created still, and Home offers "Keep both" or "Remove the N new stills" until the user chooses. Only the measured motion bytes are credited.

### Current behavior (verified)
- No conversion code exists. `ROADMAP.md:19` defers it, and `ROADMAP.md:51` proposes "re-save still, delete pair — reuses VideoCompressionEngine's save-then-delete machinery".
- That machinery, `VideoCompressionEngine.saveAndDeleteOriginal` (`iOSCleanup/Engines/VideoCompressionEngine.swift:477-531`), runs two `performChanges` per asset. It deletes the original directly (`:521-523`), which is the documented compression exemption, and on a decline it returns `savedButOriginalKept`, leaving a duplicate. WS-43 replaces it with a single-transaction swap. That swap is the compression exemption and must **not** be reused here (invariant 4).
- `CreatedAssetIdentifierBox` captures placeholder IDs from inside a change block (`VideoCompressionEngine.swift:483-493`).
- `DeletionManager.delete(assets:)` is at `iOSCleanup/Engines/DeletionManager.swift:146-148` today. After WS-11 it is `delete(assets:requiredKeeperIDs:knownBytes:) -> DeletionResult`, which:
  - re-resolves IDs;
  - skips an item whose required keeper no longer resolves (`.keeperMissing`);
  - returns `.declined` on PHPhotos 3072;
  - is globally single-flight;
  - records stats only after PhotoKit confirms.
- WS-36 already defines `CleanupAction.convertLivePhotos(count:)`, `PaidFeature.livePhotoBatchConversion` and its paywall caption.
- WS-59 provides `LivePhotoCandidateFacts`, `LivePhotoCandidateFilter`, `PairedVideoMeasuring`, `cachedLivePhotoMotion`, the tile, `HomeRoute.livePhotos` and the explainer with a WS-60 marker.

### Implementation plan

**WS-60.0 — VERIFY-FIRST (device, before merging)**
Build the branch with WS-60.1–60.6 in place. Use disposable Live Photos on a device. In a DEBUG build, set `LivePhotoConversionOptions.debugIncludeHidden = true` (`#if DEBUG` only) so a hidden test photo can be listed.
1. Convert one Live Photo that is a favorite, has a location and is in two user albums. Expect:
   - a still with the same date and location in the Info panel;
   - favorite;
   - in both albums;
   - no "LIVE" badge;
   - the original in Recently Deleted.
2. Convert one hidden Live Photo (DEBUG toggle). Expect: the still is in Hidden and not in Library.
3. Convert two and **decline** the prompt. Expect: both stills exist, both originals remain, and the Home card "2 converted stills are copies of Live Photos you kept" appears. Tap "Remove the 2 new stills", allow, and check that they are in Recently Deleted.
4. Force-quit between creation and the prompt: set a DEBUG breakpoint after the journal write, then stop the app from Xcode. Relaunch and expect the same Home card.
5. Record in the PR whether the created asset's `mediaSubtypes` contains `.photoLive`, and the Info-panel file name.

**If step 1 shows `.photoLive` on the still, a lost album or a changed date, stop.** Do not ship; escalate to the owner. Record everything in `docs/DEVICE_QA.md`.

**WS-60.1 — `LivePhotoConversionPlanner` (pure)**
- **Why:** FSB-01 items 1–4. User-chosen effects, edits, hidden privacy and non-deletable sources must be protected before any write.
- **Change:** new file `iOSCleanup/Engines/LivePhotoConversionPlanner.swift`:
  ```swift
  struct LivePhotoConversionOptions: Equatable, Sendable {
      var includeFavorites = false
      var allowNetworkAccess = false        // downloads only the .photo resource; frees iCloud, not iPhone, storage
      #if DEBUG
      var debugIncludeHidden = false        // WS-60.0 only
      #endif
  }
  enum LivePhotoIneligibility: String, CaseIterable, Sendable {
      case loopOrBounce, notLivePlayback, hidden, favorite, depthEffect, notInUserLibrary, cannotDelete, edited
      case photoResourceMissing, photoNotLocal, pairedVideoNotLocal
      var isUserOverridable: Bool { self == .favorite || self == .photoNotLocal || self == .pairedVideoNotLocal }
      var summaryTitle: String      // "Loop or Bounce", "Edited", "Hidden", "Favorite", "Portrait", "Shared or synced", …
  }
  struct LivePhotoConversionFacts: Equatable, Sendable {
      let candidate: LivePhotoCandidateFacts                // WS-59
      let resourceKinds: Set<AssetResourceKind>             // from PHAssetResource.assetResources(for:)
      let photoResourceIsLocal: Bool?                       // nil = unknown
      let pairedVideoOutcome: LivePhotoMotionMeasurement.Outcome?
  }
  enum LivePhotoEligibility: Equatable, Sendable { case eligible, ineligible([LivePhotoIneligibility]) }
  enum LivePhotoConversionPlanner {
      static let maximumChunkSize = 25
      static func eligibility(_ facts: LivePhotoConversionFacts, options: LivePhotoConversionOptions) -> LivePhotoEligibility
      static func chunks(_ ids: [String]) -> [[String]]     // selection order, ≤ 25 each
  }
  ```
  - **`eligibility`:**
    - Start with `LivePhotoCandidateFilter.exclusions(candidate, includeFavorites:)`, mapped 1:1. `.hidden` is honored unless `debugIncludeHidden`.
    - Add `.edited` if `resourceKinds` contains `.adjustmentData`, `.adjustmentBasePhoto` or `.adjustmentBasePairedVideo`. This catches edits that `hasAdjustments` missed.
    - Add `.photoResourceMissing` if there is no `.photo`.
    - Add `.photoNotLocal` if `photoResourceIsLocal == false && !allowNetworkAccess`.
    - Add `.pairedVideoNotLocal` if `pairedVideoOutcome == .iCloudOnly && !allowNetworkAccess`. That item frees no iPhone space.
    - Return every reason, in enum order, deduplicated.
- **Edge cases:**
  - An unknown locality (`nil`) is **not** a reason. The service measures it at commit (WS-60.5).
  - `debugIncludeHidden` needs a `#if DEBUG` overload `SystemLivePhotoLibrary.livePhotoFacts(includeHidden: Bool)` that sets `includeHiddenAssets = true` on the `PhotoLibraryFetch.imageOptions()` result (never on a fresh `PHFetchOptions()`; WS-40's lint scans DEBUG code too). `LivePhotoConversionModel` calls it only when the flag is set. Release builds contain neither (invariant 27).
  - Building the facts (resource enumeration) is off-main and happens only for the selection at commit time, never for the whole grid.

**WS-60.2 — `DeletionManager` stats policy**
- **Why:** A converted Live Photo is not a "cleaned item". Its net saving is the motion bytes, and removing stills the app created is not a cleanup at all. Counting either would inflate WS-32's ledger and WS-64's recap.
- **Change:**
  - In `Engines/DeletionTypes.swift`: `enum DeletionStatsPolicy: String, Sendable, Equatable { case record, bytesOnly, none }`.
  - `DeletionManager.delete(assets:requiredKeeperIDs:knownBytes:statsPolicy: DeletionStatsPolicy = .record)`. In `commit`, after PhotoKit success:
    - `.record` → today's `recordConfirmedDeletion(bytes:itemCount:)`;
    - `.bytesOnly` → `recordConfirmedDeletion(bytes:itemCount: 0)`;
    - `.none` → no stats call.
  - The receipt, `lastReceipt`, `confirmedDeletions` (WS-21), the announcement and the haptic are unchanged for all three policies. Only stats differ.
  - `keepBest` paths always use `.record`.
- **Edge cases:** `.declined` and thrown errors still record nothing (invariant 9).

**WS-60.3 — Library writer (live) and still verification (pure)**
- **Change:** new file `iOSCleanup/Engines/LivePhotoLibraryWriter.swift`:
  ```swift
  struct LocationSnapshot: Equatable, Sendable {              // CLLocation is not assumed Sendable
      let latitude, longitude, altitude, horizontalAccuracy, verticalAccuracy, course, speed: Double; let timestamp: Date
      init(_ l: CLLocation); var location: CLLocation { get }
  }
  struct LivePhotoOriginalSnapshot: Equatable, Sendable {
      let id: String; let creationDate: Date?; let location: LocationSnapshot?
      let isFavorite: Bool; let isHidden: Bool; let pixelWidth: Int; let pixelHeight: Int
      let albumIDsToCarry: [String]                            // ReplacementPlanner.albumIdentifiersToCarry (WS-43)
      let photoOriginalFilename: String
  }
  struct LivePhotoStillCreationRequest: Equatable, Sendable { let original: LivePhotoOriginalSnapshot; let photoFileURL: URL }
  struct CreatedStillFacts: Equatable, Sendable {
      let id: String; let isImage: Bool; let isLivePhoto: Bool; let pixelWidth: Int; let pixelHeight: Int
      let creationDate: Date?; let location: LocationSnapshot?; let isFavorite: Bool; let isHidden: Bool; let albumIDs: Set<String>
  }
  protocol LivePhotoLibraryWriting: Sendable {
      func snapshot(originalID: String) async -> LivePhotoOriginalSnapshot?
      /// Streams the original's .photo resource (network per flag) to `url`. Throws when not local and network is off.
      func exportPhotoResource(originalID: String, to url: URL, allowNetworkAccess: Bool) async throws
      /// ONE performChanges: a PHAssetCreationRequest per request, with metadata and album adds. Returns originalID → created ID.
      func createStills(_ requests: [LivePhotoStillCreationRequest]) async throws -> [String: String]
      func fetchCreatedFacts(ids: [String]) async -> [String: CreatedStillFacts]
  }
  struct SystemLivePhotoLibraryWriter: LivePhotoLibraryWriting {
      init(changePerformer: any PhotoLibraryChangePerforming = SystemPhotoLibraryChangePerformer())   // WS-43 seam
  }
  enum LivePhotoStillVerifier {
      enum Failure: String, Sendable, CaseIterable { case missing, notImage, stillLive, dimensions, creationDate, location, favorite, hidden, albums }
      static func failures(original: LivePhotoOriginalSnapshot, created: CreatedStillFacts?) -> [Failure]
  }
  ```
  - **`createStills`, inside one change block for each request:**
    - `let r = PHAssetCreationRequest.forAsset()`.
    - `let o = PHAssetResourceCreationOptions()`, with `o.originalFilename = photoOriginalFilename` and `o.shouldMoveFile = true`.
    - `r.addResource(with: .photo, fileURL: photoFileURL, options: o)`.
    - Set `creationDate`, `location`, `isFavorite` and `isHidden` from the snapshot.
    - With the placeholder, for each carried album ID, run `PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)`. Albums are fetched **before** the block, in one `PHAssetCollection.fetchAssetCollections(withLocalIdentifiers:options:)`.
    - Collect placeholder IDs with a `CreatedAssetIdentifierBox`-style lock box keyed by original ID.
    - Never add a `.pairedVideo` resource.
    - Never call `deleteAssets` in this file.
  - **`snapshot`:**
    - Albums: `PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil)` mapped to `ReplacementAlbumCandidate`, then `ReplacementPlanner.albumIdentifiersToCarry` (WS-43).
    - The filename is the `.photo` resource's `originalFilename`, or `"Photo.heic"`.
  - **`failures`**, in this order:
    - `missing` if nil;
    - `!isImage`;
    - `isLivePhoto` → `stillLive`;
    - pixel dimensions must be equal;
    - `creationDate` within 1 s, when the original had one;
    - `location` within 1 m (`CLLocation.distance`), when the original had one;
    - `isFavorite` and `isHidden` equal;
    - `albumIDs ⊇ albumIDsToCarry`.
- **Edge cases:**
  - Every PhotoKit read runs off-main (`Task.detached`, `.utility`).
  - `shouldMoveFile` means Photos consumes the temp file on success. Temp cleanup must tolerate a missing file.

**WS-60.4 — `LivePhotoConversionJournal` and launch resolution**
- **Why:** FSB-01 item 5. A decline or a crash between creation and deletion must never silently leave duplicates.
- **Change:** new file `iOSCleanup/Engines/LivePhotoConversionJournal.swift`:
  ```swift
  struct LivePhotoConversionJournalEntry: Codable, Equatable, Sendable, Identifiable {
      enum State: String, Codable, Sendable { case awaitingOriginalDeletion, originalsKept, verificationFailed }
      struct Pair: Codable, Equatable, Sendable { let originalID: String; let stillID: String; let motionBytes: Int64 }
      let id: UUID; let createdAt: Date; var state: State; var pairs: [Pair]
  }
  final class LivePhotoConversionJournalStore {               // @MainActor use only
      static let key = "photoduck.live-photo-conversion-journal.v1"
      static let maximumEntries = 200
      init(defaults: UserDefaults)
      func load() -> [LivePhotoConversionJournalEntry]         // corrupt data → [] plus a DEBUG assertionFailure; never crash
      func upsert(_ e: LivePhotoConversionJournalEntry); func remove(entryID: UUID); func removePairs(stillIDs: Set<String>)
      var pendingStillCount: Int                               // pairs in .originalsKept or .verificationFailed
  }
  enum LivePhotoConversionJournalOp: Sendable {       // the service's `journal` closure takes these
      case upsert(LivePhotoConversionJournalEntry), remove(entryID: UUID), removePairs(stillIDs: Set<String>)
  }
  enum LivePhotoJournalResolver {
      enum Resolution: Equatable { case drop, keep(LivePhotoConversionJournalEntry) }
      /// Pure. `existing` = IDs that still resolve in PhotoKit. `canDropUnresolved` is true only under `.authorized`.
      static func resolve(_ e: LivePhotoConversionJournalEntry, existing: Set<String>, canDropUnresolved: Bool) -> Resolution
  }
  ```
  - **`resolve` rules, per pair** (when `canDropUnresolved == false`, every pair is kept, because an unshared ID only *looks* missing):
    - still gone → drop the pair;
    - original gone and still present → drop the pair (the conversion completed);
    - both present → keep the pair.
  - An entry with no pairs left → `.drop`. Otherwise `.keep`, and `.awaitingOriginalDeletion` becomes `.originalsKept`.
  - **Launch resolution:** add `func resolveLivePhotoJournal() async` to the facade, calling a small `LivePhotoConversionModel.resolveJournal(...)` helper. It runs only when authorization is `.authorized` or `.limited` (invariant 20), after bootstrap hydration. It fetches every journal ID in one `PHAsset.fetchAssets(withLocalIdentifiers:options:)` off-main, then applies the resolver. The options start from `PhotoLibraryFetch.identifierOptions()` (WS-40), with `includeHiddenAssets = true` set on the result so a hidden original or still never looks missing. It **never deletes anything**.
  - The journal lives in `dependencies.defaults`. It is safety data: Storage & Data › Clear (WS-48) must not touch it. Do not add it to `PhotoDuckLocalDataReset`.
- **Edge cases:**
  - Under Limited access an unshared ID looks missing. Treat `.limited` like `.authorized` for creation, but at launch **keep** pairs whose original or still is unresolvable. Only `.authorized` may drop pairs. Test this explicitly.
  - After a device restore the IDs do not resolve. Under `.authorized`, everything drops, which is correct.

**WS-60.5 — `LivePhotoStillConversionService`**
- **Change:** new file `iOSCleanup/Engines/LivePhotoStillConversionService.swift`:
  ```swift
  protocol LivePhotoOriginalDeleting: Sendable {
      @MainActor func deleteOriginals(_ ids: [String], keptStillByOriginal: [String: String], motionBytes: [String: Int64]) async throws -> DeletionResult
      @MainActor func deleteCreatedStills(_ ids: [String]) async throws -> DeletionResult
  }
  struct DeletionManagerLivePhotoDeleter: LivePhotoOriginalDeleting {   // live: resolves PHAssets off-main via PhotoLibraryFetch.identifierOptions() (+ includeHiddenAssets), then:
      // deleteOriginals → deletionManager.delete(assets:, requiredKeeperIDs: keptStillByOriginal, knownBytes: motionBytes, statsPolicy: .bytesOnly)
      // deleteCreatedStills → deletionManager.delete(assets:, statsPolicy: .none)
  }
  struct LivePhotoConversionReport: Equatable, Sendable {
      var converted: [String] = []                 // originals confirmed deleted
      var skipped: [String: [LivePhotoIneligibility]] = [:]
      var verificationFailed: [String] = []
      var pendingEntryIDs: [UUID] = []             // journal entries needing a user choice
      var motionBytes: Int64 = 0                   // Σ motion bytes of `converted`
      var stopReason: StopReason? = nil
      enum StopReason: Equatable, Sendable { case declined, cancelled, failed(String) }
  }
  actor LivePhotoStillConversionService {
      init(writer: any LivePhotoLibraryWriting = SystemLivePhotoLibraryWriter(),
           factsProvider: @escaping @Sendable ([String]) async -> [String: LivePhotoConversionFacts],
           motionMeasurer: any PairedVideoMeasuring = LivePairedVideoMeasurer(),
           deleter: any LivePhotoOriginalDeleting,
           journal: @escaping @MainActor @Sendable (LivePhotoConversionJournalOp) -> Void,
           temporaryDirectory: URL = LivePhotoStillConversionService.defaultTemporaryDirectory,
           now: @escaping @Sendable () -> Date = { Date() })
      static var defaultTemporaryDirectory: URL   // tmp/PhotoDuckLivePhotoStills
      static func sweepTemporaryDirectory()       // called from App.init next to VideoCompressionEngine.performStartupCleanup()
      func convert(ids: [String], options: LivePhotoConversionOptions,
                   progress: @escaping @Sendable (Int, Int) -> Void) async -> LivePhotoConversionReport
  }
  ```
  - **Per chunk**, in `LivePhotoConversionPlanner.chunks(ids)` order:
    1. Check `Task.isCancelled` **between chunks only**. On cancellation, stop with `.cancelled`. Never cancel inside a change block.
    2. Rebuild the facts for the chunk (`factsProvider`, off-main). Measure missing paired-video outcomes with `motionMeasurer` (network off). Recheck `eligibility`; ineligible items go to `skipped`.
    3. For each eligible item, get its `writer.snapshot`, then `writer.exportPhotoResource(to: tmp/<UUID>.<ext>)`. Failures go to `skipped` with `.photoNotLocal`.
    4. `let created = try await writer.createStills(requests)`, one transaction. On a throw: remove the temp files, set `.failed`, stop. No original has been touched.
    5. `writer.fetchCreatedFacts(ids: created.values)`, then `LivePhotoStillVerifier.failures`. Split the chunk into verified and failed pairs.
    6. **Journal before any delete.**
       - Write one entry per chunk: `.awaitingOriginalDeletion` for the verified pairs.
       - Write a separate `.verificationFailed` entry for the failed ones. Their originals are **never** deleted.
       - Journal ops hop to the main actor through the injected closure.
    7. If there are verified pairs, call `deleter.deleteOriginals(verifiedOriginalIDs, keptStillByOriginal: original→still, motionBytes: measured local bytes)`, one call per chunk:
       - `.deleted(receipt)`:
         - pairs whose original is in `receipt.assetIDs` → `converted`, remove them from the journal, and add their motion bytes;
         - pairs skipped as `.missing` → drop them from the journal (the original is already gone);
         - pairs skipped as `.keeperMissing` or `.undeletable` → state `.originalsKept`, and add the entry to `pendingEntryIDs`.
       - `.declined` → entry `.originalsKept`, `pendingEntryIDs`, `stopReason = .declined`, and **stop**. A declined prompt is never followed by more prompts.
       - A thrown error (including `.deletionAlreadyInProgress`) → `.originalsKept`, `.failed(copy)`, stop.
    8. Delete any temp files left from the chunk. Report progress.
  - `requiredKeeperIDs` = original → still, so WS-11 re-resolves each still at commit and skips the original (`.keeperMissing`) if its still vanished.
  - `knownBytes` = measured motion bytes, and `statsPolicy: .bytesOnly`. `DECISION (owner may override): converting credits only the measured motion bytes to "Sent to Recently Deleted" and monthly stats, and does not count converted Live Photos as "items cleaned".`
- **Edge cases:**
  - The app backgrounds mid-run. PhotoKit cannot show the prompt, so the delete throws or declines, and the entry is kept. So that auto-lock does not interrupt, `LivePhotoConversionModel` holds `let idleToken = IdleTimerCoordinator.shared.acquire(reason: "live-photo-conversion")` (WS-29, README §9 contract 7) around `convert`, and calls `IdleTimerCoordinator.shared.release(idleToken)` on every exit path (`defer`).
  - `.deletionAlreadyInProgress` means another deletion is running. Stop, keep the journal, and show "Another deletion is finishing. Try again."
  - Hidden items are excluded by default, but `isHidden` is still copied and verified, so a future opt-in stays safe.

**WS-60.6 — UI: explicit selection, confirmation, progress, outcome and the pending-stills card**
- **Change:**
  1. New `Views/Photos/LivePhotoConversionModel.swift`, a `@MainActor ObservableObject`:
     - It loads the eligible Live Photo assets for the grid through WS-59's `LivePhotoLibraryReading` plus `LivePhotoCandidateFilter` with the current options.
     - It exposes `exclusionCounts`.
     - It owns a `CategorySelectionModel` (WS-41) whose sizer is `{ asset in asset.cachedLivePhotoMotion.map { CategoryAssetSize(bytes: $0.deviceBytes, isEstimated: false) } ?? CategoryAssetSize(bytes: AssetResourceSizePolicy.livePhotoMotionEstimateBytes, isEstimated: true) }`.
     - It runs the service, publishes the report, and exposes `pendingEntries` from the journal store.
     - Methods: `keepBoth(entryID:)` removes the entry, and `removeNewStills(entryID:)` calls `deleter.deleteCreatedStills` (`.none` stats). `.deleted` removes those pairs; `.declined` keeps the entry.
  2. New `Views/Photos/LivePhotoReviewView.swift`, pushed from the explainer's "Choose Live Photos to convert" button (replacing WS-59's marker):
     - Toggles: "Include favorites" and "Include photos stored only in iCloud (uses data)". The second sets `allowNetworkAccess`, with the caption "Frees iCloud storage, not iPhone storage."
     - An excluded summary line from `exclusionCounts`.
     - A `LazyVGrid` of month sections with `PhotoThumbnailView` (WS-14). Nothing is pre-selected.
     - Tile taps call `selection.toggle(id, allowsMultiple: purchaseManager.canUse(.convertLivePhotos(count: 2)))`. `.requiresUnlock` opens `PaywallRequest(feature: .livePhotoBatchConversion, resume: { _ = selection.toggle(id, allowsMultiple: true) })`, so a purchase applies the tap the user made.
     - Select All and Select Month are locked controls for free users. The caption shows before any selection: "Free: convert one at a time. Pro: convert many at once."
     - Bottom bar: "Convert N · ≈X". Tapping it presents the confirmation dialog:
       - title "Convert N Live Photos to still photos?";
       - message "The motion and sound are removed. Each still keeps its date, location, favorite and albums. The originals move to Recently Deleted, and ≈X is freed after you empty it. iOS asks you to confirm each batch of up to 25.";
       - buttons "Convert N" and "Cancel".
     - Then a non-dismissable progress overlay, "Converting 25 of 300… Keep PhotoDuck open.", with a "Stop after this batch" button that cancels the task.
     - Outcome sheet:
       - success: "Converted N Live Photos. ≈X of motion moves to Recently Deleted with the originals.";
       - declined or kept: "N new stills are copies of Live Photos you kept." with "Keep both" and "Remove the N new stills";
       - failures: "N couldn't be converted and were left unchanged."
  3. New `Views/Home/LivePhotoPendingStillsCard.swift`: a `DuckCard` shown when `pendingEntries` is non-empty: "N converted stills are copies of Live Photos you kept", with "Keep both" and "Remove N stills". Add one line in `HomeView` after WS-32's `FinishFreeingSpaceCard`.
- **Edge cases:**
  - The gating decision comes from `CleanupAccessPolicy` only (invariant 10). Never read `isPurchased`.
  - Invariant 8: nothing is pre-selected, even after an options toggle.
  - When the options change, the model reconfigures and drops selected IDs that are no longer eligible.

**WS-60.7 — Docs**
- `CLAUDE.md` deletion-safety section: "Live Photo conversion creates stills in one transaction, verifies them, journals them, then deletes originals through `DeletionManager` (one prompt per ≤25). It is not an exemption."
- The workspace `../CLAUDE.md` key invariants need the same sentence. That file is in the outer repo, so list it as an owner action in the PR.
- `README.md` feature list.

### Tests
- **`iOSCleanupTests/LivePhotoConversionPlannerTests.swift`** (pure):
  - `testLoopOrBounceExcluded`.
  - `testLongExposureOtherPlaybackExcluded`.
  - `testAdjustmentDataResourceExcludedEvenWithoutHasAdjustments`.
  - `testHiddenExcluded`.
  - `testFavoriteExcludedByDefaultAndIncludedWhenOptedIn`.
  - `testNonUserLibraryExcluded`.
  - `testCannotDeleteExcluded`.
  - `testDepthEffectExcluded`.
  - `testICloudOnlyPairedVideoExcludedUnlessNetworkAllowed`.
  - `testPhotoNotLocalExcludedUnlessNetworkAllowed`.
  - `testUnknownLocalityIsNotAReason`.
  - `testMissingPhotoResourceExcluded`.
  - `testAllReasonsReportedInOrder`.
  - `testChunksNeverExceedTwentyFive`: 0, 1, 25, 26 and 301 items.
- **`iOSCleanupTests/LivePhotoStillConversionServiceTests.swift`.** It uses a `FakeLivePhotoWriter` actor that records calls and returns scripted created IDs and facts, a `FakeLivePhotoDeleter` returning scripted `DeletionResult`s and recording its arguments, an in-memory journal recorder and a temp directory.
  - `testDeleteNeverCalledBeforeCreateAndVerify`: an ordered call log shows `createStills` < `fetchCreatedFacts` < journal upsert < `deleteOriginals`.
  - `testFailedVerificationKeepsThatOriginalAndConvertsOthers`: 3 items, one created still `isLivePhoto == true` → `deleteOriginals` receives 2 IDs, a `.verificationFailed` entry holds 1 pair, and `report.verificationFailed.count == 1`.
  - `testCreateRequestCarriesDateLocationFavoriteHiddenAndAlbums`: the snapshot values arrive unchanged in `createStills`.
  - `testDeclinedDeleteKeepsJournalAndStopsRun`: 60 IDs (3 chunks); chunk 1 declined → `deleteOriginals` called once, the entry is `.originalsKept`, `stopReason == .declined`, and `createStills` was called once.
  - `testChunksNeverExceedTwentyFive`: 60 IDs → `createStills` batch sizes `[25, 25, 10]`.
  - `testJournalClearedAfterSuccessfulDelete`.
  - `testKeeperMissingSkipKeepsPairPending`: the receipt reports `.keeperMissing` for one original.
  - `testMissingOriginalSkipDropsPair`.
  - `testRequiredKeeperMapsOriginalToStill` and `testKnownBytesAreMeasuredMotionBytes`.
  - `testCreateFailureLeavesOriginalsAndCleansTemp`: the temp directory is empty afterwards.
  - `testCancellationStopsBetweenChunksOnly`.
  - `testIneligibleAtCommitIsSkippedWithReason`: the facts provider now reports `.adjustmentData`.
- **`iOSCleanupTests/LivePhotoConversionJournalTests.swift`:**
  - `testResolverDropsCompletedAndVanishedStills`.
  - `testResolverKeepsBothPresentAsOriginalsKept`.
  - `testLimitedAccessNeverDropsUnresolvedPairs`.
  - `testStoreRoundTripsAndCapsEntries`.
  - `testCorruptJournalLoadsEmpty`.
  - `testRemovePairsByStillIDs`.
- **`iOSCleanupTests/DeletionManagerTests.swift`:**
  - `testBytesOnlyPolicyCreditsBytesNotItems`.
  - `testNonePolicyRecordsNoStatsButEmitsReceiptAndConfirmedDeletions`.
  - `testDefaultPolicyUnchanged`.
- **`iOSCleanupTests/CleanupStatsStoreTests.swift`:** `testZeroItemDeletionAddsBytesOnly`.
- Device-only: WS-60.0 and the Device QA below.

### Acceptance criteria
- [ ] WS-60.0 is recorded in the PR and in `docs/DEVICE_QA.md`: the still has no `.photoLive` and the same date, location, favorite, hidden state and albums; a decline leaves stills that the Home card resolves.
- [ ] Converting 50 local, unedited Live Photos yields 50 stills with identical metadata and the originals in Recently Deleted, with two iOS prompts (25 + 25) (Device QA 1).
- [ ] Loop, Bounce, edited, hidden and portrait Live Photos are never listed by default. Favorites are listed only with the toggle (planner tests plus Device QA 2).
- [ ] The service never calls `deleteOriginals` before creation, verification and the journal write (`testDeleteNeverCalledBeforeCreateAndVerify`).
- [ ] A decline or a crash never silently leaves duplicates: the journal plus the Home card (tests plus WS-60.0 steps 3–4).
- [ ] `grep -rn "deleteAssets" iOSCleanup/Engines/LivePhoto* iOSCleanup/Views/Photos/LivePhoto*` finds nothing. WS-11's `DeletionLintTests` still pass.
- [ ] Converting one is free, and a second selection shows the lock before selection (`CleanupAccessPolicyTests` already cover `.convertLivePhotos`, plus a view check in Device QA 3).
- [ ] Stats credit motion bytes only, and "Items cleaned" is unchanged by a conversion (tests).
- [ ] Zero new warnings. `CLAUDE.md` is updated, and the outer `../CLAUDE.md` change is listed as an owner action.

### Device QA
1. Select 50 local, unedited Live Photos (as Pro), convert, allow both prompts. Spot-check 5 stills in the Info panel and in two albums. Empty Recently Deleted and record the free-space change against the "≈X" shown (±25%).
2. Make one Loop, one Bounce, one edited, one portrait and one favorite Live Photo. Only the favorite appears, and only after "Include favorites".
3. As a free user: select one (no lock), then try a second (lock and paywall, the selection is unchanged). Select All shows the lock before anything is selected.
4. With Optimize iPhone Storage on, an iCloud-only Live Photo is not listed until the iCloud toggle is on. With the toggle on, it converts, and the outcome says it frees iCloud storage.
5. Background the app during the second prompt. The run stops, and the Home card appears on return.

### Pitfalls and out of scope
- **Never** reuse WS-43's `replaceOriginal` or put `deleteAssets` in a conversion file (invariant 4).
- **Never** add the `.fullSizePhoto` resource. That would bake an edit into the new original, and edited items are excluded anyway.
- Never auto-delete app-created stills. Removal is always a user choice through `DeletionManager`.
- Do not count conversions as items (WS-60.2), and do not change WS-32's ledger semantics beyond the policy switch.
- The measurement tile and explainer are WS-59. The review prompt is WS-58. Do not redesign Duck Mode or the Paywall (invariant 29).
- **Reconciliation:**
  - The idle timer uses WS-29's exact API: `acquire(reason:)`, then `release(_:)` on every exit (README §9 contract 7).
  - PhotoKit ID lookups (journal resolution, the deleter, the writer's snapshot) start from WS-40's `PhotoLibraryFetch.identifierOptions()`, with `includeHiddenAssets = true` set where a hidden item must resolve. `PhotoFetchLintTests` stays green, and there is no `PHFetchOptions()` in a conversion file.
  - Gating uses WS-36's `CleanupAction.convertLivePhotos(count:)` and `PaidFeature.livePhotoBatchConversion` unchanged (contract 11).
  - `DeletionStatsPolicy` is additive to WS-11's `delete(assets:requiredKeeperIDs:knownBytes:)`. WS-64's monthly buckets read it (`.bytesOnly` records items 0; `.none` records nothing).
  - New UI follows chapter rule 7.

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| FSB-01 | confirmed | No conversion exists (`ROADMAP.md:19`, `:51`). `saveAndDeleteOriginal` (VideoCompressionEngine.swift:477-531) deletes directly with a prompt per asset and leaves a duplicate on decline. `delete(assets:)` is at DeletionManager.swift:146-148. The plan follows the fix, with five changes. Verification also checks location, favorite, hidden and albums, not just count, subtype, dimensions and date. `requiredKeeperIDs` (original → still) lets WS-11 refuse to delete an original whose still vanished. A declined chunk stops the run instead of prompting 20 more times. Journal resolution never drops pairs under Limited access. A `DeletionStatsPolicy` keeps conversions from counting as cleaned items. |

DECISION (owner may override): after a declined prompt the conversion run stops, and the pending stills stay on a Home card until the user picks "Keep both" or "Remove the N new stills".

---

## WS-61 — Cross-date identical copies

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M4 | M | WS-38, WS-53 | no | `ws/61-cross-date-identical-copies` |

**Primary files:**
- New engine files: `iOSCleanup/Engines/PerceptualHash.swift`, `iOSCleanup/Engines/IdenticalCopyIndex.swift`
- Existing engine files:
  - `iOSCleanup/Engines/PhotoScanEngine.swift` (thin wiring; `makePerceptualHash` becomes a forward)
  - `iOSCleanup/Engines/PhotoScanWorkingSet.swift` (WS-23)
  - `iOSCleanup/Engines/CompactPairEdge.swift` (WS-53; one flag bit)
  - `iOSCleanup/Engines/PhotoAssetAnalysisPipeline.swift` (WS-22)
  - `iOSCleanup/Engines/SimilarityPolicyTypes.swift`
  - `iOSCleanup/Engines/SimilarityPolicyServices.swift`
  - `iOSCleanup/Engines/SimilarityThresholdProfile.swift` (WS-39)
  - `iOSCleanup/Engines/DuplicateVerificationService.swift` (WS-38 gate)
- Views: `iOSCleanup/Views/Photos/PhotoResultsView.swift` (one caption, if WS-45.6 did not ship it)
- Tests: `iOSCleanupTests/PerceptualHashTests.swift` (*new*), `iOSCleanupTests/IdenticalCopyIndexTests.swift` (*new*), `iOSCleanupTests/SimilarityPolicyTests.swift`, `iOSCleanupTests/DuplicateVerificationTests.swift`, `iOSCleanupTests/PhotoScanEngineEndToEndTests.swift`, `iOSCleanupTests/PhotoScanEngineTests.swift`, `iOSCleanupTests/PhotoScanScaleGoldenTests.swift` (WS-53; must stay unchanged)

**Findings covered:** SCAN-17 (P3, partially; merged: VALUE-15 partially, its photo half. The video half is WS-62.)

**Decisions applied:**
- **D-SCOPE:** cross-date identical copies are M4.
- **D-THRESHOLDS:** no existing threshold changes. `identicalCopyMaxFeatureDistance` (0.01, WS-38/WS-39) is reused. One new destructive bound (aHash Hamming ≤ 3) lives in `DestructiveSimilarityThresholds`.
- **D-REANALYSIS:** no `analyzerVersion` bump. The hash algorithm is byte-identical.

### Goal
Two copies of the same image saved on different days, for example from WhatsApp, Safari or a double import, are compared and grouped:
- **Keep Best** when WS-38 verification says `.identical`;
- **review-only** otherwise.

Every non-identical strong match on different days stays ungrouped, exactly as today. Nothing loosens any time-bound rule for other photos, and verification never downloads iCloud originals without opt-in.

### Current behavior (verified)
- Camera candidates come only from the ±60 min walk: `PhotoScanCandidateSelector.genericCandidateIDs` (`PhotoScanEngine.swift:1848-1891`, early `break` at the extended window) via `comparisonCandidateIDs` (`:1206-1234`). WS-23 moved this into `PhotoScanWorkingSet.candidateIDs(for:perceptualHash:)`.
- Hash buckets exist only for screenshots (`screenshotIDsByHash`, `:551`, `:571-573`, `:826-837`). WS-38 replaced them with `ScreenshotHashIndex`.
- `nearDuplicateEligible` requires `timeDelta <= nearDuplicateWindowSeconds` (20 s) (`SimilarityPolicyServices.swift:155-159`). A gap over 120 s adds `.largeTimeGap` unless both are extreme screenshot matches (`:115-122`). The cluster classifier requires `maxTimeSpan <= nearDuplicateWindowSeconds` for `.nearDuplicate` (`:465-484`) and downgrades otherwise (`:511-521`).
- `sharedTimeScore` returns 0 beyond 60 min (`:887-893`). An identical pair across days therefore scores `0.958 × 0.55 ≈ 0.53`, below `nearDuplicateAutoDeleteScoreFloor` 0.60 (`SimilarityPolicyTypes.swift:261`).
- `iOSCleanupTests/SimilarityPolicyTests.swift:562-582` `testStrongCameraMatchOnDifferentDayDoesNotGroup` (distance 0.005, 86,400 s apart) asserts `.notSimilar`. Its descriptors carry no hash.
- The 64-bit average hash `makePerceptualHash` (`PhotoScanEngine.swift:1092-1114`) is computed for every analyzed photo, including on Vision failure (`:1076-1085`). It is persisted in the ML analysis row and returned by `cachedAssetAnalyses` (`PhotoMLBridge.swift:151-189`). WS-07 made it internal. WS-22 calls it from `PhotoAssetAnalysisPipeline`.
- Non-screenshot embeddings leave memory once the window passes. Today that is positional at 480 (`:848-861`); after WS-23 it is time-based (±60 min) with a 4,096 cap. After WS-46 the warm cache stores analyses only for the **10,000 newest** photos.
- `ROADMAP.md:31` concedes exact duplicates to Apple's Duplicates album. WS-45.6 (optional) adds a caption pointing there.

### Implementation plan

**WS-61.1 — `PerceptualHash` (shared, byte-identical)**
- **Change:** new file `iOSCleanup/Engines/PerceptualHash.swift`:
  ```swift
  nonisolated enum PerceptualHash {
      /// 8×8 device-gray downsample, .low interpolation — the exact drawing code of today's makePerceptualHash.
      static func grayPixels8x8(_ image: CGImage) -> [UInt8]?
      /// Bit i set when pixel i >= integer mean — byte-identical to PhotoScanEngine.makePerceptualHash.
      static func average64(pixels: [UInt8]) -> UInt64
      static func average64(_ image: CGImage) -> UInt64?
      static func luminanceRange(pixels: [UInt8]) -> Int          // max - min; WS-62 uses it
      static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }
  }
  ```
  - `PhotoScanEngine.makePerceptualHash(from:)` becomes a one-line forward (the fixture analyzer and the pipeline still call it).
  - WS-38's `ScreenshotHashIndex` switches its Hamming math to `hammingDistance`.

**WS-61.2 — `IdenticalCopyIndex` (pure, bounded)**
- **Why:** Identical copies share exact pixel dimensions and nearly always the exact aHash. Bucketing by both finds them at any time distance without an all-pairs scan.
- **Change:** new file `iOSCleanup/Engines/IdenticalCopyIndex.swift`:
  ```swift
  enum IdenticalCopyTuning {
      static let maximumHashDistance = 3           // 4 bands × 16 bits: pigeonhole guarantees a shared band only for d ≤ 3
      static let maximumCandidatesPerAsset = 8
      static let maximumMembersPerBandBucket = 8   // most recent kept
      static let maximumIndexedAssets = 80_000     // FIFO eviction beyond this
      static let maximumSupplementalLookupsPerRun = 2_000
      static let maximumMissFlushesPerRun = 32
      static let rareDimensionBucketLimit = 8      // incremental context: ≤ 8 library photos share the exact size
      static let maximumRareDimensionContext = 500
  }
  struct IdenticalCopyIndex {
      mutating func insert(id: String, pixelWidth: Int, pixelHeight: Int, hash: UInt64)
      mutating func remove(id: String)
      /// Same exact dimensions, Hamming ≤ maximumHashDistance, most recent first, excluding `id`.
      func candidates(for id: String, pixelWidth: Int, pixelHeight: Int, hash: UInt64, limit: Int = IdenticalCopyTuning.maximumCandidatesPerAsset) -> [String]
      var count: Int { get }
  }
  enum IdenticalCopyContextPlanner {
      /// Incremental scans: library images (not screenshots, not bursts, not required) whose exact (w, h) bucket
      /// holds ≤ rareDimensionBucketLimit members, for each required non-screenshot, non-burst image. Capped.
      static func contextIDs(required: [PHAsset], library: [PHAsset]) -> Set<String>
  }
  ```
  - **Storage:**
    - `ordinalByID: [String: Int32]` and `idByOrdinal: [String?]` (FIFO over `maximumIndexedAssets`);
    - `hashByOrdinal: [UInt64]`;
    - `buckets: [BandKey: [Int32]]`, where `struct BandKey: Hashable { let w: Int32; let h: Int32; let band: UInt8; let value: UInt16 }`.

    Four inserts per asset. Buckets hold ordinals, not strings, so memory stays at about 1–2 MB at 60k.
  - **Lookup:** union the 4 band buckets, drop evicted ordinals and `id`, keep Hamming ≤ 3, sort by ordinal descending (most recent first), prefix `limit`.
- **Edge cases:**
  - Screenshots and burst members are never inserted. Screenshots use WS-38's index; bursts use PhotoKit burst logic.
  - Assets with a nil hash or nil embedding are not inserted.

**WS-61.3 — Pair and cluster rule: "identical copy saved on a different date"**
- **Change:**
  1. `SimilarityThresholdProfile.swift` (WS-39): add `var identicalCopyMaxHashDistance: Int` to `DestructiveSimilarityThresholds`, set to `IdenticalCopyTuning.maximumHashDistance` in `.standard`. Destructive, and never changed by WS-63 presets. Do not bump `revision`: no existing value changes.
  2. `SimilarityPolicyTypes.swift`:
     - `SimilarityAssetDescriptor` gains `let perceptualHash: UInt64?`, an init parameter defaulting to `nil`, so old tests and Codable still work.
     - Add `SimilaritySignalBuilder.descriptor(for:perceptualHash:)`; the existing signature forwards with `nil`.
     - `SimilaritySignals` gains `let perceptualHashDistance: Int?`, computed in `make` when both hashes are non-nil. It is optional, so Codable is unaffected.
     - `PairEligibilityResult` gains `let isIdenticalCopy: Bool`, with a memberwise-init default of `false`. First `grep -rn "PairEligibilityResult.self" iOSCleanup`: if it is decoded anywhere, add `init(from:)` with `decodeIfPresent ?? false`.
  3. `ConservativePairSimilarityClassifier.classifyPair`: before the bucket selection, compute
     ```swift
     let identicalCopyEligible = visualEvidenceAvailable
         && !signals.bothScreenshots && !signals.screenshotMixedWithCamera
         && !signals.isBurstPair
         && signals.variantRelationship == .none
         && !signals.editedStateDivergence
         && lhs.pixelWidth == rhs.pixelWidth && lhs.pixelHeight == rhs.pixelHeight
         && (signals.perceptualHashDistance.map { $0 <= profile.destructive.identicalCopyMaxHashDistance } ?? false)
         && featureDistance <= profile.destructive.identicalCopyMaxFeatureDistance
         && timeDelta > profile.destructive.nearDuplicateWindowSeconds      // within 20 s the normal rule applies
     ```
     When true:
     - do **not** append `.largeTimeGap` (extend the existing exemption condition);
     - compute `timeScore` as `sharedTimeScore(for: nearDuplicateWindowSeconds)` (0.15), giving about 0.68 for an identical pair;
     - set `provisionalBucket = .nearDuplicate` and `eligible = true`;
     - skip the "Downgraded from near-duplicate" time clause;
     - append the reason "Identical copy saved on a different date";
     - return `isIdenticalCopy: true`.

     Every other path is unchanged, so `testStrongCameraMatchOnDifferentDayDoesNotGroup` (no hashes) stays `.notSimilar`.
  4. Cluster classifier (`:337-532`): `let isIdenticalCopyCluster = pairResults.values.contains(where: \.isIdenticalCopy)`.
     - In the `.nearDuplicate` branch, replace `maxTimeSpan <= nearDuplicateWindowSeconds` with `(maxTimeSpan <= nearDuplicateWindowSeconds || isIdenticalCopyCluster)`. The branch still requires *every* pair to be eligible `.nearDuplicate`, and the pair classifier only allows cross-window near-duplicates for identical copies.
     - In the final downgrade clause (`:511-521`), exempt only the time-span part: `(maxTimeSpan > nearDuplicateWindowSeconds && !isIdenticalCopyCluster) || hardBlockers.contains(.majorCompositionChange) || hardBlockers.contains(.differentIntent)`.
     - Hard blockers still downgrade as before.
- **Edge cases:**
  - A cluster that mixes a within-window near-duplicate and a cross-date identical copy is allowed only if **every** pair is eligible `.nearDuplicate`. Complete-link still applies.
  - Favorites and album-curated members stay protected by WS-13 at plan time. The keeper is chosen by score, then `KeeperTieBreaker` (WS-38.5): favorite, edited, larger measured bytes, more albums, earlier capture.

**WS-61.4 — The verification gate requires `.identical` for cross-date clusters**
- **Change:** WS-38's `DuplicateVerificationGate.evaluate(_:isScreenshotCluster:)` gains `requiresIdentical: Bool = false`.
  - When true, only `.identical` allows a destructive plan.
  - `.nearIdentical` and `.sceneMatch` are denied with the reason "Saved on different dates, and PhotoDuck couldn't confirm they're exact copies." and no blocker.
  - `makeGroups` passes `requiresIdentical: isIdenticalCopyCluster`, computed from the cluster's pair results.
  - WS-38.5's `isVerifiedIdenticalCluster` is unchanged: same dimensions, every pair distance ≤ 0.01, and `.identical`. It is still the only exemption from the 0.08 margin (invariant 6).
- **Edge cases:** iCloud-only members make verification `.unavailable`, which is review-only. The network is used only with the scan's existing opt-in (invariant 11).

**WS-61.5 — Engine wiring: candidates, supplemental embeddings, incremental context**
- **Change** (keep `PhotoScanEngine.swift` edits to calls; logic lives in the new files and in WS-23's working set):
  1. `PhotoScanWorkingSet`:
     - Hold `var identicalIndex = IdenticalCopyIndex()`.
     - `candidateIDs(for:perceptualHash:)` appends `identicalIndex.candidates(...)` for non-screenshot, non-burst descriptors with a hash, deduplicated against the generic candidates, at most 8 extra, outside the 120 generic cap.
     - Build descriptors with `descriptor(for:perceptualHash:)` in both `ingestTarget` and `ingestContext`.
     - After evaluation, insert into `identicalIndex` when the hash and embedding are present and the asset is neither a screenshot nor a burst member.
     - Add `func idsNeedingSupplementalEmbeddings(_ candidateIDs: [String]) -> [String]`: identical-index candidates with no resident embedding.
     - `ingestTarget` and `ingestContext` gain `supplementalEmbeddings: [String: Data] = [:]`. The shared `evaluatePairs` uses them only when the resident embedding is missing. They are never inserted into resident features, so WS-23's 4,096 bound holds.
  2. In `IdenticalCopyIndex.swift`, add `struct IdenticalCopyEmbeddingLoader` with budget counters and `mutating func load(_ ids: [String], assets: [String: PHAsset], bridge: PhotoMLBridge) async -> [String: Data]`:
     - It calls `bridge.cachedAssetAnalyses(for:)` for the missing assets.
     - On a miss, it calls `await bridge.flushBufferedWrites()` once, then retries. At most `maximumMissFlushesPerRun` flushes per run.
     - Once `maximumSupplementalLookupsPerRun` is used, it returns `[:]`.
     - A DEBUG counter `identicalCopyMissingEmbeddingCount` is logged at scan end (counts only).
  3. The engine per-asset flow (target and context) becomes: `candidateIDs` → `idsNeedingSupplementalEmbeddings` → `await loader.load` → `ingestTarget/ingestContext(…, supplementalEmbeddings:)`. The loader is a local `var` in `performScan`.
  4. `incrementalAssets(from:requiredAssetIDs:)`: union in `IdenticalCopyContextPlanner.contextIDs(required:library:)`. Context flows through WS-23's context stream unchanged: cached context is ingested, and uncached context becomes targets. That is bounded at 500.
  5. `makeGroups` builds groups exactly as today. The pair reason flows into `groupReasonsSummary`.
- **Edge cases:**
  - **WS-46 window:** an older copy outside the 10,000-newest warm cache, and no longer resident, has no embedding. That pair gets a nil distance and is skipped. This is a documented limitation (DECISION below), and it is safe.
  - **WS-53 (chapter 11) compact edges.** After WS-53 the working set keeps `edges: [SimilarityPairKey: RetainedPairEdge]` (signals plus `CompactPairEligibility`), not full `PairEligibilityResult`s. So:
    - add bit 2 `isIdenticalCopy` to `CompactPairEligibility.flags`, set from `PairEligibilityResult.isIdenticalCopy` in its `init`;
    - expose `var isIdenticalCopy: Bool` on `CompactPairEligibility` and forward it from `RetainedPairEdge`;
    - `makeGroups` computes `isIdenticalCopyCluster` (for WS-61.4's `requiresIdentical`) from `workingSet.edges[key]?.eligibility.isIdenticalCopy` over the cluster's pairs. `classifyCluster` recomputes full results from `signals`, which now carry `perceptualHashDistance`, so WS-61.3's cluster rule sees the same flag.

    Identical-copy edges are ordinary eligible edges in `workingSet.edges`, so they reach the generic `formClusters` unchanged.
  - **WS-53 frontier pruning.** WS-53 as specified adds no frontier-based edge pruning or cluster freezing: every retained edge lives until the scan ends. If time-window finalization (WS-53's BACKLOG item) has landed, exempt `isIdenticalCopy` edges from it. Re-read WS-53's landed code first.
  - **Edge size.** Keep WS-53's `testPeakEdgeCountIsReported` (`MemoryLayout<RetainedPairEdge>.stride ≤ 96`) green. If `SimilaritySignals.perceptualHashDistance` pushes the stride over, store it as `UInt8?` (a 64-bit Hamming distance fits).
  - Invariant 17: the per-asset order, `bufferingNewest(1)` and watchdog accounting are unchanged. The loader await sits in the same place as WS-23's context-loading await.

**WS-61.6 — Copy**
- If WS-45.6's caption is missing, add it to `PhotoResultsView` below the list and in the empty state: "Exact copies saved on different days? PhotoDuck checks the ones on this iPhone. iOS also lists them in Photos › Albums › Utilities › Duplicates." If WS-45.6's caption exists, change its first sentence to that one.
- Group rows show the reason string above. Do not change row layout.

### Tests
- **`iOSCleanupTests/PerceptualHashTests.swift`:**
  - `testAverage64MatchesLegacyImplementationBitForBit`: synthetic gradient, checkerboard, uniform and 3-color CGImages. Compare against a copy of the pre-move function kept in the test file.
  - `testHammingDistance`.
  - `testLuminanceRangeOfUniformImageIsZero`.
- **`iOSCleanupTests/IdenticalCopyIndexTests.swift`:**
  - `testExactHashAndDimensionsFound`.
  - `testHammingThreeFoundWhenBitsSpreadAcrossFourBands`.
  - `testHammingFourRejected`.
  - `testDifferentDimensionsNeverCandidates`.
  - `testMostRecentFirstAndLimit`.
  - `testBandBucketCapHolds`.
  - `testFIFOEvictionBeyondMaximum`: small maximum via an internal init.
  - `testRemove`.
  - `testContextPlannerIncludesRareDimensionsOnly`: a bucket of 3 is included, a bucket of 9 is excluded.
  - `testContextPlannerSkipsScreenshotsBurstsAndCaps`.
- **`iOSCleanupTests/SimilarityPolicyTests.swift`:** keep `testStrongCameraMatchOnDifferentDayDoesNotGroup` **unchanged**. Add:
  - `testIdenticalCopyOnDifferentDayIsEligibleNearDuplicate`: hashes equal, same dimensions, distance 0.005, 30 days → eligible, `.nearDuplicate`, `isIdenticalCopy`, no `.largeTimeGap`, score ≥ 0.60.
  - `testDifferentDayHashDistanceFourNotIdentical`.
  - `testDifferentDayDifferentDimensionsNotIdentical`.
  - `testDifferentDayDistanceAboveIdenticalCutoffNotGrouped`: 0.02 → `.notSimilar`.
  - `testIdenticalCopyRuleIgnoresLivePhotoVariantAndEditedPairs`.
  - `testCrossDateIdenticalClusterSuggestsDeleteOthers`: cluster classifier → `.nearDuplicate` / `.suggestDeleteOthers` / `.high`.
  - `testWithinWindowNearDuplicateUnchanged`: a regression pin on today's 2 s case.
- **`iOSCleanupTests/DuplicateVerificationTests.swift`:** `testGateRequiresIdenticalForCrossDateClusters`: `.identical` is allowed; `.nearIdentical` and `.sceneMatch` are denied with the reason; `.unavailable` is denied.
- **`iOSCleanupTests/PhotoScanEngineEndToEndTests.swift`** (WS-08 fixtures, `StubDuplicateVerifier`, a temp bridge with default tuning):
  - `testEndToEndCrossDateIdenticalCopiesBecomeKeepBestEligible`:
    - Setup: A and B are 30 days apart with the same size, hash and embedding, plus 20 unrelated fillers between them. The verifier returns `.identical`.
    - Assert:
      - one `.nearDuplicate` group {A, B};
      - `isAutoCleanEligible`;
      - keeper A;
      - `deleteCandidateIDs == ["B"]`;
      - reasons contain "Identical copy saved on a different date" and "Kept the earlier copy";
      - `PhotoDeletionGuardrails.validate(group:)` does not throw.
  - `testEndToEndCrossDateNearIdenticalStaysReviewOnly`: the verifier returns `.nearIdentical` → `.reviewManually` and empty delete IDs.
  - `testEndToEndCrossDateDifferentDimensionsNotGrouped`.
  - `testEndToEndIncrementalScanFindsCopyOfOldPhotoWithRareDimensions`:
    - A full scan analyzes A (1600×1200, unique).
    - Then run incremental with required {B}, B identical and 60 days later.
    - A arrives as cached context, and the group forms.
- **Regression pins:** WS-53's `PhotoScanScaleGoldenTests` (both literals) and WS-08's end-to-end tests pass **unchanged**, because their fixtures contain no cross-date identical copies. If a golden line changes, stop and report it; do not re-record the literal. Add `testCompactEdgeCarriesIdenticalCopyFlag` to `PhotoScanEngineTests`: `CompactPairEligibility(result)` round-trips `isIdenticalCopy`, `eligible` and `isBurstBucket`.
- Performance: none new. `testEngineThroughputWithFiveMillisecondAnalyzer` (WS-08) must stay within its ratio.

### Acceptance criteria
- [ ] Verified identical copies saved any number of days apart form a Keep Best group only with `.identical` verification. Otherwise the group is review-only (tests).
- [ ] `testStrongCameraMatchOnDifferentDayDoesNotGroup` is unchanged and green. No existing threshold value changed (`testStandardProfileMatchesLegacyValues`, WS-39).
- [ ] Only verified identical clusters skip the 0.08 margin (WS-38 tests unchanged).
- [ ] With the network off, iCloud-only copies stay review-only (Device QA 2).
- [ ] The 64-bit hash is bit-identical, and there is no `analyzerVersion` bump.
- [ ] Resident embeddings never exceed WS-23's cap, because supplemental embeddings are transient (DEBUG peak counter in the E2E test).
- [ ] Full suite green, zero warnings. `CLAUDE.md`'s similarity policy section documents the identical-copy rule and its warm-cache limit.

### Device QA
1. Save the same WhatsApp image today, and a copy saved 3+ weeks ago (or AirDrop an image to yourself twice on different days). Run Scan Again. One Keep Best group forms with "Identical copy saved on a different date", and Keep Best removes one.
2. With Optimize iPhone Storage on, repeat with an old copy whose original is in iCloud. The group is review-only, and no download happens.
3. Two different photos with the same dimensions shot on different days are not grouped.
4. Add a new copy of an old image, then let the automatic incremental scan run. The group appears without Scan Again (rare-dimension context).

### Pitfalls and out of scope
- Never relax `nearDuplicateWindowSeconds`, the visual windows or any existing floor (D-THRESHOLDS). The rule is additive and gated on hash, dimensions, distance and `.identical`.
- Never let verification *create* a plan (WS-38 pitfall). The pair rule proposes and the gate permits.
- Do not add a hash column or index to the ML store. WS-46's cache is bounded by design, and the limit is documented.
- Duplicate videos are WS-62. Presets are WS-63 and never touch `identicalCopyMaxHashDistance`.
- **Reconciliation:**
  - WS-53 landed before this workstream. The identical-copy flag rides in `CompactPairEligibility`, and any frontier-based edge pruning or cluster freezing must exempt `isIdenticalCopy` edges. WS-53 adds none, and its BACKLOG entry carries the same rule.
  - `IdenticalCopyIndex` keeps 4 bands × 16 bits for Hamming ≤ 3. That is separate from WS-38's `ScreenshotHashIndex`, which uses 7 bands (six 9-bit, one 10-bit) for Hamming ≤ 6 (README §9 contract 12). Share only `PerceptualHash.hammingDistance`, not the band layout.
  - WS-38 hands SCAN-M04's leftover to this workstream: band selection of *screenshot* context for incremental scans. That needs indexed hash lookups in the ML store, which this workstream deliberately does not add. It stays deferred. Add (or keep) a `spec/BACKLOG.md` entry: "SCAN-M04 leftover: incremental-context screenshot band selection via an indexed hash column; WS-61's rare-dimension context covers exact camera copies only."

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| SCAN-17 | partially | Behavior confirmed: `genericCandidateIDs` ±60 min (PhotoScanEngine.swift:1848-1891), near-duplicate ≤ 20 s (SimilarityPolicyServices.swift:155-159), hash buckets only for screenshots, and the different-day test at SimilarityPolicyTests.swift:562-582. It is a documented product concession (ROADMAP.md:31). Plan changes: the bucket key is exact dimensions plus banded aHash with Hamming ≤ 3 (not an exact 64-bit key, which misses re-saves whose average flips a bit). The bucket cap is 8, not 120. Embeddings of old copies come from the warm cache on demand instead of a retention list, which keeps the WS-23 memory bound. The time component uses the near-duplicate score (0.15), because identical copies otherwise score 0.53 < 0.60 and could never be high confidence. The gate requires `.identical`. |
| VALUE-15 (merged) | partially | Photo half: correct that non-screenshots are compared only inside session windows, but "append matches to comparisonCandidateIDs" alone does nothing, because the time rules reject the pair. It needs the classifier rule above. The incremental-context update is done with rare-dimension context, not ML-store hash lookups. Video half: superseded by FSB-07 (WS-62). |

DECISION (owner may override): an identical copy is found only when the older copy is still resident in the scan, or is among the 10,000 newest photos in the warm cache (WS-46). Older copies are left to Photos' Duplicates album, which the caption mentions.
DECISION (owner may override): identical-copy candidates require exactly equal pixel dimensions and aHash Hamming ≤ 3.

---

## WS-62 — Duplicate videos

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M4 | L | WS-42, WS-61 | no | `ws/62-duplicate-videos` |

**Primary files:**
- Engines: `iOSCleanup/Engines/FileScanEngine.swift` (fingerprint in `makeMeasuredVideo`), `iOSCleanup/Engines/VideoInventoryCache.swift` (*new*), `iOSCleanup/Engines/DuplicateVideoCandidatePlanner.swift` (*new*), `iOSCleanup/Engines/DuplicateVideoVerifier.swift` (*new*), `iOSCleanup/Engines/PerceptualHash.swift` (reuse only), `iOSCleanup/Engines/PhotoDuckLocalDataReset.swift` (one target)
- Models: `iOSCleanup/Models/DuplicateVideoGroup.swift` (*new*)
- Home: `iOSCleanup/Views/Home/DuplicateVideoScanController.swift` (*new*), `iOSCleanup/Views/Home/LargeVideoScanController.swift`, `iOSCleanup/Views/Home/ScanOutcomeSummary.swift`, `iOSCleanup/Views/Home/HomeTileLayout.swift`, `iOSCleanup/Views/Home/HomeTileRoute.swift` (WS-55), `iOSCleanup/Views/Home/HomeRouteDestinationView.swift`, `iOSCleanup/Views/Home/HomeViewModelDependencies.swift` (one field), `iOSCleanup/Views/HomeViewModel.swift` (pass-throughs and one reset target)
- Files views: `iOSCleanup/Views/Files/DuplicateVideoReviewView.swift` (*new*)
- Store and utilities: `iOSCleanup/Store/CleanupAccessPolicy.swift`, `iOSCleanup/Utilities/PhotoDuckStorageFootprint.swift` (verify only; see WS-62.1)
- Tests: `iOSCleanupTests/DuplicateVideoCandidatePlannerTests.swift` (*new*), `iOSCleanupTests/DuplicateVideoVerifierTests.swift` (*new*), `iOSCleanupTests/VideoInventoryCacheTests.swift` (*new*), `iOSCleanupTests/DuplicateVideoSelectionTests.swift` (*new*), `iOSCleanupTests/FileScanEngineTests.swift`, `iOSCleanupTests/PhotoDuckLocalDataResetTests.swift` (WS-48), `iOSCleanupTests/PrivacySurfaceTests.swift` (WS-48's footprint tests), `iOSCleanupTests/HomeTileRouteTests.swift` (WS-55), `iOSCleanupTests/CleanupAccessPolicyTests.swift`

**Findings covered:** FSB-07 (P2, confirmed)

**Decisions applied:**
- **D-SCOPE:** duplicate videos by frame-hash verification are M4.
- **D-GATING:** deleting one member is free, more than one is Pro, with the lock before the second selection.
- **D-UNDO:** one `delete(assets:)` call per commit.
- **D-LIMITED-ACCESS:** the inventory is not written under `.limited`.

### Goal
A clip and its re-encoded copy, for example a 4K camera original and a 720p WhatsApp save, appear as one **review-only** group. Both sizes, resolutions and dates are shown, with a "Suggested keep" badge and nothing pre-selected. Bit-identical imports of any size are found too. Different clips of the same length are not grouped. Verification never downloads iCloud originals. Pairs involving an iCloud-only clip are shown only on an exact measured byte match, labeled "Not downloaded".

### Current behavior (verified)
- There is no duplicate-video logic anywhere.
- `FileScanEngine` keeps only qualifying videos: `FileScanPolicy.qualifies(byteSize:)` against `minimumFileSizeBytes = 100 * 1024 * 1024` (`iOSCleanup/Engines/FileScanEngine.swift:88`, `:175-190`, `:261-265`). Every smaller video is measured and then dropped.
- After WS-42:
  - the retention floor is 50 MB plus every screen recording;
  - `VideoInventorySummary` holds totals only;
  - `makeMeasuredVideo` is the per-video seam left for this workstream.

  So a 22 MB WhatsApp copy still has no stored record.
- The average-hash routine is `PhotoScanEngine.swift:1092-1114`. WS-61 moved it to `PerceptualHash`.
- `LargeVideoResultCache` (`FileScanEngine.swift:294-435`) is the persistence pattern. WS-27.1 made it single-flight load, a revision guard and serialized synchronous atomic writes.
- `ROADMAP.md:60` (T2.11) proposes duration + resolution + byte size, which would miss re-encodes.

### Implementation plan

**WS-62.1 — Fingerprints for every measured video, and `VideoInventoryCache`**
- **Change:**
  1. In the WS-42 file `Models/VideoInventory.swift`, next to `VideoInventorySummary`:
     ```swift
     struct VideoFingerprintCandidate: Codable, Equatable, Sendable {
         let assetID: String; let modificationDate: Date?; let creationDate: Date?
         let duration: TimeInterval; let pixelWidth: Int; let pixelHeight: Int
         let byteSize: Int64; let byteSizeIsEstimated: Bool
         let storageLocation: AssetStorageLocation          // WS-30
         let videoKind: VideoKind                           // WS-42
     }
     enum VideoInventoryPolicy { static let maximumFingerprints = 20_000 }   // newest by creationDate
     ```
  2. `FileScanEngine.makeMeasuredVideo` also returns a `VideoFingerprintCandidate` for **every** video, whatever its size. `FileScanResult` gains `fingerprints: [VideoFingerprintCandidate]`, capped at `maximumFingerprints` newest. `FileScanUpdate` is unchanged.
  3. New `iOSCleanup/Engines/VideoInventoryCache.swift`:
     ```swift
     struct VideoFrameSignature: Codable, Equatable, Sendable {
         static let positions: [Double] = [0.1, 0.3, 0.5, 0.7, 0.9]
         let hashes: [UInt64?]            // nil = frame unavailable
         let informative: [Bool]          // luminanceRange >= DuplicateVideoTuning.minimumLuminanceRange
     }
     struct StoredVideoFingerprint: Codable, Equatable, Sendable {
         let fingerprint: VideoFingerprintCandidate
         var signature: VideoFrameSignature?          // valid only for fingerprint.modificationDate
         var signatureOutcome: SignatureOutcome?      // .computed / .notLocal / .unavailable
         var signatureAttemptedAt: Date?
         enum SignatureOutcome: String, Codable, Sendable { case computed, notLocal, unavailable }
     }
     struct CachedVideoInventory: Codable, Equatable, Sendable { static let schemaVersion = 1; let schemaVersion: Int; let savedAt: Date; var items: [StoredVideoFingerprint] }
     actor VideoInventoryCache: LocalDataClearing {
         static let shared = VideoInventoryCache()
         init(directoryURL: URL? = nil)   // (try? PhotoDuckStorage.directory()) / "video-inventory-v1.json" (WS-34; under Application Support/PhotoDuck)
         func load() async -> CachedVideoInventory?                        // single-flight, revision guard (WS-27.1)
         func replaceFingerprints(_ f: [VideoFingerprintCandidate], savedAt: Date) async   // keeps signature when assetID + modificationDate match
         func storeSignatures(_ s: [String: (VideoFrameSignature?, StoredVideoFingerprint.SignatureOutcome)], at: Date) async  // ONE write
         func remove(assetIdentifiers: Set<String>) async                   // ONE write
         nonisolated var localDataClearingName: String { "video_inventory" }
         func clearLocalData() async throws
     }
     ```
     Copy WS-27.1's pattern exactly:
     - `private var revision`;
     - `inFlightLoad`;
     - `commit(_:)` = revision += 1, then assign, then a synchronous `.atomic` write through a `nonisolated static` helper.

     A schema mismatch counts as a miss.
  4. `LargeVideoScanController.run(budget:)`: on a **completed** video pass, only when WS-20's `persistsLibraryDerivedState(status)` is true **and** the pass's captured `generation == passGeneration` (WS-27), `await videoInventoryCache.replaceFingerprints(result.fingerprints, savedAt: now)`, then call `duplicateVideoController.inventoryDidChange()` (WS-62.5). This is the same fence that keeps a pass started before WS-48's Clear (`invalidateAndCancelCurrentPass()`) from writing `large-video-results.json` afterwards (README §9 contract 24). A fenced pass writes nothing. Under `.limited`, hand the fingerprints to the controller in memory only.
  5. **WS-48 reset and footprint (README §9 contract 18):**
     - Add `videoInventoryCache: VideoInventoryCache` to `HomeViewModelDependencies`, with production default `.shared` (contract 16). Tests inject `VideoInventoryCache(directoryURL:)` on a temp directory. `LargeVideoScanController` and `DuplicateVideoScanController` receive it from the dependencies.
     - In `HomeViewModel.clearLocalData()`, add `dependencies.videoInventoryCache` to the `PhotoDuckLocalDataReset(targets:)` list, right after `dependencies.largeVideoCache`.
     - **Footprint:** the file lives under `PhotoDuckStorage.rootURL()` (`Application Support/PhotoDuck`), so `PhotoDuckStorageFootprint.measure` already counts it in `savedDataBytes` ("Scan results & preferences"). No new measurement code is needed. Add a test that proves it (below). At 20,000 fingerprints with signatures the file is several MB (estimate). Record the measured size, and the new Storage & Data total, against WS-54's ≤ 160 MB footprint record in the PR.
- **Edge cases:**
  - Fingerprinting adds no PhotoKit work, because it only reuses what the loop already measured.
  - A modified video (new `modificationDate`) loses its signature.

**WS-62.2 — `DuplicateVideoCandidatePlanner` (pure)**
- **Change:** new file `iOSCleanup/Engines/DuplicateVideoCandidatePlanner.swift`:
  ```swift
  enum DuplicateVideoTuning {
      static let maximumAspectDelta = 0.02            // orientation-normalized (max edge / min edge)
      static let maximumDurationDelta: TimeInterval = 0.35
      static let minimumDuration: TimeInterval = 1.0
      static let maximumBucketSize = 12               // a video pairs with at most 11 neighbors
      static let maximumHammingPerFrame = 6
      static let minimumMatchingInformativeFrames = 3
      static let minimumLuminanceRange = 12
      static let maximumSignaturesPerPass = 300
      static let metadataOnlyMaximumDurationDelta: TimeInterval = 0.05
  }
  struct DuplicateVideoCandidatePair: Hashable, Sendable { let a: String; let b: String }   // a < b
  enum DuplicateVideoCandidatePlanner {
      static func normalizedAspect(width: Int, height: Int) -> Double           // max/min; 0 when either is 0
      static func candidatePairs(_ fingerprints: [VideoFingerprintCandidate]) -> [DuplicateVideoCandidatePair]
  }
  ```
  `candidatePairs`:
  1. Drop durations under 1 s and zero dimensions.
  2. Sort by `(duration, assetID)`.
  3. For each video, sweep forward while `Δduration ≤ 0.35`. Pair with neighbors whose normalized aspect is within 0.02, until the video has 11 partners.
  4. Deduplicate.

  O(n · k).

**WS-62.3 — Frame signatures and `DuplicateVideoVerifier`**
- **Change:** new file `iOSCleanup/Engines/DuplicateVideoVerifier.swift`:
  ```swift
  enum VideoFrameSamplingOutcome: Equatable, Sendable { case signature(VideoFrameSignature), notLocal, unavailable }
  protocol VideoFrameSampling: Sendable {
      func sample(assetID: String) async -> VideoFrameSamplingOutcome
  }
  struct LiveVideoFrameSampler: VideoFrameSampling {
      // fetch PHAsset by ID (PHAsset.fetchAssets(withLocalIdentifiers:options: PhotoLibraryFetch.identifierOptions()), WS-40 lint);
      // PHImageManager.requestAVAsset(.current, isNetworkAccessAllowed = false) via WS-10's PhotoKitRequestState<Value> (5 s);
      // nil + PHImageResultIsInCloudKey == true → .notLocal; other nil → .unavailable;
      // AVAssetImageGenerator: maximumSize 64×64, appliesPreferredTrackTransform = true,
      // requestedTimeToleranceBefore/After = 0.25 s; image(at:) for each position × duration;
      // PerceptualHash.grayPixels8x8 → average64(pixels:) + luminanceRange(pixels:)
  }
  enum DuplicateVideoPairVerdict: Equatable, Sendable { case framesMatch, metadataOnly, rejected, pending }
  enum DuplicateVideoPairEvaluator {
      static func verdict(_ a: StoredVideoFingerprint, _ b: StoredVideoFingerprint) -> DuplicateVideoPairVerdict
  }
  actor DuplicateVideoVerifier {
      init(sampler: any VideoFrameSampling = LiveVideoFrameSampler(), maximumConcurrent: Int = 2)
      /// Computes missing signatures (newest first, ≤ budget) for videos in `pairs`, priority .utility.
      func computeSignatures(for ids: [String], budget: Int) async -> [String: VideoFrameSamplingOutcome]
  }
  ```
  - **`verdict` rules:**
    - Both signatures computed:
      - positions where exactly one side is informative → `rejected`;
      - positions where both are informative: all must be Hamming ≤ 6, and there must be at least 3 → `framesMatch`; otherwise `rejected`.
    - Either side `.notLocal`: `metadataOnly` only if both byte sizes are **measured** (`!byteSizeIsEstimated`), `byteSize` is equal, pixel dimensions are equal and `Δduration ≤ 0.05`. Otherwise `rejected`.
    - Missing signatures (not attempted, or over budget) → `pending`.
    - `.unavailable` on either side → `rejected`, with a retry after 7 days via `signatureAttemptedAt`.
  - The verifier never sets network access and checks `Task.isCancelled` between videos. Signatures are persisted through `storeSignatures` in batches of 32.
- **Edge cases:**
  - Slo-mo is delivered as an `AVComposition` for `.current`. `AVAssetImageGenerator` accepts compositions, so no special case is needed.
  - Uniform frames (black, fades) are uninformative and never count as matches.

**WS-62.4 — Grouping, suggested keep and the selection rule (pure)**
- **Change:** new file `iOSCleanup/Models/DuplicateVideoGroup.swift`:
  ```swift
  struct DuplicateVideoMember: Equatable, Sendable, Identifiable {
      let fingerprint: VideoFingerprintCandidate
      var id: String { fingerprint.assetID }
      var pixelCount: Int64 { Int64(fingerprint.pixelWidth) * Int64(fingerprint.pixelHeight) }
  }
  struct DuplicateVideoGroup: Equatable, Sendable, Identifiable {
      enum Evidence: String, Sendable { case framesMatch, notDownloaded }
      let id: String                     // member IDs sorted and joined with "|"
      let members: [DuplicateVideoMember]   // suggested keep first, then bytes desc, then id
      let suggestedKeepID: String
      let evidence: Evidence
      let reclaimSizing: ReclaimSizing   // members other than suggestedKeep: onDevice → device, iCloudOnly → iCloud, unknown → unknown
  }
  enum DuplicateVideoGrouping {
      static let maximumGroupSize = 12
      static func groups(pairs: [(DuplicateVideoCandidatePair, DuplicateVideoPairVerdict)],
                         fingerprints: [String: VideoFingerprintCandidate]) -> [DuplicateVideoGroup]
      static func suggestedKeep(_ members: [DuplicateVideoMember]) -> String
      // highest pixelCount, then larger measured byteSize (measured beats estimated), then earlier creationDate, then smaller id
  }
  enum DuplicateVideoSelection {
      enum Problem: Equatable { case wholeGroupSelected(groupID: String) }
      static func validate(selected: Set<String>, groups: [DuplicateVideoGroup]) -> Problem?
      /// assetID → a member of the same group that stays (suggested keep if unselected, else the first unselected in member order).
      static func requiredKeeperIDs(selected: Set<String>, groups: [DuplicateVideoGroup]) -> [String: String]
  }
  ```
  - `groups` runs union-find over `framesMatch` and `metadataOnly` pairs only.
    - A component with more than 12 members is dropped (DECISION below).
    - `evidence` is `.notDownloaded` if any edge in the component is `metadataOnly`.
    - Groups are sorted by `reclaimSizing.deviceBytes` descending, then `id`.
- **Edge cases:** a group never pre-selects anything (invariant 8), and a whole group can never be selected (invariant 3's spirit).

**WS-62.5 — `DuplicateVideoScanController` (idle worker) and facade**
- **Change:** new `iOSCleanup/Views/Home/DuplicateVideoScanController.swift`:
  ```swift
  @MainActor final class DuplicateVideoScanController: ObservableObject {
      @Published private(set) var groups: [DuplicateVideoGroup] = []
      @Published private(set) var isVerifying = false
      init(cache: VideoInventoryCache = .shared, verifier: DuplicateVideoVerifier = .init(),
           persistsDerivedState: @escaping () -> Bool, now: @escaping () -> Date = Date.init)
      func inventoryDidChange()                    // recompute groups from stored signatures (pure, no PhotoKit)
      func refresh(canRun: Bool)                   // single-flight: plan → computeSignatures(budget 300) → store → regroup
      func cancel()
      func applyConfirmedDeletion(_ ids: Set<String>)   // drop members; regroup; cache.remove (skipped under .limited)
  }
  ```
  - At launch, `inventoryDidChange()` rebuilds groups from the persisted inventory with no PhotoKit work.
  - Chaining (chapter rule 2): `storageInsightsController.onPassFinished = { [weak self] in self?.duplicateVideoController.refresh(canRun: self?.canMeasure ?? false) }`. Also cancel everywhere WS-30 cancels.
  - `HomeViewModel` pass-throughs: `duplicateVideoGroups`. Forward `applyConfirmedDeletion`. Feed `ScanOutcomeInputs.duplicateVideoGroupCount` and `duplicateVideoSizing` (Σ group `reclaimSizing`).
- **Edge cases:**
  - Under `.limited`: groups exist in memory, and nothing is written.
  - A photo run or video pass starting mid-refresh cancels it. Signatures already computed are persisted in their batch.

**WS-62.6 — UI: tile, route, review view, gating, deletion**
- **Change:**
  1. `CleanupOpportunity.Kind.duplicateVideos`, supplementary (it overlaps Large Videos). Add the `HomeTileLayout` tile: SF Symbol `film.stack`, title "Duplicate videos", `sizeBadge` "≈X", note "You choose what to delete", tone `.accent` (WS-56). Add `HomeRoute.duplicateVideos` (pushed) → `DuplicateVideoReviewView`, and `case .duplicateVideos: return .duplicateVideos` in WS-55's exhaustive `HomeTileRoute.route(for:)`.
  2. `CleanupAccessPolicy`: add `ManualDeleteSurface.duplicateVideos` additively (README §9 contract 11), with its policy test.
  3. New `iOSCleanup/Views/Files/DuplicateVideoReviewView.swift` (functional layout using existing Duck components; no redesign of Files):
     - One section per group, with the header "\(CountText.videos(n)) · could free ≈X".
     - Rows: `PhotoThumbnailView` (WS-14), "3840×2160 · 180 MB · 12 Mar 2024" (`ByteText`, "≈" when estimated), and `StatusBadge(title:tone:)` badges (WS-56): "Suggested keep" (`.success`), "In iCloud" (`.secondary`; `storageLocation == .iCloudOnly`), and "Not downloaded — matched by exact size and length" (`.warning`) for `.notDownloaded` groups.
     - Toggles: nothing is pre-selected. A tap that would select every member of its group is refused, with the inline caption "Keep at least one copy."
     - A second selection for free users follows `.manualDelete(.duplicateVideos, count:)`: the lock shows, and the paywall opens with `resume` re-applying the tap. The caption shows before any selection: "Free: delete one at a time. Pro: delete many at once."
     - The bar reads "Delete N · ≈X". Confirmation dialog: `"Move \(CountText.videos(n)) (≈X) to Recently Deleted?"`, message "≈Y of this is on this iPhone."
     - Resolve the selected IDs to fresh `PHAsset`s off-main (`ResolvedPhotoAssets`, through `PhotoLibraryFetch.identifierOptions()`), then make **one** `deletionManager.delete(assets:requiredKeeperIDs: DuplicateVideoSelection.requiredKeeperIDs(...), knownBytes: measured sizes)` call.
     - `.deleted(receipt)` → deselect `receipt.assetIDs`. WS-21's path removes them from every surface.
     - `.declined` → keep the selection. Errors → the existing alert copy (`DeletionFailureCopy`, WS-11).
- **Edge cases:** WS-11's `.keeperMissing` skip protects the case where the "kept" copy was deleted elsewhere between review and commit.

### Tests
- **`iOSCleanupTests/DuplicateVideoCandidatePlannerTests.swift`:**
  - `testPairsWithinDurationToleranceAndSameAspect`.
  - `testRejectsOneSecondApart`.
  - `testRotated1080x1920MatchesLandscape1920x1080`.
  - `testWhatsAppStyle848x480MatchesFourK`.
  - `testSkipsSubSecondClips`.
  - `testBucketCapHolds`: 40 videos of equal length → each has ≤ 11 partners.
  - `testDeterministicOrder`.
- **`iOSCleanupTests/DuplicateVideoVerifierTests.swift`** (a `FakeFrameSampler` returns scripted outcomes):
  - `testAllInformativeFramesMatchingGroups`.
  - `testOneFrameHammingTwentyRejects`.
  - `testUninformativeFramesDoNotCount`: 2 informative matches → rejected.
  - `testOneSideUninformativeRejects`.
  - `testNotLocalRequiresExactMeasuredBytes`: equal measured bytes → `metadataOnly`; estimated bytes → `rejected`; 1-byte difference → `rejected`.
  - `testSamplerNeverRequestsNetwork`: the fake records the flag.
  - `testBudgetLimitsSignaturesAndLeavesPending`.
  - `testCancellationStopsBetweenVideos`.
- **`iOSCleanupTests/DuplicateVideoSelectionTests.swift`:**
  - `testGroupHasNoPreselection`.
  - `testSuggestedKeepHighestResolutionThenBytes`.
  - `testUnionFindMergesTransitivePairs`.
  - `testOversizedComponentDropped`.
  - `testWholeGroupSelectionRejected`.
  - `testRequiredKeeperIsSuggestedKeepWhenUnselected`.
  - `testReclaimSizingExcludesSuggestedKeep`.
- **`iOSCleanupTests/VideoInventoryCacheTests.swift`:**
  - `testRoundTrip`.
  - `testReplaceKeepsSignatureWhenModificationDateUnchanged`.
  - `testReplaceDropsSignatureWhenModified`.
  - `testConcurrentStoreAndRemoveLeaveDiskEqualToMemory`: WS-27.1's 50-iteration pattern.
  - `testSchemaMismatchIsMiss`.
  - `testClearLocalDataRemovesFile`.
- **`iOSCleanupTests/FileScanEngineTests.swift`:**
  - `testScanFingerprintsEveryVideoIncludingSmallOnes`: 5 MB, 30 MB and 150 MB → 3 fingerprints, retained per WS-42 rules.
  - `testFingerprintCapKeepsNewest`.
- **`DuplicateVideoScanController`** (`@MainActor`, in `VideoInventoryCacheTests` or its own file):
  - `testLimitedAccessNeverWritesInventory`.
  - `testInventoryDidChangeRebuildsWithoutSampling`.
  - `testConfirmedDeletionRemovesMembersAndDissolvesPairs`.
- **`CleanupAccessPolicyTests`:** `testDuplicateVideoSingleFreeMultiPro`.
- **WS-48's tests, extended:**
  - `PhotoDuckLocalDataResetTests.testClearAllEmptiesEveryDerivedStore` seeds a temp `VideoInventoryCache(directoryURL:)` too. After `clearAll()`, its `load() == nil` and the file is gone.
  - `testClearLocalDataIncludesVideoInventory` (`HomeViewModelTests`, WS-07 harness): `clearLocalData()` removes the injected inventory file.
  - `testFootprintCountsVideoInventory` (next to WS-48's `PhotoDuckStorageFootprintTests`): a temp Application Support root holding `video-inventory-v1.json` raises `savedDataBytes` by at least the file's size.
  - `testLargeVideoPassFencedByClearWritesNoInventory` (`LargeVideoScanControllerTests`, modeled on WS-27's `testInvalidatedPassNeverWritesResults`): park the resolver mid-pass, call `invalidateAndCancelCurrentPass()`, then release. The inventory file never reappears.
- **`HomeTileRouteTests`** (WS-55): `.duplicateVideos` maps to the pushed `HomeRoute.duplicateVideos`.
- Device-only: see Device QA.

### Acceptance criteria
- [ ] A clip and its WhatsApp-saved re-encode appear as one review-only group showing both sizes. Different clips of the same length are not grouped (tests plus Device QA 1–2).
- [ ] Nothing is pre-selected, and a whole group can never be selected (tests).
- [ ] No network is used: the fake sampler asserts the flag, and Device QA 3 shows no download indicator.
- [ ] Deletion is one `delete(assets:requiredKeeperIDs:…)` call, and the gate is shown before the second selection.
- [ ] The inventory file is written only under full access and only by an unfenced pass. It is a `PhotoDuckLocalDataReset` target (cleared by Storage & Data) and is counted in `PhotoDuckStorageFootprint`'s `savedDataBytes` (tests).
- [ ] Duplicate-video bytes are not in any combined total (WS-59's supplementary test extended with `.duplicateVideos`).
- [ ] Full suite green, zero warnings. `CLAUDE.md` gains a `VideoInventoryCache` row and the review-only rule.

### Device QA
1. Record a 60 s 4K clip. Send it to yourself on WhatsApp, and save the received video. After the idle pass, the Duplicate videos tile shows one group with both resolutions and sizes, and "Suggested keep" is on the 4K clip.
2. Record two different 10 s clips in the same room. They are not grouped.
3. With Optimize iPhone Storage on, an iCloud-only clip is never downloaded (no spinner, no network in Instruments). It is grouped only if its measured size exactly equals a local copy's.
4. As a free user, select one member (allowed), then a second (lock). As Pro, delete 2 members across 2 groups: one iOS prompt, both in Recently Deleted.

### Pitfalls and out of scope
- Photo and video scans never load PhotoKit concurrently (invariant 16). The verifier is an idle worker that runs after the other workers, never inside the video pass.
- Do not change WS-42's retention floor, thresholds or cache v2. Fingerprints are a separate file.
- Never pre-select and never auto-clean duplicate videos. There is no Keep Best for videos in v1 of this feature.
- Compression and large-video multi-delete are WS-42/WS-43/WS-44.
- **Reconciliation:**
  - `VideoInventoryCache` joins WS-48's `PhotoDuckLocalDataReset` targets through a `HomeViewModelDependencies` field. Its bytes appear in `PhotoDuckStorageFootprint` automatically, because it sits under the Application Support root (README §9 contract 18).
  - Writes are fenced by WS-27's `passGeneration`, which WS-48's Clear bumps through `invalidateAndCancelCurrentPass()` (contract 24).
  - The frame sampler and the deletion resolve IDs through WS-40's `PhotoLibraryFetch.identifierOptions()` (`PhotoFetchLintTests`).
  - `ManualDeleteSurface.duplicateVideos` is additive to WS-36's enum (contract 11).
  - The tile routes through WS-55's `HomeTileRoute`, and strings and badges follow WS-56 (chapter rule 7).
  - WS-54's write-cost work does not cover this file: it is one serialized write per completed pass (WS-27.1 pattern).

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| FSB-07 | confirmed | No duplicate-video code exists. Sub-threshold videos are measured and dropped (FileScanEngine.swift:88, 175-190, 261-265). The hash routine is private at PhotoScanEngine.swift:1092-1114 (moved by WS-61). The plan follows the fix, with these changes: aspect tolerance 0.02 instead of 0.01, because an 848×480 re-encode of 16:9 differs by 0.011; five frame positions with an informative-frame rule instead of three raw frames, because black intros and fades otherwise match any two clips; signatures are cached per video in the inventory file, so re-scans never re-sample; and oversized components are dropped. VALUE-15's metadata-only rule ("bytes within 1%") would false-match iCloud-only clips whose sizes are *estimates* derived from the same duration and resolution, so metadata-only matches require exact, measured byte equality. |

DECISION (owner may override): duplicate-video candidates use a 0.02 aspect tolerance and a 1 s minimum duration, and need at least 3 matching informative frames out of 5. Components larger than 12 videos are not shown. Pairs with an iCloud-only member are shown only on an exact measured byte match.

---

## WS-63 — Similarity sensitivity presets

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M4 | L | WS-08, WS-39 | no | `ws/63-similarity-presets` |

**Primary files:**
- Engines: `iOSCleanup/Engines/SimilaritySensitivity.swift` (*new*), `iOSCleanup/Engines/GroupPairEvidence.swift` (*new*), `iOSCleanup/Engines/SimilarityThresholdProfile.swift` (WS-39; `.strict`), `iOSCleanup/Engines/PhotoScanEngine.swift` (evidence capture in `makeGroups`, about 3 lines), `iOSCleanup/Engines/PhotoAnalysisCache.swift` (`CachedPhotoGroup` field), `iOSCleanup/Engines/PhotoMLBridge.swift` (backfill reads `cachedAssetAnalyses` only)
- Models: `iOSCleanup/Models/PhotoGroup.swift`, `iOSCleanup/Models/PhotoGroup+ReclaimSizing.swift` (pass-through)
- Home: `iOSCleanup/Views/Home/PhotoResultsStore.swift`, `iOSCleanup/Views/Home/SimilarityProfileRevisionNotice.swift` (*new*), `iOSCleanup/Views/HomeViewModel.swift` (pass-throughs), and the WS-37.8 planner call site (`HomeViewModel.swift`, or `iOSCleanup/Views/Home/PhotoScanCoordinator.swift` if WS-49 landed) for one `forceFullRescan` term
- Views: `iOSCleanup/Views/Settings/StorageAndDataView.swift`, `iOSCleanup/Views/Photos/PhotoResultsView.swift`, `iOSCleanup/Views/PhotoDuckShellView.swift` (read the presented groups)
- Tests: `iOSCleanupTests/SimilaritySensitivityPresetTests.swift` (*new*), `iOSCleanupTests/SimilaritySensitivityFilterTests.swift` (*new*), `iOSCleanupTests/PhotoScanEngineEndToEndTests.swift`, `iOSCleanupTests/PhotoResultsStoreTests.swift`, `iOSCleanupTests/HomeViewModelTests.swift`, `iOSCleanupTests/ScalePerformanceTests.swift`

**Findings covered:** FSB-15 (P3, partially: the facts are right, the fix is redesigned)

**Decisions applied:**
- **D-SENSITIVITY:** "Standard" and "Strict" change only review-only thresholds (visual distances and cluster floors), with no Vision work. Any future "Aggressive" preset stays review-only.
- **D-THRESHOLDS:** Standard is exactly today's calibrated profile (WS-39). Strict only *narrows* review-only values, so it needs no destructive evidence.
- Invariants 1, 2 and 22.

### Goal
Settings › Storage & Data has "Similar photo matching: Standard / Strict". Switching takes well under a second on a 10k library, even a 50k one. It makes zero analyzer or Vision calls and zero PhotoKit image loads. It **cannot** change any Keep Best or Auto-clean plan: presets only hide or trim review-only "Similar" groups, and they are recomputed from pair evidence stored with each group. Standard always shows exactly what the scan produced.

### Current behavior (verified)
- Thresholds are `static let` constants in `enum SimilarityThresholds` (`iOSCleanup/Engines/SimilarityPolicyTypes.swift:230-273`). WS-39 makes them an injectable `SimilarityThresholdProfile` with separate `destructive` and `reviewOnly` parts (`.standard` = today's values).
- Required assets are always re-analyzed. Only context reuses cached analyses (`PhotoScanEngine.swift:437-491`). `PhotoMLBridge.cachedAssetAnalyses(for:)` exists (`PhotoMLBridge.swift:151-189`).
- **Review-only thresholds do affect destructive outcomes if clustering is re-run.** `SimilarityCandidateGraph.formClusters` (`SimilarityPolicyServices.swift:690-782`) runs complete-link over *all* eligible edges, near-duplicate and visual. Say a near-duplicate pair (A,B) gains C through visual edges: {A,B,C} is classified `.visuallySimilar`, review-only (`:485-498`). Tighten the visual distance so C's edges fail, and {A,B} becomes `.nearDuplicate`, a Keep Best candidate. Re-running clustering with Strict therefore **creates** destructive plans, which violates D-SENSITIVITY.
- After WS-46 the warm cache holds analyses for only the 10,000 newest photos (`PhotoEmbeddingCachePolicy.capacity`). On a 50k library, "regroup from cached analyses" cannot cover 40k photos without Vision, and treating them as unanalyzed would report 40k failures (invariant 11 would force "incomplete" copy).
- `CachedPhotoGroup` (`PhotoAnalysisCache.swift:332-452`) has synthesized `Codable`: an added optional field decodes old snapshots and, when nil, is omitted on encode.
- The WS-48 marker `// WS-63: "Similar photo matching" section goes here` is in `StorageAndDataView`.

### Implementation plan

**WS-63.1 — `SimilarityThresholdProfile.strict` and the preset enum**
- **Change:** new file `iOSCleanup/Engines/SimilaritySensitivity.swift`:
  ```swift
  enum SimilaritySensitivityPreset: String, CaseIterable, Identifiable, Sendable {
      case standard, strict
      static let storageKey = "photoduck.similarity-sensitivity"
      var id: Self { self }
      var title: String { self == .standard ? "Standard" : "Strict" }
      var profile: SimilarityThresholdProfile { self == .standard ? .standard : .strict }
  }
  extension SimilarityThresholdProfile {
      /// Review-only narrowing ONLY. Destructive values and scoring are copied from .standard, never edited here.
      static let strict: SimilarityThresholdProfile = {
          var p = SimilarityThresholdProfile.standard
          p.reviewOnly.maxVisualSimilarFeatureDistance = 0.12      // standard 0.18
          p.reviewOnly.maxExtendedVisualFeatureDistance = 0.06     // standard 0.08
          p.reviewOnly.visualClusterFloor = 0.32                   // standard 0.25
          p.reviewOnly.visualReviewClusterFloor = 0.24             // standard 0.18
          return p
      }()
  }
  ```
  If WS-39.4 changed Standard's review-only values, keep Strict's distances at 2/3 of Standard's and its floors at Standard + 0.06–0.07, and record the numbers in the PR. `DECISION (owner may override): Strict = visual distance 0.12 / 0.06 and cluster floors 0.32 / 0.24.`
- **Edge cases:** the windows (`visualSessionWindowSeconds`, `extendedVisualSessionWindowSeconds`) and `timeGapVisualScoreFloor` are review-only too, but stay equal to Standard to keep the preset explainable.

**WS-63.2 — `GroupPairEvidence`: store what the filter needs**
- **Why:** Evaluating a group under Strict needs its member pair distances. Embeddings are gone for most of a large library, but the distances were computed at scan time.
- **Change:** new file `iOSCleanup/Engines/GroupPairEvidence.swift`:
  ```swift
  struct GroupPairEvidence: Codable, Equatable, Sendable {
      static let maximumMembers = 40
      let memberIDs: [String]
      let distances: [Float?]              // upper triangle over memberIDs, row-major; nil = no visual evidence
      static func make(memberIDs: [String], signals: [SimilarityPairKey: SimilaritySignals]) -> GroupPairEvidence?   // nil when > maximumMembers
      func distance(_ a: String, _ b: String) -> Double?
      func restricted(to ids: Set<String>) -> GroupPairEvidence?   // nil when < 2 members remain
  }
  ```
  - `PhotoGroup`:
    - Add a stored `let pairEvidence: GroupPairEvidence?` and an init parameter `pairEvidence: GroupPairEvidence? = nil`.
    - `init` stores `reason == .visuallySimilar ? pairEvidence?.restricted(to: assetIDs) : nil`. Nothing else in `init` changes.
    - Update every rebuild site so it passes `pairEvidence: group.pairEvidence`, exactly as each already passes WS-40's `autoCleanPolicy`: grep `PhotoGroup(`. The sites include WS-30's `replacingReclaimSizing`, WS-12's `applyingUserKeptIDs`, WS-21's `PhotoResultPruner`, `CachedPhotoGroup.makeGroup` and the engine. Extend WS-30's `testReplacingReclaimSizingPreservesEveryOtherField` (and the equivalent pass-through tests for the other sites) to cover `pairEvidence`.
  - `CachedPhotoGroup`: `let pairEvidence: GroupPairEvidence?`, mapped in both directions. There is no schema bump, and WS-16's golden tests stay byte-identical, because their fixtures have no evidence.
  - `PhotoScanEngine.makeGroups`, where it builds each `PhotoGroup` (`:1384`): pass `pairEvidence: reason == .visuallySimilar ? GroupPairEvidence.make(memberIDs:, signals: pairSignals) : nil`. That is the only engine edit.
- **Edge cases:**
  - Snapshot growth: about 400 B per similar group. At 3,000 groups that is about 1.2 MB. Record the before and after snapshot size at the WS-08 60k benchmark in the PR. Extend WS-54's `testSnapshotEncodingAt150kFitsUnderCap` so 3,000 of its groups are `.visuallySimilar` with 8-member evidence. The encoded size must stay under the 64 MB cap. Report the growth of both snapshot copies against WS-54's ≤ 160 MB footprint record (README §9 contract 5).
  - Evidence is review-only data. It never feeds a destructive decision.

**WS-63.3 — `SimilaritySensitivityFilter` (pure)**
- **Change:** in `SimilaritySensitivity.swift`:
  ```swift
  enum SimilaritySensitivityFilter {
      enum Outcome: Equatable { case unchanged, trimmed(keeping: [String]), hidden, notEvaluable }
      /// Standard → groups unchanged. Strict → only .visuallySimilar groups are evaluated; every other group is returned
      /// as the IDENTICAL value (same id, keeper, deleteCandidateIDs, action).
      static func apply(_ preset: SimilaritySensitivityPreset, to groups: [PhotoGroup],
                        backfilledEvidence: [UUID: GroupPairEvidence] = [:]) -> (groups: [PhotoGroup], notEvaluableCount: Int)
      static func evaluate(_ group: PhotoGroup, evidence: GroupPairEvidence, profile: SimilarityThresholdProfile) -> Outcome
  }
  ```
  - **`evaluate`:**
    - Descriptors come from `SimilaritySignalBuilder.descriptor(for:)` over `group.assets` (metadata only).
    - Signals are `SimilaritySignals.make(lhs:rhs:featureDistance: evidence.distance(…))`.
    - Loop while at least 2 members remain:
      1. `let r = ConservativeSimilarityClusterClassifier(pairClassifier: ConservativePairSimilarityClassifier(profile: profile)).classifyCluster(input, keeperResult: .reviewOnlyPlaceholder)`. `reviewOnlyPlaceholder` is a static `KeeperRankingResult` with a nil keeper and empty maps, added in this file. Only `.bucket` is read.
      2. If `r.bucket != .notSimilar`, return `.unchanged` when no member was removed, else `.trimmed`.
      3. Otherwise remove the member with the most ineligible pairs under the profile. Break ties by the lowest mean pair score, then the larger ID.
    - Fewer than 2 members left → `.hidden`.
  - **`apply`:**
    - `.unchanged` → the same value.
    - `.trimmed` → a rebuild through `PhotoGroup.init` (invariant 1) with:
      - `id: group.id`;
      - the remaining `assets` in the original order;
      - `reason: .visuallySimilar` and `recommendedAction: .reviewManually`;
      - `keeperAssetID` = the original keeper if it remains, else nil;
      - `deleteCandidateIDs: []`;
      - the other fields copied, including WS-40's `autoCleanPolicy`;
      - `groupReasonsSummary + ["Strict matching removed \(n) photos"]`;
      - `captureDateRange: nil`;
      - candidates filtered by the remaining IDs;
      - `pairEvidence` restricted;
      - WS-30's `reclaimSizing: nil`.
    - `.hidden` → dropped.
    - No evidence and no backfill → returned unchanged and counted in `notEvaluableCount`.
    - A trimmed subset stays `.visuallySimilar` **even if its remaining pairs are all near-duplicates**: Strict never creates a Keep Best plan.
- **Edge cases:** the filter makes no async calls and does no PhotoKit image work. Group count × at most 780 pair evaluations per group is milliseconds. Still, run it in `Task.detached(priority: .userInitiated)` from the store once there are more than 500 similar groups.

**WS-63.4 — Presentation in `PhotoResultsStore`, the preset setting and the evidence backfill**
- **Change:**
  1. `PhotoResultsStore` keeps `photoGroups` as the **unfiltered source of truth**. Merge, prune, user-kept filtering, snapshot building, WS-30 sizing, Auto-clean and Duck Mode keep reading it, so this workstream does not change them. Add:
     ```swift
     @Published private(set) var presentedPhotoGroups: [PhotoGroup] = []          // filter(photoGroups)
     private(set) var presentedVisuallySimilarGroups: [PhotoGroup] = []
     @Published private(set) var sensitivityPreset: SimilaritySensitivityPreset = .standard
     @Published private(set) var isApplyingSensitivity = false
     private(set) var notEvaluableSimilarGroupCount = 0
     func setSensitivityPreset(_ p: SimilaritySensitivityPreset)
     ```
     - Recompute the presented arrays after every write to `photoGroups` and every preset change, with a generation counter so a stale detached result is discarded.
     - `.standard` → `presentedPhotoGroups = photoGroups`, with no work.
  2. **UI readers of review-only groups** switch to the presented arrays:
     - `PhotoResultsView`'s `groups` input at both presenters (the Home results sheet and the Similar tab);
     - the Home "Similar" tile count (`visuallySimilarPhotoGroups` becomes the presented one);
     - `SimilarPhotosDashboardView`;
     - `ScanOutcomeInputs.visuallySimilarGroupCount`.

     Nothing else changes. Add a code comment at `photoGroups`: "Persistence and destructive paths read photoGroups; UI reads presentedPhotoGroups (WS-63)."
  3. `HomeViewModel` (forwarding only):
     - `@Published var similaritySensitivity: SimilaritySensitivityPreset`, read from `dependencies.defaults` at init (unknown value → `.standard`);
     - `func setSimilaritySensitivity(_:)` writes the defaults and calls the store.
  4. **Backfill (legacy snapshots without evidence):** `GroupPairEvidenceBackfill` in `GroupPairEvidence.swift`:
     ```swift
     enum GroupPairEvidenceBackfill {
         static let chunkSize = 512
         static func fill(groups: [PhotoGroup],
                          loadEmbeddings: @Sendable ([PHAsset]) async -> [String: Data]) async -> [UUID: GroupPairEvidence]
     }
     ```
     - It runs only when the preset is Strict, for `.visuallySimilar` groups with no `pairEvidence`.
     - It loads embeddings through `dependencies.mlBridge.cachedAssetAnalyses(for:)` in 512-asset chunks and computes `PhotoEmbeddingValueDistance.normalizedDistance`.
     - A group missing any member embedding gets no evidence.
     - The result is held in the store, in memory, and passed to `apply`. It is **not** persisted and **not** written into `photoGroups`.
     - It never runs during a photo run (`isPhotoRunActive`). It reruns after the next completion barrier if still needed.
- **Edge cases:**
  - WS-12 hides user-kept groups before the filter. The filter never re-adds anything.
  - A group ID shown under Strict is the same UUID as under Standard, so hidden and deferred state keyed by UUID keeps working.

**WS-63.5 — Settings UI**
- **Change:** in `StorageAndDataView`, replace the WS-48 marker with a `DuckCard` section:
  - Title "Similar photo matching". A segmented `Picker` bound to `viewModel.similaritySensitivity` (Standard / Strict).
  - Caption: "Strict shows fewer, closer matches under Similar. It never changes Keep Best or Auto-clean."
  - A `ProgressView` while `isApplyingSensitivity`.
  - When `notEvaluableSimilarGroupCount > 0` under Strict: "\(CountText.groups(n)) found before this update can't use Strict until the next full scan (menu › Scan Again)."
  - Use `duck*` fonts and tokens. No redesign.

**WS-63.6 — Threshold-revision rollout and notice (README §9 contract 13)**
- **Why:** there is no engine `regroup(thresholds:)` over saved snapshots, in WS-39 or here. After WS-46 only the newest 10k photos have cached analyses, and re-clustering could create destructive plans. A post-release change to `SimilarityThresholdProfile.standard` (a `revision` bump) therefore takes effect on the **next user-initiated full re-analysis**, mirroring WS-37's `analyzerVersion` rollout. Automatic scans stay incremental. The user must be told, instead of silently keeping old groups.
- **Change:** new `iOSCleanup/Views/Home/SimilarityProfileRevisionNotice.swift`:
  ```swift
  struct SimilarityProfileRevisionStore {           // key "photoduck.similarity.grouped-profile-revision"
      init(defaults: UserDefaults)
      func recordCompletedFullScan(revision: Int)   // called after the completion barrier of a full (non-incremental) run
      func shouldShowNotice(current: Int) -> Bool   // stored < current and not dismissed for `current`; nil stored → write current, false
      /// WS-37's rule, applied to the threshold revision: true only when isUserInitiated && stored != nil && stored < current.
      func requiresFullReanalysis(current: Int, isUserInitiated: Bool) -> Bool
      func dismiss(current: Int)
  }
  ```
  - **Planner call site** (WS-37.8's line, in `HomeViewModel` or WS-49's `PhotoScanCoordinator`): `forceFullRescan: existing || AnalyzerUpgradePolicy.requiresFullReanalysis(…) || revisionStore.requiresFullReanalysis(current: SimilarityThresholdProfile.standard.revision, isUserInitiated: origin == .userInitiated)`. The user/automatic distinction is WS-26's `ScanOrigin`.
  - A dismissible Home `DuckCard`: "PhotoDuck's photo matching was improved. Scan again to update your groups." Its button calls `viewModel.refreshPhotoScan()`, WS-26's canonical user-initiated entry point (the same call WS-31/WS-45 use for "Scan again"; `requestsBackgroundContinuation` keeps its default). Because the scan is user-initiated, the rule above upgrades it to a full re-analysis. Never start a scan automatically.
  - Add one line in `HomeView`.
- **Edge cases:**
  - The first launch after this workstream records the current revision silently, so neither the notice nor a forced full pass happens then.
  - Incremental runs never update the stored revision.
  - WS-26's confirmed gear rescan (`startPhotoScan(from: .gearRescanConfirmed)`) is already full and also records the revision.

### Tests
- **`iOSCleanupTests/SimilaritySensitivityPresetTests.swift`:**
  - `testPresetsNeverChangeDestructiveThresholds`: `SimilarityThresholdProfile.strict.destructive == .standard.destructive`, and `scoring` is equal.
  - `testStrictOnlyNarrowsReviewOnlyValues`: every Strict distance ≤ Standard, and every floor ≥ Standard.
  - `testStandardPresetIsStandardProfile`.
  - `testUnknownStoredPresetFallsBackToStandard`.
- **`iOSCleanupTests/SimilaritySensitivityFilterTests.swift`** (built with WS-08's `ConfigurablePhotoScanTestAsset` and hand-made evidence):
  - `testStandardReturnsIdenticalArray`.
  - `testStrictHidesFifteenHundredthsGroup`: a 2-member group at distance 0.15.
  - `testStrictKeepsTightGroupUnchangedValue`: 0.05 → the same `id`, member IDs, `keeperAssetID`, `deleteCandidateIDs`, `recommendedAction`, `reason` and `groupReasonsSummary`. `PhotoGroup` is not `Equatable`, so compare fields, as WS-30's `testReplacingReclaimSizingPreservesEveryOtherField` does.
  - `testStrictTrimsOutlierDeterministically`: 4 members, one at 0.16 from the others → 3 remain, same `id`, reason `.visuallySimilar`, `deleteCandidateIDs.isEmpty`.
  - `testTrimmedNearDuplicateSubsetStaysReviewOnly`: the remaining pair is at 0.02 → still `.visuallySimilar`, `!isAutoCleanEligible`.
  - `testNonSimilarGroupsPassThroughByValue`: a near-duplicate Keep Best group has the same `id`, member IDs, `keeperAssetID`, `deleteCandidateIDs`, `recommendedAction` and `isAutoCleanEligible` before and after.
  - `testGroupsWithoutEvidenceCountedNotEvaluable`.
  - `testBackfillComputesEvidenceFromCachedEmbeddingsOnly`: the stub loader is the only data source; the analyzer counter stays 0.
  - `testBackfillSkipsGroupsMissingAnyEmbedding`.
- **`iOSCleanupTests/PhotoScanEngineEndToEndTests.swift`:**
  - `testPresetsNeverChangeDestructivePlansEndToEnd`: one scan produces a 0.02 near-duplicate Keep Best pair, a 0.15 visually similar pair and the mixed A,B,C case. Assert:
    - Strict hides the 0.15 group;
    - the Keep Best group, and the list of `isAutoCleanEligible` groups, are equal under both presets;
    - no Strict output group is `isAutoCleanEligible` unless it was under Standard.
  - `testPresetSwitchMakesZeroAnalyzerCalls`: a counting analyzer. Record the count after the scan, apply Strict then Standard 10 times, and the count is unchanged.
  - `testEngineStoresEvidenceOnlyOnVisuallySimilarGroups`.
- **`iOSCleanupTests/PhotoResultsStoreTests.swift`:**
  - `testPresentedGroupsFollowPresetButSnapshotInputsUnfiltered`: under Strict, `photoGroups` still contains the hidden group, and `AnalysisSnapshotBuilder.build` from the store's inputs contains it.
  - `testStaleFilterResultDiscarded`.
  - `testCachedGroupRoundTripsEvidenceAndLegacyDecodes`.
- **`AnalysisSnapshotBuilderTests`** (WS-16): the golden tests must pass **unchanged**.
- **`SimilarityProfileRevisionNoticeTests`** (in `SimilaritySensitivityPresetTests.swift`): first run records silently; a lower stored revision shows the notice; dismissal holds until the next revision; incremental runs never record; `requiresFullReanalysis` is true only for a user-initiated scan with a lower stored revision, and false for automatic scans and for a nil stored value.
- **`HomeViewModelTests`** (WS-07 harness): `testThresholdRevisionMakesNextUserScanFullButNotAutomatic`. Seed a stored revision below `standard.revision` and a completed snapshot. An automatic scan plans incrementally, a user-initiated scan plans a full pass, and afterwards the stored revision equals the current one.
- **Performance** (Performance plan): `testStrictFilterScalesTo3000SimilarGroups`, growth ratio < 6 (D-PERF-GATE). Put it in `ScalePerformanceTests`, the only class `Performance.xctestplan` selects (WS-06).

### Acceptance criteria
- [ ] Switching presets on a 10k-photo fixture records under 1 s in the Performance plan (advisory under D-PERF-GATE; the growth ratio is the gate), with zero analyzer calls (tests).
- [ ] Destructive thresholds are identical across presets, and no Keep Best or Auto-clean plan differs between presets (`testPresetsNeverChangeDestructivePlansEndToEnd`).
- [ ] Every rebuild goes through `PhotoGroup.init`. Trimmed groups are always `.visuallySimilar` with empty delete IDs.
- [ ] Snapshots persist unfiltered groups. Old snapshots decode. WS-16's golden tests are unchanged.
- [ ] The Storage & Data section exists, the choice persists across relaunch, and the revision notice works as specified. A threshold revision makes the next user-initiated scan a full re-analysis while automatic scans stay incremental (`testThresholdRevisionMakesNextUserScanFullButNotAutomatic`).
- [ ] Full suite green, zero warnings. `CLAUDE.md` similarity section: "Presets filter review-only groups from stored pair evidence; they never re-cluster."

### Device QA
1. On the owner's library, note the Similar count under Standard. Switch to Strict: the count drops within a second and no progress stalls. Keep Best groups and the Auto-clean count are unchanged. Switch back and the count is restored.
2. After upgrading from a pre-WS-63 build, Strict shows the "can't use Strict until the next full scan" note if any old groups lack cached embeddings. After "Scan Again" the note disappears.

### Pitfalls and out of scope
- **Never** re-run `formClusters` with a preset profile. That is the path that turns review-only changes into destructive ones.
- Never persist the filtered list, and never let a destructive surface read `presentedPhotoGroups`.
- An "Aggressive" preset is not built. If it ever is, it must stay review-only and would need re-clustering, which is out of scope.
- Changing Standard's values is WS-39 only (D-THRESHOLDS).
- **Reconciliation:**
  - This workstream does **not** build `regroup(thresholds:)` (README §9 contract 13). WS-39 does not promise it either. A threshold revision reaches users through WS-63.6's rule, which mirrors WS-37's `analyzerVersion` rollout: the next user-initiated scan is a full re-analysis, and automatic scans stay incremental.
  - The notice button uses WS-26's internal `refreshPhotoScan(requestsBackgroundContinuation:)`; `restartPhotoScan` no longer exists, and `rescanEntireLibrary()` is private, reachable only through `startPhotoScan(from: .gearRescanConfirmed)` (contract 1).
  - The preset type names are WS-39's (`SimilarityThresholdProfile`); the test file is `SimilaritySensitivityPresetTests.swift`, not `SimilarityThresholdSetTests`.
  - The snapshot growth from `pairEvidence` is checked against WS-54's 64 MB cap and the ≤ 160 MB footprint (contract 5).
  - `pairEvidence` passes through every `PhotoGroup` rebuild site the same way WS-40's `autoCleanPolicy` does: WS-12's `applyingUserKeptIDs`, WS-21's `PhotoResultPruner`, WS-30's `replacingReclaimSizing` and `CachedPhotoGroup.makeGroup`.

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| FSB-15 | partially | Facts confirmed: static constants (SimilarityPolicyTypes.swift:230-273), required assets always re-analyzed (PhotoScanEngine.swift:437-491), and `cachedAssetAnalyses` exists (PhotoMLBridge.swift:151-189). WS-39 already delivers the injectable profile under the name `SimilarityThresholdProfile`, not `SimilarityThresholdSet`, and this plan uses WS-39's name. The proposed `regroup(thresholds:)` is **rejected**, for two reasons. (1) Complete-link clustering over mixed edges (SimilarityPolicyServices.swift:690-782) means a stricter visual threshold can turn a review-only {A,B,C} into a destructive {A,B}, violating D-SENSITIVITY. (2) After WS-46 only the newest 10k photos have cached analyses, so a 50k regroup would need Vision or would report tens of thousands of "unanalyzed" photos. The plan instead stores per-group pair evidence and filters review-only groups by value. A threshold revision takes effect on the next user-initiated full re-analysis, mirroring WS-37's `analyzerVersion` rollout, and a notice tells the user (README §9 contract 13). |

DECISION (owner may override): presets are a review-only filter over the scan's Standard results. Pre-WS-63 groups that can't be evaluated stay visible under Strict until the next full scan.
DECISION (owner may override): when `SimilarityThresholdProfile.standard.revision` increases, Home shows a dismissible "Scan again to update your groups" card, and the next user-initiated scan is a full re-analysis (as for WS-37's `analyzerVersion`). There is no automatic rescan, and automatic scans stay incremental.

---

## WS-64 — Retention and growth loop

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M4 | L | WS-32, WS-45, WS-58 | no | `ws/64a-monthly-recap`, then `ws/64b-widget-intents-reminder` |

**Primary files:**
- **PR 64a:**
  - `iOSCleanup/Engines/CleanupStats.swift` (WS-32; monthly buckets). The bundle lists `DeletionManager.swift`, but WS-32 moved the stats out of it.
  - `iOSCleanup/Views/Home/ThisMonthCard.swift` (*new*), `iOSCleanup/Views/Home/ThisMonthSummary.swift` (*new*), `iOSCleanup/Views/Home/CleanupRecapCard.swift` (*new*)
  - `iOSCleanup/Views/Photos/SwipeModeViewModel.swift` and `iOSCleanup/Views/Photos/SwipeQueueBuilder.swift` (`.combined` source)
  - `iOSCleanup/Views/HomeView.swift` (one line)
  - Tests: `iOSCleanupTests/CleanupStatsStoreTests.swift`, `iOSCleanupTests/ThisMonthSummaryTests.swift` (*new*), `iOSCleanupTests/SwipeQueueBuilderTests.swift`
- **PR 64b:**
  - `iOSCleanup/Utilities/WidgetSnapshot.swift` (*new*, compiled into **both** targets), `iOSCleanup/Views/Home/WidgetSnapshotPublisher.swift` (*new*)
  - `PhotoDuckWidgets/ReviewableCountWidget.swift` (*new*), `PhotoDuckWidgets/PhotoDuckWidgetsBundle.swift`
  - `iOSCleanup/iOSCleanup.entitlements` (*new*), `PhotoDuckWidgets/PhotoDuckWidgets.entitlements` (*new*)
  - `iOSCleanup/Intents/OpenScreenshotReviewIntent.swift` (*new*), `iOSCleanup/iOSCleanupApp.swift` (router singleton)
  - `iOSCleanup/Views/Home/MonthlyReminderScheduler.swift` (*new*), `iOSCleanup/Views/HomeViewModel.swift` (pass-throughs)
  - `iOSCleanup.xcodeproj/project.pbxproj`
  - Tests: `iOSCleanupTests/WidgetSnapshotTests.swift` (*new*), `iOSCleanupTests/MonthlyReminderSchedulerTests.swift` (*new*), `iOSCleanupTests/OpenScreenshotReviewIntentTests.swift` (*new*)

**Findings covered:** FSB-14 (P3, confirmed; item 1, the review prompt, is WS-58's)

**Decisions applied:**
- **D-GROWTH:** the M4 items are monthly stats, the "This month" card, the recap share card, the widget with an App Group, App Intents and the monthly notification. The review prompt is WS-58's (WS-58.6, shipped only if the owner accepted D-GROWTH). It must not be duplicated or retriggered here, and if WS-58.6 was skipped, this workstream still adds none.
- **D-UNDO** / WS-32: copy says "moved to Recently Deleted", never "freed".
- Invariant 26: the notification delegate stays in `App.init`, and foreground presentation stays suppressed.

**Split rule:** ship 64a (WS-64.1–64.3) first. 64b (WS-64.4–64.7) follows once the owner has provisioned the App Group. Each PR stays under about 1,500 lines.

### Goal
- Home shows a "June" card: how many things captured this month are waiting for review, and what was moved to Recently Deleted this month. Its button opens Duck Mode limited to this month.
- A recap image ("412 photos and videos cleaned up · ≈3.2 GB moved to Recently Deleted") can be shared. It contains no photos and no identifiers.
- A home-screen widget (small and circular) shows the count to review and this month's result. It updates after scans and deletions.
- "Clean my screenshots in PhotoDuck" opens Screenshots review from Siri, Spotlight or Shortcuts.
- An opt-in reminder arrives on the 1st of each month.

### Current behavior (verified)
- `iOSCleanup/Engines/DeletionManager.swift:17-20`: `CleanupStats { lifetimeBytesFreed; lifetimeItemsFreed }`. `recordConfirmedDeletion` (`:38-53`) updates lifetime totals only. WS-32 moves it to `CleanupStats.swift` with a decodeIfPresent decoder, a 30-day ledger and a comment reserving room for WS-64's monthly buckets.
- `PhotoDuckWidgets/PhotoDuckWidgetsBundle.swift:4-8` bundles only `ExportLiveActivityWidget`, which uses literal colors because widgets don't share the app's asset catalog (`ExportLiveActivityWidget.swift:6-9`). `ExportActivityAttributes.swift` is compiled into both targets (`project.pbxproj:13,16`), which is the pattern for shared files.
- No `.entitlements` files exist. The widget bundle ID is `com.photoduck.app.PhotoDuckWidgets` and the app is `com.photoduck.app` (`project.pbxproj:779,854`).
- `grep -rn "AppIntent\|AppShortcutsProvider\|ShareLink\|ImageRenderer\|WidgetCenter\|UNCalendarNotificationTrigger" iOSCleanup PhotoDuckWidgets` finds nothing. The only share sheet is the diagnostics `UIActivityViewController` (`HomeView.swift:37-60`).
- `iOSCleanup/iOSCleanupApp.swift:9-14`: `private let notificationRouter = CleanupNotificationRouter()`, and the delegate is set in `init`. WS-31 made `Target = CleanupReviewTarget` (with `.reviewScreenshots`), added `consumePendingTarget()`, and `PhotoDuckShellView` handles targets on `.onAppear` and `.onChange` (cold launch included).
- `SwipeModeViewModel.swift:317-331` builds month headers (`"MMMM yyyy"`). WS-41 added `SwipeQueueSource` and `SwipeQueueBuilder`.
- Runtime baseline: the build has one benign "appintents" metadata warning because no AppIntents are linked. It disappears once an intent exists.

### Implementation plan

**WS-64.1 — Monthly buckets in `CleanupStats` (PR 64a)**
- **Change** (`Engines/CleanupStats.swift`):
  ```swift
  struct MonthlyCleanupStats: Codable, Equatable, Sendable {
      var bytes: Int64 = 0; var items: Int = 0; var compressionSavedBytes: Int64 = 0
      init() {}; init(from decoder: Decoder) throws        // decodeIfPresent for every key
  }
  enum CleanupMonthKey {
      static func key(for date: Date, calendar: Calendar) -> String          // String(format: "%04d-%02d", y, m)
      static func title(for key: String, calendar: Calendar, locale: Locale) -> String   // "June"; "June 2025" if not the current year
  }
  // CleanupStats gains:
  static let maximumMonthlyBuckets = 24
  var monthly: [String: MonthlyCleanupStats] = [:]         // decodeIfPresent ?? [:] in WS-32's custom decoder
  mutating func recordMonthly(bytes: Int64, items: Int, compressionSaved: Int64, at: Date, calendar: Calendar)  // then trims to 24 by smallest key
  ```
  - `CleanupStatsStore(defaults:now:calendar: Calendar = .current)`:
    - `recordConfirmedDeletion(bytes:itemCount:)` also calls `recordMonthly(bytes:items:0…)`;
    - WS-32's canonical `recordCompressionSavings(originalBytes:outputBytes:)` (README §9 contract 6) also adds the net `max(originalBytes − outputBytes, 0)` to the month's `compressionSavedBytes`. It does not add to the month's `bytes` or `items`: the original's bytes go only to WS-32's `.compressionOriginal` ledger entry, as today. There is no `recordCompressionSavings(bytes:)` variant;
    - `recordExternalReclaim(bytes:itemCount:)` does not touch the monthly buckets;
    - WS-60's `.bytesOnly` path records items 0;
    - `.none` records nothing.

    All of this runs only after PhotoKit confirms (invariant 9).
  - `DeletionManager` publishes `cleanupStats` already (WS-32), so no API change is needed.

**WS-64.2 — `ThisMonthSummary`, `ThisMonthCard` and a month-scoped Duck Mode (PR 64a)**
- **Change:**
  1. New `Views/Home/ThisMonthSummary.swift` (pure):
     ```swift
     struct ThisMonthSummary: Equatable {
         let monthKey: String; let monthTitle: String
         let reviewableCount: Int          // eligible-group delete candidates + screenshots + blurry whose creationDate is in this month
         let cleanedItems: Int; let cleanedBytes: Int64
         var isEmpty: Bool { reviewableCount == 0 && cleanedItems == 0 && cleanedBytes == 0 }
         static func make(now: Date, calendar: Calendar, groups: [PhotoGroup], screenshots: [PHAsset],
                          blurry: [PHAsset], stats: CleanupStats) -> ThisMonthSummary
         static func monthInterval(now: Date, calendar: Calendar) -> DateInterval
     }
     ```
     Group candidates are resolved **by ID** from `group.assets` (never by position). Only `isAutoCleanEligible` groups count. Inputs come from the store, which WS-12 already filtered for user-kept IDs.
  2. `SwipeQueueSource` gains `case combined([SwipeQueueSource])`. `SwipeQueueBuilder` builds each part, merges the asset entries in `(creationDate, localIdentifier)` order, rebuilds month headers, keeps each entry's `groupID` (nil for categories) and applies `excludedIDs` once. The queue rules of the parts are unchanged: only eligible delete candidates, never keepers.
  3. New `Views/Home/ThisMonthCard.swift`, a `DuckCard` inserted in `HomeView` after WS-60's card (one line):
     - "\(monthTitle) cleanup" and "\(CountText.items(reviewableCount, "item", "items")) to review from this month". Use "Nothing new to review this month" when 0.
     - When `cleanedItems + cleanedBytes > 0`: "This month: \(CountText.items(cleanedItems, "item", "items")) cleaned up · ≈\(ByteText.stat(cleanedBytes)) moved to Recently Deleted".
     - Button "Review \(monthTitle)" (hidden when 0) presents `SwipeModeView(source: .combined([.groups(monthGroups), .assets(monthScreenshots, category: .screenshot), .assets(monthBlurry, category: .blurry)]))` via `.fullScreenCover`. Duck Mode commits stay free (D-GATING).
     - "Share recap" (WS-64.3) when the month has cleanups.
     - "Remind me each month" (WS-64.7, PR 64b; hidden in 64a).
     - Hide the whole card when `isEmpty` and there is no completed scan.
- **Edge cases:**
  - Month boundaries use `Calendar.current` and the device time zone. The summary is recomputed on `.active` (so a new month rolls over) and whenever the groups or stats change.
  - The card is not shown during the first scan (`heroState` `.deepCleanActive` with no completed scan).

**WS-64.3 — `CleanupRecapCard` and sharing (PR 64a)**
- **Change:** new `Views/Home/CleanupRecapCard.swift`:
  ```swift
  struct CleanupRecapModel: Equatable {
      let title: String            // "June with PhotoDuck"
      let itemsLine: String        // "412 photos and videos cleaned up": CountText.items(n, "photo or video", "photos and videos") + " cleaned up"
      let bytesLine: String?       // "≈3.2 GB moved to Recently Deleted"
      let footer: String           // "On-device · No account · No subscription"
      static func make(monthKey: String, stats: CleanupStats, calendar: Calendar, locale: Locale) -> CleanupRecapModel?   // nil when the month is empty
  }
  struct CleanupRecapCard: View { let model: CleanupRecapModel }   // fixed 360×450 pt, PhotoDuckMascotArt(size: 120), duck fonts, tokens
  @MainActor enum CleanupRecapRenderer { static func render(_ model: CleanupRecapModel, scale: CGFloat) -> UIImage? }  // ImageRenderer(content:), scale 3
  ```
  - `ThisMonthCard` renders lazily (`.task(id: model)`) and shows `ShareLink(item: Image(uiImage: image), preview: SharePreview(model.title, image: Image(uiImage: image)))`.
  - The card contains **no photo thumbnails, filenames, dates of photos or identifiers**. It shows only month-level counts.
- **Edge cases:**
  - PhotoDuck cannot observe Recently Deleted being emptied, so the copy always says "moved to Recently Deleted" and never "freed".
  - The render runs on the main actor, once per model change.

**WS-64.4 — App Group, `WidgetSnapshot` and the publisher (PR 64b)**
- **Owner step (blocking for device QA, not for CI):** register `group.com.photoduck.app` in the Apple Developer portal, and enable it for `com.photoduck.app` and `com.photoduck.app.PhotoDuckWidgets`.
- **Change:**
  1. New entitlements files, both containing:
     ```xml
     <key>com.apple.security.application-groups</key>
     <array><string>group.com.photoduck.app</string></array>
     ```
     Set `CODE_SIGN_ENTITLEMENTS` for both targets in Debug and Release.
  2. New `iOSCleanup/Utilities/WidgetSnapshot.swift`, added to **both** targets' Sources (the same way as `ExportActivityAttributes.swift`). Foundation only, no Photos:
     ```swift
     enum WidgetKinds { static let reviewableCount = "ReviewableCountWidget" }
     struct WidgetSnapshot: Codable, Equatable, Sendable {
         static let schemaVersion = 1
         static let appGroupIdentifier = "group.com.photoduck.app"
         static let fileName = "widget-snapshot-v1.json"
         var schemaVersion = WidgetSnapshot.schemaVersion
         var hasCompletedScan: Bool
         var reviewableCount: Int              // Σ itemCount of non-review-only, non-supplementary opportunities
         var reviewableDeviceBytes: Int64      // Σ sizing.deviceBytes of the same
         var monthKey: String; var monthCleanedItems: Int; var monthCleanedBytes: Int64
         var updatedAt: Date
         func hasSameContent(as other: WidgetSnapshot) -> Bool   // ignores updatedAt
     }
     enum WidgetSnapshotStore {
         static func containerURL(fileManager: FileManager = .default) -> URL?   // nil when the entitlement is absent (CI, unsigned sim)
         static func write(_ s: WidgetSnapshot, to directory: URL) throws        // atomic
         static func read(from directory: URL) -> WidgetSnapshot?                // nil on missing, corrupt or schema mismatch
     }
     ```
     In the app target only, add `extension WidgetSnapshot { static func make(outcome: ScanOutcomeSummary, hasCompletedScan: Bool, stats: CleanupStats, now: Date, calendar: Calendar) -> WidgetSnapshot }`.
  3. New `Views/Home/WidgetSnapshotPublisher.swift`:
     ```swift
     @MainActor final class WidgetSnapshotPublisher {
         init(directory: @escaping () -> URL? = { WidgetSnapshotStore.containerURL() },
              reload: @escaping () -> Void = { WidgetCenter.shared.reloadTimelines(ofKind: WidgetKinds.reviewableCount) })
         func publish(_ s: WidgetSnapshot)   // skip if hasSameContent(last); write in Task.detached(.utility); then reload on main
     }
     ```
     `HomeViewModel` calls `publish(.make(...))` in four places:
     - after a photo run's completion barrier is published (do not move the barrier; invariant 13);
     - after a video pass completes;
     - in `applyConfirmedDeletion(assetIDs:)`;
     - on `.background`.
- **Edge cases:**
  - A nil container means a no-op (CI and unsigned simulator builds).
  - The snapshot contains no asset IDs (privacy, invariant 26 spirit).
  - No new required-reason API: this is a plain file write and read with no timestamps and no `UserDefaults(suiteName:)`. `PrivacyManifestLintTests` stay green.

**WS-64.5 — `ReviewableCountWidget` (PR 64b)**
- **Change:** new `PhotoDuckWidgets/ReviewableCountWidget.swift`:
  ```swift
  struct ReviewableCountEntry: TimelineEntry { let date: Date; let snapshot: WidgetSnapshot? }
  struct ReviewableCountProvider: TimelineProvider {
      // placeholder: sample snapshot; getSnapshot/getTimeline: read from the App Group container;
      // Timeline(entries: [entry], policy: .after(now + 6 h))
  }
  struct ReviewableCountWidget: Widget {
      var body: some WidgetConfiguration {
          StaticConfiguration(kind: WidgetKinds.reviewableCount, provider: ReviewableCountProvider()) { ReviewableCountWidgetView(entry: $0) }
              .configurationDisplayName("To review").description("What PhotoDuck found for you to review.")
              .supportedFamilies([.systemSmall, .accessoryCircular])
      }
  }
  ```
  - **`systemSmall`:**
    - "PhotoDuck" caption;
    - a large `reviewableCount` with "to review";
    - "≈\(bytes) on this iPhone" when > 0;
    - "\(month): \(n) cleaned up" when > 0;
    - "Open PhotoDuck to scan" when `snapshot == nil || !hasCompletedScan`;
    - "Updated \(relative)" when `updatedAt` is older than 7 days.
  - **`accessoryCircular`:** the count and "review", using `AccessoryWidgetBackground()`.
  - Use `.containerBackground(for: .widget) { … }`, which iOS 17 requires. If the owner kept iOS 16 under D-MIN-OS, wrap it in `#available(iOSApplicationExtension 17.0, *)`.
  - Colors are literal, like `ExportLiveActivityWidget`. Fonts are system fonts, since the widget target has no duck fonts. Every text gets an accessibility label.
  - Tapping opens the app (Home). There is no widget URL scheme (DECISION below).
  - Add `ReviewableCountWidget()` to `PhotoDuckWidgetsBundle.body`. Keep `ExportLiveActivityWidget` in the bundle unchanged, including its use of WS-57's shared `PhotoDuckExportActivityAttributes.ContentState` presentation extension (`title(isStale:)`, `detailLine(isStale:)`, `compactTrailing(isStale:)`, `symbolName(isStale:)`, and the `.interrupted` phase). Do not fork those helpers back into the widget.

**WS-64.6 — App Intent and App Shortcut (PR 64b)**
- **Change:**
  1. `iOSCleanupApp.swift`: add `static let shared = CleanupNotificationRouter()` to `CleanupNotificationRouter` and use it for the delegate and the environment object. Delegate installation stays in `init` (invariant 26). Add `@MainActor func route(to target: CleanupReviewTarget) { pendingTarget = target }`.
  2. New `iOSCleanup/Intents/OpenScreenshotReviewIntent.swift`:
     ```swift
     import AppIntents
     struct OpenScreenshotReviewIntent: AppIntent {
         static var title: LocalizedStringResource { "Review Screenshots" }
         static var description: IntentDescription { IntentDescription("Opens screenshot review in PhotoDuck.") }
         static var openAppWhenRun: Bool { true }
         @MainActor func perform() async throws -> some IntentResult {
             CleanupNotificationRouter.shared.route(to: .reviewScreenshots)
             return .result()
         }
     }
     struct PhotoDuckShortcuts: AppShortcutsProvider {
         static var appShortcuts: [AppShortcut] {
             AppShortcut(intent: OpenScreenshotReviewIntent(),
                         phrases: ["Clean my screenshots in \(.applicationName)", "Review screenshots in \(.applicationName)"],
                         shortTitle: "Review Screenshots", systemImageName: "camera.viewfinder")
         }
     }
     ```
     Use computed statics, not stored `static var`s, so strict concurrency reports no global mutable state. Routing reuses WS-31's `NotificationTargetRouting.destination(.reviewScreenshots)`, which gives the Home tab plus `HomeRoute.screenshots`, including cold launch and onboarding: the target waits in the router until the shell appears.
- **Edge cases:**
  - Without Photos permission, the Screenshots route shows its existing permission or empty state. The intent never requests permission (invariant 20).
  - The AppIntents metadata step must produce no warnings: the phrases must contain `.applicationName`.

**WS-64.7 — Opt-in monthly reminder (PR 64b)**
- **Change:** new `Views/Home/MonthlyReminderScheduler.swift`:
  ```swift
  enum MonthlyReminderPolicy {
      static let identifier = "photoduck.monthly-reminder"
      static let enabledKey = "photoduck.monthly-reminder.enabled"      // default false
      static func nextFireComponents(after now: Date, calendar: Calendar) -> DateComponents   // 1st of next month, 10:00 local
      static func content(for s: WidgetSnapshot) -> (title: String, body: String)
      // "A new month in PhotoDuck" / "\(n) to review. Nothing is deleted without your OK." (n > 0)
      //                              "See what's new in your library." (n == 0)
  }
  protocol MonthlyReminderCenter: Sendable {
      func authorizationStatus() async -> UNAuthorizationStatus
      func schedule(identifier: String, title: String, body: String, at: DateComponents, userInfo: [String: String]) async throws
      func removePending(identifier: String) async
  }
  @MainActor final class MonthlyReminderScheduler {
      init(center: any MonthlyReminderCenter = SystemMonthlyReminderCenter(), defaults: UserDefaults, now: @escaping () -> Date = Date.init, calendar: Calendar = .current)
      var isEnabled: Bool { get }
      func setEnabled(_ on: Bool) async
      func reschedule(snapshot: WidgetSnapshot) async   // enabled && authorized → replace pending; else remove
  }
  ```
  - The trigger is `UNCalendarNotificationTrigger(dateMatching:repeats: false)`, rescheduled on `.active` and after each published widget snapshot, so the text uses current counts. `userInfo = ["cleanupTarget": CleanupReviewTarget.home.rawValue]`.
  - **Opt-in:** in `ThisMonthCard`, "Remind me each month" first shows a `.confirmationDialog`:
    - title "Get one reminder at the start of each month?";
    - buttons "Continue" and "Not Now" (WS-48's primer wording).
  - After "Continue": `await viewModel.requestCompletionNotifications()` (WS-15), then `setEnabled(true)` only if authorized.
  - If the permission is denied, show the caption "Notifications are off for PhotoDuck in Settings."
  - No prompt ever appears without the user tapping the control.
- **Edge cases:**
  - Disabling removes the pending request.
  - December rolls over to January of the next year.
  - Foreground delivery stays suppressed (invariant 26).

### Tests
- **`iOSCleanupTests/CleanupStatsStoreTests.swift`** (extends WS-32's file):
  - `testMonthlyBucketsAccumulateByMonth`: injected `now`/`calendar` across two months.
  - `testLegacyJSONWithoutMonthlyDecodes`: WS-32 v1 JSON and WS-32 ledger JSON.
  - `testTwentyFourMonthCapDropsOldest`.
  - `testCompressionSavingsGoToCompressionField`.
  - `testZeroItemBytesOnlyDeletion`.
  - `testDeclinedDeletionRecordsNothing`: through `DeletionManager` with WS-03's fake deleter.
- **`iOSCleanupTests/ThisMonthSummaryTests.swift`:**
  - `testCountsOnlyThisMonthsCandidatesScreenshotsBlurry`.
  - `testResolvesGroupCandidatesByIDNotPosition`: shuffled assets.
  - `testReviewOnlyGroupsNotCounted`.
  - `testMonthRolloverUsesCalendar`.
  - `testRecapModelNilForEmptyMonth`.
  - `testRecapCopyIsHonest`: every recap string contains no "freed", "free up" or "saved space", and the bytes line contains "Recently Deleted".
  - `testRecapContainsNoIdentifiers`: the model's strings contain none of the input asset IDs.
- **`iOSCleanupTests/SwipeQueueBuilderTests.swift`:**
  - `testCombinedSourceMergesChronologicallyWithMonthHeaders`.
  - `testCombinedSourceNeverQueuesKeepers`.
  - `testCombinedAppliesExcludedIDsOnce`.
- **`iOSCleanupTests/WidgetSnapshotTests.swift`:**
  - `testCodableRoundTrip`.
  - `testMakeExcludesReviewOnlyAndSupplementary`.
  - `testStoreReadReturnsNilForMissingCorruptOrOtherSchema` (temp directory).
  - `@MainActor testPublisherSkipsIdenticalContentAndReloadsAfterWrite`.
  - `testPublisherNoOpWithoutContainer`.
- **`iOSCleanupTests/MonthlyReminderSchedulerTests.swift`** (fake center):
  - `testNextFireIsFirstOfNextMonthAtTen`.
  - `testDecemberRollsToJanuary`.
  - `testDisabledRemovesPending`.
  - `testNotAuthorizedSchedulesNothing`.
  - `testRescheduleReplacesWithCurrentCounts`.
  - `testDefaultIsDisabled`.
- **`iOSCleanupTests/OpenScreenshotReviewIntentTests.swift`:**
  - `@MainActor testPerformRoutesToScreenshots`: `try await OpenScreenshotReviewIntent().perform()`, then `CleanupNotificationRouter.shared.consumePendingTarget() == .reviewScreenshots`.
  - `testRouterSharedInstanceIsNotificationDelegate` (checked in App init code via a source lint, or asserting identity where testable).
- Widget rendering and Siri are device-only (below). The widget provider's read path is covered by `WidgetSnapshotStore` tests.

### Acceptance criteria
- [ ] **64a:**
  - Monthly buckets accumulate only on confirmed deletions, and old stats JSON decodes (tests).
  - The "This month" card counts this month's items and opens a month-only Duck Mode (tests plus Device QA 1).
  - The recap image shares via the system sheet with honest copy and no photos (tests plus Device QA 2).
- [ ] **64b:**
  - Both targets carry the App Group entitlement.
  - The widget shows the count and updates within a minute after a scan or deletion (Device QA 3).
  - "Clean my screenshots in PhotoDuck" opens Screenshots review from a cold start (Device QA 4).
  - The monthly reminder is opt-in, preceded by the primer, and delivered on the 1st (Device QA 5).
- [ ] The build has zero warnings, including the AppIntents metadata step. The earlier "appintents" warning is gone.
- [ ] The review prompt is not triggered or duplicated by any code in this workstream: `grep -rln "requestReview" iOSCleanup` lists only WS-58's `iOSCleanup/Views/Home/ReviewPromptModifier.swift`, or nothing if WS-58.6 was skipped.
- [ ] `ExportLiveActivityWidget` still builds from WS-57's shared presentation extension, and WS-57's `ExportLiveActivityTests` pass unchanged.
- [ ] `CLAUDE.md` gains an App Group / widget / intents section, including the owner provisioning step.

### Device QA
1. With groups and screenshots from this month, tap "Review June". Duck Mode shows only this month's items. Commit, and the card's "cleaned up" line updates.
2. Share the recap to Messages. The image shows only counts, the mascot and the footer.
3. Add the small and circular widgets. Run a scan, then delete 5 photos. Within a minute both widgets change. With the App Group missing (fresh simulator), the app runs normally and the widget shows "Open PhotoDuck to scan".
4. From a killed app, say "Clean my screenshots in PhotoDuck". The Screenshots review opens after onboarding and permission.
5. Enable "Remind me each month" and set the device date to the last day of the month at 23:59. At 10:00 on the 1st a notification appears. Tapping it opens Home.

### Pitfalls and out of scope
- Never say "freed" for Recently Deleted bytes (WS-32). Never include thumbnails or IDs in the recap or the widget.
- Keep the notification delegate in `App.init`, and never present in the foreground (invariant 26).
- Do not add a URL scheme or deep link. The widget tap opens the app.
- The review prompt belongs to WS-58. Streaks, a lock-screen gauge and Spotlight indexing of photos are out of scope (add them to `BACKLOG.md` if wanted).
- Do not redesign Duck Mode (invariant 29). The month filter is a queue-source change only.
- **Reconciliation:**
  - Stats live in `iOSCleanup/Engines/CleanupStats.swift`, where WS-32 moved them; `DeletionManager.swift` is not edited for stats (README §9 contract 28).
  - Compression feeds monthly buckets only through `recordCompressionSavings(originalBytes:outputBytes:)` (contract 6).
  - The review prompt is WS-58's `ReviewPromptModifier`. This workstream relies on it and adds none.
  - WS-57's `.interrupted` phase and shared Live Activity presentation stay intact in the widget bundle.
  - If WS-49 landed, the "after a photo run's completion barrier" publish point is reached through the coordinator's `runDidEnd(.completed)` host callback. The barrier itself does not move (invariant 13).
  - New strings follow WS-56 (`CountText`; chapter rule 7).

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| FSB-14 | confirmed | `CleanupStats` holds lifetime totals only (DeletionManager.swift:17-20, 38-53). The only widget is `ExportLiveActivityWidget` (PhotoDuckWidgetsBundle.swift:4-8). There are no entitlements files, no AppIntent, ShareLink, ImageRenderer or WidgetCenter, and the only share sheet is for diagnostics (HomeView.swift:37-60). Month headers exist (SwipeModeViewModel.swift:317-331). Item 1 (the review prompt) is WS-58 per D-GROWTH. Plan differences: monthly buckets hold bytes, items and compression savings (no "reviewed" count, which nothing records honestly). The widget reads a JSON file in the App Group container instead of `UserDefaults(suiteName:)`, which avoids a new required-reason declaration. Routing reuses WS-31's router as a shared instance. The reminder is non-repeating and rescheduled, so its counts are current. |

DECISION (owner may override): the monthly reminder is off by default, fires once on the 1st at 10:00 local, and is enabled only from the "This month" card after the primer.
DECISION (owner may override): the widget has no deep link. Tapping it opens Home.
DECISION (owner may override): the widget's "to review" count adds duplicate groups, screenshots, blurry photos, large videos and screen recordings, so it mixes groups and items.
