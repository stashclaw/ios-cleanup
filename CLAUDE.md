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
| `SimilarReviewServices` | Heuristic best-shot ranking (resolution 34%, framing 22%, recency/favorites/burst bonuses). Heuristic baseline, enhanced by ML when model is bundled. |
| `PhotoMLStore` | SQLite-backed (`libsqlite3`) feature store for ML training data. Tables: `photo_features`, `pairwise_similarity`, `feedback_events`, `training_rows`. CSV export for CreateML. Located at `Application Support/PhotoDuck/ml/photoduck-ml.sqlite`. |
| `PhotoMLBridge` | Bridges domain types ↔ SQLite records. Extracts VNFeaturePrintObservation as raw `Data`. Exports training CSVs + raw DB to Documents for AirDrop/Finder. |
| `MLEnhancedKeeperRankingService` | Wraps `ConservativeKeeperRankingService` with CoreML predictions (60% heuristic / 40% ML blend). Auto-falls back to heuristics when no model is bundled. |
| `SimilarityCoreMLClassifier` | `MLKeeperRankingService` + `MLGroupActionService` — loads `PhotoDuckKeeper.mlmodelc` and `PhotoDuckGroupAction.mlmodelc` from app bundle. `MLFeatureProvider` adapters for both. |

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
- **Similarity threshold** is `PhotoScanEngine.similarityThreshold = 0.16` (distance, not score). Near-duplicate cutoff is `0.05`.
- Tests cover clustering logic, threshold boundaries, and ML store operations — no live `PHAsset` tests exist.
- **Build simulator**: `iPhone 17 Pro` (iPhone 16 not available on this machine).

## ML Training Pipeline

### On-device data collection (automatic)
Every scan persists Vision embeddings + photo metadata to SQLite. Every keep/delete/skip decision dual-writes to SQLite via `PhotoMLBridge`. Data lives at `Application Support/PhotoDuck/ml/photoduck-ml.sqlite`.

### Export from device
The app writes to `Documents/PhotoDuck-ML-Export/`:
- `keeper_ranking_training.csv` — per-asset training rows
- `group_outcome_training.csv` — per-group training rows
- `training_stats.json` — collection summary
- `photoduck-ml.sqlite` — raw database copy

### Train on Mac (10GB workspace)
```bash
cd MLTraining
swift TrainKeeperModel.swift /path/to/PhotoDuck-ML-Export
```
Outputs `trained-models/PhotoDuckKeeper.mlmodel` + `PhotoDuckGroupAction.mlmodel`.

### Compile & bundle
```bash
xcrun coremlcompiler compile trained-models/PhotoDuckKeeper.mlmodel .
xcrun coremlcompiler compile trained-models/PhotoDuckGroupAction.mlmodel .
```
Drop `.mlmodelc` directories into Xcode project. On next launch, `MLEnhancedKeeperRankingService` picks them up automatically.

### Storage budget
- Embedding per photo: 512 bytes (128 floats × 4 bytes)
- Metadata per photo: ~200 bytes
- 50K photos ≈ 35 MB. 10GB budget = ~14M photos of headroom.
