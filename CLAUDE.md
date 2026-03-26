# iOSCleanup — Claude Code memory

## What this is
iOS app: phone storage cleaner. On-device only, no server, no third-party SDKs.
App name in UI: **PhotoDuck**. Bundle: `com.yourname.iOSCleanup`. iOS 16.0 minimum. No external packages.

---

## Phase 1 scope (complete)
Three headless scan engines + unit tests.
- `PhotoScanEngine`: Vision VNFeaturePrintObservation, union-find clustering
- `ContactScanEngine`: CNContactStore, phone normalization, Levenshtein name match
- `FileScanEngine`: FileManager + PHAsset video enumeration

### Key constraints (never violate)
- Swift strict concurrency — all engines are actors
- iOS 16.0 minimum; no external packages
- All paid gates check `PurchaseManager.isPurchased` from `.environmentObject`
- `Notification.Name.purchaseDidSucceed` posted on successful purchase → dismisses PaywallView
- Phase 1 engine files must not be modified (only Models/ may be extended)

---

## Current state — all built & shipped

### Engines

| Engine | File | Returns | Event enum / cases |
|--------|------|---------|-------------------|
| `PhotoScanEngine` | `Engines/PhotoScanEngine.swift` | `AsyncStream<Result<[PhotoGroup], Error>>` | Result wrapper (no enum) |
| `DuplicateHashEngine` | `Engines/DuplicateHashEngine.swift` | `AsyncThrowingStream<DuplicateScanEvent, Error>` | `.progress(completed:total:)`, `.duplicatesFound([PhotoGroup])` |
| `SimilarityEngine` | `Engines/SimilarityEngine.swift` | `AsyncThrowingStream<SimilarityEvent, Error>` | `.progress(completed:total:)`, `.groupsFound([PhotoGroup])` |
| `BlurScanEngine` | `Engines/BlurScanEngine.swift` | `AsyncThrowingStream<BlurScanEvent, Error>` | `.progress(completed:total:)`, `.blurryPhotosFound([PHAsset])` |
| `FileScanEngine` | `Engines/FileScanEngine.swift` | `async throws -> [LargeFile]` | No stream — direct return |
| `VideoCompressionEngine` | `Engines/VideoCompressionEngine.swift` | `AsyncStream<CompressionEvent, Never>` | `.progress(Double)`, `.success`, `.failure(Error)` |
| `ScreenshotScanEngine` | `Engines/ScreenshotScanEngine.swift` | `AsyncThrowingStream<ScreenshotScanEvent, Error>` | `.screenshotsFound([PHAsset])` |
| `LargePhotoScanEngine` | `Engines/LargePhotoScanEngine.swift` | `AsyncThrowingStream<LargePhotoScanEvent, Error>` | `.progress(completed:total:)`, `.photosFound([LargePhotoItem])` |
| `ContactScanEngine` | `Engines/ContactScanEngine.swift` | (Phase 1) | — |
| `EventRollScanEngine` | `Engines/EventRollScanEngine.swift` | `AsyncThrowingStream<EventRollScanEvent, Error>` | `.progress(completed:total:)`, `.rollsFound([EventRoll])` |
| `VideoDuplicateEngine` | `Engines/VideoDuplicateEngine.swift` | `AsyncThrowingStream<VideoDuplicateEvent, Error>` | `.progress(completed:total:)`, `.groupsFound([VideoGroup])` |
| `ScreenshotTagEngine` | `Engines/ScreenshotTagEngine.swift` | `AsyncThrowingStream<ScreenshotTagEvent, Error>` | `.progress(completed:total:)`, `.tagsFound([PHAsset: ScreenshotTag])` |
| `BackgroundScanScheduler` | `Engines/BackgroundScanScheduler.swift` | BGProcessingTask scheduler (no stream) | — |
| `BackgroundScanCacheWriter` | `Engines/BackgroundScanCacheWriter.swift` | Background scan + cache writer actor (no stream) | — |
| `MLModelUpdater` | `Engines/MLModelUpdater.swift` | `actor MLModelUpdater` with `.shared` singleton. Runs `MLUpdateTask` to fine-tune `PhotoQualityClassifier` on the user's kept-asset images. Requires 50+ decisions with `featureVector`. Writes `PhotoQualityClassifier_personalized.mlmodelc` to Application Support. Posts `"mlModelDidUpdate"` notification on success. No stream — direct `async` call. | — |

⚠️ `PhotoScanEngine` uniquely uses `AsyncStream<Result<…>>` not `AsyncThrowingStream`. All new engines use `AsyncThrowingStream`.

### Models

**`PhotoGroup`** (`Models/PhotoGroup.swift`):
```swift
struct PhotoGroup: Identifiable, @unchecked Sendable {
    let id: UUID
    let assets: [PHAsset]   // assets[0] = best quality
    let similarity: Float
    let reason: SimilarityReason

    enum SimilarityReason: Sendable {
        case nearDuplicate    // PhotoScanEngine: distance < 0.05
        case exactDuplicate   // DuplicateHashEngine: same dHash
        case visuallySimilar  // SimilarityEngine: distance < 0.5
        case burstShot        // PhotoScanEngine: burstIdentifier match
    }
}
```

**`ScanProgress`** (`Models/PhotoGroup.swift`):
```swift
struct ScanProgress: Sendable {
    let phase: String
    let completed: Int
    let total: Int
    var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }
    // ⚠️ NO startedAt / updatedAt fields
}
```

**`LargeFile`** (`Models/LargeFile.swift`):
```swift
struct LargeFile: Identifiable, @unchecked Sendable {
    let id: UUID
    let source: Source      // .photoLibrary(asset: PHAsset) | .filesystem(url: URL)
    let displayName: String
    let byteSize: Int64
    let creationDate: Date?
    var formattedSize: String

    enum Source: @unchecked Sendable {
        case photoLibrary(asset: PHAsset)
        case filesystem(url: URL)
    }
}
```

**`LargePhotoItem`** (`Models/LargePhotoItem.swift`):
```swift
struct LargePhotoItem: Identifiable, @unchecked Sendable {
    let id: UUID
    let asset: PHAsset
    let byteSize: Int64
    var formattedSize: String
}
```

**`ScanError`** (defined in `PhotoScanEngine.swift`, used by all engines):
```swift
enum ScanError: Error { case permissionDenied }
```

**`EventRoll`** (`Models/EventRoll.swift`):
```swift
struct EventRoll: Identifiable, Sendable {
    let id: UUID
    let assets: [PHAsset]          // sorted by creationDate ascending
    let startDate: Date
    let endDate: Date
    let locationName: String?      // reverse-geocoded display name, nil if no GPS
    let approximateLocation: CLLocationCoordinate2D?
    var duration: TimeInterval { endDate.timeIntervalSince(startDate) }
    var photoCount: Int { assets.count }
}
```

**`VideoGroup`** (`Models/VideoGroup.swift`):
```swift
struct VideoGroup: Identifiable, @unchecked Sendable {
    let id: UUID
    let assets: [PHAsset]    // assets[0] = largest/best quality, rest are duplicates
    let totalBytes: Int64    // sum of all assets' file sizes
    let reason: VideoGroupReason
}
enum VideoGroupReason: Sendable {
    case nearDuplicate   // similar keyframes, likely same video recorded twice
    case exactDuplicate  // identical first-frame hash
}
```

**`UserDecision`** (`Store/UserDecisionStore.swift`):
```swift
struct UserDecision: Codable, Sendable {
    let id: UUID
    let recordedAt: Date
    let keptAssetID: String
    let deletedAssetIDs: [String]         // pairwise signal
    let groupID: UUID
    let similarityReason: String          // stable string key matching SimilarityReason.cacheKey
    let keptLabels: [String]
    let deletedLabels: [[String]]
    let keptQualityScore: Float
    let deletedQualityScores: [Float]
    let featureVector: [Float]?           // kept asset's VNFeaturePrintObservation flattened (nil = old record)
    let deletedFeatureVectors: [[Float]]? // parallel to deletedAssetIDs
}
// actor UserDecisionStore with .shared singleton, ring buffer (max 500),
// stored at Application Support/userDecisions.json
```

### Views

| View | File | Role |
|------|------|------|
| `HomeView` | `Views/HomeView.swift` | 6-card grid, scan button, storage stats. Dark theme. PhotoDuck logo PNG in header (replaces plain text). Gear icon → `SettingsView` sheet. Category chips show live photo counts during scan. Storage stat cards (Used, Free, Total Cleaned) in individual rounded squares — "Junk" label removed/renamed. Doughnut ring smaller; storage chip slightly smaller. |
| `HomeViewModel` | `Views/HomeViewModel.swift` | `@MainActor ObservableObject`. All scan functions. `ScanState` enum (conforms to `Equatable`). UUID-guard stale-write prevention. Persistent `totalCleanedBytes` via `@AppStorage`. Scan result caching via `UserDefaults`. `PHFetchOptions` uses `includeAllBursts: true` for accurate photo counts. **Category card navigation**: if results cached → navigate immediately; if not → trigger scan + auto-navigate on completion. |
| `OnboardingView` | `Views/OnboardingView.swift` | 2-step TabView pager, PHPhotoLibrary + CNContactStore permissions |
| `PaywallView` | `Views/PaywallView.swift` | Sheet, StoreKit 2, posts `.purchaseDidSucceed` + `.didFreeBytes` notifications |
| `SettingsView` | `Views/SettingsView.swift` | Sheet, dark theme. Premium status card, Restore Purchase, Privacy Policy. Dev section (only visible when `AppConfig.unlockPremium == true`): shows "Premium Override ON" badge + Reset Onboarding button. App version + name info. |
| `PhotoResultsView` | `Views/Photos/PhotoResultsView.swift` | 2-col `LazyVGrid`, filter pills (dynamic), bulk select (paid). Takes `title: String` + pre-filtered `groups`. "Review All" button launches `GroupReviewView`. Floating delete bar shows queued count; "Delete All" is paid gate. Passes `$reviewVM.markedIDs` binding to `PhotoGroupDetailView`. |
| `PhotoGroupDetailView` | `Views/Photos/PhotoGroupDetailView.swift` | Side-by-side compare, "Keep Best, Queue Others" marks all except best (free), "Mark Selected" writes to `@Binding markedIDs` (paid), fullscreen preview. No longer calls `PHPhotoLibrary.performChanges` directly. |
| `GroupReviewView` | `Views/Photos/GroupReviewView.swift` | Full-screen dark bulk review flow. Horizontal photo strip per group; auto-marks all non-best photos red on load. Tap cell → change best; green **"↩ Keep"** Capsule pill (top-right) → unqueue individual photo (replaces old red ✕ circle — less scary). Red **"QUEUED"** Capsule badge (bottom-left, `clock.badge.xmark` icon) labels marked photos. Hint text updated: "Tap to change best · Keep to unqueue". "Queue N for Delete" advances to next group and commits pending marks. "Skip" advances without queuing. Running tally bar shows total queued across reviewed groups. Cache banner on relaunch (continue / start fresh). Summary screen with single bulk delete (paid). ML quality labels shown on each photo cell. |
| `GroupReviewViewModel` | `Views/Photos/GroupReviewViewModel.swift` | `@MainActor ObservableObject`. `queue: [PhotoGroup]`, `currentIndex`, `markedIDs` (persisted to UserDefaults via `didSet`). `bestIDForCurrentGroup`, `pendingMarked` per-group state. `selectBest(_:)` → re-auto-marks others. `togglePendingMark(_:)` → cannot unmark the best. `queueAndAdvance()` commits pending + steps. `skipGroup()` steps without queuing. `commitDeletes()` → single `PHPhotoLibrary.performChanges`. `hasCachedSession` for crash recovery. `startFresh()` clears cache. `buildDecisions()` extracts `VNFeaturePrintObservation` vectors + quality scores before deletion and records `UserDecision` entries in `UserDecisionStore.shared`. |
| `BlurResultsView` | `Views/Photos/BlurResultsView.swift` | 3-col grid, progressive loading (60/page), self-loading cells, bulk delete (paid) |
| `ScreenshotsResultsView` | `Views/Photos/ScreenshotsResultsView.swift` | 3-col grid, 9:19.5 aspect ratio, progressive loading, bulk delete (paid). Fixed blurry rendering (use `.zero` deliveryMode, exact pixel-size requests). Fixed overlapping photo rendering — cells sized correctly with no z-index conflicts. **Updated**: `ScreenshotTagEngine` filter pills + tag badge overlay per cell (CaseIterable `ScreenshotTag` enum, icon-only `.ultraThinMaterial` Capsule bottom-left). Age-bucketed sections ("Safe to Delete" / "Recent"). |
| `RecentlyDeletedView` | `Views/Photos/RecentlyDeletedView.swift` | 3-col grid showing photos in the iOS Recently Deleted album (`PHAssetCollectionSubtype.smartAlbumDeletedAssets`). Hero card with item count + bytes to free. "Empty Trash" (bulk, free) with confirmation dialog. Long-press context menu → "Delete Permanently" (individual, free). Self-loading `RDCell` with video duration badge. |
| `LargePhotosResultsView` | `Views/Photos/LargePhotosResultsView.swift` | List of large photos sorted by size, individual delete (free), shows file size per asset |
| `ContactResultsView` | `Views/Contacts/ContactResultsView.swift` | List grouped by MatchConfidence |
| `ContactMergePreviewView` | `Views/Contacts/ContactMergePreviewView.swift` | Two-column diff, green/red fields, merge (paid) |
| `FileResultsView` | `Views/Files/FileResultsView.swift` | List, tap-to-expand row, Delete (free) + Compress (paid). Dark theme. `deletedIDs` optimistic local deletion. |
| `VideoCompressionView` | `Views/Files/VideoCompressionView.swift` | Preset picker, estimated sizes, progress bar, success banner |
| `SmartPicksResultsView` | `Views/Photos/SmartPicksResultsView.swift` | 3-col grid of low-quality photos sorted by quality score (ascending). Color-coded quality score badge per cell: red (<0.2), orange (<0.35), gold otherwise. Individual delete free; bulk delete paid. Yellow/gold accent theme. `PhotoQualityAnalyzer.shared.qualityScore(for:)` loaded per cell after thumbnail. |
| `EventRollResultsView` | `Views/Photos/EventRollResultsView.swift` | List of event rolls with 3-photo thumbnail strip, location name, same-day vs multi-day date range text. `optional-binding navigationDestination` pushes `RollDetailView`. Cross-level `@Binding deletedAssetIDs` propagated parent → detail for optimistic deletion. Bulk delete in detail paid. |
| `VideoGroupResultsView` | `Views/Photos/VideoGroupResultsView.swift` | Accordion expandable group rows (`expandedGroupID: UUID?`). `VideoThumbnailCell` with m:ss duration badge and per-size cache key. "Keep Largest, Delete Rest" action (`assets.dropFirst()`). Two-level optimistic deletion (`deletedAssetIDs` + `deletedGroupIDs`; hide group when < 2 remain). `Keep`/`Delete` conditional Capsule badge (idx == 0 = keep candidate). |
| `TrashSummarySheet` | `Views/Components/TrashSummarySheet.swift` | Post-delete "You freed X MB" sheet. Presented via `.onReceive(.didFreeBytes)` from HomeView. Dark theme, green checkmark, ByteCountFormatter. Presented with `presentationDetents([.medium])`. |

### HomeViewModel — key scan wiring

`scanPhotos()` runs **PhotoScanEngine + DuplicateHashEngine + SimilarityEngine in parallel** via `withTaskGroup(of: Void.self)`. Results deduplicated by `PhotoGroupCollector` (private actor, keyed by `Set<String>` of asset identifiers). Post-processes to strip `exactDuplicate` asset IDs from `visuallySimilar` groups.

`scanBlur()`, `scanFiles()`, `scanScreenshots()` each run their engine independently. All use a per-scan `UUID` stale-write guard.

`scanEventRolls()` runs `EventRollScanEngine` independently; results stored in `eventRolls: [EventRoll]`.

`scanVideoDuplicates()` runs `VideoDuplicateEngine` independently; results stored in `videoGroups: [VideoGroup]`. Not included in `fullRescan()` — triggered standalone (video processing is too slow for the default scan bundle).

`scanContacts()` runs `ContactScanEngine`; results stored in `contactMatches`. Wired into HomeView's contact card.

`computeSmartPicks()` post-processes `blurPhotos` + non-best assets from `photoGroups` — deduplicates by localIdentifier, sorts ascending by `PhotoQualityAnalyzer` score, keeps top 200. Stored in `smartPicks: [PHAsset]`.

`fetchStorageBreakdown()` — called in `init()` — populates `photoLibraryBytes`, `videoLibraryBytes`, and drives the segmented storage donut in HomeView. Uses `PHAsset.fetchAssets` with media-type predicates + `PHAssetResource` KVC `fileSize` for locally-stored bytes. **Enumeration runs in `Task.detached(priority: .utility)`** to avoid blocking the main thread on large libraries. `fetchMetadataCategories()` and `refreshTotalLibraryCount()` similarly moved off main thread.

**NavDest enum** has expanded to 13+ cases including `.smartPicks`, `.contacts`, `.eventRolls`, `.videoDuplicates`, `.semantic(UUID)`. HomeView uses a `@ViewBuilder destinationView(for:)` extension split for type-checker performance.

**Bounded-concurrency sliding-window TaskGroup cap=4** is the standard pattern for all compute-heavy scans.

HomeView passes **pre-filtered** groups to each card:
```swift
let duplicateGroups = viewModel.photoGroups.filter { $0.reason != .visuallySimilar }
let similarGroups   = viewModel.photoGroups.filter { $0.reason == .visuallySimilar }
```

**Category card navigation**: Tapping any home card checks if results are cached. If yes → navigate immediately. If no → trigger that category's scan, show loading state, then auto-navigate when scan completes.

**Storage stats fix**: Storage bar segments sized proportionally to total capacity. Used space = total − free. "Junk" label removed from UI — do not use that label.

**Total Cleaned**: `totalCleanedBytes: Int64` persisted via `@AppStorage("totalCleanedBytes")` in `HomeViewModel`. Incremented on every delete/compress action and displayed in HomeView storage card.

**Scan result caching**: Scan results are cached to `UserDefaults`/`AppStorage` so relaunching or rebuilding the app does not force a full rescan. Cache is invalidated when a new scan is explicitly triggered by the user. Cache directory is `Application Support` (not `Caches`) to survive Xcode clean builds; migration from old `Caches` location is performed on first launch.

**Live chip counts**: Category chips on HomeView show live photo/file counts (e.g. "47 photos") that increment in real-time during scanning. Percentages are only shown in the top progress indicator, not on chips.

**Photo count accuracy**: `PHFetchOptions` must include `includeAllBursts: true` and not filter by media subtype to match counts shown in other apps (e.g. 50k vs 27k discrepancy). Screenshots and burst photos are included in total count.

**DuplicateHashEngine improvements (CleanIt-inspired)**: dHash computed at 9×8 grayscale thumbnail; Hamming distance ≤ 10 threshold for near-duplicate grouping. Improved thumbnail request uses synchronous `requestImageDataAndOrientation` path to avoid memory spikes.

**SimilarityEngine improvements**: Vision `VNFeaturePrintObservation` distance threshold kept at 0.5. Added pre-filter: skip assets already grouped as exact duplicates to avoid double-counting.

**Storage capacity accuracy**: Total capacity read from `FileManager.default.attributesOfFileSystem(forPath:)` key `.systemSize`. Used space = total − free. Do NOT use `volumeAvailableCapacityForImportantUsage` as it over-reports free space, causing used to appear inflated.

**Storage card UI**: Each storage metric (Used, Free, Total Cleaned) displayed in its own rounded square card. Do NOT label anything "Junk" — that label was removed. Storage chip and doughnut ring are intentionally compact/small.

**Photo/Screenshot grid rendering**: Cells in `PhotoResultsView` and `ScreenshotsResultsView` must use fixed frame sizes (not aspect ratio modifiers that conflict) to avoid photos overlapping each other. Use `GeometryReader`-free fixed widths derived from column count.

**Dev unlock**: `AppConfig.unlockPremium = true` (hardcoded in `Configuration/AppConfig.swift`). `PurchaseManager.isPurchased` returns `true` whenever `AppConfig.unlockPremium` is `true`. SettingsView shows a "Developer" section with Premium Override badge when this flag is set.

**PhotoDuck logo**: Asset catalog imageset at `Assets.xcassets/photoduck-logo.imageset/` — PNG with duck icon + wordmark on transparent background. Used in HomeView header via `Image("photoduck-logo")`.

**SwipeModeView / SwipeModeViewModel**: ~~DELETED~~ — these files no longer exist. Replaced by `GroupReviewView` + `GroupReviewViewModel`.

### Utilities

| File | Role |
|------|------|
| `Utilities/ImageLoader.swift` | `ImageLoader` protocol + `PHImageLoader` with shared `PHCachingImageManager` singleton |
| `Utilities/ProgressThrottle.swift` | Thread-safe interval guard: `ProgressThrottle(every: 40).shouldReport(completed:)` |
| `Utilities/ThreadSafeCounter.swift` | `NSLock`-based atomic counter: `.increment() -> Int` |
| `Utilities/PhotoQualityAnalyzer.swift` | `actor PhotoQualityAnalyzer` with `.shared` singleton. `labels(for: PHAsset) async -> [PhotoQualityLabel]` — Laplacian blur, luminance, Vision face landmarks + capture quality. `qualityScore(for: PHAsset) async -> Float` — **priority order**: (1) personalized model (`Application Support/PhotoQualityClassifier_personalized.mlmodelc`, written by `MLModelUpdater`), (2) bundle model (`PhotoQualityClassifier.mlmodelc`), (3) heuristic composite. Model loading via `loadedQualityModel()` / `resolveQualityModel()` (replaces old `lazy var`). `invalidateModelCache()` called when `"mlModelDidUpdate"` notification arrives so next call picks up fresh personalized model. Results cached by asset localIdentifier. Labels: `.blurry`, `.eyesClosed`, `.underexposed`, `.overexposed`, `.lowFaceQuality`. |
| `Store/UserDecisionStore.swift` | `actor UserDecisionStore` with `.shared` singleton. Persists keep/delete decisions as `[UserDecision]` to `Application Support/userDecisions.json`. Ring buffer (max 500). Stores pairwise signal (keptID vs deletedIDs) + quality labels + quality scores + feature vectors captured before deletion. |
| `Configuration/AppConfig.swift` | `AppConfig.unlockPremium: Bool` — dev paywall bypass (currently `true`) |
| `Store/PurchaseManager.swift` | `@MainActor ObservableObject`, StoreKit 2. `isPurchased = AppConfig.unlockPremium || _isPurchased` |
| `CreateML/TrainPhotoQualityClassifier.swift` | macOS-only Create ML script. Trains `PhotoQualityClassifier.mlmodel` (updatable `MLImageClassifier`). Ship the compiled `.mlmodelc` in the app bundle. `PhotoQualityAnalyzer` lazy-loads it; falls back to heuristics if absent. |

### Paywall gating

| Feature | Gate |
|---------|------|
| Bulk photo select/delete (PhotoResultsView select mode) | **paid** |
| "Delete All" in floating delete bar (PhotoResultsView) | **paid** |
| "Mark Selected for Delete" in group detail | **paid** |
| "Delete Photos" in GroupReviewView summary | **paid** |
| Contact merge write | **paid** |
| Video compression | **paid** |
| Bulk blur delete | **paid** |
| Bulk screenshot delete | **paid** |
| Bulk Smart Picks delete | **paid** |
| Bulk event roll photo delete | **paid** |
| Video duplicate "Delete All" | **paid** |
| "Keep Best, Queue Others" (group detail) | **free** |
| "Review All" launch + all group review navigation | **free** |
| Individual file delete | **free** |
| Empty Recently Deleted (bulk + individual) | **free** |
| Large Photos individual delete | **free** |
| All results views / navigation | **free** |

### Navigation flow

```
ContentView (@AppStorage hasOnboarded)
├── OnboardingView  (first launch)
└── HomeView  (NavigationStack root, dark theme, category cards + storage donut + Total Cleaned stat)
    │   ↳ gear icon → SettingsView (sheet)
    │   ↳ didFreeBytes notification → TrashSummarySheet (sheet, .medium detent)
    ├── PhotoResultsView(title:"Duplicates", groups: non-similar)
    │   ├── PhotoGroupDetailView (marks → reviewVM.markedIDs binding)
    │   └── GroupReviewView (fullScreenCover, shares reviewVM ObservedObject)
    ├── PhotoResultsView(title:"Similar Photos", groups: similar)
    │   ├── PhotoGroupDetailView (marks → reviewVM.markedIDs binding)
    │   └── GroupReviewView (fullScreenCover, shares reviewVM ObservedObject)
    ├── SmartPicksResultsView (AI-ranked low-quality photos)
    ├── FileResultsView → VideoCompressionView (sheet)
    ├── BlurResultsView
    ├── ScreenshotsResultsView
    ├── LargePhotosResultsView
    ├── RecentlyDeletedView  (on-demand scan, tap card triggers scan then navigates)
    ├── EventRollResultsView → RollDetailView (optional-binding navigationDestination)
    ├── VideoGroupResultsView (accordion rows)
    └── ContactResultsView → ContactMergePreviewView
```

### Hooks / automation

- `.claude/settings.local.json` — PostToolUse hook: rebuilds Xcode project after `.swift` file edits (Write/Edit events); also triggers xcodebuild for iPhone target after each session
- `.claude/settings.json` — PostToolUse hook: xcodebuild triggered on file changes to keep Xcode project in sync after each session

---

## NOT yet built

### UI / polish
- Swipe mode for Screenshots — flat `[PHAsset]` swipe UX (separate from GroupReviewView which is for photo groups)
- iCloud-aware badge in SmartPicksResultsView / VideoGroupResultsView — `PHAsset.sourceType` check before delete; warn user if asset is iCloud-only
- Video thumbnail preview in FileResultsView
- Privacy Policy URL wired in SettingsView (placeholder only)
- SemanticScanEngine HomeView cards — Food & Drink, Pets & Animals, Nature & Outdoors, Documents & Receipts (VNClassifyImageRequest categories beyond ScreenshotTagEngine)

### Semantic category cards (partial — see what is done below)
- **Food & Drink** — `VNClassifyImageRequest` "food_and_drink" bucket
- **Pets & Animals** — `VNClassifyImageRequest` "animal" bucket
- **Nature & Outdoors** — `VNClassifyImageRequest` "outdoor" + "nature" + "sky" + "water"
- **Architecture / Vehicles** — separate semantic buckets

(Panoramas, Portrait Mode, Live Photos, Event Rolls, Screenshot detection, and Documents/Receipts via OCR are already built.)

### Infrastructure
- Re-scan on library change — `PHPhotoLibraryChangeObserver`
- `ContentClassifier`, `OrganizeView`, `DailyStreakManager`
- On-device model personalization via `MLUpdateTask` (in progress — see Phase 5)

---

## Roadmap

### Phase 3 — Quick wins on existing engines (zero new training data)

| Feature | Approach | Status |
|---------|----------|--------|
| Screenshot & receipt detection | `ScreenshotTagEngine` — `VNRecognizeTextRequest` + keyword buckets → `ScreenshotTag` enum. Tags surfaced as filter pills in `ScreenshotsResultsView`. | ✅ complete |
| Face-aware Keep Best | `PhotoQualityAnalyzer` `qualityScore(for:)` wired into `GroupReviewViewModel` reranking so `assets[0]` is best by ML/heuristic quality score, not just resolution | ✅ complete |
| **SemanticScanEngine** | Partial — screenshot/receipt detection via `ScreenshotTagEngine` is done. Full semantic buckets (Food, Pets, Nature, etc.) not yet built as a standalone engine. | pending |
| Metadata category cards | Panoramas (`.photoPanorama`), Portrait Mode (`.photoDepthEffect`), Live Photos (`.photoLive`) — instant from `PHFetchOptions` predicate, no engine. Wired in `HomeViewModel`. | ✅ complete |
| Saliency-based "no subject" label | `VNGenerateAttentionBasedSaliencyImageRequest` → `.noSubject` badge in `GroupReviewView` | pending |
| Event Roll clustering | `EventRollScanEngine` — GPS + time clustering (~1km / ~30 min), `haversineKm`, `CLGeocoder` rate-limited reverse-geocoding, `EventRollResultsView` wired into HomeView | ✅ complete |
| Adaptive blur threshold | Normalize Laplacian variance by mean pixel brightness | pending |

### Phase 4 — New on-device ML engines (no external packages)

| Feature | Approach | Status |
|---------|----------|--------|
| Photo quality scorer | `PhotoQualityAnalyzer` lazy-loads `PhotoQualityClassifier.mlmodelc` from app bundle (trained via `CreateML/TrainPhotoQualityClassifier.swift`); falls back to heuristics if model absent | ✅ complete |
| **Video similarity engine** | `VideoDuplicateEngine` — `AVAssetImageGenerator` keyframes (1 or 3 per video), `VNFeaturePrintObservation` per frame, union-find clustering, dHash exact-dupe detection. `VideoGroupResultsView` with accordion rows. | ✅ complete |
| OCR-based screenshot tagger | `ScreenshotTagEngine` — `VNRecognizeTextRequest` sliding-window TaskGroup, keyword buckets for receipt/boarding pass/meme/code/map tags | ✅ complete |
| Background scan scheduling | `BackgroundScanScheduler` (BGProcessingTask) + `BackgroundScanCacheWriter` actor — schedules nightly 2 AM scan, merges results into existing cache | ✅ complete |
| Semantic contact matching | `NLEmbedding` org-name comparison — not yet built | pending |

### Phase 5 — Training & personalization

| Feature | Approach | Status |
|---------|----------|--------|
| Persist keep/delete decisions | `UserDecisionStore` actor with ring buffer (max 500), stored to `Application Support/userDecisions.json` | ✅ complete |
| **Feature capture before deletion** | `GroupReviewViewModel.buildDecisions()` extracts `VNFeaturePrintObservation` + quality scores before `PHPhotoLibrary.performChanges` — stored in `UserDecision.featureVector` / `deletedFeatureVectors` | ✅ complete |
| **Pairwise ranking signal** | `UserDecision.keptAssetID` + `deletedAssetIDs` pairwise — stronger training signal than binary labels | ✅ complete |
| On-device model personalization | `MLModelUpdater` actor — `MLUpdateTask` fine-tunes `PhotoQualityClassifier` on kept-asset images. Requires 50+ decisions. Output: `Application Support/PhotoQualityClassifier_personalized.mlmodelc`. `PhotoQualityAnalyzer` loads it via `resolveQualityModel()` priority-1 path. | ✅ complete |
| LLM-powered contact merge | iOS 18 on-device foundation model APIs for field-level merge decisions | pending |
| Predictive scan scheduling | Time-series model to predict best nudge time based on scan history | pending |

### Training data strategy — all on-device, no server

1. **Label source**: keep/delete decisions from `GroupReviewView` are ground truth. Every action is a `(keptID, deletedID)` pair (pairwise) + individual `(localIdentifier, .kept | .deleted)`. Persisted by `UserDecisionStore`. Features extracted *before* deletion.
2. **Base model**: train a generic quality classifier with Create ML on public labeled datasets (LIVE, KonIQ — free, well-labeled). Ship in app bundle (~10–15 MB).
3. **Personalization**: `MLUpdateTask` fine-tunes the base model on each user's own decision history. Runs overnight on charger. Needs ~50–100 decisions before updates are meaningful.
4. **Threshold tuning**: learn per-user similarity thresholds — a photographer wants tighter grouping than a casual user.

⚠️ "Duck Mode" in earlier planning referred to `SwipeModeView` which was **deleted** — `GroupReviewView` is its replacement and is the correct data source for training labels.

---

## Skill files

Pattern references for Claude when writing new engines/views:
- `.claude/skills/ios-engine.md` — engine shell, event enums, TaskGroup pattern, models
- `.claude/skills/ios-view.md` — view shell, CategoryCard, DuckComponents, progressive loading, self-loading cells
- `.claude/skills/ios-paywall.md` — free/paid table, gate pattern, PurchaseManager API

## Session Start Checklist

Always read these before starting any task:
1. This file (CLAUDE.md) — current state
2. `.claude/skills/ios-engine.md` — before creating any engine
3. `.claude/skills/ios-view.md` — before creating any view
4. `.claude/skills/ios-paywall.md` — before adding any paid gate
