# Chapter 08 — Coherent monetization and Keep Best that fires

> **Milestone(s):** M2 · **Workstreams:** WS-36 – WS-40 · Read `spec/README.md` first: operating rules, invariants, build/test commands and the decision log apply to every workstream here.

## Chapter overview

These five workstreams decide what a PhotoDuck user can actually do with the duplicates the engine finds, and whether they pay for it.

- **WS-36** puts every paid gate behind one pure, tested `CleanupAccessPolicy`. The lock shows before selection effort, the paywall lists exactly what is paid, and purchases resume the action that triggered them. It also closes the Export Album back door and adds the missing in-sheet compression guard.
- **WS-37 to WS-40** make classifier Keep Best fire on real duplicates, and keep it safe when it does:
  - WS-37 fixes the analyzer signals (real blur at native resolution, orientation, true edit state) in one re-analysis.
  - WS-38 adds pixel, text and barcode verification. Verified identical copies become one-tap Keep Best.
  - WS-39 calibrates thresholds behind an injectable profile.
  - WS-40 surfaces hidden burst frames the user never picked.

**The key risk is ordering.** Loosening thresholds (WS-39) or bypassing the keeper-margin rule (WS-38) is only safe once blur is measured correctly (WS-37) and destructive plans are verified (WS-38). Never land these out of order.

---

## WS-36 — Central entitlement policy

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M2 | L | WS-11, WS-35 | no | `ws/36-central-entitlement-policy` |

**Primary files:**
- Store: `iOSCleanup/Store/CleanupAccessPolicy.swift` (*new*), `iOSCleanup/Store/PurchaseManager.swift`
- Views:
  - `iOSCleanup/Views/PaywallView.swift`
  - `iOSCleanup/Views/Components/PaywallGate.swift` (*new*)
  - `iOSCleanup/Views/Photos/PhotoGroupDetailActionPolicy.swift` (created by WS-04)
  - `iOSCleanup/Views/Photos/PhotoGroupDetailView.swift`
  - `iOSCleanup/Views/Photos/PhotoResultsView.swift`
  - `iOSCleanup/Views/Photos/AutoCleanToolbarState.swift` (*new*)
  - `iOSCleanup/Views/Photos/PhotoCategoryReviewView.swift` (moved by WS-10)
  - `iOSCleanup/Views/Export/ExportAlbumView.swift` (moved by WS-10)
  - `iOSCleanup/Views/Files/FileResultsView.swift`
  - `iOSCleanup/Views/Files/LargeVideoRowViews.swift` (WS-10)
  - `iOSCleanup/Views/Files/VideoCompressionView.swift`
  - `iOSCleanup/Views/Files/VideoCompressionStartGate.swift` (*new*)
- Tests: `iOSCleanupTests/CleanupAccessPolicyTests.swift` (*new*), `iOSCleanupTests/PurchaseFlowStoreKitTests.swift` (*new*), `iOSCleanupTests/PurchaseManagerTests.swift`
- Project and docs: `iOSCleanup.xcodeproj/project.pbxproj`, `CLAUDE.md`, `../CLAUDE.md` (outer repo, owner approval required)

**Findings covered:**
- STORE-06 (P1, confirmed; merged: VALUE-12, BUILD-12, DEL-14, FILES-18, UI-05)
- STORE-08 (P2, confirmed)
- STORE-13 (P3, partially)
- STORE-15 (P3, confirmed)
- STORE-16 (P3, confirmed)
- Also delivers FSB-11 item 4 (FSB-11 is owned by WS-56).

**Decisions applied:**
- **D-FREE-KEEPBEST:** classifier Keep Best is free on every eligible group, one group at a time. No lifetime counter. UI-05's "one free group" option is rejected.
- **D-GATING:** multi-item manual deletion outside a classifier recommendation is Pro. Everything else user-authored is free: single items, subsets of a recommendation, keeper swaps that do not add deletions, and Duck Mode. Auto-clean all, compression and bulk Live Photo conversion are Pro. The lock appears before effort, never at commit.
- **D-EXPORT-DELETE:** deleting originals after a verified export is free. "Delete N from Photos" *without* export follows the multi-select rule.
- **DECISION (owner may override): how "the lock before effort" works on multi-select surfaces.** Selecting items is never blocked for free users, because the same selection also feeds the free "Add to Export".
  - The rule caption ("Free: delete one at a time · Pro: delete many at once") is visible **before any selection**.
  - The commit control shows the lock the moment the selection would need Pro.
  - The paywall opens only from a control that already shows a lock.
  - Select All and Select Month (WS-41/WS-42) are locked controls that open the paywall on tap, before anything is selected.

### Goal
One pure policy decides every paid gate:
- The paywall lists exactly the paid features.
- A free user can delete one photo from any group or any category.
- Narrowing a recommendation is never paid.
- The Export Album back door is closed.
- "Auto-clean all" is offered only where it can act.
- Buying from a gate continues into that action.
- Cancelled restores show no error.
- `VideoCompressionView` refuses to start without the entitlement even when presented directly.
- StoreKitTest tests cover purchase, refund, Ask to Buy and restore.
- `grep isPurchased` under `Views/` finds only `PaywallView.swift`.

### Current behavior (verified)
**Inline purchase checks.** There are 14 inline `isPurchased` checks in views, plus 2 in `PaywallView`:
- `iOSCleanup/Views/HomeView.swift:276`: the "Unlock" toolbar button.
- `HomeView.swift:1222,1229,1249,1265`: the `PhotoCategoryReviewView` action bar.
- `iOSCleanup/Views/Photos/PhotoResultsView.swift:111,124,133`: the Auto-clean toolbar.
- `iOSCleanup/Views/Photos/PhotoGroupDetailView.swift:100,104`.
- `iOSCleanup/Views/Files/FileResultsView.swift:768,1471,1643,1647`.

**Group detail.** `PhotoGroupDetailView.swift:95-108` shows `DuckBottomActionBar` with `isPaid: !purchaseManager.isPurchased` whenever `deleteSet != Set(group.deleteCandidateIDs)`, so the lock applies at any count. Deleting **one** photo from a review-only group, or a strict subset of the recommendation, shows "Delete Selected — Pro". WS-04 replaces this with a resolver that carries a *temporary* inline `requiresPurchase` rule, which this workstream removes.

**Category grid.** `HomeView.swift:1220-1256` (`PhotoCategoryReviewView`):
- Deleting is gated at commit (`selectedAssetIDs.count > 1, !purchaseManager.isPurchased` shows the paywall).
- The caption "Deleting several at once is a Pro feature…" (`:1252`) appears only after the 2nd selection.
- "Add N to Export" (`:1131-1150`) is ungated.

**Export Album.** `ExportAlbumView` (`HomeView.swift:1369`) has no `PurchaseManager`:
- It pre-selects every album item (`initializeOrReconcileSelection`, `HomeView.swift:2046-2059`).
- "Delete N from Photos" (`:1764`) leads to `deleteSelectedWithoutExporting()` (`:1982-1994`), which calls `deletionManager.delete(assets:)` for any count. This is the free bulk back door (DEL-14, FILES-18).

**Auto-clean toolbar.** `PhotoResultsView.swift:111` checks `guard purchaseManager.isPurchased else { showPaywall = true; return }` *before* checking `autoCleanEligibleGroups` (`:50-54`). The Home "Similar" tile passes only `visuallySimilarPhotoGroups` (`HomeView.swift:632-642`), whose `isAutoCleanEligible` is always false. So a free user can buy an action that has nothing to act on.

**Compression.**
- `FileResultsView.swift:767-773` gates the Compress button.
- `VideoCompressionView` (`iOSCleanup/Views/Files/VideoCompressionView.swift:5-18, 247-259`) has no `PurchaseManager` and `startCompression()` has no entitlement check, although the sheet already injects `.environmentObject(purchaseManager)` (`FileResultsView.swift:406`).

**File rows.** `FileRow` (`FileResultsView.swift:1330-1332`) and `LargeVideoGridCard` (`:1548-1550`) hold `let purchaseManager: PurchaseManager` and read `isPurchased` for lock glyphs (`:1471`, `:1643-1648`). These rows also carry closure properties, so SwiftUI usually re-evaluates them anyway, and the stale glyph is not guaranteed. Passing a value is still the correct fix.

**Paywall copy.** `PaywallView.swift:9-14` lists only "Bulk auto-clean duplicate photos" and "Compress videos". `:40` says "Keep Best and individual Duck Mode decisions stay free." Multi-select, which triggers most gates, is never mentioned.

**PurchaseManager:**
- `refreshEntitlement` (`iOSCleanup/Store/PurchaseManager.swift:240-287`) returns inside the loop on the first `.unverified` record (`:253-255`) and on the first verified-revoked record (`:251-252`), so a later verified, non-revoked record is never seen.
- `listenForTransactions` (`:291-315`) and `purchase()` (`:163-202`) use `StoreKit.Transaction` directly. None of their branches is unit-tested.
- `loadProduct` (`:156-158`), `purchase` (`:199-201`) and `restore` (`:219-221`) surface raw `error.localizedDescription`, so cancelling the Apple Account sheet during Restore shows "Restore failed: …".
- Gates do `showPaywall = true; return`. After `.purchaseDidSucceed` the sheet closes (`PaywallView.swift:189-191`) and nothing resumes.

**StoreKit configuration.** The scheme attaches `iOSCleanup/Configuration/iOSCleanup.storekit` only in `LaunchAction` (`iOSCleanup.xcscheme` around line 65). It is not in the test bundle, and no `SKTestSession` tests exist.

**CLAUDE.md drift.**
- The nested `CLAUDE.md` Paywall section says "classifier-selected Keep Best for one eligible group". The workspace `../CLAUDE.md` says "Bulk automation, contact writes, and video compression are paid". Contacts were removed in commit b9b1a28.
- `SwipeModeViewModel.commitDeletes` (`iOSCleanup/Views/Photos/SwipeModeViewModel.swift:194`) has no gate. This is correct and must stay that way.

### Implementation plan

**WS-36.1 — `CleanupAccessPolicy` and `PurchaseManager` access API**
- **Why:** fourteen hand-written rules disagree with each other and with the docs. One refactor (`> 1` changed to `>= 1`) silently paywalls single deletes.
- **Change:** create `iOSCleanup/Store/CleanupAccessPolicy.swift` with one action enum. Do **not** also add BUILD-12's `PaidFeature`-as-action enum. `PaidFeature` below is only the *reason* shown on the paywall.

```swift
enum ManualDeleteSurface: String, Sendable, CaseIterable {
    case groupDetail, screenshots, blurry, largeVideos, screenRecordings, exportAlbumWithoutExport
}
enum BulkSelectSurface: String, Sendable, CaseIterable { case screenshots, blurry, largeVideos, screenRecordings }

struct GroupSelection: Equatable, Sendable {
    let selectedIDs: Set<String>
    let recommendedIDs: Set<String>   // classifier delete candidates; [] for review-only groups
    let originalKeeperID: String?     // classifier keeper before any keeper swap (WS-04)
}

enum CleanupAction: Equatable, Sendable {
    case keepBest                                   // one classifier group (D-FREE-KEEPBEST)
    case autoCleanAll
    case groupSelection(GroupSelection)
    case manualDelete(ManualDeleteSurface, count: Int)
    case bulkSelect(BulkSelectSurface)              // Select All / Select Month / "older than" (WS-41, WS-42)
    case duckModeCommit(count: Int)
    case verifiedExportDelete(count: Int)           // D-EXPORT-DELETE
    case compressVideo
    case convertLivePhotos(count: Int)              // WS-60: one free, more than one Pro
}

enum PaidFeature: String, Sendable, Identifiable {
    case autoCleanAll, multiSelectDelete, bulkSelect, videoCompression, livePhotoBatchConversion
    var id: String { rawValue }
}
enum CleanupAccessDecision: Equatable, Sendable { case allowed, requiresUnlock(PaidFeature) }

enum CleanupAccessPolicy {
    static func decision(for action: CleanupAction, isPurchased: Bool) -> CleanupAccessDecision {
        guard let feature = paidFeature(for: action) else { return .allowed }
        return isPurchased ? .allowed : .requiresUnlock(feature)
    }
    /// nil = free for everyone.
    static func paidFeature(for action: CleanupAction) -> PaidFeature? {
        switch action {
        case .keepBest, .duckModeCommit, .verifiedExportDelete: return nil
        case .autoCleanAll: return .autoCleanAll
        case .compressVideo: return .videoCompression
        case .bulkSelect: return .bulkSelect
        case .manualDelete(_, let count): return count <= 1 ? nil : .multiSelectDelete
        case .convertLivePhotos(let count): return count <= 1 ? nil : .livePhotoBatchConversion
        case .groupSelection(let s): return isFreeGroupSelection(s) ? nil : .multiSelectDelete
        }
    }
    /// Free: ≤1 item; or a selection no larger than the recommendation whose only
    /// non-recommended member is the original keeper (a keeper swap).
    static func isFreeGroupSelection(_ s: GroupSelection) -> Bool {
        if s.selectedIDs.count <= 1 { return true }
        guard !s.recommendedIDs.isEmpty, s.selectedIDs.count <= s.recommendedIDs.count else { return false }
        let extra = s.selectedIDs.subtracting(s.recommendedIDs)
        return extra.isEmpty || (extra.count == 1 && extra.first == s.originalKeeperID)
    }
}
```

  - In the same file, add an extension on `PurchaseManager`:
    - `func accessDecision(for action: CleanupAction) -> CleanupAccessDecision`
    - `func canUse(_ action: CleanupAction) -> Bool`
    - `var showsUnlockOffer: Bool { !isPurchased }`, used by the Home "Unlock" toolbar button so that `HomeView` no longer reads `isPurchased`.
    - `func hasUnlocked(_ feature: PaidFeature) -> Bool { isPurchased }`, used by `PaywallGate` (WS-36.2) so no file under `Views/` except `PaywallView.swift` names `isPurchased`.
  - DEBUG admin access already folds into `isPurchased`, so it unlocks every case automatically.
- **Edge cases:**
  - Group detail with a *current* keeper swapped: `originalKeeperID` must be the classifier's keeper (`group.keeperAssetID`), not the swapped one.
  - `count == 0` is `.allowed`, because the commit button is disabled anyway.
  - The enum must already contain the cases WS-41 (`.bulkSelect`), WS-42 (`.manualDelete(.largeVideos/.screenRecordings, …)`, `.bulkSelect(.largeVideos)`) and WS-60 (`.convertLivePhotos`) will call. Do not implement their UI.
  - **These enums are canonical (L11).** Later workstreams call exactly these cases and add new ones only additively, each with a `CleanupAccessPolicyTests` case. None of them adds a parallel action such as `categoryBulkSelect(count:)`:
    - **WS-41** (screenshots/blurry grid): "Select All", "Select Month" and "Select Older Than 30 Days" → `.bulkSelect(.screenshots)` / `.bulkSelect(.blurry)`. A tile tap passes `allowsMultiple: canUse(.manualDelete(surface, count: 2))`, and the commit evaluates `.manualDelete(surface, count: selected.count)`. `surface` is `.screenshots` or `.blurry` (WS-36.4).
    - **WS-42** (Large Videos / screen recordings): multi-delete → `.manualDelete(.largeVideos, count: n)` or `.manualDelete(.screenRecordings, count: n)`; any Select All → `.bulkSelect(.largeVideos)` / `.bulkSelect(.screenRecordings)`. A single delete (`count: 1`) stays free.
    - **WS-59** adds `ManualDeleteSurface.largePhotos` and `BulkSelectSurface.largePhotos`, with `testLargePhotoSingleDeleteFreeMultiPro` and `testLargePhotoBulkSelectIsPro`.
    - **WS-60** uses `.convertLivePhotos(count:)` (already here), including for its Select All/Month (`count: 2` or more), with `PaidFeature.livePhotoBatchConversion`.
    - **WS-62** adds `ManualDeleteSurface.duplicateVideos`, with `testDuplicateVideoSingleFreeMultiPro`.
    - `testSingleItemDeleteIsFreeOnEverySurface` and `testMultiItemManualDeleteRequiresUnlockOnEverySurface` iterate `allCases`, so additive surfaces are covered automatically.

**WS-36.2 — Paywall presentation with context and resume (STORE-16, STORE-06 copy)**
- **Why:** gates drop the user back where they were after buying. The paywall does not say what is paid.
- **Change:**
  - New `iOSCleanup/Views/Components/PaywallGate.swift`:

```swift
struct PaywallRequest: Identifiable {
    let id = UUID()
    let feature: PaidFeature
    let resume: @MainActor () -> Void      // runs after the sheet is fully dismissed, only if unlocked
}
private struct PaywallGateModifier: ViewModifier {
    @EnvironmentObject private var purchaseManager: PurchaseManager
    @Binding var request: PaywallRequest?
    @State private var pending: PaywallRequest?
    func body(content: Content) -> some View {
        content
            .onChange(of: request?.id) { _ in if let request { pending = request } }
            .sheet(item: $request, onDismiss: finish) { r in
                PaywallView(context: r.feature).environmentObject(purchaseManager)
            }
    }
    private func finish() {
        defer { pending = nil }
        guard let pending, purchaseManager.hasUnlocked(pending.feature) else { return }
        Task { @MainActor in await Task.yield(); pending.resume() }  // let UIKit finish teardown
    }
}
extension View { func paywallGate(_ request: Binding<PaywallRequest?>) -> some View }
```

  - `PaywallView` gains `init(context: PaidFeature? = nil)`. When `context` is non-nil, it renders one extra `Text` in the existing `.duckCaption` style under "One-time purchase · No subscription":
    - `.autoCleanAll`: "Auto-clean clears every high-confidence group at once."
    - `.multiSelectDelete`: "Deleting several at once is part of PhotoDuck Pro. One at a time stays free."
    - `.bulkSelect`: "Select All and Select Month are part of PhotoDuck Pro."
    - `.videoCompression`: "Video compression is part of PhotoDuck Pro."
    - `.livePhotoBatchConversion`: "Converting many Live Photos at once is part of PhotoDuck Pro."
  - Replace `features` (`PaywallView.swift:9-14`) with:
    - "Auto-clean every duplicate group at once"
    - "Select and delete many photos and videos at once"
    - "Compress videos to save space"
    - "On-device processing — nothing uploaded"
    - "One-time unlock · No subscription"
  - Replace line 40 with: "Keep Best, single deletes, Duck Mode swipes and verified Export & Delete stay free."
  - No other visual change (Paywall redesign awaits the handoff).
  - Every gate below uses `.paywallGate($paywallRequest)` and deletes its own `showPaywall` state and `.onReceive(.purchaseDidSucceed) { showPaywall = false }`. `PaywallView` already dismisses itself on success.
- **Edge cases:**
  - Restore that finds a purchase also resumes, because `hasUnlocked` is true on dismissal.
  - Closing the sheet without buying never resumes.
  - Resumed actions that end in a PhotoKit deletion must start only after `onDismiss`, the same pattern as `PhotoResultsView.startPendingAutoCleanIfNeeded`. Otherwise iOS can suppress the system prompt.

**WS-36.3 — Group detail uses the policy (VALUE-12, STORE-06 case 1 and 3)**
- **Why:** a free user cannot delete one bad shot or narrow the suggestion without paying. This pays users to be *more* destructive.
- **Change:**
  - In `PhotoGroupDetailActionPolicy.swift` (WS-04), change the resolver so it no longer computes purchase state itself:
    `static func resolve(group: PhotoGroup, deleteSet: Set<String>, access: (CleanupAction) -> CleanupAccessDecision) -> PhotoGroupDetailPrimaryAction`
    - `.deleteSelected(ids, requiresPurchase:)` becomes `requiresPurchase = access(.groupSelection(GroupSelection(selectedIDs: deleteSet, recommendedIDs: group.isAutoCleanEligible ? Set(group.deleteCandidateIDs) : [], originalKeeperID: group.keeperAssetID))) != .allowed`.
    - Delete WS-04's temporary inline rule.
    - The view passes `purchaseManager.accessDecision(for:)`.
  - The locked button opens `PaywallRequest(feature: .multiSelectDelete, resume: { Task { await deleteSelected() } })`. `deleteSelected()` still calls `PhotoDeletionGuardrails.validateManualSelection` first, and keeper protection in `toggleSelection` is unchanged.
  - Before any selection, if `!purchaseManager.canUse(.manualDelete(.groupDetail, count: 2))`, show one caption in the existing dark-chrome caption style (`Color.white.opacity(0.75)`, `.duckCaption`):
    - Review-only groups: "Delete one photo free, or several at once with Pro."
    - Eligible groups: "Keep Best and removing photos from the suggestion are free. Adding more to delete is Pro."
- **Edge cases:**
  - A keeper swap (WS-04) that keeps the count is free. A swap plus an extra addition is Pro.
  - `visuallySimilar` groups have `recommendedIDs == []`, so only single deletes are free. They stay review-only: no automatic selection.

**WS-36.4 — Category grid (`PhotoCategoryReviewView`)**
- **Change:**
  - Add `let surface: ManualDeleteSurface` (`.screenshots` or `.blurry`), passed by `HomeView`'s tiles.
  - The commit button switches on `purchaseManager.accessDecision(for: .manualDelete(surface, count: selectedAssetIDs.count))`:
    - `.allowed`: `deleteSelectedAssets()`.
    - `.requiresUnlock(f)`: `paywallRequest = PaywallRequest(feature: f, resume: { Task { await deleteSelectedAssets() } })`.
  - The lock glyph and the "· Pro" label derive from the same decision.
  - Show the caption from the first render when multi-delete is locked (not after the 2nd selection): "Free: delete one at a time or swipe through them in Duck Mode. Pro: delete many at once. Adding to Export is always free."
  - Nothing is pre-selected (invariant 8).
- **Edge cases:** WS-41 rewrites this view's selection model (`CategorySelectionModel`) and adds Select All/Month. Keep this change minimal so WS-41 can rebase.

**WS-36.5 — Export Album gate (DEL-14, FILES-18)**
- **Change:**
  - Add `@EnvironmentObject private var purchaseManager: PurchaseManager` to `ExportAlbumView`. Inject it explicitly at both presenters: the Home Export Album tile and `FileResultsView`'s `.navigationDestination(isPresented: $showExportAlbum)` (`FileResultsView.swift:383`).
  - "Delete N from Photos" evaluates `.manualDelete(.exportAlbumWithoutExport, count: selectedAssets.count)`:
    - When locked, show the lock glyph and "Delete N from Photos · Pro", plus the caption "Deleting several without exporting is Pro. Export & Delete is free."
    - Tapping opens the paywall **before** the existing confirmation dialog. `resume` sets `showDeleteWithoutExportConfirmation = true`.
  - "Export & Delete N" and the post-export "Delete Originals" are `.verifiedExportDelete`, which is always allowed. They get no gate. Record the rule in a code comment citing D-EXPORT-DELETE.
- **Edge cases:** the Export Album pre-selects all items (no user effort), so showing the lock at render time satisfies "before effort".

**WS-36.6 — Auto-clean toolbar (STORE-08)**
- **Change:** new `iOSCleanup/Views/Photos/AutoCleanToolbarState.swift`:

```swift
enum AutoCleanToolbarState: Equatable {
    case hidden
    case locked(groupCount: Int)
    case enabled(groupCount: Int)
    static func resolve(eligibleCount: Int, access: CleanupAccessDecision) -> AutoCleanToolbarState {
        guard eligibleCount > 0 else { return .hidden }
        return access == .allowed ? .enabled(groupCount: eligibleCount) : .locked(groupCount: eligibleCount)
    }
    var title: String?   // "Auto-clean 1 group" / "Auto-clean N groups"; nil when hidden
}
```

  - `PhotoResultsView` computes `autoCleanEligibleGroups` first, using the same list WS-12's `AutoCleanPlanner` consumes.
    - `.hidden`: render no `ToolbarItem`, and never offer the paywall.
    - `.locked`: lock label, then `PaywallRequest(feature: .autoCleanAll, resume: { beginAutoCleanPlan() })`.
    - `.enabled`: the existing plan-then-confirmation-sheet flow.
  - Extract the existing body of the toolbar button into `beginAutoCleanPlan()`. Resuming shows the confirmation sheet; it never deletes directly.
  - Remove the "No high-confidence duplicate groups are safe to auto-clean in this filter…" error path, which is unreachable once the button is hidden.
- **Edge cases:** eligible count changes with the filter pill. WS-40 later excludes `.perGroupOnly` burst groups from this count.

**WS-36.7 — Files: compression gate, value-typed rows, in-sheet guard (STORE-13, FSB-11 item 4)**
- **Change:**
  - `FileResultsView.requestCompression(of:)` switches on `accessDecision(for: .compressVideo)`:
    - `.allowed`: `compressionTarget = file`.
    - `.requiresUnlock`: `PaywallRequest(feature: .videoCompression, resume: { compressionTarget = file })`.
  - `FileRow` and `LargeVideoGridCard` (in `LargeVideoRowViews.swift` after WS-10) replace `let purchaseManager: PurchaseManager` with `let compressionLocked: Bool`, computed once in `FileResultsView` as `!purchaseManager.canUse(.compressVideo)`.
  - New pure `iOSCleanup/Views/Files/VideoCompressionStartGate.swift`:

```swift
enum VideoCompressionStartGate {
    enum Outcome: Equatable { case start, requestUnlock(PaidFeature), ignore }
    static func decide(access: CleanupAccessDecision, isBusy: Bool) -> Outcome {
        if isBusy { return .ignore }
        if case .requiresUnlock(let f) = access { return .requestUnlock(f) }
        return .start
    }
}
```

  - `VideoCompressionView`:
    - Add `@EnvironmentObject private var purchaseManager: PurchaseManager`.
    - `startCompression()` calls the gate first with `isBusy = compressionTask != nil || hasSavedCopy || savedCopyAssetIdentifier != nil`.
    - On `.requestUnlock`, present the paywall through `.paywallGate` with `resume: startCompression`.
    - The Compress & Replace button shows a lock glyph when locked. No other visual change.
- **Edge cases:** every presenter of `VideoCompressionView` must inject the environment object. Today only `FileResultsView.swift:406` presents it; WS-42/WS-44 must keep this.

**WS-36.8 — PurchaseManager correctness and testability (STORE-15, STORE-16)**
- **Change** in `PurchaseManager.swift`:
  1. `refreshEntitlement`: collect `records` for `Self.productID`, then apply these rules in order:
     1. Any `.verified(_, nil)` → `applyEntitlement(…, postSuccessNotification: false)` and return true.
     2. Else any `.verified(_, date)` → `setPurchased(false, .notPurchased)` and return false.
     3. Else, if records were only `.unverified`: consult `latestTransaction`, using the same verified and revoked handling as today. If that is nil, call `preserveCachedEntitlement()` and return false. This keeps today's result for unverified-only records.
     4. Else fall through to the existing `latestTransaction` and empty-set logic unchanged.
  2. Add `enum PurchaseOutcome: Equatable, Sendable { case verified(productID: String, revocationDate: Date?), unverified(transactionID: UInt64, productID: String), pending, userCancelled, unknownResult }`.
  3. Add internal `func handlePurchaseOutcome(_:)`. `purchase()` maps `Product.PurchaseResult` to it *after* `await transaction.finish()`. Finishing stays in `purchase()`.
  4. Add internal `func handleUpdate(_ record: EntitlementRecord, transactionID: UInt64)`. `listenForTransactions` finishes the transaction first, then calls it. Behavior is identical: a verified non-revoked update posts `.purchaseDidSucceed`, a verified revocation downgrades without posting, and an unverified update notes the banner once per ID.
  5. Add `enum StoreOperation { case loadProduct, purchase, restore }` and `nonisolated static func userMessage(for error: Error, during: StoreOperation) -> String?`:
     - `StoreKitError.userCancelled` → nil.
     - `.networkError` → "Couldn't reach the App Store. Check your connection and try again."
     - `.notAvailableInStorefront` → "The PhotoDuck unlock isn't available in your App Store region."
     - `.notEntitled` → "This Apple Account doesn't own the PhotoDuck unlock."
     - `Product.PurchaseError.purchaseNotAllowed` → "Purchases are turned off on this iPhone (Screen Time)."
     - Anything else → a short operation-specific generic message. Never raw `localizedDescription`.
     - All three `catch` blocks use it. A nil message leaves `errorMessage` nil.
- **Edge cases:** keep the `EntitlementSource` seam, "inconclusive never revokes", and finishing both verified and unverified transactions (invariant 23).

**WS-36.9 — StoreKitTest purchase-flow tests (BUILD-12)**
- **Change:**
  - Add `iOSCleanup/Configuration/iOSCleanup.storekit` to the **test target's** Copy Bundle Resources in `project.pbxproj`. Create a Resources build phase for the test target if missing. Never add it to the app target.
  - Create `iOSCleanupTests/PurchaseFlowStoreKitTests.swift` (`import StoreKitTest`):
    - Create the session with `SKTestSession(contentsOf: Bundle(for: Self.self).url(forResource: "iOSCleanup", withExtension: "storekit")!)`.
    - In `setUp`, call `resetToDefaultState()` and `clearTransactions()`, and set `disableDialogs = true`.
    - Use managers built with `PurchaseManager(defaults: <isolated suite>, entitlementSource: LiveEntitlementSource(), observesTransactionUpdates: true)`. Only this class uses `true`.
  - The class must not run in parallel with other purchase tests. It runs in the default test plan (`iOSCleanup.xctestplan`, WS-06), which already sets `"parallelizable" : false` for `iOSCleanupTests`; keep that setting. There is no "Unit" plan. The session loads the `.storekit` file from the test bundle via `SKTestSession(contentsOf:)`, so do not add a StoreKit configuration key to the test plan. The plan's random ordering is fine, because `setUp` resets the session.

**WS-36.10 — Lint guard and docs**
- **Change:**
  - Add lint tests to `CleanupAccessPolicyTests`, reusing the `scanViews` pattern from `iOSCleanupTests/DesignLintTests.swift:71-98`:
    - no line under `iOSCleanup/Views/` contains `isPurchased`, except in `PaywallView.swift`;
    - no view declares `let purchaseManager: PurchaseManager`.
  - Update the nested `CLAUDE.md` "Paywall" paragraph to:
    > **Paid:** Auto-clean all; deleting more than one item at once outside a classifier recommendation (group detail beyond the suggestion, screenshot/blurry/video/screen-recording multi-select, Select All/Month, Export Album "Delete N from Photos" without export); video compression; converting more than one Live Photo. **Free:** classifier Keep Best on any eligible group, one group at a time; any single-item delete; any subset of a recommendation or a keeper swap that adds no deletions; Duck Mode swipe commits; deleting originals after a verified export. Every gate goes through `CleanupAccessPolicy`; the lock shows before selection effort, never at commit.
  - Prepare the matching one-line change for `../CLAUDE.md` (drop "contact writes"). The outer repo requires owner approval (README §3.5): ask first. If there is no approval, put the proposed text in the PR summary.

### Tests
All tests below run in the simulator.

**`iOSCleanupTests/CleanupAccessPolicyTests.swift`** (pure; no host dependencies):
- `testPolicyTableMatchesDGating`: a table of `(CleanupAction, isPurchased, expected)` covering every case at counts 0, 1, 2 and 50, for both purchase states.
- `testKeepBestIsAlwaysFree`
- `testAutoCleanAllRequiresUnlockForFreeUsers`
- `testSingleItemDeleteIsFreeOnEverySurface`: iterates `ManualDeleteSurface.allCases`.
- `testMultiItemManualDeleteRequiresUnlockOnEverySurface`
- `testExportAlbumDeleteWithoutExportFollowsMultiSelectRule`
- `testVerifiedExportDeleteIsFreeAtAnyCount`
- `testDuckModeCommitIsNeverPaywalled`
- `testBulkSelectRequiresUnlock`
- `testCompressionRequiresUnlock`
- `testLivePhotoConversionOneFreeManyPaid`
- `testPurchasedUnlocksEveryAction`
- Group selections:
  - `testStrictSubsetOfRecommendationIsFree`
  - `testKeeperSwapThatKeepsCountIsFree`
  - `testKeeperSwapPlusExtraIsPaid`
  - `testSelectionBeyondRecommendationIsPaid`
  - `testReviewOnlyGroupAllowsOneFreeDelete`
- `testNoDirectPurchaseChecksUnderViews` (lint)
- `testNoViewStoresPurchaseManagerAsPlainLet` (lint)

**`iOSCleanupTests/PhotoGroupDetailActionPolicyTests.swift`** (WS-04 file): update `resolve` call sites to pass `{ CleanupAccessPolicy.decision(for: $0, isPurchased: false) }`. Add `testSingleManualDeleteInReviewOnlyGroupIsFree` and `testSubsetOfRecommendationNeverRequiresPurchase`.

**`AutoCleanToolbarStateTests`** (in `CleanupAccessPolicyTests.swift`):
- `(0, .allowed)` → `.hidden`; `(0, .requiresUnlock)` → `.hidden`; `(3, .requiresUnlock)` → `.locked(3)`; `(3, .allowed)` → `.enabled(3)`.
- A `visuallySimilar`-only `[PhotoGroup]` fixture has `compatibleAutoCleanGroups` empty, so the state is `.hidden`.
- Title pluralization for 1 and 2.

**`VideoCompressionStartGateTests`** (same file): busy → `.ignore`; locked → `.requestUnlock(.videoCompression)`; allowed → `.start`.

**`iOSCleanupTests/PurchaseManagerTests.swift`** (stub `EntitlementSource`, observes false):
- `testUnverifiedThenVerifiedEntitlementUnlocks`: `[.unverified, .verified(nil)]` gives entitled.
- `testRevokedThenVerifiedEntitlementUnlocks`.
- `testHandleUpdateVerifiedPostsPurchaseDidSucceed`: `XCTNSNotificationExpectation`.
- `testHandleUpdateRevocationDowngradesWithoutNotification`: inverted expectation.
- `testHandlePurchaseOutcomePendingSetsStatusAndKeepsAccess`.
- `testRepeatedUnverifiedIDReportsOnce`.
- `testUserMessageIsNilForUserCancelled`.
- `testUserMessageForNetworkErrorIsActionable`.
- `testUserMessageNeverUsesLocalizedDescription`: a custom `NSError` whose `localizedDescription` is "RAW".

**`iOSCleanupTests/PurchaseFlowStoreKitTests.swift`:**
- `testPurchaseUnlocksAndCaches`: `loadProduct()`, then `purchase()`. Assert `isPurchased`, `.entitled`, and the defaults cache is true.
- `testRefundDowngradesThroughTransactionUpdates`:
  - Purchase, then `session.refundTransaction(identifier:)` using the ID from `session.allTransactions()`.
  - Await `$isPurchased == false` through a Combine sink expectation (timeout 10 s; no sleeps).
  - An inverted `.purchaseDidSucceed` expectation passes.
- `testAskToBuyApprovalUnlocksAndPostsNotification`:
  - Set `askToBuyEnabled = true` and purchase. Assert `statusMessage` is pending and `isPurchased` is false.
  - Call `approveAskToBuyTransaction(identifier:)`. The notification expectation is fulfilled and `isPurchased` is true.
- `testRestoreFindsExistingPurchase`:
  - Buy via `session.buyProduct(…)`, then create a fresh manager with empty defaults and call `restore()`. Assert `isPurchased`.
  - If `AppStore.sync()` is unsupported inside `SKTestSession` (throws or never returns within the timeout), assert through `refreshEntitlement(allowDefinitiveMissing: true)` with `LiveEntitlementSource` instead, and record the deviation in the PR.

### Acceptance criteria
- [ ] `grep -rn "isPurchased" iOSCleanup/Views` returns only `PaywallView.swift`, and the lint tests enforce it.
- [ ] Every paid gate calls `purchaseManager.accessDecision(for:)` or `canUse(_:)`. The policy tests encode D-GATING, D-FREE-KEEPBEST and D-EXPORT-DELETE.
- [ ] A free user can delete one photo from a review-only group, delete a strict subset of a Keep Best recommendation, and swap the keeper, all without a lock.
- [ ] A free user sees the multi-delete rule before selecting anything (category grid, group detail, Export Album). Every locked control shows the lock before it is tapped. Nothing paywalls at commit behind a control that looked free.
- [ ] Export Album "Delete N from Photos" with N > 1 is locked for free users. "Export & Delete" and "Delete Originals" after a verified export stay free.
- [ ] The Auto-clean toolbar is absent when zero groups are eligible (Similar tile). Its label reads "Auto-clean N groups".
- [ ] Buying from any gate continues into that action after the sheet closes, still behind the confirmation sheet or the iOS system prompt. Closing the paywall without buying does nothing.
- [ ] `VideoCompressionView` refuses to start without the entitlement even when presented directly (`VideoCompressionStartGateTests`).
- [ ] A cancelled restore shows no error. No StoreKit error shows raw `localizedDescription`.
- [ ] The StoreKitTest tests (purchase, refund, Ask to Buy approval, restore) pass in CI. `.storekit` is in the test bundle only.
- [ ] The paywall feature list and line 40 match D-GATING. The nested `CLAUDE.md` is updated. The `../CLAUDE.md` change is applied with owner approval or proposed in the PR.
- [ ] Full suite green, zero warnings.

### Device QA
Add to `docs/DEVICE_QA.md` (TestFlight sandbox account):
1. As a free user, open a Similar (review-only) group and delete one photo. There is no lock, and the iOS prompt appears.
2. Open an eligible group and unmark one suggested photo. The commit is free.
3. Select 3 screenshots. The lock is visible and the caption was visible before the first tap. Tap the locked Delete, buy in the sandbox, and confirm the iOS delete prompt appears after the paywall closes.
4. Home → Similar has no Auto-clean button. Duplicates shows "Auto-clean N groups 🔒". Buy, and the confirmation sheet appears.
5. On Restore, cancel the Apple Account sheet. No red error appears.
6. Enable Ask to Buy on a child sandbox account and approve from the parent. The app unlocks without relaunch.

### Pitfalls and out of scope
- Do not gate Duck Mode commits, per-group Keep Best, single deletes or verified Export & Delete (invariant 10, D-FREE-KEEPBEST, D-EXPORT-DELETE).
- **Free bulk path through Export & Delete.** A free user can export many items to an "On My iPhone" folder and then delete the originals for free. This is the owner-accepted D-EXPORT-DELETE trade-off and frees no space overall. Do not add a gate.
- Keep `validateManualSelection`, keeper protection, the `visuallySimilar` review-only rule and the `DeletionManager` routing unchanged (invariants 2–4).
- **Out of scope, owned elsewhere:**
  - Select All/Month and the swipe queue: WS-41 (chapter 09).
  - Video and screen-recording multi-delete: WS-42 (chapter 09).
  - Live Photo conversion UI: WS-60 (chapter 13).
  - The App Store Connect description (the local `.storekit` still says "merge contacts") and App Review notes: WS-58 (chapter 12).
  - Contrast and plural polish: WS-56 (chapter 12).
  - Paywall visual redesign: design handoff.
- `AutoCleanPlanner` batching belongs to WS-12. Only read its eligible list here.
- **Reconciliation:**
  - L11: `CleanupAction`, `ManualDeleteSurface`, `BulkSelectSurface` and `PaidFeature` are canonical, and the cases WS-41/42/59/60/62 use are listed in WS-36.1.
  - L9: the StoreKit tests run in the default test plan (`iOSCleanup.xctestplan`); there is no "Unit" plan.
  - The `../CLAUDE.md` owner-approval wording is kept (README §3 rule 5).
  - The in-sheet `VideoCompressionView` guard and `VideoCompressionStartGateTests` (FSB-11 item 4) land here; WS-56 only checks that they exist.
  - The Auto-clean count uses WS-12's eligible list, which WS-40 switches to `isAutoCleanAllEligible`.

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| STORE-06 | confirmed | All three scenarios exist in code (`PhotoGroupDetailView.swift:95-108`, `HomeView.swift:1131-1150, 1764, 1982-1994`). The reviewer's primary fix ("every user-authored selection free") is **not** used. D-GATING keeps multi-select Pro, made coherent. Subsets, single items and keeper swaps are free. |
| VALUE-12 (dup) | confirmed | The single-photo lock in group detail comes from `isPaid: !isPurchased` at any count (`:104`). Its per-surface enum is folded into `ManualDeleteSurface`. |
| BUILD-12 (dup) | confirmed | 14 view checks plus 2 in the paywall; no `SKTestSession`. Its `PaidFeature` *action* enum is not adopted. `PaidFeature` is kept only as the paywall reason, so there is one action enum. |
| DEL-14 (dup) | confirmed | `ExportAlbumView` has no `PurchaseManager`. The gate applies to "without export" only. |
| FILES-18 (dup) | confirmed | The same back door is reachable from Large Videos via "Add to Export Album". The export itself stays free; only deletion without export is gated. |
| UI-05 (dup) | partially | The inconsistency and the paywall copy are confirmed. The "one lifetime free Keep Best" fix is rejected by D-FREE-KEEPBEST, so no counter is added. |
| STORE-08 | confirmed | `PhotoResultsView.swift:111` checks purchase before eligibility. Fixed with `AutoCleanToolbarState`. |
| STORE-13 | partially | Rows hold `let purchaseManager`, but they also carry closures, so SwiftUI usually re-evaluates them. The stale glyph is not guaranteed. The value-typed fix is kept because it removes `isPurchased` from rows and enables the lint. |
| STORE-15 | confirmed | Early `return`s at `PurchaseManager.swift:251-255`. The fix keeps today's unverified-only result (preserve cache) and adds the extracted handlers for tests. |
| STORE-16 | confirmed | Raw errors at `:157, :200, :220`, no resume. Resume goes through `PaywallGate.onDismiss` instead of an `onUnlocked` closure inside `PaywallView`, so follow-up PhotoKit prompts never race the sheet teardown. |

---

## WS-37 — Analyzer signal correctness (one re-analysis)

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M2 | L | WS-22, WS-23, WS-24 | yes | `ws/37-analyzer-signal-correctness` |

**Primary files:**
- New engine files:
  - `iOSCleanup/Engines/AnalysisImagePreparation.swift`
  - `iOSCleanup/Engines/SharpnessMetrics.swift`
  - `iOSCleanup/Engines/KeeperSignalsBuilder.swift`
  - `iOSCleanup/Engines/KeeperEnrichmentService.swift`
  - `iOSCleanup/Engines/KeepBestEvidenceCollector.swift`
  - `iOSCleanup/Engines/AnalyzerUpgradePolicy.swift`
- Existing files to change:
  - `iOSCleanup/Engines/PhotoScanEngine.swift`
  - `iOSCleanup/Engines/SimilarityPolicyTypes.swift`
  - `iOSCleanup/Engines/SimilarityPolicyServices.swift`
  - `iOSCleanup/Utilities/SharedHelpers.swift`
  - `iOSCleanup/Models/PhotoReviewFeedback.swift`
  - `iOSCleanup/Engines/SimilarityCoreMLClassifier.swift`
  - `iOSCleanup/Engines/PhotoMLBridge.swift`
  - `iOSCleanup/Engines/PhotoTrainingExampleBuilder.swift`
  - `iOSCleanup/Engines/PhotoAnalysisCache.swift` (snapshot stamp only)
  - `iOSCleanup/Views/Home/AnalysisSnapshotBuilder.swift` (WS-16; stamp input only)
  - `iOSCleanup/Utilities/DebugFixtureAnalyzer.swift` and `iOSCleanup/Views/Home/HomeViewModelDependencies.swift` (WS-07; DEBUG fixture mode only)
- New test files:
  - `iOSCleanupTests/AnalyzerSignalTests.swift`
  - `iOSCleanupTests/SharpnessMetricsTests.swift`
- Existing test files to change: `iOSCleanupTests/PhotoScanEngineEndToEndTests.swift`, `iOSCleanupTests/Support/HomeViewModelTestHarness.swift`, `iOSCleanupTests/DebugFixtureAnalyzerTests.swift`, `iOSCleanupTests/ScalePerformanceTests.swift`, `iOSCleanupTests/AnalysisSnapshotBuilderTests.swift`

**Findings covered:** SCAN-10 (P1, confirmed), SCAN-11 (P2, partially), SCAN-13 (P2, confirmed), SCAN-15 (P2, confirmed)

**Decisions applied:**
- **D-REANALYSIS:** exactly one `PhotoMLBridge.analyzerVersion` bump (1 to 2) for all four findings. `favoriteBonus` and `editedBonusOrPenalty` are recomputed from the live `PHAsset` in `makeGroups`, not trusted from cache.
- **D-THRESHOLDS:** the blur ceilings are re-derived here, but similarity thresholds are not touched (WS-39).
- **DECISION (owner may override): after an analyzer upgrade, the next user-initiated scan runs as a full re-analysis. Automatic scans stay incremental. No new UI.** v1 is unreleased, so this matters only on development and TestFlight devices.

### Goal
- The keeper and the blurry category are decided by real blur (variance of Laplacian at native resolution, not a 64×64 mean), on orientation-correct pixels, with edits detected by `hasAdjustments`.
- A missing blur-confirmation image never erases keeper evidence and never promotes an unmeasured photo to "Best".
- Keep-Best-bound groups rank members with ≥1,024 px native sharpness and face-capture quality, bounded and local-only.
- One analyzer bump that actually reaches the saved results.

### Current behavior (verified)
**Edit detection:**
- `PHAsset.isEdited` is `abs(modificationDate − creationDate) > 1` (`iOSCleanup/Utilities/SharedHelpers.swift:493-496`).
- The same logic is duplicated in:
  - `SimilaritySignalBuilder.descriptor` (`iOSCleanup/Engines/SimilarityPolicyTypes.swift:360-366`)
  - `keeperSignals(for:)` (`:393-398`)
  - `photoReviewFeedbackAsset` (`iOSCleanup/Models/PhotoReviewFeedback.swift:244-248`)
  - `GroupActionPredictionInput(group:)` (`iOSCleanup/Engines/SimilarityCoreMLClassifier.swift:459-462`)
- Divergence produces:
  - the `.editedStateDivergence` soft blocker (`SimilarityPolicyServices.swift:90-93`);
  - `.editedToOriginal` (`SimilarityPolicyTypes.swift:346-348`), which leads to "Variant pair stays review-only" (`SimilarityPolicyServices.swift:187-191`);
  - "Preferred edit" +0.04 in keeper ranking (`:300-303`).
- `hasAdjustments` is available on iOS 15+ (checked in `Photos.framework/Headers/PHAsset.h:68`).

**Sharpness:**
- `makeKeeperSignals` (`PhotoScanEngine.swift:1116-1204`) draws into a 64×64 gray context and computes `sharpness = clamp(mean|Laplacian| / 45)` and `blurPenalty = 1 − sharpness`.
- It sets `eyesOpenScore` and `expressionScore` to nil, and bakes `favoriteBonus` and `editedBonusOrPenalty` from the asset (`:1199-1200`).
- The keeper score is in `ConservativeKeeperRankingService` (`SimilarityPolicyServices.swift:260-328`): `0.36·sharpness − 0.28·blurPenalty − …`.

**Blur confirmation:**
- In `analyzeAsset` (`PhotoScanEngine.swift:1037-1053`), when thumbnail sharpness ≤ 0.22, a 1,024 px `.analysis` image is loaded, and **keeperSignals becomes nil** if it is unavailable.
- If the image is available, it is downsampled to 64×64 again, so the confirmation adds almost nothing.

**Blurry category:** `PhotoReviewCategoryClassifier.classify(isScreenshot:sharpness:)` (`:1747-1760`) uses `sharpness <= PhotoScanDefaults.blurryPhotoSharpnessCeiling` (0.22, `:1695`), with no texture gate.

**Missing signals:**
- `makeGroups` substitutes `SimilaritySignalBuilder.keeperSignals(for:)` for missing signals (`:1310-1318`): `sharpness = resolutionScore` (≈0.885 for 12 MP).
- The group becomes review-only through `hasCompleteKeeperEvidence` (`:1351-1356`), but the unmeasured photo usually outranks measured ones and gets "Best". `KeeperSignals.conservativeFallback` (`SimilarityPolicyServices.swift:862-876`) has the same optimism.

**Orientation:** `guard let image = loadedImage, let cgImage = image.cgImage` (`PhotoScanEngine.swift:1033`) drops `imageOrientation`. `VNImageRequestHandler(cgImage:options:)` (`:1057-1060`), the hash (`:1092-1107`) and the signals (`:1122-1134`) all use the raw buffer.

**Caching:**
- `KeeperSignals` (`SimilarityPolicyTypes.swift:142-153`) is `Codable` and persisted as JSON in `photo_asset_analysis`.
- The cache is valid only when `analyzerVersion` matches (`PhotoMLBridge.swift:19, 150-185`).
- **The analysis snapshot has no analyzer stamp.** `PhotoScanResumePlanner.requiredAssetIDs` (`PhotoAnalysisCache.swift:268-330`) re-targets only new, modified or unanalyzed IDs. A bump alone would never recompute existing groups.

**Feature schema versions:** `PhotoTrainingExampleBuilder.featureSchemaVersion = 2` (`PhotoTrainingExampleBuilder.swift:4`) and `PhotoReviewFeedbackVersions.featureSchemaVersion = 1` (`PhotoReviewFeedback.swift:7`).

### Implementation plan

**WS-37.1 — Verify-first: edit state on a real device**
- **Why:** SCAN-10's severity depends on PhotoKit behavior: does favoriting or importing move `modificationDate`, and is `hasAdjustments` false for those?
- **Change:**
  1. Read the WS-09 baseline in `docs/qa-runs/`, which records hasAdjustments vs modificationDate for favorited, imported and edited photos.
  2. If the baseline is missing, run this check on a device with a DEBUG build: favorite an untouched photo, crop another, AirDrop one in. Log `(hasAdjustments, abs(mod−create) > 1)` per asset with a temporary `#if DEBUG` `os_log` in `SimilaritySignalBuilder.descriptor`, and remove the log before merge. Record the results in the PR.
  3. Proceed only if `hasAdjustments` is false for favorited and imported photos and true for the cropped one.
  4. If `hasAdjustments` is wrong, fall back to detecting edits by the presence of a `.adjustmentData` resource via `PHAssetResource.assetResources(for:)`. This is metadata only, but call it only inside `makeGroups` for cluster members, never per asset in the hot path.

**WS-37.2 — One definition of "edited", and live favorite/edit signals (SCAN-10, D-REANALYSIS)**
- **Change:**
  - `SharedHelpers.swift:493`: `var isEdited: Bool { hasAdjustments }`, with a doc comment that `modificationDate` is only a cache-invalidation key.
  - Replace every duplicated date comparison with `asset.isEdited`:
    - `SimilarityPolicyTypes.swift:361-366`, `:393-398`
    - `PhotoReviewFeedback.swift:244-248` (`isEdited = isEdited` stays optional)
    - `SimilarityCoreMLClassifier.swift:459-462` (`editedCount = group.assets.filter(\.isEdited).count`)
  - Bump `PhotoTrainingExampleBuilder.featureSchemaVersion` to 3 and `PhotoReviewFeedbackVersions.featureSchemaVersion` to 2, because `is_edited` changes meaning.
  - In `PhotoPreferenceProfileStore.swift:138`, count an event toward `profile.edited` only when `event.featureSchemaVersion >= 2`.
  - Add, in `iOSCleanup/Engines/KeeperSignalsBuilder.swift`:

```swift
extension KeeperSignals {
    /// Cached analyses never carry user state; overlay the live PHAsset values.
    func withLiveAssetState(isFavorite: Bool, isEdited: Bool) -> KeeperSignals {
        var copy = self
        copy.favoriteBonus = isFavorite ? 0.08 : 0
        copy.editedBonusOrPenalty = isEdited ? 0.04 : 0
        return copy
    }
}
```

  - Change `favoriteBonus` and `editedBonusOrPenalty` from `let` to `var`.
  - `analyzeAsset` stores 0 for both.
  - `makeGroups` applies `withLiveAssetState(isFavorite: asset.isFavorite, isEdited: asset.isEdited)` to every member's signals before building `SimilarityClusterInput`.
- **Edge cases:** WS-13 relies on `favoriteBonus` staying in the score (favorites are protected from deletion, not ranked first). Do not change the 0.08 and 0.04 weights.

**WS-37.3 — Orientation-correct analysis pixels (SCAN-15)**
- **Change:** new `iOSCleanup/Engines/AnalysisImagePreparation.swift`:

```swift
extension CGImagePropertyOrientation {
    init(_ o: UIImage.Orientation) {
        switch o {
        case .up: self = .up; case .upMirrored: self = .upMirrored
        case .down: self = .down; case .downMirrored: self = .downMirrored
        case .left: self = .left; case .leftMirrored: self = .leftMirrored
        case .right: self = .right; case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
enum AnalysisImagePreparation {
    /// Returns pixels in display orientation. Cheap at analysis sizes (≤1,024 px).
    static func uprightCGImage(from image: UIImage) -> CGImage? {
        guard let cg = image.cgImage else { return nil }
        guard image.imageOrientation != .up else { return cg }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: image.size, format: format)
            .image { _ in image.draw(in: CGRect(origin: .zero, size: image.size)) }.cgImage
    }
}
```

  - `analyzeAsset` renders the upright image once and reuses it for:
    - `VNImageRequestHandler(cgImage: upright, orientation: .up, options: [:])`
    - `makePerceptualHash`
    - signals
    - the 1,024 px confirmation (also uprighted)
  - Keep WS-22's CPU-retry and failure-reason code paths intact.
- **Edge cases:** `UIGraphicsImageRenderer` is safe off the main thread. Keep it inside the existing `PhotoScanSynchronousAnalysisExecutor` or the analysis task. Never render on the main actor.

**WS-37.4 — Real sharpness and edge density (SCAN-11, part 1)**
- **Change:** new pure `iOSCleanup/Engines/SharpnessMetrics.swift` (`import Accelerate`; system framework, not SPM):

```swift
struct SharpnessMeasurement: Equatable, Sendable {
    let laplacianVariance: Double      // variance of 3×3 Laplacian, 0…1 intensity units
    let normalizedSharpness: Double    // clamp(log1p(v·k) / log1p(ref·k), 0, 1)
    let edgeDensity: Double            // coarse-scale structure: fraction of pixels whose Sobel magnitude > threshold
    let directionalImbalance: Double   // |Σ|gx| − Σ|gy|| / max(...)
}
enum SharpnessTuning {                  // derived from fixtures in this PR; values recorded in the PR
    static let analysisReferenceVariance: Double        // 224 px thumbnail scale
    static let confirmationReferenceVariance: Double    // ≥1,024 px native scale
    static let edgeGradientThreshold: Double            // on the 256 px coarse copy
    static let centerCropFraction = 0.8
}
enum SharpnessMetrics {
    /// Measures at the image's own resolution (no 64×64 downsample). Center-weighted 80% crop.
    static func measure(_ image: CGImage, referenceVariance: Double) -> SharpnessMeasurement?
}
```

  - Implementation outline:
    - Convert to Planar8 grayscale at native size, crop, and convert to PlanarF with `vImageConvert_Planar8toPlanarF`.
    - Apply the Laplacian with `vImageConvolve_PlanarF` (kernel `[0,1,0, 1,−4,1, 0,1,0]`).
    - Compute the mean and variance with `vDSP_meanv` and `vDSP_measqv`.
    - Edge density: downscale the gray crop to a 256 px long side with `vImageScale_Planar8`, apply Sobel on the downscaled copy, and take the fraction above the threshold.
    - Low-texture scenes (night sky, snow, plain walls) have near-zero coarse structure. A shaken textured scene keeps coarse edges but loses fine Laplacian energy.
  - New `iOSCleanup/Engines/KeeperSignalsBuilder.swift` holds `static func make(from upright: CGImage, asset: PHAsset, referenceVariance: Double) -> KeeperSignals?`:
    - `sharpness = m.normalizedSharpness` at 224 scale, and `blurPenalty = 1 − sharpness`.
    - `motionBlurPenalty` uses today's formula with the new imbalance.
    - Exposure, framing and the resolution tie-breaker are unchanged.
  - The `makeKeeperSignals` and `makePerceptualHash` statics that WS-07 exposed for the DEBUG fixture analyzer stay as thin wrappers, so the fixture analyzer keeps compiling.
- **Edge cases:** do not mix scales inside one ranking.
  - `sharpness` is always the 224 px metric for every asset.
  - Native values live in separate optional fields (WS-37.5, WS-37.7).

**WS-37.5 — Blur confirmation that keeps evidence, and a gated blurry category (SCAN-11, SCAN-13)**
- **Change:** add optional fields to `KeeperSignals`. Declare them as `var … : T? = nil`, so the synthesized memberwise init keeps compiling and synthesized `Decodable` uses `decodeIfPresent` for old JSON:

```swift
enum BlurConfirmation: String, Codable, Sendable { case confirmed, unconfirmed, notNeeded }
// in struct KeeperSignals:
var blurConfirmation: BlurConfirmation? = nil
var confirmedSharpness: Double? = nil   // ≥1,024 px native-scale normalized sharpness
var edgeDensity: Double? = nil          // from the confirmation image when confirmed, else the 224 px image
var nativeSharpness: Double? = nil      // WS-37.7 enrichment
var isFallback: Bool? = nil             // WS-37.6
```

  - `analyzeAsset` flow:
    1. If 224 px `sharpness <= PhotoScanDefaults.blurCandidateCeiling`, load the 1,024 px `.analysis` image (same network flag), upright it, and measure it with `confirmationReferenceVariance`.
    2. If the image is available: `.confirmed`, and set `confirmedSharpness` and `edgeDensity`.
    3. If it is unavailable: keep the 224 px signals and mark `.unconfirmed`. **Never nil.**
    4. Otherwise: `.notNeeded`.
  - Replace `PhotoScanDefaults.blurryPhotoSharpnessCeiling` with three constants:
    - `blurCandidateCeiling` (224 scale)
    - `blurryConfirmedSharpnessCeiling` (native scale)
    - `minimumEdgeDensityForBlurry`
    - Derive all three with the fixtures in the Tests section and record the values and fixture results in the PR.
  - `PhotoReviewCategoryClassifier.classify(isScreenshot: Bool, signals: KeeperSignals?) -> PhotoReviewCategory?`:
    - Screenshot → `.screenshot`.
    - Blurry only when `blurConfirmation == .confirmed`, `confirmedSharpness <= blurryConfirmedSharpnessCeiling` and `edgeDensity >= minimumEdgeDensityForBlurry`.
    - Update the call site (`PhotoScanEngine.swift:707-716`).
  - **DEBUG fixture mode (WS-07.8 forward contract).** `DebugFixtureAnalyzer.analysis(for:asset:)` must emit **confirmed** blur signals, or `blurredForest` would drop out of the blurry category in the simulator. Measure the fixture image with `SharpnessMetrics.measure(_, referenceVariance: SharpnessTuning.confirmationReferenceVariance)`, then set `blurConfirmation = .confirmed`, `confirmedSharpness` and `edgeDensity` from it. Update `DebugFixtureAnalyzerTests.testOnlyBlurredForestIsBlurryCategory` so it asserts through `PhotoReviewCategoryClassifier.classify(isScreenshot:signals:)` (only `blurredForest` is `.blurry`). The old 0.15/0.30 sharpness bounds were tuned on the 64×64 metric.
- **Edge cases:**
  - An unconfirmed photo is never blurry.
  - The category stays review-only and never pre-selects anything (invariant 8).
  - The confirmation load count is bounded by the candidate ceiling. Keep `blurCandidateCeiling` low enough that fixtures show ≤ ~15% of natural-texture images become candidates.

**WS-37.6 — Neutral-pessimistic fallback; measured members outrank unmeasured (SCAN-13)**
- **Change:**
  - Replace both optimistic fallbacks (`SimilaritySignalBuilder.keeperSignals(for:)` and `KeeperSignals.conservativeFallback(for:)`) with one function in `KeeperSignalsBuilder.swift`:
    `static func neutralFallback(for descriptor: SimilarityAssetDescriptor, measuredPeers: [KeeperSignals]) -> KeeperSignals`
    - `sharpness = measuredPeers.map(\.sharpness).min() ?? 0.5`
    - `blurPenalty = 1 − sharpness`
    - `motionBlurPenalty = 0.3`
    - `exposureScore = 0.5`
    - framing and resolution computed as today
    - `isFallback = true`
  - `makeGroups` passes the cluster's measured signals as `measuredPeers`.
  - In `ConservativeKeeperRankingService.rankKeeper`, after scoring: if at least one member has `isFallback != true`, clamp every fallback member's score to `min(measured scores) − 0.01` and add the reason "Not measured".
  - Mirror the rule in `MLEnhancedKeeperRankingService`: reject an ML winner that is fallback-only while a measured member exists, the same way WS-13 rejects a non-favorite winner.
- **Edge cases:** groups with any fallback member remain review-only through `hasCompleteKeeperEvidence`. Keep that check. With WS-37.5, far fewer members lack signals.

**WS-37.7 — Keeper enrichment for Keep-Best-bound clusters (SCAN-11, part 2)**
- **Why:** 224 px cannot see handheld shake on a 12 MP frame (σ≈2 px at 1,024 is ≈0.4 px at 224). The keeper matters only where a plan will delete.
- **Change:** new `iOSCleanup/Engines/KeeperEnrichmentService.swift`:

```swift
struct KeeperEnrichment: Equatable, Sendable { let nativeSharpness: Double?; let faceCaptureQuality: Double? }
protocol KeeperEnriching: Sendable {
    func enrich(_ assets: [PHAsset], allowNetworkAccess: Bool) async -> [String: KeeperEnrichment]
}
protocol FaceCaptureQualityProviding: Sendable { func quality(for upright: CGImage) async -> Double? }  // nil = no faces / unavailable
actor KeeperEnrichmentService: KeeperEnriching {
    init(imageLoader: @escaping @Sendable (PHAsset, Bool) async -> UIImage? = { /* PhotoImageRepository .analysis, 1,024 aspectFit */ },
         faceQuality: any FaceCaptureQualityProviding = VisionFaceCaptureQualityProvider(),
         maxConcurrent: Int = 4, maxAssetsPerRun: Int = 2_000)
    // memo keyed by (localIdentifier, modificationDate); bounded LRU of 4,096 entries
}
```

  - `VisionFaceCaptureQualityProvider` runs `VNDetectFaceCaptureQualityRequest` on the upright 1,024 px image and returns the max `faceCaptureQuality`, or nil. It uses the same CPU-in-simulator setting as WS-07's `makePinnedFeaturePrintRequest`.
  - New `iOSCleanup/Engines/KeepBestEvidenceCollector.swift` is the **single** call site in `makeGroups` for Keep-Best-bound work. WS-38 extends it.
    - Actor `KeepBestEvidenceCollector` with `init(enricher: any KeeperEnriching)`.
    - `func collect(assets: [PHAsset], input: SimilarityClusterInput, allowNetworkAccess: Bool) async -> KeepBestEvidence`.
    - `KeepBestEvidence` carries `input: SimilarityClusterInput`, which may be enriched.
  - A cluster is Keep-Best-bound when all of these hold:
    - `evaluation.groupResult.action == .suggestDeleteOthers`
    - `bucket != .visuallySimilar`
    - complete keeper evidence
    - `assets.count <= SimilarityThresholds.maxBurstAssetsPerCluster`
  - Enrichment rules:
    - If **every** member received `nativeSharpness`, set `sharpness = nativeSharpness` and `blurPenalty = 1 − nativeSharpness` for all members (one consistent scale). Otherwise keep the 224 values for all.
    - If every member with a face returned a quality and at least one has a face, set `eyesOpenScore = expressionScore = faceCaptureQuality` on those members. Per SCAN-11, use this one signal for both until a better one exists.
    - Then re-run `similarityPolicyEngine.evaluateCluster` with the enriched input.
  - `PhotoScanEngine.init` gains `keepBestEvidence: KeepBestEvidenceCollector = KeepBestEvidenceCollector(enricher: KeeperEnrichmentService())`.
  - Add `#if DEBUG struct NoOpKeeperEnricher: KeeperEnriching` (returns `[:]`) in `KeeperEnrichmentService.swift`. It lives in the app target so both fixture mode and tests can use it.
  - **Inject `KeepBestEvidenceCollector(enricher: NoOpKeeperEnricher())` into every engine built over fake assets or in the simulator, in this PR.** Otherwise the default loader calls PhotoKit on fake assets. The sites are:
    - WS-08's `makeEndToEndEngine` helper, which covers every `PhotoScanEngineEndToEndTests` test;
    - WS-07's `HomeViewModelTestHarness.makeIsolatedDependencies` → `makePhotoScanEngine`;
    - the engine-level `DebugFixtureAnalyzerTests.testFixtureLibraryScanProducesExpectedGroups`;
    - WS-08's benchmark 7, `ScalePerformanceTests.testEngineThroughputWithFiveMillisecondAnalyzer`;
    - the DEBUG fixture mode `HomeViewModelDependencies.debugFixture()` → `makePhotoScanEngine` (WS-07.8), because face-quality requests fail in the simulator.

    Also grep `PhotoScanEngine(` under `iOSCleanupTests/`: any other test that asserts a Keep Best plan over fake assets gets the same injection.
- **Edge cases:**
  - Loads are local-only unless the user opted into network for this scan (invariant 11).
  - Over `maxAssetsPerRun`, clusters keep 224 signals and remain subject to the 0.08 margin.
  - Enrichment happens before the group is first published, so partial results never show a different keeper than the final one.
  - Do not change the WS-24 loop. This runs inside `makeGroups` only.

**WS-37.8 — One analyzer bump that reaches saved results (D-REANALYSIS)**
- **Change:**
  - Set `PhotoMLBridge.analyzerVersion = 2`. WS-22, WS-24 and WS-38 must not bump it.
  - Add `let analyzerVersion: Int?` to `CachedPhotoAnalysisSnapshot`: add it to `CodingKeys`, decode it with `decodeIfPresent` (nil means 1), and default it to `nil` in `init`. No snapshot schema bump (`schemaVersion` stays 7).
  - The stamp is **carried, never defaulted.** Every rebuild copies the source snapshot's value, exactly as chapter 04 does for `libraryChangeTokenData`: `withPersistenceGeneration`, `repairingPrematureCompletion`, WS-19's `droppingUncoveredInventory`, and WS-18's `persistChangeToken`. WS-16's `AnalysisSnapshotInputs` gains `analyzerVersion: Int?` (default nil), which `AnalysisSnapshotBuilder.build(inputs:isComplete:)` writes. The facade fills it from the run-scoped stamp during a run, and from the restored snapshot's value for checkpoint, reconcile and prune rebuilds (WS-21's `PhotoResultPruner` paths included). WS-54's write-path rewrite (chapter 11) must keep carrying it.
  - **Golden tests (L14).** WS-16's `AnalysisSnapshotBuilderTests` golden literals do not change: their inputs leave `analyzerVersion` nil, and the synthesized encoder omits nil. Following WS-16's additive-field rule, the field gets its own round-trip test instead of a golden edit.
  - The stamp is set to `PhotoMLBridge.analyzerVersion` only for runs that started from a full plan (`requiredAssetIDs == nil`). Hold a run-scoped `runAnalyzerStamp` next to the run's scan ID.
  - New pure `iOSCleanup/Engines/AnalyzerUpgradePolicy.swift`:
    - `static func requiresFullReanalysis(snapshotAnalyzerVersion: Int?, current: Int, isUserInitiated: Bool) -> Bool`
    - It returns `isUserInitiated && (snapshotAnalyzerVersion ?? 1) != current`.
    - Where `PhotoScanResumePlanner.requiredAssetIDs(snapshot:currentAssetIDs:currentMetadata:mode:forceFullRescan:retryAssetIDs:)` is called in `scanPhotos`, pass `forceFullRescan: existing || AnalyzerUpgradePolicy.requiresFullReanalysis(…, isUserInitiated: origin == .userInitiated)`. `origin` is WS-26's required `scanPhotos(…origin:)` parameter, so every user entry point (`startPhotoScan(from:)` → `runUserInitiatedScan`, `retryIncludingICloudPhotos`, a new-run `resumeDeepClean`) counts, and every automatic caller (`scanNewPhotosIfNeeded`, reconcile, WS-19/WS-21 follow-ups) does not.
- **Edge cases:**
  - Automatic scans stay incremental. Their context-cache misses re-analyze context assets, which is bounded.
  - Rows in `photo_asset_analysis` whose `analyzerVersion` differs from the current `PhotoMLBridge.analyzerVersion` become dead. WS-46 (chapter 10) purges every such row (`analyzerVersion != current`, not only version 1), so any later bump is covered too.

### Tests
**Pure tests** (simulator), in `iOSCleanupTests/AnalyzerSignalTests.swift`.

The test asset double: extend WS-08's `ConfigurablePhotoScanTestAsset` with `override var hasAdjustments: Bool` and `modificationDate` if absent.

Edit state:
- `testImportedAssetWithLaterModificationDateIsNotEdited`: `mod = create + 1 day`, `hasAdjustments = false` gives `descriptor.isEdited == false`.
- `testFavoritedPairTwoSecondsApartStaysNearDuplicate`: distance 0.01 → `.nearDuplicate` with no `.editedStateDivergence`.
- `testRealAdjustmentKeepsPairReviewOnly`: `hasAdjustments = true` on one member → review-only.

Orientation:
- `testOrientationMappingCoversAllEightCases`
- `testUprightRenderingMatchesPreRotatedImage`: a raw buffer rotated 90° with `UIImage(cgImage:scale:orientation: .right)` gives `uprightCGImage` equal to the upright fixture (±1 per channel).
- `testPerceptualHashIsOrientationInvariant`

Live signals, fallback, ranking and decoding:
- `testLiveFavoriteOverridesCachedBonus`: cached signals carry `favoriteBonus 0.08`; the asset is not a favorite now; the ranking input carries 0.
- `testFallbackMemberNeverOutranksMeasuredMember`
- `testNeutralFallbackUsesMinimumMeasuredSharpness`
- `testLegacyKeeperSignalsJSONDecodes`: JSON without the new keys decodes; the new fields are nil.
- `testKeeperSignalsRoundTripWithNewFields`

Blurry category:
- `testUnconfirmedSignalsAreNeverBlurry`
- `testLowEdgeDensityIsNeverBlurry`
- `testConfirmedLowSharpnessWithStructureIsBlurry`
- Replace `testBlurryCategoryUsesConservativeTuningBoundary` in `PhotoScanEngineTests.swift:331-351` with a version for the new signature.

Upgrade policy:
- `testAnalyzerUpgradeForcesFullPlanOnlyWhenUserInitiated`
- `testSnapshotWithoutAnalyzerVersionDecodesAsVersionOne`
- `testSnapshotRebuildCarriesAnalyzerStamp`: `withPersistenceGeneration`, `repairingPrematureCompletion` and `droppingUncoveredInventory` each preserve nil and preserve 2.
- `AnalysisSnapshotBuilderTests.testAnalyzerStampRoundTrips`: the existing goldens are unchanged, and an input with `analyzerVersion: 2` encodes the key and decodes back to 2.
- `testUserInitiatedScanAfterUpgradePlansFullLibrary` (`HomeViewModelTests`, WS-07 harness): a restored snapshot without a stamp. `startPhotoScan(from: .homePrimaryCTA)` analyzes every asset, while an automatic `scanNewPhotosIfNeeded()` analyzes only new ones.

**`iOSCleanupTests/SharpnessMetricsTests.swift`** (simulator). Synthetic fixtures are drawn with CoreGraphics at test time; there are no binary files.
- `testCheckerboardSharperThanBlurredCopy`: 1,024 px checkerboard vs a σ=2 px tent blur (`vImageTentConvolve_Planar8`). The difference in `normalizedSharpness` is ≥ 0.2.
- `testNativeScaleDetectsBlurThat224Misses`: the same pair measured after downscaling to 224 differs by < 0.05, and at 1,024 by ≥ 0.1. This documents SCAN-11.
- `testSmoothGradientHasLowEdgeDensity`: below `minimumEdgeDensityForBlurry`.
- `testBlurredTexturedSceneKeepsEdgeDensity`: above it.
- `testSharpTextPageIsNotBlurry`
- `testMeasureIsDeterministic`

**Engine tests** (`iOSCleanupTests/PhotoScanEngineEndToEndTests.swift`, WS-08):
- `testEnrichmentPicksNativeSharpestKeeper`:
  - Two near-duplicates have equal 224 signals.
  - A stub `KeeperEnriching` returns native 0.9 vs 0.5.
  - The keeper is the 0.9 member, and the group is Keep Best when the margin passes.
- `testMissingConfirmationKeepsGroupEligibleAndOutOfBlurry`:
  - The analyzer returns `.unconfirmed` signals for one member.
  - The group's eligibility is unchanged, and the asset is not in `blurryAssets`.
- Update `testEndToEndBlurryCategory`: its injected signals must now carry `blurConfirmation: .confirmed, confirmedSharpness: 0.1, edgeDensity: 0.2`. Say in the PR that the blurry rule now requires confirmation and structure.
- All WS-08 end-to-end tests inject `NoOpKeeperEnricher` through `makeEndToEndEngine`, because the default loader would call PhotoKit on fake assets. The same applies to the WS-07 harness, `testFixtureLibraryScanProducesExpectedGroups` and benchmark 7 (see WS-37.7).
- `DebugFixtureAnalyzerTests.testOnlyBlurredForestIsBlurryCategory`, updated as in WS-37.5, stays green with confirmed fixture signals.

**Device-only:** see Device QA.

### Acceptance criteria
- [ ] The WS-37.1 device evidence for `hasAdjustments` is recorded in the PR.
- [ ] Exactly one `analyzerVersion` bump (to 2). The snapshot carries the stamp. The next user-initiated scan after upgrading is a full re-analysis; automatic scans are not.
- [ ] Every "edited" decision uses `asset.isEdited` (`hasAdjustments`). `grep -rn "modificationDate.timeIntervalSince(creationDate)" iOSCleanup` returns nothing.
- [ ] Favorite and edited keeper bonuses come from the live asset in `makeGroups`.
- [ ] Vision, the hash and the signals use one upright image per asset.
- [ ] The blurry category requires a confirmed ≥1,024 px native measurement and edge density ≥ threshold. Unconfirmed photos are never blurry.
- [ ] Keep-Best-bound clusters rank on native ≥1,024 px sharpness when available for all members, plus face capture quality. The work is bounded (`maxAssetsPerRun`, concurrency 4) and local-only by default.
- [ ] A fallback-only member is never keeper while a measured member exists.
- [ ] `KeeperSignals` new fields decode from legacy JSON.
- [ ] Feature schema versions are bumped (training 3, feedback 2).
- [ ] WS-08 end-to-end tests are green (blurry fixture updated and explained).
- [ ] Full suite green, zero warnings. `CLAUDE.md`'s `PhotoScanEngine` and keeper-ranking notes mention native-resolution blur and the edge-density gate.

### Device QA
1. On a 10k library after upgrading from a pre-WS-37 build, tap Scan. The run re-analyzes everything (the unanalyzed count resets and progress restarts), and total time is recorded in the QA run.
2. Open the Blurry tile. Spot-check 30 items: none should be a sharp night sky, snow scene, plain wall or bokeh portrait. Record the count before and after.
3. Take 3 handheld frames in 2 s, one with deliberate shake. If a Keep Best group forms, its keeper is not the shaken frame.
4. Favorite one of two identical frames. The group stays near-duplicate, not "Original and edited variant".
5. AirDrop in a portrait JPEG and a copy of it. They group together.

### Pitfalls and out of scope
- Reconciliation (from chapter 13): WS-63.6 later adds one more `forceFullRescan` term at the planner call site this workstream introduces (a similarity-threshold revision mismatch triggers a full re-analysis on the next user-initiated scan, like `analyzerVersion`). Keep the call site's combined `forceFullRescan` expression easy to extend.
- **Never mix measurement scales in one ranking**: 224 values vs native values. The all-members-or-none rule in WS-37.7 is mandatory.
- **Never let a nil confirmation erase signals.** That is exactly SCAN-13.
- Keep blur confirmation. `PERFORMANCE_MASTER_PROMPT` forbids removing it, and invariant 22 applies.
- Do not change similarity thresholds (WS-39) or bypass the 0.08 margin (WS-38).
- Do not touch the WS-24 pipeline, the WS-22 failure reasons, or the Vision revision pin (invariant 12).
- Resolution and Live Photo keeper tie-breaks from SCAN-11 item 3 are not added. Identical-copy tie-breaks come in WS-38.
- ML-store row purge belongs to WS-46 (chapter 10).
- **Reconciliation:**
  - L14: the `analyzerVersion` stamp is carried through chapter 04's actual rebuild sites (`withPersistenceGeneration`, `repairingPrematureCompletion`, `droppingUncoveredInventory`, `persistChangeToken`, `AnalysisSnapshotInputs`), and WS-16's goldens stay byte-identical. The user-initiated flag is WS-26's `origin` parameter at the planner call site in `scanPhotos`. WS-46 purges `photo_asset_analysis` rows whose `analyzerVersion != current`.
  - Lead item (chapters 01–02 final): the no-op enricher reaches every engine built in tests (the WS-08 helper, the WS-07 harness, `testFixtureLibraryScanProducesExpectedGroups`, benchmark 7) and DEBUG fixture mode. `DebugFixtureAnalyzer` emits confirmed blur signals so `blurredForest` stays blurry (WS-07.8 forward contract).

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| SCAN-10 | confirmed | The code facts are certain: 4 duplicates of the date heuristic, the divergence blocker and variant downgrade, and the +0.04 keeper bonus. How often favoriting or importing moves `modificationDate` is device behavior, so WS-37.1 checks it first. Per D-REANALYSIS, the pair-level fix needs no bump (pair rows store distances only). The bonuses are overlaid live instead of cached. |
| SCAN-11 | partially | The metric facts are confirmed (`PhotoScanEngine.swift:1116-1170`), but deletion harm today is limited by the 0.08 margin, so P2. The reviewer's "224 px analysis image" fix is corrected: native ≥1,024 px variance of Laplacian for confirmation and for Keep-Best-bound enrichment, and 224 px only for comparable in-cluster ranking. The edge density is coarse-scale structure, so blurred textured scenes still qualify while flat scenes do not. |
| SCAN-13 | confirmed | `keeperSignals = confirmationImage?.cgImage.flatMap {…}` becomes nil when the image is missing (`:1050-1052`). The fallback's sharpness is ≈0.885. The new fields are declared as optional `var`s, so both old JSON and the memberwise init keep working. |
| SCAN-15 | confirmed | Orientation is dropped at `:1033`. Real-world frequency depends on how often the `.analysis` (original-decode) fallback runs. The fix is cheap and bundled into the one bump. |

---

## WS-38 — Duplicate verification and one-tap identical copies

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M2 | L | WS-13, WS-37 | no | `ws/38-duplicate-verification` |

**Primary files:**
- New engine files:
  - `iOSCleanup/Engines/DuplicateVerificationService.swift`
  - `iOSCleanup/Engines/DuplicatePixelComparator.swift`
  - `iOSCleanup/Engines/TextTokenRecognizer.swift`
  - `iOSCleanup/Engines/KeeperTieBreaker.swift`
  - `iOSCleanup/Engines/ScreenshotHashIndex.swift`
- Existing files to change:
  - `iOSCleanup/Engines/KeepBestEvidenceCollector.swift` (WS-37)
  - `iOSCleanup/Engines/PhotoScanEngine.swift`
  - `iOSCleanup/Engines/PhotoScanWorkingSet.swift` and `iOSCleanup/Engines/PhotoScanResidentFeatures.swift` (WS-23; screenshot hash index only)
  - `iOSCleanup/Engines/SimilarityPolicyTypes.swift`
  - `iOSCleanup/Engines/PreferenceAdjustedRecommendationService.swift`
  - `iOSCleanup/Engines/SimilarityPolicyServices.swift`
  - `iOSCleanup/Views/Home/HomeViewModelDependencies.swift` (WS-07; DEBUG fixture mode only)
- Tests:
  - `iOSCleanupTests/DuplicateVerificationTests.swift` (*new*)
  - `iOSCleanupTests/Support/StubDuplicateVerifier.swift` (*new*)
  - `iOSCleanupTests/PhotoScanEngineEndToEndTests.swift`, `iOSCleanupTests/Support/HomeViewModelTestHarness.swift`, `iOSCleanupTests/DebugFixtureAnalyzerTests.swift`, `iOSCleanupTests/ScalePerformanceTests.swift` (stub injection only)

**Findings covered:** SCAN-02 (P2, partially), SCAN-04 (P1, confirmed), SCAN-M04 (P3, confirmed)

**Decisions applied:**
- **D-REANALYSIS:** no `analyzerVersion` bump. Verification is computed at group time and memoized.
- **D-THRESHOLDS:** this workstream is the safety net that allows WS-39 to loosen thresholds later.
- **DECISION (owner may override): verification tiers.**
  - Screenshots and any cluster containing recognized text or barcodes need `.identical` or `.nearIdentical` pixel tiles and equal tokens.
  - Camera clusters with no text or barcodes may stay destructive on `.sceneMatch` (differences spread across the frame, not localized), still subject to the 0.08 margin.
  - Requiring near-identical tiles for *all* plans would turn every handheld near-duplicate and burst into review-only.

### Goal
- No group reaches `keepBestTrashRest` unless local pixel verification (and token verification where text or barcodes exist) supports it.
- Verified identical copies (same dimensions, feature distance ≤ 0.01, `.identical` tiles) skip the narrow-margin rule and become one-tap Keep Best, with a deterministic, explained keeper.
- Screenshots whose hashes differ by a few bits are still compared.

### Current behavior (verified)
**Screenshot candidates:**
- Screenshot candidates come only from an exact 64-bit average-hash bucket: `comparisonCandidateIDs` → `screenshotIDsByHash[perceptualHash]` (`PhotoScanEngine.swift:1214-1219`). Buckets are filled at `:826-837` and `:571-573`.
- The hash sets each bit with `pixel >= average` on an 8×8 squash (`:1092-1114`), so status-bar clock and battery changes can flip bits near the mean.
- Incremental context picks screenshots only by identical dimensions, most recent first (`:1616-1644`).

**Screenshot policy:**
- `isExtremeScreenshotMatch` suppresses the `largeTimeGap` blocker, so screenshots have no time bound (`SimilarityPolicyServices.swift:115-122`).
- `exactScreenshotGroup` plus `minEligibleScore >= 0.50` gives `.high`/`.suggestDeleteOthers` (`:436-447`).
- Camera near-duplicates need `featureDistance <= 0.05` within 20 s (`:155-159`).
- There is no pixel or text check anywhere.

**Margin rule:**
- `PreferenceAdjustedRecommendationService.swift:140-144` downgrades `keepBestTrashRest` to `reviewManually` when `keeperMargin < 0.08`. The margin is top-1 minus top-2 by score (`:187-194`).
- Identical copies have identical signals, so the margin is 0 and the tie is broken only by `lhs.key < rhs.key` (`SimilarityPolicyServices.swift:315-318`).
- The result is `finalDeleteCandidateIDs == []` and reclaim 0 (`PhotoScanEngine.swift:1354-1360`).
- The margin rule is currently what blocks SCAN-02's destructive scenarios, which is why SCAN-02 is a hard prerequisite for exempting identical copies.

**Tests:** `SimilarityPolicyTests.testExactDuplicatesClassifyAsNearDuplicateHighConfidence` (`iOSCleanupTests/SimilarityPolicyTests.swift:10-30`) exercises the policy engine alone. WS-08's `testEndToEndIdenticalCopiesProduceReviewableGroup` pins today's review-only outcome for this workstream to flip.

**BlockerFlag** (`SimilarityPolicyTypes.swift:23-39`) has no pixel or text variant.

### Implementation plan

**WS-38.1 — Pure pixel comparator (tiles, not global MAD)**
- **Why:** a different 2FA code, seat number or amount changes a tiny region. A global mean absolute difference stays near 0 and misses it.
- **Change:** new `iOSCleanup/Engines/DuplicatePixelComparator.swift`:

```swift
struct GrayBuffer: Equatable, Sendable { let width: Int; let height: Int; let pixels: [UInt8] }
struct TileComparison: Equatable, Sendable {
    let maxTileMAD: Double                // 0…255 units
    let fractionOfTilesAboveNear: Double  // tiles whose MAD > nearIdenticalMaxTileMAD
}
enum DuplicateVerificationTuning {
    static let bufferLongSide = 256, tileSide = 16
    static let identicalMaxTileMAD = 2.0, nearIdenticalMaxTileMAD = 6.0
    static let localizedChangeMaxTileFraction = 0.10   // below this = a localized content change
    static let screenshotStatusBarFraction = 0.06      // cropped from the top
    static let minimumTokensForTextBearing = 3
    static let maxVerifiedMembers = 40, maxVerifiedClustersPerRun = 1_500
    static let loadLongSide: CGFloat = 512
}
enum DuplicatePixelComparator {
    /// Aspect-preserving grayscale at `bufferLongSide`; optionally crops the top fraction first.
    static func grayBuffer(from upright: CGImage, cropTopFraction: Double = 0) -> GrayBuffer?
    /// nil when buffer sizes differ (aspect mismatch).
    static func compare(_ a: GrayBuffer, _ b: GrayBuffer) -> TileComparison?
}
```

- **Edge cases:** an aspect mismatch above 1% gives `nil` and then `.differs`. Use the upright image from WS-37's `AnalysisImagePreparation`.

**WS-38.2 — Text and barcode tokens**
- **Change:** new `iOSCleanup/Engines/TextTokenRecognizer.swift`:
  - `protocol TextTokenRecognizing: Sendable { func tokens(in upright: CGImage) async throws -> [String] }`
  - `VisionTextTokenRecognizer` runs `VNRecognizeTextRequest` (`.fast`, no language correction) and `VNDetectBarcodesRequest` in **one** `perform`.
    - Normalize text: lowercase, keep `[a-z0-9]`, keep tokens of 2 characters or more.
    - Barcode payloads become `"bc:<payload>"`.
    - Return a sorted multiset.
    - Use the simulator-CPU setting WS-07 applies to Vision requests.
- **Edge cases:**
  - A recognizer error means the verdict is `.unavailable`.
  - Barcodes (tickets, boarding passes) always make a cluster text-bearing.
  - This workstream creates `FixtureTextRecognizer: TextTokenRecognizing` (returns `[]`) under `#if DEBUG && targetEnvironment(simulator)` and wires it into WS-07's DEBUG fixture mode in the same PR. `HomeViewModelDependencies.debugFixture()` → `makePhotoScanEngine` passes `keepBestEvidence: KeepBestEvidenceCollector(enricher: NoOpKeeperEnricher(), verifier: DuplicateVerificationService(recognizer: FixtureTextRecognizer()))`, as WS-07.8's forward contract requires. Otherwise Vision error 9 in the simulator would make every group review-only and Keep Best unreachable there. Fixture assets are real seeded photos, so the pixel comparator still runs on real images.

**WS-38.3 — `DuplicateVerificationService`**
- **Change:** new `iOSCleanup/Engines/DuplicateVerificationService.swift`:

```swift
enum DuplicateVerification: Int, Comparable, Sendable { case identical = 0, nearIdentical, sceneMatch, differs, unavailable }
struct DuplicateVerificationResult: Equatable, Sendable {
    let verdict: DuplicateVerification
    let isTextBearing: Bool
    let differingEvidence: BlockerFlag?     // .pixelContentDiffers or .textContentDiffers when verdict == .differs
    let reason: String
}
protocol DuplicateVerifying: Sendable {
    func verify(assets: [PHAsset], isScreenshotCluster: Bool, allowNetworkAccess: Bool) async -> DuplicateVerificationResult
}
actor DuplicateVerificationService: DuplicateVerifying {
    init(imageLoader: @escaping @Sendable (PHAsset, Bool) async -> UIImage? = { /* PhotoImageRepository, .analysis intent, 512 aspectFit, local unless allowed */ },
         recognizer: any TextTokenRecognizing = VisionTextTokenRecognizer(),
         maxConcurrentLoads: Int = 4)
}
```

  - Per member (memoized by `localIdentifier` and `modificationDate`, bounded LRU of 2,000): load, upright, build the gray buffer (screenshots crop `screenshotStatusBarFraction` first) and tokens (screenshots are recognized on the cropped image).
  - Pair verdict:
    1. Screenshots:
       - Pixel sizes must be equal, else `.differs`.
       - `maxTileMAD <= identical` and equal tokens give `.identical`; otherwise `.differs`.
    2. Text-bearing (either member has ≥ `minimumTokensForTextBearing` tokens, or any barcode):
       - Tokens must be equal, else `.differs(.textContentDiffers)`.
       - Then tiles: ≤ identical gives `.identical`, ≤ near gives `.nearIdentical`, else `.differs(.pixelContentDiffers)`.
    3. Camera without text:
       - Tiles ≤ identical gives `.identical`; ≤ near gives `.nearIdentical`.
       - If `fractionOfTilesAboveNear < localizedChangeMaxTileFraction`, the change is localized: `.differs(.pixelContentDiffers)`.
       - Otherwise `.sceneMatch`.
  - Cluster verdict: the **worst** pair over all pairs. Any member image missing or any recognizer error gives `.unavailable`, unless some pair already `.differs`. More than `maxVerifiedMembers` members gives `.unavailable`.
- **Edge cases:**
  - Images load through `PhotoImageRepository`'s analysis lane (WS-22/WS-52). Never use `PHImageManagerMaximumSize`.
  - Never let verification loads evict UI thumbnails (invariant 21).
  - Network only if this scan already has the user's opt-in.

**WS-38.4 — Gate destructive plans in `makeGroups`**
- **Change:**
  - Extend `KeepBestEvidenceCollector` (WS-37) with `init(enricher:, verifier: any DuplicateVerifying = DuplicateVerificationService())`.
  - `KeepBestEvidence` gains `verification: DuplicateVerificationResult?` and `tieBreakFacts` (WS-38.5).
  - The collector memoizes verification per `PhotoScanGroupCacheKey` for the run and enforces `maxVerifiedClustersPerRun`. Over the cap, the result is `.unavailable`.
  - Add `BlockerFlag.pixelContentDiffers` and `.textContentDiffers`, and update any exhaustive switch.
  - Add a pure `DuplicateVerificationGate` in the same file as the service:

```swift
enum DuplicateVerificationGate {
    struct Outcome: Equatable { let allowsDestructivePlan: Bool; let blocker: BlockerFlag?; let reason: String? }
    static func evaluate(_ r: DuplicateVerificationResult?, isScreenshotCluster: Bool) -> Outcome {
        guard let r else { return .init(allowsDestructivePlan: false, blocker: nil, reason: "Not verified; review manually.") }
        switch r.verdict {
        case .identical, .nearIdentical: return .init(allowsDestructivePlan: true, blocker: nil, reason: nil)
        case .sceneMatch: return .init(allowsDestructivePlan: !isScreenshotCluster && !r.isTextBearing, blocker: nil, reason: nil)
        case .differs: return .init(allowsDestructivePlan: false, blocker: r.differingEvidence, reason: r.reason)
        case .unavailable: return .init(allowsDestructivePlan: false, blocker: nil,
                                        reason: "Couldn't compare these closely because they aren't fully on this iPhone.")
        }
    }
}
```

  - In `makeGroups`, for Keep-Best-bound clusters: run collector → preference adjustment (with `isVerifiedIdenticalCluster`, WS-38.5) → `DuplicateVerificationGate`.
    - If the adjusted action is `.keepBestTrashRest` and the gate denies it: `finalAction = .reviewManually`, confidence `.high` becomes `.medium`, and the blocker and reason are appended.
  - WS-13's favorite and undeletable protections still run afterwards. `PhotoGroup.init` still validates.
- **Edge cases:**
  - Non-bound clusters are never verified (keep work off the hot path).
  - Burst-extras groups (WS-40) are built from PhotoKit burst metadata, not visual similarity, and do not pass through this gate.
  - Snapshot groups saved before WS-38 keep their old action until their assets are re-scanned. v1 is unreleased, so no migration.

**WS-38.5 — Identical copies skip the margin, with deterministic tie-breaks (SCAN-04)**
- **Change:**
  - Add `var isVerifiedIdenticalCluster: Bool = false` to `PreferenceAdjustedRecommendationInput`.
    - It is true only when all members share `pixelWidth`/`pixelHeight`, every pair has `featureDistance <= SimilarityThresholds.identicalCopyMaxFeatureDistance` (new constant, 0.01; WS-39 moves it into the destructive profile), and the verdict is `.identical`.
    - In the service, skip **only** the `keeperMargin < 0.08` rule when true, and add the reason "Identical copies — keeping one".
  - Add optional tie-break facts to `SimilarityAssetDescriptor` (init params with defaults):
    - `hasLocation: Bool?`, filled by `descriptor(for:)` from `asset.location != nil`
    - `measuredByteCount: Int64?`, filled by the collector for bound clusters from WS-30's measured sizes only, never estimates. `KeepBestEvidenceCollector` gains `measuredBytes: @Sendable ([AssetFileSizeCacheKey]) async -> [String: Int64]`. The default does one batch read, `AssetFileSizeRepository.shared.records(for:)` with keys `AssetFileSizeCacheKey(localIdentifier:modificationDate:)`, and keeps `record.footprint?.totalBytes` only when `record.footprint?.isFullyMeasured == true`. Anything else is nil, including estimates. Tests inject a closure.
    - `userAlbumCount: Int?`, from WS-13's album seam. For a Keep-Best-bound cluster, `makeGroups` calls the engine's `albumMembershipProvider.userAlbumMembership(for: memberIDs)` (`AlbumMembershipProviding`; its index is cached per change token) and passes the result into `collect(…, albums: AssetAlbumMembership?)`. The count is `albums.userAlbumCount(for: id)`, and nil when the provider returns nil (Limited access).
  - New pure `iOSCleanup/Engines/KeeperTieBreaker.swift`:
    - `static func compare(_ a: SimilarityAssetDescriptor, _ b: SimilarityAssetDescriptor) -> (aWins: Bool, reason: String)`.
    - Criteria in this order:
      1. favorite
      2. `isEdited` (hasAdjustments)
      3. larger measured bytes (only if both measured)
      4. more user albums (only if both known)
      5. earlier `captureTimestamp`
      6. has location
      7. smaller `id`
    - Reasons: "Kept the favorite", "Kept your edited copy", "Kept the larger original", "Kept the copy in more albums", "Kept the earlier copy", "Kept the copy with location", "Kept the first copy".
  - `ConservativeKeeperRankingService` sorts by score, then `KeeperTieBreaker` when `abs(Δscore) < 1e-9`. The deciding reason is appended to `reasonsByAssetID[keeper]`.
- **Edge cases:**
  - Favorites already win by score (+0.08), which is consistent with the tie-break order. WS-13 still excludes favorites from delete sets.
  - Cross-date identical copies are WS-61 (chapter 13). They stay outside the 20 s window here.

**WS-38.6 — Screenshot multi-index hashing (SCAN-M04)**
- **Change:** new `iOSCleanup/Engines/ScreenshotHashIndex.swift`:

```swift
struct ScreenshotHashIndex {
    /// 7 bands: six of 9 bits (bits 0–53) and one of 10 bits (bits 54–63). Any two hashes within
    /// Hamming 6 differ in at most 6 bands, so at least one of the 7 bands is identical (pigeonhole).
    static let bandBitWidths = [9, 9, 9, 9, 9, 9, 10]
    init(maxPerBand: Int = SimilarityThresholds.maxFeatureComparisonsPerAsset)
    mutating func insert(id: String, hash: UInt64)          // one bucket per (band, value); each bucket capped (oldest dropped)
    mutating func remove(id: String)                        // called when WS-23's resident features evict the screenshot
    func candidates(for hash: UInt64, maxHamming: Int = 6, limit: Int) -> [String]   // most recent first
}
```

  - WS-23 moved the screenshot buckets into `PhotoScanWorkingSet`. Replace `PhotoScanWorkingSet.screenshotIDsByHash` with a `ScreenshotHashIndex`, filled where `ingestTarget` and `ingestContext` fill it today and read by `PhotoScanWorkingSet.candidateIDs(for:perceptualHash:)`.
  - Keep WS-23's screenshot retention bound (`PhotoScanResidentFeatures`' screenshot queue and cap). Have `PhotoScanResidentFeatures.insert`/`evict` report the screenshot IDs they drop, and call `remove` for each, so the index never outlives an evicted embedding.
  - `candidates` unions the 7 band buckets, dedupes, keeps only IDs whose full 64-bit Hamming distance (`(a ^ b).nonzeroBitCount`) is ≤ `maxHamming`, and returns the most recent first, up to `limit`. The work per lookup is bounded by 7 × `maxPerBand`.
  - The Vision distance gate (0.025) and this workstream's verification remain the only path to a destructive plan.
- **Edge cases:**
  - A Hamming distance up to 6 is guaranteed to share at least one exact band (L12). The old 4 × 16-bit layout guarantees this only up to Hamming 3.
  - 9-bit bands collide more often than 16-bit ones. The full-distance filter and the per-bucket cap keep false candidates out and the cost bounded.
  - Incremental-context band selection is **not** done here: it needs hash lookups in the ML store. Add it to `spec/BACKLOG.md` referencing WS-61.

**WS-38.7 — Update WS-08's end-to-end tests**
- **Change:**
  - Add `iOSCleanupTests/Support/StubDuplicateVerifier.swift` (`StubDuplicateVerifier(result:)`, conforming to `DuplicateVerifying`).
  - **Inject `KeepBestEvidenceCollector(enricher: NoOpKeeperEnricher(), verifier: StubDuplicateVerifier(result:))` through `PhotoScanEngine.init(keepBestEvidence:)` into every engine built over fake assets, in this PR.** The default verifier would call PhotoKit on fake assets and turn every plan review-only. The sites are:
    - WS-08's `makeEndToEndEngine` helper, which covers every `PhotoScanEngineEndToEndTests` test;
    - WS-07's `HomeViewModelTestHarness.makeIsolatedDependencies` → `makePhotoScanEngine`;
    - `DebugFixtureAnalyzerTests.testFixtureLibraryScanProducesExpectedGroups`;
    - WS-08's benchmark 7, `ScalePerformanceTests.testEngineThroughputWithFiveMillisecondAnalyzer`.

    Default the stub to `.sceneMatch` for camera fixtures, so existing Keep Best expectations hold. Grep `PhotoScanEngine(` under `iOSCleanupTests/` for any other test that asserts a Keep Best plan over fake assets. DEBUG fixture mode gets `FixtureTextRecognizer` instead (WS-38.2), because its assets are real.
  - `testEndToEndNearDuplicatePairProducesExplicitKeepBestPlan` uses `.sceneMatch` and must stay green.
  - Flip `testEndToEndIdenticalCopiesProduceReviewableGroup` into `testEndToEndIdenticalCopiesBecomeKeepBestEligible`, as specified in the Tests section.

### Tests
**`iOSCleanupTests/DuplicateVerificationTests.swift`** (simulator, pure plus stubbed loader and recognizer). Pixel verdicts:
- `testIdenticalBuffersAreIdentical`
- `testTwoPercentBrightnessChangeIsNearIdentical`
- `testSameLayoutDifferentTextBlockIsLocalizedDiffers`: a white page with one 80×20 px block changed.
- `testGlobalThreePercentShiftWithoutTextIsSceneMatch`
- `testStatusBarOnlyChangeOnScreenshotIsIdentical`
- `testChangeBelowStatusBarOnScreenshotDiffers`
- `testScreenshotDimensionMismatchDiffers`
- `testAspectMismatchDiffers`

Token verdicts:
- `testDifferentTokensDiffer`: stub recognizer returns `["seat","12a"]` vs `["seat","14c"]`.
- `testDifferentBarcodePayloadsDiffer`
- `testTextBearingClusterNeedsNearIdenticalTiles`

Unavailable verdicts and cluster rules:
- `testMissingImageIsUnavailable`
- `testRecognizerErrorIsUnavailable`
- `testClusterVerdictIsWorstPair`
- `testOverMemberCapIsUnavailable`

Gate:
- `testGateAllowsSceneMatchOnlyForNonTextCamera`
- `testGateDeniesDiffersWithBlocker`
- `testGateDeniesUnavailableWithoutBlocker`

Tie-breaks and screenshot index:
- `testTieBreakOrder`: one case per criterion, in order. The measured-bytes case uses the injected `measuredBytes` closure, and a fact missing on either side skips that criterion.
- `testScreenshotHashIndexFindsHammingSix`: the 7-band layout's worst case, with the 6 differing bits placed one per band in 6 different bands (and a second case with all 6 in the 10-bit band). The candidate is found in both.
- `testScreenshotHashIndexRejectsHammingSeven`: a pair that shares a band but differs in 7 bits overall is filtered out by the full-distance check.
- `testScreenshotHashIndexBandLayoutCoversAllBits`: `bandBitWidths.reduce(0, +) == 64` and `bandBitWidths.count == 7`.
- `testScreenshotHashIndexCapHoldsWithThousandSameBandHashes`
- `testScreenshotHashIndexRemove`
- `testResidentScreenshotEvictionRemovesFromIndex`: a screenshot trimmed by `PhotoScanResidentFeatures` is no longer returned by `candidates`.

**`iOSCleanupTests/PhotoScanEngineEndToEndTests.swift`** (simulator):
- `testEndToEndIdenticalCopiesBecomeKeepBestEligible`:
  - Two `ConfigurablePhotoScanTestAsset`s 1 s apart, same dimensions, identical embedding and signals.
  - Stub verifier returns `.identical`.
  - Assert `isAutoCleanEligible`, `keeperAssetID` equals the earlier asset, `deleteCandidateIDs.count == 1`, `PhotoDeletionGuardrails.validate(group:)` does not throw, and the reasons contain "Kept the earlier copy".
- `testEndToEndIdenticalCopiesSameTimestampUseIDOrder`
- `testEndToEndVerifierDiffersKeepsGroupReviewOnlyWithBlocker`
- `testEndToEndUnavailableVerificationStaysReviewOnly`
- `testEndToEndNonIdenticalNarrowMarginStaysReviewOnly`: margin 0.03 with `.sceneMatch`.
- `testEndToEndExactScreenshotGroupWithDifferingTextIsReviewOnly`
- `testEndToEndScreenshotsOneBitApartStillGroup`: hashes differ by 1 bit and the verifier says `.identical`.

**`iOSCleanupTests/SimilarityPolicyTests.swift`:** `testMarginRuleStillDowngradesUnverifiedTies`, which runs `PreferenceAdjustedRecommendationService` directly with `isVerifiedIdenticalCluster: false`.

### Acceptance criteria
- [ ] No group reaches `keepBestTrashRest` without a verification result allowed by `DuplicateVerificationGate`:
  - screenshots and text or barcode clusters need `.identical`/`.nearIdentical`;
  - camera clusters without text need at least `.sceneMatch`;
  - `.unavailable` is always review-only.
- [ ] Document, receipt and 2FA-style pairs with differing text or localized tiles are review-only with a `pixelContentDiffers`/`textContentDiffers` blocker.
- [ ] Verified identical copies are Keep Best eligible through the engine (the WS-08 pin is flipped), with a deterministic keeper and a recorded deciding reason.
- [ ] The 0.08 margin rule still applies to everything that is not a verified identical cluster.
- [ ] Screenshot candidates use the 7-band multi-index (six 9-bit bands and one 10-bit band), which guarantees that every pair within Hamming ≤ 6 shares a band (`testScreenshotHashIndexFindsHammingSix`). Candidates are filtered by full Hamming distance and stay capped at `maxFeatureComparisonsPerAsset` per band.
- [ ] Every engine built over fake assets in tests (the WS-08 helper, the WS-07 harness, `testFixtureLibraryScanProducesExpectedGroups`, benchmark 7) injects the stub verifier and no-op enricher. DEBUG fixture mode injects `FixtureTextRecognizer`, and `scripts/sim-fixtures.sh` still shows a Keep Best-eligible pond group.
- [ ] Verification runs only for Keep-Best-bound clusters. It is memoized per cache key, capped per run, and local-only by default.
- [ ] No `analyzerVersion` bump.
- [ ] Full suite green, zero warnings. `CLAUDE.md`'s "Deletion safety" and "Similarity policy" bullets mention verification and the identical-copy exemption.

### Device QA
1. Save the same photo twice (Share → Save Image). One Keep Best group forms; Keep Best shows one iOS prompt and removes one copy.
2. Photograph two different receipts 5 s apart. Any group that forms is "Review together" with no Keep Best.
3. Take two screenshots of a 2FA screen with different codes. The group is review-only.
4. With Optimize iPhone Storage on and network off, a duplicate pair whose originals are iCloud-only stays review-only, with the "not fully on this iPhone" reason.
5. Take the same screen twice a minute apart (the clock differs). The screenshots group together.

### Pitfalls and out of scope
- **The margin exemption is only for verified identical clusters** (invariant 6). Never widen it to `.nearIdentical`.
- **Verification must never *create* a plan.** It only denies or permits one that the policy already proposed. `PhotoGroup.init` and the guardrails still run.
- Do not verify on the per-asset hot path, and do not bump `analyzerVersion` (D-REANALYSIS).
- Do not change distance thresholds (WS-39).
- **Out of scope, owned elsewhere:**
  - Cross-date identical copies and ML-store hash lookups: WS-61 (chapter 13).
  - Duplicate videos: WS-62 (chapter 13).
  - Burst extras: WS-40.
- **Reconciliation:**
  - L12: the screenshot index uses 7 bands (six 9-bit bands and one 10-bit band), so Hamming ≤ 6 is actually guaranteed. The test and acceptance are updated to match.
  - The identical-copy tie-breaks use the real seams: WS-13's `AlbumMembershipProviding.userAlbumMembership(for:)` / `AssetAlbumMembership.userAlbumCount(for:)`, and WS-30's `AssetFileSizeRepository.records(for:)` footprints (fully measured only).
  - The screenshot buckets live in WS-23's `PhotoScanWorkingSet`, not `performScan`.
  - Lead item (chapters 01–02 final): the stub verifier and no-op enricher reach every test-built engine (WS-38.7). WS-38 itself creates `FixtureTextRecognizer` and wires it into WS-07's fixture mode.

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| SCAN-02 | partially | The evidence holds (exact aHash bucket, no time bound for extreme screenshot matches, no pixel or text check). Today the 0.08 margin blocks most destructive outcomes, so it is P2 and a hard prerequisite for SCAN-04. The fix is corrected: per-tile max MAD instead of global MAD, a status-bar crop, and any token difference means `.differs`. Barcodes and a localized-change rule are added. **Deviation:** SCAN-02's acceptance ("only identical or nearIdentical may be destructive") is relaxed for non-text camera clusters (`.sceneMatch`), per the DECISION above. Otherwise handheld near-duplicates and bursts could never be Keep Best. |
| SCAN-04 | confirmed | Margin 0 for identical signals (`PreferenceAdjustedRecommendationService.swift:140-144, 187-194`); ID-only tie-break (`SimilarityPolicyServices.swift:315-318`). The exemption requires same dimensions, distance ≤ 0.01 and `.identical`. The tie-break order follows the WS notes; the user-album count comes from WS-13, and measured bytes only from WS-30 measurements. |
| SCAN-M04 | confirmed | Exact bucket at `PhotoScanEngine.swift:1214-1219`. Multi-index hashing is implemented in-run. Band selection for incremental context is deferred (backlog, WS-61) because it needs indexed hash lookups in the ML store. |

---

## WS-39 — Similarity threshold calibration (verify-first)

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M2 | M | WS-22, WS-38 | yes | `ws/39-threshold-calibration` |

**Primary files:**
- Engine:
  - `iOSCleanup/Engines/SimilarityThresholdProfile.swift` (*new*)
  - `iOSCleanup/Engines/SimilarityPolicyTypes.swift`
  - `iOSCleanup/Engines/SimilarityPolicyServices.swift`
  - `iOSCleanup/Engines/PhotoScanEngine.swift` (init injection only)
  - `iOSCleanup/Engines/SimilarityCalibrationRecorder.swift` (*new*, DEBUG)
  - `iOSCleanup/Utilities/SharedHelpers.swift` (only if the DEBUG file writer needs a shared helper)
- DEBUG view: `iOSCleanup/Views/Debug/CalibrationReviewView.swift` (*new*, DEBUG)
- Tests:
  - `iOSCleanupTests/Fixtures/Calibration/` (optional CC0 set)
  - `iOSCleanupTests/Support/CalibrationFixtureFactory.swift` (*new*)
  - `iOSCleanupTests/SimilarityCalibrationTests.swift` (*new*)

**Findings covered:** SCAN-05 (P1, confirmed)

**Decisions applied:**
- **D-THRESHOLDS:** verify-first. Use synthetic or CC0 fixtures only, never user photos, plus device distributions. Loosen only because WS-37 and WS-38 have landed.
- **D-SENSITIVITY:** the profile separates destructive from review-only thresholds, so WS-63's presets can change review-only values alone.
- **D-REANALYSIS:** threshold changes need no `analyzerVersion` bump, because cached pair rows store distances.

**Cut rule:** cuttable if the schedule forces it. Then land only WS-39.1, which is a pure refactor that WS-63 needs.

### Goal
- Thresholds live in an injectable `SimilarityThresholdProfile` keyed by `embeddingVersion`, with destructive and review-only values separated.
- A calibration test and device distance distributions are committed.
- The near-duplicate cutoff changes only when those distributions justify it. Otherwise the PR documents that the current values hold.

### Current behavior (verified)
**Thresholds:** static constants in `SimilarityThresholds` (`iOSCleanup/Engines/SimilarityPolicyTypes.swift:231-274`):
- `maxNearDuplicateFeatureDistance` 0.05 (`:238`)
- visual 0.18 (`:240`)
- extended visual 0.08 (`:241`)
- burst 0.16 (`:242`)
- screenshot 0.025 (`:243`)
- They are read directly by `ConservativePairSimilarityClassifier` (`SimilarityPolicyServices.swift:115-217`), the cluster classifier (`:406-560`), `SimilarityCandidateGraph` (`:689-829`), `SimilaritySignals.isStrongVisualMatch` (`SimilarityPolicyTypes.swift:415-424`) and `PhotoScanCandidateSelector`.

**Distance scale:**
- Revision 1 is pinned (`PhotoMLBridge.swift:18`); 2,048 elements (`PhotoMLStore.swift:9-14`).
- Distances are RMS-normalized, raw/√2048 (`PhotoScanEngine.swift:1820-1834`). The near-duplicate cutoff is therefore ≈2.26 raw, visual ≈8.1, screenshot ≈1.13.
- `ROADMAP.md:76` records useful revision-1 thresholds of about 11 raw.

**Tests:**
- The only fixture test, `testPinnedVisionFeaturePrintScaleUsingDeterministicFixtures` (`iOSCleanupTests/PhotoScanEngineTests.swift:36-95`), checks identical ≤ 0.001 and unrelated > 0.18. It skips in the simulator on Vision error 9. WS-07 forces CPU in the simulator; its PR records whether that removes the skip.
- `testTuningConstantsStayPrecisionFirstAndBounded` (`:226-277`) asserts the ordering of the static constants.

### Implementation plan

**WS-39.1 — Injectable threshold profile (pure refactor, no behavior change)**
- **Change:** new `iOSCleanup/Engines/SimilarityThresholdProfile.swift`:

```swift
struct DestructiveSimilarityThresholds: Equatable, Sendable {   // never changed by presets (WS-63)
    var maxNearDuplicateFeatureDistance: Double, maxScreenshotDuplicateFeatureDistance: Double
    var identicalCopyMaxFeatureDistance: Double, maxBurstFeatureDistance: Double
    var burstWindowSeconds: Double, nearDuplicateWindowSeconds: Double
    var burstPairEligibilityScoreFloor: Double, screenshotAutoDeleteScoreFloor: Double
    var burstAutoDeleteScoreFloor: Double, nearDuplicateAutoDeleteScoreFloor: Double
    var nearDuplicateClusterFloor: Double, splitConsistencyFloor: Double
}
struct ReviewOnlySimilarityThresholds: Equatable, Sendable {    // WS-63 presets may change only these
    var maxVisualSimilarFeatureDistance: Double, maxExtendedVisualFeatureDistance: Double
    var visualSessionWindowSeconds: Double, extendedVisualSessionWindowSeconds: Double
    var visualClusterFloor: Double, visualReviewClusterFloor: Double, timeGapVisualScoreFloor: Double
}
struct SimilarityScoringConstants: Equatable, Sendable { /* featureScoreWeight, featureScoreNormalizationDistance, penalties, bonuses, largeTimeGapPenaltyAfterSeconds */ }
struct SimilarityThresholdProfile: Equatable, Sendable {
    let embeddingVersion: Int
    let revision: Int                    // bump when values change; recorded in the PR
    var destructive: DestructiveSimilarityThresholds
    var reviewOnly: ReviewOnlySimilarityThresholds
    var scoring: SimilarityScoringConstants
    static let standard: SimilarityThresholdProfile   // today's values, embeddingVersion 2, revision 1
    static func profile(for embeddingVersion: Int) -> SimilarityThresholdProfile?
}
```

  - Inject `profile` (default `.standard`) into `ConservativePairSimilarityClassifier`, `ConservativeSimilarityClusterClassifier` (through its pair classifier), `SimilarityCandidateGraph`, `ConservativeSimilarityPolicyEngine` and the candidate selector.
  - Replace the `SimilaritySignals` extension computed vars with functions taking the profile.
  - `PhotoScanEngine.init(thresholdProfile: SimilarityThresholdProfile = .standard)` passes it through.
  - `SimilarityThresholds` keeps only the non-threshold bounds (`maxCandidateAssetsInspected`, `maxFeatureComparisonsPerAsset`, `maxBurstAssetsPerCluster`, retention caps, …).
  - Move WS-38's `identicalCopyMaxFeatureDistance` into `destructive`.
- **Edge cases:**
  - An unknown `embeddingVersion` is a DEBUG `assertionFailure` and falls back to `.standard` in Release. Distances are already version-validated upstream.
  - All existing tests must pass unmodified, apart from references to the moved constants.

**WS-39.2 — Calibration fixtures and test**
- **Change:**
  - `iOSCleanupTests/Support/CalibrationFixtureFactory.swift` renders deterministic synthetic scenes at 1,024 px with CoreGraphics and CoreText (seeded shapes, gradients, noise textures, document pages).
  - It derives pairs for each category:
    - `identical`, `reencodedJPEG70`, `resized50`, `brightness5`
    - `reframe3pct` (crop and shift, handheld proxy), `rotate1deg`, `burstLike` (small shift plus light blur)
    - `sameSceneDifferentMoment`, `differentScene`
    - `documentDifferentText`, `screenshotDifferentText`
  - Optional: if `iOSCleanupTests/Fixtures/Calibration/cc0/` exists (a folder reference with `LICENSES.md` listing a CC0 source per file), load its pair manifest too. Never user photos.
  - `iOSCleanupTests/SimilarityCalibrationTests.swift`:
    - `testRevision1DistancesBracketCalibrationFixtures` computes pinned revision-1 normalized distances through `PhotoMLBridge.makePinnedFeaturePrintRequest()`, the same path as production including WS-07's simulator CPU setting. It attaches a per-category distribution table (min / P50 / P95 / max) as an `XCTAttachment`.
    - It asserts only robust properties:
      - identical ≤ 0.001
      - `reencodedJPEG70`, `resized50` and `brightness5` ≤ `destructive.maxNearDuplicateFeatureDistance`
      - `differentScene` > `reviewOnly.maxVisualSimilarFeatureDistance`
      - median(`reframe3pct`) < median(`differentScene`)
      - for every `documentDifferentText` and `screenshotDifferentText` pair at or below a destructive cutoff, `DuplicatePixelComparator` plus a stub recognizer returning the rendered words yield `.differs`. WS-38 is the safety net.
    - If Vision still cannot run in the simulator, throw `XCTSkip("run on device")`. Then the evidence must come from a device run (`-destination 'platform=iOS,id=<udid>'`).
  - Move the ordering assertions of `testTuningConstantsStayPrecisionFirstAndBounded` onto `SimilarityThresholdProfile.standard`, and add `testDestructiveAndReviewOnlyThresholdsAreSeparated`.

**WS-39.3 — DEBUG distance histogram and labeled pair sampler (device evidence)**
- **Change:**
  - `#if DEBUG` actor `SimilarityCalibrationRecorder` records every evaluated candidate pair from `performScan`'s pair-evidence step. The hook sits next to where `PairSimilarityRecord` is built: one `await` of a non-blocking `record(...)` that only increments counters.
  - Histogram bins: distance 0.00–0.40 in 0.01 bins, split by pair kind (camera ≤20 s, camera 20 s–30 min, burst, screenshot).
  - It also keeps a stratified in-memory sample of at most 200 pair ID tuples: 20 per distance band from 0.0 to 0.30 in steps of 0.03.
  - At scan completion it writes `Application Support/PhotoDuck/Debug/similarity-calibration.json`, containing counts and labels only and **no asset IDs**.
  - `#if DEBUG` `CalibrationReviewView`, reachable from the DEBUG admin area next to the existing admin toggle, shows each sampled pair side by side with three buttons: "Same moment / near-duplicate", "Different", "Unsure". Labels are appended per distance bin to the same JSON.
  - Retrieve the file through Xcode's container download or WS-47's DEBUG export.
- **Edge cases:**
  - None of this compiles into Release (invariant 27). Assert it with `#if DEBUG` around every type and call site.
  - It is not part of the shareable diagnostic report, which exports only elapsed-time values (invariant 26).

**WS-39.4 — Decide from evidence**
- **Change:**
  1. Run WS-39.2 on a device and WS-39.3 on the owner's device library, labeling at least 100 pairs. Put both distribution tables in the PR.
  2. **Rule:** the new `maxNearDuplicateFeatureDistance` is the P95 of labeled "near-duplicate" distances, capped strictly below the P1 of labeled "different" distances. Apply the same rule to the screenshot cutoff using screenshot pairs.
  3. If the labeled sets overlap so that no cap exists, keep the current values and document that in the PR and in a code comment.
  4. Only `destructive` near-duplicate and screenshot cutoffs may move here. Review-only values move only if the same evidence shows the visual band misses labeled near-duplicates.
  5. Bump `SimilarityThresholdProfile.standard.revision` if anything changes.
  6. Adopting Vision revision 2 would mean `embeddingVersion` 3 plus cache invalidation, and is **never** combined with threshold changes.
- **Edge cases:** saved snapshot groups are never regrouped from cached analyses. No engine `regroup(thresholds:)` exists or is planned (L13): after WS-46 only the newest 10k photos have cached analyses, and re-clustering could create destructive plans. A threshold change, before or after release, takes effect on the next user-initiated full re-analysis, mirroring WS-37's `analyzerVersion` rollout. On devices, verify the change with WS-26's confirmed full rescan (`startPhotoScan(from: .gearRescanConfirmed)`). After release, WS-63.6 shows a "Scan again to update your groups" notice when `SimilarityThresholdProfile.standard.revision` increases; it never rescans automatically.

### Tests
- Simulator (if Vision runs on CPU) or device:
  - `SimilarityCalibrationTests.testRevision1DistancesBracketCalibrationFixtures`
- Simulator:
  - `SimilarityCalibrationTests.testDestructiveAndReviewOnlyThresholdsAreSeparated`
  - `SimilarityCalibrationTests.testStandardProfileMatchesLegacyValues`: every field equals the pre-refactor constant.
  - `PhotoScanEngineTests.testTuningConstantsStayPrecisionFirstAndBounded`, ported to the profile.
  - `SimilarityPolicyTests.testInjectedProfileChangesPairOutcome`: a pair at distance 0.06 is `.visuallySimilar` with `.standard` and `.nearDuplicate` with a test profile whose cutoff is 0.07. This proves the injection is real.
  - `testCalibrationRecorderBinsAndCapsSamples` (DEBUG-only): the recorder is bounded to 200 samples and the histogram totals match the calls.
- Device-only: the WS-39.3 labeling run.

### Acceptance criteria
- [ ] `SimilarityThresholdProfile` is an injectable value type (default `.standard`) used by the pair classifier, cluster classifier, candidate graph and selector. No classifier reads a distance or floor from `SimilarityThresholds` any more.
- [ ] Destructive and review-only thresholds are separate types.
- [ ] The calibration test is committed. Its distribution attachment, plus the device histogram and labels, are in the PR.
- [ ] Thresholds changed only per the P95/P1 rule with a revision bump, or the PR documents that the current values hold.
- [ ] DEBUG-only code is absent from Release: `nm` or a build-setting check, and a grep of the Release build log.
- [ ] Full suite green, zero warnings.

### Device QA
1. DEBUG build on the owner's device: run a full scan, open Calibration Review, label ≥100 pairs, export `similarity-calibration.json`, and attach it to the PR.
2. After any threshold change: run the confirmed full rescan (gear › Scan Again › Rescan Library), then compare Keep Best group counts and spot-check 20 new Keep Best groups for wrong keepers or distinct content.

### Pitfalls and out of scope
- Never calibrate on user photos in the repo, and never ship labels or IDs off the device.
- Never loosen thresholds before WS-37 and WS-38 are merged.
- Never combine a revision-2 adoption with threshold changes.
- Presets: WS-63 (chapter 13).
- There is no automatic regrouping of saved snapshots in any workstream. WS-63 adds only review-only preset filtering and the revision notice.
- **Reconciliation:** L13. WS-39 no longer promises WS-63's `regroup(thresholds:)`, which WS-63 rejected. Threshold changes apply on the next user-initiated full re-analysis, and WS-63.6 prompts for one after a revision bump.

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| SCAN-05 | confirmed | Confirmed: there is no calibration evidence, and the thresholds map to ≈2.26 raw (near-duplicate) vs the ≈11 raw noted in `ROADMAP.md:76`. The claimed effect ("matches only pixel-identical copies") is unverified until WS-39.4's device data exists. The plan follows the reviewer's steps, with three differences: synthetic or CC0 fixtures generated at test time instead of ~40 committed real JPEGs; the histogram written to a DEBUG-only file instead of the diagnostics log (invariant 26); and a labeling sampler added so P95 and P1 have labeled positives and negatives. |

---

## WS-40 — Burst extras

| Milestone | Size | Depends on | Verify-first | Branch |
|---|---|---|---|---|
| M2 | M | WS-13, WS-18, WS-38 | no (task 1 is a device check) | `ws/40-burst-extras` |

**Primary files:**
- Engine:
  - `iOSCleanup/Engines/PhotoLibraryFetch.swift` (WS-18)
  - `iOSCleanup/Engines/BurstExtrasPlanner.swift` (*new*)
  - `autoCleanPolicy` pass-through only: `iOSCleanup/Views/Home/PhotoResultPruner.swift` (WS-21), `iOSCleanup/Models/PhotoGroup+ReclaimSizing.swift` (WS-30), and WS-12's `applyingUserKeptIDs` in `iOSCleanup/Models/PhotoGroup.swift`
  - `iOSCleanup/Engines/PhotoScanEngine.swift`
  - `iOSCleanup/Engines/PhotoLibraryInventory.swift` (WS-18)
  - `iOSCleanup/Engines/SimilarityPolicyTypes.swift`
  - `iOSCleanup/Engines/SimilarityPolicyServices.swift`
  - `iOSCleanup/Engines/PhotoAnalysisCache.swift`
  - `iOSCleanup/Engines/AutoCleanPlanner.swift` (WS-12)
  - Fetch-options routing only: `iOSCleanup/Engines/PhotoLibraryDeleting.swift` (WS-03 resolver), `iOSCleanup/Engines/AlbumMembership.swift` (WS-13), `iOSCleanup/Views/Home/LargeVideoScanController.swift` (WS-27 count fallback), `iOSCleanup/Views/HomeViewModel.swift` (restore seed and token reset), and the DEBUG files `iOSCleanup/Utilities/DebugFixtureLibrary.swift` (WS-07 seeder), `iOSCleanup/Utilities/DebugQAProbes.swift` (WS-09 census) and `iOSCleanup/Engines/AssetFootprintProbe.swift` (WS-30)
- Model: `iOSCleanup/Models/PhotoGroup.swift`
- Tests:
  - `iOSCleanupTests/BurstExtrasPlannerTests.swift` (*new*)
  - `iOSCleanupTests/PhotoFetchLintTests.swift` (*new*)

**Findings covered:** SCAN-09 (P1, confirmed)

**Decisions applied:**
- **D-SCOPE:** burst extras are v1.
- **D-FREE-KEEPBEST:** per-group Keep Best on burst extras is free.
- **D-GATING:** Auto-clean all stays Pro.
- **D-REANALYSIS:** no analyzer bump. The pass is metadata-only.
- **DECISION (owner may override): Auto-clean eligibility for burst extras.**
  - Bursts where the only kept frame is the camera's auto-picked cover photo are **per-group Keep Best only** (excluded from Auto-clean all).
  - Bursts with at least one user pick are Auto-clean eligible at high confidence.
- **DECISION (owner may override): counting hidden frames.** Hidden burst frames count as processed and analyzed (classified by metadata) and never as unanalyzed. Library totals therefore include them and can exceed the Photos app's visible count.

**Cut rule:** cuttable if the schedule forces it.

### Goal
Hidden burst frames the user never picked appear as one burst-extras group per burst:
- the keeper is the burst's cover photo (representative) or a user pick;
- every user-picked frame is protected;
- only unpicked frames are delete candidates.

The groups are built through `PhotoGroup.init` and the guardrails. Counts, reconcile, resume and rehydrate stay consistent because every photo fetch uses one options factory.

### Current behavior (verified)
**Fetching:**
- `SystemPhotoScanAssetProvider` sets only `sortDescriptors` (`PhotoScanEngine.swift:61-80`). HomeViewModel's inventory fetches pass `options: nil` (`HomeViewModel.swift:2273, 2532`).
- `includeAllBurstAssets` defaults to false, so PhotoKit returns only the representative and the user picks.
- `grep includeAllBurstAssets|representsBurst|burstSelectionTypes` finds nothing. The APIs exist: `PHAsset.h:63-64, 81`, `PHFetchOptions.h:27`.

**Existing burst code is effectively dead:** burst buckets (`SimilarityPolicyServices.swift:706-722`), burst candidate lists (`PhotoScanEngine.swift:1222-1227`) and 40-frame chunking rarely see two members of one burst.

**Identifier fetches also use `options: nil`:**
- existence checks (`HomeViewModel.swift:1857-1886` via `existingAssetIdentifiers`, `:1968-1975`)
- `PhotoAnalysisCache.rehydrateGroups` / `rehydrateAssets` (`PhotoAnalysisCache.swift:768-797`)
- `ExternalPhotoExportService.swift:108`
- If hidden frames are not returned by these, `CachedPhotoGroup.makeGroup` downgrades the group to review-only (`PhotoAnalysisCache.swift:403-416`), and pruning drops the frames.

**Guardrails:** `PhotoGroup.init` (`iOSCleanup/Models/PhotoGroup.swift:24-160`) requires high confidence, a keeper, delete IDs and no blockers. It has no time-span rule. The 3 s burst window lives only in the cluster classifier (`SimilarityPolicyServices.swift:448`).

**Dependencies:** WS-18 introduced the shared fetch-options factory with `includeAllBurstAssets` still false. WS-13 added favorite and undeletable protection.

### Implementation plan

**WS-40.1 — Device check (first step)**
- **Why:** everything below depends on PhotoKit burst behavior.
- **Change:** on a device with a DEBUG build and at least 2 bursts (one with a user pick via Photos "Select…" → "Keep Everything"), log counts (temporary `#if DEBUG`, removed before merge):
  1. `fetchAssets(with: .image)` with default options vs `includeAllBurstAssets = true`;
  2. for hidden frames: `representsBurst`, `burstSelectionTypes`, `canPerform(.delete)`;
  3. whether `fetchAssets(withLocalIdentifiers:)` returns hidden frames with `nil` options and with `includeAllBurstAssets = true`;
  4. `fetchAssets(withBurstIdentifier:options:)` counts.
  - Record the results in the PR.
  - If (3) returns hidden frames only with the flag, WS-40.2's identifier options are mandatory, as planned.
  - If hidden frames are never deletable, stop and report.

**WS-40.2 — One fetch-options factory, flipped**
- **Change:**
  - In WS-18's `PhotoLibraryFetch`: `imageOptions()` sets `includeAllBurstAssets = true` (keep the creation-date sort). Add `identifierOptions()` with `includeAllBurstAssets = true` for every `fetchAssets(withLocalIdentifiers:)`.
  - Route through them (start from `grep -rn "fetchAssets(\|PHFetchOptions()" iOSCleanup`; this list is the minimum):
    - the engine provider
    - `PhotoLibraryInventory` (enumeration and persistent-change paths)
    - `repairPrematureCompletion`
    - `existingAssetIdentifiers` and every reconcile or existence check (WS-21)
    - `PhotoAnalysisCache.rehydrateGroups` / `rehydrateAssets`
    - `ExportAlbumStore` and `ExternalPhotoExportService` identifier fetches
    - `DeletionManager`'s identifier resolver → `identifierOptions()`: WS-03's `PhotoLibraryDefaults.resolveAssets` (`Engines/PhotoLibraryDeleting.swift`), which after WS-11 returns `ResolvedPhotoAssets` (`Engines/DeletionTypes.swift`). Keep that return type; change only the fetch options. Without this, hidden burst frames resolve as `.missing` at commit, and Keep Best on a burst-extras group deletes nothing.
    - WS-13's album index (`SystemAlbumMembershipProvider`'s `PHAsset.fetchAssets(in:options:)` per album) → `identifierOptions()`
    - WS-27's video-count fallback in `LargeVideoScanController.liveVideoCount` → `videoOptions()`
    - the DEBUG fetches: WS-07's `DebugFixtureSeeder` existence check → `identifierOptions()`; WS-09's census in `DebugQAProbes` → `imageOptions()`, so hidden burst frames are counted; WS-30's `AssetFootprintProbe` → `imageOptions()`/`videoOptions()`, adjusted after creation (for example `fetchLimit`). These currently pass `PHFetchOptions()`, which the lint below rejects.
  - Video fetches use WS-18's video options (the flag is irrelevant there).
  - New `iOSCleanupTests/PhotoFetchLintTests.swift` → `testEveryPhotoKitFetchUsesSharedOptions`. It scans `iOSCleanup/` sources, DEBUG code included, using the `DesignLintTests` pattern with the root changed to `iOSCleanup/`, and fails on either of these:
    - (a) a `PHAsset.fetchAssets(` call whose arguments contain `options: nil`;
    - (b) a `PHFetchOptions()` initializer in any file other than `Engines/PhotoLibraryFetch.swift`.

    Callers that need a `fetchLimit` or an extra predicate start from a `PhotoLibraryFetch` factory and mutate the result. The allowlist is empty. `PHAssetCollection.fetchAssetCollections(…, options: nil)` is not affected.
  - **Reset the persisted change token (WS-18 pitfall: "changing `includeAllBurstAssets` … must reset tokens").** A token taken before the flip describes a library without hidden frames, so a delta refresh from it would never surface them. Add `static let definitionVersion = 2` to `PhotoLibraryFetch` (1 is the pre-WS-40 definition), and store the applied version under the `dependencies.defaults` key `photoduck.library-fetch-definition`. When the restore seeds WS-18's inventory (`inventory.seed(fromSnapshotLibrary:changeTokenData:)`) and the stored version is lower than `definitionVersion`, pass `changeTokenData: nil`. That forces one full enumeration. Write the key only after that enumeration completes. WS-19's token-exactness rule then persists a fresh token with the next snapshot.
- **Edge cases:** Limited-access sessions keep WS-20's in-memory rule (invariant 15). The flag does not change what Limited access can see.

**WS-40.3 — `burstPickBonus` in keeper ranking**
- **Change:**
  - `KeeperSignals` gains `var burstPickBonus: Double? = nil` (optional `var`, like WS-37's fields).
  - In `ConservativeKeeperRankingService.rankKeeper`: `score += signals.burstPickBonus ?? 0`, with reasons "Your burst pick" (user pick) or "Burst cover photo" (representative).
  - The field is set only by `BurstExtrasPlanner`, so no other ranking changes.

**WS-40.4 — `BurstExtrasPlanner` (pure)**
- **Change:** new `iOSCleanup/Engines/BurstExtrasPlanner.swift`:

```swift
struct BurstFrameDescriptor: Equatable, Sendable {
    let id: String; let burstIdentifier: String; let creationDate: Date?
    let representsBurst: Bool; let isAutoPick: Bool; let isUserPick: Bool
    let isFavorite: Bool; let canDelete: Bool; let pixelWidth: Int; let pixelHeight: Int
    var isUnpicked: Bool { !representsBurst && !isAutoPick && !isUserPick }
    static func make(_ asset: PHAsset) -> BurstFrameDescriptor?        // nil when burstIdentifier == nil
    static func isHiddenExtra(_ asset: PHAsset) -> Bool                // burst frame, !representsBurst, not a user pick
}
enum GroupAutoCleanPolicy: String, Codable, Sendable { case standard, perGroupOnly }
struct BurstExtrasPlan: Equatable, Sendable {
    let memberIDs: [String]; let keeperID: String?; let deleteCandidateIDs: [String]
    let protectedIDs: Set<String>; let confidence: SimilarGroupConfidence
    let recommendedAction: SimilarRecommendedAction; let autoCleanPolicy: GroupAutoCleanPolicy; let reasons: [String]
}
enum BurstExtrasPlanner {
    /// Signals: WS-37 neutral fallback + burstPickBonus 1.0 for the representative or a user pick.
    static func rankingInput(for frames: [BurstFrameDescriptor]) -> SimilarityClusterInput?
    static func plan(frames: [BurstFrameDescriptor], ranking: KeeperRankingResult) -> BurstExtrasPlan?
}
```

  - Rules in `plan`:
    1. Unpicked frames go in `deleteCandidates`, minus favorites and frames that cannot be deleted. If nothing remains, return nil (no group).
    2. Protected: every user pick, every non-representative auto-pick, favorites and undeletable frames. On candidates these become `isProtected = true` with `selectionState = .protected`.
    3. The keeper must be the representative or a user pick. Anything else gives `.reviewManually`, `.medium`.
    4. If there is no representative at all: `.reviewManually`.
    5. Otherwise: `.keepBestTrashRest`, `.high`.
    6. `autoCleanPolicy`: `.standard` if any frame is a user pick, else `.perGroupOnly`.
    7. Reasons: "N burst frames you never picked", plus the keeper reason.
  - One group per burst, never chunked (one cover photo means one keeper).
  - No time-span limit, because bursts are identified by `burstIdentifier`. `SimilarityThresholds`/profile `burstWindowSeconds` is unchanged.

**WS-40.5 — Engine integration (metadata-only, published immediately)**
- **Change** in `PhotoScanEngine.performScan`:
  1. After target planning and **before** the analysis loop:
     - Build `framesByBurst` once from `allAssets` (O(n)).
     - `touchedBursts` = `burstIdentifier`s of target assets that have at least one `isHiddenExtra` frame. Process them in chunks of 200 with `Task.checkCancellation()`.
     - For each burst, call `rankingInput`, then the engine's keeper ranker, then `plan`, then `PhotoGroup(...)` with `reason: .burstShot`, `groupType: .burst`, explicit keeper and delete IDs, and candidates carrying `isProtected`.
  2. Hidden extras are removed from the Vision work list. They are inserted into `evaluatedAssetIDs` and counted as processed and analyzed (DECISION above), and they are never added to `unanalyzedAssetIDs`.
  3. `burstOwnedIDs` = all members of those groups. `makeGroups` filters `descriptors` to exclude `burstOwnedIDs` before `candidateGraph.formClusters`, so the representative and picks (still Vision-analyzed as visible photos) never form a second, overlapping burst cluster. Groups stay pairwise disjoint.
  4. Every `PhotoScanUpdate.groups` includes the burst-extras groups (the cumulative shape is unchanged; invariant 17).
  5. Incremental runs recompute only touched bursts. Untouched burst groups persist in the snapshot.
- **Edge cases:**
  - Do not alter the WS-24 loop structure. The partition happens before it.
  - WS-12's `applyingUserKeptIDs` applies to these groups automatically.
  - WS-13's live-favorite guardrail applies at commit.
  - Burst-extras groups do not pass WS-38's visual verification (see WS-38.4).

**WS-40.6 — Persist the policy and exclude per-group-only bursts from Auto-clean**
- **Change:**
  - `PhotoGroup` gains a stored `autoCleanPolicy: GroupAutoCleanPolicy` (init default `.standard`) and `var isAutoCleanAllEligible: Bool { isAutoCleanEligible && autoCleanPolicy == .standard }`.
  - `CachedPhotoGroup` gains `autoCleanPolicy: GroupAutoCleanPolicy?` (`decodeIfPresent`, nil → `.standard`), round-tripped in `makeGroup(using:)`. Encode `.standard` as nil (write the field only for `.perGroupOnly`), so WS-16's `AnalysisSnapshotBuilderTests` goldens stay byte-identical (WS-16's additive-field rule). Add a round-trip test instead of a golden edit.
  - **Every `PhotoGroup(...)` rebuild must carry `autoCleanPolicy`.** Otherwise a rebuilt burst group silently becomes `.standard` and enters Auto-clean all. Add the field to each rebuild call in this PR:
    - WS-12's `PhotoGroup.applyingUserKeptIDs(_:)`;
    - WS-21's `PhotoResultPruner.prunedGroup(_:removing:)`;
    - WS-30's `PhotoGroup.replacingReclaimSizing(_:)`;
    - `CachedPhotoGroup.makeGroup(using:)`.

    Then `grep -rn "PhotoGroup(" iOSCleanup` for any other site. WS-63's `pairEvidence` later follows the same list.
  - `AutoCleanPlanner` (WS-12), `PhotoResultsView.autoCleanEligibleGroups` and `AutoCleanToolbarState`'s count (WS-36) use `isAutoCleanAllEligible`.
  - Row and detail Keep Best and the Duck Mode queue keep using `isAutoCleanEligible`, because those surfaces show the photos.
- **Edge cases:** snapshot compatibility. Old snapshots decode as `.standard`, and no schema bump is needed.

### Tests
**`iOSCleanupTests/BurstExtrasPlannerTests.swift`** (simulator, pure plus `ConservativeKeeperRankingService`):
- `testRepresentativeIsKeeper`
- `testUserPicksAreProtectedAndNeverDeleted`
- `testUnpickedFramesAreDeleteCandidates`
- `testNonRepresentativeAutoPickIsKeptNotDeleted`
- `testBurstWithOnlyPicksProducesNoGroup`
- `testMissingRepresentativeIsReviewOnly`
- `testFavoriteHiddenFrameIsExcludedFromDeletes`
- `testUndeletableFrameIsExcluded`
- `testAutoPickOnlyBurstIsPerGroupOnly`
- `testBurstWithUserPickIsAutoCleanStandard`
- `testNoTimeSpanLimitForThirtySecondBurst`
- `testPlanPassesPhotoGroupInitAndGuardrails`: build the `PhotoGroup` and call `PhotoDeletionGuardrails.validate(group:)`.

**`iOSCleanupTests/PhotoScanEngineEndToEndTests.swift`** (simulator). Setup:
- A stub provider exposing one burst: representative, one user pick and 5 unpicked frames.
- Extend `ConfigurablePhotoScanTestAsset` with `representsBurst` and `burstSelectionTypes`.

Tests:
- `testBurstExtrasGroupIsKeepBestEligibleWithUnpickedDeletes`: eligible; reclaim equals the sum of the 5 frames' estimated sizes.
- `testHiddenFramesAreNeverSentToAnalyzer`: a counting analyzer is called only for visible assets, and hidden frames count as analyzed.
- `testBurstOwnedFramesDoNotFormSecondCluster`
- `testAutoPickOnlyBurstExcludedFromAutoCleanAll`

**Snapshot, planner and lint tests** (simulator):
- `PhotoScanEngineTests.testCachedGroupRoundTripsAutoCleanPolicy`
- `PhotoScanEngineTests.testLegacyCachedGroupDecodesStandardPolicy`
- `BurstExtrasPlannerTests.testEveryRebuildCarriesAutoCleanPolicy`: a `.perGroupOnly` group stays `.perGroupOnly` through `applyingUserKeptIDs`, `PhotoResultPruner.prunedGroup`, `replacingReclaimSizing` and the cache round-trip.
- `PhotoScanEngineTests.testResumePlannerTreatsHiddenFramesAsCoveredAfterCompletion`: a completed snapshot containing hidden-frame IDs gives `requiredAssetIDs` without them.
- `PhotoFetchLintTests.testEveryPhotoKitFetchUsesSharedOptions`: rules (a) and (b), empty allowlist.
- `HomeViewModelTests.testPreBurstFlipChangeTokenForcesFullEnumeration` (WS-07 harness with a stub library source): a restored snapshot with a token and no `photoduck.library-fetch-definition` key. The restore seeds with a nil token, one full enumeration runs, and the key is written afterwards. A second launch uses the delta path.
- `DeletionManagerTests.testResolverUsesIdentifierOptions` (or a lint-only check if the resolver cannot be observed): hidden-frame IDs resolve at commit.

**Device-only:** WS-40.1 and the Device QA section.

### Acceptance criteria
- [ ] WS-40.1 device results are recorded in the PR.
- [ ] Burst-extras groups appear with every user-pick frame protected and only unpicked frames deletable (BurstExtrasPlanner tests).
- [ ] The keeper comes from `ConservativeKeeperRankingService` via `burstPickBonus`.
- [ ] Every PhotoKit asset fetch (inventory, engine, reconcile, existence, rehydrate, export, the `DeletionManager` resolver, the album index and the DEBUG seeder, census and probe) uses `PhotoLibraryFetch`, and the lint enforces it: no `options: nil` and no `PHFetchOptions()` outside `PhotoLibraryFetch.swift`.
- [ ] The first launch after upgrading ignores the pre-flip change token and enumerates once, so existing installs see hidden burst frames (`testPreBurstFlipChangeTokenForcesFullEnumeration`).
- [ ] After a completed scan, relaunch and an incremental scan neither drop the groups nor rescan the hidden frames.
- [ ] Hidden frames never hit Vision.
- [ ] Auto-pick-only bursts are excluded from Auto-clean all. Per-group Keep Best on them is free.
- [ ] Full suite green, zero warnings. `CLAUDE.md` documents burst extras, the fetch-options rule and `autoCleanPolicy`.

### Device QA
1. Hold the shutter to shoot a 20-frame burst. Scan. One burst-extras group appears in the Burst filter, and its delete count equals the unpicked frames.
2. In Photos, Select… one favorite frame of a second burst and choose "Keep Everything". Scan. The picked frame is marked protected and is never selected.
3. Keep Best on the first burst: one iOS prompt, and the count matches. Photos shows the burst reduced.
4. Relaunch the app. The group does not reappear, and Home counts are stable. Run an automatic scan: no re-analysis loop.
5. Auto-clean all excludes the first burst (auto-pick only) and includes the second.

### Pitfalls and out of scope
- **Never treat an auto-picked representative as user-confirmed for Auto-clean all** (DECISION above).
- Never delete a user pick in an automated plan (invariant 7).
- **Never bypass `PhotoGroup.init` or the guardrails.**
- Never fetch with `options: nil` again, or hidden frames silently vanish from rehydrate and reconcile.
- The library count now includes hidden frames. Home copy that quotes "N photos" is WS-31/WS-45 territory (chapters 07 and 09).
- Scale hardening for huge bursts belongs to WS-53 (chapter 11).
- **Reconciliation:**
  - Lead item (chapters 01–02 final): the routing list and `PhotoFetchLintTests` now cover `DeletionManager`'s resolver (`PhotoLibraryDefaults.resolveAssets`, WS-03/WS-11) and the DEBUG fetches (WS-07's seeder, WS-09's census, WS-30's probe). Those currently pass `PHFetchOptions()`, so the lint defines rule (b) explicitly. WS-13's album index and WS-27's count fallback are added for the same reason.
  - WS-18's pitfall requires a change-token reset when `includeAllBurstAssets` flips. This was missing here and is now WS-40.2's definition-version key.
  - Issue from this chapter to WS-12: `AutoCleanPlanner` and WS-36's `AutoCleanToolbarState` count both use `isAutoCleanAllEligible` (WS-40.6).
  - Lead item (chapters 03–04 final): WS-40.6 lists every `PhotoGroup` rebuild site that must carry `autoCleanPolicy` (`applyingUserKeptIDs`, `PhotoResultPruner.prunedGroup`, `replacingReclaimSizing`, `CachedPhotoGroup.makeGroup`), matching the reconciliation notes in chapters 03 and 04. `.standard` is encoded as nil so WS-16's goldens hold. The resolver route names WS-11's `ResolvedPhotoAssets` return type.

### Verification notes
| Finding | Verdict | Notes (what is actually true; how the plan differs from the reviewer's proposed fix) |
|---|---|---|
| SCAN-09 | confirmed | No burst APIs are used anywhere, and inventory fetches pass `options: nil`. How much reclaim this unlocks depends on the user's bursts. The verifier's correction is adopted: one shared fetch-options factory used everywhere, including identifier, rehydrate and export fetches, instead of keeping hidden frames out of the inventory. That would make reconcile and resume treat them as unknown and rescan forever. The planner skips visual verification and the 3 s window by construction (metadata identity). Hidden frames skip Vision entirely. The reviewer's "high confidence only when keeper is representative or user pick" is kept, and auto-pick-only bursts are additionally excluded from Auto-clean all. |
