# iOSCleanup - Codex memory

## What this is
iOS app: photo cleanup tool focused on duplicate and similar photos. On-device only, no server, no third-party SDKs.

## Phase 1 scope (branch: main - complete)
Photo scan engine + unit tests.
- `PhotoScanEngine`: Vision VNFeaturePrintObservation, union-find clustering

## Phase 2 scope (branch: phase-2 - complete)
Full production UI, StoreKit 2 paywall, photo review flow.

### New files added in Phase 2
| Path | Role |
|------|------|
| `Store/PurchaseManager.swift` | @MainActor ObservableObject, StoreKit 2, @AppStorage("isPurchased") |
| `Configuration/iOSCleanup.storekit` | StoreKit config - Non-Consumable, ID: com.yourname.iOSCleanup.unlock |
| `Views/OnboardingView.swift` | 2-step TabView pager, PHPhotoLibrary permission |
| `Views/HomeView.swift` | Photo scan cards, summary bar, NavigationStack root |
| `Views/HomeViewModel.swift` | @MainActor ObservableObject, drives photo engine |
| `Views/PaywallView.swift` | Dismissible sheet, product.displayPrice, purchaseDidSucceed notification |
| `Views/Photos/PhotoResultsView.swift` | Grid of PhotoGroups, bulk select (paid) |
| `Views/Photos/PhotoGroupDetailView.swift` | Side-by-side compare, Keep Best (free), Select & Delete (paid) |

### Key constraints
- Swift strict concurrency - the photo engine is an actor
- iOS 16.0 minimum; no external packages
- All paid gates check `PurchaseManager.isPurchased` from `.environmentObject`
- `Notification.Name.purchaseDidSucceed` posted on successful purchase -> dismisses PaywallView

### Navigation flow
```
ContentView (@AppStorage hasOnboarded)
├── OnboardingView  (first launch)
└── HomeView        (NavigationStack root)
    └── PhotoResultsView   -> PhotoGroupDetailView
```

### Paywall gating
| Feature | Gate |
|---------|------|
| Bulk photo select/delete | paid |
| Select & Delete in group detail | paid |
| Keep Best (group detail) | free |

## Phase 3 plan (not yet built)
Refined analytics, settings screen, and polish for the photo cleanup flow.
