# PhotoDuck — Fix Specification

Derived from a full four-track code review (photo/ML pipeline, UI layer, files/video/deletion, monetization/App Store) on 2026-07-23. All paths relative to `ios-cleanup/`. Work top to bottom: P0 items are broken features, data-loss risks, or submission blockers; P1 is correctness; P2 is performance; P3 is polish. Contacts engine work is deliberately out of scope except where paying users are affected.

Conventions for every fix: don't modify deletion/purchase safety semantics without a test; new behavior gets a test where a seam exists; update CLAUDE.md when behavior changes.

---

## P0 — Broken features, data loss, ship blockers

### 0.1 Commit the codebase [REPO]
The entire current app is untracked (`?? ios-cleanup/`). Commit and push before anything else. Then (separate commit) remove the stale duplicate app at the repo root so there is exactly one source of truth.
- **Accept:** `git status` clean; GitHub `stashclaw/ios-cleanup` contains the current app; root-level stale copy removed or clearly marked.

### 0.2 Files tab is permanently dead [BUG]
`HomeViewModel.scanFiles()` (Views/HomeViewModel.swift:513) and `scanContacts()` (:500) are never called from any view. `PhotoDuckShellView.swift:36-48` passes always-empty arrays, so FileResultsView/ContactResultsView show "nothing found" forever and Home tiles read "Idle / 0 found".
- **Fix:** trigger both scans from the appropriate lifecycle points (initial deep clean, tab activation, pull-to-refresh). Ensure scan states drive the tiles.
- **Accept:** on a device with large videos, the Files tab lists them; Home tile shows real counts.

### 0.3 Free tier has zero photo deletion — inverted from design [MONETIZATION][REVIEW-RISK]
Docs promise "Keep Best free, individual swipe-deletes free". Reality: Auto-clean paid (Views/Photos/PhotoResultsView.swift:296, :105), Delete Selected paid (Views/Photos/PhotoGroupDetailView.swift:79), and Duck Mode's only commit path is paywalled (Views/Photos/SwipeModeView.swift:246) — free users can swipe 200 photos, then hit a paywall to have any of it honored. Highest App-Review dark-pattern risk in the app; also kills conversion.
- **Fix (decide one):** (a) restore the documented free tier — per-group Keep Best free + individual swipe commits free, bulk operations paid; or (b) metered free tier (e.g. 5 free commits/month). Paywall must appear BEFORE invested effort, never after.
- **Also:** add "Keep Best" button to PhotoGroupDetailView (currently doesn't exist at all); fix `DuckBottomActionBar.swift:40` so an empty selection disables the button outright, and show a lock affordance when gated.
- **Accept:** a free user can complete at least one real deletion end-to-end; no flow collects user effort and then paywalls the commit; CLAUDE.md matches the shipped gating.

### 0.4 Video export cannot be cancelled; orphans multi-GB tmp files [DATA-LOSS-ADJACENT]
"Cancel" only dismisses the sheet (Views/Files/VideoCompressionView.swift:41); the compression `Task` (:185) is never stored/cancelled; the engine's `AsyncStream` has no `onTermination` and never calls `session.cancelExport()` (Engines/VideoCompressionEngine.swift:45-57).
- **Fix:** store the task; on dismiss/cancel, cancel it; add `continuation.onTermination` that calls `cancelExport()` and deletes the partial output; propagate cancellation from stream to the inner export task. Add a startup sweep deleting orphaned `compressed_*.mp4` in tmp.
- **Accept:** dismissing mid-export stops CPU work within ~1s and leaves no file in tmp; relaunching cleans any historic orphans.

### 0.5 Compress-and-replace strips creation date and location [DATA-LOSS]
`creationRequestForAssetFromVideo` (Engines/VideoCompressionEngine.swift:106-108) never copies metadata; replacement asset is dated "now", no geodata — irreversible once the original leaves Recently Deleted.
- **Fix:** on the creation request set `creationDate = originalAsset.creationDate`, `location = originalAsset.location`, and `isFavorite` if set.
- **Accept:** compressed replacement sorts at the original's date in Photos and keeps its location.

### 0.6 Compression partial-failure: false "failed", duplicate copies on retry [DATA-LOSS]
`saveAndDeleteOriginal` (Engines/VideoCompressionEngine.swift:104-115): save succeeds → user declines system delete dialog → error path shows "Compression failed" (VideoCompressionView.swift:216-217) and Retry (:168) re-exports and saves ANOTHER copy; tmp cleanup (:114) is skipped on this path.
- **Fix:** make save and delete separately reported outcomes (e.g. enum `savedAndDeleted` / `savedButOriginalKept(Error?)` / `failed`). Treat `PHPhotosError.userCancelled` on the delete step as success-with-note ("Compressed copy saved — original kept"). Never re-export on retry if a saved copy already exists (track the created asset's localIdentifier). Always clean tmp.
- **Accept:** declining the delete dialog shows accurate copy and no error; tapping the action again cannot produce a second compressed copy.

### 0.7 No disk-space or output-size checks in compression [BUG]
No preflight of `volumeAvailableCapacityForImportantUsage` before iCloud download or export; fixed savings multipliers (0.30/0.55/0.90, Engines/VideoCompressionEngine.swift:22-28) ignore codec/resolution; output is never compared to input — HEVC sources re-encoded via H.264 presets can come out LARGER and the app replaces anyway.
- **Fix:** preflight free space vs estimated need (fail early with clear message); after export compare sizes and abort replacement (with explanation) if output ≥ input; prefer `AVAssetExportPresetHEVC*` presets; derive estimates from source bitrate/resolution instead of flat multipliers.
- **Accept:** compressing an already-efficient video never replaces it with a bigger file; low-disk devices get a clear preflight error, not a mid-export AVFoundation failure.

### 0.8 iCloud-optimized libraries scan to "clean" silently [BUG]
Feature prints load with `allowNetwork: false` (Engines/PhotoScanEngine.swift:363-369); on "Optimize iPhone Storage" libraries most assets yield no evidence; scan completes 100% and reports nothing; no per-asset "couldn't analyze" surfacing exists in `PhotoScanUpdate`.
- **Fix:** count assets with no usable feature print; surface "N photos couldn't be analyzed (stored in iCloud)" in scan results with an option to re-run with network allowed (user opt-in, show it may download data). Same `allowNetwork` treatment for result thumbnails (see 1.6).
- **Accept:** an iCloud-optimized library reports unanalyzed counts instead of a false "library looks clean".

### 0.9 No PHPhotoLibraryChangeObserver — stale UI everywhere [BUG]
Zero observers app-wide (verified). Consequences: deleted assets linger in `photoGroups`; hero "reclaimable" floored by persisted `max(...)` so it never decreases (Views/HomeViewModel.swift:114-119); `_storageInfo` cached once (:147-156); compressed video's original stays listed in Files (its row's Compress action then fails); freshness check is count-only (:543-561) so delete-one-shoot-one looks fresh.
- **Fix:** register a `PHPhotoLibraryChangeObserver` (in HomeViewModel or a dedicated service); on change, prune dead assets from `photoGroups` / `largeFiles` via `PHObjectChangeDetails`, recompute reclaimable bytes (remove the `max()` floor), refresh storage info, and mark freshness by change details rather than count.
- **Accept:** deleting photos in Photos.app while the app is open updates lists and hero numbers without a manual rescan.

### 0.10 Invisible chrome traps users [BUG][UI]
(a) Duck Mode's only exit "Done" is white text (Views/Photos/SwipeModeView.swift:35-37) on the globally-forced near-white nav bar (iOSCleanupApp.swift:41-54) — invisible. Same for the white gear menu (Views/PhotoDuckShellView.swift:149-151). (b) "Scan diagnostics" heading is duckCream-on-duckCream (PhotoDuckShellView.swift:276-279).
- **Fix:** remove the global opaque appearance; use per-screen `.toolbarBackground`/`.toolbarColorScheme` matched to each screen's background; fix the heading color.
- **Accept:** every toolbar control is visible on every screen in light and dark mode.

### 0.11 App Store submission blockers [STORE]
1. Bundle ID is `com.yourname.iOSCleanup` (iOSCleanup.xcodeproj/project.pbxproj:694, 715; tests :732, :749) while the IAP is `com.photoduck.app.unlock` — pick the real ID and align.
2. `CFBundleDisplayName` is "iOSCleanup" and both permission strings say "iOSCleanup needs…" (Info.plist:12, 38-41) — rebrand to PhotoDuck (permission dialogs show this text).
3. No `PrivacyInfo.xcprivacy` anywhere → automatic ITMS-91053 rejection. Declare `NSPrivacyAccessedAPICategoryUserDefaults` (CA92.1) and `NSPrivacyAccessedAPICategoryDiskSpace` (E174.1/85F4.1); declare no data collection.
4. Add `ITSAppUsesNonExemptEncryption` = false.
5. Remove fabricated numbers (2.3.1 magnet for cleaner apps): hardcoded 40/25/20/15% storage split (Views/HomeView.swift:321-343), flat 250 MB/group estimate (:416), "% analyzed" showing storage-used fraction (:107-111), "Photos scanned" showing photos-in-groups (:227-230), static "Est. completing soon" (:379), and onboarding "Duplicates Found!" before any scan (Views/OnboardingView.swift:77-84) plus "All Set!" above a permission button (:127-153).
6. Remove `iOSCleanup.storekit` from the Resources build phase (project.pbxproj:49, 466); check in a shared `.xcscheme` with the StoreKit configuration attached (repo currently has NO schemes — fresh checkouts get an empty-products paywall).
7. Add `NSPhotoLibraryAddUsageDescription` (compression writes to the library).
8. Add privacy-policy link (and ideally terms) to PaywallView; decide `familySharable` deliberately (irreversible in ASC).
- **Accept:** archive uploads without ITMS errors; all user-facing numbers are computed from real data; TestFlight purchase flow works from a clean checkout.

### 0.12 Purchase state hardening [MONETIZATION]
`@AppStorage("isPurchased")` bool (Store/PurchaseManager.swift:10) is the sole gate: trivially flippable, and `updatePurchaseStatus()` (:81-92) writes `false` whenever `currentEntitlements` is transiently empty (signed-out App Store, fresh reinstall, outage) — silently re-locking paying users.
- **Fix:** distinguish "verified not-purchased" from "couldn't determine": only downgrade to false when the entitlement check completed successfully and definitively; keep cached true otherwise. Optionally re-check entitlements at high-value gate time. Surface `.pending` (Ask to Buy, :54-55) with user feedback, and post `.purchaseDidSucceed` from the `Transaction.updates` listener path too (currently only from PaywallView buttons — an open paywall won't dismiss on updates-driven purchases).
- **Accept:** airplane-mode relaunch keeps a purchaser unlocked; Ask to Buy shows a pending message; paywall auto-dismisses when an approval lands.

### 0.13 Paid "Merge" button is a no-op for payers [MONETIZATION][contacts, in scope because payers hit it]
Views/Contacts/ContactResultsView.swift:88-91 — after the paywall guard, the button body is an unimplemented comment. Paying users tap Merge, nothing happens.
- **Fix:** navigate to `ContactMergePreviewView` (the working path already exists via Review).
- **Accept:** paid user's Merge tap lands on the merge preview.

---

## P1 — Correctness and UX-critical

### 1.1 Undo toast: hidden, lying countdown, blocking flows [UX]
(a) Toast overlays ContentView (iOSCleanupApp.swift:22-35) but main delete flows run in sheets above it (HomeView.swift:50-56, PhotoDuckShellView.swift:157-163) — undo affordance invisible exactly when needed. (b) Countdown label always reads "0s": `withAnimation` sets the model value instantly (Views/Components/UndoToast.swift:107-110) while `remainingSeconds` (:23-25) reads it. (c) Callers `await` the 10s window (`scheduleDeleteAndWait`, Engines/DeletionManager.swift:138-144): rows vanish only after 10s, second action during window throws `deletionAlreadyPending` shown as raw error (PhotoResultsView.swift:173-178), PhotoGroupDetailView shows "Deleting…" for 10s (:75).
- **Fix:** present the toast at the top presented-view-controller layer (or inside each sheet); drive countdown from a timer/`TimelineView`; make deletion optimistic — update UI immediately, run the undo window in the background, restore on undo; queue or coalesce follow-up deletions instead of erroring. Align window duration with docs (pick 5s or 10s, update DeletionManager.swift:139 comment + both CLAUDE.mds).
- **Accept:** delete from the results sheet → toast visible with live countdown; UI updates instantly; a second delete during the window works.

### 1.2 Permission-denied dead ends [UX]
`heroState == .permissionRequired` CTA calls `startDeepClean()` again → throws again, silent infinite loop (Views/HomeView.swift:209-212). `scanErrorMessage`, `heroDetailText`, `heroStatusLabel`, `resultsFreshnessState` are rendered nowhere (verified). No limited-library management UI (`presentLimitedLibraryPicker` never called), no explanatory banner.
- **Fix:** denied → banner + "Open Settings" deep link; limited → banner + "Manage selection" (`presentLimitedLibraryPicker`); wire the existing unused hero copy into the UI or delete it; render freshness state ("results from DATE — rescan").
- **Accept:** a user who skipped permissions can recover from Home without reinstalling.

### 1.3 Duck Mode edge states [UX]
Empty queue → blank black screen: `buildQueue` never sets `isComplete` for an empty build (Views/Photos/SwipeModeViewModel.swift:148-212), progress shows 100% via the `totalReviewableCount == 0 → 1` branch (:58-61). Rapid taps double-advance: `swipeLeft/right` schedule via `asyncAfter(0.25)` with no in-flight guard (SwipeModeView.swift:182-190).
- **Fix:** empty queue → set complete immediately and show a proper "nothing to review" state; add an in-flight flag debouncing the buttons.
- **Accept:** Smart Cleanup with all-review-only groups shows a friendly state, not black; button mashing advances exactly one card per gesture.

### 1.4 Fresh install shows "Done ✓" [BUG]
`isAllDone` counts `.idle` as done (Views/HomeViewModel.swift:133-136); status pill (HomeView.swift:141-147) shows green "Done ✓" beside a "Start scan" CTA on first launch.
- **Fix:** all-idle → "Not scanned yet" state.

### 1.5 Continuation leaks on degraded-only image delivery [BUG]
Pattern `guard !isDegraded else { return }` leaks the `CheckedContinuation` (and hangs the awaiting task) when Photos delivers only a degraded image — which `.fastFormat` permits. Sites: Views/Files/FileResultsView.swift:217-233, Views/Photos/PhotoResultsView.swift:480-491 (also `isNetworkAccessAllowed = false` → eternal spinners on iCloud assets, :417-419), Utilities/SharedHelpers.swift:76-98, Views/Photos/PhotoGroupDetailView.swift:243-259, SwipeModeView.swift:351-365, PhotoDuckShellView.swift:486-508.
- **Fix:** one shared async thumbnail loader: `.opportunistic`, resume exactly once on final (or on degraded if the request errors/ends), placeholder on nil, explicit iCloud fallback icon. Replace all six call sites.
- **Accept:** iCloud-only library shows placeholders/cloud icons, never eternal spinners; no continuation-misuse runtime warnings.

### 1.6 FileResultsView deletion bypasses everything [BUG]
Views/Files/FileResultsView.swift:60-79: raw `performChanges` — no undo window, no freed-bytes stats, `deletionAlreadyPending` serialization bypassed, `PHPhotosError.userCancelled` rendered as a red error banner (:26, :69), and the `.filesystem` branch calls `FileManager.removeItem` with zero confirmation (:73).
- **Fix:** route photo-library deletes through `DeletionManager`; treat userCancelled as no-op; add a confirmation dialog for filesystem deletes (or remove the dead `.filesystem` source entirely — see 3.9).
- **Accept:** file deletes get the undo toast and count toward totals; declining the dialog shows nothing scary.

### 1.7 File size math is wrong and inconsistent [BUG]
`FileScanEngine.fileSize` (Engines/FileScanEngine.swift:36-47) sums ALL `PHAssetResource`s → edited videos double-count (~2×). Coexists with `PHAsset.estimatedFileSize` (Utilities/PHAsset+FileSize.swift:11-17) which picks one resource, uses private KVC key `"fileSize"` (App Review risk, :15) and a pixel-based fallback that's nonsense for video (:19-22) yet `DeletionManager.estimatedBytes` applies it to any asset.
- **Fix:** one audited size function: pick the current representative resource (`.fullSizeVideo`/rendered edit if present, else original), no private KVC (use `PHAssetResource` + on-demand `URLResourceValues` where possible, else document the estimate), video-aware fallback. Use it everywhere; extract pure logic as `[(type, size)] → bytes` for tests.
- **Also:** `displayName` is `asset.localIdentifier` (FileScanEngine.swift:29) — users see UUIDs; use `PHAssetResource.originalFilename` (already fetching resources). The UUID also feeds the extension-based `isVideo` fallback (FileResultsView.swift:94-95) which can never match.
- **Accept:** edited video shows its real size; both screens agree; rows show real filenames.

### 1.8 Permission denial masquerades as empty success [BUG]
Engines/FileScanEngine.swift:13-14 returns `[]` on denied/restricted → state `.completed` → "No files or videos over 50 MB were found". Engine also requests `.readWrite` for a read-only scan.
- **Fix:** throw a typed `permissionDenied` error; HomeViewModel maps it to the permission state (1.2). Request `.readWrite` only when needed.

### 1.9 ML: train/serve feature skew [ML]
`rankKeeper` feeds the keeper model empty strings / zeros for six trained features (`bucket`, `groupType`, `confidence`, `suggestedAction`, `similarityToKeeper`, `fileSizeBytes`) — Engines/MLEnhancedKeeperRankingService.swift:34-49 — so predictions are noise and the 0.85 override gate fires arbitrarily. The correct full-context builder `KeeperPredictionInput.init(asset:group:)` already exists unused (Engines/SimilarityCoreMLClassifier.swift:233-254).
- **Fix:** thread group context into `rankKeeper` and use the existing builder. Add a schema contract test: feature names/values emitted by `KeeperFeatureProvider` == CSV header set from `exportKeeperTrainingCSV`, and no trained feature receives a constant placeholder.

### 1.10 ML: feedback loop trains on its own suggestions [ML]
(a) `keeperID = selectedKeeperID ?? group.keeperAssetID` records the SYSTEM's suggestion as the user's choice on accept-default paths (Engines/PhotoFeedbackStore.swift:72); (b) label is `asset.id == finalKeeperAssetID` (Engines/PhotoTrainingExampleBuilder.swift:138-146); (c) dominant feature `ranking_score` is the ranker's own output (PhotoFeedbackStore.swift:314). Model learns "predict the existing ranker"; the 60/40 blend then double-counts.
- **Fix:** add `active_choice` column (kind == .keeperOverride, or finalKeeper ≠ suggested) to keeper training rows; downweight or exclude accepted-default rows at training time; consider dropping `ranking_score` as a feature or logging it for analysis only. Schema is versioned (`feature_schema_version`) — bump it.

### 1.11 ML: training script split inverted + metric mislabeled [ML]
`randomSplit(by: 0.2)` puts 20% in TRAINING (MLTraining/TrainKeeperModel.swift:125-129, 205-209); prints `classificationError` labeled "accuracy" (:148-152, :226-230); random row split leaks same-group siblings across train/test.
- **Fix:** swap the split (train on 80%), print `1 - classificationError` as accuracy, split by group/event ID not by row. Add an assertion on split sizes.

### 1.12 ML: batch append double-writes to SQLite [ML]
`append(_ newEvents:)` dedupes per-event for JSON but forwards the FULL input array to `persistFeedbackEvents` (Engines/PhotoFeedbackStore.swift:42-57); SQLite only dedupes on UUID PK, so a same-dedupe-key/fresh-UUID replay double-counts in training data.
- **Fix:** forward only events that survived JSON dedupe. Test: batch path with duplicate dedupe_key, distinct UUIDs → one SQLite row.

### 1.13 ML: exports/maintenance are dead code; DB grows forever [ML]
`exportTrainingDataToDocuments`, `exportDatabaseToDocuments`, `deleteOldFeatures`, `vacuum` have zero call sites; `MLGroupActionService`/`predictGroupAction` never invoked. `exportDatabaseToDocuments` copies the sqlite file WITHOUT a WAL checkpoint (Engines/PhotoMLBridge.swift:171-179) so exports silently miss recent transactions. `photo_features`/`pairwise_similarity` retain rows for deleted photos forever.
- **Fix:** add a debug/settings surface for export; run `PRAGMA wal_checkpoint(TRUNCATE)` before copying; run retention (delete features for assets gone from the library, periodic vacuum) after scans.
- **Also (group-action model):** `recommendation_accepted` is target leakage — derived from the same decision as the label (Engines/PhotoMLStore.swift:575, PhotoFeedbackStore.swift:347-367) and hardcoded `-1` at inference (SimilarityCoreMLClassifier.swift:272). Drop it as a feature.

### 1.14 Burst chunk remainder orphaned [BUG]
41-photo burst chunked by 40 → remainder of 1 fails `count >= 2`, isn't added to `assignedIDs`, and its only edges are filtered as burst-bucket/assigned (Engines/SimilarityPolicyServices.swift:696-713) — photo silently unreviewable every scan.
- **Fix:** fold remainder into the last chunk (39+2) or mark remainder assets assigned to the burst group. Test chunk boundaries at 40/41/80/81.

### 1.15 Stale @State copies of parent data [BUG]
`PhotoResultsView` copies `groups` into `State(initialValue:)` (Views/Photos/PhotoResultsView.swift:24-27) — list never grows during a live scan while `heroCard` denominators use fresh `groups.count` (:228-231). Same pattern in ContactResultsView (:12-15).
- **Fix:** derive visible rows from the parent binding + a local hidden/deleted-ID set instead of snapshotting the array.

### 1.16 Pause/resume is broken [BUG]
"Tap to pause" during Speed Clean calls `pauseDeepClean()` which guards `.deepClean` and silently no-ops (Views/HomeView.swift:213-214, HomeViewModel.swift:404-405). Paused state falls into the default CTA "Start scan" with no Resume language (HomeView.swift:160-180), and resume restarts from zero with a new engine (HomeViewModel.swift:417-434).
- **Fix:** support pausing both modes; show "Resume" CTA; persist scan cursor so resume continues (the engine already batches — persist last-processed index + accumulated groups, or at minimum reuse the analysis cache so completed work isn't redone).

### 1.17 Main-thread stalls [PERF-CORRECTNESS]
(a) `saveCompletedAnalysisSnapshot()` runs ~900 synchronous `PHAssetResource.assetResources` calls on the main actor at scan completion (Views/HomeViewModel.swift:652-653 → Utilities/PHAsset+FileSize.swift:11). (b) `assetFileSize` loops sync on main in PhotoGroupDetailView (:85-90, :261-269); `DuckAssetCard.fileSizeLabel` during body evaluation (SwipeModeView.swift:340-349); `pendingDeleteBytes` across all ducked assets when rendering completion (SwipeModeViewModel.swift:42-46). (c) `PhotoScanEngine()` constructed on main actor triggers synchronous CoreML model load/compile on first scan (HomeViewModel.swift:435).
- **Fix:** move size computation into the scan/background and cache per-asset bytes on the models; make model loading lazy off-main.
- **Accept:** no visible hitch at scan completion or while swiping; Instruments shows no main-thread PhotoKit metadata queries.

### 1.18 Silent error swallowing in persistence [ROBUSTNESS]
All PhotoMLBridge persistence drops errors in release (Engines/PhotoMLBridge.swift:48-53, 61-65, 103-107); `PhotoFeedbackStore.save()` is `try?` (:277-279); PhotoAnalysisCache load/save are `try?`. On a disk-full device — this app's expected environment — the entire personalization pipeline fails invisibly.
- **Fix:** log failures (os_log), track a `persistenceHealthy` flag, and surface a one-time notice when writes are failing (especially disk-full: that's actionable in a cleaner app). Distinguish "no model bundled" from "model failed to load" in SimilarityCoreMLClassifier (`try?` at :94, :134).

### 1.19 Vision revision unpinned; embedding size unvalidated [ML-ROBUSTNESS]
Thresholds (SimilarityPolicyTypes.swift:237-240) assume a fixed distance scale but `VNGenerateImageFeaturePrintRequest()` (Engines/PhotoScanEngine.swift:379) uses the OS default revision; stored embeddings stamped `embeddingVersion: 1` unconditionally (PhotoMLBridge.swift:25); `embeddingDimension = 128` (PhotoMLStore.swift:23) asserted nowhere.
- **Fix:** pin `revision` explicitly; derive `embeddingVersion` from the pinned revision; validate blob size on write and refuse mixed-version pair rows. Add a golden-fixture test (bundled image pairs → real feature-print distance within expected band) to catch OS scale shifts.

### 1.20 Compress button double-tap race [BUG]
State leaves `.idle` only when the first progress event arrives (Views/Files/VideoCompressionView.swift:111, :179) — two quick taps start two concurrent exports.
- **Fix:** set state to `.preparing` synchronously on tap; disable the button. Also surface the iCloud download phase via `PHVideoRequestOptions.progressHandler` (:222-237 currently shows a dead button for minutes on slow networks) and show "Saving…" between export completion and dialog (:132 stays at "100% — Compressing…").

### 1.21 Feedback-store role mislabeling [ML]
Non-`keeperOverride` events where final keeper ≠ suggested label the SUGGESTED keeper `.finalKeeper` too (Engines/PhotoFeedbackStore.swift:281-318) → two "final keepers", contradictory training labels via `outcomeLabel` (PhotoTrainingExampleBuilder.swift:117-124).
- **Fix:** role assignment must compare against the actual final keeper ID regardless of `kind`. Test `makeAssetSnapshots` across all kinds.

---

## P2 — Performance and efficiency

### 2.1 Priority sort waste
`assetPriority` builds `Calendar.date(byAdding:)` inside the comparator — ~1.6M calendar computations at 50k assets (Engines/PhotoScanEngine.swift:840-856); result is immediately re-sorted by date in `.deepClean` and unused in `.speedClean` (:790-838). Precompute keys once, or skip entirely per mode.

### 2.2 Feedback store rewrites everything per swipe
Every append re-encodes the full ≤1000-event JSON archive and rebuilds the entire profile (Engines/PhotoFeedbackStore.swift:27-40). Use the existing delta-merge for incremental profile updates; flush the archive periodically/on background.

### 2.3 Pairwise cache is write-only
Scan persists every pair result but never reads them back (Engines/PhotoMLStore.swift:321-379) — rescans redo all Vision work. Read cache keyed on (asset IDs, embeddingVersion) before computing.

### 2.4 Re-evaluation churn
`makeGroups` re-runs keeper ranking (and CoreML when bundled) for every cluster on each refresh (Engines/PhotoScanEngine.swift:298-313); memoize by member-ID set. Make `PhotoGroup` `Equatable` (asset IDs + action + confidence) so `apply(update:)` (HomeViewModel.swift:570) stops re-rendering the full list every ~12 photos.

### 2.5 Image decode spikes
`PhotoGroupDetailView.loadAllImages` decodes every member at 600×600 concurrently (:230-241) — ~85 MB for a 60-photo burst. Load visible cells lazily at cell size.

### 2.6 Stream buffering policy
`AsyncThrowingStream` default unbounded buffering retains full `[PhotoGroup]` snapshots if the consumer stalls (Engines/PhotoScanEngine.swift:51). Use `.bufferingNewest(1)` — matches UI semantics exactly.

### 2.7 Swipe dedupe drops legitimate repeats
Dedupe key has no time component (Engines/PhotoFeedbackStore.swift:145-152): delete → undo → delete again is silently dropped from learning. Include a decision-sequence or timestamp component.

---

## P3 — Polish, design, accessibility, hygiene

Design-system and screen-polish work is specced in the "Design-polish prompt" (see review notes / prompt file); headline items repeated here for tracking:

### 3.1 Design tokens
Consolidate the THREE parallel color systems (asset-catalog Duck*, hex `photoduck*` extensions, raw UIColor literals in iOSCleanupApp.swift:43-64 / OnboardingView.swift:22-25) into the asset catalog with dark variants; add semantic tokens (success/danger/warning/surface); replace 23 raw `.font(.system(size:))` uses with duck* scale additions (`duckStat`, `duckMicro`); codify 3 corner radii and a 4pt spacing scale; SF Symbol lock everywhere (replace emoji 🔒 at HomeView.swift:80, PhotoResultsView.swift:105).

### 3.2 Contrast and dark mode
Fix soft-pink-on-cream failures (PhotoDuckShellView.swift:255-260 "Remaining" tile, HomeView.swift:501-503 zero-count tiles, UndoToast.swift:85-97 progress bar). Decide dark mode: real dark variants or explicit `.preferredColorScheme(.light)` — currently empty states break on black (PhotoResultsView.swift:59-71, FileResultsView.swift:18-22).

### 3.3 Haptics
Zero haptics exist. Add: impact on swipe commit and keep/duck, notification-success on deletion/purchase/scan-complete, rigid on undo.

### 3.4 Moments
- Launch into Home, not the Similar tab (`selectedTab: Tab = .similar`, PhotoDuckShellView.swift:10).
- Scan-completion celebration (count-up of findings + "Review now" CTA); stop auto-presenting CompletionOverlay on every deletion commit (HomeView.swift:57-70, can collide with the results sheet — two `.sheet`s on one view); "Continue Cleanup" button should navigate, not just dismiss (:561-566).
- Auto-clean confirmation: thumbnail grid of exactly what's deleted + byte total (currently a text alert, PhotoResultsView.swift:114-121).
- Duck Mode: undo-last-swipe; pre-commit summary with thumbnails; replace placeholder yellow rectangle with mascot (SwipeModeView.swift:212-214).
- Group detail: tap-to-fullscreen compare with pinch zoom; visible best-shot badge in the grid.
- Recently Deleted honesty: post-commit note "Space frees permanently when Recently Deleted is emptied" + deep link; adjust "freed X MB" copy (DeletionManager.swift:132, VideoCompressionView.swift:146).
- Notification permission: pre-prompt context screen, don't fire mid-scan (HomeViewModel.swift:820-825); don't banner+sound while foregrounded (iOSCleanupApp.swift:89-95).

### 3.5 Accessibility
Photo grid cells are bare `onTapGesture` ZStacks — no button trait/label/selected announcement (PhotoGroupDetailView.swift:102-168); VoiceOver users cannot cull. 44pt minimum targets (filter pills ~29pt, PhotoResultsView.swift:250-262). Hide decorative "✦" (UndoToast.swift:61-63).

### 3.6 Copy fixes
Similar tab: `remainingGroups` subtracts items from groups (PhotoDuckShellView.swift:81); hero shows whole-library count under "Similars" with "photo(s)" pluralization (:71-73, :209); "Review progress" tile shows scan progress (:248-253). Duplicates vs Similar tiles both navigate to the same unfiltered list (HomeView.swift:253-257, 267-271) — filter by `SimilarityReason`. Developer vocabulary in consumer UI ("Scan diagnostics", "matches").

### 3.7 Dead code sweep
Delete or wire: `ThumbnailRail`, `ReviewDecisionHUD`, `ActionBar`, `UndoFeedbackBar`, `BestShotExplanationSheet`, `ReasonChipsRow` (DuckComponents.swift), `SimilarGroupReviewViewModel`, `BrandPresentationView`'s duplicate font resolver (:1213-1263), `UITableView.appearance()` (iOSCleanupApp.swift:64), unused HomeViewModel hero copy (or wire it per 1.2), `BundledCoreMLSimilarityClassifier` (SimilarityCoreMLClassifier.swift:66-79), dead `LargeFile.Source.filesystem` branch (or implement an app-sandbox scan that would make it real — it could find this app's own orphaned tmp files).

### 3.8 Misc hygiene
`LargeFile` blanket `@unchecked Sendable` without rationale (Models/LargeFile.swift:4, 11); decorative actors (FileScanEngine/VideoCompressionEngine hold no state — give VideoCompressionEngine real state via the current-export handle from 0.4); `PurchaseManager.deinit` touches main-actor state from nonisolated deinit (Swift 6 blocker, :22-24); hardcoded toast offset `24 + 49` (iOSCleanupApp.swift:31); landscape enabled in Info.plist but no screen adapts — lock portrait or adapt; internal purchase check inside VideoCompressionView (only the entry point gates today, FileResultsView.swift:35); align both CLAUDE.mds with shipped behavior (free tier, undo window, engine descriptions).

### 3.9 CSV/export hardening
`exportCSV` doesn't escape newlines and builds entire CSV in memory (Engines/PhotoMLStore.swift:693-699); `training_rows` unbounded. Escape properly, stream to disk, add retention.

---

## Test additions (in priority order)

1. Train/serve schema contract test (catches 1.9 and the group-action leakage in 1.13).
2. `AssetProviding` seam for PhotoScanEngine + end-to-end scan test: batching, eviction windows, screenshot compaction, nil-image degradation (0.8).
3. Positive-path guardrail test: valid high-confidence group passes `validate(groups:)` with exactly the expected delete IDs (today a reject-everything regression would pass the suite).
4. PhotoAnalysisCache round-trip + schema-version rejection + the rehydration-forces-reviewManually invariant (the single most safety-critical cache behavior is currently unasserted).
5. MLEnhancedKeeperRankingService coverage (override threshold, margin gate, blend, cancellation) — requires injecting the singletons (`MLKeeperRankingService.shared`, `PhotoMLBridge.shared`).
6. SQLite dedupe-by-dedupe_key via batch append (1.12).
7. Burst chunk boundaries 40/41/80/81 (1.14).
8. `makeAssetSnapshots` role assignment across kinds (1.21).
9. FileScanEngine size logic on extracted pure function: edited video, slo-mo, Live Photo (1.7).
10. VideoCompression: failure paths, cancellation, saveAndDeleteOriginal outcomes, output-smaller-than-input (0.4–0.7).
11. TrainKeeperModel: split-size assertion + metric naming (1.11).
12. Concurrency: concurrent `PhotoFeedbackStore.append` vs `loadIfNeeded`; scan cancellation mid-batch.

## Suggested sequencing

1. **Week 1 — stop the bleeding:** 0.1, 0.2, 0.10, 1.4, 1.5, 1.6, 0.13 (small, high-visibility).
2. **Week 2 — destructive-flow safety:** 0.4, 0.5, 0.6, 0.7, 1.1, 1.20.
3. **Week 3 — trust & data:** 0.8, 0.9, 1.2, 1.7, 1.8, 1.15, 1.16, 1.17.
4. **Week 4 — store & monetization:** 0.3, 0.11, 0.12, paywall resilience (retry on load failure, empty-products messaging).
5. **Week 5 — ML integrity:** 1.9–1.13, 1.19, 1.21, test seams.
6. **Ongoing — P2 perf + P3 polish** (pair P3 design work with the Claude design prompt).
