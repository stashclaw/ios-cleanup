# Chapter 12 — Accessibility, legibility, export resilience and release

> **Milestone(s):** M3 · **Workstreams:** WS-55 – WS-58 · Read `spec/README.md` first: operating rules, invariants, build/test commands and the decision log apply to every workstream here.

## Chapter overview

This chapter is the last stretch before submission. Its four workstreams make the finished app trustworthy to use and ready to ship.

- **WS-55 (navigation, accessibility, Duck Mode chrome):** an open group detail never pops while a scan reshapes the list. VoiceOver users can make every delete decision. Onboarding works at accessibility text sizes. Duck Mode's toolbar is legible.
- **WS-56 (legibility and copy):** text meets WCAG AA contrast (D-CONTRAST), every control has a real 44 pt hit area, counts are pluralized, internal wording never reaches users, and one token set remains.
- **WS-57 (export resilience):** a full or FAT32 drive fails fast with clear guidance, Cancel responds promptly, the Lock Screen shows when an export is stuck, and an interrupted export can be resumed from a banner.
- **WS-58 (release):** versions come from build settings, and the docs, StoreKit text and App Review notes are accurate. It also adds the one-per-version review prompt (D-GROWTH) and runs the final submission gate.

The key risks:
- WS-55 changes navigation plumbing on three screens that earlier workstreams just rebuilt.
- WS-56 is a wide, mechanical sweep that must not become a redesign (invariant 29).
- WS-57 touches the export writer that WS-05 and WS-35 hardened for data safety, so its error handling must never make an unverified file deletion-eligible.

Run the workstreams in numeric order. WS-58 is last in M3 on purpose, so that its docs describe shipped behavior.

**Types from earlier workstreams that this chapter consumes.** Names follow their chapters. If the landed name differs, use the landed one and note it under Deviations.

| Type / API | From | Used by |
|---|---|---|
| `DeletionManager.lastReceipt`, `DeletionReceipt` (`itemCount`, `estimatedBytes`), `.deletionReceiptToast(bottomPadding:)` | WS-11 (ch. 03) | WS-58 |
| `DuckModeExitPolicy`, `SwipeModeViewModel.commitDeletes(using:)` outcome, `isCommitting`, `DuckKeeperChip`, `keeperAsset(forGroupID:)` | WS-12 (ch. 03) | WS-55 |
| `PhotoThumbnailView`, `ThumbnailPhase.Kind`, `DuckCardActionPolicy.canDelete(phase:isTransitioning:)`, `PhotoAccessibilityText.label(creationDate:estimatedBytes:mediaType:)`, `SwipeModeView.cardPhase` | WS-14 (ch. 03) | WS-55 |
| `PhotoGroupDetailActionPolicy`, seeded `deleteSet`/`selectedKeeperID` state in `PhotoGroupDetailView` | WS-04 (ch. 01) | WS-55 |
| `ExportResourceSource`, `FakeExportResourceSource`, `ExportPartialStore`, `ExportManifestStore`, `ExportResultNotes.swift` (`supplementaryNotes`), `deletionEligibleAssetIDs`, `recordWarnings`, `ExternalPhotoExportCapacity` (kept for this chapter) | WS-05 (ch. 01) | WS-57 |
| `ExternalExportCoordinator`, `ExternalExportLifecycle`, `ExternalExportOutcome`, `Views/Export/ExternalPhotoExportProgressStatusView.swift`, `Views/Export/ExportAlbumView.swift`, `Views/Files/FileResultsView+Export.swift`, `Views/Files/LargeVideoPlayerView.swift` | WS-10 (ch. 02) | WS-55, WS-57 |
| `IdleTimerCoordinator.shared.acquire(reason:)` / `release(_:)`; `ScanBackgroundContinuing` and `ContinuedProcessingScanContinuation` (the iOS 26 pattern) | WS-29 (ch. 06) | WS-57 |
| `AssetFileSizeRepository.records(for:)`, `AssetFileSizeProvenance.measuredCurrentVersion` | WS-30 (ch. 07) | WS-57 |
| `CountText`, `ByteText` (`Utilities/CountText.swift`), `HomeRoute`, `HomeRouteDestinationView`, `homePath`, `open(_:)`, `ResultsEmptyContext`, `EmptyStateView(title:icon:message:style:actionTitle:action:)` | WS-31 (ch. 07) | WS-55, WS-56 |
| `PhotoDuckStorage.directory(…)` | WS-34 (ch. 07) | WS-57 |
| `VerifiedDeletionOffer`, `ExportDeletionScheduling`, `LargeVideoExportSummary`, coordinator `deletionOffer` / `sceneBecameActive()` / `commit(_:assets:using:)` | WS-35 (ch. 07) | WS-57 |
| `CleanupAccessPolicy`, `PaywallGate`, `VideoCompressionStartGate` (+ tests) | WS-36 (ch. 08) | WS-56, WS-58 |
| `SwipeQueueSource`, `SwipeModeView(source:)`, the favorite badge on `DuckAssetCard` | WS-41 (ch. 09) | WS-55 |
| `HomeTileLayout`, `HomeTileSpec`, `HomeTileKind`, `HomeTilePresentation`, `GroupSortOrder`, `PhotoResultsOrdering.visibleGroups` | WS-45 (ch. 09) | WS-55, WS-56 |
| `PhotoDuckLinks` (`privacyPolicy`, `supportPage`, `hasOwnerSuppliedValues`), `PrivacyPolicyView`, `HelpAndPrivacyMenu`, `PrivacySurfaceTests.testLinksAreOwnerSupplied`, `docs/privacy-policy.md` | WS-48 (ch. 10) | WS-56, WS-58 |
| `iOSCleanupTests/AppConfigurationTests.swift` (created by WS-02; WS-48 and WS-58 extend it, README §9 contract 17) | WS-02 (ch. 01) | WS-58 |
| `PhotoResultsPresentation` (`visible`, `filtered`, `countByFilter`, `currentReviewCount`, `currentDeletableCount`, `indexByID`, `groupIDsSignature`), `PhotoResultsPresentationMemo.presentation(groups:hiddenIDs:deferredIDs:filter:sort:)`, `PhotoResultsFilterPill`; `ScanProgressLeaves.swift`; `FileResultsView(… progress: VideoScanProgressStore, actions: LargeVideoActions)` | WS-50 (ch. 11) | WS-55, WS-56, WS-57 |

**How WS-50 (chapter 11) delivers groups.** `PhotoResultsView` keeps its `groups` input as the unfiltered, unhidden source. Its body starts with `let p = presentationMemo.presentation(groups: groups, hiddenIDs: hiddenGroupIDs, deferredIDs: …, filter: activeFilter, sort: …)`, and `heroCard`, `filterPills`, `metricRow`, `groupList` and the empty-state checks are functions taking `p`. Use `p.filtered`, `p.visible` and `p.countByFilter[pill, default: 0]` wherever the baseline read the computed `filteredGroups`, `visibleGroups` and `count(for:)`; never recompute them in the body. `SimilarPhotosDashboardView` still observes the model directly and lists `similarGroups`; WS-50 only moved its per-tick status block into a leaf. WS-52 changes thumbnails only. The rules below are written against these names.

**pbxproj recipe.** Follow WS-02.4 (chapter 01) for every new file. IDs are `D0` + the two-digit workstream number + 16 zeros + a 4-digit counter, for example `D05500000000000000000001`. `grep` the project to confirm an ID is unused before adding it.

---

## WS-55 — Navigation stability, accessibility and Duck Mode chrome

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M3 | M | WS-41, WS-45 | no | `ws/55-nav-a11y-duck-chrome` |

**Primary files:**
- New files:
  - `iOSCleanup/Views/Photos/PhotoGroupRoute.swift`: route value, resolution and route cache.
  - `iOSCleanup/Views/Photos/PhotoGroupRouteDestination.swift`.
  - `iOSCleanup/Views/Home/HomeTileRoute.swift`.
  - `iOSCleanup/Views/Photos/DuckCardAccessibility.swift`.
  - `iOSCleanup/Views/Photos/DuckModeChrome.swift`.
  - `iOSCleanup/Views/Components/OnboardingStepLayout.swift`.
- Existing files: `iOSCleanup/Views/PhotoDuckShellView.swift`, `iOSCleanup/Views/Photos/PhotoResultsView.swift`, `iOSCleanup/Views/HomeView.swift`, the file that declares `HomeRoute` (WS-31 put it in `iOSCleanup/Views/Home/ScanOutcomeSummary.swift`), `iOSCleanup/Views/Home/HomeRouteDestinationView.swift`, `iOSCleanup/Views/Photos/SwipeModeView.swift`, `iOSCleanup/Views/Photos/PhotoGroupDetailView.swift`, `iOSCleanup/Views/OnboardingView.swift`, `iOSCleanup/Views/Files/LargeVideoPlayerView.swift`.
- Tests: `iOSCleanupTests/PhotoGroupRouteTests.swift` (*new*), `iOSCleanupTests/HomeTileRouteTests.swift` (*new*), `iOSCleanupTests/DuckCardAccessibilityTests.swift` (*new*), `iOSCleanupTests/DesignLintTests.swift`.
- Project and docs: `iOSCleanup.xcodeproj/project.pbxproj`, `CLAUDE.md`, `docs/DEVICE_QA.md`.

**Findings covered:** UI-21 (P2, confirmed), UI-24 (P3, partially), FSA-15 (P3, confirmed)

**Decisions applied:**
- **D-GATING:** the VoiceOver "Delete" action in Duck Mode is a swipe, so it is free. It never calls the paywall.
- **D-FAVORITES-USER:** a favorite can still be deleted by swipe or VoiceOver action. The card's spoken label says "favorite", so the choice is informed.
- **Invariant 29:** functional and accessibility changes only. The Duck Mode and Onboarding redesign waits for the design handoff; contrast and hit areas are WS-56.

### Goal
- Opening a group detail and editing it during a Deep Clean is safe. The detail never pops because the list changed. If the group is re-clustered, the user keeps reviewing the version they opened and is told it changed.
- Home tiles push by value, so a tile whose count drops to zero never pops the screen it opened.
- A VoiceOver user in Duck Mode hears which photo is on the card (date, size, favorite, position) and can Delete, Keep or Compare through accessibility actions. Delete stays gated on a loaded preview.
- Single taps in the group detail grid toggle selection at once.
- At accessibility text sizes, both onboarding steps scroll and their primary button stays reachable.
- The truly destructive button in Duck Mode's exit dialog is styled destructive.
- Duck Mode's title, Done and Undo Swipe are legible on the black card stack and on the blush completion screen. The same applies to the video player's title.

### Current behavior (verified)
Baseline tree, 2026-09-27. WS-04, WS-10, WS-12, WS-14, WS-31, WS-41, WS-45 and WS-50 will have moved code, so re-find everything by symbol.

**Group detail links pop when the list changes (UI-21)**
- **Similar dashboard.** `iOSCleanup/Views/PhotoDuckShellView.swift:109` has `featuredGroups = Array(similarGroups.prefix(4))`. WS-45 changes this to the top 4 by savings, which changes even more often during a scan. `:435-453` shows `ForEach(featuredGroups) { group in NavigationLink { PhotoGroupDetailView(group: group, …) } label: {…} }`. This is a view-destination link inside a changing `ForEach`.
- **Results list.** `iOSCleanup/Views/Photos/PhotoResultsView.swift:369-388`: `groupList` is `ForEach(groups)`, where `groups` is `filteredGroups`. Each row is `NavigationLink { PhotoGroupDetailView(…, onDeleteGroup: { hiddenGroupIDs.insert(group.id) }) }`.
  - Filter changes, Review Later, Keep Best hiding and scan updates all reshape that `ForEach`.
- **Home tiles.** `iOSCleanup/Views/HomeView.swift:957-981`: `HomeCategoryTile` renders `NavigationLink(destination: destination)` only `if count > 0 || navigatesWhenEmpty`, and otherwise plain content. When a tile's count drops to 0 (a reconcile after deletion, or a Limited-access change), the pushed Duplicates or Similar list pops.
- **The detail holds a snapshot.** `PhotoGroupDetailView.swift:5` declares `let group: PhotoGroup`.
- **Group IDs are not stable across re-clustering.**
  - `PhotoScanEngine.swift:1276-1293` reuses a cached `PhotoGroup` (same `id`) only while the cluster's exact member set is unchanged.
  - A new member creates a new `PhotoGroup` with a fresh `UUID()` (`:1384`, `PhotoGroup.swift:25`).
  - Looking the group up by ID alone therefore fails whenever a photo joins the cluster mid-scan, so a snapshot fallback is required.
- **Paths today.**
  - Home: WS-31 made the stack `NavigationStack(path: $homePath)` with `homePath: [HomeRoute]`. A typed array path cannot push any other value type, so a `PhotoResultsView` pushed inside Home could not push a group route.
  - Shell: the Similar tab's `NavigationStack { SimilarPhotosDashboardView }` has no path (`PhotoDuckShellView.swift:48-52`).
  - Sheets: the results sheets are `NavigationStack { PhotoResultsView(…) }` (`PhotoDuckShellView.swift:268-275`, `HomeView.swift:139-…`).

**Accessibility gaps (UI-24)**
- **The Duck Mode card has no combined description.**
  - `SwipeModeView.swift:97-146`: `DuckAssetCard` has no accessibility label or actions.
  - The date and "Est. X" texts (`:454-465`) are separate elements, and the image is unlabeled.
  - The bottom buttons are labeled only "Delete photo" and "Keep photo" (`:183`, `:193`).
  - After WS-12, the keeper chip is a child view.
  - After WS-14, `cardPhase` gates Delete.
  - After WS-41, the card shows a favorite badge.
- **Double tap delays every selection.** `PhotoGroupDetailView.swift:403-404`: `.onTapGesture(count: 2, perform: onPreview)` comes before `.onTapGesture(count: 1, perform: onToggle)`, so every single tap waits for the double-tap timeout.
  - An expand button (`:432-445`) and the accessibility actions "Toggle selection" and "Open fullscreen comparison" (`:457-458`) already cover preview.
  - `ZoomablePhotoCanvas`'s double tap (`:578`) resets zoom in fullscreen and stays.
- **Onboarding does not scroll.**
  - `OnboardingView.swift:40-65` (`WelcomeStep`) and `:75-117` (`PhotoPermissionStep`) are fixed `VStack`s with `Spacer`s, 180 pt art (`:44`, `:78`), `.duckDisplay` text and `.padding(.bottom, 60)`.
  - There is no `ScrollView`, so at AX sizes the CTA can be pushed off screen.
  - The page dots overlay sits at the bottom with padding 16 (`:20-31`).
- **Exit dialog roles are inverted.** `SwipeModeView.swift:63-80`: "Move N to Recently Deleted" has no role, while "Discard Decisions" is `role: .destructive` (`:77`).

**Duck Mode chrome (FSA-15)**
- `SwipeModeView.swift:30` sets `.navigationTitle("Duck Mode")` over `Color.black.ignoresSafeArea()` (`:29`). There is no `.toolbarColorScheme` or `.toolbarBackground`.
- `ContentView.swift:29` locks `.preferredColorScheme(.light)`, so the title renders in the dark label color on black.
- Both toolbar items hard-code `.foregroundStyle(Color.white)` (`:42`, `:50`), but `DuckModeCompletion` paints `Color.backgroundBlush.ignoresSafeArea()` (`:362`), which puts white "Done" and "Undo Swipe" on light blush.
- **Same defect in the video player:** `LargeVideoPlayerView` (`FileResultsView.swift:1879-1945` today; WS-10 moves it) has `.navigationTitle(file.displayName)` over `Color.black` and no toolbar color scheme.
- **Reference implementations:**
  - `FullscreenGroupCompareView` (`PhotoGroupDetailView.swift:~536-545`) already sets `.toolbarBackground(Color.black, …)`, `.toolbarBackground(.visible, …)` and `.toolbarColorScheme(.dark, …)`.
  - `PhotoGroupDetailView` sets `.toolbarColorScheme(.dark, …)` (`:70`).
- There is no global UIKit appearance anywhere (`grep -rn "appearance()" iOSCleanup` finds only a comment).

### Implementation plan

**WS-55.1 — `PhotoGroupRoute`, resolution and the route cache (new file)**
- **Why:** value-based navigation keeps the pushed screen when the link disappears. A group ID can vanish mid-scan, though, so the destination needs the last version the user saw.
- **Change:** create `iOSCleanup/Views/Photos/PhotoGroupRoute.swift`:
  ```swift
  /// Pushed for a group detail. Never push a bare UUID; other code may push UUIDs.
  struct PhotoGroupRoute: Hashable, Sendable { let groupID: UUID }

  enum PhotoGroupRouteResolution {
      case live(PhotoGroup, position: Int, total: Int)      // the ID is in the live list
      case snapshot(PhotoGroup, position: Int, total: Int)  // the ID vanished; last live version shown
      case missing                                           // never resolved live, or evicted
      var group: PhotoGroup? { … }
  }

  /// One per NavigationStack that registers PhotoGroupRoute. A reference type held in @State:
  /// mutating it during body evaluation publishes nothing and causes no extra renders.
  @MainActor
  final class PhotoGroupRouteCache {
      static let capacity = 16
      private var entries: [UUID: (group: PhotoGroup, position: Int, total: Int)] = [:]
      private var order: [UUID] = []            // oldest first; evict beyond capacity

      /// liveGroups: the full, unfiltered, unhidden list the screen lists from.
      /// displayOrder: IDs in the order the user sees them (for "Group N of M").
      func resolve(_ route: PhotoGroupRoute, liveGroups: [PhotoGroup],
                   displayOrder: [UUID]) -> PhotoGroupRouteResolution {
          if let group = liveGroups.first(where: { $0.id == route.groupID }) {
              let position = displayOrder.firstIndex(of: group.id)
                  ?? liveGroups.firstIndex(where: { $0.id == group.id }) ?? 0
              let total = max(displayOrder.count, 1)
              remember(group, position: position, total: total)
              return .live(group, position: position, total: total)
          }
          if let entry = entries[route.groupID] {
              return .snapshot(entry.group, position: entry.position, total: entry.total)
          }
          return .missing
      }
      private func remember(_ group: PhotoGroup, position: Int, total: Int)   // upsert + LRU bump
  }
  ```
  Create `iOSCleanup/Views/Photos/PhotoGroupRouteDestination.swift`:
  ```swift
  struct PhotoGroupRouteDestination: View {
      let resolution: PhotoGroupRouteResolution
      var onDeleteGroup: ((UUID) -> Void)? = nil
      @Environment(\.dismiss) private var dismiss

      var body: some View {
          switch resolution {
          // ONE case for both, so SwiftUI keeps the detail's @State (the user's edits)
          // when the resolution flips from .live to .snapshot.
          case .live(let group, let position, let total), .snapshot(let group, let position, let total):
              PhotoGroupDetailView(group: group, groupIndex: position, totalGroups: total,
                                   onDeleteGroup: onDeleteGroup.map { callback in { callback(group.id) } })
                  .safeAreaInset(edge: .top, spacing: 0) {
                      if case .snapshot = resolution { GroupChangedNotice(onBack: { dismiss() }) }
                  }
          case .missing:
              EmptyStateView(title: "This group changed",
                             icon: "rectangle.stack.badge.minus",
                             message: "PhotoDuck updated its results. Go back to see the current groups.",
                             style: .neutral, actionTitle: "Back to results", action: { dismiss() })
          }
      }
  }
  ```
  `GroupChangedNotice` is a private view in the same file. It is one line of `.duckCaption` text in `Color.white.opacity(0.85)` on the detail's dark chrome ("This group was updated. You're still reviewing the version you opened."), plus a "Back to results" text button, on a `Color.black.opacity(0.6)` strip.
  - Use existing tokens only. Its hit area follows WS-56's rule: sizing goes inside the label.
- **DECISION (owner may override):** in `.snapshot`, the detail stays actionable. Keep Best and Delete Selected commit the snapshot's explicit plan or the user's explicit selection, exactly as before the group changed. This is safe because every commit-time guard still applies:
  - WS-11 re-resolves assets fresh and skips a group whose keeper vanished;
  - WS-12 rejects user-kept IDs in automated plans;
  - WS-13 excludes favorites and undeletable assets;
  - `PhotoDeletionGuardrails.validateManualSelection` still requires a strict subset.

  The alternative (read-only snapshot) would throw away the user's edits, which is the failure UI-21 describes.
- **Edge cases:**
  - Same ID but changed content (a reconcile after deletions, or WS-12's `applyingUserKeptIDs`): `.live` returns the new version. WS-04's `effectiveDeleteSet = deleteSet.intersection(context.assetIDs)` already drops stale IDs. Under the same ID, the keeper can disappear (a reconcile downgrades a keeper-missing plan to review-only) but never switch to a different photo, because the engine reuses a plan only for an identical member set. WS-04's resolver then offers only manual actions.
  - The cache holds at most 16 groups, which bounds memory for PHAsset references.
  - Never place `.navigationDestination` inside a lazy container.
  - Register `PhotoGroupRoute` exactly once per `NavigationStack` (see WS-55.2).

**WS-55.2 — Adopt value links on the Similar dashboard and in the results list**
- **Change:**
  - **`SimilarPhotosDashboardView`** (`PhotoDuckShellView.swift`):
    - Add `@State private var groupRouteCache = PhotoGroupRouteCache()`.
    - Replace the link at `:436` with `NavigationLink(value: PhotoGroupRoute(groupID: group.id)) { DuckCard { SimilarGroupPreviewCard(group: group).padding(12) } }.buttonStyle(.plain)`.
    - On the body's root (`ZStack`), add:
      ```swift
      .navigationDestination(for: PhotoGroupRoute.self) { route in
          PhotoGroupRouteDestination(resolution: groupRouteCache.resolve(
              route, liveGroups: similarGroups, displayOrder: similarGroups.map(\.id)))
              .environmentObject(purchaseManager)
              .environmentObject(deletionManager)
      }
      ```
      Keep whichever other environment objects today's link passes (for example WS-12's keep store).
  - **`PhotoResultsView`:**
    - Add `@State private var groupRouteCache = PhotoGroupRouteCache()`.
    - The row link becomes `NavigationLink(value: PhotoGroupRoute(groupID: group.id)) { GroupOverviewCard(group: group).contentShape(Rectangle()) }`.
    - Register the destination once, on the body's outer `Group` (the one that already carries `.navigationTitle`). `p` is WS-50's memoized `PhotoResultsPresentation`, computed at the top of `body`:
      ```swift
      .navigationDestination(for: PhotoGroupRoute.self) { route in
          PhotoGroupRouteDestination(
              resolution: groupRouteCache.resolve(route, liveGroups: groups,
                                                  displayOrder: p.filtered.map(\.id)),
              onDeleteGroup: { id in withAnimation(.duckSpring) { _ = hiddenGroupIDs.insert(id) } })
              .environmentObject(purchaseManager)
              .environmentObject(deletionManager)
      }
      ```
    - `liveGroups` must be the **unfiltered, unhidden** input: the view's `groups`, which is also what WS-50's `PhotoResultsPresentationMemo` is fed from. A filter change or a Review Later must never change the resolution. `displayOrder` is only for the title. Read it from `p.filtered`, never by recomputing a filtered list.
  - `PhotoResultsView` is the root of a sheet stack in `PhotoDuckShellView` and `HomeView`, and it is pushed inside Home's stack by WS-55.3. Home never registers `PhotoGroupRoute`, so in every stack there is exactly one registration.
- **Edge cases:**
  - A Keep Best from the row (not the detail) hides the group while its detail is not open. Nothing changes there.
  - The detail's own Keep Best calls `onDeleteGroup` and then `dismiss()`, as today.
  - `hiddenGroupIDs` hides rows only. The resolver still finds the group in `groups`, so a pushed detail of a hidden group stays live until it dismisses itself.

**WS-55.3 — Home: `NavigationPath` and value-based tiles**
- **Why:** a tile whose count reaches 0 removes its link and pops the list it opened. A typed `[HomeRoute]` path cannot carry `PhotoGroupRoute` pushes from a `PhotoResultsView` that is pushed on Home.
- **Change:**
  1. In `HomeView`, change `@State private var homePath: [HomeRoute] = []` to `@State private var homePath = NavigationPath()`.
     - `homePath.append(route)` is unchanged.
     - Replace every `homePath.removeAll()` with `homePath = NavigationPath()`.
     - `grep -n homePath iOSCleanup/Views` and adapt any other use; `count` and `isEmpty` exist on `NavigationPath`.
  2. In the file that declares `HomeRoute`, add two pushed cases, `case duplicateGroups` and `case exportAlbum`, and make `isPushed` return `true` for both.
     - `CleanupOpportunity.route` for duplicates stays `.reviewGroups` (the sheet) for the completion sheet and CTA. Only the tile uses `.duplicateGroups`.
     - If WS-31 or WS-42 already added equivalent cases, reuse them.
  3. In `HomeRouteDestinationView`:
     - `.duplicateGroups` → `PhotoResultsView(groups: viewModel.duplicatePhotoGroups, emptyContext: viewModel.resultsEmptyContext)` with the environment objects the tile passes today;
     - `.exportAlbum` → `ExportAlbumView()` with the environment objects WS-36 requires (`purchaseManager`).
  4. Create `iOSCleanup/Views/Home/HomeTileRoute.swift`:
     ```swift
     enum HomeTileRoute {
         /// Exhaustive on purpose: a new tile kind (WS-59, WS-62) must pick its route or fail to compile.
         static func route(for kind: HomeTileKind) -> HomeRoute {
             switch kind {
             case .exportAlbum: return .exportAlbum
             case .opportunity(let k):
                 switch k {
                 case .largeVideos: return .largeVideos
                 case .duplicates: return .duplicateGroups
                 case .screenshots: return .screenshots
                 case .blurry: return .blurry
                 case .similarReviewOnly: return .similarReviewOnly
                 case .screenRecordings: return .screenRecordings   // WS-42's flat pushed route
                 // WS-59 adds .livePhotoMotion/.largePhotos and WS-62 adds .duplicateVideos here. No `default`.
                 }
             }
         }
     }
     ```
  5. `HomeCategoryTile` stops being generic over `Destination`:
     - Replace `@ViewBuilder let destination` with `let route: HomeRoute`.
     - The body becomes `if count > 0 || navigatesWhenEmpty { NavigationLink(value: route) { tileContent } } else { tileContent }`.
     - `tile(for spec:)` (WS-45) passes `HomeTileRoute.route(for: spec.kind)` and deletes every destination closure. The builders now live only in `HomeRouteDestinationView`, so `HomeView.swift` shrinks.
- **Edge cases:**
  - A tile that drops to 0 loses its link, but the pushed route stays in `homePath`. The destination then shows its own empty state (`ResultsEmptyContext` / `.neutral`).
  - `pendingHomeRoute` (WS-31) still calls `open(route)`.
  - Do not change which routes are sheets (`.reviewGroups`, `.retryUnanalyzed`).

**WS-55.4 — Duck Mode VoiceOver: card element, actions, focus and dialog roles**
- **Why:** a VoiceOver user must know which photo they are about to delete. A Delete action must obey the same "preview loaded" rule as the button.
- **Change:**
  1. Create `iOSCleanup/Views/Photos/DuckCardAccessibility.swift`:
     ```swift
     enum DuckCardAccessibility {
         /// "Photo, 3 Mar 2025, 2.4 MB, favorite, 3 of 40"
         static func label(creationDate: Date?, estimatedBytes: Int64?, mediaType: PHAssetMediaType,
                           isFavorite: Bool, position: Int, total: Int) -> String {
             var parts = [PhotoAccessibilityText.label(creationDate: creationDate,
                                                       estimatedBytes: estimatedBytes, mediaType: mediaType)]
             if isFavorite { parts.append("favorite") }
             if total > 0 { parts.append("\(position.formatted()) of \(total.formatted())") }
             return parts.joined(separator: ", ")
         }
         static let hint = "Use the actions rotor to delete or keep this photo."
         static let deleteAction = "Delete", keepAction = "Keep", compareAction = "Compare with kept photo"
         static func deleteUnavailableAnnouncement(_ phase: ThumbnailPhase.Kind) -> String {
             phase == .unavailable
                 ? "This photo can't be shown, so it can't be deleted here. You can keep it."
                 : "The photo is still loading. Delete becomes available when it appears."
         }
         static func decisionAnnouncement(deleted: Bool) -> String { deleted ? "Marked for deletion" : "Kept" }
     }
     ```
  2. In `SwipeModeView.cardStack`, on `DuckAssetCard` (after WS-12's keeper-chip overlay and WS-14's `.id`):
     ```swift
     .accessibilityElement(children: .ignore)
     .accessibilityLabel(DuckCardAccessibility.label(creationDate: asset.creationDate,
         estimatedBytes: viewModel.fileSize(for: asset.localIdentifier), mediaType: asset.mediaType,
         isFavorite: asset.isFavorite, position: viewModel.reviewedCount + 1, total: viewModel.totalReviewableCount))
     .accessibilityHint(DuckCardAccessibility.hint)
     .accessibilityAction(named: DuckCardAccessibility.deleteAction) { accessibleDelete() }
     .accessibilityAction(named: DuckCardAccessibility.keepAction) { swipeRight() }
     .accessibilityFocused($isCardFocused)
     ```
     - Add `.accessibilityAction(named: DuckCardAccessibility.compareAction)` only when a keeper chip is shown. It presents the same compare cover as the chip's tap (WS-12.5). `children: .ignore` hides the chip, so this action replaces it.
     - `accessibleDelete()`:
       - `guard DuckCardActionPolicy.canDelete(phase: cardPhase, isTransitioning: viewModel.isTransitioning)`;
       - otherwise `UIAccessibility.post(notification: .announcement, argument: DuckCardAccessibility.deleteUnavailableAnnouncement(cardPhase))` and return;
       - on success `swipeLeft()`.
  3. **Focus and announcements.**
     - Add `@AccessibilityFocusState private var isCardFocused: Bool` and `@Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled`.
     - In `swipeLeft()` / `swipeRight()`, after the view model call, post `.announcement` with `decisionAnnouncement(deleted:)`.
     - In `.onChange(of: currentAssetID)`, where WS-14 resets `cardPhase`, set `isCardFocused = voiceOverEnabled`, so focus lands on the next card rather than on the toolbar.
  4. **Bottom buttons.** Labels become "Delete this photo" and "Keep this photo". Keep WS-14's `.disabled(!canDelete)` on Delete.
  5. **Exit dialog** (`SwipeModeView.swift:63-80`, as rewired by WS-12):
     - `Button("Move \(CountText.photos(n)) to Recently Deleted", role: .destructive) { … }`;
     - `Button("Discard Decisions") { dismiss() }` with no role;
     - "Keep Reviewing" stays `.cancel`;
     - the dialog title becomes `"\(CountText.photos(n)) marked for deletion"`.

     WS-12's commit and dismiss logic is unchanged.
  6. **`PendingDeleteThumbnail`:** `.accessibilityLabel("Marked for deletion: " + PhotoAccessibilityText.label(…))`.
- **Edge cases:**
  - With WS-41's asset sources, the label is the same and there is no compare action (no keeper).
  - Month headers are queue entries, not cards, so they are never read as photos.
  - Never add a paywall or confirmation to the accessibility Delete; it is a swipe (D-GATING, invariant 10).

**WS-55.5 — Group detail: single tap toggles immediately**
- **Change:** in `PhotoGroupAssetCell`, delete `.onTapGesture(count: 2, perform: onPreview)`. The single-tap handler becomes `.onTapGesture(perform: onToggle)`.
  - Keep the expand button, the "Open fullscreen comparison" accessibility action and WS-04's keeper-swap affordance.
  - Do not touch `ZoomablePhotoCanvas`'s double tap.
- **Edge cases:** WS-14 already wrote the category grid without a double tap ("per WS-55's direction"). Check that no other double tap on a selectable cell remains: `grep -rn "onTapGesture(count: 2" iOSCleanup/Views` should list only `ZoomablePhotoCanvas`.

**WS-55.6 — Onboarding scrolls at large text sizes**
- **Change:** create `iOSCleanup/Views/Components/OnboardingStepLayout.swift`:
  ```swift
  /// Functional layout only (invariant 29): at default sizes it looks like today's centered VStack;
  /// at accessibility sizes the content scrolls and the actions stay pinned above the page dots.
  struct OnboardingStepLayout<Content: View, Actions: View>: View {
      @Environment(\.dynamicTypeSize) private var dynamicTypeSize
      @ViewBuilder let content: (_ artSize: CGFloat) -> Content
      @ViewBuilder let actions: () -> Actions
      private var isLarge: Bool { dynamicTypeSize.isAccessibilitySize }

      var body: some View {
          GeometryReader { proxy in
              ScrollView {
                  VStack(spacing: 28) { Spacer(minLength: 0); content(isLarge ? 96 : 180); Spacer(minLength: 0) }
                      .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                      .padding(.horizontal, 24)
              }
              .scrollBounceBehavior(.basedOnSize)
          }
          .safeAreaInset(edge: .bottom, spacing: 0) {
              VStack(spacing: 12) { actions() }
                  .padding(.horizontal, 32).padding(.top, 12)
                  .padding(.bottom, isLarge ? 40 : 60)     // clears the page dots (bottom 16 + 8 pt)
                  .background(Color.backgroundBlush)
          }
      }
  }
  ```
  - `WelcomeStep`: `content` holds the icon, lockup and texts (art size from the closure; `PhotoDuckBrandLockup(wordmarkHeight: isLarge ? 28 : 38, …)`); `actions` holds `DuckPrimaryButton("Get Started")`.
  - `PhotoPermissionStep`: `content` holds the mascot and texts (WS-48's copy); `actions` holds the permission button logic unchanged (WS-26's `pendingFirstScan`, WS-48's "Continue") plus "Skip for now".
- **Edge cases:**
  - The paging `TabView` still swipes horizontally, because a vertical `ScrollView` inside a page does not conflict.
  - `.scrollBounceBehavior` is iOS 16.4+, and the minimum is iOS 17 (D-MIN-OS).
  - Do not change fonts, colors or copy.

**WS-55.7 — Duck Mode and video player chrome (FSA-15)**
- **Change:** create `iOSCleanup/Views/Photos/DuckModeChrome.swift`:
  ```swift
  enum DuckModeChrome {
      static func barColorScheme(isComplete: Bool) -> ColorScheme { isComplete ? .light : .dark }
      static func barBackground(isComplete: Bool) -> Color { isComplete ? .backgroundBlush : .black }
      static func itemColor(isComplete: Bool) -> Color { isComplete ? .textPrimary : .white }
  }
  ```
  - In `SwipeModeView`, on the `Group` inside `NavigationStack` (next to `.navigationTitle`), add:
    - `.toolbarBackground(DuckModeChrome.barBackground(isComplete: viewModel.isComplete), for: .navigationBar)`;
    - `.toolbarBackground(.visible, for: .navigationBar)`;
    - `.toolbarColorScheme(DuckModeChrome.barColorScheme(isComplete: viewModel.isComplete), for: .navigationBar)`.
  - Replace both hard-coded `.foregroundStyle(Color.white)` toolbar items with `DuckModeChrome.itemColor(isComplete: viewModel.isComplete)`.
  - `LargeVideoPlayerView`: add `.toolbarBackground(Color.black, …)`, `.toolbarBackground(.visible, …)` and `.toolbarColorScheme(.dark, …)`, exactly like `FullscreenGroupCompareView`.
  - Never add `UINavigationBar.appearance()` or any other global appearance.
- **First step:** in the simulator (iPhone 17 Pro, iOS 26), with WS-07's fixture harness, take `xcrun simctl io booted screenshot` of the card stack and of the completion screen before and after. Liquid Glass bars can render differently from older iOS, so if `.visible` has no effect there, keep the color scheme and item colors (the legibility fix) and note it in the PR.

### Tests
All run in the simulator.
- **`iOSCleanupTests/PhotoGroupRouteTests.swift`** (*new*, `@MainActor`). Build groups with WS-03's `TestPhotoAsset` and explicit IDs.
  - `testLiveGroupResolvesLiveAndIsRemembered`.
  - `testVanishedIDFallsBackToLastLiveSnapshot`: resolve live, then resolve with a list lacking the ID. The result is `.snapshot`, with the same `id`, `deleteCandidateIDs` and `keeperAssetID` as the remembered one.
  - `testNeverSeenIDIsMissing`.
  - `testSameIDWithChangedMembersResolvesToNewVersion`: the second list has the same ID with one asset removed, giving `.live` with 2 assets.
  - `testPositionUsesDisplayOrderAndSurvivesFilterChange`: `displayOrder` excludes the ID (filtered), `liveGroups` includes it. The result is `.live` with position from `liveGroups`.
  - `testCacheEvictsBeyondCapacity`: after 17 distinct live resolutions, the first is `.missing` when absent.
- **`iOSCleanupTests/HomeTileRouteTests.swift`** (*new*):
  - `testEveryTileKindMapsToAPushedRoute`: for every `HomeTileKind` from `HomeTileLayout.make(opportunities: [], exportAlbumCount: 0)`, `route(for:).isPushed == true`.
  - `testDuplicatesTilePushesDuplicateGroupsNotTheSheet`.
- **`iOSCleanupTests/DuckCardAccessibilityTests.swift`** (*new*):
  - `testLabelIncludesDateSizeFavoriteAndPosition`: a fixed date and 2,400,000 bytes give a label containing the `PhotoAccessibilityText` output, then "favorite", then "3 of 40".
  - `testLabelOmitsFavoriteWhenNotFavorite`.
  - `testDeleteUnavailableAnnouncementDiffersForLoadingAndUnavailable`.
  - `testChromeUsesDarkBarForCardsAndLightForCompletion`: `DuckModeChrome.barColorScheme(isComplete: false) == .dark`; `true` gives `.light`.
- **`DesignLintTests.testDarkScreensSetToolbarColorScheme`** (new rule):
  - Every file under `Views/` that contains `.navigationTitle(` **and** either `Color.black.ignoresSafeArea()` or `Color.berryBlack.ignoresSafeArea()` must also contain `.toolbarColorScheme(`.
  - The allowlist is empty. Today this fails on `SwipeModeView.swift` and the player file, and passes after WS-55.7.
- **`DesignLintTests.testNoDoubleTapOnSelectableCells`:** `onTapGesture(count: 2` appears only in the file that contains `ZoomablePhotoCanvas`.
- **Simulator QA (WS-07 fixtures):** see Device QA steps 1, 4 and 5. The VoiceOver checks can run in the simulator with Accessibility Inspector; the device pass is authoritative.

### Acceptance criteria
- [ ] No `NavigationLink { … }` or `NavigationLink(destination:)` remains in `PhotoDuckShellView.swift`, `PhotoResultsView.swift` or `HomeView.swift` (`grep`). Group and tile links are value-based.
- [ ] `PhotoGroupRoute` is registered once per stack: on `SimilarPhotosDashboardView` and on `PhotoResultsView`, never on Home.
- [ ] `homePath` is a `NavigationPath`. `HomeRoute` has `.duplicateGroups` and `.exportAlbum`, and `HomeTileRoute` covers every `HomeTileKind` with no `default`.
- [ ] Simulator: opening a featured group during a fixture scan and waiting for new groups leaves the detail on screen. Unmarked photos stay unmarked (Device QA 1).
- [ ] Duck Mode cards expose one accessibility element with date, size, favorite and position, and Delete/Keep (and Compare when a keeper exists) actions. The Delete action is refused with an announcement unless `DuckCardActionPolicy.canDelete` holds.
- [ ] In the exit dialog, "Move N to Recently Deleted" is `.destructive` and "Discard Decisions" has no role.
- [ ] `grep -rn "onTapGesture(count: 2" iOSCleanup/Views` lists only `ZoomablePhotoCanvas`.
- [ ] Onboarding at AX5 on the iPhone SE (3rd gen) simulator: both steps scroll and the primary button is fully visible without scrolling. At default size, the before and after screenshots are identical to within layout rounding.
- [ ] Duck Mode's title, Done and Undo Swipe are legible on the card stack and on the completion screen (before and after screenshots in the PR). The video player title is legible.
- [ ] All new tests and lint rules pass, the full suite is green, there are no new warnings, and new files are in `project.pbxproj`.
- [ ] `CLAUDE.md` Navigation flow mentions value-based group routes (`PhotoGroupRoute`, snapshot fallback) and `NavigationPath` on Home. Key constraints gain: "Lists never use view-destination NavigationLinks; push values and resolve them at the stack root."

### Device QA
Add to `docs/DEVICE_QA.md` under "Accessibility and navigation (WS-55)":
1. **DQA-NAV-55.1:** during a Deep Clean on a 10k+ library, open featured group #3 on the Similar tab and unmark one photo. Wait until at least 5 new groups appear. The detail stays open with your edit. If the notice "This group was updated…" appears, Keep Best still works and only the photos shown as marked go to Recently Deleted.
2. **DQA-NAV-55.2:** open the Duplicates tile, then in another app delete every photo of those groups and return. The list shows its empty state instead of popping back to Home.
3. **DQA-A11Y-55.3:** VoiceOver on, Duck Mode. Each card reads date, size, position ("favorite" when relevant). Rotor actions Delete and Keep work, and focus moves to the next card. On an iCloud-only photo in Airplane Mode, Delete announces that the photo can't be shown. Finish with "Move N to Recently Deleted": the iOS prompt appears.
4. **DQA-A11Y-55.4:** VoiceOver on. Complete Keep Best in a group detail, then Delete Selected in a review-only group. Both are reachable and announce their outcome (the receipt toast).
5. **DQA-A11Y-55.5:** Settings › Accessibility › Display & Text Size › Larger Text at the maximum, on an iPhone SE or mini. Onboarding "Get Started" and "Continue" are reachable, and "Skip for now" is tappable.
6. **DQA-A11Y-55.6:** in group detail, single taps toggle selection with no perceptible delay.

### Pitfalls and out of scope
- **Invariant 1 and 3:** the resolver never builds or edits a `PhotoGroup`. It returns an existing value. Never infer a group from list position.
- Do not register `PhotoGroupRoute` on Home's root. SwiftUI uses the registration closest to the root and warns about duplicates.
- Do not move `.navigationDestination` into `LazyVStack` or `ForEach`.
- `children: .ignore` on the card hides its children from VoiceOver. Every child interaction (compare) needs an action.
- **Reconciliation:**
  - Group resolution uses WS-50's exact names. `liveGroups` is the view's `groups` input, which also feeds `PhotoResultsPresentationMemo`, and `displayOrder` is `p.filtered`. The Similar dashboard resolves from `similarGroups`.
  - The accessibility Delete keeps WS-14's rule, which WS-51 also keeps: Delete needs the full-quality phase `.loaded`.
  - `HomeRoute` stays declared by WS-31. This workstream changes `homePath` to `NavigationPath`, as WS-31 anticipated, and adds `.duplicateGroups` and `.exportAlbum`. WS-42 already added the flat pushed `HomeRoute.screenRecordings`, which `HomeTileRoute` maps `.screenRecordings` to. `HomeTileKind` is keyed by WS-31's nested `CleanupOpportunity.Kind` (README §9 contract 10).
- **Belongs elsewhere:**
  - Contrast, hit-area sizing, the exit dialog's remaining plural sweep and the Duck Mode button fills: WS-56 (this chapter).
  - Duck Mode prefetch: WS-51 (chapter 11).
  - Any Duck Mode or Onboarding redesign: the design handoff.

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| UI-21 | confirmed | Three view-destination links in changing containers were verified: `PhotoDuckShellView.swift:435-453`, `PhotoResultsView.swift:369-388`, and the conditional link in `HomeCategoryTile` (`HomeView.swift:971-975`). The actual pop is SwiftUI runtime behavior, but the structure is the documented cause. Three differences from the reviewer's fix. First, group IDs regenerate when cluster membership changes (`PhotoScanEngine.swift:1276-1293`, `:1384`), so the snapshot fallback is essential rather than a nicety. It is captured at destination resolution through a reference-type cache instead of a tap gesture, which VoiceOver activation would bypass. Second, the `.snapshot` state stays actionable, because commit-time guards apply (DECISION). Third, Home's typed `[HomeRoute]` path has to become `NavigationPath` so pushed results can push groups, and tiles push `HomeRoute` values. |
| UI-24 | partially | All four gaps are real. The claim "VoiceOver hears only Delete/Keep" is overstated: the card's date and "Est." texts are separately focusable, but nothing ties them to the decision and there are no actions. The fix adds a combined element, Delete/Keep/Compare actions gated by WS-14's `DuckCardActionPolicy`, and focus management. The onboarding layout keeps default-size visuals through a min-height ScrollView and a pinned inset. Whether the CTA is actually clipped at AX5 is a simulator/device check (DQA-A11Y-55.5). |
| FSA-15 | confirmed | No `.toolbarColorScheme` in `SwipeModeView`. White toolbar items (`:42`, `:50`) sit over `DuckModeCompletion`'s blush (`:362`). The light lock is at `ContentView.swift:29`. The same defect exists in `LargeVideoPlayerView`, which is fixed too. iOS 26 Liquid Glass may render bar backgrounds differently, so a before/after simulator screenshot is the first step. The lint follows the reviewer's rule. |

---

## WS-56 — Legibility and copy polish: contrast, hit targets, plurals, tokens

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M3 | L | WS-31, WS-36, WS-55 | no | `ws/56-legibility-copy-tokens` |

**Primary files:**
- **Tokens:** `iOSCleanup/Utilities/DuckTheme.swift`, `iOSCleanup/Assets.xcassets/Colors/` (5 new colorsets, `DuckRose` edited), `iOSCleanup/Utilities/Font+PhotoDuck.swift`, `iOSCleanup/Utilities/CountText.swift`.
- **Components:** `iOSCleanup/Views/Components/DuckComponents.swift`, `iOSCleanup/Views/Components/DuckBottomActionBar.swift`, `iOSCleanup/Views/Components/DuckControls.swift` (*new*: `DuckChipButtonStyle`, `DuckTextLinkLabel`).
- **Views** (sweep): `iOSCleanup/Views/Photos/PhotoResultsView.swift`, `iOSCleanup/Views/Photos/PhotoResultsHeroText.swift` (*new*), `iOSCleanup/Views/HomeView.swift`, `iOSCleanup/Views/PaywallView.swift`, `iOSCleanup/Views/OnboardingView.swift`, `iOSCleanup/Views/PhotoDuckShellView.swift`, `iOSCleanup/Views/Photos/SwipeModeView.swift`, `iOSCleanup/Views/Photos/PhotoGroupDetailView.swift`, `iOSCleanup/Views/Files/*`, `iOSCleanup/Views/Export/*`, `iOSCleanup/Views/Home/*`.
- **Engines:** `iOSCleanup/Engines/PhotoScanStatusText.swift` (*new*), `iOSCleanup/Engines/PhotoScanEngine.swift` (3 string literals only), `iOSCleanup/Engines/FileScanEngine.swift`.
- **Tests:** `iOSCleanupTests/DesignContrastTests.swift` (*new*), `iOSCleanupTests/DesignLintTests.swift`, `iOSCleanupTests/Support/SwiftSourceScanner.swift` (*new*), `iOSCleanupTests/CountTextTests.swift` (*new* if WS-31 did not create one), `iOSCleanupTests/CopyTextTests.swift` (*new*).
- **Project and docs:** `iOSCleanup.xcodeproj/project.pbxproj`, `CLAUDE.md`, `docs/DEVICE_QA.md`.

**Findings covered:** FSB-08 (P3, partially), FSB-09 (P3, confirmed), FSB-10 (P3, partially), FSB-11 (P3, partially)

**Decisions applied:**
- **D-CONTRAST** (option 1, owner confirms), **as amended by this workstream** (README §6 D-CONTRAST text and §9 contract 20): add text-safe tokens, move `DuckRose` to #B04A7C, and darken every fill that carries a white label. Brand fills, icons, strokes and tints keep the brand colors. The amendment adds two things to the listed default:
  - a dark-chrome rule, `DuckTone.textOnDark`, because several listed text tokens fail on black (accentText is 3.46:1);
  - the white-on-danger/success Duck Mode Delete/Keep fills, swipe cues and grid Keeper badge (4.04:1 and 3.38:1 today).

  Option 2 is the fallback: skip WS-56.2 and delete `testWhiteLabelsOnFillsMeetAA`, recording it in the PR. This is the README's "CTA-gradient part of WS-56" cut line. The dark-chrome rule (WS-56.1, WS-56.3) applies under either option.
- **D-GATING / D-FREE-KEEPBEST:** no gating changes. The WS-36 entitlement guard inside `VideoCompressionView` is only verified here.
- **Invariant 29:** token-level and copy changes only. Layouts, fonts and component shapes stay. The only visual changes are the D-CONTRAST colors and hit-area-neutral restructuring.

### Goal
- Every text-on-background pair used in the app meets WCAG AA (4.5:1 for body text, 3:1 for ≥ 24 pt regular or ≥ 18.66 pt bold), enforced by `DesignContrastTests`.
- Every tappable control has a hit area of at least 44×44 pt, because sizing lives inside the label. A lint rule enforces this.
- No UI string shows "1 photos", "1 groups", "1 videos" or "bounded", and the scan status reads like user language.
- One radius and one spacing token set remain (`DuckRadius`, `DuckSpace`), plus a small `DuckTone` for color roles. There are no dead components and no raw corner-radius literals.

### Current behavior (verified)
**Contrast (FSB-08).** Recomputed from the colorset any-appearance components (sRGB, WCAG relative luminance):
- accentPrimary #F85FA3: 2.70 on blush, 2.80 on surface, 2.93 on white. White on it: 2.93.
- accentDeep #D4458A: white on it 4.18, so the CTA gradient's darkest stop also fails.
- textSecondary (DuckRose #C94C84): 3.98 on blush, 4.14 on cream.
- warning: 2.01. success: 3.10. danger: 3.71 on blush.
- White on `Color.danger`: 4.04. White on `Color.success`: 3.38. These are the Duck Mode Delete and Keep buttons (`SwipeModeView.swift:176-195`) and the grid "Keeper" badge (`PhotoGroupDetailView.swift:417-431`). The finding did not list them.
- **The proposed text tokens fail on dark chrome.**
  - accentText #B8307A reaches only 3.46 on black and 3.03 on berryBlack.
  - The new DuckRose #B04A7C drops to 3.76 on black, from 4.85 today.
  - Brand pink passes on dark: 7.16 on black, 6.46 on berryBlack.

  Text on the Duck Mode card stack, the group detail and fullscreen compare must therefore stay white or brand-colored. Today's textSecondary badge "N left" on black is 4.39 and already fails.
- **Badge tints.** `StatusBadge` (`DuckComponents.swift:282-296`) paints its accent at 14% behind 11 pt bold text in the same accent. With text tokens, the 14% tint gives 3.9–4.5 (warning 3.96, success 4.05 on blush). At 6% tint, the text tokens reach 4.56–5.14. textSecondary on its own tint stays at 4.34 or below at any tint, so the secondary badge needs textPrimary text.
- **Where brand colors are used as text today:**
  - `accentPrimary` is used as a text or icon foreground 26 times and textSecondary 65 times under `Views/`.
  - Components take a single color used for text: `StatusBadge(accent:)`, `PrimaryMetricCard(accent:)` (value text, `:219-222`) and `DuckOutlineButton(color:)` (`:139-157`).
  - The CTA gradient is `[accentPrimary, accentDeep]` (`DuckTheme.swift:40-46`). `DuckPrimaryButton`, the Keep Best capsule (`PhotoResultsView.swift:419-423`) and `DuckBottomActionBar` (`:42-45`) fill with it. The selected filter pill fills with accentPrimary (`PhotoResultsView.swift:348-351`).
- The wordmark fallback `Text("PhotoDuck")` (`DuckComponents.swift:50-54`) is a logotype, which WCAG 1.4.3 exempts. The header wordmark image (RT-3) is exempt too.

**Hit areas (FSB-09).** A Button's hit area is its label. Padding, frames and backgrounds applied to the `Button` view itself are not tappable. A scan of `Views/` (control expression followed by `.padding(`/`.frame(`, using the scanner in Tests) finds 11 offenders. Ten are real hit-area bugs:
- the filter pills (`PhotoResultsView.swift:340-352`, with the false comment "≥44pt target" at `:346`);
- Pause/Continue (`HomeView.swift:826-837`);
- the "Unlock" capsule (`HomeView.swift:277-285`);
- the diagnostics `Menu` (`HomeView.swift:227-247`, 36×36; WS-48 replaces it with a 44×44-label `HelpAndPrivacyMenu`);
- Restore, Privacy Policy and Terms (`PaywallView.swift:148-169`);
- "Skip for now" (`OnboardingView.swift:109-112`);
- the fullscreen-comparison button (`PhotoGroupDetailView.swift:432-441`: a 32×32 label inside a 44×44 frame applied outside);
- the video player "Try Again" (`FileResultsView.swift:1908-1915`).

  The eleventh is `continueToExportBar` (`FileResultsView.swift:972-1004`; `FileResultsView+Export.swift` after WS-10). Its label is already full-width and 54 pt tall, and the outer `.padding` only insets the bar. It must still be restructured (padding and material on a wrapping container), so the rule can stay strict with an empty allowlist.

  Also text-only, with no sizing at all: "See all" (`PhotoDuckShellView.swift:427-432`), the paywall "Try Again" (`PaywallView.swift:84-88`) and "Cancel Export" in `ExternalPhotoExportProgressStatusView` (today `HomeView.swift:1309-1311`). `DuckPrimaryButton` and `DuckBottomActionBar` already size inside their labels.

**Plurals and jargon (FSB-10).**
- The plural lint regex from the Tests section, run over `Views/**` and `Engines/**`, finds 42 lines on the baseline tree: 18 in `HomeView.swift`, 9 in `HomeViewModel.swift`, 5 in `PhotoDuckShellView.swift`, 5 in `PhotoResultsView.swift`, 3 in `FileScanEngine.swift`, and 1 each in `SwipeModeView.swift` and `FileResultsView.swift`.
- WS-31 rewrote the completion sheet, hero, CTA and notification copy with `CountText`. WS-45 removed "Tap to pause", because the CTA never pauses and shows the activity message instead. Re-run the grep after those land.
- **Internal wording:**
  - The engine's `statusMessage` "Analyzing the next bounded photo batch…" (`PhotoScanEngine.swift:958-960`) becomes the Home CTA subtitle during scans via `scanActivityMessage` (`HomeViewModel.swift:1707`).
  - "Preparing the first photo batch…" and "Restored saved results. Waiting for the next local or iCloud photo…" (`:632-634`) are also shown.
  - `FileScanEngine.statusMessage` (`:245-258`) appends "reused N saved sizes" and says "Checked 1 videos". `cache_hits` is already recorded in diagnostics (`SharedHelpers.swift:922-954`).
  - The results hero says "N / M groups shown" and "… · N move candidates" (`PhotoResultsView.swift:304-313`).

**Tokens (FSB-11).**
- `DuckSpace` (`DuckTheme.swift:28-36`), `DuckSpacing` and `DuckCornerRadius` (`Font+PhotoDuck.swift:24-36`) have 0 uses. `DuckRadius` is used widely.
- 18 raw `cornerRadius:` literals remain under `Views/` (4, 5, 9, 10, 12, 50): `DuckComponents.swift:151,153,169,172`, `DuckToast.swift:82,85,96,98`, `HomeView.swift:401,774,2144,2146`, `PhotoDuckShellView.swift:352,355,538`, `PhotoResultsView.swift:558`, `PhotoGroupDetailView.swift:624,626`.
- `BestShotBadge` (`DuckComponents.swift:299-328`) has no references.
- The `VideoCompressionView` entitlement guard is delivered by WS-36.7 (`VideoCompressionStartGate` + `VideoCompressionStartGateTests`).

### Implementation plan
One commit per task. The suite must be green after each.

**WS-56.1 — Text-safe tokens, `DuckTone` and `DesignContrastTests`**
- **Change:**
  1. **Colorsets.** Add under `Assets.xcassets/Colors/` (sRGB, any appearance; copy the same value into the dark slot, which never resolves because the app is light-locked):
     - `DuckAccentText` #B8307A (0.7216, 0.1882, 0.4784);
     - `DuckWarningText` #996100 (0.6000, 0.3804, 0.0000);
     - `DuckSuccessText` #1E7A4F (0.1176, 0.4784, 0.3098);
     - `DuckDangerText` #B8285A (0.7216, 0.1569, 0.3529);
     - `DuckCTADeep` #A8336F (0.6588, 0.2000, 0.4353).

     Change `DuckRose`'s any-appearance components to #B04A7C (0.6902, 0.2902, 0.4863).
  2. **`DuckTheme.swift`:** add `accentText`, `warningText`, `successText`, `dangerText` and `ctaDeep` statics mapping to the generated `Color.duck…` symbols. Then add:
     ```swift
     /// Color roles. `brand` = icons, strokes, tints, progress fills. Never text on light surfaces.
     enum DuckTone: CaseIterable, Sendable {
         case accent, warning, success, danger, secondary, primary
         var brand: Color { … }       // accentPrimary, warning, success, danger, textSecondary, textPrimary
         var text: Color { … }        // on light surfaces: accentText, warningText, successText, dangerText, textSecondary, textPrimary
         var textOnDark: Color { … }  // on black/berryBlack: accentPrimary, warning, success, danger, .white.opacity(0.8), .white
         var labelFill: Color { … }   // fill under a white label: accentText, warningText, successText, dangerText, textPrimary, textPrimary
         var badgeText: Color { self == .secondary ? .textPrimary : text }  // text on a 6% tint of `brand`
         static let badgeTintOpacity = 0.06
         static let darkBadgeTintOpacity = 0.14
     }
     extension LinearGradient {
         static let duckPrimaryCTAStops: [Color] = [.accentText, .ctaDeep]    // white label ≥ 4.5 on both
         static let duckPrimaryCTA = LinearGradient(colors: duckPrimaryCTAStops,
                                                    startPoint: .topLeading, endPoint: .bottomTrailing)
     }
     ```
     `duckPrimaryGlow()` keeps `accentPrimary` (a decorative glow). The `LinearGradient.duckPrimaryCTA` edit belongs to WS-56.2; in this commit add only `duckPrimaryCTAStops`, set to today's `[accentPrimary, accentDeep]`, so the gradient is built from it.
  3. **Contrast math and tests.** Create `iOSCleanupTests/DesignContrastTests.swift`. A private `ContrastMath` resolves `UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))`, reads `getRed(_:green:blue:alpha:)`, composites alpha over the background, and computes the WCAG ratio. The test pairs are in the Tests section.
- **Edge cases:**
  - The generated symbol names come from the colorset names (`DuckAccentText` → `Color.duckAccentText`).
  - Never name a static `accent` (CLAUDE.md: `Color.accent` is Xcode's `AccentColor`).

**WS-56.2 — Fills that carry white labels (D-CONTRAST option 1; its own commit, revertible)**
- **Change:**
  - `LinearGradient.duckPrimaryCTAStops = [.accentText, .ctaDeep]`. This covers `DuckPrimaryButton`, `DuckBottomActionBar`'s enabled fill, the results "Keep Best" capsule and the paywall loading placeholder.
  - Duck Mode Delete and Keep buttons: `.background(DuckTone.danger.labelFill …)` and `DuckTone.success.labelFill`.
  - The swipe cue capsules use the same `labelFill` at opacity 0.92.
  - The grid "Keeper" badge in `PhotoGroupAssetCell`, and WS-12's `DuckKeeperChip` badge, use `DuckTone.success.labelFill`.
  - The selected filter pill uses `DuckTone.accent.labelFill` (WS-56.4's `DuckChipButtonStyle`).
  - Disabled fills (`decorPink` in `DuckBottomActionBar`) are exempt: WCAG excludes inactive controls.
- **D-CONTRAST amendment (README §9 contract 20):** the Duck Mode Delete/Keep fills, the swipe cues and the Keeper badge are part of D-CONTRAST as amended, alongside the CTA, the pill and the action bar. They carry white labels on the destructive-decision screen at 4.04:1 and 3.38:1, which is the exact failure D-CONTRAST exists to fix. The owner's option 2 still reverts this whole commit.

**WS-56.3 — Text sweep and component roles**
- **Change:**
  1. **Components take a tone, not a text color:**
     - `StatusBadge(title:tone:onDark: Bool = false)`. Light: text `tone.badgeText` on `tone.brand.opacity(DuckTone.badgeTintOpacity)`. Dark: text `tone.textOnDark` on `tone.brand.opacity(DuckTone.darkBadgeTintOpacity)`.
     - `PrimaryMetricCard(…, tone: DuckTone, …)`: value text `tone.text`, progress fill `tone.brand`.
     - `DuckOutlineButton(title:tone:action:)`: text and stroke `tone.text`.
     - `DuckProgressBar(color:)` and `StatPill(accent:)` keep `Color`, because they use it only for fills and icons.
     - `HomeCategoryTile` and WS-45's `HomeTilePresentation` pass a `DuckTone`: brand for the icon circle, tone for the badge.

     Update every call site (about 15). Where a call site chose a color dynamically (`confidenceColor`, the tile color), change the helper to return a `DuckTone`.
  2. **Light surfaces.** Replace `.foregroundStyle(Color.accentPrimary / .warning / .success / .danger)` on `Text`, `Label` and button titles with `Color.accentText / .warningText / .successText / .dangerText`. `Image(systemName:)` foregrounds, strokes, fills and progress bars keep brand colors.
  3. **Dark chrome** (Duck Mode card stack and header, `PhotoGroupDetailView`, `FullscreenGroupCompareView`, `LargeVideoPlayerView`, `DuckKeeperChip`):
     - text uses `.white`, `Color.white.opacity(≥ 0.75)` or `DuckTone.x.textOnDark`, never `*Text` tokens or `textSecondary`;
     - pass `onDark: true` to their `StatusBadge`s;
     - fix "N left" on black (today 4.39).
  4. Mark each remaining brand-colored text foreground that sits on dark chrome with a trailing `// on-dark` comment. Mark the wordmark fallback `Text("PhotoDuck")` (`DuckComponents.swift:53`) with `// logotype`. The lint (Tests) requires one of the two markers. On the baseline tree the lint heuristic flags 26 lines. On dark chrome: `PhotoGroupDetailView.swift:77` and `:324`, which stay brand-colored with the marker. The rest are on light surfaces and switch to text tokens, including `SwipeModeView.swift:300` and `:324` on the blush completion screen.
- **Edge cases:**
  - `.foregroundStyle(.white, Color.danger)` palette symbols (the grid check marks) are icons and stay.
  - `PrimaryMetricCard` values are ≥ 24 pt (large text, 3:1), but they use `tone.text` anyway.
  - Leave the wordmark fallback as is (logotype exemption).

**WS-56.4 — Real 44 pt hit areas (FSB-09)**
- **Change:** create `iOSCleanup/Views/Components/DuckControls.swift`:
  ```swift
  struct DuckChipButtonStyle: ButtonStyle {
      enum Variant { case pill(isSelected: Bool), outline, text }
      var variant: Variant
      var tone: DuckTone = .accent
      func makeBody(configuration: Configuration) -> some View {
          configuration.label
              .font(.duckCaption.weight(.semibold))
              .monospacedDigit()
              .padding(.horizontal, horizontalPadding)          // DuckSpace.m / DuckSpace.s / DuckSpace.xs
              .frame(minHeight: 44)
              .foregroundStyle(foreground)                      // pill selected → .white; pill → DuckTone.secondary.text; else tone.text
              .background { background }                        // pill selected: Capsule().fill(tone.labelFill); pill: Capsule().fill(Color.surface); outline: Capsule().strokeBorder(tone.text, lineWidth: 1)
              .contentShape(Capsule())
              .opacity(configuration.isPressed ? 0.7 : 1)
      }
  }
  /// Text-link control label whose tappable area is at least 44 pt tall.
  struct DuckTextLinkLabel: View {
      let title: String
      var tone: DuckTone = .secondary
      var font: Font = .duckCaption
      var body: some View {
          Text(title).font(font).foregroundStyle(tone.text)
              .padding(.horizontal, DuckSpace.xs).frame(minHeight: 44).contentShape(Rectangle())
      }
  }
  ```
  Apply it everywhere a control sized itself from outside:
  - **Filter pills.** In WS-50's `filterPills(p)`: `Button { activeFilter = pill } label: { Text("\(pill.rawValue) \(p.countByFilter[pill, default: 0].formatted())") }.buttonStyle(DuckChipButtonStyle(variant: .pill(isSelected: activeFilter == pill)))`. Keep the `.isSelected` trait, and delete the "≥44pt target" comment. WS-45's sort `Menu` in the same row gets its padding and frame inside its label.
  - **Pause/Continue:** `.buttonStyle(DuckChipButtonStyle(variant: .outline))`.
  - **"See all":** `.buttonStyle(DuckChipButtonStyle(variant: .text))`.
  - **Home "Unlock":** move padding and background into the `label:`. Use `DuckChipButtonStyle(variant: .text)` or a label-internal capsule; keep the look. WS-36 already routes it through the policy.
  - **Paywall.** WS-48 already points the links at `PrivacyPolicyView()` and `PhotoDuckLinks.termsOfUse`.
    - `Button { … } label: { DuckTextLinkLabel(title: "Restore Purchase") }`;
    - `NavigationLink { PrivacyPolicyView() } label: { DuckTextLinkLabel(title: "Privacy Policy") }`;
    - `Link(destination: PhotoDuckLinks.termsOfUse) { DuckTextLinkLabel(title: "Terms of Use") }`;
    - "Try Again" uses the same pattern.
  - **Onboarding "Skip for now":** `Button(action: onNext) { DuckTextLinkLabel(title: "Skip for now") }`.
  - **Group detail fullscreen button:** move `.frame(width: 44, height: 44)` inside the label around the 32 pt circle, and add `.contentShape(Circle())`.
  - **Video player and progress status views:** apply the same fix to "Try Again" and to "Cancel Export". WS-57 touches that view later and keeps this.
  - **`continueToExportBar`:** wrap the `Button` in a `VStack(spacing: 0) { … }` that carries the `.padding(.horizontal, 16).padding(.vertical, 8).background(.ultraThinMaterial)`. The button keeps `.buttonStyle(.plain)` and its hint, and the look is unchanged.
  - Any further offender the new lint finds, including WS-48's `HelpAndPrivacyMenu` if its frame ended up outside the label.
- **Edge cases:**
  - `.buttonStyle` replaces the default style's pressed highlight. The style supplies its own.
  - Keep `.accessibilityAddTraits` and hints at the call sites.
  - Toolbar items (`ToolbarItem { Button("Done") }`) get system hit areas and are not touched.

**WS-56.5 — Plurals and user language (FSB-10)**
- **Change:**
  1. `CountText` (WS-31) gains `files(_:)` if it is missing; `items(_:_:_:)` covers the rest.
  2. Fix every hit of the plural lint regex (Tests) under `Views/` and `Engines/` with `CountText`, including `HomeViewModel.swift` strings that still exist. Do not reword sentences beyond pluralization.
  3. New file `iOSCleanup/Engines/PhotoScanStatusText.swift`:
     ```swift
     enum PhotoScanStatusText {
         static let preparing = "Getting ready to check your photos…"
         static let checking = "Checking photos…"
         static let checkingNew = "Checking new photos…"
         static let all = [preparing, checking, checkingNew]
     }
     ```
     `PhotoScanEngine` uses `checking` in place of "Analyzing the next bounded photo batch…". It uses `preparing` for "Preparing the first photo batch…" (full scan) and `checkingNew` for "Restored saved results. Waiting for the next local or iCloud photo…" (incremental). These three string literals are the only engine edit. Re-find them by text if WS-24 or WS-53 moved them.
  4. `FileScanEngine.statusMessage(…)` becomes internal and drops the cache-hit suffix:
     - in progress: `"Checked \(processed.formatted()) of \(CountText.videos(total))"`;
     - complete: `"Checked \(CountText.videos(total))"`.

     `cacheHitCount` stays in `FileScanProgress` and in diagnostics (`cache_hits`).
  5. New file `iOSCleanup/Views/Photos/PhotoResultsHeroText.swift`:
     ```swift
     enum PhotoResultsHeroText {
         static func make(visibleGroupCount: Int, reviewPhotoCount: Int,
                          suggestedRemovalCount: Int) -> (title: String, value: String, detail: String) {
             ("Review", CountText.groups(visibleGroupCount),
              "\(CountText.photos(reviewPhotoCount)) · \(suggestedRemovalCount.formatted()) suggested to remove")
         }
     }
     ```
     - WS-50's `heroCard(p)` uses it with `visibleGroupCount: p.filtered.count`, `reviewPhotoCount: p.currentReviewCount` and `suggestedRemovalCount: p.currentDeletableCount` (today's "N / M groups shown" and "… move candidates" inputs). It keeps its progress value, `p.filtered.count / groups.count`.
     - The metric-row `StatPill`s in `metricRow(p)` use `CountText` ("Current set" → `CountText.photos(p.currentReviewCount)`).
- **Edge cases:**
  - Status strings are user-visible only through `scanActivityMessage`. Diagnostics never log them (invariant 26).
  - Leave `PhotoDuckDiagnosticReportEnvelope.privacyNotice` alone ("Diagnostic history is bounded" is plain English in a shared file, not UI).

**WS-56.6 — One token set, no dead components (FSB-11)**
- **Change:**
  1. Delete `DuckSpacing` and `DuckCornerRadius` from `Font+PhotoDuck.swift`.
  2. Keep `DuckSpace` and use it in every component this workstream writes or edits (`DuckControls.swift`, `StatusBadge`, `DuckOutlineButton`). It then has uses and is the single spacing scale. Do not sweep untouched views; the design handoff will.
  3. Delete `BestShotBadge`. The grid badge keeps its own style, and switching to `BestShotBadge`'s gradient would be a redesign.
  4. Replace the 18 raw radii:

     | Today | Replacement |
     |---|---|
     | `cornerRadius: 50` (`DuckOutlineButton`, `DuckToast`) | `Capsule(style: .continuous)` |
     | `cornerRadius: 4` / `5` on 6–10 pt bars (`DuckProgressBar`, the shell hero bar, the Home storage bar) | `Capsule()` |
     | `cornerRadius: 9`, `10`, `12` on icons and thumbnails (shell stat icon, Home CTA icon tile, category thumbnail, Auto-clean thumbnail, compare thumbnail) | `DuckRadius.s` |

  5. Check that `VideoCompressionStartGateTests` exists (WS-36.7, in `CleanupAccessPolicyTests.swift`). If WS-36 landed without it, add it there exactly as WS-36 specifies: busy → `.ignore`, locked → `.requestUnlock(.videoCompression)`, allowed → `.start`.

**WS-56.7 — Docs**
- In `CLAUDE.md` "Design tokens":
  - list the text tokens and `DuckTone` (brand vs text vs textOnDark vs labelFill);
  - "Text on light surfaces uses `*Text` tokens, text on dark chrome uses white or brand colors, and white labels sit only on `labelFill`/CTA stops, all enforced by `DesignContrastTests`";
  - "Controls size inside their label (`DuckChipButtonStyle`, `DuckTextLinkLabel`), enforced by `DesignLintTests`";
  - "Counts go through `CountText`";
  - "`DuckRadius` and `DuckSpace` are the only radius and spacing tokens".
- Remove `DuckSpace` from any "unused" wording.

### Tests
All run in the simulator.
- **`iOSCleanupTests/DesignContrastTests.swift`** (*new*):
  - `testTokensResolveOpaque`: every `DuckTone` color and the five new statics resolve with alpha 1. This catches a missing colorset.
  - `testTextOnLightSurfacesMeetsAA`:
    - `DuckTone.allCases.map(\.text)`, plus `Color.textPrimary` and `Color.textSecondary`;
    - over `backgroundBlush`, `surface`, `surfaceElevated` and `Color.white`;
    - every pair ≥ 4.5.
  - `testBadgesMeetAA`:
    - light: for each tone, `badgeText` over `brand` composited at `badgeTintOpacity` onto blush, surface and surfaceElevated, ≥ 4.5;
    - dark: `textOnDark` over `brand` at `darkBadgeTintOpacity` onto `Color.black` and `berryBlack`, ≥ 4.5, for `.accent`, `.success`, `.warning` and `.secondary`.
  - `testTextOnDarkChromeMeetsAA`: `DuckTone.allCases.map(\.textOnDark)` and `Color.white.opacity(0.75)` over black and berryBlack, ≥ 4.5.
  - `testWhiteLabelsOnFillsMeetAA`: white over every `LinearGradient.duckPrimaryCTAStops` stop and every `DuckTone.labelFill`, ≥ 4.5. **This is the D-CONTRAST option-1 test.** Delete it only under option 2.
  - Each failure message names the pair and the ratio with two decimals.
- **`iOSCleanupTests/Support/SwiftSourceScanner.swift`** (*new*), shared by the new lint rules:
  ```swift
  enum SwiftSourceScanner {
      static var repoRoot: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent()   // Support/
          .deletingLastPathComponent().deletingLastPathComponent() }                            // repo root
      static func swiftFiles(under relative: String) throws -> [URL]    // XCTSkip if the directory is absent
      static func lines(of url: URL) throws -> [String]
      /// Chained modifiers of every control expression. Indentation-based, matching this repo's
      /// Xcode formatting, where modifiers after a trailing closure sit at the SAME indent as the call:
      /// - start = a line matching ^(\s*)(Button|NavigationLink|Link|Menu)\s*[({]; i = its indent.
      /// - If the start line ends with "{", "(" or ",": skip blank lines and lines indented deeper
      ///   than i. A line at indent i starting with "}" or ")" is the closing line, but if it ends
      ///   with "{" or "(" (e.g. "} label: {"), keep scanning to the next closing line.
      ///   Otherwise (one-line call) the start line is the closing line.
      /// - Modifiers = the consecutive lines after the closing line whose indent is >= i and whose
      ///   trimmed text starts with ".". Stop at the first line that is not such a modifier.
      static func controlModifierChains(in lines: [String]) -> [(line: Int, modifiers: [String])]
  }
  ```
  A Python dry run of exactly this algorithm on the baseline tree flagged the 11 lines listed in Current behavior and nothing else. Reproduce that in the first commit before fixing anything.
- **`DesignLintTests`** (new rules; every allowlist starts empty):
  - `testControlsSizeInsideTheirLabel`: no control's modifier chain contains `.padding(` or `.frame(`. `.background(`, `.overlay(` and `.disabled(` are allowed; they do not shrink the hit area when sizing is inside the label. On the baseline tree it reports the 11 offenders listed above (fewer if WS-48 already replaced the diagnostics `Menu`), so run it first and check that.
  - `testNoBrandColorTextOnLightSurfaces`:
    - flag a line with `.foregroundStyle(` or `.foregroundColor(` naming `accentPrimary`, `warning`, `success` or `danger` (with or without the `Color.` prefix);
    - flag it only when the nearest preceding line (up to 4) that constructs a view contains `Text(`, `Label(`, `Button(`, `Link(` or `NavigationLink(` (not `Image(`);
    - skip lines ending in `// on-dark` or `// logotype`.
  - `testCountsArePluralized`: the regex `#"\\\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\)\s(?:photos|groups|videos|screenshots|items|files)\b"#` over `Views/**` and `Engines/**` has no match.
  - `testNoInternalJargonInUserStrings`: no string literal (`"[^"\n]*\bbounded\b[^"\n]*"`) under `Views/**` or `Engines/**`.
  - `testSingleTokenSet`: `enum DuckSpacing`, `enum DuckCornerRadius`, `DuckSpacing.`, `DuckCornerRadius.` and `struct BestShotBadge` appear nowhere under `iOSCleanup/`.
  - `testNoRawCornerRadiusLiterals`: `cornerRadius:\s*[0-9]` under `Views/**` has no match.
  - Move `scanViews` onto `SwiftSourceScanner` so every rule shares one walker. Existing rules keep their assertions.
- **`iOSCleanupTests/CopyTextTests.swift`** (*new*):
  - `testCountTextSingularPluralAndGrouping`: 0 photos, 1 photo, 2 photos, 1,234 photos, 1 file. If WS-31 created `CountTextTests`, extend that file instead.
  - `testScanStatusTextIsPlainLanguage`: no entry of `PhotoScanStatusText.all` contains "bounded" or "batch".
  - `testFileScanStatusHasNoCacheWordingAndPluralizes`: "Checked 1 video" and "Checked 3 of 120 videos", with no "saved sizes".
  - `testResultsHeroText`: counts 1/1/0 give "1 group", "1 photo · 0 suggested to remove".

### Acceptance criteria
- [ ] `DesignContrastTests` pass. The PR states which D-CONTRAST option the owner confirmed. Under option 2, WS-56.2 is absent and `testWhiteLabelsOnFillsMeetAA` is deleted.
- [ ] Accessibility Inspector's color-contrast audit reports no failures on Home, Similar, Group detail, Duck Mode (cards and completion) and Paywall (simulator is fine; screenshots of the audit in the PR).
- [ ] Accessibility Inspector shows hit areas of at least 44×44 pt for the filter pills, Pause/Continue, See all, Unlock, Restore, Privacy Policy, Terms, Try Again, Skip for now and Cancel Export. Tapping the capsule edge of a pill changes the filter.
- [ ] No UI string shows "1 photos", "1 groups", "1 videos" or "bounded", and the lint rules enforce it. The Home CTA subtitle during a scan reads "Checking photos…".
- [ ] `DuckSpacing`, `DuckCornerRadius` and `BestShotBadge` are gone. There are no raw `cornerRadius:` literals under `Views/`, and `DuckSpace` has uses.
- [ ] `VideoCompressionStartGateTests` exists and passes.
- [ ] The full suite is green, there are no new warnings, new files are in `project.pbxproj`, and `CLAUDE.md` is updated.

### Device QA
Add under "Legibility (WS-56)":
1. **DQA-A11Y-56.1:** outdoors at full brightness, read the Home CTA, the group detail action bar, Duck Mode's Delete/Keep and the paywall links. Everything is readable. Record any complaint with a screenshot.
2. **DQA-A11Y-56.2:** with Settings › Accessibility › Display › Increase Contrast on, Home, Duck Mode and Paywall stay legible, and no text disappears into its background.
3. **DQA-A11Y-56.3:** in the Accessibility Inspector hit-area overlay (device or simulator), tap the extreme left and right edges of each filter pill and of Pause/Continue. All respond.

### Pitfalls and out of scope
- **Never apply `*Text` tokens on dark chrome.** They fail there, as the Current behavior section shows. The dark rule is part of the contract, not a nicety.
- Do not change fonts, layout, copy tone or component shapes (invariant 29). Duck Mode, Files, Paywall and Onboarding redesigns wait for the handoff.
- Do not change `accentPrimary`'s value. The brand pink stays for fills, icons, glows and the tab tint.
- The plural sweep must not touch `CleanupState` persistence keys or diagnostics payloads (invariant 26).
- **Reconciliation:**
  - D-CONTRAST is amended here (README §9 contract 20): the dark-chrome rule (`DuckTone.textOnDark`) and the white-on-danger/success Duck Mode fills. The README decision text already says so, so WS-56.2's fills are no longer a separate owner DECISION.
  - `PhotoResultsView` edits go through WS-50's `PhotoResultsPresentation` (`p.countByFilter`, `p.filtered`, `p.currentReviewCount`, `p.currentDeletableCount`).
  - `VideoCompressionStartGate` and `VideoCompressionStartGateTests` are WS-36.7's; they are verified here, not rebuilt.
- **Belongs elsewhere:**
  - the export progress copy and the "Stopping…" state: WS-57;
  - the App Store IAP text: WS-58;
  - the Duck Mode and Onboarding visual redesign: the handoff.

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| FSB-08 | partially | Every ratio recomputes exactly. The proposed fix is incomplete and would regress two cases. First, the text tokens fail on dark chrome (accentText 3.46 on black, and the new DuckRose 3.76 on black versus 4.85 today), so a dark-chrome rule and a `DuckTone.textOnDark` role were added. Second, `StatusBadge`'s 14% self-tint drops text tokens below 4.5, so the tint is 6% and secondary badges use textPrimary. The CTA gradient must go accentText → #A8336F; the reviewer's "accentText → accentDeep" leaves a 4.18 stop. The white-on-danger/success Duck Mode buttons and the Keeper badge (4.04 / 3.38) were added (D-CONTRAST amendment, README §9 contract 20). The wordmark fallback is a logotype and is left alone. Tests use `UIColor(Color)` resolution of the actual statics, plus a brand-text lint. |
| FSB-09 | confirmed | All five cited sites are verified, and a source scan found six more (Unlock, the diagnostics Menu, the fullscreen button, the video "Try Again", the paywall "Try Again", "Cancel Export"). The lint is broadened from "inline-title Buttons" to every `Button`/`NavigationLink`/`Link`/`Menu` expression (inline or `label:` form), using an indentation-based scanner, because label-form buttons had the same defect. |
| FSB-10 | partially | 42 unpluralized interpolations exist today (lint regex). The reviewer's regex misses `\(x.formatted()) photos`; the replacement handles nested parentheses. The completion sheet, hero, CTA and notification strings are rewritten by WS-31, and the "Tap to pause" variant by WS-45 (the CTA never pauses), so those items are stale by dependency. The engine jargon, Files status and results hero are handled here. The Files status also said "Checked 1 videos", which is fixed. |
| FSB-11 | partially | Items 1–3 are confirmed: 0 uses of `DuckSpace`/`DuckSpacing`/`DuckCornerRadius`, 18 raw radii, and an unused `BestShotBadge`. `DuckSpace` is kept and adopted in the components this workstream edits; `BestShotBadge` is deleted (reusing it would be a redesign). Item 4 (the `VideoCompressionView` entitlement guard) is delivered by WS-36.7, so it is stale by dependency and only verified here. |

---

## WS-57 — Export resilience

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M3 | L | WS-35 | no | `ws/57-export-resilience` |

**Primary files:**
- **Engines:**
  - `iOSCleanup/Engines/ExternalPhotoExportService.swift` (loop edits only);
  - new: `iOSCleanup/Engines/ExportDestinationPolicy.swift` (error classifier, destination probe, `ExternalPhotoExportCapacity` moved here), `iOSCleanup/Engines/ExportResourceSizing.swift`, `iOSCleanup/Engines/ExportLiveActivityController.swift` (moved out of the service file), `iOSCleanup/Engines/PendingExportStore.swift`;
  - `iOSCleanup/Engines/ExportResultNotes.swift` (WS-05).
- **Shared model:** `iOSCleanup/Models/ExportActivityAttributes.swift`.
- **Views:**
  - `iOSCleanup/Views/Files/ExternalExportCoordinator.swift`;
  - `iOSCleanup/Views/Export/ExternalPhotoExportProgressStatusView.swift`;
  - new: `iOSCleanup/Views/Export/ExternalPhotoExportProgressText.swift`, `iOSCleanup/Views/Export/InterruptedExportBanner.swift`, `iOSCleanup/Views/Export/ResumeExportView.swift`;
  - `iOSCleanup/Views/Export/ExportAlbumView.swift`, `iOSCleanup/Views/Files/FileResultsView+Export.swift`, `iOSCleanup/Views/Files/LargeVideoExportSummary.swift`, `iOSCleanup/Views/HomeView.swift` (one banner line).
- **App and widget:** `iOSCleanup/iOSCleanupApp.swift`, `PhotoDuckWidgets/ExportLiveActivityWidget.swift`, `PhotoDuckWidgets/README.md`.
- **Tests:** `iOSCleanupTests/ExternalPhotoExportServiceTests.swift`, `iOSCleanupTests/ExternalExportCoordinatorTests.swift`, `iOSCleanupTests/Support/FakeExportResourceSource.swift`; new: `iOSCleanupTests/ExportDestinationPolicyTests.swift`, `iOSCleanupTests/ExportProgressTests.swift`, `iOSCleanupTests/ExportLiveActivityTests.swift`, `iOSCleanupTests/PendingExportStoreTests.swift`.
- **Project and docs:** `iOSCleanup.xcodeproj/project.pbxproj`, `CLAUDE.md`, `docs/DEVICE_QA.md`.

**Findings covered:** FILES-15 (P2, partially), FILES-16 (P2, partially), FILES-17 (P2, confirmed). For FILES-15 and FILES-16 this workstream covers **only the parts WS-05 did not already remove**. WS-05.3 deletes `writeDirect` and its `writeResumable` retry, which closes FILES-15's "skip the retry" item and FILES-16 item 2 (the uncancellable `writeData`). The rest is here: error classification and stop reasons, the preflights, per-resource expected sizes, the cancelling state and the help text.

**Decisions applied:**
- **D-BACKUP:** the pending-export record lives in `Application Support/PhotoDuck` (backup-excluded via `PhotoDuckStorage`). It holds device-specific asset IDs and a bookmark.
- **D-EXPORT-DELETE:** a resumed export may offer verified deletion for free, through WS-35's offer.
- **D-UNDO:** deletion stays behind WS-35's offer and the iOS prompt.
- **D-BACKGROUND / D-MIN-OS:** continued processing for exports is optional (WS-57.7), behind `#available(iOS 26, *)`, and reuses WS-29's pattern.
- **Invariant 24:** copy → verify (hash) → manifest → explicit delete. Nothing in this workstream may make an item deletion-eligible that WS-05 would not.

### Goal
- A drive that fills up stops the export at the first write error. The rest are reported as "not attempted", with one clear message. No further iCloud downloads start.
- A file larger than the drive's format allows is skipped with FAT32 guidance, before it is downloaded when its size is known.
- Tapping Cancel shows "Stopping…" at once, and a downloading item stops within about a second.
- Byte labels never show a total smaller than the bytes copied.
- When iOS suspends PhotoDuck mid-export, the Lock Screen and the Dynamic Island show a paused or stale state within about 30 s.
- After termination, the Live Activity says "Interrupted — open PhotoDuck to resume", and Home offers a one-tap Resume to the same folder, which skips verified items.

### Current behavior (verified)
The WIP (committed by WS-01) is in the tree. WS-05, WS-10, WS-29 and WS-35 restructure this code before this workstream runs; re-find by symbol.

**FILES-15 (no destination errors are classified)**
- `ExternalPhotoExportService.swift:642-648`: the per-item free-space preflight was removed ("The destination's real writer remains authoritative").
- `:763-789`: the generic `catch` records a failure and runs `continue assetLoop` for any error, ENOSPC included.
- `ExternalPhotoExportCapacity` (`:336-368`) is used only by tests (`FileScanEngineTests.swift:1454-1510`). WS-05 keeps it for this workstream.
- `write()` (`:1152-1208`) retries a failed `writeDirect` through `writeResumable`.
- **WS-05.3 deletes `writeDirect` and that retry,** so that part of the finding is stale after WS-05.
- No code reads `volumeMaximumFileSizeKey` or inspects `ENOSPC`/`EFBIG`.

**FILES-16 (Cancel and progress)**
- Today `writeDirect` (`:1251-1299`) uses `writeData(for:toFile:)`, which cannot be cancelled. After WS-05 every resource streams through `resourceSource.requestData`, whose cancel path calls `cancelDataRequest` (WS-05.1/.2; its splice test cancels a held request).
- Per-resource expected bytes are `asset.estimatedFileSize` for every resource of an asset (`:680`, `:706`), and `min(byteFraction, 0.99)` caps the fraction (`:703`). After WS-35's archival exports, an asset has several resources (original, render, adjustment data), so the per-file label is wrong for most of them.
- `ExternalPhotoExportProgressStatusView` (today `HomeView.swift:1293-1367`; WS-10 moves it):
  - prints "\(copied) of \(expected)" even when copied exceeds expected;
  - clamps the percent at 99;
  - has no cancelling state; "Cancel Export" is a text-only button.
- The help text says "Cancel stops the current item… choose the same destination again to resume" (`HomeView.swift:1813-1814`, `FileResultsView.swift:849-851`).

**FILES-17 (Live Activity and interruption)**
- **Expiration handler.** `HomeView.swift:1846-1858` (`FileResultsView.swift:1156-1167` is the twin; both are in `ExternalExportCoordinator` after WS-10). It runs `Task { @MainActor in await liveActivity.markPaused() }` and then calls `endBackgroundTask` immediately, so the process can suspend before the Task runs.
- **Stale dates** (`ExportLiveActivityController`, `ExternalPhotoExportService.swift:1671-1850`): `start` and `update` use a stale date of 5 minutes (`:1704`, `:1755`), and `markPaused` uses 2 minutes (`:1773`). A suspended export therefore reads "Exporting 37%" for up to 5 minutes.
- **Scene phase.** `.onChange(of: scenePhase)` (`HomeView.swift:1569-1586`) does nothing on `.background` and only resumes on `.active`.
- **Widget.** `PhotoDuckWidgets/ExportLiveActivityWidget.swift:95-99` checks `context.isStale` on the Lock Screen only. The Dynamic Island expanded regions (`:18-47`), `compactTrailing` (`:52-55`) and `minimal` (`:56-60`) ignore it.
- **Orphans at launch.** `iOSCleanupApp.swift:30-33` calls `ExportLiveActivityController.endOrphanedActivities()`, which ends every activity with phase `.cancelled` and `.immediate` dismissal (`:1832-1848`).
- **No bookmark.** Nothing persists the destination or the request. The picker URL (`ExternalFolderPicker`) is used once; the service starts and stops security-scoped access itself (`:489-493`).
- **Shared model.** `ExportActivityAttributes.swift:36` reads "\(totalFileCount) files exported and verified" ("1 files"). The widget README says exports pause after ~30 s (`PhotoDuckWidgets/README.md:12-14`).
- `ExternalPhotoExportSessionGate` (`:251-268`) has no `isHeld` accessor.

### Implementation plan
Commit per task, in this order. The suite must be green after each.

**WS-57.1 — Move the Live Activity controller (pure move)**
- Move `ExportLiveActivityController` from `ExternalPhotoExportService.swift` to the new `iOSCleanup/Engines/ExportLiveActivityController.swift`, unchanged. Also move `ExternalPhotoExportCapacity` to the new `ExportDestinationPolicy.swift`.
- Add `var isHeld: Bool { activeToken != nil }` to `ExternalPhotoExportSessionGate`.

**WS-57.2 — Fail fast on a full, read-only or too-small destination (FILES-15)**
- **Change:**
  1. In `ExportDestinationPolicy.swift`:
     ```swift
     enum ExternalPhotoExportStopReason: String, Equatable, Sendable { case destinationFull, destinationReadOnly }

     enum ExportWriteDisposition: Equatable, Sendable {
         case stopRun(ExternalPhotoExportStopReason)   // ENOSPC, EDQUOT, fileWriteOutOfSpace, EROFS, fileWriteVolumeReadOnly
         case itemTooLarge                              // EFBIG, or the preflight below
         case itemFailed
     }
     enum ExportWriteErrorClassifier {
         /// Walks the NSError / NSUnderlyingErrorKey chain (max depth 4). Checks POSIX codes
         /// (ENOSPC 28, EDQUOT 69, EFBIG 27, EROFS 30) and CocoaError codes 640 (.fileWriteOutOfSpace)
         /// and 642 (.fileWriteVolumeReadOnly).
         static func classify(_ error: Error) -> ExportWriteDisposition
     }
     protocol ExportDestinationProbing: Sendable {
         func maximumFileSize(at directoryURL: URL) -> Int64?          // positive .volumeMaximumFileSizeKey, else nil
         /// Only when the destination's .volumeIdentifierKey and FileManager.temporaryDirectory's are both
         /// non-nil and differ (so the reading is the drive's own). Then
         /// ExternalPhotoExportCapacity.firstTrustedCapacity([.volumeAvailableCapacityKey reading]).
         func trustedAvailableCapacity(at directoryURL: URL) -> Int64?
     }
     struct FileSystemExportDestinationProbe: ExportDestinationProbing { … }
     ```
     Compare volume identifiers with `(a as? NSObject)?.isEqual(b) == true`. `volumeAvailableCapacityKey` is DiskSpace, already declared (`E174.1`); `volumeMaximumFileSizeKey` and `volumeIdentifierKey` are not required-reason APIs. Run `PrivacyManifestLintTests`.
  2. `ExternalPhotoExportService.init` gains:
     - `destinationProbe: any ExportDestinationProbing = FileSystemExportDestinationProbe()`;
     - `measuredCurrentVersionBytes: @Sendable ([AssetFileSizeCacheKey]) async -> [String: Int64]`. The default reads WS-30's `AssetFileSizeRepository.records(for:)` and keeps only `provenance == .measuredCurrentVersion` (this also feeds WS-57.3). `export()` calls it once for the pending assets.
  3. Add `ExternalPhotoExportError.fileTooLargeForDestination(filename: String, limitBytes: Int64)`. Its message is "This drive's format can't store files larger than \(ByteText.stat(limitBytes)), so \(filename) was skipped. Reformat the drive as exFAT or APFS to export it." The classifier maps it to `.itemTooLarge`. Also use this message for an EFBIG from the writer when the limit is unknown ("…larger than 4 GB…").
  4. In `writeAssets` (WS-05's per-resource flow):
     - **Before an asset's first resource:** if `probe.trustedAvailableCapacity(at:)` is non-nil **and** the asset has a measured size, and `!ExternalPhotoExportCapacity.hasCapacity(estimatedAssetBytes: measured, availableBytes: available)`: set `stopReason = .destinationFull`, append this and every later asset ID to `notAttemptedAssetIDs`, and `break assetLoop`. Never use estimated sizes here: a false refusal is worse than a late ENOSPC.
     - **Before `streamResource`:** if `probe.maximumFileSize(at:)` is known and `ExportResourceSizing.expectedByteCount(…)` exceeds it, throw `.fileTooLargeForDestination` without calling `requestData`.
     - **In the generic `catch`** (after WS-05's `ExportPartialStore.discard` and sibling rollback, both unchanged), switch on `ExportWriteErrorClassifier.classify(error)`:
       - `.stopRun(let reason)`: record this item's failure ("The drive is full." or "The drive is read-only."), set `stopReason`, append the remaining asset IDs to `notAttemptedAssetIDs`, `break assetLoop`;
       - `.itemTooLarge` and `.itemFailed`: record the failure and `continue assetLoop`, as today.
     - Classify errors from `ExportPartialStore.prepare` (sidecar write) the same way.
  5. `ExternalPhotoExportResult` gains `var stopReason: ExternalPhotoExportStopReason? = nil` and `var notAttemptedAssetIDs: [String] = []`. Neither changes `deletionEligibleAssetIDs`.
  6. `ExportResultNotes.supplementaryNotes` (WS-05) prepends, when `stopReason != nil`:
     - "The drive is full. \(n) item(s) weren't attempted — free up space on the drive or choose another one, then export again.";
     - or "The drive is read-only, so the export stopped. \(n) item(s) weren't attempted."

     Use `CountText` (WS-31); it exists by numeric order. If it is absent, use an explicit ternary.
  7. **UI:**
     - `ExportAlbumView`'s status and WS-35's `LargeVideoExportSummary` titles use "Export Stopped — Drive Full" or "Export Stopped — Drive Read-Only" when `stopReason != nil`.
     - `remainingIDs` already includes not-attempted items (requested − verified), so they stay selected.
     - The coordinator ends the Live Activity with `.failed` when `stopReason != nil`.
- **Edge cases:**
  - Journal appends and the final manifest write can also hit ENOSPC. WS-05 already turns those into record warnings and treats a failed journal append as not deletion-eligible. Do not change that.
  - A run stopped before any item is attempted has `requestedAssetCount == selection` (WS-35) and no failures.
  - Unplugging the drive mid-export: record the error codes in Device QA step 6. If each remaining item fails one by one, add a BACKLOG entry; do not guess codes.

**WS-57.3 — Honest per-file progress and a visible "Stopping…" (FILES-16)**
- **Change:**
  1. `ExportResourceSizing.swift`:
     ```swift
     enum ExportResourceSizing {
         /// The resource PhotoDuck measured (the current version): .fullSizeVideo when present, else .video.
         static func measuredResourceType(among types: [PHAssetResourceType]) -> PHAssetResourceType?
         static func expectedByteCount(for type: PHAssetResourceType, among types: [PHAssetResourceType],
                                       measuredCurrentVersionBytes: Int64?) -> Int64?   // nil for every other resource
         /// downloadFraction: PhotoKit's progressHandler value (0 for local data).
         static func progress(downloadFraction: Double, bytesWritten: Int64,
                              expected: Int64?) -> (fileFraction: Double, bytesExpected: Int64?) {
             if let expected, expected > 0, bytesWritten <= expected {
                 return (min(max(downloadFraction, Double(bytesWritten) / Double(expected)), 0.99), expected)
             }
             return (min(max(downloadFraction, 0), 0.99), nil)   // unknown or exceeded → bytes only
         }
     }
     ```
     The service's per-resource progress closure uses it, with no other `0.99` cap.
  2. `ExternalPhotoExportProgressStore` gains `@Published private(set) var isCancelling = false`, `func markCancelling()` and a reset in `reset()`. `ExternalExportCoordinator` gains `func markCancelling()`, which forwards to the store. Both views' Cancel handlers call it before cancelling their `Task`.
  3. New `iOSCleanup/Views/Export/ExternalPhotoExportProgressText.swift`:
     ```swift
     enum ExternalPhotoExportProgressText {
         static func label(progress: ExternalPhotoExportProgress?, bytesPerSecond: Double?, isCancelling: Bool) -> String
         // isCancelling → "Stopping… Verified items stay on the drive."
         // nil → "Preparing export…"
         // file with expected → "X of Y · S/s · P%\nFile i of n · name"
         // file without expected → "X copied · S/s\nFile i of n · name"  (no percent)
         // between files → "\(completed) of \(CountText.items(total, "file", "files")) done · verifying…"
         static let cancelHelp = "Cancel stops the export within a few seconds. Verified items stay on the drive, and an interrupted export can be resumed from Home."
     }
     ```
     - `ExternalPhotoExportProgressStatusView` renders `label(…)`.
     - Its button is `Button(role: .destructive) { onCancel() } label: { DuckTextLinkLabel(title: store.isCancelling ? "Stopping…" : "Cancel Export", tone: .danger) }.disabled(store.isCancelling)`. `DuckTextLinkLabel` is WS-56's; if WS-56 is absent, size inside the label directly.
     - Both call sites pass `ExternalPhotoExportProgressText.cancelHelp` instead of their own strings.
- **First step (device):** DQA-EXPORT-57.2 confirms that cancelling a downloading iCloud-only video stops the network transfer within about a second through `cancelDataRequest`. If it does not, keep the "Stopping…" state until the request completes, and change `cancelHelp` to "Cancel stops after the current file."
- **Edge cases:** the Live Activity keeps using `overallFraction`, which is unaffected by the per-file expected size.

**WS-57.4 — Live Activity staleness, the Dynamic Island and an `.interrupted` phase (FILES-17 items 1–2)**
- **Change:**
  1. `ExportLiveActivityController.swift`:
     ```swift
     enum ExportLiveActivityStalePolicy {
         static let foregroundInterval: TimeInterval = 5 * 60
         static let backgroundInterval: TimeInterval = 25    // expires before iOS's ~30 s grace ends
         static func staleDate(now: Date, isAppActive: Bool) -> Date
     }
     ```
     - The controller gains `private var isAppActive = true` and `func setAppActive(_ active: Bool) async`. That function stores the flag and re-sends the last state with the new stale date; it is a no-op when there is no activity.
     - `start`, `update` and `markPaused` all use `staleDate(now:isAppActive:)`. While in the background, each throttled update rolls the stale date forward by 25 s. If iOS suspends the app, the activity turns stale on its own, with no expiration-handler race.
  2. `ExternalExportCoordinator` gains `func scenePhaseChanged(_ phase: ScenePhase)`:
     - `.background` while running → `await liveActivity.setAppActive(false)`;
     - `.active` → `setAppActive(true)`, then the existing resume, then WS-35's `sceneBecameActive()`.

     `ExportAlbumView` and `FileResultsView` forward their existing `.onChange(of: scenePhase)` to it instead of calling the Live Activity directly. Keep the expiration handler's `markPaused()`; it is best effort now.
  3. `ExportActivityAttributes.swift` (compiled into both targets):
     - add `case interrupted` to `Phase` (statusLine "Interrupted — open PhotoDuck to resume");
     - pluralize `.finished` ("\(n) file(s) exported and verified") with an inline ternary; the widget does not link `CountText`;
     - add a shared presentation extension so the widget and the app tests use one source:
     ```swift
     extension PhotoDuckExportActivityAttributes.ContentState {
         func title(isStale: Bool) -> String          // stale && .exporting → "Export paused"
         func detailLine(isStale: Bool) -> String     // stale && .exporting → "Not responding — open PhotoDuck"
         func compactTrailing(isStale: Bool) -> String // stale && .exporting → "Paused", else percent
         func symbolName(isStale: Bool) -> String     // stale && .exporting → "pause.circle.fill"
         var percentText: String
     }
     ```
  4. `ExportLiveActivityWidget`:
     - replace the private `phaseTitle`, `phaseSymbol` and `percentLabel` with the shared extension, passing `context.isStale` everywhere: lock screen, expanded leading/trailing/bottom, `compactLeading`, `compactTrailing` and `minimal`;
     - add the `.interrupted` case wherever a switch needs it;
     - keep the literal brand color (the widget has no asset catalog).
- **Edge cases:** an old activity state without `.interrupted` still decodes. The new case is additive, and app and widget ship together.

**WS-57.5 — `PendingExportRecord` and orphan handling at launch (FILES-17 item 3)**
- **Change:**
  1. `iOSCleanup/Engines/PendingExportStore.swift`:
     ```swift
     struct PendingExportRecord: Codable, Equatable, Sendable {
         enum Origin: String, Codable, Sendable { case exportAlbum, largeVideos, resume }
         static let currentSchemaVersion = 1
         let schemaVersion: Int
         let id: UUID
         let origin: Origin
         let destinationDisplayName: String   // directoryURL.lastPathComponent; display only
         let bookmark: Data
         let requestedAssetIDs: [String]      // the user's selection, in order
         let startedAt: Date
     }
     protocol ExportDestinationBookmarking: Sendable {
         func makeBookmark(for url: URL) throws -> Data      // live: start access, url.bookmarkData(), stop access
         func resolve(_ data: Data) throws -> (url: URL, isStale: Bool)
     }
     struct FoundationExportDestinationBookmarking: ExportDestinationBookmarking { … }

     @MainActor
     final class PendingExportStore: ObservableObject {
         static let shared = PendingExportStore()
         static let fileName = "pending-export-v1.json"
         @Published private(set) var interruptedRecord: PendingExportRecord?
         private(set) var activeRecordID: UUID?
         init(fileURL: URL? = nil)                         // default: PhotoDuckStorage.directory() + fileName
         func loadInterruptedRecordAtLaunch() async        // once; ignored while activeRecordID != nil; corrupt/newer schema → delete file, nil
         func beginRun(_ record: PendingExportRecord) async  // atomic write off-main; activeRecordID = id; interruptedRecord = nil
         func finishRun(id: UUID) async                    // deletes the file only if it still holds `id`
         func dismissInterrupted() async                   // deletes the file; interruptedRecord = nil
     }
     ```
     Serialize file I/O through one private actor, so a `finishRun` can never be overtaken by an older `beginRun` write.
  2. **Coordinator.** `ExternalExportCoordinator.run(…)` gains `origin: PendingExportRecord.Origin` and `requestedAssetIDs: [String]`, plus injected `pendingStore: PendingExportStore = .shared` and `bookmarking: any ExportDestinationBookmarking`:
     - after acquiring the gate, build the record. If `makeBookmark` throws, log it (sanitized, invariant 26) and export without a record; resume is then unavailable for this run, and the result is otherwise unchanged;
     - `await pendingStore.beginRun(record)` before calling the export;
     - on every return path (finished, stopped, cancelled, failed), `await pendingStore.finishRun(id:)`;
     - the only way a record survives is process termination mid-run, or WS-57.7's expiry.
  3. **Launch.** In `iOSCleanupApp`, replace the orphan `.task` with:
     ```swift
     .task {
         await PendingExportStore.shared.loadInterruptedRecordAtLaunch()
         await ExportLiveActivityController.endOrphanedActivities(
             hasPendingRecord: PendingExportStore.shared.interruptedRecord != nil)
     }
     ```
     Add a pure `enum OrphanedExportActivityPolicy { static func endState(previous: ContentState, hasPendingRecord: Bool) -> (state: ContentState, dismissImmediately: Bool) }`:
     - with a record: phase `.interrupted` and the default dismissal policy;
     - without a record: `.cancelled` and `.immediate`.
- **Edge cases:**
  - Starting any new export replaces an interrupted record, and the banner disappears. **DECISION (owner may override):** only one resumable export is remembered.
  - Limited Photos access: resume exports only the IDs that still resolve.
  - WS-48's Storage & Data "Clear" need not delete this file. It is tiny and is removed on completion or dismissal.

**WS-57.6 — Resume banner and resume flow (FILES-17 item 3)**
- **Change:**
  1. `InterruptedExportBanner.swift` contains `InterruptedExportModel` (`@MainActor ObservableObject` wrapping the store and the bookmarking) and the banner view:
     - `DuckCard` with `.duckBody` "Your export to “\(name)” was interrupted." and `.duckCaption` "Resume to copy the remaining items. Items already verified are skipped.";
     - buttons "Resume" (`DuckChipButtonStyle(variant: .outline)`) and "Dismiss" (`.text`).

     Show it only when `interruptedRecord != nil && !ExternalPhotoExportSessionGate.shared.isHeld`.
  2. `HomeView`: insert `InterruptedExportBanner()` under the top bar. That is the only `HomeView` edit.
  3. Resume behavior:
     - `model.prepareResume()` resolves the bookmark. On success it presents `ResumeExportView(record:directoryURL:)` as a sheet. If the bookmark was stale, refresh it on the next `beginRun`.
     - On failure (drive not connected, folder moved), show an alert "PhotoDuck can't reach “\(name)”. Connect the drive, or choose the folder again." with "Choose Folder" (presents `ExternalFolderPicker`, then `ResumeExportView` with the picked URL) and "Cancel".
  4. `ResumeExportView`:
     - Fetch `PHAsset`s for `record.requestedAssetIDs` off the main actor with `PHAsset.fetchAssets(withLocalIdentifiers:options: PhotoLibraryFetch.identifierOptions())`, preserving order. WS-40's `PhotoFetchLintTests` rejects `options: nil` and any `PHFetchOptions()` outside `PhotoLibraryFetch.swift`.
     - Show "\(found) of \(requested) items are still in your library" when fewer resolve.
     - Own a `@StateObject ExternalExportCoordinator` and call `run(assets:to:backgroundTaskName: "PhotoDuck Export Resume", origin: .resume, requestedAssetIDs:)`. WS-05's dedupe skips verified items, and its partials resume.
     - Render `ExternalPhotoExportProgressStatusView`, then `result.supplementaryNotes`.
     - Then run WS-35's offer through `ExportDeletionScheduling.decide(offer:deleteRequestedUpFront: false, …)`.
     - **DECISION (owner may override):** a resumed export never deletes automatically, even if the interrupted run was "Export & Delete". It may only *offer* verified deletion (one confirmation plus the iOS prompt).
  5. Dismiss calls `dismissInterrupted()`.
- **Edge cases:**
  - Resume while another export runs: the coordinator returns `.busy` (WS-10), and the sheet shows the existing "Another export is already running" copy.
  - Every deletion goes through WS-35's `commit`, which uses `DeletionManager` (invariant 4).

**WS-57.7 — Optional: continued processing for exports on iOS 26**
- Do this only if WS-29.0's spike showed `BGContinuedProcessingTask` working and this PR stays under about 800 lines. Otherwise add a `spec/BACKLOG.md` entry.
- **Shape:**
  - `ExportBackgroundContinuation` conforms to WS-29's `ScanBackgroundContinuing` (same begin/update/end/expire contract), with identifier `com.photoduck.app.export.files`.
  - Add the identifier to `BGTaskSchedulerPermittedIdentifiers`, or rely on a wildcard if WS-29 registered one that covers it.
  - Register the launch handler in `iOSCleanupApp.init` behind `#available(iOS 26, *)`.
  - The coordinator begins it only for runs started by a user tap (never for auto-resume), and updates it from progress at 1 Hz.
  - On expiry: set a `keepsPendingRecord` flag, cancel the export `Task` (the partial is kept, WS-05), and do not call `finishRun`. The record stays, and the banner offers Resume.
  - Update `PhotoDuckWidgets/README.md` accordingly.

**WS-57.8 — Docs**
- `PhotoDuckWidgets/README.md`:
  - replace the "pauses after ~30 s" note with: the activity turns stale about 25 s after PhotoDuck leaves the foreground unless iOS keeps it running (and the continued-processing note if 57.7 shipped);
  - interrupted exports end as "Interrupted" and resume from Home;
  - the deployment target follows WS-06.
- `CLAUDE.md` export row:
  - ENOSPC/EROFS stop the run ("not attempted"); EFBIG and preflights skip the item with format guidance;
  - `PendingExportRecord` + resume banner; Cancel through `cancelDataRequest`;
  - the Live Activity stale policy.

### Tests
All run in the simulator with temp directories, `TestPhotoAsset` and WS-05's `FakeExportResourceSource`.
- **Fake extension** (`iOSCleanupTests/Support/FakeExportResourceSource.swift`): `register(…, failAfterChunks: Int? = nil, error: Error? = nil)` delivers `n` chunks, then calls `completion(error)`. Also `recordedCancelledRequestIDs`.
- **`iOSCleanupTests/ExportDestinationPolicyTests.swift`** (*new*):
  - `testClassifierPOSIXCodes`: ENOSPC → `.stopRun(.destinationFull)`, EDQUOT → full, EROFS → `.stopRun(.destinationReadOnly)`, EFBIG → `.itemTooLarge`, EIO → `.itemFailed`.
  - `testClassifierCocoaCodesAndUnderlyingChain`:
    - `CocoaError(.fileWriteOutOfSpace)` → full;
    - `NSError(NSCocoaErrorDomain, 512, userInfo: [NSUnderlyingErrorKey: NSError(NSPOSIXErrorDomain, ENOSPC)])` → full;
    - an error nested 5 deep → `.itemFailed` (the depth limit).
  - `testFileTooLargeErrorClassifiesAsItemTooLargeAndMentionsExFAT`.
  - `testCapacityHelpersUnchanged`: the moved `ExternalPhotoExportCapacity` tests still pass (move them from `FileScanEngineTests`).
- **`ExternalPhotoExportServiceTests`** (extend):
  - `testENOSPCStopsRunAndMarksRestNotAttempted`: 3 assets; the fake fails asset 1 with ENOSPC after 1 chunk. Expect `failures.count == 1`, `notAttemptedAssetIDs == [a2, a3]`, `stopReason == .destinationFull`, the fake's `requestCount == 1`, no partial left for a1, and `deletionEligibleAssetIDs` empty.
  - `testEFBIGFailsOnlyThatItem`: asset 1 fails with EFBIG; assets 2 and 3 export; `stopReason == nil`.
  - `testTooLargePreflightSkipsWithoutRequest`: fake probe `maximumFileSize = 4_294_967_295`; asset 1 measured at 5 GB. The fake's `requestCount` for asset 1 is 0, the failure message mentions exFAT, and assets 2–3 export.
  - `testTrustedCapacityPreflightStopsBeforeDownload`: probe capacity 1 GB, asset 1 measured at 3 GB. Expect `stopReason == .destinationFull`, `requestCount == 0`, and all assets not attempted.
  - `testUntrustedOrEstimatedCapacityNeverStops`: the probe returns nil, or the asset has no measured size, so the export proceeds.
  - `testCancelDuringHeldRequestCancelsDataRequest`: `holdAfterChunks: 1`; cancel the task. `recordedCancelledRequestIDs` has the held ID and the result is `wasCancelled`.
  - `testPerResourceExpectedSizeAppliesOnlyToMeasuredResource`: an edited video with resources `[.video, .fullSizeVideo, .adjustmentData]` and measured 2 MB. Progress for `.fullSizeVideo` has `currentBytesExpected == 2 MB`; the other two have nil.
- **`iOSCleanupTests/ExportProgressTests.swift`** (*new*):
  - `testProgressDropsExpectedWhenExceeded`: bytes 3 GB > expected 1 GB → `bytesExpected == nil`, and the fraction comes from download only.
  - `testProgressUsesBytesWhenWithinExpected`.
  - `testLabelNeverShowsTotalBelowCopied`: fuzz 200 seeded `(written, expected)` pairs. The label contains " of " only when expected ≥ written.
  - `testCancellingLabel`: "Stopping…".
  - `testStoreMarkCancellingResets`: `markCancelling()` then `reset()` → false.
- **`iOSCleanupTests/ExportLiveActivityTests.swift`** (*new*):
  - `testStaleDatePolicy`: active → +300 s, background → +25 s.
  - `testPresentationStaleExportingShowsPaused`: `compactTrailing(isStale: true) == "Paused"`, and the symbol is the pause symbol.
  - `testPresentationNotStaleShowsPercent`.
  - `testInterruptedPhaseStatusLine`.
  - `testFinishedStatusLinePluralizes`: 1 → "1 file exported and verified".
  - `testOrphanPolicyWithRecordIsInterruptedNotImmediate`, `testOrphanPolicyWithoutRecordIsCancelledImmediate`.
- **`iOSCleanupTests/PendingExportStoreTests.swift`** (*new*, `@MainActor`, temp `fileURL`):
  - `testRecordRoundTripsAcrossInstances`.
  - `testFinishRunDeletesOnlyMatchingID`: `beginRun(A)`, `beginRun(B)`, `finishRun(A)`; the file still holds B.
  - `testCorruptOrNewerSchemaFileIsDiscarded`.
  - `testLoadAtLaunchIgnoredWhileRunActive`.
  - `testBeginRunClearsInterruptedRecord`.
- **`ExternalExportCoordinatorTests`** (extend; fake bookmarking, temp store):
  - `testRunWritesRecordAndClearsItOnFinishCancelAndFailure`.
  - `testRecordPersistsWhileRunInFlight`: the export closure awaits a continuation; the file exists; resume it; the file is gone.
  - `testBookmarkFailureStillExportsWithoutRecord`.
  - `testStopReasonEndsActivityAsFailed`: map `stopReason` → phase `.failed` through the coordinator's outcome-to-phase helper.
  - `testMarkCancellingFlipsStore`.
- **Device-only:** DQA-EXPORT-57.0–57.6.

### Acceptance criteria
- [ ] With a full destination, the export stops after the first ENOSPC (or before, from a trusted preflight), reports the rest as not attempted with the drive-full message, and starts no further PhotoKit requests (tests plus DQA-EXPORT-57.1).
- [ ] EFBIG and the too-large preflight skip only that item, with exFAT/APFS guidance.
- [ ] No change in this workstream alters `deletionEligibleAssetIDs` semantics: WS-05's and WS-35's tests pass unchanged.
- [ ] Cancel shows "Stopping…" at once, and a downloading item stops within about a second on device (DQA-EXPORT-57.2). Otherwise the fallback copy is in place and recorded in the PR.
- [ ] Per-file labels never show a total smaller than the bytes copied (fuzz test).
- [ ] While backgrounded, the Live Activity's stale date is at most 25 s ahead, and the Dynamic Island compact and expanded views show "Paused" when stale (tests plus DQA-EXPORT-57.3).
- [ ] After a force-quit mid-export, relaunch shows the activity as "Interrupted" (not removed), and Home shows the resume banner. Resume to the same folder skips verified items and finishes the rest (DQA-EXPORT-57.4).
- [ ] `ExternalPhotoExportService.swift` is not longer than before this workstream (logic lives in the new files).
- [ ] The suite is green with no new warnings, new files are in `project.pbxproj`, and the widget README and `CLAUDE.md` are updated.

### Device QA
Add under "Export resilience (WS-57)". Use a USB-C SSD (exFAT), a FAT32 stick and iCloud Drive.
1. **DQA-EXPORT-57.0 (verify first):** with a DEBUG log line from `FileSystemExportDestinationProbe`, record for each of exFAT SSD, APFS SSD, FAT32 stick, iCloud Drive and On My iPhone:
   - whether `volumeIdentifier` differs from tmp's;
   - `volumeAvailableCapacity`;
   - `volumeMaximumFileSize`.

   If a USB drive reports the phone's identifier, the capacity preflight never runs there (safe). Note it.
2. **DQA-EXPORT-57.1:** fill the SSD to about 2 GB free and export 10 large videos. The run stops at the first failure with "The drive is full. N items weren't attempted…". The not-attempted videos stay selected, and no further iCloud download starts (watch the network indicator).
3. **DQA-EXPORT-57.2:** export a 4 GB iCloud-only video and tap Cancel after 10 s. "Stopping…" appears immediately, and the transfer stops within about a second (Settings › Cellular or Xcode's network gauge). Re-export: it resumes from the partial.
4. **DQA-EXPORT-57.3:** start a 20 GB export, lock the phone and wait 60 s. On the Lock Screen and in the Dynamic Island the activity reads "Paused" or "Not responding", never a frozen percentage.
5. **DQA-EXPORT-57.4:** start the same export, force-quit after about 5 items, then relaunch. The activity shows "Interrupted — open PhotoDuck to resume". Home shows the banner. Resume to the same folder: the first items are "already on this drive", the rest copy, and the verified-delete offer (never an automatic delete) follows.
6. **DQA-EXPORT-57.5:** export a 5 GB 4K video to the FAT32 stick. It is skipped before downloading when its size was measured, or it fails at 4 GB with the exFAT/APFS guidance. Other items continue. Also unplug the SSD mid-export and record the error message and codes from diagnostics.
7. **DQA-EXPORT-57.6 (only if 57.7 shipped):** on iOS 26, start an export and leave the app. System progress continues. Simulate expiry: the banner offers Resume on return.

### Pitfalls and out of scope
- **Never let a classified stop skip WS-05's cleanup:** discard the failing partial and roll back siblings before breaking the loop.
- **Never count "not attempted" as failed or verified.** It must not enter `deletionEligibleAssetIDs` or the manifest.
- The preflights use measured sizes only. An estimated size must never block an export.
- Do not reintroduce `writeDirect` or a second write path. Cancellability depends on `requestData`.
- The pending record holds asset IDs and a bookmark. Never write it to UserDefaults (backed up) or to diagnostics (invariant 26).
- Idle timer: use `IdleTimerCoordinator` only (WS-29): `IdleTimerCoordinator.shared.acquire(reason: "export")` and `release(_:)`, as WS-29 already wired into `ExternalExportCoordinator` (README §9 contract 7).
- **Reconciliation:**
  - FILES-15 and FILES-16 are covered only where WS-05 left work; `writeDirect` and its retry are already gone. `spec/TRACEABILITY.md` should say so for both findings (lead).
  - `FileResultsView` has WS-50's init (`progress:`, `actions:`). This workstream only forwards its existing `.onChange(of: scenePhase)` and touches `FileResultsView+Export.swift`.
  - `ResumeExportView`'s asset fetch goes through WS-40's `PhotoLibraryFetch.identifierOptions()`, so `PhotoFetchLintTests` stays green.
  - **Forward note (WS-64):** the `.interrupted` `Phase` case and the shared `PhotoDuckExportActivityAttributes.ContentState` presentation extension live in `ExportActivityAttributes.swift`, which both targets compile. WS-64's widget work (chapter 13) must keep them and must not fork them back into private widget helpers.
- **Belongs elsewhere:** archival resources and deletion eligibility (WS-05, WS-35); compression background work (WS-44); an export redesign (the design handoff).

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| FILES-15 | partially | Confirmed in today's tree: no error classification (`:763-789`), capacity helper unused (`:336-368`), preflight removed (`:642-648`). The "skip the writeResumable retry" part is stale after WS-05, which deletes `writeDirect` and its retry. Differences from the reviewer's fix: EROFS/read-only was added as a stop reason. The capacity preflight runs only with a volume identifier distinct from tmp's **and** a measured (never estimated) asset size, per asset, before downloading. The too-large check uses `volumeMaximumFileSize` against the measured current-version resource. `ExternalPhotoExportCapacity` is reused, not deleted. The identifier behavior on USB drives is device-dependent (DQA-EXPORT-57.0). |
| FILES-16 | partially | The uncancellable `writeData` is real today but removed by WS-05, so every resource already streams through cancellable `requestData`. The reviewer's item 2 is therefore stale. The remaining parts are confirmed and fixed: the per-resource expected size (`:680`, `:706`; worse after WS-35's archival resources), the 0.99 cap (`:703`), labels showing X of Y with X > Y, no cancelling state, and misleading help text. Whether `cancelDataRequest` stops an iCloud download within about a second is device-verified first (DQA-EXPORT-57.2), with a documented fallback. |
| FILES-17 | confirmed | The racy expiration handler (`HomeView.swift:1846-1858`), the 5- and 2-minute stale dates (`:1704`, `:1755`, `:1773`), the Dynamic Island ignoring `isStale` (widget `:18-60`), `.cancelled`/`.immediate` orphan ends (`:1832-1848`) and the missing bookmark are all verified. Instead of a nested background task, a rolling 25 s stale date while backgrounded makes staleness independent of the handler. The record lives in a backup-excluded file rather than UserDefaults (asset-ID lists can be large, and it is device-specific data under D-BACKUP). Resume never auto-deletes (DECISION). Continued processing is optional (57.7). |

---

## WS-58 — Release engineering, docs, review prompt and App Review notes

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M3 | M | WS-36, WS-47, WS-48, WS-56 | no | `ws/58-release-docs-review` |

**Primary files:**
- **Build:** `iOSCleanup/Info.plist`, `iOSCleanup.xcodeproj/project.pbxproj`.
- **StoreKit:** `iOSCleanup/Configuration/iOSCleanup.storekit`.
- **Assets:** `iOSCleanup/Assets.xcassets` (4 imagesets removed, 3 re-exported), `Design/mockups/` (*new*), `Design/brand/`.
- **Docs:** `README.md`, `CLAUDE.md`, `../CLAUDE.md` (outer workspace; owner approval), `docs/archive/` (*new*), `docs/AppReviewNotes.md` (*new*), `docs/RELEASE.md` (*new*), `spec/README.md` (paths and status only).
- **Review prompt:** `iOSCleanup/Views/Home/ReviewPromptPolicy.swift` (*new*), `iOSCleanup/Views/Home/ReviewPromptModifier.swift` (*new*), `iOSCleanup/iOSCleanupApp.swift` (one modifier), `iOSCleanup/Views/PaywallView.swift` (one `.onAppear`).
- **Tests:** `iOSCleanupTests/AppConfigurationTests.swift` (WS-02), `iOSCleanupTests/StoreKitConfigurationLintTests.swift` (*new*), `iOSCleanupTests/ReleaseDocsLintTests.swift` (*new*), `iOSCleanupTests/ReviewPromptPolicyTests.swift` (*new*).

Primary files also named `HomeView.swift`, but the review prompt attaches at the app root next to WS-11's receipt toast, so `HomeView.swift` is not edited.

**Findings covered:** BUILD-13 (P2, confirmed; merged: STORE-10), BUILD-16 (P2, confirmed; merged: STORE-07, FSA-16), BUILD-17 (P3, partially; merged: STORE-14 asset part), STORE-17 (P2, confirmed)

**Decisions applied:**
- **D-PRICING:** the price is set in App Store Connect ($19.99 lifetime, with a $14.99 launch price schedule). The local `.storekit` mirrors the base price 19.99. No code reads a price literal (`Product.displayPrice`, invariant 23).
- **D-GATING / D-FREE-KEEPBEST / D-EXPORT-DELETE:** the StoreKit description, README, both CLAUDE.md files and the review notes describe exactly WS-36's policy.
- **D-GROWTH (owner confirms):** the only v1 growth feature is the review prompt, once per app version, after a DeletionManager-confirmed cleanup of ≥ 500 MB or ≥ 50 items, never triggered by an error, a paywall or a decline. FSB-14 as a whole stays with WS-64.
- **D-PRIVACY-URL:** the final gate requires `PrivacySurfaceTests.testLinksAreOwnerSupplied` to run and pass, not skip.
- **D-PERF-GATE:** the final gate requires the Performance plan green with no `XCTExpectFailure` left.
- **D-UNDO:** docs and review notes say "iOS confirmation, then Recently Deleted (30 days)". There is no undo window.

### Goal
- Bumping the version or build in one place updates the app and the widget together.
- The README, both CLAUDE.md files and the StoreKit description describe shipped behavior only: no Contacts, no undo window, working commands.
- The asset catalog ships only referenced, right-sized images.
- `docs/AppReviewNotes.md` lets a reviewer reach a duplicate group, Keep Best, Duck Mode and the paywall in under 2 minutes on a fresh device.
- The review prompt appears at most once per version, only after a real cleanup.
- A TestFlight build passes the final gate and is submitted.

### Current behavior (verified)
**Versions (BUILD-13, STORE-10)**
- `iOSCleanup/Info.plist:17-20` hard-codes `1.0` and `1`, while `PhotoDuckWidgets/Info.plist:17-20` uses `$(MARKETING_VERSION)` and `$(CURRENT_PROJECT_VERSION)`.
- `project.pbxproj` sets `CURRENT_PROJECT_VERSION = 1` and `MARKETING_VERSION = 1.0` in all six target configurations (`:772/778`, `:793/799`, `:813/816`, `:830/833`, `:847/852`, `:871/876`).
- The project-level configurations `AA0000010000000000000D01` (Debug, `:645`) and `…0D02` (Release, `:709`) have no `VERSIONING_SYSTEM`.
- Diagnostics record `CFBundleVersion` (`iOSCleanupApp.swift:35-46`).

**Docs (BUILD-16, STORE-07, FSA-16)**
- **`README.md`:**
  - `:3-4`: "duplicate contacts … CNContactStore";
  - `:8-10`: Xcode 15, iOS 16, Swift 5.9;
  - `:16`: "simulator has no library";
  - `:19-21`: Contact engine, `PhoneNormalizer`, `NameMatcher`;
  - `:41-44`: a 10-second undo bar and `ActionBar(trashIsPaid:)`;
  - `:64`: `iPhone 15`.

  WS-06, WS-07, WS-09 and WS-11 edited parts of it since.
- **`CLAUDE.md`:**
  - `:13-22`: `iPhone 16` commands (WS-06 replaces them);
  - `:53-60`: the navigation flow shows a `HomeView` root instead of `PhotoDuckShellView`'s `TabView`;
  - `:39`: the 10-second undo (WS-11 fixes it);
  - `:65`: "Keep Best for one eligible group" (WS-36 fixes it);
  - `:91-120`: the ML pipeline section (WS-33/WS-46/WS-47 change it).
- **`../CLAUDE.md`:15-17:** "contact writes … are paid" and "10-second undo window".
- **`iOSCleanup.storekit:10`:** "Unlock all cleanup features — delete duplicates, merge contacts, compress videos." (81 characters). `displayPrice` is "2.99".
- **Planning docs.** `FIXSPEC.md` (2026-07-23), `ROADMAP.md` and `PERFORMANCE_MASTER_PROMPT.md` (with a stray "å" on line 2) sit at the repo root. `spec/README.md:3` says the spec replaces them.

**Assets (BUILD-17, STORE-14)**
- `Assets.xcassets` contains the unreferenced `photoduck_home_mock` (1.40 MB PNG), `photoduck_scan_mock` (1.28 MB), `photoduck_complete_mock` (1.25 MB) and `photoduck_logo` (0.25 MB, 1024 px).
- Code references only `photoduck_icon`, `photoduck_wordmark` and `photoduck_mascot` (`DuckComponents.swift:30,50,67`).
- `photoduck_icon` and `photoduck_mascot` are 1254×1254 single-scale universal images (1.29 and 1.40 MB). `photoduck_wordmark` is 1983×793 (0.54 MB).
- **Largest display sizes** (not 120 pt as the finding says): icon 180 pt (`OnboardingView.swift:44`), mascot 180 pt (`:78`), wordmark 38 pt tall (`OnboardingView.swift:46`, `PaywallView.swift:29`).
- WS-01 put `photoduck_mascot-source.png` and `photoduck_wordmark-source.png` in `Design/brand/`.
- `UILaunchScreen` is an empty dict (`Info.plist:39-40`).
- STORE-14's `#if DEBUG` wrapping of ML export is WS-47's (ML-13).

**App Review (STORE-17)**
- With no groups, results show "Your library looks clean" (`PhotoResultsView.swift:70-75`; WS-31 makes it context-aware), and Auto-clean has nothing to act on (WS-36 hides it).
- The Similar dashboard says "Run a scan from Home…" (`PhotoDuckShellView.swift:165-166`).
- There are no review notes anywhere. `ROADMAP.md:41` lists paywall compliance but no demo path.

### Implementation plan

**WS-58.1 — Versions from build settings (BUILD-13)**
- **Change:**
  - In `iOSCleanup/Info.plist`, set `CFBundleShortVersionString` = `$(MARKETING_VERSION)` and `CFBundleVersion` = `$(CURRENT_PROJECT_VERSION)`.
  - In `project.pbxproj`, add `VERSIONING_SYSTEM = "apple-generic";` to `AA0000010000000000000D01` and `…0D02`. Keep the six target-level values equal; `agvtool` updates them together.
  - New `docs/RELEASE.md` with a "Versioning" section:
    - build bump: `xcrun agvtool next-version -all`;
    - marketing bump: `xcrun agvtool new-marketing-version 1.0.1`;
    - verify with `xcrun agvtool what-version` and `xcrun agvtool what-marketing-version`;
    - "never edit Info.plist versions".
- **Edge cases:** if the Xcode General tab is used instead, it writes target-level values. The equality test below catches a mismatch.

**WS-58.2 — StoreKit text and price mirror (STORE-07, FSA-16)**
- **Change:** `iOSCleanup.storekit`:
  - `description` becomes "Auto-clean, bulk delete & video compression" (43 characters, matching D-GATING's paid set);
  - `displayPrice` becomes "19.99";
  - keep `displayName` "PhotoDuck Unlock", `familySharable: true` and the product ID.
- **Owner step:** enter the identical description in App Store Connect and set the price schedule ($14.99 launch, $19.99 after). Record both in the PR.

**WS-58.3 — Lean asset catalog (BUILD-17)**
- **Change:**
  1. `git mv` the four PNGs of `photoduck_home_mock`, `photoduck_scan_mock`, `photoduck_complete_mock` and `photoduck_logo` into `Design/mockups/`, then delete their `.imageset` folders. **DECISION (owner may override):** moved, not deleted, so design history stays in the repo but out of the bundle.
  2. Before replacing, `md5` the current `photoduck_icon.png`, `photoduck_mascot.png` and `photoduck_wordmark.png`. Copy any that is not byte-identical to a file in `Design/brand/` into `Design/brand/` (as `*-app-1254.png` etc.).
  3. Re-export with `sips` from the `Design/brand` sources (lossless PNG):
     - icon and mascot at 540×540 px (3 × 180 pt);
     - wordmark at 300×120 px (3 × 38 pt, aspect ≈ 2.5).

     Keep each `Contents.json` single-entry universal. Views size them with `.resizable().scaledToFit()`, so nothing else changes.
  4. **Optional:** `UILaunchScreen` = `{ UIColorName: "DuckBlush" }`, for a blush launch instead of white. The colorset is at the catalog root namespace (the `Colors` folder has no `Contents.json`).
- **Edge cases:**
  - `AppIcon.appiconset` and `AccentColor.colorset` are untouched.
  - Compare onboarding and paywall screenshots at 3x for sharpness before and after.

**WS-58.4 — Accurate docs and archived planning files (BUILD-16)**
- **Change:**
  1. **Rewrite `README.md`** with these sections, merging (not deleting) the sections WS-06, WS-07, WS-09 and WS-11 added:
     - **What PhotoDuck does:** duplicates and similar/burst review, screenshots and blurry, large videos and screen recordings, compression, export-then-delete. On-device only, no account, no contacts.
     - **Requirements:** Xcode 26.x, iOS 17.0+, iPhone only.
     - **Build and test:** the `scripts/test.sh` and `scripts/build-release.sh` commands, and the Performance plan.
     - **Simulator fixtures:** WS-07's harness.
     - **Device QA:** a link to `docs/DEVICE_QA.md`.
     - **Deletion safety:** WS-11's text (guardrails → the iOS confirmation → Recently Deleted for 30 days).
     - **Free vs Pro:** WS-36's paragraph.
     - **Release:** a link to `docs/RELEASE.md`.
     - **Privacy:** links to `PrivacyPolicyView` and `docs/privacy-policy.md`.
  2. **Audit `CLAUDE.md` line by line against the shipped code:**
     - the navigation flow: `ContentView → OnboardingView | PhotoDuckShellView (TabView: Home, Similar, Files) → HomeView (NavigationPath, HomeRoute) / SimilarPhotosDashboardView (PhotoGroupRoute) / FileResultsView`, with PhotoResultsView, SwipeModeView and the compression and export screens as sheets or covers;
     - the engine table (the ML store as a bounded cache per WS-46/WS-47; the export row per WS-05/WS-35/WS-57);
     - the test-coverage line; the ML pipeline section per D-ML.

     Fix every stale statement. A workstream that already fixed one leaves nothing to do there.
  3. **Outer `../CLAUDE.md`** (owner approval required, README §3.5): propose reducing it to a pointer — "The active app is `ios-cleanup/`. `ios-cleanup/CLAUDE.md` and `ios-cleanup/spec/README.md` are the single source of truth; do not duplicate invariants here." Without approval, put the proposed text in the PR summary and leave the file alone.
  4. `git mv FIXSPEC.md ROADMAP.md PERFORMANCE_MASTER_PROMPT.md docs/archive/`. Prepend to each: "> **Historical (archived <merge date>).** Superseded by `spec/`. Verify every item against current code before acting." Delete the stray "å" line.
  5. **Update the links (this task, not a later one).**
     - `spec/README.md:3` names the three files and says "WS-58 moves them to `docs/archive/`". Rewrite that sentence to link `../docs/archive/FIXSPEC.md`, `../docs/archive/PERFORMANCE_MASTER_PROMPT.md` and `../docs/archive/ROADMAP.md`, and say they were archived.
     - Then run `grep -rn "FIXSPEC\.md\|ROADMAP\.md\|PERFORMANCE_MASTER_PROMPT\.md" --include='*.md' .` and fix every path-style link outside the chapter bodies. That includes `README.md`, `CLAUDE.md` (its "Implementation plan" section names `FIXSPEC.md` and `PERFORMANCE_MASTER_PROMPT.md`) and the rest of `spec/README.md`.
     - Leave historical citations alone: the decision log's "FIXSPEC 0.3"/"ROADMAP" mentions, `spec/TRACEABILITY.md`'s source column, and file:line citations such as `ROADMAP.md:41` in chapter text. Chapter 13 notes that its `ROADMAP.md:NN` citations point at the archived copy.
- **Edge cases:** WS-11's `DeletionLintTests.testRepositoryDocsDescribeImmediateDeletion` must stay green, so do not reintroduce undo phrasing.

**WS-58.5 — App Review notes (STORE-17)**
- **Change:** create `docs/AppReviewNotes.md`, to be pasted into App Store Connect › App Review Information › Notes. Verify every step against the TestFlight build and replace anything that differs. Draft:
  ```markdown
  # PhotoDuck — notes for App Review
  PhotoDuck works entirely on the device. No account, sign-in or network connection is needed.

  ## Create test content (about 1 minute)
  1. Photos app: open any photo › ••• › Duplicate. Repeat on 2–3 photos (exact copies).
  2. Camera: take a burst (swipe the shutter left, or enable Settings › Camera › Use Volume Up for Burst).
  3. Take 3 quick photos of the same scene (similar photos).
  4. Control Center: record the screen for about 10 seconds (Screen Recordings).
  5. Record a 1-minute 4K video if you want to test video compression (small videos are refused because
     compression would not save enough space).

  ## Walkthrough
  - Home › Start scan (allow Photos access). Groups appear within about a minute.
  - Duplicates tile › a group › Keep Best: one system confirmation moves the extra copies to Recently Deleted.
  - Similar tab › Swipe Review (Duck Mode): swipe left to delete, right to keep, then Move to Recently Deleted.
  - Screenshots / Screen recordings tiles: delete one item free; Select All shows the Pro lock.

  ## Free vs Pro (one-time purchase, no subscription)
  Free: Keep Best one group at a time, any single delete, Duck Mode swipe review, verified Export & Delete.
  Pro: Auto-clean all groups, deleting many items at once, video compression.
  The paywall appears before a Pro action (on the locked control), never after the user has made selections.

  ## Deletion safety
  Every deletion shows Apple's system confirmation and goes to Photos › Recently Deleted (30 days).

  ## Purchases and privacy
  Restore Purchase: Home › Help & Privacy (question-mark button) › Restore Purchase, and on the paywall.
  Privacy Policy and Terms: Home › Help & Privacy, and on the paywall. Policy URL: <PhotoDuckLinks.privacyPolicy>.
  ```
  Also add a one-line tip to the neutral empty state of the Similar dashboard and of `PhotoResultsView`'s `.noFindings` context: "Tip: take a burst or duplicate a photo in Photos, then scan again." This uses existing copy slots in `ResultsEmptyContext`.
- **Edge cases:**
  - The draft assumes WS-38 and WS-40 landed. Check both before pasting the notes.
  - Identical copies are Keep Best eligible only after WS-38. If WS-38 slipped, step 1 still produces a review-only group; say "review" in the walkthrough.
  - Burst frames appear only with WS-40 (cuttable); drop step 2 and the burst wording if it was cut.
  - Take the "Free vs Pro" lines from WS-36's README "Free vs Pro" paragraph (D-GATING). They must say the same thing as the `.storekit` description and the paywall captions.

**WS-58.6 — Review prompt (D-GROWTH; skip entirely if the owner declines)**
- **Change:**
  1. `iOSCleanup/Views/Home/ReviewPromptPolicy.swift`:
     ```swift
     enum ReviewPromptPolicy {
         static let minimumItems = 50
         static let minimumBytes: Int64 = 500_000_000            // decimal, like ByteText
         static let paywallQuietPeriod: TimeInterval = 10 * 60
         struct Input: Equatable {
             let appVersion: String
             let lastPromptedVersion: String?
             let sessionConfirmedItems: Int
             let sessionConfirmedBytes: Int64
             let lastPaywallPresentedAt: Date?
             let now: Date
         }
         static func shouldRequestReview(_ i: Input) -> Bool {
             guard i.lastPromptedVersion != i.appVersion else { return false }
             if let paywall = i.lastPaywallPresentedAt, i.now.timeIntervalSince(paywall) < paywallQuietPeriod { return false }
             return i.sessionConfirmedItems >= minimumItems || i.sessionConfirmedBytes >= minimumBytes
         }
     }
     @MainActor
     final class ReviewPromptTracker: ObservableObject {
         static let shared = ReviewPromptTracker()
         static let lastVersionKey = "photoduck.review-prompt.last-version"
         init(defaults: UserDefaults = .standard,
              appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
              now: @escaping () -> Date = Date.init)
         /// Accumulates confirmed receipts (DECISION: per app session). Returns true at most once per
         /// version and records the version when it does.
         func record(_ receipt: DeletionReceipt) -> Bool
         func notePaywallPresented()
     }
     ```
  2. `ReviewPromptModifier.swift`: `extension View { func reviewPromptAfterCleanup() -> some View }`:
     - It reads `@Environment(\.requestReview)` and `@EnvironmentObject deletionManager`.
     - `.onChange(of: deletionManager.lastReceipt?.id)`: if `ReviewPromptTracker.shared.record(receipt)` returns true, then `Task { try? await Task.sleep(for: .seconds(2)); requestReview() }`, so the receipt toast is seen first.
     - Skip when `UserDefaults.standard.bool(forKey: "PhotoDuckFixtureAnalyzer")` is true (WS-07's harness).
  3. In `iOSCleanupApp`, add `.reviewPromptAfterCleanup()` next to `.deletionReceiptToast(bottomPadding:)`. In `PaywallView`, add `.onAppear { ReviewPromptTracker.shared.notePaywallPresented() }`; this is not a visual change.
- **DECISION (owner may override):** thresholds count all confirmed receipts in the current app session (reset at launch), so ten one-tap Keep Bests of 5 photos qualify. Errors and declines produce no receipt, so they can never trigger the prompt.
- **Edge cases:**
  - `requestReview` is rate-limited by iOS anyway. The policy only guarantees PhotoDuck never asks at a bad moment.
  - Never call it from paywall, error or decline paths.

**WS-58.7 — Final submission gate (owner-run; the workstream is `needs device QA` until done)**
- **Change:** in `docs/RELEASE.md`, add a "Submission gate" checklist. Every item links to its evidence file.
  1. `scripts/test.sh` and `scripts/build-release.sh` are green with warnings as errors.
  2. `scripts/test.sh -testPlan Performance` is green, and `grep -rn XCTExpectFailure iOSCleanupTests` is empty (D-PERF-GATE). If a wrapper remains, its fix did not land: stop and report.
  3. **Privacy (D-PRIVACY-URL; WS-48's owner steps):**
     - `PrivacySurfaceTests.testLinksAreOwnerSupplied` **runs and passes**; it is not skipped. If it is skipped, the owner has not supplied the domain and email: stop.
     - `docs/privacy-policy.md` is **published** (GitHub Pages), and `PhotoDuckLinks.privacyPolicy` opens it on a device. `testHostedPolicyMarkdownMatchesInAppSections` passes.
  4. Release archive:
     - Organizer › Validate App: no ITMS-91053, 90474 or 90473;
     - Generate Privacy Report: exactly UserDefaults, DiskSpace, FileTimestamp and SystemBootTime;
     - `nm`/`strings` on the Release binary show no `DebugFixture`, `PhotoMLDebugExport`, `exportTrainingData` or admin-unlock symbols (invariant 27).
  5. TestFlight build on at least one device with a 30–60k iCloud library: run the full `docs/DEVICE_QA.md` and record `docs/qa-runs/<date>-<device>-release.md`. Every M3 exit criterion that says "device" is recorded there.
  6. **App Store Connect:**
     - IAP description equals `.storekit`, and the price schedule is set;
     - the **Privacy Policy URL** is set to `PhotoDuckLinks.privacyPolicy` and the **Support URL** to `PhotoDuckLinks.supportPage`;
     - **App Privacy is "Data Not Collected"**, which matches the policy: diagnostics leave only through the user's own share sheet. If the owner would answer anything else, stop and reconcile the policy text (WS-48) first;
     - review notes are pasted from `docs/AppReviewNotes.md`;
     - iPhone screenshots only (D-IPAD).
  7. Submit for review, and record the build number and date in `spec/README.md`'s status table.

### Tests
All run in the simulator.
- **`AppConfigurationTests`** (WS-02's file; extend):
  - `testAppInfoPlistUsesBuildSettingVersions`: parse the source `iOSCleanup/Info.plist` via `#filePath` and `PropertyListSerialization`. The two keys equal `$(MARKETING_VERSION)` and `$(CURRENT_PROJECT_VERSION)`.
  - `testWidgetInfoPlistUsesBuildSettingVersions`.
  - `testAllTargetsShareOneVersion`: parse `project.pbxproj` text. `Set` of `MARKETING_VERSION = …;` values has count 1, the same for `CURRENT_PROJECT_VERSION`, and `VERSIONING_SYSTEM = "apple-generic";` appears exactly twice.
  - `testEmbeddedWidgetVersionMatchesApp`: hosted. `Bundle(url: Bundle.main.builtInPlugInsURL!.appendingPathComponent("PhotoDuckWidgets.appex"))` has both version keys equal to `Bundle.main`'s. `XCTSkip` if the appex is absent.
- **`iOSCleanupTests/StoreKitConfigurationLintTests.swift`** (*new*; `#filePath` JSON, not the test bundle copy):
  - `testExactlyOneNonConsumableMatchingProductID`: equals `PurchaseManager.productID`; there are no subscriptions or consumables.
  - `testDescriptionFitsAndIsAccurate`: count ≤ 45, and it does not contain "contact" (case-insensitive).
  - `testDisplayNameFits`: ≤ 30.
  - `testFamilySharableIsTrue`.
- **`iOSCleanupTests/ReleaseDocsLintTests.swift`** (*new*):
  - `testDocsNeverMentionRemovedContactsFeature`: `README.md`, `CLAUDE.md` and the `.storekit` contain none of `CNContact`, "duplicate contacts", "merge contacts", "contact writes", `ContactScanEngine`, `PhoneNormalizer`, `NameMatcher`. "Contact Support" is allowed.
  - `testDocsUseAvailableSimulator`: no `name=iPhone 15` or `name=iPhone 16` in `README.md` or `CLAUDE.md`.
  - `testReviewNotesExistAndCoverEssentials`: `docs/AppReviewNotes.md` exists and contains "Restore", "Recently Deleted", "Privacy" and "Duplicate".
  - `testPlanningDocsAreArchived`: `FIXSPEC.md`, `ROADMAP.md` and `PERFORMANCE_MASTER_PROMPT.md` are absent at the root and present in `docs/archive/`, each starting with "> **Historical".
  - `testEveryImageSetIsReferenced`: every `*.imageset` directory name under `Assets.xcassets` appears as a string literal in some `iOSCleanup/**/*.swift`.
  - `testBrandImagesAreRightSized`: each PNG in the three imagesets has max pixel dimension ≤ 600. Read the dimensions with `CGImageSourceCopyPropertiesAtIndex`.
- **`iOSCleanupTests/ReviewPromptPolicyTests.swift`** (*new*):
  - `testNotBelowThresholds` (49 items / 499 MB → false).
  - `testItemsOrBytesThresholdTriggers`.
  - `testOncePerVersion`.
  - `testNewVersionReenables`.
  - `testPaywallQuietPeriod`: 9 minutes → false, 11 minutes → true.
  - `@MainActor testTrackerAccumulatesReceiptsAndPersistsVersion`: temp `UserDefaults(suiteName:)`, WS-11's `DeletionReceipt` memberwise init. Five receipts of 10 items → the fifth returns true, and a sixth returns false.
  - `@MainActor testTrackerIgnoresReceiptsAfterPrompt`.
- **Owner or device only:** the final gate (WS-58.7) and the StoreKit text in App Store Connect.

### Acceptance criteria
- [ ] Changing `CURRENT_PROJECT_VERSION` with `agvtool next-version -all` changes both bundles. The four version tests pass.
- [ ] The `.storekit` description is ≤ 45 characters and accurate. Its lint passes, and the App Store Connect text matches (owner, recorded in the PR).
- [ ] The four unused imagesets are out of the bundle (moved to `Design/mockups/`). The three brand images are ≤ 600 px. The compiled `Assets.car` is under 2.5 MB (`ls -l` of the built app in the PR).
- [ ] README, `CLAUDE.md` and the outer `CLAUDE.md` (with approval) are accurate. The planning docs are archived with a header. `ReleaseDocsLintTests` pass.
- [ ] `docs/AppReviewNotes.md` exists. A tester following it on a fresh device reaches a group, Keep Best, Duck Mode and the paywall in under 2 minutes (DQA-REL-58.2).
- [ ] If D-GROWTH is accepted, the review prompt policy tests pass and the prompt appears at most once per version, only after a confirmed cleanup (DQA-REL-58.3).
- [ ] The submission gate checklist in `docs/RELEASE.md` is complete with evidence, and the build is submitted. Until then, the status is `needs device QA`. The evidence includes: `testLinksAreOwnerSupplied` ran (not skipped), `docs/privacy-policy.md` is published, the App Store Connect Privacy Policy and Support URLs are set, and App Privacy is "Data Not Collected".
- [ ] The planning docs are in `docs/archive/`, and `spec/README.md`, `README.md` and `CLAUDE.md` link to the archived paths (WS-58.4 step 5).
- [ ] Full suite green, zero warnings, new files in `project.pbxproj`.

### Device QA
Add under "Release (WS-58)":
1. **DQA-REL-58.1:** after `agvtool next-version -all`, archive and install via TestFlight. Settings › General › About (or the diagnostics report) shows the new build, and the widget extension matches (Organizer shows no ITMS-90473).
2. **DQA-REL-58.2:** hand `docs/AppReviewNotes.md` to someone unfamiliar with the app, on a fresh device with a few distinct photos. Time them to a Keep Best, a Duck Mode commit and the paywall: under 2 minutes, with no questions.
3. **DQA-REL-58.3:** on a TestFlight build, delete 50 photos through Keep Best across groups. The review prompt appears once, about 2 s after the receipt toast. It does not appear again in this version, and it never appears right after opening the paywall. In TestFlight the prompt may not show; record what happens.
4. **DQA-REL-58.4:** the full `docs/DEVICE_QA.md` run on the release candidate (WS-58.7 step 5).

### Pitfalls and out of scope
- Never hard-code versions or prices in code or plists again.
- The outer `../CLAUDE.md` and any push or submission require the owner's explicit approval (README §3.5).
- Do not delete `Design/brand` sources, and do not trim `AppIcon.appiconset`.
- The review prompt must never be requested from an error, decline or paywall path, and never more than once per version.
- **Reconciliation:**
  - `AppConfigurationTests.swift` was created by WS-02 and extended by WS-48. This workstream extends it again and never recreates it (README §9 contract 17).
  - WS-58.4 step 5 updates `spec/README.md`'s links to the archived planning docs as part of this workstream.
  - The final gate spells out the privacy items (the link test runs, the policy is published, the ASC URLs are set, App Privacy is "Data Not Collected").
  - The App Review notes depend on WS-38 and on WS-40, which is cuttable. They are conditional (WS-58.5 edge cases).
  - The test commands use WS-06's plans: `scripts/test.sh` runs the default `iOSCleanup.xctestplan`, and `-testPlan Performance` runs `Performance.xctestplan` (contract 9).
  - WS-64 (chapter 13) relies on this workstream's `ReviewPromptModifier` as the only `requestReview` call site, and never adds another.
- **Belongs elsewhere:**
  - the ML export `#if DEBUG` wrapping: WS-47;
  - the privacy policy hosting and links: WS-48 (owner supplies the values);
  - monthly stats, the widget, App Intents and notifications: WS-64 (chapter 13).

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| BUILD-13 | confirmed | Literal `1.0`/`1` at `Info.plist:17-20`; the widget uses build settings; all six target configurations are equal; there is no `VERSIONING_SYSTEM`. The ITMS-90473 outcome shows only at upload. The plan adds `#filePath` plist and pbxproj equality tests in addition to the runtime appex check, because the hosted check alone cannot catch a mismatch before a bump. |
| STORE-10 (merged) | confirmed | Same facts and fix. |
| BUILD-16 | confirmed | Every cited README, `CLAUDE.md` and `.storekit` statement is verified. Several are fixed earlier (WS-06 commands, WS-11 undo lines, WS-36 paywall paragraph, WS-48 privacy), so this is a final audit plus a README rewrite. The outer `CLAUDE.md` becomes a pointer only with owner approval. The docs lint targets specific contact phrases, because "Contact Support" (WS-48) is legitimate. |
| STORE-07 (merged) | confirmed | The description is 81 characters and advertises "merge contacts". The new text is 43 characters and lists exactly D-GATING's paid features. |
| FSA-16 (merged) | confirmed | Same as STORE-07, plus the README contacts copy. |
| BUILD-17 | partially | Four unreferenced imagesets (about 4.2 MB of PNGs) and 1254 px icon/mascot are confirmed. The finding's display sizes are wrong: the icon and mascot render at up to 180 pt, so they are re-exported at 540 px, not 360. `Assets.car` size is a build artifact, checked in the PR. The mockups are moved to `Design/mockups/` rather than deleted (DECISION). |
| STORE-14 (merged) | partially | The imageset part is handled here. The `#if DEBUG` wrapping of ML export is WS-47 (ML-13). The launch-screen color is included as optional. |
| STORE-17 | confirmed | There are no review notes, and a fresh reviewer device produces empty states. Rejection is App Review behavior, so the notes are validated with DQA-REL-58.2. The notes depend on landed behavior (WS-38 for Keep Best on copies, WS-40 for bursts) and must be checked against the TestFlight build. |
