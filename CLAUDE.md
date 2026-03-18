# iOSCleanup — Claude Code memory

## What this is
iOS app: phone storage cleaner. On-device only, no server, no third-party SDKs.

## Phase 1 scope (branch: main — complete)
Three headless scan engines + unit tests.
- `PhotoScanEngine`: Vision VNFeaturePrintObservation, union-find clustering
- `ContactScanEngine`: CNContactStore, phone normalization, Levenshtein name match
- `FileScanEngine`: FileManager + PHAsset video enumeration

## Phase 2 scope (branch: phase-2 — complete)
Full production UI, StoreKit 2 paywall.

### New files added in Phase 2
| Path | Role |
|------|------|
| `Store/PurchaseManager.swift` | @MainActor ObservableObject, StoreKit 2, @AppStorage("isPurchased") |
| `Configuration/iOSCleanup.storekit` | StoreKit config — Non-Consumable, ID: com.yourname.iOSCleanup.unlock |
| `Views/OnboardingView.swift` | 3-step TabView pager, PHPhotoLibrary + CNContactStore permissions |
| `Views/HomeView.swift` | Scan cards, summary bar, NavigationStack root |
| `Views/HomeViewModel.swift` | @MainActor ObservableObject, drives all 3 engines |
| `Views/PaywallView.swift` | Dismissible sheet, product.displayPrice, purchaseDidSucceed notification |
| `Views/Photos/PhotoResultsView.swift` | Grid of PhotoGroups, bulk select (paid) |
| `Views/Photos/PhotoGroupDetailView.swift` | Side-by-side compare, Keep Best (free), Select & Delete (paid) |
| `Views/Photos/SwipeModeView.swift` | ZStack card stack, DragGesture, 100pt threshold |
| `Views/Photos/SwipeModeViewModel.swift` | Queue with month headers, keep/delete/commitDeletes |
| `Views/Contacts/ContactResultsView.swift` | List grouped by MatchConfidence |
| `Views/Contacts/ContactMergePreviewView.swift` | Two-column diff, green/red fields, merge (paid) |
| `Views/Files/FileResultsView.swift` | Sorted list, type badges, Delete + Compress per row |
| `Views/Files/VideoCompressionView.swift` | Preset picker, estimated sizes, progress bar, success banner |
| `Engines/VideoCompressionEngine.swift` | AVAssetExportSession actor, AsyncStream<CompressionEvent>, saveAndDeleteOriginal |

### Key constraints
- Swift strict concurrency — all engines are actors
- iOS 16.0 minimum; no external packages
- All paid gates check `PurchaseManager.isPurchased` from `.environmentObject`
- `Notification.Name.purchaseDidSucceed` posted on successful purchase → dismisses PaywallView
- Phase 1 engine files must not be modified (only Models/ may be extended)

### Navigation flow
```
ContentView (@AppStorage hasOnboarded)
├── OnboardingView  (first launch)
└── HomeView        (NavigationStack root)
    ├── PhotoResultsView   → PhotoGroupDetailView
    │                      → SwipeModeView (fullScreenCover)
    ├── ContactResultsView → ContactMergePreviewView
    └── FileResultsView    → VideoCompressionView (sheet)
```

### Paywall gating
| Feature | Gate |
|---------|------|
| Bulk photo select/delete | paid |
| Select & Delete in group detail | paid |
| Swipe mode bulk confirm | paid (individual swipe-deletes = free) |
| Contact merge write | paid |
| Video compression | paid |
| Keep Best (group detail) | **free** |
| Individual file delete | **free** |

## Phase 3 plan (not yet built)
Refined analytics, settings screen, push notifications for scheduled scans.
