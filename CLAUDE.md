# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is
**PhotoDuck** — an iOS photo storage cleaner. On-device only, no server, no third-party SDKs. Swift strict concurrency throughout, iOS 16.0 minimum.

## Build & Test

```bash
# Build for simulator
xcodebuild -project iOSCleanup.xcodeproj -scheme iOSCleanup \
  -destination 'platform=iOS Simulator,name=iPhone 16' build

# Run all tests
xcodebuild -project iOSCleanup.xcodeproj -scheme iOSCleanup \
  -destination 'platform=iOS Simulator,name=iPhone 16' test

# Run a single test
xcodebuild -project iOSCleanup.xcodeproj -scheme iOSCleanup \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:iOSCleanupTests/PhotoScanEngineTests/testUnionFindTransitivity test
```

Open `iOSCleanup.xcodeproj` in Xcode to run on a real device or use the simulator UI.

## Architecture

### Scan engines (actors in `Engines/`)
All engines conform to the actor model — no shared mutable state across threads.

| Engine | What it does |
|--------|-------------|
| `PhotoScanEngine` | Vision `VNFeaturePrintObservation` + union-find clustering to group similar photos. Emits progress via `AsyncThrowingStream<PhotoScanUpdate>`. |
| `ContactScanEngine` | `CNContactStore` + phone normalization + Levenshtein name matching to find duplicate contacts. |
| `FileScanEngine` | `PHAsset` video enumeration + `FileManager` to surface large files (>50 MB). |
| `VideoCompressionEngine` | `AVAssetExportSession` actor; emits `AsyncStream<CompressionEvent>`. |
| `DeletionManager` | Wraps `PHPhotoLibrary.performChanges`. Provides 5-second undo window before committing. |
| `SimilarReviewServices` | Heuristic best-shot ranking (resolution 34%, framing 22%, recency/favorites/burst bonuses). No ML model — weights are hand-tuned. |

### ViewModel layer (`Views/`)
- **`HomeViewModel`** (`@MainActor ObservableObject`) — owns all three engines and the cleanup dashboard. Persists scan state to `UserDefaults` under key `photoduck.cleanup-state.v2` as JSON. Tracks freshness with `CleanupResultsFreshnessState` (`.live` / `.lastKnown` / `.stale`).
- **`SimilarGroupReviewViewModel`** — manages per-group culling state (keep/trash/undecided per photo), best-shot overrides, and undo.
- **`SwipeModeViewModel`** — card-stack swipe queue with month headers.

### Data model (`Models/PhotoGroup.swift`)
`PhotoGroup` is the central struct: holds `[PHAsset]`, `SimilarityReason` (`.nearDuplicate` / `.visuallySimilar` / `.burstShot`), confidence, best-shot ID, and per-photo `SimilarPhotoCandidate` scoring.

### Navigation flow
```
ContentView (@AppStorage hasOnboarded)
├── OnboardingView          — permissions (Photos + Contacts)
└── HomeView                — NavigationStack root
    ├── PhotoResultsView    → PhotoGroupDetailView → SwipeModeView (fullScreenCover)
    ├── ContactResultsView  → ContactMergePreviewView
    └── FileResultsView     → VideoCompressionView (sheet)
```

### Paywall (`Store/PurchaseManager.swift`)
StoreKit 2, non-consumable ID `com.yourname.iOSCleanup.unlock`. Stored in `@AppStorage("isPurchased")`. Gated features: bulk photo delete, contact merge write, video compression, swipe-mode bulk confirm. **Free:** Keep Best in group detail, individual file delete, individual swipe-deletes.

## Key constraints

- **Engines are actors** — do not add `nonisolated` to methods that touch actor state. Methods that only use their arguments and no actor state can be `nonisolated`.
- **No external packages** — zero Swift Package Manager dependencies by design.
- **`PHImageManager.requestImage` with `.fastFormat`** can fire the completion handler twice (degraded first, then final). Always guard with `PHImageResultIsDegradedKey` before resuming a `CheckedContinuation`.
- **Phase 1 engine files must not be modified** — only `Models/` may be extended. The seam for future AI best-shot is in `SimilarReviewServices`.
- **Similarity threshold** is `PhotoScanEngine.similarityThreshold = 0.12` (distance, not score). Near-duplicate cutoff is `0.05`.
- Tests cover clustering logic and threshold boundaries only — no live `PHAsset` tests exist.
