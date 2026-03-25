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
| `GroupReviewView` | `Views/Photos/GroupReviewView.swift` | Full-screen dark bulk review flow. Horizontal photo strip per group; auto-marks all non-best photos red on load. Tap cell → change best; ✕ button → unqueue individual photo. "Queue N for Delete" advances to next group and commits pending marks. "Skip" advances without queuing. Running tally bar shows total queued across reviewed groups. Cache banner on relaunch (continue / start fresh). Summary screen with single bulk delete (paid). ML quality labels shown on each photo cell. |
| `GroupReviewViewModel` | `Views/Photos/GroupReviewViewModel.swift` | `@MainActor ObservableObject`. `queue: [PhotoGroup]`, `currentIndex`, `markedIDs` (persisted to UserDefaults via `didSet`). `bestIDForCurrentGroup`, `pendingMarked` per-group state. `selectBest(_:)` → re-auto-marks others. `togglePendingMark(_:)` → cannot unmark the best. `queueAndAdvance()` commits pending + steps. `skipGroup()` steps without queuing. `commitDeletes()` → single `PHPhotoLibrary.performChanges`. `hasCachedSession` for crash recovery. `startFresh()` clears cache. |
| `BlurResultsView` | `Views/Photos/BlurResultsView.swift` | 3-col grid, progressive loading (60/page), self-loading cells, bulk delete (paid) |
| `ScreenshotsResultsView` | `Views/Photos/ScreenshotsResultsView.swift` | 3-col grid, 9:19.5 aspect ratio, progressive loading, bulk delete (paid). Fixed blurry rendering (use `.zero` deliveryMode, exact pixel-size requests). Fixed overlapping photo rendering — cells sized correctly with no z-index conflicts. |
| `RecentlyDeletedView` | `Views/Photos/RecentlyDeletedView.swift` | 3-col grid showing photos in the iOS Recently Deleted album (`PHAssetCollectionSubtype.smartAlbumDeletedAssets`). Hero card with item count + bytes to free. "Empty Trash" (bulk, free) with confirmation dialog. Long-press context menu → "Delete Permanently" (individual, free). Self-loading `RDCell` with video duration badge. |
| `LargePhotosResultsView` | `Views/Photos/LargePhotosResultsView.swift` | List of large photos sorted by size, individual delete (free), shows file size per asset |
| `ContactResultsView` | `Views/Contacts/ContactResultsView.swift` | List grouped by MatchConfidence |
| `ContactMergePreviewView` | `Views/Contacts/ContactMergePreviewView.swift` | Two-column diff, green/red fields, merge (paid) |
| `FileResultsView` | `Views/Files/FileResultsView.swift` | List, tap-to-expand row, Delete (free) + Compress (paid). Dark theme. `deletedIDs` optimistic local deletion. |
| `VideoCompressionView` | `Views/Files/VideoCompressionView.swift` | Preset picker, estimated sizes, progress bar, success banner |

### HomeViewModel — key scan wiring

`scanPhotos()` runs **PhotoScanEngine + DuplicateHashEngine + SimilarityEngine in parallel** via `withTaskGroup(of: Void.self)`. Results deduplicated by `PhotoGroupCollector` (private actor, keyed by `Set<String>` of asset identifiers). Post-processes to strip `exactDuplicate` asset IDs from `visuallySimilar` groups.

`scanBlur()`, `scanFiles()`, `scanScreenshots()` each run their engine independently. All use a per-scan `UUID` stale-write guard.

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
| `Utilities/PhotoQualityAnalyzer.swift` | `actor PhotoQualityAnalyzer` with `.shared` singleton. `labels(for: PHAsset) async -> [PhotoQualityLabel]` — runs Laplacian blur check, mean luminance (under/overexposed), Vision face landmarks (eyes closed, EAR < 0.15), `VNDetectFaceCaptureQualityRequest` (quality < 0.25). Results cached by asset localIdentifier. Labels: `.blurry`, `.eyesClosed`, `.underexposed`, `.overexposed`, `.lowFaceQuality`. Shown as capsule badges on `ReviewPhotoCell` in `GroupReviewView`. |
| `Configuration/AppConfig.swift` | `AppConfig.unlockPremium: Bool` — dev paywall bypass (currently `true`) |
| `Store/PurchaseManager.swift` | `@MainActor ObservableObject`, StoreKit 2. `isPurchased = AppConfig.unlockPremium || _isPurchased` |

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
└── HomeView  (NavigationStack root, dark theme, 6 category cards + Total Cleaned stat)
    │   ↳ gear icon → SettingsView (sheet)
    ├── PhotoResultsView(title:"Duplicates", groups: non-similar)
    │   ├── PhotoGroupDetailView (marks → reviewVM.markedIDs binding)
    │   └── GroupReviewView (fullScreenCover, shares reviewVM ObservedObject)
    ├── PhotoResultsView(title:"Similar Photos", groups: similar)
    │   ├── PhotoGroupDetailView (marks → reviewVM.markedIDs binding)
    │   └── GroupReviewView (fullScreenCover, shares reviewVM ObservedObject)
    ├── FileResultsView → VideoCompressionView (sheet)
    ├── BlurResultsView
    ├── ScreenshotsResultsView
    ├── LargePhotosResultsView
    └── RecentlyDeletedView  (on-demand scan, tap card triggers scan then navigates)
```

ContactResultsView and ContactMergePreviewView exist but are not wired into HomeView's 6-card grid yet.

### Hooks / automation

- `.claude/settings.local.json` — PostToolUse hook: rebuilds Xcode project after `.swift` file edits (Write/Edit events); also triggers xcodebuild for iPhone target after each session
- `.claude/settings.json` — PostToolUse hook: xcodebuild triggered on file changes to keep Xcode project in sync after each session

---

## NOT yet built

### UI / polish
- Old Screenshots auto-suggest — age-bucketed sections inside `ScreenshotsResultsView`
- Swipe mode for Screenshots — flat `[PHAsset]` swipe UX (separate from GroupReviewView which is for photo groups)
- Storage breakdown donut chart — break current blanket % ring into Photos / Videos / Other segments (SwiftUI `Canvas`)
- iCloud-aware badge — `PHAsset.sourceType` check before delete; warn user if asset is iCloud-only
- Trash summary sheet — "You freed X MB" modal after delete
- Video thumbnail preview in FileResultsView
- Privacy Policy URL wired in SettingsView (placeholder only)

### Semantic category cards (Phase 3 — pending SemanticScanEngine)
New HomeView cards unlocked by `VNClassifyImageRequest` + metadata — no new model files:
- **Food & Drink** — `VNClassifyImageRequest` "food_and_drink" bucket
- **Pets & Animals** — `VNClassifyImageRequest` "animal" bucket
- **Nature & Outdoors** — `VNClassifyImageRequest` "outdoor" + "nature" + "sky" + "water"
- **Documents & Receipts** — `VNClassifyImageRequest` "text_and_graphics" + `VNRecognizeTextRequest` confirm
- **Panoramas** — `PHAsset.mediaSubtype.contains(.photoPanorama)` — instant, no scan
- **Portrait Mode** — `PHAsset.mediaSubtype.contains(.photoDepthEffect)` — instant, no scan
- **Event Rolls** — GPS + time clustering (~1km / ~30 min windows)

### Infrastructure
- Scheduled background scan — `BGAppRefreshTask`
- Re-scan on library change — `PHPhotoLibraryChangeObserver`
- Contact scanning wired into HomeView
- `ContentClassifier`, `OrganizeView`, `DailyStreakManager`
- `UserDecisionStore` — feature vector + label persistence before deletion (Phase 5 prerequisite)

---

## Roadmap

### Phase 3 — Quick wins on existing engines (zero new training data)

| Feature | Approach | Touches | Priority |
|---------|----------|---------|----------|
| Screenshot & receipt detection | Add `VNClassifyImageRequest` alongside feature prints to surface a real reason label (screenshot, receipt, meme) — currently everything is `.visuallySimilar` | `PhotoGroup.reason`, `ScreenshotScanEngine` | high |
| Face-aware Keep Best | `PhotoQualityAnalyzer` already runs `VNDetectFaceCaptureQualityRequest` + eyes-closed EAR. Wire its score into `PhotoGroupDetailView` so `assets[0]` is ranked by analyzer quality, not just resolution | `PhotoGroupDetailView`, `PhotoQualityAnalyzer` | high |
| **SemanticScanEngine** | New engine. Runs `VNClassifyImageRequest` (Apple's built-in ~1000-category classifier, ships on-device, ~5ms/photo) across full library. Buckets results into: Food & Drink, Pets & Animals, Nature & Outdoors, Documents & Receipts, Architecture, Vehicles. Emits `AsyncThrowingStream<SemanticScanEvent, Error>` with `.progress` + `.resultsFound([SemanticGroup])`. Powers new HomeView category cards. Zero model files to ship — classifier is part of Vision framework. | new `Engines/SemanticScanEngine.swift`, new `Models/SemanticGroup.swift`, `HomeView`, `HomeViewModel` | high |
| Metadata category cards | Surface `PHAsset.mediaSubtype` flags as free HomeView cards — no scan required, instant from fetch: Panoramas (`.photoPanorama`, often 20–40MB), Portrait Mode (`.photoDepthEffect`), Live Photos (`.photoLive`). Predicate-only, no engine needed. | `HomeViewModel`, `HomeView` | high |
| Saliency-based "no subject" label | Add `VNGenerateAttentionBasedSaliencyImageRequest` to `PhotoQualityAnalyzer`. If `salientObjects` is empty, emit `.noSubject` label. Combined with moderate blur score = strong throwaway signal. Shown as badge in `GroupReviewView` cells alongside existing `.blurry`, `.eyesClosed` etc. | `PhotoQualityAnalyzer`, `GroupReviewView` | med |
| Event Roll clustering | Group photos by GPS location (~1km radius) + time window (~30 min) using `PHAsset.creationDate` + `PHAsset.location`. No Vision required — pure algorithm. Surfaces "Event Rolls" card on HomeView for batch review of trip/event bursts. | `HomeViewModel`, new `EventRollScanEngine`, `HomeView` | med |
| Adaptive blur threshold | Fixed threshold causes false positives on low-light shots. Normalize Laplacian variance by mean pixel brightness so dark scenes aren't flagged blurry | `BlurScanEngine` | med |
| Nickname dictionary for contacts | Levenshtein misses "Bob" vs "Robert". Add hardcoded nickname map + `NLTokenizer` for diacritic-safe tokenization before matching | `ContactScanEngine` | med |

### Phase 4 — New on-device ML engines (no external packages)

| Feature | Approach | Touches | Priority |
|---------|----------|---------|----------|
| Photo quality scorer | Train a small `MLImageClassifier` (sharp/blurry/overexposed/underexposed) with Create ML on a labeled dataset. Replace all heuristic scoring in `PhotoQualityAnalyzer` with a single model inference call per photo. ~15MB model, ships in app bundle | Create ML, Core ML | high |
| **Video similarity engine** | Sample keyframes with `AVAssetReader`, generate `VNFeaturePrintObservation` per frame, cluster videos with similar frame fingerprints. **Biggest gap in current coverage — videos are the largest files** | `AVAssetReader`, `VNFeaturePrintObservation`, new `VideoDuplicateEngine` | high |
| OCR-based screenshot tagger | Run `VNRecognizeTextRequest` on photos classified as screenshots to surface tags: "receipt", "boarding pass", "meme" — helps users decide what to keep | `VNRecognizeTextRequest`, `PhotoGroup` tags | med |
| Semantic contact matching | Use `NLEmbedding` (ships with iOS 17) to compare organization names — "Apple Inc" vs "Apple Computers" won't be caught by edit distance alone | `NLEmbedding`, iOS 17+, `ContactScanEngine` | med |

### Phase 5 — Training & personalization

| Feature | Approach | Touches | Priority |
|---------|----------|---------|----------|
| Persist keep/delete decisions | Every keep or delete in `GroupReviewView` is a labeled training example (photo localIdentifier → .kept / .deleted). Persist to a `UserDecision` store (UserDefaults or SQLite). This is the unsexy load-bearing piece the flywheel depends on | `GroupReviewViewModel`, new `UserDecisionStore` | high |
| **Feature capture before deletion** | ⚠️ Critical: extract quality score + `VNFeaturePrintObservation` vector from each photo *before* `PHPhotoLibrary.performChanges` deletes it. Store `(featureVector, qualityLabels, label)` in `UserDecisionStore`. Without this, `MLUpdateTask` has nothing to train on — deleted assets are gone from PHImageManager. | `GroupReviewViewModel`, `UserDecisionStore`, `PhotoQualityAnalyzer` | high |
| **Pairwise ranking signal** | In GroupReviewView the user picks one photo over another in a group — store the pair `(keptAssetID, deletedAssetID)` not just binary labels. Pairwise ranking is a stronger training signal than binary keep/delete for the quality model. | `GroupReviewViewModel`, `UserDecisionStore` | high |
| On-device model personalization | `MLUpdateTask` fine-tunes the base quality model on the user's accumulated swipe history. Runs at 03:00 on charger. No server | `MLUpdateTask`, Core ML | high |
| LLM-powered contact merge | iOS 18 exposes on-device foundation model APIs. Use them to pick which fields to keep when merging contacts (prefer more complete email, newer phone number) | iOS 18 LLM APIs, `ContactMergePreviewView` | med |
| Predictive scan scheduling | Log when scans find the most duplicates (after trips, weekends). Build a simple time-series model to predict the best nudge time | `BGAppRefreshTask`, push notifications, Create ML tabular | low |

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
