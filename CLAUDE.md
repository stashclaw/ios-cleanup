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
| `PhotoScanEngine` | Candidate generation only: bounded time/burst/screenshot buckets, cached pinned-revision Vision distances, complete-link cluster formation, and non-destructive screenshot/blurry review candidates. Emits progress via `AsyncThrowingStream<PhotoScanUpdate>`. |
| `ContactScanEngine` | `CNContactStore` + phone normalization + Levenshtein name matching to find duplicate contacts. |
| `FileScanEngine` | `PHAsset` video enumeration with public-API representative-file sizing and typed permission errors. |
| `VideoCompressionEngine` | Cancellable `AVAssetExportSession` actor with disk/output validation, metadata-preserving save, and separate save/delete outcomes. |
| `ExportAlbumStore` / `ExternalPhotoExportService` | Persists explicit assets queued from compact review chips, then copies every PhotoKit resource from the Export Album to a user-picked Files folder, verifies non-empty files, and writes a manifest. The service never deletes; the album UI may offer deletion only after successful verification. |
| `PhotoAnalysisCache` | Persists classified groups, review categories, and the full Photos asset inventory. Launch compares identifiers plus modification/dimension/subtype metadata and scans only new or changed assets with bounded comparison context. |
| `DeletionManager` | The only normal photo-deletion gateway. Applies explicit-ID guardrails, optimistic UI, and a 10-second undo window before committing. Persists lifetime freed-byte/item totals only after PhotoKit confirms deletion. |
| `SimilarityPolicyServices` | Authoritative pair classifier, cluster classifier, split/downgrade rules, and conservative keeper ranking. |
| `PhotoMLStore` | SQLite-backed (`libsqlite3`) feature store for ML training data. Tables: `photo_features`, `pairwise_similarity`, `feedback_events`, `training_rows`. CSV export for CreateML. Located at `Application Support/PhotoDuck/ml/photoduck-ml.sqlite`. |
| `PhotoMLBridge` | Bridges domain types ↔ SQLite records. Extracts VNFeaturePrintObservation as raw `Data`. Exports training CSVs + raw DB to Documents for AirDrop/Finder. |
| `MLEnhancedKeeperRankingService` | Wraps `ConservativeKeeperRankingService` with CoreML predictions (60% heuristic / 40% ML blend). Auto-falls back to heuristics when no model is bundled. |
| `SimilarityCoreMLClassifier` | `MLKeeperRankingService` + `MLGroupActionService` — loads `PhotoDuckKeeper.mlmodelc` and `PhotoDuckGroupAction.mlmodelc` from app bundle. `MLFeatureProvider` adapters for both. |

### ViewModel layer (`Views/`)
- **`HomeViewModel`** (`@MainActor ObservableObject`) — owns all three engines and the cleanup dashboard. Persists scan state to `UserDefaults` under key `photoduck.cleanup-state.v2` as JSON. Tracks freshness with `CleanupResultsFreshnessState` (`.live` / `.lastKnown` / `.stale`).
- **`SwipeModeViewModel`** — explicit delete-candidate card queue with month headers, transition debouncing, and last-swipe undo.

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
StoreKit 2, non-consumable ID `com.photoduck.app.unlock` for app bundle `com.photoduck.app`. A verified entitlement is cached under the legacy `isPurchased` key for offline continuity, but inconclusive launch checks never revoke cached access; only verified revocation or a successful explicit restore with no purchase history may downgrade it. Transaction updates post `.purchaseDidSucceed`, including Ask to Buy approvals.

**Paid:** Auto-clean all groups, custom multi-select photo deletion, contact merge writes, and video compression. **Free:** classifier-selected Keep Best for one eligible group, individual file deletion, and user-authored Duck Mode swipe commits. Never collect review effort and then paywall its commit. `visuallySimilar` groups remain review-only and never expose automatic deletion.

The shared `iOSCleanup` scheme attaches `iOSCleanup/Configuration/iOSCleanup.storekit`; the StoreKit configuration is not bundled as an app resource. Family Sharing is intentionally enabled in the local StoreKit configuration and must match the irreversible App Store Connect choice. The paywall includes an in-app privacy policy and links to Apple's standard EULA. App Store Connect still requires a hosted public privacy-policy URL before submission.

## Key constraints

- **Engines are actors** — do not add `nonisolated` to methods that touch actor state. Methods that only use their arguments and no actor state can be `nonisolated`.
- **No external packages** — zero Swift Package Manager dependencies by design.
- **Photo thumbnails** must use the shared `PHAsset.loadImage` helper, which owns degraded-result, cancellation, timeout, and iCloud behavior. Do not create one-off continuations.
- **Similarity policy** lives in `SimilarityPolicyTypes.swift` and `SimilarityPolicyServices.swift`; thresholds are tuning constants, not UI behavior. Shared subject alone is never sufficient.
- **Deletion safety** requires explicit `keeperAssetID` and `deleteCandidateIDs`; never infer destructive intent from array order. `visuallySimilar` is always review-only.
- **Screenshots and blurry photos** are separate review categories. They never auto-select assets; a user-authored selection is required before deletion.
- **External move safety** is copy, verify, then explicitly confirm deletion. Export failures leave Photos untouched, and all deletion still routes through `DeletionManager`.
- **Keeper ranking** has one authoritative path: `ConservativeKeeperRankingService`, optionally wrapped by `MLEnhancedKeeperRankingService`. Core ML must remain optional and fallback-safe.
- Tests cover clustering, split/chaining prevention, deletion guardrails, ML schemas and persistence, file sizing, video failure paths, and cancellation. Real-device PhotoKit behavior still needs device QA.
- **Build simulator**: `iPhone 17 Pro` (iPhone 16 not available on this machine).

## Design tokens (polish pass, phase 1)

- Colors: use the semantic statics in `Utilities/DuckTheme.swift` (`.backgroundBlush`, `.surface`, `.surfaceElevated`, `.textPrimary`, `.textSecondary`, `.accentPrimary`, `.accentDeep`, `.success`, `.danger`, `.warning`, `.mascotYellow`, `.decorPink`, `.berryBlack`). They map to the `Duck*` colorsets; the generated `Color.duck*` symbols are a deprecated layer still used by not-yet-polished screens.
- The accent token is `Color.accentPrimary`. `Color.accent` is Xcode's generated symbol for `AccentColor.colorset` (same value, #F85FA3) — never redeclare `accent`.
- Type: Bricolage Grotesque (display) + Manrope (text) behind the `duck*` Font tokens. Never `.font(.system(size:))` under `Views/` — enforced by `DesignLintTests`.
- `DuckRadius` s/m/l, `DuckSpace`, `DuckHaptics`. Primary CTAs use `LinearGradient.duckPrimaryCTA` + `.duckPrimaryGlow()` (the only colored glow). Cards use `DuckCard` / `.duckCardElevation()` — hairline stroke + tight shadow, no floaty drop shadows. Toasts render through `DuckToast`.
- Light mode is deliberately locked in `ContentView`; every screen owns its own toolbar chrome (no global UIKit appearance).
- Duck Mode, Files/compression, Paywall, Onboarding, and scan-celebration/auto-clean moments await a later design handoff — do not invent their polish.

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
- Embedding per photo: 8,192 bytes (2,048 floats x 4 bytes)
- Metadata per photo: ~200 bytes
- 50K photos is roughly 400 MB of raw embeddings before database overhead.
